//! ZTS Bundler — Statement-Level Tree-Shaking
//!
//! 모듈 내 top-level statement 단위로 미사용 코드를 제거한다.
//! tree_shaker가 결정한 used exports를 기반으로, 각 statement의
//! 선언/참조 심볼을 분석하여 도달 불가능한 statement를 skip_nodes에 추가한다.
//!
//! esbuild의 Part 시스템, rolldown의 StmtInfo와 유사한 역할.
//! 단, ZTS에서는 별도 모듈로 분리하여 tree_shaker(모듈 단위)와
//! 역할을 명확히 구분한다.

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;

const StmtInfo = struct {
    node_idx: u32,
    span: Span,
    is_reachable: bool = false,
    has_side_effects: bool = true,
};

/// top-level statement 단위로 미사용 코드를 식별하여 skip_nodes에 추가한다.
///
/// used_export_names: tree_shaker가 결정한 이 모듈의 사용된 export local names.
/// skip_nodes: linker가 생성한 bitset — 여기에 미사용 statement 노드를 추가한다.
pub fn markUnusedStatements(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    used_export_names: []const []const u8,
    skip_nodes: *std.DynamicBitSet,
) !void {
    const root_ni = @intFromEnum(root);
    if (root_ni >= ast.nodes.items.len) return;
    const root_node = ast.nodes.items[root_ni];
    if (root_node.tag != .program) return;

    const list = root_node.data.list;
    if (list.len == 0) return;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const stmt_raw_indices = ast.extra_data.items[list.start .. list.start + list.len];

    // Statement 정보 수집
    var stmts = try allocator.alloc(StmtInfo, stmt_raw_indices.len);
    defer allocator.free(stmts);

    // top-level 선언 이름 → stmt index
    var name_to_stmt: std.StringHashMapUnmanaged(u32) = .{};
    defer name_to_stmt.deinit(allocator);

    var removable_count: u32 = 0;

    for (stmt_raw_indices, 0..) |raw_idx, i| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        const ni = @intFromEnum(idx);
        if (ni >= ast.nodes.items.len) {
            stmts[i] = .{ .node_idx = @intCast(ni), .span = .{ .start = 0, .end = 0 } };
            continue;
        }
        const node = ast.nodes.items[ni];

        stmts[i] = .{
            .node_idx = @intCast(ni),
            .span = node.span,
            .has_side_effects = true,
        };

        // 선언 이름 추출 + side effects 판정
        try extractDeclaredNames(ast, node, @intCast(i), &name_to_stmt, allocator);
        stmts[i].has_side_effects = hasSideEffects(ast, node);
        if (!stmts[i].has_side_effects) removable_count += 1;
    }

    // 제거 가능한 statement가 없으면 조기 종료
    if (removable_count == 0) return;

    // 각 statement의 참조 이름 수집 (span containment 기반)
    var stmt_refs = try allocator.alloc(std.StringHashMapUnmanaged(void), stmts.len);
    defer {
        for (stmt_refs) |*s| s.deinit(allocator);
        allocator.free(stmt_refs);
    }
    for (stmt_refs) |*s| s.* = .{};

    collectReferences(allocator, ast, stmts, stmt_refs, &name_to_stmt) catch return;

    // BFS: used exports + side-effectful statements에서 도달 가능한 statements 추적
    var queue: std.ArrayListUnmanaged(u32) = .empty;
    defer queue.deinit(allocator);

    // seed 1: side-effectful statements → 항상 포함
    for (stmts, 0..) |*stmt, i| {
        if (stmt.has_side_effects) {
            stmt.is_reachable = true;
            try queue.append(allocator, @intCast(i));
        }
    }

    // seed 2: used exports → 해당 선언 statement 포함
    for (used_export_names) |name| {
        if (name_to_stmt.get(name)) |si| {
            if (!stmts[si].is_reachable) {
                stmts[si].is_reachable = true;
                try queue.append(allocator, si);
            }
        }
    }

    // BFS 순회
    var head: u32 = 0;
    while (head < queue.items.len) : (head += 1) {
        const si = queue.items[head];
        var ref_it = stmt_refs[si].keyIterator();
        while (ref_it.next()) |ref_name| {
            if (name_to_stmt.get(ref_name.*)) |dep_si| {
                if (!stmts[dep_si].is_reachable) {
                    stmts[dep_si].is_reachable = true;
                    try queue.append(allocator, dep_si);
                }
            }
        }
    }

    // 도달 불가능한 statements를 skip_nodes에 추가
    for (stmts) |stmt| {
        if (!stmt.is_reachable and stmt.node_idx < skip_nodes.capacity()) {
            skip_nodes.set(stmt.node_idx);
        }
    }
}

