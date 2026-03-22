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
const unicode = @import("unicode.zig");
const regexp_mod = @import("../regexp/mod.zig");

const Token = token.Token;
const Kind = token.Kind;
const Span = token.Span;

/// 스캔 중 발견된 주석 하나를 나타낸다.
/// start/end는 소스 코드의 byte offset이며, 구분자(// 또는 /* */)를 포함한다.
pub const Comment = struct {
    /// 주석 시작 byte offset (첫 번째 `/` 위치)
    start: u32,
    /// 주석 끝 byte offset (single-line: 줄바꿈 직전, multi-line: `*/` 직후)
    end: u32,
    /// true이면 `/* ... */`, false이면 `// ...`
    is_multiline: bool,
    /// legal comment: @license, @preserve, 또는 /*! 로 시작 (D022)
    /// minify 모드에서도 보존해야 하는 주석
    is_legal: bool = false,
};

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
    /// 메모리 할당자. ArrayList 메서드 호출에 사용한다.
    allocator: std.mem.Allocator,

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

    /// JSX pragma (D026): 파일 상단 주석에서 감지.
    /// `@jsx h` → jsx_pragma = "h"
    jsx_pragma: ?[]const u8 = null,
    /// `@jsxFrag Fragment` → jsx_frag_pragma = "Fragment"
    jsx_frag_pragma: ?[]const u8 = null,
    /// `@jsxRuntime automatic` → jsx_runtime_pragma = "automatic"
    jsx_runtime_pragma: ?[]const u8 = null,
    /// `@jsxImportSource preact` → jsx_import_source_pragma = "preact"
    jsx_import_source_pragma: ?[]const u8 = null,

    /// 스캔 중 발견된 주석 리스트 (소스 순서).
    /// codegen에서 주석 보존에 사용한다.
    comments: std.ArrayList(Comment),

    /// 이스케이프 디코딩 버퍼 (decodeIdentifierEscapes에서 사용).
    /// Scanner 필드에 두어 dangling pointer 방지. 키워드 최대 길이(~12)+여유.
    decode_buf: [64]u8 = undefined,

    /// 소스를 UTF-8로 읽고 Scanner를 초기화한다.
    /// BOM이 있으면 스킵한다 (D019).
    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Scanner {
        // 4GB 이상의 소스는 u32 offset으로 표현 불가 (D015)
        std.debug.assert(source.len <= std.math.maxInt(u32));

        var line_offsets: std.ArrayList(u32) = .empty;
        // 첫 번째 줄의 시작 offset은 항상 0. 이 append가 실패하면 getLineColumn()이 동작 불가.
        try line_offsets.append(allocator, 0);

        var scanner = Scanner{
            .allocator = allocator,
            .source = source,
            .line_offsets = line_offsets,
            .template_depth_stack = .empty,
            .comments = .empty,
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
        self.line_offsets.deinit(self.allocator);
        self.template_depth_stack.deinit(self.allocator);
        self.comments.deinit(self.allocator);
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

    /// 현재 위치가 U+2028 (LS) 또는 U+2029 (PS)인지 확인한다.
    /// UTF-8: E2 80 A8 또는 E2 80 A9.
    fn isLineSeparator(self: *const Scanner) bool {
        return self.current + 2 < self.source.len and
            self.source[self.current] == 0xE2 and
            self.source[self.current + 1] == 0x80 and
            (self.source[self.current + 2] == 0xA8 or self.source[self.current + 2] == 0xA9);
    }

    /// 현재 바이트가 줄바꿈의 시작 바이트인지 (빠른 체크).
    fn isNewlineStart(c: u8) bool {
        return c == '\n' or c == '\r' or c == 0xE2;
    }

    /// 줄 offset 테이블에 새 줄을 기록한다.
    fn recordNewline(self: *Scanner) !void {
        self.line += 1;
        self.line_start = self.current;
        try self.line_offsets.append(self.allocator, self.current);
    }

    /// 줄바꿈 문자를 처리한다.
    /// \n, \r\n, \r, U+2028 (LS), U+2029 (PS) 전부 인식 (D019).
    /// 줄바꿈이면 true를 반환하고 current를 전진시킨다.
    fn handleNewline(self: *Scanner) !bool {
        const c = self.peek();
        if (c == '\n') {
            self.current += 1;
            try self.recordNewline();
            return true;
        }
        if (c == '\r') {
            self.current += 1;
            if (self.peek() == '\n') self.current += 1;
            try self.recordNewline();
            return true;
        }
        if (self.isLineSeparator()) {
            self.current += 3;
            try self.recordNewline();
            return true;
        }
        return false;
    }

    // ====================================================================
    // 공백 스킵
    // ====================================================================

    /// 공백 문자를 스킵한다.
    /// 줄바꿈을 만나면 has_newline_before를 true로 설정.
    fn skipWhitespace(self: *Scanner) !void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', 0x0B, 0x0C => {
                    // 일반 공백: space, tab, vertical tab, form feed
                    self.current += 1;
                },
                '\n', '\r' => {
                    // 줄바꿈
                    _ = try self.handleNewline();
                    self.token.has_newline_before = true;
                },
                0xE2 => {
                    // U+2028 (LS), U+2029 (PS) — 줄바꿈
                    if (try self.handleNewline()) {
                        self.token.has_newline_before = true;
                    } else if (self.current + 2 < self.source.len) {
                        // Unicode Space_Separator (USP): U+2000-U+200A, U+202F, U+205F
                        const b1 = self.source[self.current + 1];
                        const b2 = self.source[self.current + 2];
                        if (b1 == 0x80 and b2 >= 0x80 and b2 <= 0x8A) {
                            // U+2000-U+200A (EN QUAD, EM QUAD, EN SPACE, EM SPACE, etc.)
                            self.current += 3;
                        } else if (b1 == 0x80 and b2 == 0xAF) {
                            // U+202F (NARROW NO-BREAK SPACE)
                            self.current += 3;
                        } else if (b1 == 0x81 and b2 == 0x9F) {
                            // U+205F (MEDIUM MATHEMATICAL SPACE)
                            self.current += 3;
                        } else {
                            return;
                        }
                    } else {
                        return;
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
                0xE3 => {
                    // U+3000 (IDEOGRAPHIC SPACE) = E3 80 80
                    if (self.peekAt(1) == 0x80 and self.peekAt(2) == 0x80) {
                        self.current += 3;
                    } else {
                        return;
                    }
                },
                0xE1 => {
                    // U+1680 (OGHAM SPACE MARK) = E1 9A 80
                    if (self.peekAt(1) == 0x9A and self.peekAt(2) == 0x80) {
                        self.current += 3;
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
    pub fn next(self: *Scanner) !void {
        self.token.has_newline_before = false;
        self.token.has_pure_comment_before = false;
        self.token.has_no_side_effects_comment = false;
        self.token.has_escape = false;
        self.token.has_legacy_octal = false;

        // 주석을 만나면 스킵하고 다시 스캔해야 하므로 루프
        while (true) {
            // 공백 스킵 (줄바꿈 추적 포함)
            try self.skipWhitespace();

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
                        break :blk try self.scanTemplateContinuation();
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
                '/' => try self.scanSlash(),
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
                '\'', '"' => try self.scanStringLiteral(c),
                '`' => try self.scanTemplateLiteral(),

                '#' => blk: {
                    // hashbang (파일 시작) 또는 private identifier
                    if (self.start == 0 or (self.start == 3 and std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF"))) {
                        if (self.peek() == '!') {
                            self.scanHashbang();
                            break :blk .hashbang_comment;
                        }
                    }
                    // private identifier — # 뒤에 IdentifierStart가 있어야 함
                    // ECMAScript: PrivateName :: # IdentifierName
                    // IdentifierName :: IdentifierStart IdentifierName IdentifierPart
                    // ZWNJ (U+200C), ZWJ (U+200D) 는 IdentifierPart이지 IdentifierStart가 아님.
                    // 따라서 #\u200C_X 같은 형태는 SyntaxError.
                    const before_start = self.current;
                    if (!self.scanPrivateIdentifierStart()) {
                        // # 뒤에 유효한 IdentifierStart 없음 → syntax error
                        break :blk .syntax_error;
                    }
                    // IdentifierStart가 확인되었으면 나머지 IdentifierPart를 스캔
                    if (self.current != before_start) {
                        self.scanIdentifierTail();
                    }
                    break :blk .private_identifier;
                },

                else => blk: {
                    // ASCII 식별자 시작
                    if (isAsciiIdentStart(c)) {
                        self.scanIdentifierTail();
                        const text = self.tokenText();
                        // escape가 포함되어 있으면 디코딩 후 키워드 매칭
                        if (std.mem.indexOfScalar(u8, text, '\\') != null) {
                            self.token.has_escape = true;
                            const decoded = self.decodeIdentifierEscapes(text);
                            if (decoded) |name| {
                                if (token.keywords.get(name)) |kw| {
                                    // reserved keyword/literal → escaped_keyword (항상 식별자 사용 불가)
                                    // strict mode reserved (let, yield, implements 등) → escaped_strict_reserved
                                    // contextual keyword (async, from 등) → identifier
                                    break :blk if (kw.isReservedKeyword() or kw.isLiteralKeyword())
                                        .escaped_keyword
                                    else if (kw.isStrictModeReserved() or kw == .kw_let or kw == .kw_yield)
                                        .escaped_strict_reserved
                                    else
                                        .identifier;
                                }
                            }
                            break :blk .identifier;
                        }
                        break :blk token.keywords.get(text) orelse .identifier;
                    }
                    // \u 유니코드 이스케이프로 시작하는 식별자
                    if (c == '\\') {
                        self.token.has_escape = true;
                        // advance()에서 이미 \ 를 소비했으므로 current-1 부터
                        self.current -= 1; // put back '\'
                        const esc_start = self.current;
                        if (self.scanIdentifierEscape()) {
                            // 식별자 시작: 디코딩된 코드포인트가 ID_Start인지 검증
                            const esc_text = self.source[esc_start..self.current];
                            const start_cp = self.decodeEscapeCodepoint(esc_text);
                            if (start_cp) |cp| {
                                if (cp < 0x80) {
                                    if (!isAsciiIdentStart(@intCast(cp))) {
                                        self.current = esc_start + 1;
                                        break :blk .syntax_error;
                                    }
                                } else if (cp <= 0x10FFFF) {
                                    if (!unicode.isIdentifierStart(@intCast(cp))) {
                                        self.current = esc_start + 1;
                                        break :blk .syntax_error;
                                    }
                                }
                            } else {
                                // 디코딩 실패 (예: \u{00_76}) → 유효하지 않은 이스케이프
                                self.current = esc_start + 1;
                                break :blk .syntax_error;
                            }
                            self.scanIdentifierTail();
                            // 이스케이프를 디코딩하여 키워드인지 판별.
                            // 키워드면 escaped_keyword (식별자로 사용 불가),
                            // 아니면 일반 identifier.
                            const raw = self.tokenText();
                            const decoded = self.decodeIdentifierEscapes(raw);
                            if (decoded) |name| {
                                if (token.keywords.get(name)) |kw| {
                                    break :blk if (kw.isReservedKeyword() or kw.isLiteralKeyword())
                                        .escaped_keyword
                                    else if (kw.isStrictModeReserved() or kw == .kw_let or kw == .kw_yield)
                                        .escaped_strict_reserved
                                    else
                                        .identifier;
                                }
                            }
                            break :blk .identifier;
                        }
                        self.current += 1; // re-consume '\'
                        break :blk .syntax_error;
                    }
                    // Non-ASCII 유니코드 식별자
                    if (c >= 0x80) {
                        // advance()에서 1바이트 소비했으므로 나머지 UTF-8 바이트 소비
                        const start_pos = self.current - 1;
                        const remaining = self.source[start_pos..];
                        const decoded = unicode.decodeUtf8(remaining);
                        if (unicode.isIdentifierStart(decoded.codepoint)) {
                            self.current = @intCast(start_pos + decoded.len);
                            self.scanIdentifierTail();
                            const text = self.tokenText();
                            break :blk token.keywords.get(text) orelse .identifier;
                        }
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
    // JSX 모드 스캔 (파서가 JSX 컨텍스트에서 호출)
    /// 현재 `/` 또는 `/=` 토큰을 regexp literal로 재스캔한다.
    /// 파서가 `yield` 뒤 등 regexp context에서 호출한다.
    pub fn rescanAsRegexp(self: *Scanner) void {
        // 현재 토큰의 시작 위치로 되돌린다 (/ 또는 /= 의 시작)
        self.current = self.start + 1; // opening / 직후
        self.token.kind = self.scanRegExp();
        self.token.span = .{ .start = self.start, .end = self.current };
        self.prev_token_kind = self.token.kind;
    }

    // ====================================================================

    /// JSX 태그 내부의 다음 토큰을 스캔한다.
    /// JSX 태그 안에서는 식별자에 하이픈(-)을 허용하고 (data-value),
    /// 속성 값 문자열은 이스케이프를 처리하지 않는다.
    /// 파서가 `<` 뒤에서 이 함수를 호출한다.
    pub fn nextInsideJSXElement(self: *Scanner) !void {
        self.token.has_newline_before = false;
        try self.skipWhitespace();
        self.start = self.current;

        if (self.isAtEnd()) {
            self.token.kind = .eof;
            self.token.span = .{ .start = self.start, .end = self.current };
            return;
        }

        const c = self.advance();
        self.token.kind = switch (c) {
            '>' => .r_angle,
            '/' => .slash,
            '=' => .eq,
            '{' => blk: {
                self.brace_depth += 1;
                break :blk .l_curly;
            },
            '\'', '"' => self.scanJSXStringLiteral(c),
            '.' => .dot,
            ':' => .colon,
            else => blk: {
                // JSX 식별자: 하이픈 허용 (data-value, aria-label)
                if (isAsciiIdentStart(c) or c >= 0x80) {
                    self.scanJSXIdentifierTail();
                    break :blk .jsx_identifier;
                }
                break :blk .syntax_error;
            },
        };

        self.token.span = .{ .start = self.start, .end = self.current };
        self.prev_token_kind = self.token.kind;
    }

    /// JSX 자식 위치에서 다음 토큰을 스캔한다 (태그 사이의 텍스트).
    /// `<` 또는 `{`를 만날 때까지 텍스트를 소비한다.
    pub fn nextJSXChild(self: *Scanner) !void {
        self.token.has_newline_before = false;
        self.start = self.current;

        if (self.isAtEnd()) {
            self.token.kind = .eof;
            self.token.span = .{ .start = self.start, .end = self.current };
            return;
        }

        const c = self.peek();
        if (c == '<') {
            self.current += 1;
            self.token.kind = .l_angle;
        } else if (c == '{') {
            self.current += 1;
            self.brace_depth += 1;
            self.token.kind = .l_curly;
        } else {
            // JSX 텍스트: < 또는 { 또는 EOF 전까지 전부 소비
            try self.scanJSXText();
            self.token.kind = .jsx_text;
        }

        self.token.span = .{ .start = self.start, .end = self.current };
        self.prev_token_kind = self.token.kind;
    }

    /// JSX 텍스트를 스캔한다. `<`, `{`, `}` 전까지 소비.
    fn scanJSXText(self: *Scanner) !void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '<' or c == '{' or c == '}') break;
            if (isNewlineStart(c)) {
                if (try self.handleNewline()) {
                    self.token.has_newline_before = true;
                } else {
                    self.current += 1; // 0xE2이지만 줄바꿈이 아닌 경우
                }
            } else {
                self.current += 1;
            }
        }
    }

    /// JSX 식별자의 나머지를 스캔한다.
    /// 일반 식별자와 달리 하이픈(-)을 허용한다 (data-value, aria-label).
    fn scanJSXIdentifierTail(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (isAsciiIdentContinue(c) or c == '-') {
                self.current += 1;
            } else if (c >= 0x80) {
                const remaining = self.source[self.current..];
                const decoded = unicode.decodeUtf8(remaining);
                if (decoded.len == 0) break;
                if (unicode.isIdentifierContinue(decoded.codepoint)) {
                    self.current += decoded.len;
                } else break;
            } else break;
        }
    }

    /// JSX 속성 문자열을 스캔한다.
    /// JS 문자열과 달리 이스케이프 시퀀스를 처리하지 않는다 (\ 는 리터럴).
    fn scanJSXStringLiteral(self: *Scanner, quote: u8) Kind {
        while (!self.isAtEnd()) {
            if (self.peek() == quote) {
                self.current += 1;
                return .string_literal;
            }
            self.current += 1;
        }
        return .syntax_error;
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

    fn scanSlash(self: *Scanner) !Kind {
        const next_char = self.peek();
        if (next_char == '/') {
            try self.scanSingleLineComment();
            return .undetermined;
        }
        if (next_char == '*') {
            if (try self.scanMultiLineComment()) return .syntax_error; // 미닫힌 주석
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
        const pattern_start = self.current; // pattern 시작 위치 (opening / 직후)

        while (!self.isAtEnd()) {
            const c = self.peek();

            if (c == '\\') {
                // 이스케이프: 다음 문자가 줄바꿈이면 에러 (ECMAScript 12.9.5)
                // RegularExpressionBackslashSequence :: \ RegularExpressionNonTerminator
                // RegularExpressionNonTerminator :: SourceCharacter but not LineTerminator
                self.current += 1;
                if (!self.isAtEnd()) {
                    const next_ch = self.peek();
                    if (next_ch == '\n' or next_ch == '\r' or self.isLineSeparator()) {
                        return .syntax_error;
                    }
                    self.current += 1;
                }
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
                const pattern_end = self.current;
                self.current += 1; // consume closing /
                // flags 스캔 + 검증
                const flags_start = self.current;
                self.scanRegExpFlags();
                const flags_text = self.source[flags_start..self.current];
                // flags + pattern 검증
                const pattern_text = self.source[pattern_start..pattern_end];
                if (regexp_mod.validate(pattern_text, flags_text) != null) {
                    return .syntax_error;
                }
                return .regexp_literal;
            }

            // 줄바꿈은 정규식 안에서 불허 (U+2028/U+2029 포함)
            if (c == '\n' or c == '\r' or self.isLineSeparator()) {
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
    fn scanSingleLineComment(self: *Scanner) !void {
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

        // 주석을 기록한다 (start = 첫 번째 '/' 위치, end = 줄바꿈 직전)
        try self.comments.append(self.allocator, .{
            .start = self.start,
            .end = self.current,
            .is_multiline = false,
            .is_legal = isLegalComment(comment_text, false),
        });
    }

    /// multi-line comment를 스캔한다 (/* ... */).
    /// @__PURE__ / @__NO_SIDE_EFFECTS__ 주석을 감지한다 (D025).
    /// @license / @preserve 주석도 감지한다 (D022, 추후 코드젠에서 활용).
    /// 미닫힌 주석이면 true(에러)를 반환.
    fn scanMultiLineComment(self: *Scanner) !bool {
        self.current += 1; // skip '*'

        const comment_start = self.current;

        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '*' and self.peekAt(1) == '/') {
                const comment_text = self.source[comment_start..self.current];
                self.current += 2; // skip */
                self.checkPureComment(comment_text);

                // 주석을 기록한다 (start = 첫 번째 '/' 위치, end = '*/' 직후)
                try self.comments.append(self.allocator, .{
                    .start = self.start,
                    .end = self.current,
                    .is_multiline = true,
                    .is_legal = isLegalComment(comment_text, true),
                });

                return false; // 정상 종료
            }
            // 줄바꿈 추적 (소스맵 정확성)
            if (isNewlineStart(c)) {
                if (try self.handleNewline()) {
                    self.token.has_newline_before = true;
                } else {
                    self.current += 1;
                }
            } else {
                self.current += 1;
            }
        }
        // EOF까지 닫히지 않은 주석
        return true;
    }

    /// legal comment 감지 (D022): @license, @preserve, /*! (multi-line only)
    fn isLegalComment(comment_text: []const u8, is_multiline: bool) bool {
        if (is_multiline and comment_text.len > 0 and comment_text[0] == '!') return true;
        return std.mem.indexOf(u8, comment_text, "@license") != null or
            std.mem.indexOf(u8, comment_text, "@preserve") != null;
    }

    /// 주석 내용에서 @__PURE__ / #__PURE__ / @__NO_SIDE_EFFECTS__ 어노테이션을 확인한다.
    fn checkPureComment(self: *Scanner, comment_text: []const u8) void {
        // 빠른 reject: '@' 또는 '#' 포함하지 않으면 스킵
        if (std.mem.indexOf(u8, comment_text, "@") == null and
            std.mem.indexOf(u8, comment_text, "#") == null) return;

        if (std.mem.indexOf(u8, comment_text, "@__PURE__") != null or
            std.mem.indexOf(u8, comment_text, "#__PURE__") != null)
        {
            self.token.has_pure_comment_before = true;
        }

        if (std.mem.indexOf(u8, comment_text, "@__NO_SIDE_EFFECTS__") != null or
            std.mem.indexOf(u8, comment_text, "#__NO_SIDE_EFFECTS__") != null)
        {
            self.token.has_no_side_effects_comment = true;
        }

        // JSX pragma 감지 (D026)
        self.checkJSXPragma(comment_text);
    }

    /// 주석에서 JSX pragma 디렉티브를 감지한다 (D026).
    /// `@jsx`, `@jsxFrag`, `@jsxRuntime`, `@jsxImportSource` 뒤의 값을 추출.
    fn checkJSXPragma(self: *Scanner, comment_text: []const u8) void {
        // @jsxImportSource 먼저 (더 긴 접두사를 먼저 체크)
        if (extractPragmaValue(comment_text, "@jsxImportSource")) |val| {
            self.jsx_import_source_pragma = val;
        }
        if (extractPragmaValue(comment_text, "@jsxRuntime")) |val| {
            self.jsx_runtime_pragma = val;
        }
        if (extractPragmaValue(comment_text, "@jsxFrag")) |val| {
            self.jsx_frag_pragma = val;
        }
        // @jsx는 @jsxFrag 등과 겹치지 않도록 마지막에 체크
        if (extractPragmaValue(comment_text, "@jsx")) |val| {
            // @jsxFrag, @jsxRuntime, @jsxImportSource가 아닌 경우만
            if (!std.mem.startsWith(u8, val, "Frag") and
                !std.mem.startsWith(u8, val, "Runtime") and
                !std.mem.startsWith(u8, val, "ImportSource"))
            {
                self.jsx_pragma = val;
            }
        }
    }

    /// 주석 텍스트에서 `@directive value` 형태의 값을 추출한다.
    /// 공백으로 구분된 첫 번째 단어를 반환.
    fn extractPragmaValue(comment_text: []const u8, directive: []const u8) ?[]const u8 {
        const idx = std.mem.indexOf(u8, comment_text, directive) orelse return null;
        const after = comment_text[idx + directive.len ..];

        // directive 바로 뒤에 공백이 있어야 함
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) return null;

        // 공백 스킵
        var start: usize = 0;
        while (start < after.len and (after[start] == ' ' or after[start] == '\t')) {
            start += 1;
        }
        if (start >= after.len) return null;

        // 값 끝 찾기 (공백, *, / 에서 멈춤)
        var end = start;
        while (end < after.len and after[end] != ' ' and after[end] != '\t' and
            after[end] != '*' and after[end] != '/' and after[end] != '\n' and after[end] != '\r')
        {
            end += 1;
        }

        if (end == start) return null;
        return after[start..end];
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
                    return self.checkNumericEnd(self.scanHexLiteral());
                },
                'o', 'O' => {
                    self.current += 1;
                    return self.checkNumericEnd(self.scanOctalLiteral());
                },
                'b', 'B' => {
                    self.current += 1;
                    return self.checkNumericEnd(self.scanBinaryLiteral());
                },
                // 0_ → numeric separator in leading zero literal is invalid
                '_' => return .syntax_error,
                // 0 뒤에 숫자가 오면 legacy octal (00, 07) 또는 non-octal decimal (08, 09)
                // 둘 다 strict mode에서 금지 (ECMAScript 12.8.3.1)
                // Numeric separator(_)는 legacy octal/non-octal decimal에서 금지 (ECMAScript 12.8.3)
                '0'...'9' => {
                    self.token.has_legacy_octal = true;
                    // Legacy octal/non-octal decimal에서는 separator 없이 숫자만 소비
                    if (self.scanLegacyOctalDigits()) return .syntax_error;
                    // 소수점 (legacy octal 뒤에도 소수점 가능: 010.5 → 10.5)
                    if (self.peek() == '.') {
                        if (!(self.peekAt(1) == '.' and self.peekAt(2) == '.')) {
                            self.current += 1;
                            if (self.scanDecimalDigits()) return .syntax_error;
                            return self.checkNumericEnd(self.scanExponentPart(.float));
                        }
                    }
                    return self.checkNumericEnd(self.scanExponentPart(.decimal));
                },
                else => {},
            }
        }

        // 10진수 정수부 소비 (first_char가 이미 숫자 하나를 제공)
        if (self.scanDecimalDigitsEx(true)) return .syntax_error;

        // 소수점
        if (self.peek() == '.') {
            // 1..toString()에서 첫 번째 '.'은 소수점, 두 번째 '.'은 멤버 접근.
            // '...'(spread)이면 소수점이 아님.
            if (self.peekAt(1) == '.' and self.peekAt(2) == '.') {
                // 1... → 1 다음에 spread operator → 소수점 아님
            } else {
                self.current += 1;
                if (self.scanDecimalDigits()) return .syntax_error;
                return self.checkNumericEnd(self.scanExponentPart(.float));
            }
        }

        // 지수
        return self.checkNumericEnd(self.scanExponentPart(.decimal));
    }

    /// 소수점 이후를 스캔한다 (.5, .123e10 등).
    /// '.'은 이미 소비된 상태. ('.' 자체는 scanDot에서 감지)
    fn scanDecimalAfterDot(self: *Scanner) Kind {
        if (self.scanDecimalDigits()) return .syntax_error;
        return self.checkNumericEnd(self.scanExponentPart(.float));
    }

    /// scanDecimalDigitsEx의 wrapper. 선행 숫자 없음.
    fn scanDecimalDigits(self: *Scanner) bool {
        return self.scanDecimalDigitsEx(false);
    }

    /// 10진수 숫자 시퀀스를 소비한다 (separator '_' 포함).
    /// 숫자가 하나도 없거나 separator가 잘못된 위치면 true를 반환 (에러).
    /// has_preceding_digit: 호출 전에 이미 숫자가 소비되었으면 true.
    fn scanDecimalDigitsEx(self: *Scanner, has_preceding_digit: bool) bool {
        var has_digits = has_preceding_digit;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '9') {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) {
                    // 선행 _ 또는 연속 __ → 에러
                    return true;
                }
                self.current += 1;
                prev_was_separator = true;
            } else {
                break;
            }
        }
        // 후행 _ → 에러
        if (prev_was_separator) return true;
        return false;
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
            if (self.scanDecimalDigits()) return .syntax_error;
            // 지수 뒤에 BigInt suffix 'n'이 오면 에러 (0e0n, 1e1n 등)
            // ECMAScript 스펙: BigInt는 지수 표기를 허용하지 않음
            if (self.peek() == 'n') {
                self.current += 1;
                return .syntax_error;
            }
            return if (is_negative) .negative_exponential else .positive_exponential;
        }

        // BigInt suffix 'n'
        if (c == 'n') {
            // float에 BigInt suffix는 에러 (.0001n, 2017.8n 등)
            // ECMAScript 스펙: BigInt의 MV는 정수여야 함
            if (base_kind == .float) {
                self.current += 1;
                return .syntax_error;
            }
            // legacy octal / non-octal decimal에 BigInt suffix는 에러 (00n, 01n, 08n 등)
            // ECMAScript 스펙: DecimalBigIntegerLiteral은 0n 또는 NonZeroDigit... 만 허용
            if (self.token.has_legacy_octal) {
                self.current += 1;
                return .syntax_error;
            }
            self.current += 1;
            return .decimal_bigint;
        }

        return self.checkNumericEnd(base_kind);
    }

    /// 숫자 리터럴 직후에 IdentifierStart 문자가 오는지 확인한다.
    /// ECMAScript 명세: "The source character immediately following a NumericLiteral
    /// must not be an IdentifierStart or DecimalDigit." (12.8.3)
    /// 예: `3in []`, `0\u006f0`, `1\u005F0` 등은 SyntaxError.
    fn checkNumericEnd(self: *Scanner, kind: Kind) Kind {
        if (kind == .syntax_error) return kind;
        if (self.isAtEnd()) return kind;
        const c = self.peek();
        // ASCII IdentifierStart: a-z, A-Z, _, $
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$') {
            return .syntax_error;
        }
        // Unicode escape (\uXXXX) — IdentifierStart를 unicode escape로 표현한 경우도 에러
        if (c == '\\') {
            return .syntax_error;
        }
        // Non-ASCII UTF-8 시작 바이트 — unicode IdentifierStart일 수 있음
        if (c >= 0x80) {
            const decoded = unicode.decodeUtf8(self.source[self.current..]);
            if (decoded.len > 0 and unicode.isIdentifierStart(decoded.codepoint)) {
                return .syntax_error;
            }
        }
        return kind;
    }

    /// Legacy octal/non-octal decimal 숫자 시퀀스를 소비한다.
    /// 00, 01, 07 (legacy octal) 또는 08, 09 (non-octal decimal) 이후의 숫자만 소비.
    /// Numeric separator '_'는 금지 — 만나면 true(에러)를 반환.
    /// 소수점과 지수는 호출자(scanNumericLiteral)에서 처리.
    fn scanLegacyOctalDigits(self: *Scanner) bool {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '9') {
                self.current += 1;
            } else if (c == '_') {
                // Legacy octal/non-octal decimal에서 separator는 금지
                return true;
            } else {
                break;
            }
        }
        return false;
    }

    /// 16진수 리터럴을 스캔한다 (0x 이후).
    fn scanHexLiteral(self: *Scanner) Kind {
        if (self.scanHexDigits()) return .syntax_error;
        if (self.peek() == 'n') {
            self.current += 1;
            return self.checkNumericEnd(.hex_bigint);
        }
        return self.checkNumericEnd(.hex);
    }

    /// 8진수 리터럴을 스캔한다 (0o 이후).
    fn scanOctalLiteral(self: *Scanner) Kind {
        if (self.scanOctalDigits()) return .syntax_error;
        if (self.peek() == 'n') {
            self.current += 1;
            return self.checkNumericEnd(.octal_bigint);
        }
        return self.checkNumericEnd(.octal);
    }

    /// 2진수 리터럴을 스캔한다 (0b 이후).
    fn scanBinaryLiteral(self: *Scanner) Kind {
        if (self.scanBinaryDigits()) return .syntax_error;
        if (self.peek() == 'n') {
            self.current += 1;
            return self.checkNumericEnd(.binary_bigint);
        }
        return self.checkNumericEnd(.binary);
    }

    /// 16진수 숫자를 스캔. 숫자가 없거나 separator 오류면 true 반환.
    fn scanHexDigits(self: *Scanner) bool {
        var has_digits = false;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) return true;
                self.current += 1;
                prev_was_separator = true;
            } else break;
        }
        if (prev_was_separator) return true;
        return !has_digits; // 숫자가 없으면 에러 (0x; → error)
    }

    /// 8진수 숫자를 스캔. 숫자가 없거나 separator 오류면 true 반환.
    fn scanOctalDigits(self: *Scanner) bool {
        var has_digits = false;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '7') {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) return true;
                self.current += 1;
                prev_was_separator = true;
            } else break;
        }
        if (prev_was_separator) return true;
        return !has_digits;
    }

    /// 2진수 숫자를 스캔. 숫자가 없거나 separator 오류면 true 반환.
    fn scanBinaryDigits(self: *Scanner) bool {
        var has_digits = false;
        var prev_was_separator = false;
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == '0' or c == '1') {
                self.current += 1;
                has_digits = true;
                prev_was_separator = false;
            } else if (c == '_') {
                if (!has_digits or prev_was_separator) return true;
                self.current += 1;
                prev_was_separator = true;
            } else break;
        }
        if (prev_was_separator) return true;
        return !has_digits;
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
    fn scanStringLiteral(self: *Scanner, quote: u8) !Kind {
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
                    'n', 'r', 't', '\\', '\'', '"', 'b', 'f', 'v' => {
                        self.current += 1;
                    },
                    // \0: 뒤에 숫자가 없으면 NUL, 있으면 legacy octal
                    '0' => {
                        self.current += 1;
                        if (!self.isAtEnd() and self.peek() >= '0' and self.peek() <= '9') {
                            self.token.has_legacy_octal = true;
                        }
                    },
                    // \1..\9: legacy octal escape (strict mode에서 금지)
                    '1'...'9' => {
                        self.token.has_legacy_octal = true;
                        self.current += 1;
                    },
                    // 16진수 이스케이프: \xHH
                    'x' => {
                        self.current += 1;
                        if (self.skipHexEscape(2)) return .syntax_error;
                    },
                    // 유니코드 이스케이프: \uHHHH 또는 \u{H...H}
                    'u' => {
                        self.current += 1;
                        if (self.peek() == '{') {
                            // \u{H...H} — 가변 길이, 각 문자가 hex digit이어야 함
                            self.current += 1;
                            var has_hex = false;
                            while (!self.isAtEnd() and self.peek() != '}') {
                                const hc = self.peek();
                                if ((hc >= '0' and hc <= '9') or (hc >= 'a' and hc <= 'f') or (hc >= 'A' and hc <= 'F')) {
                                    has_hex = true;
                                    self.current += 1;
                                } else {
                                    return .syntax_error; // non-hex (예: '_' numeric separator)
                                }
                            }
                            if (!has_hex) return .syntax_error;
                            if (!self.isAtEnd()) self.current += 1; // consume '}'
                        } else {
                            // \uHHHH — 고정 4자리
                            if (self.skipHexEscape(4)) return .syntax_error;
                        }
                    },
                    // 줄 연속: \ 뒤에 줄바꿈이 오면 줄바꿈을 건너뜀
                    '\n' => {
                        _ = try self.handleNewline();
                    },
                    '\r' => {
                        _ = try self.handleNewline();
                    },
                    // 그 외: legacy octal (\1..\7) 또는 알 수 없는 이스케이프 → 1바이트 스킵
                    // (엄격한 에러 검사는 파서에서)
                    else => {
                        self.current += 1;
                    },
                }
                continue;
            }

            // \n, \r은 문자열 안에서 불허 (줄바꿈 = 미닫힌 문자열)
            // 단, U+2028/U+2029는 ES2019부터 문자열 안에서 허용
            if (c == '\n' or c == '\r') {
                return .syntax_error;
            }

            // 일반 문자: UTF-8 바이트 스킵
            self.current += 1;
        }

        // EOF까지 닫히지 않은 문자열
        return .syntax_error;
    }

    /// hex 이스케이프의 지정된 자릿수만큼 스킵한다.
    /// hex escape를 스킵한다. count자리를 소비. 부족하면 true (에러).
    fn skipHexEscape(self: *Scanner, count: u32) bool {
        var i: u32 = 0;
        while (i < count and !self.isAtEnd()) : (i += 1) {
            const c = self.peek();
            if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
                self.current += 1;
            } else return true; // 에러: non-hex character
        }
        return i < count; // 에러: 자릿수 부족 (EOF)
    }

    /// 템플릿 리터럴을 스캔한다 (opening backtick은 이미 소비됨).
    ///
    /// 반환:
    /// - no_substitution_template: `string` (보간 없음)
    /// - template_head: `text${ (보간 시작)
    /// - syntax_error: 닫히지 않은 템플릿
    fn scanTemplateLiteral(self: *Scanner) !Kind {
        return try self.scanTemplateContent(.no_substitution_template, .template_head);
    }

    /// 템플릿 중간/끝을 스캔한다 (}에서 호출).
    ///
    /// 반환:
    /// - template_middle: }text${ (보간 계속)
    /// - template_tail: }text` (템플릿 끝)
    /// - syntax_error: 닫히지 않은 템플릿
    fn scanTemplateContinuation(self: *Scanner) !Kind {
        // 스택에서 현재 템플릿 depth를 pop
        _ = self.template_depth_stack.pop();
        return try self.scanTemplateContent(.template_tail, .template_middle);
    }

    /// 템플릿 내용을 스캔하는 공통 로직.
    /// backtick을 만나면 complete_kind, ${를 만나면 interpolation_kind를 반환.
    fn scanTemplateContent(self: *Scanner, complete_kind: Kind, interpolation_kind: Kind) !Kind {
        while (!self.isAtEnd()) {
            const c = self.peek();

            if (c == '`') {
                self.current += 1;
                return complete_kind;
            }

            if (c == '$' and self.peekAt(1) == '{') {
                self.current += 2; // skip ${
                // 현재 brace depth를 스택에 push (나중에 }에서 매칭)
                try self.template_depth_stack.append(self.allocator, self.brace_depth);
                self.brace_depth += 1;
                return interpolation_kind;
            }

            if (c == '\\') {
                self.current += 1; // skip '\'
                if (!self.isAtEnd()) {
                    const escaped = self.peek();
                    switch (escaped) {
                        // 단순 이스케이프: 1바이트 스킵
                        'n', 'r', 't', '\\', '\'', '"', 'b', 'f', 'v', '`', '$' => {
                            self.current += 1;
                        },
                        // \0 — 뒤에 숫자가 오면 legacy octal → invalid
                        '0' => {
                            self.current += 1;
                            if (!self.isAtEnd() and self.peek() >= '0' and self.peek() <= '9') {
                                self.token.has_invalid_escape = true;
                                self.current += 1;
                            }
                        },
                        // legacy octal \1..\9 → template에서는 항상 invalid
                        '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                            self.token.has_invalid_escape = true;
                            self.current += 1;
                        },
                        // 16진수 이스케이프: \xHH
                        'x' => {
                            self.current += 1;
                            if (self.skipHexEscape(2)) {
                                self.token.has_invalid_escape = true;
                            }
                        },
                        // 유니코드 이스케이프: \uHHHH 또는 \u{H...H}
                        'u' => {
                            self.current += 1;
                            if (!self.isAtEnd() and self.peek() == '{') {
                                // \u{H...H} — 가변 길이, 닫는 }가 있어야 유효, 값 ≤ 0x10FFFF
                                self.current += 1;
                                var has_hex = false;
                                var code_point: u32 = 0;
                                var overflow = false;
                                while (!self.isAtEnd() and self.peek() != '}') {
                                    const hc = self.peek();
                                    const digit: u32 = if (hc >= '0' and hc <= '9')
                                        hc - '0'
                                    else if (hc >= 'a' and hc <= 'f')
                                        hc - 'a' + 10
                                    else if (hc >= 'A' and hc <= 'F')
                                        hc - 'A' + 10
                                    else {
                                        // 비-hex 문자 → invalid (문자를 소비하지 않음 — 템플릿 구분자일 수 있음)
                                        self.token.has_invalid_escape = true;
                                        break;
                                    };
                                    has_hex = true;
                                    // overflow 방지: 0x10FFFF는 21비트이므로 24비트 이상이면 overflow
                                    if (code_point > 0x10FFFF) {
                                        overflow = true;
                                    }
                                    code_point = (code_point << 4) | digit;
                                    self.current += 1;
                                }
                                if (!self.isAtEnd() and self.peek() == '}') {
                                    self.current += 1; // consume '}'
                                    if (!has_hex or overflow or code_point > 0x10FFFF) {
                                        self.token.has_invalid_escape = true;
                                    }
                                } else {
                                    self.token.has_invalid_escape = true;
                                }
                            } else {
                                // \uHHHH — 고정 4자리
                                if (self.skipHexEscape(4)) {
                                    self.token.has_invalid_escape = true;
                                }
                            }
                        },
                        // 줄바꿈 이스케이프 처리 (템플릿에서는 유효)
                        '\n', '\r' => {
                            _ = try self.handleNewline();
                        },
                        // 그 외: non-escape character (유효)
                        else => {
                            self.current += 1;
                        },
                    }
                }
                continue;
            }

            // 줄바꿈: 템플릿 리터럴에서는 허용됨 (일반 문자열과 다름)
            if (c == '\n' or c == '\r') {
                _ = try self.handleNewline();
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
            if (self.isLineSeparator()) break;
            self.current += 1;
        }
    }

    /// private identifier (#) 뒤의 첫 문자가 유효한 IdentifierStart인지 확인한다.
    /// IdentifierStart는 $, _, UnicodeIDStart, \uXXXX(IdentifierStart 코드포인트) 만 허용.
    /// ZWNJ (U+200C), ZWJ (U+200D) 등 IdentifierPart 전용 문자는 거부한다.
    fn scanPrivateIdentifierStart(self: *Scanner) bool {
        if (self.isAtEnd()) return false;
        const c = self.peek();
        if (c < 0x80) {
            // ASCII: a-z, A-Z, _, $
            if (isAsciiIdentStart(c)) {
                self.current += 1;
                return true;
            }
            if (c == '\\') {
                // \uXXXX 유니코드 이스케이프 — IdentifierStart인지 검증
                const esc_pos = self.current;
                if (!self.scanIdentifierEscape()) return false;
                const esc_slice = self.source[esc_pos..self.current];
                const cp = self.decodeEscapeCodepoint(esc_slice);
                if (cp) |codepoint| {
                    if (codepoint < 0x80) {
                        if (!isAsciiIdentStart(@intCast(codepoint))) {
                            self.current = esc_pos;
                            return false;
                        }
                    } else if (codepoint <= 0x10FFFF) {
                        if (!unicode.isIdentifierStart(@intCast(codepoint))) {
                            self.current = esc_pos;
                            return false;
                        }
                    }
                } else {
                    self.current = esc_pos;
                    return false;
                }
                return true;
            }
            return false;
        }
        // Non-ASCII: UTF-8 디코딩 후 UnicodeIDStart 확인
        const remaining = self.source[self.current..];
        const decoded = unicode.decodeUtf8(remaining);
        if (decoded.len == 0) return false;
        if (unicode.isIdentifierStart(decoded.codepoint)) {
            self.current += decoded.len;
            return true;
        }
        return false;
    }

    /// 식별자의 나머지 부분을 스캔한다. 유니코드 문자와 \u 이스케이프를 처리.
    fn scanIdentifierTail(self: *Scanner) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            // ASCII fast path
            if (c < 0x80) {
                if (isAsciiIdentContinue(c)) {
                    self.current += 1;
                } else if (c == '\\') {
                    // \uXXXX 유니코드 이스케이프
                    const esc_pos = self.current;
                    if (!self.scanIdentifierEscape()) break;
                    // 디코딩된 코드포인트가 ID_Continue인지 검증
                    const esc_slice = self.source[esc_pos..self.current];
                    const cp = self.decodeEscapeCodepoint(esc_slice);
                    if (cp) |codepoint| {
                        if (codepoint < 0x80) {
                            if (!isAsciiIdentContinue(@intCast(codepoint))) {
                                self.current = esc_pos;
                                break;
                            }
                        } else if (codepoint <= 0x10FFFF) {
                            if (!unicode.isIdentifierContinue(@intCast(codepoint))) {
                                self.current = esc_pos;
                                break;
                            }
                        }
                    } else {
                        // 디코딩 실패 → 유효하지 않은 이스케이프
                        self.current = esc_pos;
                        break;
                    }
                } else {
                    break;
                }
            } else {
                // Non-ASCII: UTF-8 디코딩 후 유니코드 ID_Continue 확인
                const remaining = self.source[self.current..];
                const decoded = unicode.decodeUtf8(remaining);
                if (decoded.len == 0) break;
                if (unicode.isIdentifierContinue(decoded.codepoint)) {
                    self.current += decoded.len;
                } else {
                    break;
                }
            }
        }
    }

    /// 식별자 안의 \uXXXX 또는 \u{XXXX} 이스케이프를 스캔한다.
    /// 성공하면 true, 유효하지 않으면 false.
    fn scanIdentifierEscape(self: *Scanner) bool {
        if (self.peek() != '\\') return false;
        if (self.peekAt(1) != 'u') return false;
        self.current += 2; // skip \u

        if (self.peek() == '{') {
            self.current += 1;
            while (!self.isAtEnd() and self.peek() != '}') {
                self.current += 1;
            }
            if (!self.isAtEnd()) self.current += 1; // skip }
        } else {
            _ = self.skipHexEscape(4);
        }
        return true;
    }

    /// 단일 유니코드 이스케이프 시퀀스 (\uXXXX 또는 \u{XXXX})에서 코드포인트를 추출한다.
    /// 식별자 시작/계속 문자의 유효성 검증에 사용한다.
    fn decodeEscapeCodepoint(_: *Scanner, raw: []const u8) ?u32 {
        // raw가 \uXXXX 또는 \u{XXXX} 형태인지 확인
        if (raw.len < 2) return null;
        var i: usize = 0;
        // 여러 이스케이프가 연결된 경우 첫 번째만 추출
        if (raw[i] != '\\' or raw[i + 1] != 'u') return null;
        i += 2;
        var codepoint: u32 = 0;
        if (i < raw.len and raw[i] == '{') {
            i += 1;
            while (i < raw.len and raw[i] != '}') {
                const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                codepoint = codepoint * 16 + digit;
                i += 1;
            }
        } else {
            var j: usize = 0;
            while (j < 4 and i < raw.len) : (j += 1) {
                const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                codepoint = codepoint * 16 + digit;
                i += 1;
            }
        }
        // Unicode 유효 범위 검증 (U+10FFFF 초과 거부)
        if (codepoint > 0x10FFFF) return null;
        return codepoint;
    }

    /// 이스케이프가 포함된 식별자 텍스트를 디코딩하여 실제 문자열을 반환한다.
    /// \uXXXX 와 \u{XXXX} 형태를 처리. BMP 문자만 지원 (키워드 매칭에 충분).
    /// 인스턴스의 decode_buf를 사용하여 dangling pointer 방지.
    pub fn decodeIdentifierEscapes(self: *Scanner, raw: []const u8) ?[]const u8 {
        // 이스케이프가 없으면 그대로 반환 (소스 텍스트 포인터, 항상 유효)
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;

        var out: usize = 0;
        var i: usize = 0;

        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == 'u') {
                i += 2; // skip \u
                var codepoint: u32 = 0;
                if (i < raw.len and raw[i] == '{') {
                    i += 1; // skip {
                    while (i < raw.len and raw[i] != '}') {
                        const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                    if (i < raw.len) i += 1; // skip }
                } else {
                    // \uXXXX — 4자리 고정
                    var j: usize = 0;
                    while (j < 4 and i < raw.len) : (j += 1) {
                        const digit = std.fmt.charToDigit(raw[i], 16) catch return null;
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                }
                // BMP 문자만 (키워드는 전부 ASCII)
                if (codepoint < 0x80) {
                    if (out >= self.decode_buf.len) return null;
                    self.decode_buf[out] = @intCast(codepoint);
                    out += 1;
                } else {
                    return null; // non-ASCII codepoint → 키워드 아님
                }
            } else {
                if (out >= self.decode_buf.len) return null;
                self.decode_buf[out] = raw[i];
                out += 1;
                i += 1;
            }
        }

        return self.decode_buf[0..out];
    }

    // ====================================================================
    // 문자 분류
    // ====================================================================

    /// ASCII 식별자 시작 문자인지.
    fn isAsciiIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            c == '_' or c == '$';
    }

    /// ASCII 식별자 계속 문자인지.
    fn isAsciiIdentContinue(c: u8) bool {
        return isAsciiIdentStart(c) or (c >= '0' and c <= '9');
    }
};

