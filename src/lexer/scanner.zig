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
            '{' => .l_curly,
            '}' => .r_curly,
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
            '0'...'9' => blk: {
                // TODO: 숫자 리터럴 세부 파싱 (hex, octal, binary, bigint, float, exponential)
                self.scanNumericLiteral();
                break :blk .decimal;
            },
            '\'', '"' => blk: {
                // TODO: 문자열 리터럴 세부 파싱 (escape sequence)
                self.scanStringLiteral(c);
                break :blk .string_literal;
            },
            '`' => blk: {
                // TODO: 템플릿 리터럴 세부 파싱
                self.scanTemplateLiteral();
                break :blk .no_substitution_template;
            },

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

        self.token.span = .{ .start = self.start, .end = self.current };
    }

    // ====================================================================
    // 복합 연산자 스캔
    // ====================================================================

    fn scanDot(self: *Scanner) Kind {
        if (self.peek() == '.' and self.peekAt(1) == '.') {
            self.current += 2;
            return .dot3;
        }
        // .5 같은 숫자는 추후 숫자 리터럴 PR에서 처리
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
        // TODO: 주석 (// /* */ ) 처리는 다음 PR
        if (self.peek() == '=') {
            self.current += 1;
            return .slash_eq;
        }
        return .slash;
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

    fn scanNumericLiteral(self: *Scanner) void {
        // TODO: hex, octal, binary, bigint, float, exponential, separator
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c >= '0' and c <= '9') {
                self.current += 1;
            } else if (c == '.') {
                self.current += 1;
            } else {
                break;
            }
        }
    }

    fn scanStringLiteral(self: *Scanner, quote: u8) void {
        // TODO: escape sequence, multi-line, legacy octal
        while (!self.isAtEnd()) {
            const c = self.advance();
            if (c == quote) return;
            if (c == '\\') _ = self.advance(); // skip escaped char
        }
    }

    fn scanTemplateLiteral(self: *Scanner) void {
        // TODO: ${} interpolation, template head/middle/tail
        while (!self.isAtEnd()) {
            const c = self.advance();
            if (c == '`') return;
            if (c == '\\') _ = self.advance();
        }
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