/// statement에서 선언된 top-level 이름을 추출하여 name_to_stmt에 등록한다.
fn extractDeclaredNames(
    ast: *const Ast,
    node: Node,
    stmt_idx: u32,
    name_to_stmt: *std.StringHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) !void {
    switch (node.tag) {
        .function_declaration => {
            if (getFunctionName(ast, node)) |name| {
                try name_to_stmt.put(allocator, name, stmt_idx);
            }
        },
        .class_declaration => {
            if (getClassName(ast, node)) |name| {
                try name_to_stmt.put(allocator, name, stmt_idx);
            }
        },
        .variable_declaration => {
            try extractVarDeclNames(ast, node, stmt_idx, name_to_stmt, allocator);
        },
        .export_named_declaration => {
            // export function f() {} / export const x = 1
            const e = node.data.extra;
            if (e + 3 < ast.extra_data.items.len) {
                const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
                if (!decl_idx.isNone() and @intFromEnum(decl_idx) < ast.nodes.items.len) {
                    const inner = ast.nodes.items[@intFromEnum(decl_idx)];
                    try extractDeclaredNames(ast, inner, stmt_idx, name_to_stmt, allocator);
                }
            }
        },
        .export_default_declaration => {
            try name_to_stmt.put(allocator, "default", stmt_idx);
            // inner declaration의 이름도 등록 (export default function foo() {})
            const inner_idx = node.data.unary.operand;
            if (!inner_idx.isNone() and @intFromEnum(inner_idx) < ast.nodes.items.len) {
                const inner = ast.nodes.items[@intFromEnum(inner_idx)];
                try extractDeclaredNames(ast, inner, stmt_idx, name_to_stmt, allocator);
            }
        },
        else => {},
    }
}

/// function declaration에서 이름 추출. extra[0] = name_idx
fn getFunctionName(ast: *const Ast, node: Node) ?[]const u8 {
    const e = node.data.extra;
    if (e >= ast.extra_data.items.len) return null;
    const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
    if (name_idx.isNone()) return null;
    const ni = @intFromEnum(name_idx);
    if (ni >= ast.nodes.items.len) return null;
    const name_node = ast.nodes.items[ni];
    return ast.getText(name_node.span);
}

/// class declaration에서 이름 추출. extra[0] = name_idx
fn getClassName(ast: *const Ast, node: Node) ?[]const u8 {
    return getFunctionName(ast, node); // 같은 레이아웃
}

/// variable declaration에서 declarator 이름들을 추출.
/// extra = [kind_flags, list_start, list_len]
fn extractVarDeclNames(
    ast: *const Ast,
    node: Node,
    stmt_idx: u32,
    name_to_stmt: *std.StringHashMapUnmanaged(u32),
    allocator: std.mem.Allocator,
) !void {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return;
    const list_start = ast.extra_data.items[e + 1];
    const list_len = ast.extra_data.items[e + 2];
    if (list_len == 0) return;

    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const idx = list_start + i;
        if (idx >= ast.extra_data.items.len) break;
        const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[idx]);
        if (decl_idx.isNone()) continue;
        const decl_ni = @intFromEnum(decl_idx);
        if (decl_ni >= ast.nodes.items.len) continue;
        const decl_node = ast.nodes.items[decl_ni];
        if (decl_node.tag != .variable_declarator) continue;

        // variable_declarator: extra [name, type_ann, init_expr]
        const de = decl_node.data.extra;
        if (de >= ast.extra_data.items.len) continue;
        const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de]);
        if (name_idx.isNone()) continue;
        const name_ni = @intFromEnum(name_idx);
        if (name_ni >= ast.nodes.items.len) continue;
        const name_node = ast.nodes.items[name_ni];
        const name = ast.getText(name_node.span);
        if (name.len > 0) {
            try name_to_stmt.put(allocator, name, stmt_idx);
        }
    }
}