// ============================================================
// Tests
// ============================================================

test "Scanner: empty source" {
    var scanner = try Scanner.init(std.testing.allocator, "");
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: BOM skip" {
    var scanner = try Scanner.init(std.testing.allocator, "\xEF\xBB\xBF;");
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expectEqual(Kind.semicolon, scanner.token.kind);
    try std.testing.expectEqual(@as(u32, 3), scanner.token.span.start);
}

test "Scanner: single character tokens" {
    const source = "(){};,~@:";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .l_paren,   .r_paren, .l_curly, .r_curly,
        .semicolon, .comma,   .tilde,   .at,
        .colon,
    };
    for (expected) |kind| {
        try scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: compound operators" {
    const source = "++ -- ** === !== => ... ?? ?. ??= &&= ||=";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .plus2,   .minus2,   .star2,     .eq3,          .neq2,
        .arrow,   .dot3,     .question2, .question_dot, .question2_eq,
        .amp2_eq, .pipe2_eq,
    };
    for (expected) |kind| {
        try scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

test "Scanner: shift operators" {
    const source = "<< >> >>> <<= >>= >>>=";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .shift_left,    .shift_right,    .shift_right3,
        .shift_left_eq, .shift_right_eq, .shift_right3_eq,
    };
    for (expected) |kind| {
        try scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

test "Scanner: identifiers and keywords" {
    const source = "const foo let bar";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("foo", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.kw_let, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("bar", scanner.tokenText());
}

test "Scanner: whitespace and newlines set has_newline_before" {
    const source = "a\nb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expect(!scanner.token.has_newline_before);

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: CRLF counts as one newline" {
    const source = "a\r\nb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
    try std.testing.expectEqual(@as(u32, 1), scanner.line);
}

test "Scanner: line offset table" {
    const source = "a\nb\nc";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체를 스캔하여 line offset 테이블 구축
    while (scanner.token.kind != .eof or scanner.start == 0) {
        try scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    // line 0 → offset 0, line 1 → offset 2, line 2 → offset 4
    try std.testing.expectEqual(@as(u32, 0), scanner.line_offsets.items[0]);
    try std.testing.expectEqual(@as(u32, 2), scanner.line_offsets.items[1]);
    try std.testing.expectEqual(@as(u32, 4), scanner.line_offsets.items[2]);
}

test "Scanner: getLineColumn" {
    const source = "ab\ncde\nf";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체 스캔
    while (true) {
        try scanner.next();
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
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.hashbang_comment, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
}

test "Scanner: private identifier" {
    const source = "#name";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.private_identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("#name", scanner.tokenText());
}

test "Scanner: optional chaining vs ternary + number" {
    // ?. → optional chaining
    const source1 = "?.";
    var s1 = try Scanner.init(std.testing.allocator, source1);
    defer s1.deinit();
    try s1.next();
    try std.testing.expectEqual(Kind.question_dot, s1.token.kind);

    // ?.5 → question + .5 (ternary + number)
    const source2 = "?.5";
    var s2 = try Scanner.init(std.testing.allocator, source2);
    defer s2.deinit();
    try s2.next();
    try std.testing.expectEqual(Kind.question, s2.token.kind);
}

test "Scanner: string literal basic" {
    const source = "'hello' \"world\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: empty string literals" {
    const source = "'' \"\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("''", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"\"", scanner.tokenText());
}

test "Scanner: slash_eq operator" {
    const source = "/=";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.slash_eq, scanner.token.kind);
}

test "Scanner: CR alone as line terminator" {
    const source = "a\rb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
    try std.testing.expectEqual(@as(u32, 1), scanner.line);
}

test "Scanner: whitespace only source" {
    const source = "   \t\t  \n  ";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: NBSP whitespace (U+00A0)" {
    // U+00A0 = C2 A0
    const source = "a\xC2\xA0b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
}

test "Scanner: all assignment operators" {
    const source = "= += -= *= /= %= **= &= |= ^= <<= >>= >>>= &&= ||= ??=";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .eq,              .plus_eq,    .minus_eq,      .star_eq,
        .slash_eq,        .percent_eq, .star2_eq,      .amp_eq,
        .pipe_eq,         .caret_eq,   .shift_left_eq, .shift_right_eq,
        .shift_right3_eq, .amp2_eq,    .pipe2_eq,      .question2_eq,
    };
    for (expected) |kind| {
        try scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

// ============================================================
// Comment tests
// ============================================================

test "Scanner: single-line comment is skipped" {
    const source = "a // comment\nb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: multi-line comment is skipped" {
    const source = "a /* comment */ b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
}

test "Scanner: multi-line comment with newline sets has_newline_before" {
    const source = "a /*\n*/ b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: @__PURE__ comment sets flag" {
    const source = "/* @__PURE__ */ foo()";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("foo", scanner.tokenText());
    try std.testing.expect(scanner.token.has_pure_comment_before);
}

test "Scanner: #__PURE__ comment sets flag" {
    const source = "/* #__PURE__ */ bar()";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(scanner.token.has_pure_comment_before);
}

test "Scanner: @__NO_SIDE_EFFECTS__ comment sets separate flag" {
    const source = "/* @__NO_SIDE_EFFECTS__ */ function f() {}";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.kw_function, scanner.token.kind);
    // @__NO_SIDE_EFFECTS__는 has_pure_comment_before가 아닌 별도 플래그
    try std.testing.expect(!scanner.token.has_pure_comment_before);
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
}

test "Scanner: #__NO_SIDE_EFFECTS__ comment sets separate flag" {
    const source = "/* #__NO_SIDE_EFFECTS__ */ function g() {}";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.kw_function, scanner.token.kind);
    try std.testing.expect(!scanner.token.has_pure_comment_before);
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
}

test "Scanner: @__PURE__ and @__NO_SIDE_EFFECTS__ are independent" {
    // @__PURE__만 있으면 has_pure_comment_before만 true
    const source1 = "/* @__PURE__ */ foo()";
    var s1 = try Scanner.init(std.testing.allocator, source1);
    defer s1.deinit();
    try s1.next();
    try std.testing.expect(s1.token.has_pure_comment_before);
    try std.testing.expect(!s1.token.has_no_side_effects_comment);
}

test "Scanner: both @__PURE__ and @__NO_SIDE_EFFECTS__ in same comment" {
    const source = "/* @__PURE__ @__NO_SIDE_EFFECTS__ */ function f() {}";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.token.has_pure_comment_before);
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
}

test "Scanner: @__NO_SIDE_EFFECTS__ resets on next token" {
    const source = "/* @__NO_SIDE_EFFECTS__ */ function f() {} x";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next(); // function — has flag
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
    try scanner.next(); // f
    try std.testing.expect(!scanner.token.has_no_side_effects_comment);
}

test "Scanner: normal comment does not set pure flag" {
    const source = "/* normal comment */ x";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(!scanner.token.has_pure_comment_before);
}

test "Scanner: single-line comment at end of file" {
    const source = "a // comment";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: comment-only source" {
    const source = "// just a comment";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: slash after comment is not confused" {
    const source = "a /* */ / b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    try scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

test "Scanner: multi-line legal comment @license" {
    const source = "/* @license MIT */ var x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: multi-line legal comment /*!" {
    const source = "/*! Copyright 2024 */ var x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: single-line legal comment @license" {
    const source = "// @license MIT\nvar x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: single-line legal comment @preserve" {
    const source = "// @preserve\nvar x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: normal comment is not legal" {
    const source = "// just a comment\nvar x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(!scanner.comments.items[0].is_legal);
}

// ============================================================
// Numeric literal tests
// ============================================================

test "Scanner: decimal integer" {
    const source = "123 0 42";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("123", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("0", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
}

test "Scanner: hex literal" {
    const source = "0xFF 0X1A";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
    try std.testing.expectEqualStrings("0xFF", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
}

test "Scanner: octal literal" {
    const source = "0o77 0O10";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.octal, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.octal, scanner.token.kind);
}

test "Scanner: binary literal" {
    const source = "0b1010 0B11";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
}

test "Scanner: float literal" {
    const source = "1.5 0.1 .5";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings("1.5", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings(".5", scanner.tokenText());
}

test "Scanner: exponential literal" {
    const source = "1e10 1E10 1e+10 1e-10";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.negative_exponential, scanner.token.kind);
}

test "Scanner: bigint literal" {
    const source = "123n 0xFFn 0o77n 0b1010n";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.decimal_bigint, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.hex_bigint, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.octal_bigint, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.binary_bigint, scanner.token.kind);
}

test "Scanner: numeric separator" {
    const source = "1_000_000 0xFF_FF 0b1010_0001";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("1_000_000", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
}

test "Scanner: 1..toString is float then dot" {
    // 1..toString() → float(1.) dot identifier(toString) — 소수점 뒤 멤버 접근
    const source = "1..toString";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings("1.", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.dot, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("toString", scanner.tokenText());
}

test "Scanner: float with exponent" {
    const source = "1.5e10";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try std.testing.expectEqualStrings("1.5e10", scanner.tokenText());
}

// ============================================================
// String literal tests
// ============================================================

test "Scanner: string with escape sequences" {
    const source = "\"hello\\nworld\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", scanner.tokenText());
}

test "Scanner: string with hex escape" {
    const source = "'\\x41'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with unicode escape \\uHHHH" {
    const source = "'\\u0041'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with unicode escape \\u{}" {
    const source = "'\\u{1F600}'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with escaped quote" {
    const source = "'it\\'s'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with line continuation" {
    // '\' + newline = line continuation (valid)
    const source = "'hello\\\nworld'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: unterminated string at EOF" {
    const source = "\"hello";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: newline inside string is error" {
    const source = "\"hello\nworld\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: string with backslash at EOF" {
    const source = "'test\\";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: consecutive strings" {
    const source = "'a' \"b\" 'c'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("'a'", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"b\"", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

// ============================================================
// Template literal tests
// ============================================================

test "Scanner: no substitution template" {
    const source = "`hello world`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
    try std.testing.expectEqualStrings("`hello world`", scanner.tokenText());
}

test "Scanner: template with interpolation" {
    // `hello ${name}!`
    const source = "`hello ${name}!`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);
    try std.testing.expectEqualStrings("`hello ${", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("name", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
    try std.testing.expectEqualStrings("}!`", scanner.tokenText());
}

test "Scanner: template with multiple interpolations" {
    // `${a} + ${b} = ${c}`
    const source = "`${a} + ${b} = ${c}`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // } + ${
    try std.testing.expectEqual(Kind.template_middle, scanner.token.kind);

    try scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // } = ${
    try std.testing.expectEqual(Kind.template_middle, scanner.token.kind);

    try scanner.next(); // c
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // }`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: nested template literals" {
    // `a${`b${c}d`}e`
    const source = "`a${`b${c}d`}e`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // `a${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // `b${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // c
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // }d`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);

    try scanner.next(); // }e`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: template with object literal inside" {
    // `${{a: 1}}`
    const source = "`${{a: 1}}`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // `${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // {
    try std.testing.expectEqual(Kind.l_curly, scanner.token.kind);

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // :
    try std.testing.expectEqual(Kind.colon, scanner.token.kind);

    try scanner.next(); // 1
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);

    try scanner.next(); // }
    try std.testing.expectEqual(Kind.r_curly, scanner.token.kind);

    try scanner.next(); // }`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: empty template" {
    const source = "``";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
}

test "Scanner: template with newline" {
    const source = "`line1\nline2`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
}

test "Scanner: unterminated template" {
    const source = "`hello";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

// ============================================================
// RegExp literal tests
// ============================================================

test "Scanner: regex after =" {
    // = /pattern/gi → eq, regexp
    const source = "= /abc/gi";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // =
    try std.testing.expectEqual(Kind.eq, scanner.token.kind);
    try scanner.next(); // /abc/gi
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("/abc/gi", scanner.tokenText());
}

test "Scanner: regex after (" {
    const source = "(/test/)";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // (
    try std.testing.expectEqual(Kind.l_paren, scanner.token.kind);
    try scanner.next(); // /test/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

test "Scanner: division after identifier" {
    // a / b → identifier, slash, identifier
    const source = "a / b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    try scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

test "Scanner: division after number" {
    const source = "10 / 2";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // 10
    try scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
}

test "Scanner: regex with character class" {
    // character class 안의 / 는 regex를 끝내지 않음
    const source = "= /[a/b]/";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // =
    try scanner.next(); // /[a/b]/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("/[a/b]/", scanner.tokenText());
}

test "Scanner: regex with escape" {
    const source = "= /a\\/b/";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // =
    try scanner.next(); // /a\/b/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

test "Scanner: regex after return keyword" {
    const source = "return /test/g";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // return
    try std.testing.expectEqual(Kind.kw_return, scanner.token.kind);
    try scanner.next(); // /test/g
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

test "Scanner: regex after comma" {
    const source = ", /re/";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // ,
    try scanner.next(); // /re/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

// ============================================================
// Unicode identifier tests
// ============================================================

test "Scanner: unicode identifier (Latin)" {
    // café = UTF-8: 63 61 66 C3 A9
    const source = "caf\xC3\xA9";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("caf\xC3\xA9", scanner.tokenText());
}

test "Scanner: unicode identifier (CJK)" {
    // 변수 = UTF-8: EB B3 80 EC 88 98
    const source = "\xEB\xB3\x80\xEC\x88\x98";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

test "Scanner: unicode identifier (Greek)" {
    // α = UTF-8: CE B1
    const source = "\xCE\xB1 = 1";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("\xCE\xB1", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.eq, scanner.token.kind);
}

test "Scanner: mixed ASCII and unicode in identifier" {
    // test변수 = ASCII + CJK
    const source = "test\xEB\xB3\x80\xEC\x88\x98";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("test\xEB\xB3\x80\xEC\x88\x98", scanner.tokenText());
}

// ============================================================
// JSX mode tests
// ============================================================

test "Scanner: JSX element identifier with hyphen" {
    const source = "data-testid";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement();
    try std.testing.expectEqual(Kind.jsx_identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("data-testid", scanner.tokenText());
}

test "Scanner: JSX element tokens" {
    // <div className="hello">
    const source = "div className=\"hello\">";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement(); // div
    try std.testing.expectEqual(Kind.jsx_identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("div", scanner.tokenText());

    try scanner.nextInsideJSXElement(); // className
    try std.testing.expectEqual(Kind.jsx_identifier, scanner.token.kind);

    try scanner.nextInsideJSXElement(); // =
    try std.testing.expectEqual(Kind.eq, scanner.token.kind);

    try scanner.nextInsideJSXElement(); // "hello"
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);

    try scanner.nextInsideJSXElement(); // >
    try std.testing.expectEqual(Kind.r_angle, scanner.token.kind);
}

test "Scanner: JSX text content" {
    const source = "Hello World<";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextJSXChild(); // "Hello World"
    try std.testing.expectEqual(Kind.jsx_text, scanner.token.kind);
    try std.testing.expectEqualStrings("Hello World", scanner.tokenText());

    try scanner.nextJSXChild(); // <
    try std.testing.expectEqual(Kind.l_angle, scanner.token.kind);
}

test "Scanner: JSX text with expression" {
    const source = "text{expr}more";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextJSXChild(); // "text"
    try std.testing.expectEqual(Kind.jsx_text, scanner.token.kind);
    try std.testing.expectEqualStrings("text", scanner.tokenText());

    try scanner.nextJSXChild(); // {
    try std.testing.expectEqual(Kind.l_curly, scanner.token.kind);
}

test "Scanner: JSX self-closing tag" {
    const source = "/>";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement();
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    // 파서가 slash + r_angle을 자체 닫힘 태그로 조합
}

test "Scanner: JSX string without escape" {
    // JSX 속성 문자열은 이스케이프를 처리하지 않음
    const source = "\"hello\\nworld\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    // 전체 텍스트가 토큰에 포함됨 (이스케이프 안 함)
    try std.testing.expectEqualStrings("\"hello\\nworld\"", scanner.tokenText());
}

// ============================================================
// JSX pragma tests (D026)
// ============================================================

test "Scanner: @jsx pragma in single-line comment" {
    const source = "// @jsx h\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // const (comment is skipped)
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
    try std.testing.expectEqualStrings("h", scanner.jsx_pragma.?);
}

test "Scanner: @jsx pragma in multi-line comment" {
    const source = "/** @jsx h */\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqualStrings("h", scanner.jsx_pragma.?);
}

test "Scanner: @jsxFrag pragma" {
    const source = "/** @jsxFrag Fragment */";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // eof (comment only)
    try std.testing.expectEqualStrings("Fragment", scanner.jsx_frag_pragma.?);
}

test "Scanner: @jsxRuntime pragma" {
    const source = "// @jsxRuntime automatic";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqualStrings("automatic", scanner.jsx_runtime_pragma.?);
}

test "Scanner: @jsxImportSource pragma" {
    const source = "/** @jsxImportSource preact */";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqualStrings("preact", scanner.jsx_import_source_pragma.?);
}

test "Scanner: multiple pragmas in one file" {
    const source = "/** @jsx h */\n// @jsxFrag Fragment\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체 스캔
    while (true) {
        try scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    try std.testing.expectEqualStrings("h", scanner.jsx_pragma.?);
    try std.testing.expectEqualStrings("Fragment", scanner.jsx_frag_pragma.?);
}

test "Scanner: no pragma in normal comment" {
    const source = "/* just a comment */ x";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(scanner.jsx_pragma == null);
    try std.testing.expect(scanner.jsx_frag_pragma == null);
}
