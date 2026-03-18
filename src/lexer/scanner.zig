//! ZTS Lexer Scanner
//!
//! 소스 코드를 순회하며 토큰을 하나씩 생성하는 핵심 모듈.
//! 파서가 `next()`를 호출하면 다음 토큰을 스캔한다 (D036).
//!
//! 설계:
//! - UTF-8 소스를 직접 순회 (D035)
//! - byte offset으로 위치 추적 (D015)
//! - line offset 테이블을 구축하여 line/column을 lazy 계산
//! - BOM 스킵, 줄 끝 문자 전부 인식 (D019)
//!
//! 참고: references/bun/src/js_lexer.zig, references/esbuild/internal/js_lexer/js_lexer.go

const std = @import("std");
const token = @import("token.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = token.Span;

/// 소스 코드를 토큰으로 분리하는 렉서.
///
/// 사용법:
/// ```zig
/// var lexer = Scanner.init(source);
/// lexer.next(); // 첫 토큰 스캔
/// while (lexer.token.kind != .eof) {
///     // 토큰 처리
///     lexer.next();
/// }
/// ```
pub const Scanner = struct {
    /// 소스 코드 (UTF-8)
    source: []const u8,

    /// 현재 읽기 위치 (byte offset). 다음에 읽을 바이트를 가리킨다.
    current: u32 = 0,

    /// 현재 토큰의 시작 위치 (byte offset)
    start: u32 = 0,

    /// 현재 토큰
    token: Token = .{},

    /// 줄 번호 (0-based). 줄바꿈을 만날 때마다 증가.
    line: u32 = 0,

    /// 현재 줄의 시작 byte offset. column = current - line_start.
    line_start: u32 = 0,

    /// 줄 시작 offset 테이블 (소스맵, 에러 메시지용).
    /// line_offsets[i] = i번째 줄의 시작 byte offset.
    /// line 0은 항상 offset 0이므로 초기값 포함.
    line_offsets: std.ArrayList(u32),

    /// 템플릿 리터럴 중첩 깊이 스택.
    /// 템플릿 안의 `${` 마다 brace depth를 push하고, 대응하는 `}`에서 pop한다.
    /// 스택이 비어있지 않으면 `}`를 만났을 때 템플릿 중간/끝으로 스캔해야 한다.
    template_depth_stack: std.ArrayList(u32),

    /// 현재 brace depth. `{`이면 +1, `}`이면 -1.
    brace_depth: u32 = 0,

    /// 이전 토큰의 종류. regex vs division 판별에 사용 (slashIsRegex).
    prev_token_kind: Kind = .eof,

    /// 소스를 UTF-8로 읽고 Scanner를 초기화한다.
    /// BOM이 있으면 스킵한다 (D019).
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Scanner {
        // 4GB 이상의 소스는 u32 offset으로 표현 불가 (D015)
        std.debug.assert(source.len <= std.math.maxInt(u32));

        var line_offsets = std.ArrayList(u32).init(allocator);
        // 첫 번째 줄의 시작 offset은 항상 0. 이 append가 실패하면 getLineColumn()이 동작 불가.
        line_offsets.append(0) catch @panic("OOM: failed to allocate initial line offset");

        var scanner = Scanner{
            .source = source,
            .line_offsets = line_offsets,
            .template_depth_stack = std.ArrayList(u32).init(allocator),
        };

        // UTF-8 BOM 스킵 (0xEF 0xBB 0xBF)
        if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) {
            scanner.current = 3;
            scanner.start = 3;
            scanner.line_start = 3;
            // line_offsets[0]도 BOM 이후로 업데이트
            scanner.line_offsets.items[0] = 3;
        }

        return scanner;
    }

    pub fn deinit(self: *Scanner) void {
        self.line_offsets.deinit();
        self.template_depth_stack.deinit();
    }

    // ====================================================================
    // 기본 읽기 함수
    // ====================================================================

    /// 현재 위치의 바이트를 반환한다. 끝이면 0을 반환.
    fn peek(self: *const Scanner) u8 {
        if (self.current >= self.source.len) return 0;
        return self.source[self.current];
    }

    /// 현재 위치 + offset의 바이트를 반환한다. 끝이면 0을 반환.
    fn peekAt(self: *const Scanner, offset: u32) u8 {
        const pos = self.current + offset;
        if (pos >= self.source.len) return 0;
        return self.source[pos];
    }

    /// 현재 위치를 1바이트 전진하고 이전 바이트를 반환한다.
    fn advance(self: *Scanner) u8 {
        if (self.current >= self.source.len) return 0;
        const byte = self.source[self.current];
        self.current += 1;
        return byte;
    }

    /// 소스 끝에 도달했는지.
    fn isAtEnd(self: *const Scanner) bool {
        return self.current >= self.source.len;
    }

    /// 현재 토큰의 소스 텍스트를 반환한다.
    pub fn tokenText(self: *const Scanner) []const u8 {
        return self.source[self.start..self.current];
    }

    /// byte offset으로부터 line과 column을 계산한다 (0-based).
    /// line_offsets 테이블에서 이진 탐색.
    pub fn getLineColumn(self: *const Scanner, offset: u32) struct { line: u32, column: u32 } {
        // 이진 탐색: offset보다 작거나 같은 가장 큰 line_start를 찾는다
        const offsets = self.line_offsets.items;
        var lo: u32 = 0;
        var hi: u32 = @intCast(offsets.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (offsets[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line_idx = lo - 1;
        return .{
            .line = line_idx,
            .column = offset - offsets[line_idx],
        };
    }

    // ====================================================================
    // 줄바꿈 처리
    // ====================================================================

    /// 줄바꿈 문자를 처리한다.
    /// \n, \r\n, \r, U+2028 (LS), U+2029 (PS) 전부 인식 (D019).
    /// 줄바꿈이면 true를 반환하고 current를 전진시킨다.
    fn handleNewline(self: *Scanner) bool {
        const c = self.peek();
        if (c == '\n') {
            self.current += 1;
            self.line += 1;
            self.line_start = self.current;
            self.line_offsets.append(self.current) catch {};
            return true;
        }
        if (c == '\r') {
            self.current += 1;
            // \r\n은 하나의 줄바꿈으로 처리
            if (self.peek() == '\n') {
                self.current += 1;
            }
            self.line += 1;
            self.line_start = self.current;
            self.line_offsets.append(self.current) catch {};
            return true;
        }
        // U+2028 (LS) = E2 80 A8, U+2029 (PS) = E2 80 A9
        if (c == 0xE2 and self.current + 2 < self.source.len) {
            if (self.source[self.current + 1] == 0x80 and
                (self.source[self.current + 2] == 0xA8 or self.source[self.current + 2] == 0xA9))
            {
                self.current += 3;
                self.line += 1;
                self.line_start = self.current;
                self.line_offsets.append(self.current) catch {};
                return true;
            }
        }
        return false;
    }

    // ====================================================================
    // 공백 스킵
    // ====================================================================

    /// 공백 문자를 스킵한다.
    /// 줄바꿈을 만나면 has_newline_before를 true로 설정.
    fn skipWhitespace(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', 0x0B, 0x0C => {
                    // 일반 공백: space, tab, vertical tab, form feed
                    self.current += 1;
                },
                '\n', '\r' => {
                    // 줄바꿈
                    _ = self.handleNewline();
                    self.token.has_newline_before = true;
                },
                0xE2 => {
                    // U+2028 (LS), U+2029 (PS) — handleNewline()에 위임
                    if (self.handleNewline()) {
                        self.token.has_newline_before = true;
                    } else {
                        return; // E2로 시작하지만 줄바꿈이 아님
                    }
                },
                0xC2 => {
                    // U+00A0 (NBSP) = C2 A0
                    if (self.peekAt(1) == 0xA0) {
                        self.current += 2;
                    } else {
                        return;
                    }
                },
                0xEF => {
                    // U+FEFF (BOM/ZWNBSP) = EF BB BF
                    if (self.peekAt(1) == 0xBB and self.peekAt(2) == 0xBF) {
                        self.current += 3;
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    // ====================================================================
    // 메인 스캔 루프
    // ====================================================================

    /// 다음 토큰을 스캔한다.
    /// 파서가 이 함수를 반복 호출하여 토큰을 소비한다.
    pub fn next(self: *Scanner) void {
        self.token.has_newline_before = false;
        self.token.has_pure_comment_before = false;

        // 주석을 만나면 스킵하고 다시 스캔해야 하므로 루프
        while (true) {
            // 공백 스킵 (줄바꿈 추적 포함)
            self.skipWhitespace();

            // 토큰 시작 위치 기록
            self.start = self.current;

            // 소스 끝 도달
            if (self.isAtEnd()) {
                self.token.kind = .eof;
                self.token.span = .{ .start = self.start, .end = self.current };
                return;
            }

            const c = self.advance();

            self.token.kind = switch (c) {
                // 단일 문자 토큰
                '(' => .l_paren,
                ')' => .r_paren,
                '[' => .l_bracket,
                ']' => .r_bracket,
                '{' => blk: {
                    self.brace_depth += 1;
                    break :blk .l_curly;
                },
                '}' => blk: {
                    // brace depth 감소
                    if (self.brace_depth > 0) self.brace_depth -= 1;
                    // 감소 후 스택 top과 비교: 템플릿 리터럴 안의 `}` 인지 확인
                    if (self.template_depth_stack.items.len > 0 and
                        self.brace_depth == self.template_depth_stack.items[self.template_depth_stack.items.len - 1])
                    {
                        break :blk self.scanTemplateContinuation();
                    }
                    break :blk .r_curly;
                },
                ';' => .semicolon,
                ',' => .comma,
                '~' => .tilde,
                '@' => .at,
                ':' => .colon,

                // 후속 문자에 따라 분기하는 토큰 — 추후 PR에서 구현
                // 현재는 단일 문자만 처리
                '.' => self.scanDot(),
                '+' => self.scanPlus(),
                '-' => self.scanMinus(),
                '*' => self.scanStar(),
                '/' => self.scanSlash(),
                '%' => self.scanPercent(),
                '<' => self.scanLAngle(),
                '>' => self.scanRAngle(),
                '=' => self.scanEquals(),
                '!' => self.scanBang(),
                '&' => self.scanAmp(),
                '|' => self.scanPipe(),
                '^' => self.scanCaret(),
                '?' => self.scanQuestion(),

                // 리터럴 — 추후 PR에서 세부 구현
                '0'...'9' => self.scanNumericLiteral(c),
                '\'', '"' => self.scanStringLiteral(c),
                '`' => self.scanTemplateLiteral(),

                '#' => blk: {
                    // hashbang (파일 시작) 또는 private identifier
                    if (self.start == 0 or (self.start == 3 and std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF"))) {
                        if (self.peek() == '!') {
                            self.scanHashbang();
                            break :blk .hashbang_comment;
                        }
                    }
                    // private identifier
                    self.scanIdentifierTail();
                    break :blk .private_identifier;
                },

                else => blk: {
                    // 식별자 시작 문자인지 확인
                    if (isIdentifierStart(c)) {
                        self.scanIdentifierTail();
                        // 키워드 확인
                        const text = self.tokenText();
                        break :blk token.keywords.get(text) orelse .identifier;
                    }
                    break :blk .syntax_error;
                },
            };

            // 주석(undetermined)이면 루프를 돌아 다음 토큰 스캔
            if (self.token.kind != .undetermined) {
                self.token.span = .{ .start = self.start, .end = self.current };
                self.prev_token_kind = self.token.kind;
                return;
            }
        }
    }

    // ====================================================================
    // 복합 연산자 스캔
    // ====================================================================

    fn scanDot(self: *Scanner) Kind {
        if (self.peek() == '.' and self.peekAt(1) == '.') {
            self.current += 2;
            return .dot3;
        }
        // .5 같은 숫자 리터럴
        const next_char = self.peek();
        if (next_char >= '0' and next_char <= '9') {
            return self.scanDecimalAfterDot();
        }
        return .dot;
    }

    fn scanPlus(self: *Scanner) Kind {
        if (self.peek() == '+') {
            self.current += 1;
            return .plus2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .plus_eq;
        }
        return .plus;
    }

    fn scanMinus(self: *Scanner) Kind {
        if (self.peek() == '-') {
            self.current += 1;
            return .minus2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .minus_eq;
        }
        return .minus;
    }

    fn scanStar(self: *Scanner) Kind {
        if (self.peek() == '*') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .star2_eq;
            }
            return .star2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .star_eq;
        }
        return .star;
    }

    fn scanSlash(self: *Scanner) Kind {
        const next_char = self.peek();
        if (next_char == '/') {
            self.scanSingleLineComment();
            return .undetermined;
        }
        if (next_char == '*') {
            self.scanMultiLineComment();
            return .undetermined;
        }

        // /= 는 항상 대입 연산자 (regex에서 = 가 첫 문자인 경우는 없음...
        // 실제로는 /=.../flags 도 유효한 regex이지만, 대입 연산자가 더 일반적.
        // esbuild/Bun도 /=를 항상 slash_eq로 처리)
        if (next_char == '=') {
            self.current += 1;
            return .slash_eq;
        }

        // regex vs division: 이전 토큰에 기반하여 판별
        if (self.prev_token_kind.slashIsRegex()) {
            return self.scanRegExp();
        }

        return .slash;
    }

    /// 정규식 리터럴을 스캔한다 (/pattern/flags).
    /// opening `/`는 이미 소비된 상태.
    ///
    /// 규칙:
    /// - `\/` 이스케이프된 slash → 정규식 계속
    /// - `[...]` character class 안에서는 `/`가 정규식을 끝내지 않음
    /// - 줄바꿈은 정규식 안에서 불허
    fn scanRegExp(self: *Scanner) Kind {
        var in_class = false; // [...] character class 안인지

        while (!self.isAtEnd()) {
            const c = self.peek();

            if (c == '\\') {
                // 이스케이프: 다음 문자를 무조건 스킵
                self.current += 1;
                if (!self.isAtEnd()) self.current += 1;
                continue;
            }

            if (c == '[') {
                in_class = true;
                self.current += 1;
                continue;
            }

            if (c == ']' and in_class) {
                in_class = false;
                self.current += 1;
                continue;
            }

            if (c == '/' and !in_class) {
                self.current += 1; // consume closing /
                // flags: g, i, m, s, u, v, y, d 등
                self.scanRegExpFlags();
                return .regexp;
            }

            // 줄바꿈은 정규식 안에서 불허
            if (c == '\n' or c == '\r') {
                return .syntax_error;
            }

            self.current += 1;
        }

        // EOF까지 닫히지 않은 정규식
        return .syntax_error;
    }

    /// 정규식 플래그를 스캔한다 (/pattern/ 뒤의 문자들).
    fn scanRegExpFlags(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                self.current += 1;
            } else break;
        }
    }

    /// single-line comment를 스캔한다 (// ... \n).
    /// JSX pragma (@jsx, @jsxFrag, @jsxRuntime, @jsxImportSource)를 감지한다 (D026).
    fn scanSingleLineComment(self: *Scanner) void {
        self.current += 1; // skip second '/'

        const comment_start = self.current;

        // 줄 끝까지 스킵
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '\n' or c == '\r') break;
            // U+2028, U+2029
            if (c == 0xE2 and self.current + 2 < self.source.len and
                self.source[self.current + 1] == 0x80 and
                (self.source[self.current + 2] == 0xA8 or self.source[self.current + 2] == 0xA9))
            {
                break;
            }
            self.current += 1;
        }

        const comment_text = self.source[comment_start..self.current];
        self.checkPureComment(comment_text);
    }

    /// multi-line comment를 스캔한다 (/* ... */).
    /// @__PURE__ / @__NO_SIDE_EFFECTS__ 주석을 감지한다 (D025).
    /// @license / @preserve 주석도 감지한다 (D022, 추후 코드젠에서 활용).
    fn scanMultiLineComment(self: *Scanner) void {
        self.current += 1; // skip '*'

        const comment_start = self.current;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '*' and self.peekAt(1) == '/') {
                const comment_text = self.source[comment_start..self.current];
                self.current += 2; // skip */
                self.checkPureComment(comment_text);
                return;
            }
            // 줄바꿈 추적 (소스맵 정확성)
            if (c == '\n' or c == '\r') {
                _ = self.handleNewline();
                self.token.has_newline_before = true;
            } else {
                self.current += 1;
            }
        }
        // EOF까지 닫히지 않은 주석 — 에러지만 여기서는 조용히 종료
        // (에러 리포팅은 추후 에러 처리 PR에서)
    }

    /// 주석 내용에서 @__PURE__ / #__PURE__ / @__NO_SIDE_EFFECTS__ 어노테이션을 확인한다.
    fn checkPureComment(self: *Scanner, comment_text: []const u8) void {
        // 빠른 reject: '@' 또는 '#' 포함하지 않으면 스킵
        if (std.mem.indexOf(u8, comment_text, "@") == null and
            std.mem.indexOf(u8, comment_text, "#") == null) return;

        if (std.mem.indexOf(u8, comment_text, "@__PURE__") != null or
            std.mem.indexOf(u8, comment_text, "#__PURE__") != null or
            std.mem.indexOf(u8, comment_text, "@__NO_SIDE_EFFECTS__") != null)
        {
            self.token.has_pure_comment_before = true;
        }
    }

    fn scanPercent(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            return .percent_eq;
        }
        return .percent;
    }

    fn scanLAngle(self: *Scanner) Kind {
        if (self.peek() == '<') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .shift_left_eq;
            }
            return .shift_left;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .lt_eq;
        }
        return .l_angle;
    }

    fn scanRAngle(self: *Scanner) Kind {
        if (self.peek() == '>') {
            self.current += 1;
            if (self.peek() == '>') {
                self.current += 1;
                if (self.peek() == '=') {
                    self.current += 1;
                    return .shift_right3_eq;
                }
                return .shift_right3;
            }
            if (self.peek() == '=') {
                self.current += 1;
                return .shift_right_eq;
            }
            return .shift_right;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .gt_eq;
        }
        return .r_angle;
    }

    fn scanEquals(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .eq3;
            }
            return .eq2;
        }
        if (self.peek() == '>') {
            self.current += 1;
            return .arrow;
        }
        return .eq;
    }

    fn scanBang(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .neq2;
            }
            return .neq;
        }
        return .bang;
    }

    fn scanAmp(self: *Scanner) Kind {
        if (self.peek() == '&') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .amp2_eq;
            }
            return .amp2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .amp_eq;
        }
        return .amp;
    }

    fn scanPipe(self: *Scanner) Kind {
        if (self.peek() == '|') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .pipe2_eq;
            }
            return .pipe2;
        }
        if (self.peek() == '=') {
            self.current += 1;
            return .pipe_eq;
        }
        return .pipe;
    }

    fn scanCaret(self: *Scanner) Kind {
        if (self.peek() == '=') {
            self.current += 1;
            return .caret_eq;
        }
        return .caret;
    }

    fn scanQuestion(self: *Scanner) Kind {
        if (self.peek() == '?') {
            self.current += 1;
            if (self.peek() == '=') {
                self.current += 1;
                return .question2_eq;
            }
            return .question2;
        }
        if (self.peek() == '.') {
            // ?. 은 optional chaining이지만 ?.5 는 ternary + 숫자
            const next_byte = self.peekAt(1);
            if (next_byte < '0' or next_byte > '9') {
                self.current += 1;
                return .question_dot;
            }
        }
        return .question;
    }

    // ====================================================================
    // 리터럴 스캔 (placeholder — 추후 PR에서 세부 구현)
    // ====================================================================

    /// 숫자 리터럴을 스캔한다.
    /// 첫 번째 숫자 문자(c)는 이미 advance()로 소비된 상태.
    ///
    /// 처리하는 형식:
    /// - 10진수: 123, 1_000_000
    /// - 소수: 1.5, .5
    /// - 지수: 1e10, 1e+10, 1e-10
    /// - 16진수: 0xFF, 0XFF
    /// - 8진수: 0o77, 0O77
    /// - 2진수: 0b1010, 0B1010
    /// - BigInt: 123n, 0xFFn, 0o77n, 0b1010n
    /// - 숫자 구분자: 1_000, 0xFF_FF
    fn scanNumericLiteral(self: *Scanner, first_char: u8) Kind {
        // 0으로 시작하면 접두사 확인
        if (first_char == '0') {
            const prefix = self.peek();
            switch (prefix) {
                'x', 'X' => {
                    self.current += 1;
                    return self.scanHexLiteral();
                },
                'o', 'O' => {
                    self.current += 1;
                    return self.scanOctalLiteral();
                },
                'b', 'B' => {
                    self.current += 1;
                    return self.scanBinaryLiteral();
                },
                else => {},
            }
        }

        // 10진수 정수부 소비
        self.scanDecimalDigits();

        // 소수점
        if (self.peek() == '.') {
            // 1..toString() 같은 경우 방지: '..' 이면 소수점이 아님
            if (self.peekAt(1) != '.') {
                self.current += 1;
                self.scanDecimalDigits();
                return self.scanExponentPart(.float);
            }
        }

        // 지수
        return self.scanExponentPart(.decimal);
    }

    /// 소수점 이후를 스캔한다 (.5, .123e10 등).
    /// '.'은 이미 소비된 상태. ('.' 자체는 scanDot에서 감지)
    fn scanDecimalAfterDot(self: *Scanner) Kind {
        self.scanDecimalDigits();
        return self.scanExponentPart(.float);
    }

    /// 10진수 숫자 시퀀스를 소비한다 (separator '_' 포함).
    fn scanDecimalDigits(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '9') {
                self.current += 1;
            } else if (c == '_') {
                // numeric separator: 다음 문자가 숫자여야 유효
                // (유효성 검사는 추후 에러 리포팅에서)
                self.current += 1;
            } else {
                break;
            }
        }
    }

    /// 지수부(e/E)를 스캔하고, BigInt suffix(n)도 확인한다.
    /// base_kind: 지수가 없을 때의 기본 Kind (.decimal 또는 .float)
    fn scanExponentPart(self: *Scanner, base_kind: Kind) Kind {
        const c = self.peek();
        if (c == 'e' or c == 'E') {
            self.current += 1;
            const sign = self.peek();
            const is_negative = sign == '-';
            if (sign == '+' or sign == '-') {
                self.current += 1;
            }
            self.scanDecimalDigits();
            return if (is_negative) .negative_exponential else .positive_exponential;
        }

        // BigInt suffix 'n'
        if (c == 'n') {
            self.current += 1;
            return switch (base_kind) {
                .decimal => .decimal_bigint,
                // float에 n은 JS에서 invalid이지만 렉서는 파싱하고 파서에서 에러
                else => .decimal_bigint,
            };
        }

        return base_kind;
    }

    /// 16진수 리터럴을 스캔한다 (0x 이후).
    fn scanHexLiteral(self: *Scanner) Kind {
        self.scanHexDigits();
        if (self.peek() == 'n') {
            self.current += 1;
            return .hex_bigint;
        }
        return .hex;
    }

    /// 8진수 리터럴을 스캔한다 (0o 이후).
    fn scanOctalLiteral(self: *Scanner) Kind {
        self.scanOctalDigits();
        if (self.peek() == 'n') {
            self.current += 1;
            return .octal_bigint;
        }
        return .octal;
    }

    /// 2진수 리터럴을 스캔한다 (0b 이후).
    fn scanBinaryLiteral(self: *Scanner) Kind {
        self.scanBinaryDigits();
        if (self.peek() == 'n') {
            self.current += 1;
            return .binary_bigint;
        }
        return .binary;
    }

    fn scanHexDigits(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '_') {
                self.current += 1;
            } else break;
        }
    }

    fn scanOctalDigits(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if ((c >= '0' and c <= '7') or c == '_') {
                self.current += 1;
            } else break;
        }
    }

    fn scanBinaryDigits(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '0' or c == '1' or c == '_') {
                self.current += 1;
            } else break;
        }
    }

    /// 문자열 리터럴을 스캔한다 (opening quote는 이미 소비됨).
    ///
    /// 처리하는 이스케이프 시퀀스:
    /// - 단순: \n \r \t \\ \' \" \0
    /// - 16진수: \xHH
    /// - 유니코드: \uHHHH, \u{H...H}
    /// - 줄 연속: \ + 줄바꿈 (줄바꿈이 문자열에 포함되지 않음)
    ///
    /// 에러 감지:
    /// - 닫히지 않은 문자열 → syntax_error
    /// - 문자열 안 줄바꿈 (JS 스펙 위반) → syntax_error
    fn scanStringLiteral(self: *Scanner, quote: u8) Kind {
        while (!self.isAtEnd()) {
            const c = self.peek();

            if (c == quote) {
                self.current += 1; // consume closing quote
                return .string_literal;
            }

            // 이스케이프 시퀀스
            if (c == '\\') {
                self.current += 1; // consume '\'
                if (self.isAtEnd()) break; // '\' at EOF

                const escaped = self.peek();
                switch (escaped) {
                    // 단순 이스케이프: 1바이트 스킵
                    'n', 'r', 't', '\\', '\'', '"', '0', 'b', 'f', 'v' => {
                        self.current += 1;
                    },
                    // 16진수 이스케이프: \xHH
                    'x' => {
                        self.current += 1;
                        self.skipHexEscape(2);
                    },
                    // 유니코드 이스케이프: \uHHHH 또는 \u{H...H}
                    'u' => {
                        self.current += 1;
                        if (self.peek() == '{') {
                            // \u{H...H} — 가변 길이
                            self.current += 1;
                            while (!self.isAtEnd() and self.peek() != '}') {
                                self.current += 1;
                            }
                            if (!self.isAtEnd()) self.current += 1; // consume '}'
                        } else {
                            // \uHHHH — 고정 4자리
                            self.skipHexEscape(4);
                        }
                    },
                    // 줄 연속: \ 뒤에 줄바꿈이 오면 줄바꿈을 건너뜀
                    '\n' => {
                        _ = self.handleNewline();
                    },
                    '\r' => {
                        _ = self.handleNewline();
                    },
                    // 그 외: legacy octal (\1..\7) 또는 알 수 없는 이스케이프 → 1바이트 스킵
                    // (엄격한 에러 검사는 파서에서)
                    else => {
                        self.current += 1;
                    },
                }
                continue;
            }

            // 줄바꿈은 문자열 안에서 불허 (JS 스펙)
            if (c == '\n' or c == '\r') {
                // 에러: 닫히지 않은 문자열. 줄바꿈을 소비하지 않고 종료.
                return .syntax_error;
            }
            // U+2028, U+2029도 줄바꿈
            if (c == 0xE2 and self.current + 2 < self.source.len and
                self.source[self.current + 1] == 0x80 and
                (self.source[self.current + 2] == 0xA8 or self.source[self.current + 2] == 0xA9))
            {
                return .syntax_error;
            }

            // 일반 문자: UTF-8 바이트 스킵
            self.current += 1;
        }

        // EOF까지 닫히지 않은 문자열
        return .syntax_error;
    }

    /// hex 이스케이프의 지정된 자릿수만큼 스킵한다.
    fn skipHexEscape(self: *Scanner, count: u32) void {
        var i: u32 = 0;
        while (i < count and !self.isAtEnd()) : (i += 1) {
            const c = self.peek();
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                self.current += 1;
            } else break;
        }
    }

    /// 템플릿 리터럴을 스캔한다 (opening backtick은 이미 소비됨).
    ///
    /// 반환:
    /// - no_substitution_template: `string` (보간 없음)
    /// - template_head: `text${ (보간 시작)
    /// - syntax_error: 닫히지 않은 템플릿
    fn scanTemplateLiteral(self: *Scanner) Kind {
        return self.scanTemplateContent(.no_substitution_template, .template_head);
    }

    /// 템플릿 중간/끝을 스캔한다 (}에서 호출).
    ///
    /// 반환:
    /// - template_middle: }text${ (보간 계속)
    /// - template_tail: }text` (템플릿 끝)
    /// - syntax_error: 닫히지 않은 템플릿
    fn scanTemplateContinuation(self: *Scanner) Kind {
        // 스택에서 현재 템플릿 depth를 pop
        _ = self.template_depth_stack.pop();
        return self.scanTemplateContent(.template_tail, .template_middle);
    }

    /// 템플릿 내용을 스캔하는 공통 로직.
    /// backtick을 만나면 complete_kind, ${를 만나면 interpolation_kind를 반환.
    fn scanTemplateContent(self: *Scanner, complete_kind: Kind, interpolation_kind: Kind) Kind {
        while (!self.isAtEnd()) {
            const c = self.peek();

            if (c == '`') {
                self.current += 1;
                return complete_kind;
            }

            if (c == '$' and self.peekAt(1) == '{') {
                self.current += 2; // skip ${
                // 현재 brace depth를 스택에 push (나중에 }에서 매칭)
                self.template_depth_stack.append(self.brace_depth) catch {};
                self.brace_depth += 1;
                return interpolation_kind;
            }

            if (c == '\\') {
                self.current += 1; // skip '\'
                if (!self.isAtEnd()) {
                    // 줄바꿈 이스케이프 처리 (템플릿에서는 유효)
                    if (self.peek() == '\n' or self.peek() == '\r') {
                        _ = self.handleNewline();
                    } else {
                        self.current += 1; // skip escaped char
                    }
                }
                continue;
            }

            // 줄바꿈: 템플릿 리터럴에서는 허용됨 (일반 문자열과 다름)
            if (c == '\n' or c == '\r') {
                _ = self.handleNewline();
                self.token.has_newline_before = true;
                continue;
            }

            self.current += 1;
        }

        // EOF까지 닫히지 않은 템플릿
        return .syntax_error;
    }

    fn scanHashbang(self: *Scanner) void {
        // #! 이후 줄 끝까지 스킵
        self.current += 1; // skip '!'
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '\n' or c == '\r') break;
            self.current += 1;
        }
    }

    fn scanIdentifierTail(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isIdentifierContinue(c)) {
                self.current += 1;
            } else {
                break;
            }
        }
    }

    // ====================================================================
    // 문자 분류
    // ====================================================================

    /// ASCII 식별자 시작 문자인지. (추후 유니코드 PR에서 확장)
    fn isIdentifierStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '_' or c == '$';
    }

    /// ASCII 식별자 계속 문자인지. (추후 유니코드 PR에서 확장)
    fn isIdentifierContinue(c: u8) bool {
        return isIdentifierStart(c) or (c >= '0' and c <= '9');
    }
};

