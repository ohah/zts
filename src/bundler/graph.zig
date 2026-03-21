//! ZTS Bundler — Module Graph
//!
//! 진입점에서 시작하여 모든 의존성을 재귀적으로 탐색하고,
//! DFS 후위 순서로 ESM 실행 순서(exec_index)를 부여한다.
//!
//! 설계:
//!   - D057: 모듈 그래프가 번들러의 기반
//!   - D058: DFS 후위 순서 = ESM 실행 순서
//!   - D065: 순환 참조 감지 (in_stack 배열, Rollup 알고리즘)
//!   - D076: DFS 순회
//!   - D078: 양방향 인접 리스트 (Module.addDependency)
//!   - D079: import_scanner.extractImports로 import 추출
//!
//! 참고:
//!   - references/rollup/src/utils/executionOrder.ts
//!   - references/rolldown/crates/rolldown/src/module_loader/
//!   - references/bun/src/bundler/LinkerContext.zig

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const ImportKind = types.ImportKind;
const ImportRecord = types.ImportRecord;
const BundlerDiagnostic = types.BundlerDiagnostic;
const Module = @import("module.zig").Module;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const import_scanner = @import("import_scanner.zig");
const binding_scanner_mod = @import("binding_scanner.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Span = @import("../lexer/token.zig").Span;

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(Module),
    path_to_module: std.StringHashMap(ModuleIndex),
    diagnostics: std.ArrayList(BundlerDiagnostic),
    resolve_cache: *ResolveCache,

    // DFS 상태
    exec_counter: u32 = 0,
    cycle_counter: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, resolve_cache: *ResolveCache) ModuleGraph {
        return .{
            .allocator = allocator,
            .modules = .empty,
            .path_to_module = std.StringHashMap(ModuleIndex).init(allocator),
            .diagnostics = .empty,
            .resolve_cache = resolve_cache,
        };
    }

    pub fn deinit(self: *ModuleGraph) void {
        for (self.modules.items) |*m| {
            // import_records, import_bindings, export_bindings는 graph allocator 소유.
            if (m.import_records.len > 0) self.allocator.free(m.import_records);
            if (m.import_bindings.len > 0) self.allocator.free(m.import_bindings);
            if (m.export_bindings.len > 0) self.allocator.free(m.export_bindings);
            m.deinit(self.allocator); // parse_arena.deinit() + dependencies/importers 해제
        }
        self.modules.deinit(self.allocator);
        var key_it = self.path_to_module.keyIterator();
        while (key_it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.path_to_module.deinit();
        self.diagnostics.deinit(self.allocator);
    }

    /// 진입점들로부터 모듈 그래프를 구축한다.
    /// Phase 1: 모든 모듈 등록 + 파싱 + import resolve (BFS)
    /// Phase 2: DFS로 exec_index + 순환 감지
    pub fn build(self: *ModuleGraph, entry_points: []const []const u8) !void {
        // Phase 1: BFS로 모든 모듈 등록 + 의존성 resolve
        for (entry_points) |entry_path| {
            _ = try self.addModule(entry_path);
        }

        // BFS 큐: addModule에서 추가된 모듈들의 import를 resolve.
        // modules 배열이 커질 수 있으므로 인덱스로 순회 (포인터 무효화 방지).
        var i: usize = 0;
        while (i < self.modules.items.len) : (i += 1) {
            try self.resolveModuleImports(@enumFromInt(@as(u32, @intCast(i))));
        }

        // Phase 2: DFS로 exec_index + 순환 감지
        const count = self.modules.items.len;
        if (count == 0) return;

        var visited = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer visited.deinit();
        var in_stack = try std.DynamicBitSet.initEmpty(self.allocator, count);
        defer in_stack.deinit();

        for (entry_points) |entry_path| {
            if (self.path_to_module.get(entry_path)) |idx| {
                try self.dfs(idx, &visited, &in_stack);
            }
        }
    }

    /// 모듈을 그래프에 추가하고 파싱한다.
    /// 이미 존재하면 기존 인덱스를 반환.
    fn addModule(self: *ModuleGraph, abs_path: []const u8) !ModuleIndex {
        // 중복 체크
        if (self.path_to_module.get(abs_path)) |existing| {
            return existing;
        }

        // 새 모듈 슬롯 할당
        const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.items.len)));
        const path_owned = try self.allocator.dupe(u8, abs_path);

        var module = Module.init(index, path_owned);
        module.module_type = ModuleType.fromExtension(std.fs.path.extension(abs_path));
        try self.modules.append(self.allocator, module);
        try self.path_to_module.put(path_owned, index);

        // 파싱
        self.parseModule(index);

        return index;
    }

    /// 단일 모듈을 파싱하고 import를 추출한다.
    /// 모듈별 Arena로 Scanner/Parser/AST를 할당하여 emitter까지 보존.
    /// import_records는 graph allocator로 별도 할당 (specifier가 source를 참조).
    fn parseModule(self: *ModuleGraph, idx: ModuleIndex) void {
        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.items.len) return;

        var module = &self.modules.items[mod_idx];
        module.state = .parsing;

        if (module.module_type != .javascript) {
            module.state = .ready;
            return;
        }

        // 모듈별 Arena: Scanner/Parser/AST 메모리를 소유 (D061)
        module.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_alloc = module.parse_arena.?.allocator();

        // 파일 읽기 (arena — module.source가 참조)
        const source = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 100 * 1024 * 1024) catch {
            self.addDiag(.read_error, .@"error", module.path, Span.EMPTY, .resolve, "Cannot read file", null);
            module.state = .ready;
            return;
        };
        module.source = source;

        // Scanner + Parser (arena 할당)
        var scanner = Scanner.init(arena_alloc, source) catch {
            self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Scanner initialization failed", null);
            module.state = .ready;
            return;
        };

        var parser = Parser.init(arena_alloc, &scanner);
        parser.is_module = true;
        _ = parser.parse() catch {
            self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Parse failed", null);
            module.state = .ready;
            return;
        };

        if (parser.errors.items.len > 0) {
            self.addDiag(.parse_error, .warning, module.path, Span.EMPTY, .parse, "Parse completed with errors", null);
        }

        // Semantic analysis — linker에 필요한 스코프/심볼/export 정보.
        // arena_alloc으로 실행: SemanticAnalyzer의 모든 데이터가 parse_arena에 할당.
        // analyzer.deinit()을 의도적으로 호출하지 않음 — arena가 일괄 해제.
        // 주의: 이후에 defer analyzer.deinit()을 추가하면 double-free 발생.
        var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        const analyze_ok = if (analyzer.analyze()) |_| true else |_| false;

        // OOM 시 semantic = null로 유지 (부분 데이터로 linker가 오동작하는 것 방지)
        if (analyze_ok) {
            module.semantic = .{
                .symbols = analyzer.symbols.items,
                .scopes = analyzer.scopes.items,
                .scope_maps = analyzer.scope_maps.items,
                .exported_names = analyzer.exported_names,
                .symbol_ids = analyzer.symbol_ids.items,
            };
        }

        // Import 추출 (D079) — graph allocator로 할당
        const records = import_scanner.extractImports(self.allocator, &parser.ast) catch {
            module.state = .ready;
            return;
        };
        module.import_records = records;

        // Import/Export 바인딩 상세 추출 — linker에서 사용
        module.import_bindings = binding_scanner_mod.extractImportBindings(self.allocator, &parser.ast, records) catch &.{};
        module.export_bindings = binding_scanner_mod.extractExportBindings(self.allocator, &parser.ast, records) catch &.{};

        module.ast = parser.ast;
        module.state = .ready;
    }

    /// Phase 1: 모듈의 import들을 resolve하고 의존성 모듈을 등록한다.
    /// modules 배열이 커질 수 있으므로, 포인터가 아닌 인덱스로만 접근.
    fn resolveModuleImports(self: *ModuleGraph, idx: ModuleIndex) !void {
        const mod_idx = @intFromEnum(idx);
        if (mod_idx >= self.modules.items.len) return;

        const module_path = self.modules.items[mod_idx].path;
        const source_dir = std.fs.path.dirname(module_path) orelse ".";
        const records = self.modules.items[mod_idx].import_records;

        for (records, 0..) |record, rec_i| {
            const resolved = self.resolve_cache.resolve(
                source_dir,
                record.specifier,
                record.kind,
            ) catch |err| switch (err) {
                error.ModuleNotFound => {
                    const sev: BundlerDiagnostic.Severity = if (record.kind == .dynamic_import) .warning else .@"error";
                    self.addDiag(.unresolved_import, sev, module_path, record.span, .resolve, "Cannot resolve module", record.specifier);
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };

            if (resolved) |r| {
                defer self.allocator.free(r.path);
                const dep_idx = try self.addModule(r.path);

                // import_records 업데이트 (modules 배열이 재할당되었을 수 있으므로 다시 접근)
                self.modules.items[mod_idx].import_records[rec_i].resolved = dep_idx;

                if (record.kind == .dynamic_import) {
                    try self.modules.items[mod_idx].addDynamicImport(self.allocator, dep_idx);
                } else {
                    // 양방향 엣지 (D078)
                    try self.modules.items[mod_idx].addDependency(self.allocator, dep_idx, self.modules.items);
                }
            }
            // resolved == null → external, 스킵
        }
    }

    /// Phase 2: 반복 DFS 후위 순서 순회. exec_index 부여 + 순환 감지 (D065, D076).
    /// 재귀 대신 명시적 스택 사용 — 깊은 모듈 체인에서도 스택 오버플로 없음.
    fn dfs(self: *ModuleGraph, start_idx: ModuleIndex, visited: *std.DynamicBitSet, in_stack: *std.DynamicBitSet) !void {
        const DfsEntry = struct {
            idx: u32,
            post: bool, // true = 후처리 (exec_index 부여), false = 전처리 (의존성 push)
        };

        var stack: std.ArrayList(DfsEntry) = .empty;
        defer stack.deinit(self.allocator);

        const start = @intFromEnum(start_idx);
        if (start >= self.modules.items.len) return;
        if (visited.isSet(start)) return;

        try stack.append(self.allocator, .{ .idx = start, .post = false });

        while (stack.items.len > 0) {
            const entry = stack.pop() orelse break;

            if (entry.post) {
                // 후처리: exec_index 부여 + in_stack 해제
                in_stack.unset(entry.idx);
                visited.set(entry.idx);
                self.modules.items[entry.idx].exec_index = self.exec_counter;
                self.exec_counter += 1;
                continue;
            }

            if (visited.isSet(entry.idx)) continue;

            // 순환 감지 (D065)
            if (in_stack.isSet(entry.idx)) {
                self.cycle_counter += 1;
                self.modules.items[entry.idx].cycle_group = self.cycle_counter;
                self.addDiag(
                    .circular_dependency,
                    .warning,
                    self.modules.items[entry.idx].path,
                    Span.EMPTY,
                    .link,
                    "Circular dependency detected",
                    null,
                );
                continue;
            }

            in_stack.set(entry.idx);

            // 후처리를 먼저 push (LIFO이므로 나중에 실행)
            try stack.append(self.allocator, .{ .idx = entry.idx, .post = true });

            // 의존성을 역순으로 push (원래 순서대로 방문하기 위해)
            const deps = self.modules.items[entry.idx].dependencies.items;
            var j: usize = deps.len;
            while (j > 0) {
                j -= 1;
                const dep = @intFromEnum(deps[j]);
                if (dep < self.modules.items.len and !visited.isSet(dep)) {
                    try stack.append(self.allocator, .{ .idx = dep, .post = false });
                }
            }
        }
    }

    fn addDiag(
        self: *ModuleGraph,
        code: BundlerDiagnostic.ErrorCode,
        severity: BundlerDiagnostic.Severity,
        file_path: []const u8,
        span: Span,
        step: BundlerDiagnostic.Step,
        message: []const u8,
        suggestion: ?[]const u8,
    ) void {
        self.diagnostics.append(self.allocator, .{
            .code = code,
            .severity = severity,
            .message = message,
            .file_path = file_path,
            .span = span,
            .step = step,
            .suggestion = suggestion,
        }) catch {};
    }
};

