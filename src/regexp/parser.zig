//! ECMAScript 정규식 패턴 파서.
//!
//! `/pattern/flags` 의 pattern 부분을 검증한다.
//! comptime emit_ast=false이면 검증만, true이면 AST 빌드 (Phase 6).
//!
//! ECMAScript 정규식 문법 (간략):
//!   Pattern     → Disjunction
//!   Disjunction → Alternative ('|' Alternative)*
//!   Alternative → Term*
//!   Term        → Assertion | Atom Quantifier?
//!   Atom        → '.' | CharacterClass | Group | Escape | Character
//!
//! 참고: references/oxc/crates/oxc_regular_expression/src/parser

const std = @import("std");
const flags_mod = @import("flags.zig");
const Flags = flags_mod.Flags;

/// 패턴 파서. comptime emit_ast로 검증/AST 모드 분리.
pub fn PatternParser(comptime emit_ast: bool) type {
    _ = emit_ast; // Phase 6에서 활성화

    return struct {
        const Self = @This();

        /// 패턴 소스 텍스트
        source: []const u8,
        /// 현재 위치
        pos: u32 = 0,
        /// 파싱된 플래그 (unicode mode 판별에 필요)
        flags: Flags,
        /// 에러 메시지 (첫 번째 에러만)
        err_message: ?[]const u8 = null,
        /// 에러 위치
        err_offset: u32 = 0,
        /// capturing group 카운트 (back reference 검증용)
        group_count: u32 = 0,
        /// named group 이름 목록 (중복 검증용)
        named_groups: [32][]const u8 = undefined,
        named_group_count: u8 = 0,
        /// 가장 큰 back reference 번호 (group_count와 비교)
        max_back_ref: u32 = 0,

        pub fn init(source: []const u8, parsed_flags: Flags) Self {
            return .{
                .source = source,
                .flags = parsed_flags,
            };
        }

        /// 패턴을 검증한다. 에러가 있으면 에러 메시지, 없으면 null.
        pub fn validate(self: *Self) ?[]const u8 {
            self.parseDisjunction();
            if (self.err_message != null) return self.err_message;

            // 소스 끝까지 소비하지 않았으면 에러
            if (self.pos < self.source.len) {
                return "unexpected character in regular expression";
            }

            // back reference가 group count보다 크면 에러 (unicode mode에서)
            if (self.flags.hasUnicodeMode() and self.max_back_ref > self.group_count) {
                return "invalid back reference in regular expression";
            }

            return self.err_message;
        }

        // ================================================================
        // 핵심 파싱 함수
        // ================================================================

        /// Disjunction → Alternative ('|' Alternative)*
        fn parseDisjunction(self: *Self) void {
            self.parseAlternative();
            while (self.eat('|')) {
                self.parseAlternative();
            }
        }

        /// Alternative → Term*
        fn parseAlternative(self: *Self) void {
            while (!self.isEnd() and self.peek() != '|' and self.peek() != ')') {
                self.parseTerm();
                if (self.err_message != null) return;
            }
        }

        /// Term → Assertion | Atom Quantifier?
        fn parseTerm(self: *Self) void {
            // Assertion: ^, $, \b, \B, lookahead/lookbehind
            if (self.parseAssertion()) return;

            // Atom
            const atom_start = self.pos;
            if (!self.parseAtom()) {
                if (self.err_message == null) {
                    self.setError("unexpected character in regular expression");
                }
                return;
            }

            // Quantifier: *, +, ?, {n,m}
            self.parseQuantifier(atom_start);
        }

        // ================================================================
        // Assertion
        // ================================================================

        fn parseAssertion(self: *Self) bool {
            if (self.isEnd()) return false;
            const c = self.peek();

            if (c == '^' or c == '$') {
                self.advance();
                return true;
            }

            // \b, \B (word boundary)
            if (c == '\\' and self.pos + 1 < self.source.len) {
                const next = self.source[self.pos + 1];
                if (next == 'b' or next == 'B') {
                    self.pos += 2;
                    return true;
                }
            }

            // Lookahead/Lookbehind: (?=...), (?!...), (?<=...), (?<!...)
            if (c == '(' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '?') {
                if (self.pos + 2 < self.source.len) {
                    const third = self.source[self.pos + 2];
                    if (third == '=' or third == '!') {
                        self.pos += 3;
                        self.parseDisjunction();
                        if (!self.eat(')')) self.setError("unterminated lookahead assertion");
                        return true;
                    }
                    if (third == '<' and self.pos + 3 < self.source.len) {
                        const fourth = self.source[self.pos + 3];
                        if (fourth == '=' or fourth == '!') {
                            self.pos += 4;
                            self.parseDisjunction();
                            if (!self.eat(')')) self.setError("unterminated lookbehind assertion");
                            return true;
                        }
                    }
                }
            }

            return false;
        }

        // ================================================================
        // Atom
        // ================================================================

        fn parseAtom(self: *Self) bool {
            if (self.isEnd()) return false;
            const c = self.peek();

            switch (c) {
                '.' => {
                    self.advance();
                    return true;
                },
                '\\' => return self.parseEscape(),
                '[' => return self.parseCharacterClass(),
                '(' => return self.parseGroup(),
                // quantifier without atom — 에러
                '*', '+', '?' => {
                    self.setError("unexpected quantifier without preceding atom");
                    return false;
                },
                '{' => {
                    // unicode mode에서 standalone {는 에러
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("unexpected quantifier without preceding atom");
                        return false;
                    }
                    // non-unicode mode에서는 literal
                    self.advance();
                    return true;
                },
                '}' => {
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("unexpected '}' in regular expression");
                        return false;
                    }
                    self.advance();
                    return true;
                },
                ']' => {
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("unexpected ']' in regular expression");
                        return false;
                    }
                    self.advance();
                    return true;
                },
                ')' => return false, // alternative 종료
                else => {
                    self.advance();
                    return true;
                },
            }
        }

        // ================================================================
        // Escape
        // ================================================================

        fn parseEscape(self: *Self) bool {
            if (self.pos + 1 >= self.source.len) {
                self.setError("unterminated escape sequence in regular expression");
                return false;
            }
            self.advance(); // skip '\'
            const c = self.peek();

            switch (c) {
                // Character class escapes
                'd', 'D', 'w', 'W', 's', 'S' => {
                    self.advance();
                    return true;
                },
                // Control escape
                'f', 'n', 'r', 't', 'v' => {
                    self.advance();
                    return true;
                },
                // \cX control character
                'c' => {
                    self.advance();
                    if (!self.isEnd()) {
                        const ctrl = self.peek();
                        if ((ctrl >= 'a' and ctrl <= 'z') or (ctrl >= 'A' and ctrl <= 'Z')) {
                            self.advance();
                            return true;
                        }
                    }
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("invalid control character escape");
                        return false;
                    }
                    return true;
                },
                // \0 null
                '0' => {
                    self.advance();
                    // \0 뒤에 digit이 오면 legacy octal (unicode에서 금지)
                    if (!self.isEnd() and self.peek() >= '0' and self.peek() <= '9') {
                        if (self.flags.hasUnicodeMode()) {
                            self.setError("invalid octal escape in unicode mode");
                            return false;
                        }
                        // non-unicode: legacy octal 허용
                        while (!self.isEnd() and self.peek() >= '0' and self.peek() <= '7') {
                            self.advance();
                        }
                    }
                    return true;
                },
                // \xHH hex escape
                'x' => {
                    self.advance();
                    if (!self.eatHexDigits(2)) {
                        if (self.flags.hasUnicodeMode()) {
                            self.setError("invalid hex escape in regular expression");
                            return false;
                        }
                    }
                    return true;
                },
                // \uHHHH or \u{HHHH} unicode escape
                'u' => {
                    self.advance();
                    if (self.eat('{')) {
                        if (!self.eatHexDigitsUntil('}')) {
                            self.setError("invalid unicode escape in regular expression");
                            return false;
                        }
                    } else {
                        if (!self.eatHexDigits(4)) {
                            if (self.flags.hasUnicodeMode()) {
                                self.setError("invalid unicode escape in regular expression");
                                return false;
                            }
                        }
                    }
                    return true;
                },
                // \p{...} or \P{...} unicode property escape
                'p', 'P' => {
                    if (self.flags.hasUnicodeMode()) {
                        self.advance();
                        if (!self.eat('{')) {
                            self.setError("invalid unicode property escape");
                            return false;
                        }
                        // property name: skip until }
                        while (!self.isEnd() and self.peek() != '}') {
                            self.advance();
                        }
                        if (!self.eat('}')) {
                            self.setError("unterminated unicode property escape");
                            return false;
                        }
                        return true;
                    }
                    // non-unicode: literal
                    self.advance();
                    return true;
                },
                // \k<name> named back reference
                'k' => {
                    if (self.flags.hasUnicodeMode() or self.named_group_count > 0) {
                        self.advance();
                        if (!self.eat('<')) {
                            if (self.flags.hasUnicodeMode()) {
                                self.setError("invalid named back reference");
                                return false;
                            }
                            return true;
                        }
                        // 그룹 이름 검증
                        if (!self.parseGroupName()) return false;
                        return true;
                    }
                    self.advance();
                    return true;
                },
                // Back reference \1-\9
                '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                    var ref_num: u32 = 0;
                    while (!self.isEnd() and self.peek() >= '0' and self.peek() <= '9') {
                        ref_num = ref_num *| 10 +| (self.peek() - '0'); // saturating arithmetic
                        self.advance();
                    }
                    if (ref_num > self.max_back_ref) self.max_back_ref = ref_num;
                    return true;
                },
                // Identity escape — unicode mode에서는 제한
                else => {
                    if (self.flags.hasUnicodeMode()) {
                        // unicode mode: syntax characters만 identity escape 가능
                        if (isSyntaxChar(c)) {
                            self.advance();
                            return true;
                        }
                        self.setError("invalid escape sequence in unicode mode");
                        return false;
                    }
                    // non-unicode: 모든 문자 identity escape 가능
                    self.advance();
                    return true;
                },
            }
        }

        // ================================================================
        // Character Class
        // ================================================================

        fn parseCharacterClass(self: *Self) bool {
            self.advance(); // skip '['
            _ = self.eat('^'); // negated class

            while (!self.isEnd() and self.peek() != ']') {
                if (!self.parseClassAtom()) {
                    if (self.err_message != null) return false;
                }
                // range: a-z
                if (!self.isEnd() and self.peek() == '-') {
                    self.advance();
                    if (!self.isEnd() and self.peek() != ']') {
                        if (!self.parseClassAtom()) {
                            if (self.err_message != null) return false;
                        }
                    }
                }
            }

            if (!self.eat(']')) {
                self.setError("unterminated character class");
                return false;
            }
            return true;
        }

        fn parseClassAtom(self: *Self) bool {
            if (self.isEnd()) return false;
            if (self.peek() == '\\') {
                return self.parseEscape();
            }
            self.advance();
            return true;
        }

        // ================================================================
        // Group
        // ================================================================

        fn parseGroup(self: *Self) bool {
            self.advance(); // skip '('

            if (!self.isEnd() and self.peek() == '?') {
                self.advance(); // skip '?'
                if (self.isEnd()) {
                    self.setError("unterminated group");
                    return false;
                }
                const c = self.peek();
                switch (c) {
                    ':' => {
                        // non-capturing group (?:...)
                        self.advance();
                    },
                    '<' => {
                        // named group (?<name>...)
                        self.advance();
                        const name_start = self.pos;
                        // 그룹 이름 유효성: IdentifierName (ID_Start + ID_Continue*)
                        if (!self.parseGroupName()) return false;
                        const name = self.source[name_start .. self.pos - 1]; // -1 for '>'
                        // 중복 이름 체크
                        for (self.named_groups[0..self.named_group_count]) |existing| {
                            if (std.mem.eql(u8, existing, name)) {
                                self.setError("duplicate named capturing group");
                                return false;
                            }
                        }
                        if (self.named_group_count < 32) {
                            self.named_groups[self.named_group_count] = name;
                            self.named_group_count += 1;
                        } else {
                            self.setError("too many named capturing groups");
                            return false;
                        }
                        self.group_count += 1;
                    },
                    // inline modifiers (?ims:...) or (?ims-ims:...)
                    'i', 'm', 's' => {
                        if (!self.parseModifiers()) return false;
                    },
                    '-' => {
                        if (!self.parseModifiers()) return false;
                    },
                    else => {
                        self.setError("invalid group specifier");
                        return false;
                    },
                }
            } else {
                // capturing group (...)
                self.group_count += 1;
            }

            self.parseDisjunction();
            if (!self.eat(')')) {
                self.setError("unterminated group");
                return false;
            }
            return true;
        }

        // ================================================================
        // Modifiers (?ims-ims:...)
        // ================================================================

        fn parseModifiers(self: *Self) bool {
            var seen_i: bool = false;
            var seen_m: bool = false;
            var seen_s: bool = false;
            // positive modifiers
            while (!self.isEnd() and isModifierChar(self.peek())) {
                switch (self.peek()) {
                    'i' => {
                        if (seen_i) {
                            self.setError("duplicate modifier 'i'");
                            return false;
                        }
                        seen_i = true;
                    },
                    'm' => {
                        if (seen_m) {
                            self.setError("duplicate modifier 'm'");
                            return false;
                        }
                        seen_m = true;
                    },
                    's' => {
                        if (seen_s) {
                            self.setError("duplicate modifier 's'");
                            return false;
                        }
                        seen_s = true;
                    },
                    else => {},
                }
                self.advance();
            }
            // optional '-' for negative modifiers
            if (!self.isEnd() and self.peek() == '-') {
                self.advance();
                while (!self.isEnd() and isModifierChar(self.peek())) {
                    switch (self.peek()) {
                        'i' => {
                            if (seen_i) {
                                self.setError("modifier 'i' already set");
                                return false;
                            }
                            seen_i = true;
                        },
                        'm' => {
                            if (seen_m) {
                                self.setError("modifier 'm' already set");
                                return false;
                            }
                            seen_m = true;
                        },
                        's' => {
                            if (seen_s) {
                                self.setError("modifier 's' already set");
                                return false;
                            }
                            seen_s = true;
                        },
                        else => {},
                    }
                    self.advance();
                }
            }
            if (!self.eat(':')) {
                self.setError("invalid modifier group, expected ':'");
                return false;
            }
            return true;
        }

        // ================================================================
        // Group Name (IdentifierName)
        // ================================================================

        /// named group 이름을 파싱하고 `>`로 닫힘을 검증한다.
        /// ECMAScript: GroupName = `<` RegExpIdentifierName `>`
        /// RegExpIdentifierName = RegExpIdentifierStart RegExpIdentifierPart*
        fn parseGroupName(self: *Self) bool {
            if (self.isEnd() or self.peek() == '>') {
                self.setError("empty group name");
                return false;
            }
            // 첫 글자: ID_Start 또는 \u escape
            if (!self.parseGroupNameChar(true)) {
                self.setError("invalid group name start character");
                return false;
            }
            // 나머지: ID_Continue 또는 \u escape
            while (!self.isEnd() and self.peek() != '>') {
                if (!self.parseGroupNameChar(false)) {
                    self.setError("invalid character in group name");
                    return false;
                }
            }
            if (!self.eat('>')) {
                self.setError("unterminated group name");
                return false;
            }
            return true;
        }

        /// 그룹 이름의 한 문자를 파싱한다.
        /// is_start=true이면 ID_Start, false이면 ID_Continue 체크.
        fn parseGroupNameChar(self: *Self, is_start: bool) bool {
            if (self.isEnd()) return false;
            const c = self.peek();

            // \u escape in group name
            if (c == '\\') {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
                    self.pos += 2; // skip \u
                    // \u{HHHH} or \uHHHH
                    if (self.eat('{')) {
                        if (!self.eatHexDigitsUntil('}')) {
                            self.setError("invalid unicode escape in group name");
                            return false;
                        }
                    } else {
                        if (!self.eatHexDigits(4)) {
                            self.setError("invalid unicode escape in group name");
                            return false;
                        }
                    }
                    return true; // escape의 코드포인트 검증은 생략 (대부분의 케이스를 잡음)
                }
                return false;
            }

            // ASCII 식별자 문자 체크
            if (c == '_' or c == '$') {
                self.advance();
                return true;
            }
            if (is_start) {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                    self.advance();
                    return true;
                }
            } else {
                if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
                    self.advance();
                    return true;
                }
            }

            // Non-ASCII: UTF-8 multi-byte 문자 (Unicode ID_Start/ID_Continue)
            if (c >= 0x80) {
                // unicode mode에서 non-ASCII는 에러 (유효한 Unicode escape를 사용해야 함)
                if (self.flags.hasUnicodeMode()) {
                    return false;
                }
                self.advance();
                // multi-byte UTF-8: 후속 바이트 스킵
                while (!self.isEnd() and (self.peek() & 0xC0) == 0x80) {
                    self.advance();
                }
                return true;
            }

            return false;
        }

        // ================================================================
        // Quantifier
        // ================================================================

        fn parseQuantifier(self: *Self, _: u32) void {
            if (self.isEnd()) return;
            const c = self.peek();

            switch (c) {
                '*', '+', '?' => {
                    self.advance();
                    _ = self.eat('?'); // lazy modifier
                },
                '{' => {
                    const saved = self.pos;
                    self.advance(); // skip '{'
                    if (self.eatDigits()) {
                        if (self.eat(',')) {
                            _ = self.eatDigits(); // optional max
                        }
                        if (self.eat('}')) {
                            _ = self.eat('?'); // lazy
                            return;
                        }
                    }
                    // invalid braced quantifier
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("invalid braced quantifier");
                        return;
                    }
                    // non-unicode: rollback, treat '{' as literal
                    self.pos = saved;
                },
                else => {},
            }
        }

        // ================================================================
        // 헬퍼 함수
        // ================================================================

        fn peek(self: *const Self) u8 {
            return self.source[self.pos];
        }

        fn advance(self: *Self) void {
            if (self.pos < self.source.len) self.pos += 1;
        }

        fn isEnd(self: *const Self) bool {
            return self.pos >= self.source.len;
        }

        fn eat(self: *Self, expected: u8) bool {
            if (!self.isEnd() and self.peek() == expected) {
                self.advance();
                return true;
            }
            return false;
        }

        fn eatDigits(self: *Self) bool {
            if (self.isEnd() or self.peek() < '0' or self.peek() > '9') return false;
            while (!self.isEnd() and self.peek() >= '0' and self.peek() <= '9') {
                self.advance();
            }
            return true;
        }

        fn eatHexDigits(self: *Self, count: u32) bool {
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (self.isEnd()) return false;
                const c = self.peek();
                if (!isHexDigit(c)) return false;
                self.advance();
            }
            return true;
        }

        fn eatHexDigitsUntil(self: *Self, terminator: u8) bool {
            var count: u32 = 0;
            while (!self.isEnd() and self.peek() != terminator) {
                if (!isHexDigit(self.peek())) return false;
                self.advance();
                count += 1;
            }
            if (count == 0) return false;
            return self.eat(terminator);
        }

        fn setError(self: *Self, msg: []const u8) void {
            if (self.err_message == null) {
                self.err_message = msg;
                self.err_offset = self.pos;
            }
        }
    };
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isSyntaxChar(c: u8) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        else => false,
    };
}