// ============================================================
// Tests
// ============================================================

test "Scanner: empty source" {
    var scanner = Scanner.init(std.testing.allocator, "");
    defer scanner.deinit();
    scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: BOM skip" {
    var scanner = Scanner.init(std.testing.allocator, "\xEF\xBB\xBF;");
    defer scanner.deinit();
    scanner.next();
    try std.testing.expectEqual(Kind.semicolon, scanner.token.kind);
    try std.testing.expectEqual(@as(u32, 3), scanner.token.span.start);
}

test "Scanner: single character tokens" {
    const source = "(){};,~@:";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .l_paren,   .r_paren, .l_curly, .r_curly,
        .semicolon, .comma,   .tilde,   .at,
        .colon,
    };
    for (expected) |kind| {
        scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
    scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: compound operators" {
    const source = "++ -- ** === !== => ... ?? ?. ??= &&= ||=";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .plus2,   .minus2,   .star2,     .eq3,          .neq2,
        .arrow,   .dot3,     .question2, .question_dot, .question2_eq,
        .amp2_eq, .pipe2_eq,
    };
    for (expected) |kind| {
        scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

test "Scanner: shift operators" {
    const source = "<< >> >>> <<= >>= >>>=";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .shift_left,    .shift_right,    .shift_right3,
        .shift_left_eq, .shift_right_eq, .shift_right3_eq,
    };
    for (expected) |kind| {
        scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

test "Scanner: identifiers and keywords" {
    const source = "const foo let bar";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("foo", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.kw_let, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("bar", scanner.tokenText());
}

test "Scanner: whitespace and newlines set has_newline_before" {
    const source = "a\nb";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expect(!scanner.token.has_newline_before);

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: CRLF counts as one newline" {
    const source = "a\r\nb";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // a
    scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
    try std.testing.expectEqual(@as(u32, 1), scanner.line);
}

test "Scanner: line offset table" {
    const source = "a\nb\nc";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체를 스캔하여 line offset 테이블 구축
    while (scanner.token.kind != .eof or scanner.start == 0) {
        scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    // line 0 → offset 0, line 1 → offset 2, line 2 → offset 4
    try std.testing.expectEqual(@as(u32, 0), scanner.line_offsets.items[0]);
    try std.testing.expectEqual(@as(u32, 2), scanner.line_offsets.items[1]);
    try std.testing.expectEqual(@as(u32, 4), scanner.line_offsets.items[2]);
}

test "Scanner: getLineColumn" {
    const source = "ab\ncde\nf";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체 스캔
    while (true) {
        scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    // 'a' = offset 0 → line 0, col 0
    const lc0 = scanner.getLineColumn(0);
    try std.testing.expectEqual(@as(u32, 0), lc0.line);
    try std.testing.expectEqual(@as(u32, 0), lc0.column);

    // 'c' = offset 3 → line 1, col 0
    const lc1 = scanner.getLineColumn(3);
    try std.testing.expectEqual(@as(u32, 1), lc1.line);
    try std.testing.expectEqual(@as(u32, 0), lc1.column);

    // 'f' = offset 7 → line 2, col 0
    const lc2 = scanner.getLineColumn(7);
    try std.testing.expectEqual(@as(u32, 2), lc2.line);
    try std.testing.expectEqual(@as(u32, 0), lc2.column);
}

test "Scanner: hashbang" {
    const source = "#!/usr/bin/env node\nconst x = 1;";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.hashbang_comment, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
}

test "Scanner: private identifier" {
    const source = "#name";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.private_identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("#name", scanner.tokenText());
}

test "Scanner: optional chaining vs ternary + number" {
    // ?. → optional chaining
    const source1 = "?.";
    var s1 = Scanner.init(std.testing.allocator, source1);
    defer s1.deinit();
    s1.next();
    try std.testing.expectEqual(Kind.question_dot, s1.token.kind);

    // ?.5 → question + .5 (ternary + number)
    const source2 = "?.5";
    var s2 = Scanner.init(std.testing.allocator, source2);
    defer s2.deinit();
    s2.next();
    try std.testing.expectEqual(Kind.question, s2.token.kind);
}

test "Scanner: string literal basic" {
    const source = "'hello' \"world\"";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: empty string literals" {
    const source = "'' \"\"";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("''", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"\"", scanner.tokenText());
}

test "Scanner: slash_eq operator" {
    const source = "/=";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.slash_eq, scanner.token.kind);
}

test "Scanner: CR alone as line terminator" {
    const source = "a\rb";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // a
    scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
    try std.testing.expectEqual(@as(u32, 1), scanner.line);
}

test "Scanner: whitespace only source" {
    const source = "   \t\t  \n  ";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: NBSP whitespace (U+00A0)" {
    // U+00A0 = C2 A0
    const source = "a\xC2\xA0b";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
}

test "Scanner: all assignment operators" {
    const source = "= += -= *= /= %= **= &= |= ^= <<= >>= >>>= &&= ||= ??=";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .eq,              .plus_eq,    .minus_eq,      .star_eq,
        .slash_eq,        .percent_eq, .star2_eq,      .amp_eq,
        .pipe_eq,         .caret_eq,   .shift_left_eq, .shift_right_eq,
        .shift_right3_eq, .amp2_eq,    .pipe2_eq,      .question2_eq,
    };
    for (expected) |kind| {
        scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

// ============================================================
// Comment tests
// ============================================================

test "Scanner: single-line comment is skipped" {
    const source = "a // comment\nb";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: multi-line comment is skipped" {
    const source = "a /* comment */ b";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
}

test "Scanner: multi-line comment with newline sets has_newline_before" {
    const source = "a /*\n*/ b";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // a
    scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: @__PURE__ comment sets flag" {
    const source = "/* @__PURE__ */ foo()";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("foo", scanner.tokenText());
    try std.testing.expect(scanner.token.has_pure_comment_before);
}

test "Scanner: #__PURE__ comment sets flag" {
    const source = "/* #__PURE__ */ bar()";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expect(scanner.token.has_pure_comment_before);
}

test "Scanner: @__NO_SIDE_EFFECTS__ comment sets flag" {
    const source = "/* @__NO_SIDE_EFFECTS__ */ function f() {}";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.kw_function, scanner.token.kind);
    try std.testing.expect(scanner.token.has_pure_comment_before);
}

test "Scanner: normal comment does not set pure flag" {
    const source = "/* normal comment */ x";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expect(!scanner.token.has_pure_comment_before);
}

test "Scanner: single-line comment at end of file" {
    const source = "a // comment";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: comment-only source" {
    const source = "// just a comment";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: slash after comment is not confused" {
    const source = "a /* */ / b";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

// ============================================================
// Numeric literal tests
// ============================================================

test "Scanner: decimal integer" {
    const source = "123 0 42";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("123", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("0", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
}

test "Scanner: hex literal" {
    const source = "0xFF 0X1A";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
    try std.testing.expectEqualStrings("0xFF", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
}

test "Scanner: octal literal" {
    const source = "0o77 0O10";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.octal, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.octal, scanner.token.kind);
}

test "Scanner: binary literal" {
    const source = "0b1010 0B11";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
}

test "Scanner: float literal" {
    const source = "1.5 0.1 .5";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings("1.5", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings(".5", scanner.tokenText());
}

test "Scanner: exponential literal" {
    const source = "1e10 1E10 1e+10 1e-10";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.negative_exponential, scanner.token.kind);
}

test "Scanner: bigint literal" {
    const source = "123n 0xFFn 0o77n 0b1010n";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.decimal_bigint, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.hex_bigint, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.octal_bigint, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.binary_bigint, scanner.token.kind);
}

test "Scanner: numeric separator" {
    const source = "1_000_000 0xFF_FF 0b1010_0001";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("1_000_000", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
}

test "Scanner: 1..toString is not float" {
    // 1..toString() → decimal(1) dot dot identifier(toString) ...
    const source = "1..toString";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("1", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.dot, scanner.token.kind);
    scanner.next();
    try std.testing.expectEqual(Kind.dot, scanner.token.kind);
}

test "Scanner: float with exponent" {
    const source = "1.5e10";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try std.testing.expectEqualStrings("1.5e10", scanner.tokenText());
}

// ============================================================
// String literal tests
// ============================================================

test "Scanner: string with escape sequences" {
    const source = "\"hello\\nworld\"";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", scanner.tokenText());
}

test "Scanner: string with hex escape" {
    const source = "'\\x41'";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with unicode escape \\uHHHH" {
    const source = "'\\u0041'";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with unicode escape \\u{}" {
    const source = "'\\u{1F600}'";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with escaped quote" {
    const source = "'it\\'s'";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with line continuation" {
    // '\' + newline = line continuation (valid)
    const source = "'hello\\\nworld'";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: unterminated string at EOF" {
    const source = "\"hello";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: newline inside string is error" {
    const source = "\"hello\nworld\"";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: string with backslash at EOF" {
    const source = "'test\\";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: consecutive strings" {
    const source = "'a' \"b\" 'c'";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("'a'", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"b\"", scanner.tokenText());
    scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

// ============================================================
// Template literal tests
// ============================================================

test "Scanner: no substitution template" {
    const source = "`hello world`";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
    try std.testing.expectEqualStrings("`hello world`", scanner.tokenText());
}

test "Scanner: template with interpolation" {
    // `hello ${name}!`
    const source = "`hello ${name}!`";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);
    try std.testing.expectEqualStrings("`hello ${", scanner.tokenText());

    scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("name", scanner.tokenText());

    scanner.next();
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
    try std.testing.expectEqualStrings("}!`", scanner.tokenText());
}

test "Scanner: template with multiple interpolations" {
    // `${a} + ${b} = ${c}`
    const source = "`${a} + ${b} = ${c}`";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    scanner.next(); // } + ${
    try std.testing.expectEqual(Kind.template_middle, scanner.token.kind);

    scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    scanner.next(); // } = ${
    try std.testing.expectEqual(Kind.template_middle, scanner.token.kind);

    scanner.next(); // c
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    scanner.next(); // }`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: nested template literals" {
    // `a${`b${c}d`}e`
    const source = "`a${`b${c}d`}e`";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // `a${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    scanner.next(); // `b${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    scanner.next(); // c
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    scanner.next(); // }d`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);

    scanner.next(); // }e`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: template with object literal inside" {
    // `${{a: 1}}`
    const source = "`${{a: 1}}`";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // `${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    scanner.next(); // {
    try std.testing.expectEqual(Kind.l_curly, scanner.token.kind);

    scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    scanner.next(); // :
    try std.testing.expectEqual(Kind.colon, scanner.token.kind);

    scanner.next(); // 1
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);

    scanner.next(); // }
    try std.testing.expectEqual(Kind.r_curly, scanner.token.kind);

    scanner.next(); // }`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: empty template" {
    const source = "``";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
}

test "Scanner: template with newline" {
    const source = "`line1\nline2`";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
}

test "Scanner: unterminated template" {
    const source = "`hello";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

// ============================================================
// RegExp literal tests
// ============================================================

test "Scanner: regex after =" {
    // = /pattern/gi → eq, regexp
    const source = "= /abc/gi";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // =
    try std.testing.expectEqual(Kind.eq, scanner.token.kind);
    scanner.next(); // /abc/gi
    try std.testing.expectEqual(Kind.regexp, scanner.token.kind);
    try std.testing.expectEqualStrings("/abc/gi", scanner.tokenText());
}

test "Scanner: regex after (" {
    const source = "(/test/)";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // (
    try std.testing.expectEqual(Kind.l_paren, scanner.token.kind);
    scanner.next(); // /test/
    try std.testing.expectEqual(Kind.regexp, scanner.token.kind);
}

test "Scanner: division after identifier" {
    // a / b → identifier, slash, identifier
    const source = "a / b";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

test "Scanner: division after number" {
    const source = "10 / 2";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // 10
    scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
}

test "Scanner: regex with character class" {
    // character class 안의 / 는 regex를 끝내지 않음
    const source = "= /[a/b]/";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // =
    scanner.next(); // /[a/b]/
    try std.testing.expectEqual(Kind.regexp, scanner.token.kind);
    try std.testing.expectEqualStrings("/[a/b]/", scanner.tokenText());
}

test "Scanner: regex with escape" {
    const source = "= /a\\/b/";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // =
    scanner.next(); // /a\/b/
    try std.testing.expectEqual(Kind.regexp, scanner.token.kind);
}

test "Scanner: regex after return keyword" {
    const source = "return /test/g";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // return
    try std.testing.expectEqual(Kind.kw_return, scanner.token.kind);
    scanner.next(); // /test/g
    try std.testing.expectEqual(Kind.regexp, scanner.token.kind);
}

test "Scanner: regex after comma" {
    const source = ", /re/";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    scanner.next(); // ,
    scanner.next(); // /re/
    try std.testing.expectEqual(Kind.regexp, scanner.token.kind);
}
