//! TypeScript 파싱
//!
//! TS 타입 어노테이션, 선언(interface, type alias, enum, namespace),
//! decorator, 제네릭 파라미터를 파싱하는 함수들.
//! oxc의 ts/types.rs + ts/statement.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/ts/types.rs
//! - references/oxc/crates/oxc_parser/src/ts/statement.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

// ================================================================
// TypeScript Declarations
// ================================================================

/// type Foo = Type;
pub fn parseTsTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'type'

    const name = try self.parseSimpleIdentifier();

    // 제네릭 파라미터: type Foo<T> = ...
    var type_params = NodeIndex.none;
    if (self.current() == .l_angle) {
        type_params = try parseTsTypeParameterDeclaration(self);
    }

    try self.expect(.eq);
    const ty = try parseType(self);
    _ = try self.eat(.semicolon);

    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(@intFromEnum(type_params));
    _ = try self.ast.addExtra(@intFromEnum(ty));

    return try self.ast.addNode(.{
        .tag = .ts_type_alias_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// interface Foo { ... }
/// interface Foo extends Bar, Baz { ... }
/// extra = [name, type_params, extends_start, extends_len, body]
pub fn parseTsInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'interface'

    const name = try self.parseSimpleIdentifier();

    // 제네릭 파라미터
    var type_params = NodeIndex.none;
    if (self.current() == .l_angle) {
        type_params = try parseTsTypeParameterDeclaration(self);
    }

    // extends (콤마 구분 리스트: interface Foo extends Bar, Baz)
    // NodeList(start, len)로 저장하여 다중 extends를 지원한다.
    // extends 없으면 extends_list.len = 0.
    const scratch_top = self.saveScratch();
    if (try self.eat(.kw_extends)) {
        const first = try parseType(self);
        try self.scratch.append(self.allocator, first);
        while (try self.eat(.comma)) {
            const next = try parseType(self);
            try self.scratch.append(self.allocator, next);
        }
    }
    const extends_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    // interface body
    const body = try parseObjectType(self);

    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(type_params),
        extends_list.start,
        extends_list.len,
        @intFromEnum(body),
    });

    return try self.ast.addNode(.{
        .tag = .ts_interface_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// const enum Foo { A, B, C }
/// const enum은 일반 enum과 동일하게 파싱하되, flags=1로 표시.
pub fn parseConstEnum(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'const'
    return parseTsEnumDeclarationWithFlags(self, 1);
}

/// enum Foo { A, B, C }
pub fn parseTsEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
    return parseTsEnumDeclarationWithFlags(self, 0);
}

/// enum 파싱. flags: 0=일반 enum, 1=const enum.
/// extra = [name, members_start, members_len, flags]
fn parseTsEnumDeclarationWithFlags(self: *Parser, flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'enum'

    const name = try self.parseSimpleIdentifier();
    try self.expect(.l_curly);

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const member = try parseTsEnumMember(self);
        try self.scratch.append(self.allocator, member);
        if (!try self.eat(.comma)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name), members.start, members.len, flags,
    });

    return try self.ast.addNode(.{
        .tag = .ts_enum_declaration,
        .span = .{ .start = start, .end = end },
        .data = .{ .extra = extra_start },
    });
}

fn parseTsEnumMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const name = try self.parsePropertyKey();

    var init_val = NodeIndex.none;
    if (try self.eat(.eq)) {
        init_val = try self.parseAssignmentExpression();
    }

    return try self.ast.addNode(.{
        .tag = .ts_enum_member,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = init_val, .flags = 0 } },
    });
}

/// namespace Foo { ... } / module "name" { ... }
pub fn parseTsModuleDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip 'namespace' or 'module'
    return parseTsModuleBody(self, start);
}

