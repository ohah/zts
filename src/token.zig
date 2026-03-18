//! ZTS Token Definitions
//!
//! ECMAScript / TypeScript / JSX / Flow 토큰 종류를 정의한다.
//! oxc의 Kind enum을 참고하여 설계 (D034).
//!
//! 설계 원칙:
//! - u8 repr (~208개, 256 이내)
//! - 키워드를 개별 토큰으로 (파서에서 문자열 비교 불필요)
//! - 숫자를 세분화 (Decimal/Float/Hex/Octal/Binary/BigInt)
//! - 키워드 범위를 연속 배치하여 range check 최적화
//!   예: `token.isKeyword()` → `@intFromEnum(token) >= first_kw and <= last_kw`
//!
//! 참고: references/oxc/crates/oxc_parser/src/lexer/kind.rs

const std = @import("std");

/// 소스 코드의 위치를 나타내는 span.
/// start와 end는 소스 코드의 byte offset이다.
/// line/column은 별도 line offset 테이블에서 lazy 계산한다 (D015).
pub const Span = struct {
    start: u32,
    end: u32,

    pub const EMPTY = Span{ .start = 0, .end = 0 };

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    /// 두 span을 합친다 (시작은 self, 끝은 other).
    pub fn merge(self: Span, other: Span) Span {
        return .{
            .start = self.start,
            .end = other.end,
        };
    }
};

/// 렉서가 생성하는 토큰 하나.
/// 토큰 종류(kind) + 소스 위치(span) + 메타데이터.
pub const Token = struct {
    kind: Kind = .eof,
    span: Span = Span.EMPTY,

    /// 이 토큰 직전에 줄바꿈이 있었는지 (ASI 판정에 필요)
    has_newline_before: bool = false,

    /// 이 토큰 직전에 @__PURE__ 또는 @__NO_SIDE_EFFECTS__ 주석이 있었는지 (D025)
    has_pure_comment_before: bool = false,
};