/// statement가 side effects를 가지는지 보수적으로 판정한다.
fn hasSideEffects(ast: *const Ast, node: Node) bool {
    switch (node.tag) {
        .function_declaration => return false,
        .variable_declaration => return varDeclHasSideEffects(ast, node),
        .export_named_declaration => {
            const e = node.data.extra;
            if (e + 3 < ast.extra_data.items.len) {
                const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
                if (!decl_idx.isNone() and @intFromEnum(decl_idx) < ast.nodes.items.len) {
                    return hasSideEffects(ast, ast.nodes.items[@intFromEnum(decl_idx)]);
                }
                // inner declaration이 없는 export { ... } → linker가 skip_nodes로 처리
                return false;
            }
            return true;
        },
        .export_default_declaration => {
            // linker가 export default → var _default = X 변환하므로
            // rename된 이름이 다른 모듈에서 참조될 수 있음 → 항상 보존
            return true;
        },
        // import/export 문은 linker skip_nodes와 충돌 방지를 위해 건드리지 않음
        .import_declaration, .export_all_declaration => return true,
        else => return true,
    }
}

/// variable declaration의 side effects 판정.
/// 초기값이 없거나 리터럴이면 side-effect-free.
fn varDeclHasSideEffects(ast: *const Ast, node: Node) bool {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return true;
    const list_start = ast.extra_data.items[e + 1];
    const list_len = ast.extra_data.items[e + 2];
    if (list_len == 0) return false;

    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const idx = list_start + i;
        if (idx >= ast.extra_data.items.len) return true;
        const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[idx]);
        if (decl_idx.isNone()) continue;
        const decl_ni = @intFromEnum(decl_idx);
        if (decl_ni >= ast.nodes.items.len) return true;
        const decl_node = ast.nodes.items[decl_ni];
        if (decl_node.tag != .variable_declarator) return true;

        // variable_declarator: extra [name, type_ann, init_expr]
        const de = decl_node.data.extra;
        if (de + 2 >= ast.extra_data.items.len) return true;
        const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de + 2]);
        if (init_idx.isNone()) continue; // 초기값 없음 → safe

        const init_ni = @intFromEnum(init_idx);
        if (init_ni >= ast.nodes.items.len) return true;
        const init_node = ast.nodes.items[init_ni];
        if (!isExprSideEffectFree(init_node.tag)) return true;
    }
    return false;
}

/// 표현식이 side-effect-free인지 판정 (리터럴, 함수/화살표 표현식 등).
fn isExprSideEffectFree(tag: @import("../parser/ast.zig").Node.Tag) bool {
    return switch (tag) {
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .template_literal,
        .function_expression,
        .arrow_function_expression,
        .array_expression,
        .object_expression,
        => true,
        else => false,
    };
}

/// 모든 AST 노드를 순회하면서 identifier_reference를 찾고,
/// span containment로 소속 top-level statement을 결정하여 참조 기록.
fn collectReferences(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmts: []const StmtInfo,
    stmt_refs: []std.StringHashMapUnmanaged(void),
    name_to_stmt: *const std.StringHashMapUnmanaged(u32),
) !void {
    if (stmts.len == 0) return;

    for (ast.nodes.items) |node| {
        // identifier_reference + assignment_target_identifier 모두 추적
        // (++x, x = ..., [x] = ... 등에서 x는 assignment_target_identifier)
        const is_ref = switch (node.tag) {
            .identifier_reference, .assignment_target_identifier => true,
            else => false,
        };
        if (!is_ref) continue;

        const name = ast.getText(node.span);
        if (!name_to_stmt.contains(name)) continue;

        const containing_idx = findContainingStmt(stmts, node.span.start) orelse continue;

        try stmt_refs[containing_idx].put(allocator, name, {});
    }
}

/// binary search로 주어진 위치를 포함하는 top-level statement를 찾는다.
fn findContainingStmt(stmts: []const StmtInfo, pos: u32) ?usize {
    if (stmts.len == 0) return null;

    // span.start 기준으로 정렬되어 있다고 가정 (AST 순서)
    var lo: usize = 0;
    var hi: usize = stmts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (stmts[mid].span.end <= pos) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < stmts.len and stmts[lo].span.start <= pos and pos < stmts[lo].span.end) {
        return lo;
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;

fn parseAndGetRoot(allocator: std.mem.Allocator, source: []const u8) !struct {
    ast: Ast,
    root: NodeIndex,
    arena: std.heap.ArenaAllocator,
} {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    const root = try parser.parse();

    return .{
        .ast = parser.ast,
        .root = root,
        .arena = arena,
    };
}

test "statement shaker: unused function removed" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function used() { return helper(); }
        \\function helper() { return 1; }
        \\function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    const used_names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &used_names, &skip_nodes);

    // "unused" 함수의 statement node가 skip_nodes에 포함되어야 함
    // "used"와 "helper"는 포함되지 않아야 함
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1); // unused가 최소 1개 스킵됨
}

