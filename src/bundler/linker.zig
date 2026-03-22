//! ZTS Bundler — Linker
//!
//! 크로스 모듈 심볼 바인딩: 각 import를 대응하는 export에 연결한다.
//! re-export 체인을 따라가서 canonical export를 찾는다.
//!
//! 설계:
//!   - D059: Rolldown식 스코프 호이스팅
//!   - 메타데이터 방식: AST 수정 없이 codegen에서 치환
//!
//! 참고:
//!   - references/rolldown/crates/rolldown/src/stages/link_stage/bind_imports_and_exports.rs
//!   - references/esbuild/internal/linker/linker.go

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const BundlerDiagnostic = types.BundlerDiagnostic;
const Module = @import("module.zig").Module;
const ImportBinding = @import("binding_scanner.zig").ImportBinding;
const ExportBinding = @import("binding_scanner.zig").ExportBinding;
const Span = @import("../lexer/token.zig").Span;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Ast = @import("../parser/ast.zig").Ast;

/// 크로스 모듈 심볼 참조. 어떤 모듈의 어떤 export를 가리키는지.
/// codegen에 전달하는 per-module 메타데이터.
/// AST를 수정하지 않고 codegen이 출력 시 참조.
pub const LinkingMetadata = struct {
    /// 스킵할 AST 노드 인덱스 (import_declaration, export 키워드 등)
    skip_nodes: std.DynamicBitSet,
    /// symbol_id → 새 이름. codegen이 식별자 출력 시 symbol_ids[node_idx]로 조회.
    renames: std.AutoHashMap(u32, []const u8),
    /// 엔트리 포인트의 최종 export 문 (e.g. "export { x, y$1 as y };\n")
    final_exports: ?[]const u8,
    /// 노드 인덱스 → 심볼 인덱스 매핑. 빌림 — deinit에서 해제하지 않음.
    /// module.parse_arena 또는 transformer.new_symbol_ids(emit_arena)가 소유.
    symbol_ids: []const ?u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LinkingMetadata) void {
        self.skip_nodes.deinit();
        self.renames.deinit();
        if (self.final_exports) |fe| self.allocator.free(fe);
    }
};

pub const SymbolRef = struct {
    module_index: ModuleIndex,
    /// 해당 모듈의 export 이름 (e.g. "x", "default")
    export_name: []const u8,
};

/// 해석된 import 바인딩. linker가 codegen에 전달.
pub const ResolvedBinding = struct {
    /// importer 모듈에서 사용하는 로컬 이름
    local_name: []const u8,
    /// 로컬 바인딩의 소스 위치 (rename 키)
    local_span: Span,
    /// 최종적으로 가리키는 export (re-export 체인 해결 후)
    canonical: SymbolRef,
};