/// ECMAScript / TypeScript / JSX 토큰 종류.
///
/// oxc 방식으로 세분화: TS 키워드 개별 토큰, 숫자 11가지 세분화.
/// u8로 표현 가능 (208개 < 256).
///
/// 키워드는 연속 배치하여 range check 최적화:
///   isKeyword() → kw_await..kw_null 범위 체크
///   isReservedKeyword() → kw_await..kw_with 범위 체크
///   isStrictModeReserved() → kw_implements..kw_yield 범위 체크
///   isTypeScriptKeyword() → kw_abstract..kw_override 범위 체크
pub const Kind = enum(u8) {
    // ========================================================================
    // Special
    // ========================================================================
    eof = 0,
    /// 아직 결정되지 않은 토큰 (렉서 내부 상태)
    undetermined,
    /// 구문 에러가 발생한 토큰
    syntax_error,
    /// hashbang 주석 (`#!/usr/bin/env node`)
    hashbang_comment,

    // ========================================================================
    // Identifiers
    // ========================================================================
    /// 일반 식별자
    identifier,
    /// private 식별자 (`#name`)
    private_identifier,
    /// 유니코드 이스케이프로 작성된 키워드 (키워드가 아닌 식별자로 취급)
    escaped_keyword,

    // ========================================================================
    // ECMAScript Reserved Keywords (ES2024)
    // 순서 중요: isReservedKeyword() range check에 사용
    // ========================================================================
    kw_await,
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_enum,
    kw_export,
    kw_extends,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_return,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,

    // ========================================================================
    // ECMAScript Contextual Keywords
    // ========================================================================
    kw_async,
    kw_from,
    kw_get,
    kw_meta,
    kw_of,
    kw_set,
    kw_target,
    kw_accessor,
    kw_source,
    kw_defer,
    kw_using,
    kw_let,

    // ========================================================================
    // Strict Mode Reserved Words
    // 순서 중요: isStrictModeReserved() range check에 사용
    // ========================================================================
    kw_implements,
    kw_interface,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_static,
    kw_yield,

    // ========================================================================
    // Literal Keywords
    // ========================================================================
    kw_true,
    kw_false,
    kw_null,

    // ========================================================================
    // TypeScript Contextual Keywords
    // 순서 중요: isTypeScriptKeyword() range check에 사용
    // ========================================================================
    kw_abstract,
    kw_any,
    kw_as,
    kw_asserts,
    kw_assert,
    kw_bigint,
    kw_boolean,
    kw_constructor,
    kw_declare,
    kw_global,
    kw_infer,
    kw_intrinsic,
    kw_is,
    kw_keyof,
    kw_module,
    kw_namespace,
    kw_never,
    kw_number,
    kw_object,
    kw_out,
    kw_readonly,
    kw_require,
    kw_satisfies,
    kw_string,
    kw_symbol,
    kw_type,
    kw_undefined,
    kw_unique,
    kw_unknown,
    kw_override,

    // ========================================================================
    // Punctuators / Operators
    // ========================================================================

    // Grouping
    l_paren, // (
    r_paren, // )
    l_bracket, // [
    r_bracket, // ]
    l_curly, // {
    r_curly, // }

    // Delimiters
    semicolon, // ;
    comma, // ,
    colon, // :
    dot, // .
    dot3, // ...

    // Comparison
    l_angle, // <
    r_angle, // >
    lt_eq, // <=
    gt_eq, // >=
    eq2, // ==
    neq, // !=
    eq3, // ===
    neq2, // !==

    // Arithmetic
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    star2, // **

    // Increment / Decrement
    plus2, // ++
    minus2, // --

    // Bitwise
    amp, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    shift_left, // <<
    shift_right, // >>
    shift_right3, // >>>

    // Logical
    amp2, // &&
    pipe2, // ||
    bang, // !

    // Nullish / Optional
    question, // ?
    question2, // ??
    question_dot, // ?.

    // Assignment
    eq, // =
    plus_eq, // +=
    minus_eq, // -=
    star_eq, // *=
    slash_eq, // /=
    percent_eq, // %=
    star2_eq, // **=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    shift_left_eq, // <<=
    shift_right_eq, // >>=
    shift_right3_eq, // >>>=
    amp2_eq, // &&=
    pipe2_eq, // ||=
    question2_eq, // ??=

    // Arrow
    arrow, // =>

    // Decorator
    at, // @

    // ========================================================================
    // Numeric Literals (세분화, D034)
    // 순서 중요: isNumericLiteral() range check에 사용
    // ========================================================================
    decimal, // 123
    float, // 1.5, .5
    binary, // 0b1010
    octal, // 0o77
    hex, // 0xFF
    positive_exponential, // 1e10, 1e+10
    negative_exponential, // 1e-10

    // BigInt Literals (numeric literals with 'n' suffix)
    decimal_bigint, // 123n
    binary_bigint, // 0b1010n
    octal_bigint, // 0o77n
    hex_bigint, // 0xFFn

    // ========================================================================
    // String Literals
    // ========================================================================
    string_literal,

    // ========================================================================
    // Regular Expression Literal
    // ========================================================================
    regexp,

    // ========================================================================
    // Template Literals
    // ========================================================================
    no_substitution_template, // `string`  (보간 없는 완전한 템플릿)
    template_head, // `text${
    template_middle, // }text${
    template_tail, // }text`

    // ========================================================================
    // JSX (D008)
    // ========================================================================
    jsx_text, // JSX 태그 사이 텍스트 (다른 렉싱 규칙 적용)
    jsx_identifier, // JSX 식별자 (하이픈 허용: data-value)

    // ========================================================================
    // Helper methods
    // ========================================================================

    /// ECMAScript reserved keyword인지 (await..with)
    pub fn isReservedKeyword(self: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(Kind.kw_await) and v <= @intFromEnum(Kind.kw_with);
    }

    /// Strict mode reserved word인지 (implements..yield)
    pub fn isStrictModeReserved(self: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(Kind.kw_implements) and v <= @intFromEnum(Kind.kw_yield);
    }

    /// TypeScript contextual keyword인지 (abstract..override)
    pub fn isTypeScriptKeyword(self: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(Kind.kw_abstract) and v <= @intFromEnum(Kind.kw_override);
    }

    /// 키워드인지 (reserved + contextual + strict + TS + literals)
    pub fn isKeyword(self: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(Kind.kw_await) and v <= @intFromEnum(Kind.kw_override);
    }

    /// Literal keyword인지 (true, false, null)
    pub fn isLiteralKeyword(self: Kind) bool {
        return self == .kw_true or self == .kw_false or self == .kw_null;
    }

    /// 숫자 리터럴인지 (decimal..hex_bigint)
    pub fn isNumericLiteral(self: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(Kind.decimal) and v <= @intFromEnum(Kind.hex_bigint);
    }

    /// BigInt 리터럴인지 (decimal_bigint..hex_bigint)
    pub fn isBigIntLiteral(self: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(Kind.decimal_bigint) and v <= @intFromEnum(Kind.hex_bigint);
    }

    /// 템플릿 리터럴인지
    pub fn isTemplateLiteral(self: Kind) bool {
        return self == .no_substitution_template or
            self == .template_head or
            self == .template_middle or
            self == .template_tail;
    }

    /// 대입 연산자인지 (=, +=, -=, ...)
    pub fn isAssignment(self: Kind) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(Kind.eq) and v <= @intFromEnum(Kind.question2_eq);
    }

    /// 이 토큰 뒤에 `/`가 나오면 regex로 해석해야 하는지.
    /// false면 division으로 해석.
    pub fn slashIsRegex(self: Kind) bool {
        return switch (self) {
            // 식별자/리터럴/닫는 괄호 뒤 → division
            .identifier,
            .private_identifier,
            .escaped_keyword,
            .kw_this,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_super,
            .r_paren,
            .r_bracket,
            .plus2,
            .minus2, // ++ --
            .string_literal,
            .regexp,
            .no_substitution_template,
            .template_tail,
            => false,

            // 숫자 리터럴 뒤 → division
            .decimal,
            .float,
            .binary,
            .octal,
            .hex,
            .positive_exponential,
            .negative_exponential,
            .decimal_bigint,
            .binary_bigint,
            .octal_bigint,
            .hex_bigint,
            => false,

            // 그 외 → regex
            // 연산자, 키워드(return, throw, yield 등), 여는 괄호, 세미콜론 등
            else => true,
        };
    }

    /// 토큰의 이름 문자열을 반환한다 (에러 메시지용).
    pub fn symbol(self: Kind) []const u8 {
        return token_names[@intFromEnum(self)];
    }
};