/// namespace body (재귀: A.B.C 중첩 처리). keyword는 이미 소비된 상태.
/// `declare module "*.css" { ... }` 처럼 문자열 리터럴 모듈 이름도 지원.
fn parseTsModuleBody(self: *Parser, start: u32) ParseError2!NodeIndex {
    // declare module "name" { ... } — 문자열 리터럴 모듈 이름 (ambient module declaration)
    if (self.current() == .string_literal) {
        const str_node = try self.ast.addNode(.{
            .tag = .string_literal,
            .span = self.currentSpan(),
            .data = .{ .none = 0 },
        });
        try self.advance();
        // 문자열 모듈 이름은 flags=1로 표시하여 ambient임을 알림
        const body = try self.parseBlockStatement();
        return try self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = str_node, .right = body, .flags = 1 } },
        });
    }
    const name = try self.parseSimpleIdentifier();

    // 중첩: namespace A.B.C { }
    if (try self.eat(.dot)) {
        const inner = try parseTsModuleBody(self, start);
        return try self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = inner, .flags = 0 } },
        });
    }

    const body = try self.parseBlockStatement();

    return try self.ast.addNode(.{
        .tag = .ts_module_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = body, .flags = 0 } },
    });
}

/// declare var/let/const/function/class/...
pub fn parseTsDeclareStatement(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'declare'
    // declare 뒤의 선언은 ambient context (const 이니셜라이저 불필요 등)
    const saved = self.ctx;
    self.ctx.in_ambient = true;
    const result = try self.parseStatement();
    self.ctx = saved;
    return result;
}

/// abstract class Foo { }
pub fn parseTsAbstractClass(self: *Parser) ParseError2!NodeIndex {
    try self.advance(); // skip 'abstract'
    return self.parseClassDeclaration();
}

/// @decorator 파싱 후 class/export 문을 파싱
pub fn parseDecoratedStatement(self: *Parser) ParseError2!NodeIndex {
    // 데코레이터 수집
    const scratch_top = self.saveScratch();
    while (self.current() == .at) {
        const dec = try parseDecorator(self);
        try self.scratch.append(self.allocator, dec);
    }
    const decorators = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    // 데코레이터 뒤에 올 수 있는 것: class, export, abstract
    return switch (self.current()) {
        .kw_class => self.parseClassWithDecorators(.class_declaration, decorators),
        .kw_export => self.parseExportDeclaration(),
        .kw_abstract => parseTsAbstractClass(self),
        else => {
            try self.addError(self.currentSpan(), "Class or export expected after decorator");
            return self.parseExpressionStatement();
        },
    };
}

/// @expr — 단일 데코레이터 파싱
pub fn parseDecorator(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip @
    const expr = try self.parseCallExpression();

    return try self.ast.addNode(.{
        .tag = .decorator,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
    });
}

// ================================================================
// TypeScript Type Parameters
// ================================================================

/// <T, U extends V = W>
pub fn parseTsTypeParameterDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip <

    const scratch_top = self.saveScratch();
    while (self.current() != .r_angle and self.current() != .eof) {
        const param = try parseTsTypeParameter(self);
        try self.scratch.append(self.allocator, param);
        if (!try self.eat(.comma)) break;
    }
    try self.expect(.r_angle);

    const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_type_parameter_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = params },
    });
}