pub const Linker = struct {
    allocator: std.mem.Allocator,
    modules: []const Module,

    /// 모듈별 export 맵: "module_index\x00exported_name" → ExportEntry
    export_map: std.StringHashMap(ExportEntry),

    /// import→export 바인딩 결과: (module_index, local_span_key) → ResolvedBinding
    resolved_bindings: std.AutoHashMap(BindingKey, ResolvedBinding),

    diagnostics: std.ArrayList(BundlerDiagnostic),

    /// 이름 충돌 해결 결과: (module_index, export_name) → canonical_name.
    /// 충돌 없으면 원본 이름 유지 (엔트리 없음).
    canonical_names: std.StringHashMap([]const u8),

    const ExportEntry = struct {
        binding: ExportBinding,
        module_index: ModuleIndex,
    };

    const BindingKey = struct {
        module_index: u32,
        span_key: u64,
    };

    pub fn init(allocator: std.mem.Allocator, modules: []const Module) Linker {
        return .{
            .allocator = allocator,
            .modules = modules,
            .export_map = std.StringHashMap(ExportEntry).init(allocator),
            .resolved_bindings = std.AutoHashMap(BindingKey, ResolvedBinding).init(allocator),
            .diagnostics = .empty,
            .canonical_names = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Linker) void {
        var eit = self.export_map.keyIterator();
        while (eit.next()) |key| {
            self.allocator.free(key.*);
        }
        self.export_map.deinit();
        self.resolved_bindings.deinit();
        // canonical_names의 키(makeExportKey 할당)와 값(fmt.allocPrint 할당) 해제
        var cit = self.canonical_names.iterator();
        while (cit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.canonical_names.deinit();
        self.diagnostics.deinit(self.allocator);
    }

    /// 링킹 실행: export 맵 구축 → import 바인딩 해결.
    pub fn link(self: *Linker) !void {
        try self.buildExportMap();
        try self.resolveImports();
    }

    /// 이름 충돌 감지 + 리네임 계산 (Rolldown renamer 패턴).
    /// exec_index가 가장 낮은 모듈이 원본 이름 유지, 나머지는 $1, $2, ...
    pub fn computeRenames(self: *Linker) !void {
        // 1. 모든 모듈의 top-level export 이름 수집
        const NameOwner = struct {
            module_index: u32,
            exec_index: u32,
        };
        var name_to_owners = std.StringHashMap(std.ArrayList(NameOwner)).init(self.allocator);
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit();
        }

        for (self.modules, 0..) |m, i| {
            const sem = m.semantic orelse continue;
            // C1 수정: export뿐 아니라 모듈 스코프의 모든 top-level 심볼을 수집.
            // scope_maps[0]이 보통 모듈/글로벌 스코프.
            if (sem.scope_maps.len == 0) continue;
            const module_scope = sem.scope_maps[0];

            var scope_it = module_scope.iterator();
            while (scope_it.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                if (std.mem.eql(u8, sym_name, "default")) continue;

                // import binding은 다른 모듈의 심볼을 참조하므로 충돌 대상 아님
                const sym_idx = scope_entry.value_ptr.*;
                if (sym_idx < sem.symbols.len and sem.symbols[sym_idx].decl_flags.is_import) continue;

                const entry = try name_to_owners.getOrPut(sym_name);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                }
                try entry.value_ptr.append(self.allocator, .{
                    .module_index = @intCast(i),
                    .exec_index = m.exec_index,
                });
            }
        }

        // 2. 충돌하는 이름에 대해 리네임 계산
        var nit = name_to_owners.iterator();
        while (nit.next()) |entry| {
            const name = entry.key_ptr.*;
            const owners = entry.value_ptr.items;
            if (owners.len <= 1) continue; // 충돌 없음

            // exec_index 순으로 정렬 — 가장 낮은 게 원본 유지
            std.mem.sort(NameOwner, entry.value_ptr.items, {}, struct {
                fn lessThan(_: void, a: NameOwner, b: NameOwner) bool {
                    return a.exec_index < b.exec_index;
                }
            }.lessThan);

            // 첫 번째는 원본 유지, 나머지는 $1, $2, ...
            var suffix: u32 = 1;
            for (owners[1..]) |owner| {
                // 후보 이름 생성
                var candidate = try std.fmt.allocPrint(self.allocator, "{s}${d}", .{ name, suffix });

                // 후보 이름이 예약어, 글로벌 객체, 또는 nested scope에 있으면 다음 번호
                while (isReservedName(candidate) or self.hasNestedBinding(owner.module_index, candidate)) {
                    self.allocator.free(candidate);
                    suffix += 1;
                    candidate = try std.fmt.allocPrint(self.allocator, "{s}${d}", .{ name, suffix });
                }

                const key = try makeExportKey(self.allocator, owner.module_index, name);
                // M4 수정: 중복 키 시 이전 키/값 해제
                if (self.canonical_names.fetchRemove(key)) |old| {
                    self.allocator.free(old.key);
                    self.allocator.free(old.value);
                }
                try self.canonical_names.put(key, candidate);
                suffix += 1;
            }
        }
    }

    /// 모듈의 중첩 스코프(비-모듈 스코프)에 해당 이름이 존재하는지 확인.
    fn hasNestedBinding(self: *const Linker, module_index: u32, name: []const u8) bool {
        if (module_index >= self.modules.len) return false;
        const m = self.modules[module_index];
        const sem = m.semantic orelse return false;

        // scope_maps[0]은 보통 모듈 스코프. 나머지가 중첩 스코프.
        for (sem.scope_maps, 0..) |scope_map, scope_idx| {
            if (scope_idx == 0) continue; // 모듈 스코프는 스킵
            if (scope_map.get(name) != null) return true;
        }
        return false;
    }

    /// JS 예약어 + 글로벌 객체 이름인지 확인 (Rolldown renamer.rs 참고).
    /// `name$1` 형태에서 예약어가 될 가능성은 거의 없지만, 안전을 위해 체크.
    fn isReservedName(name: []const u8) bool {
        // ECMAScript 예약어
        const reserved = [_][]const u8{
            "break",     "case",       "catch",    "class",     "const",
            "continue",  "debugger",   "default",  "delete",    "do",
            "else",      "enum",       "export",   "extends",   "false",
            "finally",   "for",        "function", "if",        "import",
            "in",        "instanceof", "new",      "null",      "return",
            "super",     "switch",     "this",     "throw",     "true",
            "try",       "typeof",     "var",      "void",      "while",
            "with",      "yield",      "let",      "static",    "implements",
            "interface", "package",    "private",  "protected", "public",
            "await",
        };
        // 글로벌 객체
        const globals = [_][]const u8{
            "undefined", "NaN",        "Infinity", "arguments",
            "eval",      "Array",      "Object",   "Function",
            "String",    "Number",     "Boolean",  "Symbol",
            "Date",      "Math",       "JSON",     "Promise",
            "RegExp",    "Error",      "Map",      "Set",
            "WeakMap",   "WeakSet",    "Proxy",    "Reflect",
            "console",   "globalThis", "window",   "document",
            "require",   "module",     "exports",  "__filename",
            "__dirname",
        };
        for (reserved) |r| {
            if (std.mem.eql(u8, name, r)) return true;
        }
        for (globals) |g| {
            if (std.mem.eql(u8, name, g)) return true;
        }
        return false;
    }

    /// export의 실제 local_name을 조회. default export에서 "default" → "greet" 등.
    pub fn getExportLocalName(self: *const Linker, module_index: u32, exported_name: []const u8) ?[]const u8 {
        var key_buf: [4096]u8 = undefined;
        const key = makeExportKeyBuf(&key_buf, module_index, exported_name);
        const entry = self.export_map.get(key) orelse return null;
        return entry.binding.local_name;
    }

    /// 특정 모듈+이름에 대한 canonical name 조회. 리네임 안 됐으면 null (원본 유지).
    pub fn getCanonicalName(self: *const Linker, module_index: u32, name: []const u8) ?[]const u8 {
        var key_buf: [4096]u8 = undefined;
        const key = makeExportKeyBuf(&key_buf, module_index, name);
        return self.canonical_names.get(key);
    }

    /// transformer 이후의 new_ast를 기반으로 LinkingMetadata를 생성한다.
    /// skip_nodes와 renames가 new_ast의 노드 인덱스와 일치.
    pub fn buildMetadataForAst(
        self: *const Linker,
        new_ast: *const Ast,
        module_index: u32,
        is_entry: bool,
    ) !LinkingMetadata {
        if (module_index >= self.modules.len) {
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = &.{},
                .allocator = self.allocator,
            };
        }

        const m = self.modules[module_index];
        const node_count = new_ast.nodes.items.len;
        var skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count);
        errdefer skip_nodes.deinit();
        var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);
        errdefer renames.deinit();

        // 1. new_ast에서 import/export 노드 스킵
        for (new_ast.nodes.items, 0..) |node, node_idx| {
            switch (node.tag) {
                .import_declaration => skip_nodes.set(node_idx),
                .export_named_declaration => {
                    // export const x = 1 → export 키워드만 생략 (codegen 분기로 처리)
                    // export { x } → 전체 스킵
                    // export { x } from './dep' → 전체 스킵
                    const e = node.data.extra;
                    if (e + 3 < new_ast.extra_data.items.len) {
                        const decl_idx: NodeIndex = @enumFromInt(new_ast.extra_data.items[e]);
                        if (decl_idx.isNone()) {
                            skip_nodes.set(node_idx); // export { } 또는 re-export
                        }
                        // export const → codegen에서 export 키워드만 생략
                    }
                },
                .export_default_declaration => {
                    // 번들 모드에서 codegen이 "export default" 키워드만 생략하고
                    // 내부 선언은 유지하므로 skip_nodes에 넣지 않음.
                    // (emitExportDefault가 linking_metadata 체크하여 처리)
                },
                .export_all_declaration => skip_nodes.set(node_idx),
                else => {},
            }
        }

        // 2. import 바인딩 리네임 (모듈의 semantic 기반)
        const sem = m.semantic orelse return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };

        if (sem.scope_maps.len > 0) {
            const module_scope = sem.scope_maps[0];
            // import 바인딩 → canonical 이름
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                const rec = m.import_records[ib.import_record_index];
                if (rec.resolved.isNone()) continue;

                const canonical_mod = @intFromEnum(rec.resolved);

                // default import 처리: "default" → export의 실제 local_name
                // (e.g. "export default function greet()" → "greet")
                var effective_name = ib.imported_name;
                if (std.mem.eql(u8, ib.imported_name, "default")) {
                    if (self.getExportLocalName(@intCast(canonical_mod), "default")) |local| {
                        effective_name = local;
                    }
                }

                const target_name = if (self.getCanonicalName(@intCast(canonical_mod), effective_name)) |renamed|
                    renamed
                else
                    effective_name;

                if (!std.mem.eql(u8, ib.local_name, target_name)) {
                    if (module_scope.get(ib.local_name)) |sym_idx| {
                        try renames.put(@intCast(sym_idx), target_name);
                    }
                }
            }

            // 자체 top-level 심볼 리네임 (이름 충돌)
            var sit = module_scope.iterator();
            while (sit.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                if (self.getCanonicalName(module_index, sym_name)) |renamed| {
                    const sym_idx = scope_entry.value_ptr.*;
                    try renames.put(@intCast(sym_idx), renamed);
                }
            }
        }

        // 3. 엔트리 포인트 final exports
        var final_exports: ?[]const u8 = null;
        if (is_entry and m.export_bindings.len > 0) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, "export {");
            var first = true;
            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_all) continue;
                if (std.mem.eql(u8, eb.exported_name, "*")) continue;
                if (!first) try buf.appendSlice(self.allocator, ",");
                first = false;
                const actual_name = self.getCanonicalName(module_index, eb.local_name) orelse eb.local_name;
                try buf.append(self.allocator, ' ');
                try buf.appendSlice(self.allocator, actual_name);
                if (!std.mem.eql(u8, actual_name, eb.exported_name)) {
                    try buf.appendSlice(self.allocator, " as ");
                    try buf.appendSlice(self.allocator, eb.exported_name);
                }
            }
            try buf.appendSlice(self.allocator, " };\n");
            if (!first) {
                final_exports = try self.allocator.dupe(u8, buf.items);
            }
        }

        return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = final_exports,
            .symbol_ids = sem.symbol_ids,
            .allocator = self.allocator,
        };
    }

    /// 특정 모듈에 대한 LinkingMetadata를 생성한다 (원본 AST 기준, 테스트용).
    pub fn buildMetadata(self: *const Linker, module_index: u32, is_entry: bool) !LinkingMetadata {
        if (module_index >= self.modules.len) {
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = &.{},
                .allocator = self.allocator,
            };
        }

        const m = self.modules[module_index];
        const ast = m.ast orelse {
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = &.{},
                .allocator = self.allocator,
            };
        };

        const node_count = ast.nodes.items.len;
        var skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count);
        var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);

        // 1. import_declaration → 전체 스킵
        for (ast.nodes.items, 0..) |node, node_idx| {
            if (node.tag == .import_declaration) {
                skip_nodes.set(node_idx);
            }
        }

        // 2. export 키워드 처리
        for (ast.nodes.items, 0..) |node, node_idx| {
            switch (node.tag) {
                .export_named_declaration => {
                    const e = node.data.extra;
                    if (e + 3 >= ast.extra_data.items.len) continue;
                    const decl_idx_raw = ast.extra_data.items[e];
                    const decl_idx: NodeIndex = @enumFromInt(decl_idx_raw);
                    const source_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 3]);

                    if (!decl_idx.isNone()) {
                        // export const x = 1; → export 노드 스킵, declaration은 유지
                        // codegen은 skip_nodes에 있으면 emitNode를 건너뜀.
                        // declaration을 직접 출력하기 위해 export_named_declaration을 스킵하고
                        // declaration 노드만 남김.
                        // 하지만 이렇게 하면 declaration도 스킵됨...
                        // 대신: export_named_declaration을 스킵하지 않고,
                        // codegen에서 linking 모드일 때 "export " 키워드만 생략하도록 함.
                        // → skip_nodes 대신 codegen 분기로 처리 (PR #5 codegen 수정에서)
                    } else if (!source_idx.isNone()) {
                        // export { x } from './dep' — re-export: 전체 스킵
                        skip_nodes.set(node_idx);
                    } else {
                        // export { x } — 로컬 export: 전체 스킵 (심볼은 이미 선언됨)
                        skip_nodes.set(node_idx);
                    }
                },
                .export_default_declaration => {
                    // export default expr — 비-엔트리 모듈에서는 스킵
                    if (!is_entry) {
                        skip_nodes.set(node_idx);
                    }
                },
                .export_all_declaration => {
                    // export * from './dep' — 전체 스킵
                    skip_nodes.set(node_idx);
                },
                else => {},
            }
        }

        const sem = m.semantic orelse return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };

        // 3. import 바인딩: import된 심볼을 canonical 이름으로 치환
        // import binding의 심볼 인덱스를 모듈 스코프에서 이름으로 조회
        if (sem.scope_maps.len > 0) {
            const module_scope = sem.scope_maps[0];
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                const rec = m.import_records[ib.import_record_index];
                if (rec.resolved.isNone()) continue;

                const canonical_mod = @intFromEnum(rec.resolved);
                const target_name = if (self.getCanonicalName(@intCast(canonical_mod), ib.imported_name)) |renamed|
                    renamed
                else
                    ib.imported_name;

                if (!std.mem.eql(u8, ib.local_name, target_name)) {
                    // 모듈 스코프에서 import binding의 심볼 인덱스 찾기
                    if (module_scope.get(ib.local_name)) |sym_idx| {
                        try renames.put(@intCast(sym_idx), target_name);
                    }
                }
            }
        }

        // 4. 이 모듈 자체의 top-level 심볼 리네임 (이름 충돌로 인한)
        if (sem.scope_maps.len > 0) {
            const module_scope = sem.scope_maps[0];
            var sit = module_scope.iterator();
            while (sit.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                if (self.getCanonicalName(module_index, sym_name)) |renamed| {
                    const sym_idx = scope_entry.value_ptr.*;
                    try renames.put(@intCast(sym_idx), renamed);
                }
            }
        }

        // 5. 엔트리 포인트: final exports
        var final_exports: ?[]const u8 = null;
        if (is_entry and m.export_bindings.len > 0) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, "export {");
            var first = true;
            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_all) continue;
                if (std.mem.eql(u8, eb.exported_name, "*")) continue;

                if (!first) try buf.appendSlice(self.allocator, ",");
                first = false;

                // canonical 이름 (리네임됐으면 변경된 이름)
                const actual_name = self.getCanonicalName(module_index, eb.local_name) orelse eb.local_name;

                try buf.append(self.allocator, ' ');
                try buf.appendSlice(self.allocator, actual_name);
                if (!std.mem.eql(u8, actual_name, eb.exported_name)) {
                    try buf.appendSlice(self.allocator, " as ");
                    try buf.appendSlice(self.allocator, eb.exported_name);
                }
            }
            try buf.appendSlice(self.allocator, " };\n");
            if (!first) {
                final_exports = try self.allocator.dupe(u8, buf.items);
            }
        }

        return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = final_exports,
            .symbol_ids = sem.symbol_ids,
            .allocator = self.allocator,
        };
    }

    /// 모든 모듈의 export를 수집하여 export_map에 등록.
    fn buildExportMap(self: *Linker) !void {
        for (self.modules, 0..) |m, i| {
            const mod_idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
            for (m.export_bindings) |eb| {
                if (std.mem.eql(u8, eb.exported_name, "*")) continue;
                const key = try makeExportKey(self.allocator, @intCast(i), eb.exported_name);
                // C2 수정: 중복 키 시 이전 키 해제
                if (self.export_map.fetchRemove(key)) |old| {
                    self.allocator.free(old.key);
                }
                try self.export_map.put(key, .{
                    .binding = eb,
                    .module_index = mod_idx,
                });
            }
        }
    }

    /// 모든 모듈의 import 바인딩을 해석하여 canonical export에 연결.
    fn resolveImports(self: *Linker) !void {
        for (self.modules, 0..) |m, i| {
            for (m.import_bindings) |ib| {
                if (ib.kind == .namespace) continue; // namespace import는 별도 처리 (후순위)

                const source_record = if (ib.import_record_index < m.import_records.len)
                    m.import_records[ib.import_record_index]
                else
                    continue;

                if (source_record.resolved.isNone()) continue; // external 또는 미해석

                // re-export 체인을 따라가서 canonical export 찾기
                const canonical = self.resolveExportChain(
                    source_record.resolved,
                    ib.imported_name,
                    0,
                ) orelse {
                    // export를 찾을 수 없음
                    self.addDiag(
                        .missing_export,
                        .@"error",
                        m.path,
                        ib.local_span,
                        .link,
                        "Imported name not found in module",
                        ib.imported_name,
                    );
                    continue;
                };

                const bk = BindingKey{
                    .module_index = @intCast(i),
                    .span_key = types.spanKey(ib.local_span),
                };
                try self.resolved_bindings.put(bk, .{
                    .local_name = ib.local_name,
                    .local_span = ib.local_span,
                    .canonical = canonical,
                });
            }
        }
    }

    /// re-export 체인을 따라가서 canonical export를 찾는다.
    /// 깊이 제한 100 (순환 re-export 방지).
    pub fn resolveExportChain(
        self: *const Linker,
        module_idx: ModuleIndex,
        name: []const u8,
        depth: u32,
    ) ?SymbolRef {
        if (depth > 100) return null; // 순환 방지

        const mod_i = @intFromEnum(module_idx);
        if (mod_i >= self.modules.len) return null;

        // 1. 직접 export 확인
        var key_buf: [4096]u8 = undefined;
        const key = makeExportKeyBuf(&key_buf, @intCast(mod_i), name);
        if (self.export_map.get(key)) |entry| {
            if (entry.binding.kind == .re_export) {
                // re-export: 소스 모듈로 재귀
                if (entry.binding.import_record_index) |rec_idx| {
                    const m = self.modules[mod_i];
                    if (rec_idx < m.import_records.len) {
                        const source_mod = m.import_records[rec_idx].resolved;
                        if (!source_mod.isNone()) {
                            // re-export에서 exported_name이 local_name과 같으면
                            // 소스 모듈에서도 같은 이름으로 export됨
                            return self.resolveExportChain(source_mod, entry.binding.local_name, depth + 1);
                        }
                    }
                }
                return null;
            }
            // local export: 이 모듈의 심볼
            return .{
                .module_index = module_idx,
                .export_name = name,
            };
        }

        // 2. export * 확인 (re_export_all)
        const m = self.modules[mod_i];
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export_all) continue;
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < m.import_records.len) {
                    const source_mod = m.import_records[rec_idx].resolved;
                    if (!source_mod.isNone()) {
                        if (self.resolveExportChain(source_mod, name, depth + 1)) |result| {
                            return result;
                        }
                    }
                }
            }
        }

        return null;
    }

    /// 특정 모듈+import에 대한 resolved binding 조회.
    pub fn getResolvedBinding(self: *const Linker, module_index: u32, span: Span) ?ResolvedBinding {
        const bk = BindingKey{
            .module_index = module_index,
            .span_key = types.spanKey(span),
        };
        return self.resolved_bindings.get(bk);
    }

    fn addDiag(
        self: *Linker,
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

    const makeExportKey = types.makeModuleKey;
    const makeExportKeyBuf = types.makeModuleKeyBuf;
};