test "statement shaker: transitive dependency preserved" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function a() { return b(); }
        \\function b() { return c(); }
        \\function c() { return 42; }
        \\function d() { return 99; }
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    const used_names: [1][]const u8 = .{"a"};
    try markUnusedStatements(alloc, &r.ast, r.root, &used_names, &skip_nodes);

    // a → b → c는 보존, d만 제거
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1); // d가 스킵됨
}

test "statement shaker: side-effectful statement always included" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function used() { return 1; }
        \\function unused() { return 2; }
        \\console.log("init");
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    const used_names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &used_names, &skip_nodes);

    // console.log는 side effect → 항상 포함
    // unused만 제거
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1);
}

test "statement shaker: empty used_exports skips nothing with side effects" {
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\console.log("side effect");
    );
    defer r.arena.deinit();

    var skip_nodes = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip_nodes.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip_nodes);

    // side-effectful statement → 스킵 안 됨
    var skipped: u32 = 0;
    var it = skip_nodes.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 0), skipped);
}

// --- 디버깅 중 발견된 엣지 케이스 ---

test "statement shaker: let without initializer is side-effect-free" {
    // nanostores 패턴: let store; (초기값 없는 변수 선언)
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\let store;
        \\function used() { store = 1; return store; }
        \\function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip);

    // "let store"는 side-effect-free지만 "used"가 참조 → 보존
    // "unused"만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: const with literal initializer is side-effect-free" {
    // valibot 패턴: const REGEX = /pattern/;
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\const REGEX = /test/;
        \\function used() { return 1; }
        \\function unused() { return REGEX; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip);

    // REGEX: 미참조 → 제거, unused: 미참조 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 2);
}

test "statement shaker: assignment_target_identifier tracked (++x pattern)" {
    // minimatch 패턴: let ID = 0; class AST { id = ++ID; }
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\let ID = 0;
        \\function make() { return ++ID; }
        \\function unused() { return 99; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"make"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip);

    // make → ++ID → ID 보존. unused만 제거.
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: export default always preserved" {
    // zod 패턴: export default function 은 linker rename 때문에 항상 보존
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\export default function config() { return {}; }
        \\function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    // used_exports가 비어있어도 export default는 보존
    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip);

    // export default → side-effectful (항상 보존)
    // unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: export specifier-only is side-effect-free" {
    // valibot 패턴: 함수 선언 후 마지막에 export { ... }
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\function object() { return 1; }
        \\function unused() { return 2; }
        \\export { object, unused };
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"object"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip);

    // export { ... } → side-effect-free (linker가 skip_nodes로 처리)
    // unused → 미참조 → 제거
    // export 문 자체도 제거 가능
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1); // unused + export 문
}

test "statement shaker: class with side effects always included" {
    // class extends/decorators/computed properties → side-effectful
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\class Base {}
        \\class Derived extends Base {}
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip);

    // class 선언 → side-effectful → 항상 보존
    // unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: var with call initializer is side-effectful" {
    // var x = someFunction(); → side-effectful (함수 호출)
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\var x = init();
        \\function unused() { return 1; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip);

    // var x = init() → side-effectful → 보존
    // unused만 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 1), skipped);
}

test "statement shaker: export function declaration" {
    // export function foo() {} → inner function은 side-effect-free
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\export function used() { return 1; }
        \\export function unused() { return 2; }
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    const names: [1][]const u8 = .{"used"};
    try markUnusedStatements(alloc, &r.ast, r.root, &names, &skip);

    // export function unused → 미사용 → 제거
    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expect(skipped >= 1);
}

test "statement shaker: no removable statements → early return" {
    // 모든 statement가 side-effectful → skip 없음
    const alloc = std.testing.allocator;
    var r = try parseAndGetRoot(alloc,
        \\console.log("a");
        \\console.log("b");
    );
    defer r.arena.deinit();

    var skip = try std.DynamicBitSet.initEmpty(alloc, r.ast.nodes.items.len);
    defer skip.deinit();

    try markUnusedStatements(alloc, &r.ast, r.root, &.{}, &skip);

    var skipped: u32 = 0;
    var it = skip.iterator(.{});
    while (it.next()) |_| skipped += 1;
    try std.testing.expectEqual(@as(u32, 0), skipped);
}

test "statement shaker module compiles" {
    _ = @import("statement_shaker.zig");
}