fn parseTsTypeParameter(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const name = try self.parseSimpleIdentifier();

    // T extends U
    var constraint = NodeIndex.none;
    if (try self.eat(.kw_extends)) {
        constraint = try parseType(self);
    }

    // T = DefaultType
    var default_type = NodeIndex.none;
    if (try self.eat(.eq)) {
        default_type = try parseType(self);
    }

    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(@intFromEnum(constraint));
    _ = try self.ast.addExtra(@intFromEnum(default_type));

    return try self.ast.addNode(.{
        .tag = .ts_type_parameter,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

// ================================================================
// TypeScript Type 파싱
// ================================================================

/// `: Type` 어노테이션이 있으면 파싱하고 노드 반환. 없으면 none.
pub fn tryParseTypeAnnotation(self: *Parser) ParseError2!NodeIndex {
    if (self.current() != .colon) return NodeIndex.none;
    // 타입 어노테이션이 아닌 colon인 경우 구분 필요:
    // object literal `{ key: value }`, ternary `? : `, switch `case:` 등
    // 여기서는 binding pattern/variable declarator 컨텍스트에서만 호출되므로 안전
    try self.advance(); // skip ':'
    return parseType(self);
}

/// 리턴 타입 어노테이션 (`: Type`). 함수 선언에서 사용.
pub fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
    if (self.current() != .colon) return NodeIndex.none;
    try self.advance();
    return parseType(self);
}

/// TS 타입을 파싱한다. 유니온/인터섹션을 포함.
pub fn parseType(self: *Parser) ParseError2!NodeIndex {
    var left = try parseIntersectionType(self);

    // 유니온: A | B | C
    while (self.current() == .pipe) {
        const start = self.ast.getNode(left).span.start;
        try self.advance(); // skip |
        const right = try parseIntersectionType(self);
        left = try self.ast.addNode(.{
            .tag = .ts_union_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
        });
    }

    return left;
}

fn parseIntersectionType(self: *Parser) ParseError2!NodeIndex {
    var left = try parsePostfixType(self);

    // 인터섹션: A & B & C
    while (self.current() == .amp) {
        const start = self.ast.getNode(left).span.start;
        try self.advance(); // skip &
        const right = try parsePostfixType(self);
        left = try self.ast.addNode(.{
            .tag = .ts_intersection_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
        });
    }

    return left;
}

fn parsePostfixType(self: *Parser) ParseError2!NodeIndex {
    var base = try parsePrimaryType(self);

    while (self.current() == .l_bracket) {
        const start = self.ast.getNode(base).span.start;
        if (try self.peekNextKind() == .r_bracket) {
            // 배열 타입: T[]
            try self.advance(); // [
            try self.advance(); // ]
            base = try self.ast.addNode(.{
                .tag = .ts_array_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = base, .flags = 0 } },
            });
        } else {
            // 인덱스 접근 타입: T[K]
            try self.advance(); // [
            const index_type = try parseType(self);
            try self.expect(.r_bracket);
            base = try self.ast.addNode(.{
                .tag = .ts_indexed_access_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = base, .right = index_type, .flags = 0 } },
            });
        }
    }

    return base;
}