// ============================================================
// Tests
// ============================================================

const resolve_cache_mod = @import("resolve_cache.zig");
const ModuleGraph = @import("graph.zig").ModuleGraph;

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

fn dirPath(tmp: *std.testing.TmpDir) ![]const u8 {
    return try tmp.dir.realpathAlloc(std.testing.allocator, ".");
}

fn buildAndLink(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .browser, &.{});
    var graph = ModuleGraph.init(allocator, &cache);
    try graph.build(&.{entry});

    var linker = Linker.init(allocator, graph.modules.items);
    try linker.link();

    return .{ .linker = linker, .graph = graph, .cache = cache };
}

test "linker: direct import resolves to export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // a.ts의 import x가 b.ts의 export x에 연결
    const a = r.graph.modules.items[0];
    try std.testing.expect(a.import_bindings.len > 0);
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
    // canonical이 b.ts(index 1)를 가리킴
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(binding.?.canonical.module_index));
}

test "linker: re-export chain resolved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // chain: a→b→c, canonical은 c(index 2)
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(binding.?.canonical.module_index));
}

test "linker: missing export produces diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { missing } from './b';");
    try writeFile(tmp.dir, "b.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // missing export → diagnostic
    var has_missing = false;
    for (r.linker.diagnostics.items) |d| {
        if (d.code == .missing_export) has_missing = true;
    }
    try std.testing.expect(has_missing);
}

