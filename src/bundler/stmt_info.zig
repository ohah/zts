//! ZTS Bundler — Statement Info (rolldown 방식)
//!
//! 각 top-level statement가 선언하는 심볼과 참조하는 심볼을 추적한다.
//! semantic analyzer의 symbol_ids (node_index → symbol_index) 매핑을 재활용.
//!
//! tree_shaker: import binding liveness 판정 (도달성 기반)
//! statement_shaker: 미사용 statement 제거 (skip_nodes)
//! emitter: used_names 정제

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const purity = @import("purity.zig");

pub const StmtInfo = struct {
    node_idx: u32,
    span: Span,
    has_side_effects: bool,
    /// 이 statement가 선언하는 top-level 심볼 인덱스들
    declared_symbols: []const u32,
    /// 이 statement가 참조하는 심볼 인덱스들 (자체 declared에 없는 것만)
    referenced_symbols: []const u32,
};

pub const ModuleStmtInfos = struct {
    stmts: []StmtInfo,
    /// symbol_index → stmt_index (선언 역매핑). 없으면 null.
    symbol_to_stmt: []const ?u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ModuleStmtInfos) void {
        for (self.stmts) |stmt| {
            self.allocator.free(stmt.declared_symbols);
            self.allocator.free(stmt.referenced_symbols);
        }
        self.allocator.free(self.stmts);
        self.allocator.free(self.symbol_to_stmt);
    }

    /// symbol_index가 선언된 statement 인덱스 반환.
    pub fn declaredStmtBySymbol(self: *const ModuleStmtInfos, sym_idx: u32) ?u32 {
        if (sym_idx >= self.symbol_to_stmt.len) return null;
        return self.symbol_to_stmt[sym_idx];
    }

    /// used exports에서 도달 가능한 심볼 set을 BFS로 계산.
    /// 반환: symbol_index → reachable 여부를 나타내는 bitset.
    pub fn computeReachable(
        self: *const ModuleStmtInfos,
        allocator: std.mem.Allocator,
        used_export_sym_indices: []const u32,
    ) !std.DynamicBitSet {
        var reachable_stmts = try std.DynamicBitSet.initEmpty(allocator, self.stmts.len);
        errdefer reachable_stmts.deinit();

        var queue: std.ArrayListUnmanaged(u32) = .empty;
        defer queue.deinit(allocator);

        // seed: side-effectful statements
        for (self.stmts, 0..) |stmt, i| {
            if (stmt.has_side_effects) {
                reachable_stmts.set(i);
                try queue.append(allocator, @intCast(i));
            }
        }

        // seed: used exports가 선언된 statements
        for (used_export_sym_indices) |sym_idx| {
            if (self.declaredStmtBySymbol(sym_idx)) |stmt_idx| {
                if (!reachable_stmts.isSet(stmt_idx)) {
                    reachable_stmts.set(stmt_idx);
                    try queue.append(allocator, stmt_idx);
                }
            }
        }

        // BFS: referenced_symbols → symbol_to_stmt → dependent statements
        var head: u32 = 0;
        while (head < queue.items.len) : (head += 1) {
            const stmt_idx = queue.items[head];
            for (self.stmts[stmt_idx].referenced_symbols) |ref_sym| {
                if (self.declaredStmtBySymbol(ref_sym)) |dep_stmt| {
                    if (!reachable_stmts.isSet(dep_stmt)) {
                        reachable_stmts.set(dep_stmt);
                        try queue.append(allocator, dep_stmt);
                    }
                }
            }
        }

        return reachable_stmts;
    }
};