// ============================================================
// Tests
// ============================================================

const resolve_cache_mod = @import("resolve_cache.zig");

fn createFile(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    const file = try dir.createFile(path, .{});
    file.close();
}

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    dir.writeFile(.{ .sub_path = path, .data = data }) catch |err| return err;
}

fn dirPath(tmp: *std.testing.TmpDir) ![]const u8 {
    return try tmp.dir.realpathAlloc(std.testing.allocator, ".");
}

test "graph: single module, no imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 1), graph.modules.items.len);
    try std.testing.expectEqual(@as(u32, 0), graph.modules.items[0].exec_index);
    try std.testing.expectEqual(Module.State.ready, graph.modules.items[0].state);
}

test "graph: A imports B — correct exec order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);

    // DFS 후위: B가 먼저 (exec_index=0), A가 나중 (exec_index=1)
    const a_mod = graph.modules.items[0]; // a.ts가 먼저 addModule됨
    const b_mod = graph.modules.items[1];
    try std.testing.expect(b_mod.exec_index < a_mod.exec_index);
}

test "graph: chain A → B → C — correct exec order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "import './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 3), graph.modules.items.len);

    // C=0, B=1, A=2 (후위 순서)
    const a = graph.modules.items[0];
    const b = graph.modules.items[1];
    const c = graph.modules.items[2];
    try std.testing.expect(c.exec_index < b.exec_index);
    try std.testing.expect(b.exec_index < a.exec_index);
}