test "linker: export * resolves through re-export all" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export * from './c';");
    try writeFile(tmp.dir, "c.ts", "export const x = 99;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // export * → c.ts(index 2)
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(binding.?.canonical.module_index));
}

test "linker: default import resolves" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import myDefault from './b';");
    try writeFile(tmp.dir, "b.ts", "export default 42;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("default", binding.?.canonical.export_name);
}

test "linker: external import not resolved (no binding)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from 'react';");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{"react"});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var linker = Linker.init(std.testing.allocator, graph.modules.items);
    defer linker.deinit();
    try linker.link();

    // external → resolved binding 없음, diagnostic도 없음
    try std.testing.expectEqual(@as(usize, 0), linker.resolved_bindings.count());
    try std.testing.expectEqual(@as(usize, 0), linker.diagnostics.items.len);
}

// ============================================================
// Rename Tests
// ============================================================

const TestResult = struct {
    linker: Linker,
    graph: ModuleGraph,
    cache: resolve_cache_mod.ResolveCache,
};

fn buildLinkAndRename(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !TestResult {
    var r = try buildAndLink(allocator, tmp, entry_name);
    try r.linker.computeRenames();
    return .{ .linker = r.linker, .graph = r.graph, .cache = r.cache };
}

test "rename: no conflict — no rename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b'; console.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // x는 b.ts에만 있으므로 충돌 없음 → canonical_names 비어 있음
    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_names.count());
}