/// 키워드 문자열 → Kind 매핑 테이블.
/// 렉서가 식별자를 스캔한 후, 이 테이블에서 키워드인지 확인한다.
pub const keywords = std.StaticStringMap(Kind).initComptime(.{
    // ECMAScript Reserved Keywords
    .{ "await", .kw_await },
    .{ "break", .kw_break },
    .{ "case", .kw_case },
    .{ "catch", .kw_catch },
    .{ "class", .kw_class },
    .{ "const", .kw_const },
    .{ "continue", .kw_continue },
    .{ "debugger", .kw_debugger },
    .{ "default", .kw_default },
    .{ "delete", .kw_delete },
    .{ "do", .kw_do },
    .{ "else", .kw_else },
    .{ "enum", .kw_enum },
    .{ "export", .kw_export },
    .{ "extends", .kw_extends },
    .{ "finally", .kw_finally },
    .{ "for", .kw_for },
    .{ "function", .kw_function },
    .{ "if", .kw_if },
    .{ "import", .kw_import },
    .{ "in", .kw_in },
    .{ "instanceof", .kw_instanceof },
    .{ "new", .kw_new },
    .{ "return", .kw_return },
    .{ "super", .kw_super },
    .{ "switch", .kw_switch },
    .{ "this", .kw_this },
    .{ "throw", .kw_throw },
    .{ "try", .kw_try },
    .{ "typeof", .kw_typeof },
    .{ "var", .kw_var },
    .{ "void", .kw_void },
    .{ "while", .kw_while },
    .{ "with", .kw_with },

    // Contextual Keywords
    .{ "async", .kw_async },
    .{ "from", .kw_from },
    .{ "get", .kw_get },
    .{ "meta", .kw_meta },
    .{ "of", .kw_of },
    .{ "set", .kw_set },
    .{ "target", .kw_target },
    .{ "accessor", .kw_accessor },
    .{ "source", .kw_source },
    .{ "defer", .kw_defer },
    .{ "using", .kw_using },
    .{ "let", .kw_let },

    // Strict Mode Reserved
    .{ "implements", .kw_implements },
    .{ "interface", .kw_interface },
    .{ "package", .kw_package },
    .{ "private", .kw_private },
    .{ "protected", .kw_protected },
    .{ "public", .kw_public },
    .{ "static", .kw_static },
    .{ "yield", .kw_yield },

    // Literal Keywords
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "null", .kw_null },

    // TypeScript Contextual Keywords
    .{ "abstract", .kw_abstract },
    .{ "any", .kw_any },
    .{ "as", .kw_as },
    .{ "asserts", .kw_asserts },
    .{ "assert", .kw_assert },
    .{ "bigint", .kw_bigint },
    .{ "boolean", .kw_boolean },
    .{ "constructor", .kw_constructor },
    .{ "declare", .kw_declare },
    .{ "global", .kw_global },
    .{ "infer", .kw_infer },
    .{ "intrinsic", .kw_intrinsic },
    .{ "is", .kw_is },
    .{ "keyof", .kw_keyof },
    .{ "module", .kw_module },
    .{ "namespace", .kw_namespace },
    .{ "never", .kw_never },
    .{ "number", .kw_number },
    .{ "object", .kw_object },
    .{ "out", .kw_out },
    .{ "readonly", .kw_readonly },
    .{ "require", .kw_require },
    .{ "satisfies", .kw_satisfies },
    .{ "string", .kw_string },
    .{ "symbol", .kw_symbol },
    .{ "type", .kw_type },
    .{ "undefined", .kw_undefined },
    .{ "unique", .kw_unique },
    .{ "unknown", .kw_unknown },
    .{ "override", .kw_override },
});