/// AST + semantic data로부터 ModuleStmtInfos를 구축한다.
pub fn build(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    symbols: []const Symbol,
    symbol_ids: []const ?u32,
) !?ModuleStmtInfos {
    // program 노드 (마지막 노드)
    if (ast.nodes.items.len == 0) return null;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return null;

    const list = root.data.list;
    if (list.len == 0) return null;
    if (list.start + list.len > ast.extra_data.items.len) return null;
    const stmt_raw_indices = ast.extra_data.items[list.start .. list.start + list.len];

    var stmts = try allocator.alloc(StmtInfo, stmt_raw_indices.len);
    errdefer {
        for (stmts) |s| {
            allocator.free(s.declared_symbols);
            allocator.free(s.referenced_symbols);
        }
        allocator.free(stmts);
    }

    // symbol_to_stmt 역매핑
    var sym_to_stmt = try allocator.alloc(?u32, symbols.len);
    errdefer allocator.free(sym_to_stmt);
    for (sym_to_stmt) |*s| s.* = null;

    for (stmt_raw_indices, 0..) |raw_idx, stmt_i| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        const ni = @intFromEnum(idx);
        if (ni >= ast.nodes.items.len) {
            stmts[stmt_i] = .{
                .node_idx = @intCast(ni),
                .span = .{ .start = 0, .end = 0 },
                .has_side_effects = true,
                .declared_symbols = &.{},
                .referenced_symbols = &.{},
            };
            continue;
        }
        const node = ast.nodes.items[ni];

        // side-effects 판정: import는 side-effect-free (도달성 분석 핵심)
        const side_effects = if (node.tag == .import_declaration) false else hasSideEffects(ast, node);

        // 심볼 수집: 이 statement의 span 안에 있는 모든 노드의 symbol_ids
        var declared_buf: std.ArrayListUnmanaged(u32) = .empty;
        defer declared_buf.deinit(allocator);
        var referenced_buf: std.ArrayListUnmanaged(u32) = .empty;
        defer referenced_buf.deinit(allocator);

        // declared: top-level scope (scope_id == 0)에 선언된 심볼
        var declared_set = std.AutoHashMap(u32, void).init(allocator);
        defer declared_set.deinit();

        // 모든 노드를 순회하며 이 statement span 안의 심볼 수집
        for (ast.nodes.items, 0..) |n, node_i| {
            if (n.span.start < node.span.start or n.span.start >= node.span.end) continue;
            if (node_i >= symbol_ids.len) continue;
            const sym_idx = symbol_ids[node_i] orelse continue;
            if (sym_idx >= symbols.len) continue;

            const sym = &symbols[sym_idx];
            // top-level scope에 선언된 심볼 = declared
            if (@intFromEnum(sym.scope_id) == 0 and
                n.span.start >= sym.declaration_span.start and
                n.span.end <= sym.declaration_span.end)
            {
                if (!declared_set.contains(@intCast(sym_idx))) {
                    try declared_set.put(@intCast(sym_idx), {});
                    try declared_buf.append(allocator, @intCast(sym_idx));
                    // 역매핑 등록
                    if (sym_idx < sym_to_stmt.len) {
                        sym_to_stmt[sym_idx] = @intCast(stmt_i);
                    }
                }
            }
        }

        // referenced: identifier_reference + assignment_target_identifier 중 declared에 없는 것
        var referenced_set = std.AutoHashMap(u32, void).init(allocator);
        defer referenced_set.deinit();

        for (ast.nodes.items, 0..) |n, node_i| {
            if (n.span.start < node.span.start or n.span.start >= node.span.end) continue;
            const is_ref = switch (n.tag) {
                .identifier_reference, .assignment_target_identifier => true,
                else => false,
            };
            if (!is_ref) continue;
            if (node_i >= symbol_ids.len) continue;
            const sym_idx = symbol_ids[node_i] orelse continue;
            if (sym_idx >= symbols.len) continue;
            if (declared_set.contains(@intCast(sym_idx))) continue;
            if (!referenced_set.contains(@intCast(sym_idx))) {
                try referenced_set.put(@intCast(sym_idx), {});
                try referenced_buf.append(allocator, @intCast(sym_idx));
            }
        }

        stmts[stmt_i] = .{
            .node_idx = @intCast(ni),
            .span = node.span,
            .has_side_effects = side_effects,
            .declared_symbols = try allocator.dupe(u32, declared_buf.items),
            .referenced_symbols = try allocator.dupe(u32, referenced_buf.items),
        };
    }

    return .{
        .stmts = stmts,
        .symbol_to_stmt = sym_to_stmt,
        .allocator = allocator,
    };
}