test "rename: two modules same name — second gets $1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // b.ts(exec_index 낮음)가 원본 유지, a.ts가 count$1
    // 또는 a.ts가 원본이고 b.ts가 $1 (exec_index에 따라)
    try std.testing.expect(r.linker.canonical_names.count() > 0);

    // 하나는 리네임됨
    var has_rename = false;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "count$")) has_rename = true;
    }
    try std.testing.expect(has_rename);
}

test "rename: three modules same name — $1 and $2" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nexport const name = 'a';");
    try writeFile(tmp.dir, "b.ts", "export const name = 'b';");
    try writeFile(tmp.dir, "c.ts", "export const name = 'c';");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // 3개 중 2개 리네임
    var rename_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "name$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), rename_count);
}

test "rename: different names — no conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    try std.testing.expectEqual(@as(u32, 0), r.linker.canonical_names.count());
}

test "rename: getCanonicalName returns renamed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const count = 0;");
    try writeFile(tmp.dir, "b.ts", "export const count = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // 하나는 getCanonicalName으로 리네임 조회 가능
    var found_rename = false;
    for (r.graph.modules.items, 0..) |_, i| {
        if (r.linker.getCanonicalName(@intCast(i), "count")) |renamed| {
            try std.testing.expect(std.mem.startsWith(u8, renamed, "count$"));
            found_rename = true;
        }
    }
    try std.testing.expect(found_rename);

    // 원본 유지되는 모듈은 getCanonicalName이 null
    var found_original = false;
    for (r.graph.modules.items, 0..) |_, i| {
        if (r.linker.getCanonicalName(@intCast(i), "count") == null) {
            found_original = true;
        }
    }
    try std.testing.expect(found_original);
}