/// 각 토큰 종류의 표시 이름 (에러 메시지, 디버깅용).
/// Kind enum의 u8 값으로 인덱싱.
const token_names = blk: {
    const enum_fields = @typeInfo(Kind).@"enum".fields;
    var names: [enum_fields.len][]const u8 = undefined;
    for (enum_fields) |field| {
        names[field.value] = switch (@as(Kind, @enumFromInt(field.value))) {
            .eof => "<eof>",
            .undetermined => "<undetermined>",
            .syntax_error => "<syntax error>",
            .hashbang_comment => "#!",
            .identifier => "<identifier>",
            .private_identifier => "<private identifier>",
            .escaped_keyword => "<escaped keyword>",
            // Punctuators
            .l_paren => "(",
            .r_paren => ")",
            .l_bracket => "[",
            .r_bracket => "]",
            .l_curly => "{",
            .r_curly => "}",
            .semicolon => ";",
            .comma => ",",
            .colon => ":",
            .dot => ".",
            .dot3 => "...",
            .l_angle => "<",
            .r_angle => ">",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .eq2 => "==",
            .neq => "!=",
            .eq3 => "===",
            .neq2 => "!==",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .star2 => "**",
            .plus2 => "++",
            .minus2 => "--",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .tilde => "~",
            .shift_left => "<<",
            .shift_right => ">>",
            .shift_right3 => ">>>",
            .amp2 => "&&",
            .pipe2 => "||",
            .bang => "!",
            .question => "?",
            .question2 => "??",
            .question_dot => "?.",
            .eq => "=",
            .plus_eq => "+=",
            .minus_eq => "-=",
            .star_eq => "*=",
            .slash_eq => "/=",
            .percent_eq => "%=",
            .star2_eq => "**=",
            .amp_eq => "&=",
            .pipe_eq => "|=",
            .caret_eq => "^=",
            .shift_left_eq => "<<=",
            .shift_right_eq => ">>=",
            .shift_right3_eq => ">>>=",
            .amp2_eq => "&&=",
            .pipe2_eq => "||=",
            .question2_eq => "??=",
            .arrow => "=>",
            .at => "@",
            // Literals
            .decimal => "<decimal>",
            .float => "<float>",
            .binary => "<binary>",
            .octal => "<octal>",
            .hex => "<hex>",
            .positive_exponential => "<exponential>",
            .negative_exponential => "<exponential>",
            .decimal_bigint => "<bigint>",
            .binary_bigint => "<bigint>",
            .octal_bigint => "<bigint>",
            .hex_bigint => "<bigint>",
            .string_literal => "<string>",
            .regexp => "<regexp>",
            .no_substitution_template => "<template>",
            .template_head => "<template head>",
            .template_middle => "<template middle>",
            .template_tail => "<template tail>",
            // JSX
            .jsx_text => "<jsx text>",
            .jsx_identifier => "<jsx identifier>",
            // Keywords — 키워드 이름 그대로 사용
            else => field.name,
        };
    }
    break :blk names;
};