test "graph: diamond A→B,C; B→D; C→D — no duplicate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b'; import './c';");
    try writeFile(tmp.dir, "b.ts", "import './d';");
    try writeFile(tmp.dir, "c.ts", "import './d';");
    try writeFile(tmp.dir, "d.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // D가 중복 없이 4개 모듈
    try std.testing.expectEqual(@as(usize, 4), graph.modules.items.len);

    // D가 가장 먼저 실행 (exec_index 최소)
    var min_exec: u32 = std.math.maxInt(u32);
    var min_path: []const u8 = "";
    for (graph.modules.items) |m| {
        if (m.exec_index < min_exec) {
            min_exec = m.exec_index;
            min_path = m.path;
        }
    }
    try std.testing.expect(std.mem.endsWith(u8, min_path, "d.ts"));
}

test "graph: circular dependency — warning emitted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "import './a';");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // 2개 모듈, 순환 경고 존재
    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);

    var has_circular_warning = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .circular_dependency) has_circular_warning = true;
    }
    try std.testing.expect(has_circular_warning);
}

test "graph: external module — not in graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import 'react';");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{"react"});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // react는 external이므로 그래프에 안 들어감
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items.len);
}

test "graph: unresolved import — error diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './nonexistent';");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // 에러 diagnostic 있어야 함
    var has_unresolved = false;
    for (graph.diagnostics.items) |d| {
        if (d.code == .unresolved_import) has_unresolved = true;
    }
    try std.testing.expect(has_unresolved);
}