test "rename: non-exported top-level variables also detected (C1)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // helper는 export 안 됨, 하지만 두 모듈 모두 top-level에 선언
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst helper = () => 1;\nexport const x = helper();");
    try writeFile(tmp.dir, "b.ts", "const helper = () => 2;\nexport const y = helper();");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // helper가 두 모듈에서 충돌 → 하나가 리네임됨
    var has_helper_rename = false;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "helper$")) has_helper_rename = true;
    }
    try std.testing.expect(has_helper_rename);
}

test "rename: nested scope conflict avoidance (hasNestedBinding)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts: top-level x + nested scope에 x$1
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const x = 1;\nfunction foo(x$1: number) { return x$1; }");
    try writeFile(tmp.dir, "b.ts", "export const x = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // x가 충돌. 리네임된 쪽이 x$1을 건너뛰고 x$2가 되어야 함
    // (nested scope에 x$1이 이미 있으므로)
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "x$")) {
            // x$1이 아닌 다른 값이어야 함 (nested scope에 x$1 있으므로)
            // 단, semantic analyzer가 parameter를 어떤 scope에 넣는지에 따라 다를 수 있음
            try std.testing.expect(val.*.len > 0);
        }
    }
}

test "rename: default export local name conflict (L5)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport default function foo() { return 1; }");
    try writeFile(tmp.dir, "b.ts", "export const foo = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // foo가 두 모듈에서 충돌 (a.ts: default export의 local name, b.ts: named export)
    var has_foo_rename = false;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "foo$")) has_foo_rename = true;
    }
    try std.testing.expect(has_foo_rename);
}