// ============================================================
// Tests
// ============================================================

test "Kind fits in u8" {
    // 토큰 종류가 256개 이내인지 확인 (u8 범위)
    const fields = @typeInfo(Kind).@"enum".fields;
    try std.testing.expect(fields.len <= 256);
}

test "Kind.isReservedKeyword" {
    try std.testing.expect(Kind.kw_break.isReservedKeyword());
    try std.testing.expect(Kind.kw_with.isReservedKeyword());
    try std.testing.expect(Kind.kw_await.isReservedKeyword());
    try std.testing.expect(!Kind.kw_async.isReservedKeyword());
    try std.testing.expect(!Kind.identifier.isReservedKeyword());
    try std.testing.expect(!Kind.kw_abstract.isReservedKeyword());
}

test "Kind.isStrictModeReserved" {
    try std.testing.expect(Kind.kw_implements.isStrictModeReserved());
    try std.testing.expect(Kind.kw_yield.isStrictModeReserved());
    try std.testing.expect(Kind.kw_public.isStrictModeReserved());
    try std.testing.expect(!Kind.kw_break.isStrictModeReserved());
    try std.testing.expect(!Kind.kw_async.isStrictModeReserved());
}

test "Kind.isTypeScriptKeyword" {
    try std.testing.expect(Kind.kw_abstract.isTypeScriptKeyword());
    try std.testing.expect(Kind.kw_override.isTypeScriptKeyword());
    try std.testing.expect(Kind.kw_readonly.isTypeScriptKeyword());
    try std.testing.expect(!Kind.kw_break.isTypeScriptKeyword());
    try std.testing.expect(!Kind.kw_async.isTypeScriptKeyword());
}

test "Kind.isKeyword covers all keyword ranges" {
    try std.testing.expect(Kind.kw_await.isKeyword());
    try std.testing.expect(Kind.kw_with.isKeyword());
    try std.testing.expect(Kind.kw_async.isKeyword());
    try std.testing.expect(Kind.kw_yield.isKeyword());
    try std.testing.expect(Kind.kw_true.isKeyword());
    try std.testing.expect(Kind.kw_null.isKeyword());
    try std.testing.expect(Kind.kw_abstract.isKeyword());
    try std.testing.expect(Kind.kw_override.isKeyword());
    try std.testing.expect(!Kind.identifier.isKeyword());
    try std.testing.expect(!Kind.plus.isKeyword());
}