fn isModifierChar(c: u8) bool {
    return c == 'i' or c == 'm' or c == 's';
}

// ============================================================
// Tests
// ============================================================

test "basic patterns" {
    const P = PatternParser(false);
    {
        var p = P.init("abc", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("a|b|c", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("a*b+c?", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "character class" {
    const P = PatternParser(false);
    {
        var p = P.init("[abc]", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("[a-z]", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("[^abc]", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "groups" {
    const P = PatternParser(false);
    {
        var p = P.init("(abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("(?:abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("(?<name>abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "unterminated group" {
    const P = PatternParser(false);
    var p = P.init("(abc", .{});
    try std.testing.expect(p.validate() != null);
}

test "lone quantifier" {
    const P = PatternParser(false);
    {
        var p = P.init("*", .{});
        try std.testing.expect(p.validate() != null);
    }
    {
        var p = P.init("+abc", .{});
        try std.testing.expect(p.validate() != null);
    }
}

test "unicode mode identity escape" {
    const P = PatternParser(false);
    {
        // \M is invalid in unicode mode
        var p = P.init("\\M", .{ .u = true });
        try std.testing.expect(p.validate() != null);
    }
    {
        // \M is valid in non-unicode mode
        var p = P.init("\\M", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "duplicate named group" {
    const P = PatternParser(false);
    var p = P.init("(?<a>x)(?<a>y)", .{});
    try std.testing.expect(p.validate() != null);
}

test "braced quantifier without atom in unicode mode" {
    const P = PatternParser(false);
    var p = P.init("{2,3}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}