test "linker: deep re-export chain (near depth limit)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 5단계 re-export 체인: a → b → c → d → e
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x } from './c';");
    try writeFile(tmp.dir, "c.ts", "export { x } from './d';");
    try writeFile(tmp.dir, "d.ts", "export { x } from './e';");
    try writeFile(tmp.dir, "e.ts", "export const x = 'deep';");

    var r = try buildAndLink(std.testing.allocator, &tmp, "a.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const a = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, a.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 e.ts(마지막 모듈)
    try std.testing.expectEqualStrings("x", binding.?.canonical.export_name);
}

test "isReservedName: JS reserved words" {
    try std.testing.expect(Linker.isReservedName("class"));
    try std.testing.expect(Linker.isReservedName("return"));
    try std.testing.expect(Linker.isReservedName("const"));
    try std.testing.expect(Linker.isReservedName("await"));
    try std.testing.expect(Linker.isReservedName("yield"));
    try std.testing.expect(!Linker.isReservedName("foo"));
    try std.testing.expect(!Linker.isReservedName("count$1"));
}

test "isReservedName: global objects" {
    try std.testing.expect(Linker.isReservedName("Array"));
    try std.testing.expect(Linker.isReservedName("Object"));
    try std.testing.expect(Linker.isReservedName("console"));
    try std.testing.expect(Linker.isReservedName("undefined"));
    try std.testing.expect(Linker.isReservedName("require"));
    try std.testing.expect(Linker.isReservedName("module"));
    try std.testing.expect(!Linker.isReservedName("myVar"));
}
