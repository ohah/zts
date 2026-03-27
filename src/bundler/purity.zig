//! ZTS Bundler — Expression Purity Analysis
//!
//! tree_shaker(모듈 수준)와 statement_shaker(문 수준) 양쪽에서 공유하는
//! 표현식 순수성 판정 로직. 순수 표현식은 side effect가 없어 안전하게 제거 가능.
//!
//! 판정 기준 (esbuild/rolldown 동일):
//!   - 리터럴, 식별자 참조, 함수/arrow 표현식 → 순수
//!   - 객체/배열 리터럴 → 원소가 모두 순수이면 순수 (computed key, spread 제외)
//!   - 삼항/이항/논리/단항 → 재귀 검사 (delete 제외)
//!   - 멤버 접근 → 순수 (getter side effect는 실전에서 극히 드물어 무시, esbuild 동일)
//!   - @__PURE__ call/new → 순수
//!   - 나머지 → 보수적으로 불순

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const CallFlags = @import("../parser/ast.zig").CallFlags;
const Token = @import("../lexer/token.zig");

/// 재귀 깊이 제한. 초과 시 보수적으로 불순 처리.
const max_depth: u32 = 128;

/// NodeIndex를 받아 순수성을 판정한다.
pub fn isExprPure(ast: *const Ast, idx: NodeIndex) bool {
    return isExprPureDepth(ast, idx, 0);
}

fn isExprPureDepth(ast: *const Ast, idx: NodeIndex, depth: u32) bool {
    if (depth >= max_depth) return false;
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return true;
    return isNodePureDepth(ast, ast.nodes.items[@intFromEnum(idx)], depth);
}

/// Node를 받아 순수성을 판정한다.
pub fn isNodePure(ast: *const Ast, node: Node) bool {
    return isNodePureDepth(ast, node, 0);
}

fn isNodePureDepth(ast: *const Ast, node: Node, depth: u32) bool {
    if (depth >= max_depth) return false;
    const d = depth + 1;
    return switch (node.tag) {
        .boolean_literal,
        .null_literal,
        .numeric_literal,
        .string_literal,
        .bigint_literal,
        .regexp_literal,
        => true,

        .identifier_reference => true,

        .function_expression,
        .arrow_function_expression,
        => true,

        // class expression — extends/static 초기화에 side effect 가능
        .class_expression => false,

        .object_expression => isObjectPure(ast, node, d),
        .array_expression => isArrayPure(ast, node, d),

        .call_expression, .new_expression => {
            if (ast.hasExtra(node.data.extra, 3)) {
                return (ast.readExtra(node.data.extra, 3) & CallFlags.is_pure) != 0;
            }
            return false;
        },

        .parenthesized_expression => isExprPureDepth(ast, node.data.unary.operand, d),

        .conditional_expression => {
            const t = node.data.ternary;
            return isExprPureDepth(ast, t.a, d) and isExprPureDepth(ast, t.b, d) and isExprPureDepth(ast, t.c, d);
        },

        .binary_expression, .logical_expression => {
            return isExprPureDepth(ast, node.data.binary.left, d) and
                isExprPureDepth(ast, node.data.binary.right, d);
        },

        .unary_expression => {
            const e = node.data.extra;
            if (!ast.hasExtra(e, 1)) return false;
            const op_kind: u8 = @truncate(ast.readExtra(e, 1) & 0xFF);
            if (op_kind == @intFromEnum(Token.Kind.kw_delete)) return false;
            return isExprPureDepth(ast, @enumFromInt(ast.readExtra(e, 0)), d);
        },

        // 멤버 접근 — getter side effect는 무시 (esbuild 동일)
        .static_member_expression, .computed_member_expression => true,

        else => false,
    };
}

fn isObjectPure(ast: *const Ast, node: Node, depth: u32) bool {
    const list = node.data.list;
    if (list.len == 0) return true;
    if (list.start + list.len > ast.extra_data.items.len) return false;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const prop_idx: NodeIndex = @enumFromInt(raw_idx);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) continue;
        const prop = ast.nodes.items[@intFromEnum(prop_idx)];
        if (prop.tag != .object_property) return false;
        const key_idx = prop.data.binary.left;
        if (!key_idx.isNone() and @intFromEnum(key_idx) < ast.nodes.items.len) {
            if (ast.nodes.items[@intFromEnum(key_idx)].tag == .computed_property_key) return false;
        }
        if (!isExprPureDepth(ast, prop.data.binary.right, depth)) return false;
    }
    return true;
}

fn isArrayPure(ast: *const Ast, node: Node, depth: u32) bool {
    const list = node.data.list;
    if (list.len == 0) return true;
    if (list.start + list.len > ast.extra_data.items.len) return false;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const elem_idx: NodeIndex = @enumFromInt(raw_idx);
        if (elem_idx.isNone() or @intFromEnum(elem_idx) >= ast.nodes.items.len) continue;
        const elem = ast.nodes.items[@intFromEnum(elem_idx)];
        if (elem.tag == .spread_element) return false;
        if (!isNodePureDepth(ast, elem, depth)) return false;
    }
    return true;
}

/// variable declaration의 순수성 판정.
/// 모든 declarator의 초기값이 순수이면 순수.
pub fn isVarDeclPure(ast: *const Ast, node: Node) bool {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return false;
    const list_start = ast.extra_data.items[e + 1];
    const list_len = ast.extra_data.items[e + 2];
    if (list_len == 0) return true;
    if (list_start + list_len > ast.extra_data.items.len) return false;
    const decls = ast.extra_data.items[list_start .. list_start + list_len];
    for (decls) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const decl = ast.nodes.items[@intFromEnum(idx)];
        if (decl.tag != .variable_declarator) return false;
        const de = decl.data.extra;
        if (de + 2 >= ast.extra_data.items.len) return false;
        const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de + 2]);
        if (init_idx.isNone()) continue;
        if (!isExprPure(ast, init_idx)) return false;
    }
    return true;
}

/// class declaration/expression의 side effect 판정.
/// extends 절이 없으면 순수 (esbuild보다 정밀, rolldown 동일).
pub fn classHasSideEffects(ast: *const Ast, node: Node) bool {
    const e = node.data.extra;
    if (e + 1 >= ast.extra_data.items.len) return true;
    const super_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 1]);
    return !super_idx.isNone();
}
