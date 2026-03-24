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
const resolve_cache_mod = @import("resolve_cache.zig");
const ResolveCache = resolve_cache_mod.ResolveCache;
const import_scanner = @import("import_scanner.zig");
const binding_scanner_mod = @import("binding_scanner.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Span = @import("../lexer/token.zig").Span;
const pkg_json = @import("package_json.zig");

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(Module),
    path_to_module: std.StringHashMap(ModuleIndex),
    diagnostics: std.ArrayList(BundlerDiagnostic),
    resolve_cache: *ResolveCache,

    /// 패키지별 sideEffects 캐시. pkg_dir_path → SideEffects.
    /// 같은 패키지의 여러 모듈이 동일 package.json을 반복 읽지 않도록.
    side_effects_cache: std.StringHashMap(pkg_json.PackageJson.SideEffects),

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
            .side_effects_cache = std.StringHashMap(pkg_json.PackageJson.SideEffects).init(allocator),
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
        var se_it = self.side_effects_cache.valueIterator();
        while (se_it.next()) |se| se.deinit(self.allocator);
        self.side_effects_cache.deinit();
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

        // Phase 3: ExportsKind.none 모듈을 소비하는 쪽에 따라 승격
        self.promoteExportsKinds();

        // Phase 4: TLA 전파 — TLA 모듈을 static import하는 모듈도 TLA로 표시
        self.propagateTopLevelAwait();
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

    /// platform=browser에서 Node 빌트인 모듈을 빈 CJS 모듈로 등록 (esbuild "(disabled)" 방식).
    /// AST 없이 wrap_kind=.cjs, is_disabled=true로 설정.
    /// DFS가 이 모듈을 방문하여 exec_index를 부여하고, emitter가 빈 __commonJS wrapper를 출력.
    fn addDisabledModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
        // 가상 경로: "(disabled):specifier" (esbuild 형식).
        // specifier 기준으로 중복 체크 — 여러 모듈이 같은 빌트인을 require해도 하나만 생성.
        const disabled_path = try std.mem.concat(self.allocator, u8, &.{ "(disabled):", specifier });

        // 중복 체크
        if (self.path_to_module.get(disabled_path)) |existing| {
            self.allocator.free(disabled_path);
            return existing;
        }

        const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.items.len)));
        var module = Module.init(index, disabled_path);
        module.module_type = .javascript;
        module.exports_kind = .commonjs;
        module.wrap_kind = .cjs;
        module.is_disabled = true;
        module.side_effects = false;
        module.state = .ready;
        try self.modules.append(self.allocator, module);
        try self.path_to_module.put(disabled_path, index);

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

        // JSON 모듈: 파싱 불필요, CJS로 래핑만
        if (module.module_type == .json) {
            module.parse_arena = std.heap.ArenaAllocator.init(self.allocator);
            const arena_alloc = module.parse_arena.?.allocator();
            module.source = std.fs.cwd().readFileAlloc(arena_alloc, module.path, 10 * 1024 * 1024) catch "";
            module.exports_kind = .commonjs;
            module.wrap_kind = .cjs;
            module.state = .ready;
            return;
        }

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
                .unresolved_references = analyzer.unresolved_references,
            };
            // TLA 감지: semantic analyzer가 스코프 체인을 추적하며 정확히 판별
            module.uses_top_level_await = analyzer.has_top_level_await;
        }

        // Import 추출 + CJS 감지 (D079) — graph allocator로 할당
        const scan_result = import_scanner.extractImportsWithCjsDetection(self.allocator, &parser.ast) catch {
            module.state = .ready;
            return;
        };
        module.import_records = scan_result.records;

        // CJS/ESM 판별 — 스캔 결과 + 확장자 + package.json type 필드
        module.exports_kind = determineExportsKind(scan_result, module.path);
        // CJS 모듈은 __commonJS 팩토리 함수로 래핑
        module.wrap_kind = if (module.exports_kind == .commonjs) .cjs else .none;

        // Import/Export 바인딩 상세 추출 — linker에서 사용
        module.import_bindings = binding_scanner_mod.extractImportBindings(self.allocator, &parser.ast, scan_result.records) catch &.{};
        module.export_bindings = binding_scanner_mod.extractExportBindings(self.allocator, &parser.ast, scan_result.records, module.import_bindings) catch &.{};

        module.ast = parser.ast;
        module.line_offsets = scanner.line_offsets.items;

        // package.json sideEffects 필드 반영 (node_modules 패키지만)
        self.applySideEffectsFromPackageJson(module);

        module.state = .ready;
    }

    /// 모듈 경로에서 node_modules/패키지/ 디렉토리 경로를 추출.
    /// 스코프 패키지 (@scope/name) 지원.
    fn findPackageDirPath(module_path: []const u8) ?[]const u8 {
        const nm = "node_modules" ++ std.fs.path.sep_str;
        const nm_pos = std.mem.lastIndexOf(u8, module_path, nm) orelse return null;
        const pkg_start = nm_pos + nm.len;
        var pkg_end = pkg_start;
        if (pkg_end < module_path.len and module_path[pkg_end] == '@') {
            if (std.mem.indexOfPos(u8, module_path, pkg_end, std.fs.path.sep_str)) |sep1| {
                pkg_end = std.mem.indexOfPos(u8, module_path, sep1 + 1, std.fs.path.sep_str) orelse module_path.len;
            } else pkg_end = module_path.len;
        } else {
            pkg_end = std.mem.indexOfPos(u8, module_path, pkg_start, std.fs.path.sep_str) orelse module_path.len;
        }
        return module_path[0..pkg_end];
    }

    /// node_modules 패키지의 package.json sideEffects 필드를 module.side_effects에 반영.
    fn applySideEffectsFromPackageJson(self: *ModuleGraph, module: *Module) void {
        const pkg_dir_path = findPackageDirPath(module.path) orelse return;

        // 캐시 확인 — 같은 패키지의 package.json을 반복 읽지 않음
        if (self.side_effects_cache.get(pkg_dir_path)) |cached| {
            switch (cached) {
                .all => |val| module.side_effects = val,
                .patterns => |patterns| {
                    module.side_effects = matchSideEffectsPatterns(module.path, pkg_dir_path, patterns);
                },
                .unknown => {},
            }
            return;
        }

        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{}) catch return;
        defer pkg_dir.close();

        var parsed = pkg_json.parsePackageJson(self.allocator, pkg_dir) catch return;
        defer parsed.deinit();

        // 캐시에 저장 (patterns는 parseSideEffects가 allocator로 dupe 완료)
        const se = parsed.pkg.side_effects;
        self.side_effects_cache.put(pkg_dir_path, se) catch {};
        // 소유권을 캐시로 이전했으므로 parsed.deinit()에서 이중 해제 방지
        parsed.pkg.side_effects = .unknown;

        switch (se) {
            .all => |val| module.side_effects = val,
            .patterns => |patterns| {
                module.side_effects = matchSideEffectsPatterns(module.path, pkg_dir_path, patterns);
            },
            .unknown => {},
        }
    }

    /// sideEffects 글롭 패턴 매칭.
    /// 모듈의 패키지 내 상대 경로를 각 패턴과 비교하여,
    /// 하나라도 매칭되면 side_effects=true (해당 파일은 제거하면 안 됨).
    /// 아무 패턴도 매칭되지 않으면 side_effects=false (순수 모듈, 제거 가능).
    fn matchSideEffectsPatterns(module_path: []const u8, pkg_dir_path: []const u8, patterns: []const []const u8) bool {
        const matchGlob = @import("resolve_cache.zig").matchGlob;

        // 패키지 디렉토리 기준 상대 경로 추출: /abs/node_modules/pkg/src/foo.js → src/foo.js
        const relative = if (module_path.len > pkg_dir_path.len + 1)
            module_path[pkg_dir_path.len + 1 ..] // +1 for separator
        else
            module_path;

        // Windows 경로 정규화: \ → / (패턴은 항상 / 사용)
        var rel_buf: [4096]u8 = undefined;
        const rel_normalized = normalizeSep(relative, &rel_buf);
        const base = std.fs.path.basename(rel_normalized);

        for (patterns) |pattern| {
            // "./" 접두사 제거: "./src/polyfill.js" → "src/polyfill.js"
            const normalized = if (std.mem.startsWith(u8, pattern, "./"))
                pattern[2..]
            else
                pattern;

            if (matchGlob(normalized, rel_normalized)) return true;
            // basename 폴백: "*.css"는 "src/style.css"도 매칭해야 함
            if (base.len != rel_normalized.len) {
                if (matchGlob(normalized, base)) return true;
            }
        }
        return false;
    }

    /// 경로의 \ 구분자를 /로 정규화 (Windows 호환).
    fn normalizeSep(path: []const u8, buf: *[4096]u8) []const u8 {
        if (comptime @import("builtin").os.tag == .windows) {
            const len = @min(path.len, buf.len);
            for (path[0..len], 0..) |c, i| {
                buf[i] = if (c == '\\') '/' else c;
            }
            return buf[0..len];
        }
        return path;
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
                    // platform=browser에서 Node 빌트인 모듈은 빈 CJS로 대체 (esbuild "(disabled)" 방식)
                    if (self.resolve_cache.platform == .browser and resolve_cache_mod.isNodeBuiltin(record.specifier)) {
                        const dep_idx = try self.addDisabledModule(record.specifier);
                        self.modules.items[mod_idx].import_records[rec_i].resolved = dep_idx;
                        if (record.kind == .dynamic_import) {
                            try self.modules.items[mod_idx].addDynamicImport(self.allocator, dep_idx);
                        } else {
                            try self.modules.items[mod_idx].addDependency(self.allocator, dep_idx, self.modules.items);
                        }
                        continue;
                    }
                    const sev: BundlerDiagnostic.Severity = if (record.kind == .dynamic_import) .warning else .@"error";
                    self.addDiag(.unresolved_import, sev, module_path, record.span, .resolve, "Cannot resolve module", record.specifier);
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };

            if (resolved) |r| {
                defer self.allocator.free(r.path);

                // package.json "browser" 필드에서 false로 매핑된 파일 → 빈 CJS 모듈로 대체
                if (r.disabled) {
                    const dep_idx = try self.addDisabledModule(record.specifier);
                    self.modules.items[mod_idx].import_records[rec_i].resolved = dep_idx;
                    if (record.kind == .dynamic_import) {
                        try self.modules.items[mod_idx].addDynamicImport(self.allocator, dep_idx);
                    } else {
                        try self.modules.items[mod_idx].addDependency(self.allocator, dep_idx, self.modules.items);
                    }
                    continue;
                }

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

    /// ExportsKind.none 모듈을 소비하는 쪽에 따라 승격한다.
    /// - 다른 모듈이 `import`하면 → .esm
    /// - 다른 모듈이 `require()`하면 → .commonjs + wrap_kind = .cjs
    /// 모든 모듈의 import_records를 순회하여, 대상 모듈이 .none이면 승격.
    /// require가 import보다 우선: 이미 .esm으로 승격된 모듈도 require가 있으면 .commonjs로 변경.
    fn promoteExportsKinds(self: *ModuleGraph) void {
        for (self.modules.items) |m| {
            for (m.import_records) |rec| {
                if (rec.resolved.isNone()) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= self.modules.items.len) continue;

                var target = &self.modules.items[target_idx];

                if (rec.kind == .require) {
                    // require()로 소비 → CJS로 승격 (이미 ESM으로 승격된 것도 덮어씀, esbuild 동작)
                    if (target.exports_kind == .none or target.exports_kind == .esm) {
                        target.exports_kind = .commonjs;
                        target.wrap_kind = .cjs;
                    }
                } else if (rec.kind == .static_import or rec.kind == .side_effect or rec.kind == .re_export) {
                    // ESM import로 소비 → .none이면 승격
                    if (target.exports_kind == .none) {
                        // node_modules 내 .js 파일이 ESM/CJS 신호 없으면 CJS로 간주 (Node.js 기본값)
                        // package.json "type": "module"인 경우만 ESM
                        if (self.isImplicitCjs(target)) {
                            target.exports_kind = .commonjs;
                            target.wrap_kind = .cjs;
                        } else {
                            target.exports_kind = .esm;
                        }
                    }
                }
            }
        }
    }

    /// node_modules 내 .js 파일이 ESM/CJS 신호 없으면 CJS로 간주.
    /// Node.js 규칙: package.json "type": "module"이 없으면 .js는 CJS.
    fn isImplicitCjs(self: *ModuleGraph, module: *const Module) bool {
        // node_modules 밖이면 ESM으로 간주 (사용자 코드)
        const nm = "node_modules" ++ std.fs.path.sep_str;
        if (std.mem.indexOf(u8, module.path, nm) == null) return false;
        const ext = std.fs.path.extension(module.path);
        // .cjs/.cts는 항상 CJS (type 필드 무관)
        if (std.mem.eql(u8, ext, ".cjs") or std.mem.eql(u8, ext, ".cts")) return true;
        // .mjs/.mts는 항상 ESM
        if (std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".mts")) return false;
        // package.json "type": "module"이면 ESM
        if (self.isPackageTypeModule(module.path)) return false;
        return true;
    }

    /// 모듈 경로에서 가장 가까운 package.json의 "type" 필드가 "module"인지 확인.
    fn isPackageTypeModule(self: *ModuleGraph, module_path: []const u8) bool {
        const pkg_dir_path = findPackageDirPath(module_path) orelse return false;
        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{}) catch return false;
        defer pkg_dir.close();
        var parsed = pkg_json.parsePackageJson(self.allocator, pkg_dir) catch return false;
        defer parsed.deinit();
        return parsed.pkg.isModule();
    }

    /// TLA 전이적 전파: TLA 모듈을 static import하는 모듈도 TLA로 표시.
    /// await가 포함된 모듈의 실행이 완료되기 전에 이를 import하는 모듈이
    /// 실행될 수 없으므로, import하는 쪽도 TLA로 간주해야 한다.
    /// 동적 import는 비동기이므로 전파하지 않는다.
    fn propagateTopLevelAwait(self: *ModuleGraph) void {
        var changed = true;
        var iteration: u32 = 0;
        while (changed and iteration < 100) : (iteration += 1) {
            changed = false;
            for (self.modules.items) |*m| {
                if (m.uses_top_level_await) continue;
                for (m.import_records) |rec| {
                    if (rec.resolved.isNone()) continue;
                    // 동적 import는 비동기 → TLA 전파 불필요
                    if (rec.kind != .static_import and rec.kind != .side_effect and rec.kind != .re_export) continue;
                    const target_idx = @intFromEnum(rec.resolved);
                    if (target_idx >= self.modules.items.len) continue;
                    if (self.modules.items[target_idx].uses_top_level_await) {
                        m.uses_top_level_await = true;
                        changed = true;
                        break;
                    }
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

/// 스캔 결과와 파일 확장자로 모듈의 export 방식을 결정한다.
/// 우선순위: 1) ESM+CJS 혼용 → esm_with_dynamic_fallback
///          2) ESM만 → esm
///          3) CJS 신호 → commonjs
///          4) 확장자 (.cjs/.mjs 등) → commonjs/esm
///          5) 판별 불가 → none
fn determineExportsKind(
    scan: import_scanner.ScanResult,
    path: []const u8,
) types.ExportsKind {
    const has_cjs = scan.has_cjs_require or scan.has_module_exports or scan.has_exports_dot;

    // ESM + CJS 혼용
    if (scan.has_esm_syntax and has_cjs) return .esm_with_dynamic_fallback;

    // ESM만
    if (scan.has_esm_syntax) return .esm;

    // CJS 신호
    if (has_cjs) return .commonjs;

    // 확장자로 판별
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".cjs") or std.mem.eql(u8, ext, ".cts")) return .commonjs;
    if (std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".mts")) return .esm;

    return .none;
}

// ============================================================
// Tests
// ============================================================

fn createFile(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    const file = try dir.createFile(path, .{});
    file.close();
}

const writeFile = @import("test_helpers.zig").writeFile;

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

test "determineExportsKind: ESM only" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = true,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm, determineExportsKind(scan, "index.ts"));
}

