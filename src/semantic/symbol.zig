//! ZTS Semantic — 심볼 정의
//!
//! 최소 심볼 모델 (D053): name + scope_id + kind + flags + declaration_span.
//! 재선언 검증에 필요한 최소 정보만 저장.
//! references(참조 추적)는 Phase 6(minifier/bundler)에서 추가 예정.

const std = @import("std");
const ScopeId = @import("scope.zig").ScopeId;
const Span = @import("../lexer/token.zig").Span;

/// 심볼 인덱스. symbols 배열의 위치를 가리킨다.
pub const SymbolId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: SymbolId) bool {
        return self == .none;
    }
};

/// 심볼 종류. 재선언 규칙이 kind별로 다르다 (D053).
///
/// 재선언 규칙 요약:
///   var + var       → 허용 (같은 스코프에서도 가능)
///   var + function  → 허용 (함수 선언이 우선)
///   let + let       → 에러
///   let + const     → 에러
///   const + const   → 에러
///   var + let/const → 에러
///   function + let  → 에러
///   import + *      → 항상 에러
pub const SymbolKind = enum(u8) {
    /// var 선언 — 함수 스코프로 호이스팅, 재선언 허용
    variable_var,
    /// let 선언 — 블록 스코프, 재선언 불가
    variable_let,
    /// const 선언 — 블록 스코프, 재선언 불가, 재할당 불가
    variable_const,
    /// function 선언 — 함수 스코프로 호이스팅, 재선언 조건부 허용
    function_decl,
    /// generator function 선언 (function*) — 블록 스코프에서 lexical
    generator_decl,
    /// async function 선언 — 블록 스코프에서 lexical
    async_function_decl,
    /// async generator function 선언 (async function*) — 블록 스코프에서 lexical
    async_generator_decl,
    /// class 선언 — 블록 스코프, 재선언 불가
    class_decl,
    /// 함수 파라미터
    parameter,
    /// catch(e)의 e
    catch_binding,
    /// import { x }의 x — 재선언 불가, 재할당 불가
    import_binding,

    /// 블록 스코프 선언인지 (let/const/class/generator/async function/async generator)
    pub fn isBlockScoped(self: SymbolKind) bool {
        return switch (self) {
            .variable_let, .variable_const, .class_decl,
            .generator_decl, .async_function_decl, .async_generator_decl,
            => true,
            else => false,
        };
    }

    /// 같은 스코프에서 재선언 가능한지 (var, function만)
    /// generator/async function/async generator는 항상 블록 스코프에서 lexical이므로 재선언 불가
    pub fn allowsRedeclaration(self: SymbolKind) bool {
        return switch (self) {
            .variable_var, .function_decl => true,
            else => false,
        };
    }

    /// function-like 선언인지 (function, generator, async function, async generator)
    pub fn isFunctionLike(self: SymbolKind) bool {
        return switch (self) {
            .function_decl, .generator_decl, .async_function_decl, .async_generator_decl => true,
            else => false,
        };
    }
};

/// 심볼 플래그 (D053).
pub const SymbolFlags = packed struct(u16) {
    /// export된 심볼
    is_exported: bool = false,
    /// export default
    is_default_export: bool = false,
    /// 사용되지 않는 패딩 (Phase 6에서 is_reassigned, is_read 등 추가 예정)
    _padding: u14 = 0,
};

/// 심볼 하나의 데이터.
/// symbols[symbol_id]로 접근.
pub const Symbol = struct {
    /// 심볼 이름 — 소스 코드의 byte offset 범위 (zero-copy)
    name: Span,

    /// 심볼이 등록된 스코프 (var는 호이스팅된 var scope)
    scope_id: ScopeId,

    /// 원래 선언이 작성된 스코프 (var는 호이스팅 전 block scope).
    /// let/const/class 선언 시 같은 block의 var를 찾는 데 사용.
    /// var가 아닌 경우 scope_id와 동일.
    origin_scope: ScopeId = ScopeId.none,

    /// 선언 종류
    kind: SymbolKind,

    /// 플래그
    flags: SymbolFlags = .{},

    /// 선언 위치 (에러 메시지에서 "여기서 먼저 선언됨" 출력용)
    declaration_span: Span,

    /// 이 심볼의 이름을 소스에서 읽는다.
    pub fn nameText(self: *const Symbol, source: []const u8) []const u8 {
        return source[self.name.start..self.name.end];
    }
};

test "SymbolKind.isBlockScoped" {
    try std.testing.expect(SymbolKind.variable_let.isBlockScoped());
    try std.testing.expect(SymbolKind.variable_const.isBlockScoped());
    try std.testing.expect(SymbolKind.class_decl.isBlockScoped());
    try std.testing.expect(!SymbolKind.variable_var.isBlockScoped());
    try std.testing.expect(!SymbolKind.function_decl.isBlockScoped());
    try std.testing.expect(!SymbolKind.parameter.isBlockScoped());
}

test "SymbolKind.allowsRedeclaration" {
    try std.testing.expect(SymbolKind.variable_var.allowsRedeclaration());
    try std.testing.expect(SymbolKind.function_decl.allowsRedeclaration());
    try std.testing.expect(!SymbolKind.variable_let.allowsRedeclaration());
    try std.testing.expect(!SymbolKind.variable_const.allowsRedeclaration());
    try std.testing.expect(!SymbolKind.import_binding.allowsRedeclaration());
}