test "Kind.isNumericLiteral" {
    try std.testing.expect(Kind.decimal.isNumericLiteral());
    try std.testing.expect(Kind.hex.isNumericLiteral());
    try std.testing.expect(Kind.hex_bigint.isNumericLiteral());
    try std.testing.expect(!Kind.string_literal.isNumericLiteral());
    try std.testing.expect(!Kind.identifier.isNumericLiteral());
}

test "Kind.isBigIntLiteral" {
    try std.testing.expect(Kind.decimal_bigint.isBigIntLiteral());
    try std.testing.expect(Kind.hex_bigint.isBigIntLiteral());
    try std.testing.expect(!Kind.decimal.isBigIntLiteral());
    try std.testing.expect(!Kind.float.isBigIntLiteral());
}

test "Kind.isAssignment" {
    try std.testing.expect(Kind.eq.isAssignment());
    try std.testing.expect(Kind.plus_eq.isAssignment());
    try std.testing.expect(Kind.question2_eq.isAssignment());
    try std.testing.expect(!Kind.plus.isAssignment());
    try std.testing.expect(!Kind.eq2.isAssignment());
}

test "Kind.slashIsRegex" {
    // 식별자/리터럴 뒤 → division (false)
    try std.testing.expect(!Kind.identifier.slashIsRegex());
    try std.testing.expect(!Kind.decimal.slashIsRegex());
    try std.testing.expect(!Kind.string_literal.slashIsRegex());
    try std.testing.expect(!Kind.r_paren.slashIsRegex());
    try std.testing.expect(!Kind.kw_this.slashIsRegex());

    // 연산자/키워드 뒤 → regex (true)
    try std.testing.expect(Kind.eq.slashIsRegex());
    try std.testing.expect(Kind.l_paren.slashIsRegex());
    try std.testing.expect(Kind.semicolon.slashIsRegex());
    try std.testing.expect(Kind.kw_return.slashIsRegex());
    try std.testing.expect(Kind.comma.slashIsRegex());
    try std.testing.expect(Kind.eof.slashIsRegex());
}

test "Kind.symbol returns readable name" {
    try std.testing.expectEqualStrings("(", Kind.l_paren.symbol());
    try std.testing.expectEqualStrings("<eof>", Kind.eof.symbol());
    try std.testing.expectEqualStrings("<identifier>", Kind.identifier.symbol());
    try std.testing.expectEqualStrings("=>", Kind.arrow.symbol());
    try std.testing.expectEqualStrings("===", Kind.eq3.symbol());
}

test "keywords map lookup" {
    try std.testing.expectEqual(Kind.kw_break, keywords.get("break").?);
    try std.testing.expectEqual(Kind.kw_const, keywords.get("const").?);
    try std.testing.expectEqual(Kind.kw_abstract, keywords.get("abstract").?);
    try std.testing.expectEqual(Kind.kw_readonly, keywords.get("readonly").?);
    try std.testing.expect(keywords.get("notakeyword") == null);
    try std.testing.expect(keywords.get("foo") == null);
}

test "Span.len and merge" {
    const a = Span{ .start = 5, .end = 10 };
    const b = Span{ .start = 10, .end = 20 };
    try std.testing.expectEqual(@as(u32, 5), a.len());
    const merged = a.merge(b);
    try std.testing.expectEqual(@as(u32, 5), merged.start);
    try std.testing.expectEqual(@as(u32, 20), merged.end);
}

test "Token default values" {
    const tok = Token{};
    try std.testing.expectEqual(Kind.eof, tok.kind);
    try std.testing.expect(!tok.has_newline_before);
    try std.testing.expect(!tok.has_pure_comment_before);
}