test "determineExportsKind: CJS require" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = true,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "index.js"));
}

test "determineExportsKind: ESM + CJS mixed" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = true,
        .has_cjs_require = true,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm_with_dynamic_fallback, determineExportsKind(scan, "index.js"));
}

test "determineExportsKind: .cjs extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "lib.cjs"));
}

test "determineExportsKind: .mjs extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm, determineExportsKind(scan, "lib.mjs"));
}

test "determineExportsKind: no signals" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.none, determineExportsKind(scan, "script.js"));
}

test "determineExportsKind: exports_dot is CJS" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = true,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "index.js"));
}

test "determineExportsKind: .cts extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.commonjs, determineExportsKind(scan, "lib.cts"));
}

test "determineExportsKind: .mts extension" {
    const scan = import_scanner.ScanResult{
        .records = &.{},
        .has_esm_syntax = false,
        .has_cjs_require = false,
        .has_module_exports = false,
        .has_exports_dot = false,
    };
    try std.testing.expectEqual(types.ExportsKind.esm, determineExportsKind(scan, "lib.mts"));
}

// ============================================================
// sideEffects glob 패턴 매칭 테스트
// ============================================================

test "matchSideEffectsPatterns: *.css matches css files" {
    const patterns = &[_][]const u8{"*.css"};
    // CSS 파일은 side_effects=true (제거하면 안 됨)
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/style.css",
        "/app/node_modules/pkg",
        patterns,
    ));
    // 하위 디렉토리 CSS도 매칭 (basename 폴백)
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/src/theme.css",
        "/app/node_modules/pkg",
        patterns,
    ));
    // JS 파일은 매칭 안 됨 → side_effects=false (제거 가능)
    try std.testing.expect(!ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/index.js",
        "/app/node_modules/pkg",
        patterns,
    ));
}

test "matchSideEffectsPatterns: exact path match" {
    const patterns = &[_][]const u8{ "./src/polyfill.js", "*.css" };
    try std.testing.expect(ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/src/polyfill.js",
        "/app/node_modules/pkg",
        patterns,
    ));
    try std.testing.expect(!ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/src/utils.js",
        "/app/node_modules/pkg",
        patterns,
    ));
}

test "matchSideEffectsPatterns: no patterns = no side effects" {
    const patterns = &[_][]const u8{};
    try std.testing.expect(!ModuleGraph.matchSideEffectsPatterns(
        "/app/node_modules/pkg/index.js",
        "/app/node_modules/pkg",
        patterns,
    ));
}