/// statement가 side effects를 가지는지 판정 (purity.zig 활용).
fn hasSideEffects(ast: *const Ast, node: Node) bool {
    switch (node.tag) {
        .function_declaration => return false,
        .class_declaration => return purity.classHasSideEffects(ast, node),
        .variable_declaration => return !purity.isVarDeclPure(ast, node),
        .export_named_declaration => {
            const e = node.data.extra;
            if (e + 3 < ast.extra_data.items.len) {
                const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
                if (!decl_idx.isNone() and @intFromEnum(decl_idx) < ast.nodes.items.len) {
                    return hasSideEffects(ast, ast.nodes.items[@intFromEnum(decl_idx)]);
                }
                return false;
            }
            return true;
        },
        .export_default_declaration => {
            const inner_idx = node.data.unary.operand;
            if (inner_idx.isNone() or @intFromEnum(inner_idx) >= ast.nodes.items.len) return true;
            const inner = ast.nodes.items[@intFromEnum(inner_idx)];
            return switch (inner.tag) {
                .function_declaration => false,
                .class_declaration => purity.classHasSideEffects(ast, inner),
                else => !purity.isNodePure(ast, inner),
            };
        },
        // import 문은 이 함수에서 호출되지 않음 (build에서 별도 처리)
        .import_declaration => return false,
        .export_all_declaration => return true,
        .empty_statement => return false,
        else => return true,
    }
}

// ============================================================
// Tests
// ============================================================

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

fn buildTestInfos(allocator: std.mem.Allocator, source: []const u8) !struct {
    infos: ModuleStmtInfos,
    arena: std.heap.ArenaAllocator,
} {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    scanner.is_module = true;
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    const infos = (try build(
        allocator,
        &parser.ast,
        analyzer.symbols.items,
        analyzer.symbol_ids.items,
    )) orelse return error.NullResult;

    return .{ .infos = infos, .arena = arena };
}

test "stmt_info: function declarations" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\function a() { return b(); }
        \\function b() { return 1; }
        \\function c() { return 2; }
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // 3개 함수 선언 → 3개 StmtInfo
    try std.testing.expectEqual(@as(usize, 3), r.infos.stmts.len);
    // 각 statement는 1개 심볼 선언
    try std.testing.expectEqual(@as(usize, 1), r.infos.stmts[0].declared_symbols.len);
    try std.testing.expectEqual(@as(usize, 1), r.infos.stmts[1].declared_symbols.len);
    // a()는 b()를 참조
    try std.testing.expect(r.infos.stmts[0].referenced_symbols.len >= 1);
    // 함수 선언은 side-effect-free
    try std.testing.expect(!r.infos.stmts[0].has_side_effects);
}

test "stmt_info: import binding tracked" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { x } from './mod';
        \\const y = x + 1;
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // 2개 문
    try std.testing.expectEqual(@as(usize, 2), r.infos.stmts.len);
    // import → side-effect-free
    try std.testing.expect(!r.infos.stmts[0].has_side_effects);
    // import는 1개 심볼(x) 선언
    try std.testing.expect(r.infos.stmts[0].declared_symbols.len >= 1);
    // const y = x + 1 → x를 참조
    try std.testing.expect(r.infos.stmts[1].referenced_symbols.len >= 1);
}

test "stmt_info: reachability BFS" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { x } from './mod';
        \\function used() { return x; }
        \\function unused() { return 1; }
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    // used의 심볼 index 가져오기
    const used_sym = r.infos.stmts[1].declared_symbols[0];

    var reachable = try r.infos.computeReachable(alloc, &.{used_sym});
    defer reachable.deinit();

    // stmt 0 (import) → side-effect-free, x만 선언
    // stmt 1 (used) → seed, x 참조 → stmt 0 도달
    // stmt 2 (unused) → 미도달
    try std.testing.expect(reachable.isSet(0)); // import (used가 x 참조)
    try std.testing.expect(reachable.isSet(1)); // used (seed)
    try std.testing.expect(!reachable.isSet(2)); // unused (미도달)
}

test "stmt_info: unused import not reachable" {
    const alloc = std.testing.allocator;
    var r = try buildTestInfos(alloc,
        \\import { x } from './a';
        \\import { y } from './b';
        \\function used() { return x; }
    );
    defer r.infos.deinit();
    defer r.arena.deinit();

    const used_sym = r.infos.stmts[2].declared_symbols[0];

    var reachable = try r.infos.computeReachable(alloc, &.{used_sym});
    defer reachable.deinit();

    // used → x 참조 → import x 도달
    // import y → 미참조 → 미도달
    try std.testing.expect(reachable.isSet(0)); // import x
    try std.testing.expect(!reachable.isSet(1)); // import y (unused)
    try std.testing.expect(reachable.isSet(2)); // used
}