fn parsePrimaryType(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();

    // TS 키워드 타입
    if (self.current().isTypeScriptKeyword()) {
        const tag: Tag = switch (self.current()) {
            .kw_any => .ts_any_keyword,
            .kw_string => .ts_string_keyword,
            .kw_number => .ts_number_keyword,
            .kw_boolean => .ts_boolean_keyword,
            .kw_bigint => .ts_bigint_keyword,
            .kw_symbol => .ts_symbol_keyword,
            .kw_object => .ts_object_keyword,
            .kw_never => .ts_never_keyword,
            .kw_unknown => .ts_unknown_keyword,
            .kw_undefined => .ts_undefined_keyword,
            else => .ts_type_reference, // 다른 TS 키워드는 타입 참조로
        };
        if (tag != .ts_type_reference) {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = tag,
                .span = span,
                .data = .{ .none = 0 },
            });
        }
    }

    switch (self.current()) {
        // void
        .kw_void => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_void_keyword,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // null
        .kw_null => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_null_keyword,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // this
        .kw_this => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_this_type,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        // 리터럴 타입 (true, false, 숫자, 문자열)
        .kw_true, .kw_false => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_literal_type,
                .span = span,
                .data = .{ .none = 0 },
            });
        },
        .decimal, .float, .hex, .string_literal => {
            try self.advance();
            return try self.ast.addNode(.{
                .tag = .ts_literal_type,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        // 타입 참조: Foo, Foo.Bar, Foo<T>
        .identifier => return parseTypeReference(self),
        // 괄호 타입: (Type) 또는 함수 타입: (a: T) => R
        .l_paren => return parseParenOrFunctionType(self),
        // 객체 타입 리터럴: { x: number, y: string }
        .l_curly => return parseObjectType(self),
        // 튜플 타입: [T, U]
        .l_bracket => return parseTupleType(self),
        // typeof T
        .kw_typeof => {
            try self.advance();
            const operand = try parseType(self);
            return try self.ast.addNode(.{
                .tag = .ts_type_query,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
            });
        },
        // keyof T
        .kw_keyof => {
            try self.advance();
            const operand = try parseType(self);
            return try self.ast.addNode(.{
                .tag = .ts_type_operator,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
            });
        },
        else => {
            // 다른 TS 키워드가 타입 위치에 온 경우 타입 참조로 처리
            if (self.current().isKeyword()) {
                return parseTypeReference(self);
            }
            try self.addError(span, "Type expected");
            try self.advance();
            return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
        },
    }
}

fn parseTypeReference(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    const name_span = self.currentSpan();
    try self.advance(); // type name

    // Foo.Bar 형태
    var name_end = name_span.end;
    while (try self.eat(.dot)) {
        name_end = self.currentSpan().end;
        try self.advance(); // Bar
    }

    // 제네릭: Foo<T, U>
    var type_args = NodeIndex.none;
    if (self.current() == .l_angle) {
        type_args = try parseTypeArguments(self);
    }

    const extra_start = try self.ast.addExtra(name_span.start);
    _ = try self.ast.addExtra(name_end);
    _ = try self.ast.addExtra(@intFromEnum(type_args));

    return try self.ast.addNode(.{
        .tag = .ts_type_reference,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseTypeArguments(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip <

    const scratch_top = self.saveScratch();
    while (self.current() != .r_angle and self.current() != .eof) {
        const ty = try parseType(self);
        try self.scratch.append(self.allocator, ty);
        if (!try self.eat(.comma)) break;
    }
    try self.expect(.r_angle);

    const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_type_parameter_instantiation,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = types },
    });
}

fn parseParenOrFunctionType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip (

    // 빈 괄호 + => → 함수 타입 () => R
    if (self.current() == .r_paren) {
        try self.advance();
        if (self.current() == .arrow) {
            try self.advance();
            const return_type = try parseType(self);
            return try self.ast.addNode(.{
                .tag = .ts_function_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = return_type, .flags = 0 } },
            });
        }
        // 빈 괄호 — 에러 또는 void
        return try self.ast.addNode(.{ .tag = .ts_void_keyword, .span = .{ .start = start, .end = self.currentSpan().start }, .data = .{ .none = 0 } });
    }

    // 파라미터가 있는 경우 — 단순히 첫 번째 타입을 파싱하고 ) 뒤에 =>가 있으면 함수 타입
    const inner = try parseType(self);
    if (self.current() == .r_paren) {
        try self.advance();
        if (self.current() == .arrow) {
            try self.advance();
            const return_type = try parseType(self);
            return try self.ast.addNode(.{
                .tag = .ts_function_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = inner, .right = return_type, .flags = 0 } },
            });
        }
    } else {
        try self.expect(.r_paren);
    }

    // 괄호 타입: (Type)
    return try self.ast.addNode(.{
        .tag = .ts_parenthesized_type,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
    });
}

fn parseObjectType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip {

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        const member = try parseTypeMember(self);
        try self.scratch.append(self.allocator, member);
        // ; 또는 , 로 구분
        if (!try self.eat(.semicolon) and !try self.eat(.comma)) {
            if (self.current() != .r_curly) break;
        }
    }

    const end = self.currentSpan().end;
    try self.expect(.r_curly);

    const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_type_literal,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = members },
    });
}

fn parseTypeMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // 간단: key: Type 또는 key?: Type
    const key = try self.parsePropertyKey();
    _ = try self.eat(.question); // optional
    try self.expect(.colon);
    const value_type = try parseType(self);

    return try self.ast.addNode(.{
        .tag = .ts_property_signature,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = key, .right = value_type, .flags = 0 } },
    });
}

fn parseTupleType(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.advance(); // skip [

    const scratch_top = self.saveScratch();
    while (self.current() != .r_bracket and self.current() != .eof) {
        const ty = try parseType(self);
        try self.scratch.append(self.allocator, ty);
        if (!try self.eat(.comma)) break;
    }

    const end = self.currentSpan().end;
    try self.expect(.r_bracket);

    const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .ts_tuple_type,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = types },
    });
}
