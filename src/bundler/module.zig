//! ZTS Bundler — Module
//!
//! 모듈 그래프의 노드. 하나의 JS/TS/JSON/CSS 파일에 대응.
//!
//! 설계:
//!   - D070: ModuleIndex = enum(u32)
//!   - D073: ModuleType enum
//!   - D078: 양방향 인접 리스트 (dependencies + importers)
//!   - D079: ImportRecord 배열로 import 정보 보유

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const ImportRecord = types.ImportRecord;
const Ast = @import("../parser/ast.zig").Ast;
const Span = @import("../lexer/token.zig").Span;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Scope = @import("../semantic/scope.zig").Scope;
const binding_scanner = @import("binding_scanner.zig");
pub const ImportBinding = binding_scanner.ImportBinding;
pub const ExportBinding = binding_scanner.ExportBinding;

/// Semantic analyzer 결과. parse_arena가 소유하는 데이터의 참조.
/// linker가 import→export 연결 + 이름 충돌 해결에 사용.
pub const ModuleSemanticData = struct {
    symbols: []const Symbol,
    scopes: []const Scope,
    /// 스코프별 이름→심볼 인덱스 조회. scope_maps[scope_id].get("x") → symbol index.
    scope_maps: []const std.StringHashMap(usize),
    /// export된 이름 목록. exported_names.get("x") → Span.
    exported_names: std.StringHashMap(Span),
};

pub const Module = struct {
    index: ModuleIndex,
    /// 절대 파일 경로. graph의 path_to_module 키와 동일한 메모리를 참조 (빌림).
    path: []const u8,
    /// 소스 코드. parse_arena에서 할당 (Module.arena가 소유).
    source: []const u8,
    /// 파싱된 AST. parse_arena에서 할당 (Module.arena가 소유).
    ast: ?Ast,
    /// import_scanner가 추출한 레코드. graph allocator에서 할당 (소스 텍스트를 참조).
    import_records: []ImportRecord,
    /// 모듈별 Arena — Scanner/Parser/AST/Semantic 메모리를 소유. graph.deinit에서 해제.
    parse_arena: ?std.heap.ArenaAllocator,
    /// semantic analyzer 결과. parse_arena가 소유. linker에서 사용.
    semantic: ?ModuleSemanticData,
    /// import 바인딩 상세. graph allocator 소유 (소스 텍스트 참조).
    import_bindings: []ImportBinding = &.{},
    /// export 바인딩 상세. graph allocator 소유 (소스 텍스트 참조).
    export_bindings: []ExportBinding = &.{},

    /// 내가 import하는 모듈들 (순방향)
    dependencies: std.ArrayList(ModuleIndex),
    /// 나를 import하는 모듈들 (역방향, D078 HMR용)
    importers: std.ArrayList(ModuleIndex),
    /// 동적 import (별도 관리, code splitting용)
    dynamic_imports: std.ArrayList(ModuleIndex),

    module_type: ModuleType,
    side_effects: bool,
    /// DFS 후위 순서 = ESM 실행 순서 (D058, D076).
    /// maxInt = 미방문 (DFS에서 할당되지 않음).
    exec_index: u32,
    /// 순환 참조 그룹 ID. 0 = 순환 없음 (D065)
    cycle_group: u32,
    state: State,

    pub const State = enum {
        /// 슬롯만 예약됨, 아직 파싱 안 됨
        reserved,
        /// 파싱 중
        parsing,
        /// 파싱 완료, import 추출 완료
        ready,
    };

    pub fn init(index: ModuleIndex, path: []const u8) Module {
        return .{
            .index = index,
            .path = path,
            .source = "",
            .ast = null,
            .import_records = &.{},
            .parse_arena = null,
            .semantic = null,
            .dependencies = .empty,
            .importers = .empty,
            .dynamic_imports = .empty,
            .module_type = .unknown,
            .side_effects = true,
            .exec_index = std.math.maxInt(u32),
            .cycle_group = 0,
            .state = .reserved,
        };
    }

    /// 양방향 의존성 추가 (D078).
    /// self → dep 순방향 + dep → self 역방향을 동시에 업데이트.
    pub fn addDependency(
        self: *Module,
        allocator: std.mem.Allocator,
        dep_index: ModuleIndex,
        all_modules: []Module,
    ) !void {
        if (dep_index.isNone()) return;
        const idx = @intFromEnum(dep_index);
        if (idx >= all_modules.len) return;

        try self.dependencies.append(allocator, dep_index);
        var dep = &all_modules[idx];
        try dep.importers.append(allocator, self.index);
    }

    /// 동적 import 추가.
    pub fn addDynamicImport(
        self: *Module,
        allocator: std.mem.Allocator,
        dep_index: ModuleIndex,
    ) !void {
        try self.dynamic_imports.append(allocator, dep_index);
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.dependencies.deinit(allocator);
        self.importers.deinit(allocator);
        self.dynamic_imports.deinit(allocator);
        // parse_arena가 Scanner/Parser/AST/source 메모리를 전부 소유.
        // ast.deinit()는 불필요 — arena.deinit()이 일괄 해제.
        if (self.parse_arena) |*arena| arena.deinit();
    }
};

// ============================================================
// Tests
// ============================================================

test "Module: init defaults" {
    const m = Module.init(@enumFromInt(0), "src/index.ts");
    try std.testing.expectEqual(Module.State.reserved, m.state);
    try std.testing.expectEqual(std.math.maxInt(u32), m.exec_index);
    try std.testing.expectEqual(@as(u32, 0), m.cycle_group);
    try std.testing.expect(m.side_effects);
    try std.testing.expect(m.ast == null);
    try std.testing.expectEqual(@as(usize, 0), m.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 0), m.importers.items.len);
}

test "Module: addDependency bidirectional" {
    const alloc = std.testing.allocator;
    var modules: [2]Module = .{
        Module.init(@enumFromInt(0), "a.ts"),
        Module.init(@enumFromInt(1), "b.ts"),
    };
    defer modules[0].deinit(alloc);
    defer modules[1].deinit(alloc);

    // A depends on B
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);

    // A.dependencies에 B가 있어야 함
    try std.testing.expectEqual(@as(usize, 1), modules[0].dependencies.items.len);
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(modules[0].dependencies.items[0]));

    // B.importers에 A가 있어야 함 (역방향)
    try std.testing.expectEqual(@as(usize, 1), modules[1].importers.items.len);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(modules[1].importers.items[0]));
}

test "Module: state transitions" {
    var m = Module.init(@enumFromInt(0), "test.ts");
    defer m.deinit(std.testing.allocator);

    try std.testing.expectEqual(Module.State.reserved, m.state);
    m.state = .parsing;
    try std.testing.expectEqual(Module.State.parsing, m.state);
    m.state = .ready;
    try std.testing.expectEqual(Module.State.ready, m.state);
}

test "Module: addDependency with none index — no-op" {
    const alloc = std.testing.allocator;
    var modules: [1]Module = .{Module.init(@enumFromInt(0), "a.ts")};
    defer modules[0].deinit(alloc);

    try modules[0].addDependency(alloc, .none, &modules);
    try std.testing.expectEqual(@as(usize, 0), modules[0].dependencies.items.len);
}

test "Module: addDependency with out-of-bounds index — no-op" {
    const alloc = std.testing.allocator;
    var modules: [1]Module = .{Module.init(@enumFromInt(0), "a.ts")};
    defer modules[0].deinit(alloc);

    try modules[0].addDependency(alloc, @enumFromInt(99), &modules);
    try std.testing.expectEqual(@as(usize, 0), modules[0].dependencies.items.len);
}