test "graph: bidirectional edges (D078)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // A.dependencies에 B
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[0].dependencies.items.len);
    // B.importers에 A
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[1].importers.items.len);
}

test "graph: re-export adds dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export * from './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[0].dependencies.items.len);
}

test "graph: multiple entry points" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry1.ts", "const a = 1;");
    try writeFile(tmp.dir, "entry2.ts", "const b = 2;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const e1 = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry1.ts" });
    defer std.testing.allocator.free(e1);
    const e2 = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "entry2.ts" });
    defer std.testing.allocator.free(e2);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{ e1, e2 });

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    // 둘 다 exec_index가 할당됨 (maxInt 아님)
    try std.testing.expect(graph.modules.items[0].exec_index != std.math.maxInt(u32));
    try std.testing.expect(graph.modules.items[1].exec_index != std.math.maxInt(u32));
}

test "graph: dynamic import stored in dynamic_imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "const m = import('./lazy');");
    try writeFile(tmp.dir, "lazy.ts", "export const x = 1;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    // 동적 import는 dynamic_imports에, dependencies에는 없음
    try std.testing.expectEqual(@as(usize, 0), graph.modules.items[0].dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items[0].dynamic_imports.items.len);
}

test "graph: JSON module — no AST, in graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './data.json';");
    try writeFile(tmp.dir, "data.json", "{\"key\":\"value\"}");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    // JSON 모듈은 AST 없음 (파싱 안 함)
    const json_mod = graph.modules.items[1];
    try std.testing.expect(json_mod.ast == null);
    try std.testing.expectEqual(types.ModuleType.json, json_mod.module_type);
}

test "graph: semantic data preserved after build" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const x = 1;\nexport function greet() { return 'hi'; }");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    const m = graph.modules.items[0];
    // semantic 데이터가 보존되어야 함
    try std.testing.expect(m.semantic != null);
    const sem = m.semantic.?;
    // exported_names에 x와 greet이 있어야 함
    try std.testing.expect(sem.exported_names.get("x") != null);
    try std.testing.expect(sem.exported_names.get("greet") != null);
    // symbols 배열이 비어있지 않아야 함
    try std.testing.expect(sem.symbols.len > 0);
    // scopes 배열이 비어있지 않아야 함
    try std.testing.expect(sem.scopes.len > 0);
}

test "graph: semantic data null for non-JS modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './data.json';");
    try writeFile(tmp.dir, "data.json", "{\"key\":\"value\"}");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // a.ts는 semantic 있음
    try std.testing.expect(graph.modules.items[0].semantic != null);
    // data.json은 semantic 없음
    try std.testing.expect(graph.modules.items[1].semantic == null);
}

test "graph: semantic exported_names tracks default export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export default function main() { return 42; }");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    const sem = graph.modules.items[0].semantic.?;
    try std.testing.expect(sem.exported_names.get("default") != null);
}

test "graph: import/export bindings preserved after build" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nexport const y = x + 1;");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    const dp = try dirPath(&tmp);
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    try graph.build(&.{entry});

    // a.ts: import_bindings에 x가 있어야 함
    const a = graph.modules.items[0];
    try std.testing.expect(a.import_bindings.len > 0);
    try std.testing.expectEqualStrings("x", a.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("x", a.import_bindings[0].imported_name);

    // a.ts: export_bindings에 y가 있어야 함
    try std.testing.expect(a.export_bindings.len > 0);
    try std.testing.expectEqualStrings("y", a.export_bindings[0].exported_name);

    // b.ts: export_bindings에 x가 있어야 함
    const b = graph.modules.items[1];
    try std.testing.expect(b.export_bindings.len > 0);
    try std.testing.expectEqualStrings("x", b.export_bindings[0].exported_name);
}
