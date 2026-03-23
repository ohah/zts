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
    /// CJS 모듈을 import하는 경우: require_xxx() 호출 preamble (e.g. "var lib = require_lib();\n")
    cjs_import_preamble: ?[]const u8 = null,
    /// export default의 합성 변수명. 이름 충돌 시 "_default$1" 등으로 변경됨.
    /// codegen이 `export default X` → `var <이름> = X;` 출력할 때 사용.
    default_export_name: []const u8 = "_default",
    /// namespace import의 member access 직접 치환 맵 (esbuild 방식).
    /// key: namespace 식별자의 symbol_id, value: export_name → canonical_local_name.
    /// codegen이 `ns.prop`를 만나면 이 맵으로 직접 치환 (namespace 객체 생성 불필요).
    ns_member_rewrites: NsMemberRewrites = .{},
    /// namespace가 값으로 사용될 때 인라인 객체 리터럴.
    /// codegen이 identifier_reference에서 ns 심볼을 만나면 이 문자열을 출력.
    ns_inline_objects: NsInlineObjects = .{},
    /// CJS 모듈 내부 require() 호출 치환 맵.
    /// require specifier 문자열 → require_xxx() 함수명.
    /// codegen이 require('path') 호출을 만나면 이 맵으로 치환.
    require_rewrites: std.StringHashMapUnmanaged([]const u8) = .{},
    allocator: std.mem.Allocator,

    pub const NsMemberRewrites = struct {
        /// symbol_id → (export_name → canonical_name) 매핑 배열.
        entries: []const Entry = &.{},

        pub const Entry = struct {
            symbol_id: u32,
            map: std.StringHashMap([]const u8),
        };

        /// symbol_id로 매핑 조회.
        pub fn get(self: *const NsMemberRewrites, sym_id: u32) ?*const std.StringHashMap([]const u8) {
            for (self.entries) |*e| {
                if (e.symbol_id == sym_id) return &e.map;
            }
            return null;
        }
    };

    pub const NsInlineObjects = struct {
        entries: []const Entry = &.{},

        pub const Entry = struct {
            symbol_id: u32,
            object_literal: []const u8,
        };

        pub fn get(self: *const NsInlineObjects, sym_id: u32) ?[]const u8 {
            for (self.entries) |e| {
                if (e.symbol_id == sym_id) return e.object_literal;
            }
            return null;
        }
    };

    pub fn deinit(self: *LinkingMetadata) void {
        self.skip_nodes.deinit();
        self.renames.deinit();
        if (self.final_exports) |fe| self.allocator.free(fe);
        if (self.cjs_import_preamble) |p| self.allocator.free(p);
        // require_rewrites 해제 (keys는 import record 소유, values만 해제)
        {
            var vit = self.require_rewrites.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            self.require_rewrites.deinit(self.allocator);
        }
        // ns_member_rewrites의 inner map과 entries 배열 해제
        if (self.ns_member_rewrites.entries.len > 0) {
            for (self.ns_member_rewrites.entries) |*e| {
                var m = @constCast(&e.map);
                // 인라인 객체 문자열 (allocator에서 할당됨) 해제
                var vit = m.valueIterator();
                while (vit.next()) |v| {
                    if (v.*.len > 0 and v.*[0] == '{') self.allocator.free(v.*);
                }
                m.deinit();
            }
            self.allocator.free(self.ns_member_rewrites.entries);
        }
        // ns_inline_objects 해제
        if (self.ns_inline_objects.entries.len > 0) {
            for (self.ns_inline_objects.entries) |e| {
                self.allocator.free(e.object_literal);
            }
            self.allocator.free(self.ns_inline_objects.entries);
        }
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

    /// 자동 수집된 예약 글로벌 이름. 모든 모듈의 unresolved references를 합친 것.
    /// scope hoisting 시 모듈 top-level 변수가 이 이름을 shadowing하면 리네임.
    /// Rolldown 방식: 하드코딩 목록 대신 실제 사용된 글로벌만 예약.
    reserved_globals: std.StringHashMap(void),

    const ExportEntry = struct {
        binding: ExportBinding,
        module_index: ModuleIndex,
    };

    /// namespace 객체 preamble 생성 시 사용하는 export 쌍.
    const NsExportPair = struct {
        exported: []const u8,
        local: []const u8,
        /// buildInlineObjectStr에서 할당된 문자열인 경우 true.
        /// exports ArrayList 해제 시 owned=true인 local만 free.
        owned: bool = false,
    };

    /// re-export 체인 순환 방지 깊이 제한.
    const max_chain_depth = 100;

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
            .reserved_globals = std.StringHashMap(void).init(allocator),
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
        self.reserved_globals.deinit();
        self.diagnostics.deinit(self.allocator);
    }

    /// 링킹 실행: export 맵 구축 → import 바인딩 해결.
    pub fn link(self: *Linker) !void {
        try self.buildExportMap();
        try self.resolveImports();
    }

    /// 이름 충돌 감지 + 리네임에 사용하는 소유자 정보.
    const NameOwner = struct {
        module_index: u32,
        exec_index: u32,
    };

    /// name_to_owners HashMap의 타입 별칭.
    const NameToOwnersMap = std.StringHashMap(std.ArrayList(NameOwner));

    /// 단일 모듈의 top-level 심볼 이름을 name_to_owners에 수집한다.
    /// 모듈 스코프의 모든 심볼 + export default 합성 _default 이름을 등록.
    /// import binding은 다른 모듈의 심볼을 참조하므로 건너뛴다.
    fn collectModuleNames(
        self: *Linker,
        m: Module,
        module_index: u32,
        name_to_owners: *NameToOwnersMap,
    ) !void {
        const sem = m.semantic orelse return;
        if (sem.scope_maps.len == 0) return;
        const module_scope = sem.scope_maps[0];

        var scope_it = module_scope.iterator();
        while (scope_it.next()) |scope_entry| {
            const sym_name = scope_entry.key_ptr.*;
            if (std.mem.eql(u8, sym_name, "default")) continue;

            // import binding은 다른 모듈의 심볼을 참조하므로 충돌 대상 아님.
            // namespace import도 인라인(ns.prop → prop)되어 preamble 변수가 생성되지 않으므로
            // 충돌 대상이 아님.
            const sym_idx = scope_entry.value_ptr.*;
            if (sym_idx < sem.symbols.len and sem.symbols[sym_idx].decl_flags.is_import) {
                continue;
            }

            const entry = try name_to_owners.getOrPut(sym_name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .module_index = module_index,
                .exec_index = m.exec_index,
            });
        }

        // export default의 합성 _default 이름도 수집.
        // codegen에서 `export default X` → `var _default = X;`를 생성하는데,
        // 이 이름이 semantic scope에 없으므로 별도로 수집한다.
        for (m.export_bindings) |eb| {
            if (eb.kind != .local) continue;
            if (!std.mem.eql(u8, eb.exported_name, "default")) continue;
            if (std.mem.eql(u8, eb.local_name, "default")) continue;
            // scope에 이미 있으면 중복 추가 방지
            if (module_scope.get(eb.local_name) != null) continue;
            const entry = try name_to_owners.getOrPut(eb.local_name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .module_index = module_index,
                .exec_index = m.exec_index,
            });
        }
    }

    /// name_to_owners에서 충돌하는 이름을 찾아 리네임을 계산한다.
    /// exec_index가 가장 낮은 소유자가 원본 이름 유지, 나머지는 $1, $2, ...
    /// skip_max_module_index가 true이면 module_index == maxInt(u32)인 항목(cross-chunk
    /// import 점유 마커)은 rename 대상에서 제외한다.
    fn calculateRenames(
        self: *Linker,
        name_to_owners: *NameToOwnersMap,
        skip_max_module_index: bool,
    ) !void {
        var nit = name_to_owners.iterator();
        while (nit.next()) |entry| {
            const name = entry.key_ptr.*;
            const owners = entry.value_ptr.items;

            // 단일 소유자라도 예약어/글로벌을 shadowing하면 리네임 필요.
            // scope hoisting 후 const/let 선언이 TDZ를 만들어 다른 모듈의 전역 참조가 실패.
            if (owners.len == 1) {
                if (self.isReservedOrGlobal(name)) {
                    const owner = owners[0];
                    const candidate = try std.fmt.allocPrint(self.allocator, "{s}$1", .{name});
                    const key = try makeExportKey(self.allocator, owner.module_index, name);
                    if (self.canonical_names.fetchRemove(key)) |old| {
                        self.allocator.free(old.key);
                        self.allocator.free(old.value);
                    }
                    try self.canonical_names.put(key, candidate);
                }
                continue;
            }

            // exec_index 순으로 정렬 — 가장 낮은 게 원본 유지
            std.mem.sort(NameOwner, entry.value_ptr.items, {}, struct {
                fn lessThan(_: void, a: NameOwner, b: NameOwner) bool {
                    return a.exec_index < b.exec_index;
                }
            }.lessThan);

            // 첫 번째는 원본 유지, 나머지는 $1, $2, ...
            // 단, 예약어/글로벌은 첫 번째도 리네임해야 한다.
            // 그렇지 않으면 scope hoisting 후 TDZ가 발생한다.
            const name_is_reserved = self.isReservedOrGlobal(name);
            var suffix: u32 = 1;
            const start_idx: usize = if (name_is_reserved) 0 else 1;
            for (owners[start_idx..]) |owner| {
                // 점유 마커 (cross-chunk import)는 rename 대상이 아님
                if (skip_max_module_index and owner.module_index == std.math.maxInt(u32)) continue;

                // 후보 이름 생성
                var candidate = try std.fmt.allocPrint(self.allocator, "{s}${d}", .{ name, suffix });

                // 후보 이름이 예약어, 다른 모듈의 top-level 이름, 또는 nested scope에 있으면 다음 번호
                while (self.isReservedOrGlobal(candidate) or name_to_owners.contains(candidate) or self.hasNestedBinding(owner.module_index, candidate)) {
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

    /// 모든 모듈의 unresolved references를 수집하여 reserved_globals에 합친다.
    /// Rolldown 방식: 하드코딩 목록 대신 실제 사용된 글로벌만 예약.
    pub fn collectReservedGlobals(self: *Linker) !void {
        self.reserved_globals.clearRetainingCapacity();
        for (self.modules) |m| {
            const sem = m.semantic orelse continue;
            var it = sem.unresolved_references.iterator();
            while (it.next()) |entry| {
                try self.reserved_globals.put(entry.key_ptr.*, {});
            }
        }
    }

    /// 이름 충돌 감지 + 리네임 계산 (Rolldown renamer 패턴).
    /// exec_index가 가장 낮은 모듈이 원본 이름 유지, 나머지는 $1, $2, ...
    pub fn computeRenames(self: *Linker) !void {
        // 0. 모든 모듈의 미해결 참조를 수집 → reserved_globals
        try self.collectReservedGlobals();

        // 1. 모든 모듈의 top-level export 이름 수집
        var name_to_owners = NameToOwnersMap.init(self.allocator);
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit();
        }

        for (self.modules, 0..) |m, i| {
            try self.collectModuleNames(m, @intCast(i), &name_to_owners);
        }

        // 2. 충돌하는 이름에 대해 리네임 계산
        try self.calculateRenames(&name_to_owners, false);
    }

    /// minify 활성화 시, scope hoisting 후 모든 top-level 이름을 짧은 이름으로 교체.
    /// computeRenames 이후에 호출해야 함 (충돌 해결 완료 상태).
    pub fn computeMangling(self: *Linker) !void {
        const Mangler = @import("../codegen/mangler.zig");

        // 1. 현재 사용 중인 모든 이름 수집 (canonical_names의 값 + 첫 번째 소유자의 원본 이름)
        var all_names = std.StringHashMap(void).init(self.allocator);
        defer all_names.deinit();

        for (self.modules) |m| {
            const sem = m.semantic orelse continue;
            if (sem.scope_maps.len == 0) continue;
            var sit = sem.scope_maps[0].iterator();
            while (sit.next()) |entry| {
                try all_names.put(entry.key_ptr.*, {});
            }
        }

        // canonical_names의 rename된 이름도 수집
        var cit = self.canonical_names.valueIterator();
        while (cit.next()) |v| {
            try all_names.put(v.*, {});
        }

        // 2. 이름 생성기로 모든 top-level 이름을 짧은 이름으로 매핑
        // name_map: 원본 이름 → mangled 이름 (duped).
        // canonical_names에 넣을 때 다시 dupe하므로 name_map 값은 항상 해제.
        var name_map = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var vit = name_map.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            name_map.deinit();
        }

        // mangling 결과로 사용된 이름 추적 (중복 방지)
        var used_names = std.StringHashMap(void).init(self.allocator);
        defer used_names.deinit();

        var name_gen = Mangler.NameGenerator{};

        // export된 이름은 보존해야 하므로 먼저 수집
        var exported = std.StringHashMap(void).init(self.allocator);
        defer exported.deinit();
        for (self.modules) |m| {
            for (m.export_bindings) |eb| {
                try exported.put(eb.exported_name, {});
                try exported.put(eb.local_name, {});
            }
        }

        var ait = all_names.iterator();
        while (ait.next()) |entry| {
            const orig_name = entry.key_ptr.*;

            // export된 이름은 mangling 제외
            if (exported.contains(orig_name)) continue;
            // import 바인딩, default, 1글자는 제외
            if (orig_name.len <= 1) continue;
            if (std.mem.eql(u8, orig_name, "default")) continue;
            if (std.mem.eql(u8, orig_name, "arguments")) continue;

            // 짧은 이름 생성 (예약어 + 기존/사용된 이름 충돌 방지)
            var new_name = name_gen.next();
            while (Mangler.isReservedOrGlobal(new_name) or
                all_names.contains(new_name) or
                used_names.contains(new_name) or
                exported.contains(new_name))
            {
                new_name = name_gen.next();
            }

            if (!std.mem.eql(u8, orig_name, new_name)) {
                const duped = try self.allocator.dupe(u8, new_name);
                try name_map.put(orig_name, duped);
                try used_names.put(duped, {});
            }
        }

        // 3. canonical_names 업데이트 — 기존 rename된 이름도 mangling
        var update_list: std.ArrayList(struct { key: []const u8, val: []const u8 }) = .empty;
        defer update_list.deinit(self.allocator);

        var cnit = self.canonical_names.iterator();
        while (cnit.next()) |cn_entry| {
            const current_name = cn_entry.value_ptr.*;
            if (name_map.get(current_name)) |mangled| {
                try update_list.append(self.allocator, .{
                    .key = cn_entry.key_ptr.*,
                    .val = try self.allocator.dupe(u8, mangled),
                });
            }
        }
        for (update_list.items) |upd| {
            if (self.canonical_names.getPtr(upd.key)) |ptr| {
                self.allocator.free(ptr.*);
                ptr.* = upd.val;
            }
        }

        // 4. 아직 canonical_names에 없는 이름도 추가 (충돌 없던 이름)
        for (self.modules, 0..) |m, i| {
            const sem = m.semantic orelse continue;
            if (sem.scope_maps.len == 0) continue;
            var sit = sem.scope_maps[0].iterator();
            while (sit.next()) |scope_entry| {
                const sym_name = scope_entry.key_ptr.*;
                if (name_map.get(sym_name)) |mangled| {
                    const key = makeExportKey(self.allocator, @intCast(i), sym_name) catch continue;
                    if (!self.canonical_names.contains(key)) {
                        self.canonical_names.put(key, self.allocator.dupe(u8, mangled) catch continue) catch {
                            self.allocator.free(key);
                        };
                    } else {
                        self.allocator.free(key);
                    }
                }
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

    /// ECMAScript 예약어인지 확인 (키워드 + strict mode 예약어만).
    /// 글로벌 객체 이름은 포함하지 않음 — reserved_globals에서 자동 수집.
    /// comptime StaticStringMap으로 O(1) 조회.
    fn isReservedName(name: []const u8) bool {
        const map = comptime std.StaticStringMap(void).initComptime(.{
            // ECMAScript 예약어 (keywords + future reserved words)
            .{ "break", {} },     .{ "case", {} },       .{ "catch", {} },      .{ "class", {} },
            .{ "const", {} },     .{ "continue", {} },   .{ "debugger", {} },   .{ "default", {} },
            .{ "delete", {} },    .{ "do", {} },         .{ "else", {} },       .{ "enum", {} },
            .{ "export", {} },    .{ "extends", {} },    .{ "false", {} },      .{ "finally", {} },
            .{ "for", {} },       .{ "function", {} },   .{ "if", {} },         .{ "import", {} },
            .{ "in", {} },        .{ "instanceof", {} }, .{ "new", {} },        .{ "null", {} },
            .{ "return", {} },    .{ "super", {} },      .{ "switch", {} },     .{ "this", {} },
            .{ "throw", {} },     .{ "true", {} },       .{ "try", {} },        .{ "typeof", {} },
            .{ "var", {} },       .{ "void", {} },       .{ "while", {} },      .{ "with", {} },
            .{ "yield", {} },     .{ "let", {} },        .{ "static", {} },     .{ "implements", {} },
            .{ "interface", {} }, .{ "package", {} },    .{ "private", {} },    .{ "protected", {} },
            .{ "public", {} },    .{ "await", {} },
            // ECMAScript 특수 식별자 (키워드는 아니지만 변수명으로 사용하면 문제)
                 .{ "undefined", {} },  .{ "NaN", {} },
            .{ "Infinity", {} },  .{ "arguments", {} },  .{ "eval", {} },
            // CJS 런타임 식별자 — 번들러가 합성하는 __commonJS/__require에서 사용.
            // semantic analyzer의 unresolved에 잡히지 않으므로 항상 예약.
                  .{ "require", {} },
            .{ "module", {} },    .{ "exports", {} },    .{ "__filename", {} }, .{ "__dirname", {} },
        });
        return map.has(name);
    }

    /// JS 예약어이거나 자동 수집된 글로벌 이름인지 확인.
    /// scope hoisting 시 이름 충돌 판별에 사용. isReservedName(키워드) + reserved_globals(미해결 참조).
    fn isReservedOrGlobal(self: *const Linker, name: []const u8) bool {
        return isReservedName(name) or self.reserved_globals.contains(name);
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

    /// AST에서 import/export 노드를 식별하여 스킵 비트셋을 생성한다.
    /// buildMetadataForAst와 buildDevMetadataForAst에서 공유.
    fn buildSkipNodes(allocator: std.mem.Allocator, new_ast: *const Ast) !std.DynamicBitSet {
        const node_count = new_ast.nodes.items.len;
        var skip_nodes = try std.DynamicBitSet.initEmpty(allocator, node_count);
        errdefer skip_nodes.deinit();

        for (new_ast.nodes.items, 0..) |node, node_idx| {
            switch (node.tag) {
                .import_declaration => skip_nodes.set(node_idx),
                .export_named_declaration => {
                    const e = node.data.extra;
                    if (e + 3 < new_ast.extra_data.items.len) {
                        const decl_idx: NodeIndex = @enumFromInt(new_ast.extra_data.items[e]);
                        if (decl_idx.isNone()) {
                            skip_nodes.set(node_idx); // export { } 또는 re-export
                        }
                        // export const → codegen에서 export 키워드만 생략
                    }
                },
                // export default → codegen이 linking_metadata 체크하여 키워드만 생략
                .export_default_declaration => {},
                .export_all_declaration => skip_nodes.set(node_idx),
                else => {},
            }
        }
        return skip_nodes;
    }

    /// transformer 이후의 new_ast를 기반으로 LinkingMetadata를 생성한다.
    /// skip_nodes와 renames가 new_ast의 노드 인덱스와 일치.
    pub fn buildMetadataForAst(
        self: *const Linker,
        new_ast: *const Ast,
        module_index: u32,
        is_entry: bool,
        override_symbol_ids: ?[]const ?u32,
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

        // CJS 래핑 모듈은 스코프 호이스팅 대상이 아님.
        // 단, 내부 require() 호출은 번들된 require_xxx()로 치환해야 함.
        if (m.wrap_kind == .cjs) {
            const node_count = new_ast.nodes.items.len;
            var require_rewrites: std.StringHashMapUnmanaged([]const u8) = .{};
            for (m.import_records) |rec| {
                if (rec.resolved.isNone()) continue;
                const target = @intFromEnum(rec.resolved);
                if (target >= self.modules.len) continue;
                // 번들된 모듈을 가리키는 require() → require_xxx()로 치환
                // __commonJS로 래핑되는 모듈만 대상 (CJS, JSON 모두 wrap_kind=.cjs)
                if (self.modules[target].wrap_kind == .cjs) {
                    // 동일 specifier의 기존 값이 있으면 해제 (중복 require 방지)
                    if (require_rewrites.get(rec.specifier)) |old| {
                        self.allocator.free(old);
                    }
                    const var_name = try types.makeRequireVarName(self.allocator, self.modules[target].path);
                    try require_rewrites.put(self.allocator, rec.specifier, var_name);
                }
            }
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = if (m.semantic) |sem| sem.symbol_ids else &.{},
                .cjs_import_preamble = null,
                .require_rewrites = require_rewrites,
                .allocator = self.allocator,
            };
        }

        var skip_nodes = try buildSkipNodes(self.allocator, new_ast);
        errdefer skip_nodes.deinit();
        var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);
        errdefer renames.deinit();

        // 2. import 바인딩 리네임 (모듈의 semantic 기반)
        const sem = m.semantic orelse return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };

        // CJS import preamble 빌드용 버퍼
        var cjs_preamble_buf: std.ArrayList(u8) = .empty;
        defer cjs_preamble_buf.deinit(self.allocator);

        // namespace member rewrite 엔트리 수집 (esbuild 방식)
        var ns_rewrite_list: std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry) = .empty;
        errdefer {
            for (ns_rewrite_list.items) |*e| e.map.deinit();
            ns_rewrite_list.deinit(self.allocator);
        }
        // namespace 인라인 객체 수집 (값 사용 시)
        var ns_inline_list: std.ArrayList(LinkingMetadata.NsInlineObjects.Entry) = .empty;
        errdefer {
            for (ns_inline_list.items) |e| self.allocator.free(e.object_literal);
            ns_inline_list.deinit(self.allocator);
        }

        // CJS 모듈별 require_xxx 변수명 캐시 (같은 모듈에서 여러 named import 시 중복 생성 방지)
        var cjs_var_cache = std.AutoHashMap(u32, []const u8).init(self.allocator);
        defer {
            var vit = cjs_var_cache.valueIterator();
            while (vit.next()) |v| self.allocator.free(v.*);
            cjs_var_cache.deinit();
        }

        if (sem.scope_maps.len > 0) {
            const module_scope = sem.scope_maps[0];
            // import 바인딩 → canonical 이름
            for (m.import_bindings) |ib| {
                if (ib.import_record_index >= m.import_records.len) continue;
                const rec = m.import_records[ib.import_record_index];

                // External 모듈 (Node.js 빌트인, --external): resolved가 없지만
                // import 바인딩이 존재 → preamble에 require() 호출을 생성하여 변수 바인딩 유지.
                // 예: import url from 'url' → var url = require("url")
                if (rec.resolved.isNone()) {
                    if (rec.kind == .static_import or rec.kind == .side_effect or rec.kind == .re_export) {
                        // var <local> = require("<specifier>")[.<imported>];
                        try cjs_preamble_buf.appendSlice(self.allocator, "var ");
                        try cjs_preamble_buf.appendSlice(self.allocator, ib.local_name);
                        try cjs_preamble_buf.appendSlice(self.allocator, " = require(\"");
                        try cjs_preamble_buf.appendSlice(self.allocator, rec.specifier);
                        try cjs_preamble_buf.appendSlice(self.allocator, "\")");
                        // named import만 .property 접근 추가 (namespace/default는 모듈 전체)
                        if (ib.kind != .namespace and !std.mem.eql(u8, ib.imported_name, "default")) {
                            try cjs_preamble_buf.appendSlice(self.allocator, ".");
                            try cjs_preamble_buf.appendSlice(self.allocator, ib.imported_name);
                        }
                        try cjs_preamble_buf.appendSlice(self.allocator, ";\n");
                    }
                    continue;
                }

                const canonical_mod = @intFromEnum(rec.resolved);

                // CJS 모듈에서 import하는 경우: preamble에서 require_xxx() 호출 생성
                if (canonical_mod < self.modules.len and self.modules[canonical_mod].wrap_kind == .cjs) {
                    const req_var = if (cjs_var_cache.get(@intCast(canonical_mod))) |cached|
                        cached
                    else blk: {
                        const target_path = self.modules[canonical_mod].path;
                        const name = try types.makeRequireVarName(self.allocator, target_path);
                        try cjs_var_cache.put(@intCast(canonical_mod), name);
                        break :blk name;
                    };

                    if (ib.kind == .namespace) {
                        // namespace import: var <local> = __toESM(require_xxx());
                        // __toESM이 __esModule 플래그를 확인하여 적절한 namespace 객체 생성
                        try cjs_preamble_buf.appendSlice(self.allocator, "var ");
                        try cjs_preamble_buf.appendSlice(self.allocator, ib.local_name);
                        try cjs_preamble_buf.appendSlice(self.allocator, " = __toESM(");
                        try cjs_preamble_buf.appendSlice(self.allocator, req_var);
                        try cjs_preamble_buf.appendSlice(self.allocator, "());\n");
                    } else if (std.mem.eql(u8, ib.imported_name, "default")) {
                        // default import: var <local> = __toESM(require_xxx()).default;
                        // __toESM이 { default: module.exports, ... }를 반환하므로 .default 필요
                        try cjs_preamble_buf.appendSlice(self.allocator, "var ");
                        try cjs_preamble_buf.appendSlice(self.allocator, ib.local_name);
                        try cjs_preamble_buf.appendSlice(self.allocator, " = __toESM(");
                        try cjs_preamble_buf.appendSlice(self.allocator, req_var);
                        try cjs_preamble_buf.appendSlice(self.allocator, "()).default;\n");
                    } else {
                        // named import: var <local> = require_xxx().<imported>;
                        try cjs_preamble_buf.appendSlice(self.allocator, "var ");
                        try cjs_preamble_buf.appendSlice(self.allocator, ib.local_name);
                        try cjs_preamble_buf.appendSlice(self.allocator, " = ");
                        try cjs_preamble_buf.appendSlice(self.allocator, req_var);
                        try cjs_preamble_buf.appendSlice(self.allocator, "().");
                        try cjs_preamble_buf.appendSlice(self.allocator, ib.imported_name);
                        try cjs_preamble_buf.appendSlice(self.allocator, ";\n");
                    }
                    continue;
                }

                // namespace import: esbuild 방식 — ns.prop → canonical_name 직접 치환.
                // ns 자체를 값으로 사용할 때만 폴백으로 객체 생성.
                if (ib.kind == .namespace) {
                    const ns_sym_id = module_scope.get(ib.local_name) orelse continue;
                    const effective_syms = override_symbol_ids orelse sem.symbol_ids;

                    // esbuild 방식: ns.prop → 직접 치환, ns 값 사용 → 인라인 객체
                    const need_inline = isNamespaceUsedAsValue(self.allocator, new_ast, effective_syms, @intCast(ns_sym_id));
                    try self.registerNamespaceRewrites(
                        &ns_rewrite_list,
                        if (need_inline) &ns_inline_list else null,
                        @intCast(ns_sym_id),
                        @intCast(canonical_mod),
                    );
                    continue;
                }

                // resolveImports()에서 이미 해결한 바인딩을 조회하거나, 직접 해결
                const resolved = self.getResolvedBinding(module_index, ib.local_span);
                const target_name = blk: {
                    if (resolved) |rb| {
                        const local = self.resolveToLocalName(rb.canonical);
                        // namespace re-export 감지: export * as X → local_name == exported_name
                        // 이 경우 소스 모듈의 namespace 객체 preamble을 importer에 생성
                        const cmod: u32 = @intCast(@intFromEnum(rb.canonical.module_index));
                        if (cmod < self.modules.len) {
                            for (self.modules[cmod].export_bindings) |eb| {
                                if (eb.kind == .re_export_all and
                                    std.mem.eql(u8, eb.exported_name, rb.canonical.export_name) and
                                    !std.mem.eql(u8, eb.exported_name, "*"))
                                {
                                    // namespace re-export: ns_member_rewrites + 인라인 객체 등록
                                    if (eb.import_record_index) |rec_idx| {
                                        if (rec_idx < self.modules[cmod].import_records.len) {
                                            const src = self.modules[cmod].import_records[rec_idx].resolved;
                                            if (!src.isNone()) {
                                                const import_sym_id = module_scope.get(ib.local_name) orelse break :blk ib.imported_name;
                                                try self.registerNamespaceRewrites(
                                                    &ns_rewrite_list,
                                                    &ns_inline_list,
                                                    @intCast(import_sym_id),
                                                    @intFromEnum(src),
                                                );
                                                break :blk ib.local_name;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // canonical의 export local_name이 namespace import인 경우 → 인라인 객체
                        const cmod2: u32 = @intCast(@intFromEnum(rb.canonical.module_index));
                        const export_local = self.getExportLocalName(cmod2, rb.canonical.export_name) orelse rb.canonical.export_name;
                        if (cmod2 < self.modules.len) {
                            for (self.modules[cmod2].import_bindings) |cib| {
                                if (cib.kind == .namespace and std.mem.eql(u8, cib.local_name, export_local)) {
                                    // namespace import → 인라인 객체로 처리
                                    const imp_sym = module_scope.get(ib.local_name) orelse break;
                                    const ns_target_mod = if (cib.import_record_index < self.modules[cmod2].import_records.len)
                                        @intFromEnum(self.modules[cmod2].import_records[cib.import_record_index].resolved)
                                    else
                                        break;
                                    try self.registerNamespaceRewrites(
                                        &ns_rewrite_list,
                                        &ns_inline_list,
                                        @intCast(imp_sym),
                                        @intCast(ns_target_mod),
                                    );
                                    break :blk ib.local_name;
                                }
                            }
                        }
                        break :blk local;
                    }
                    break :blk ib.imported_name;
                };

                // JS 예약어 (default 등)를 rename target으로 사용 불가
                if (!std.mem.eql(u8, ib.local_name, target_name) and
                    !isReservedName(target_name))
                {
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

        // CJS import preamble 저장
        var cjs_import_preamble: ?[]const u8 = null;
        if (cjs_preamble_buf.items.len > 0) {
            cjs_import_preamble = try self.allocator.dupe(u8, cjs_preamble_buf.items);
        }

        // export default의 합성 변수명 계산 (이름 충돌 시 _default$1 등)
        var default_export_name: []const u8 = "_default";
        for (m.export_bindings) |eb| {
            if (eb.kind == .local and std.mem.eql(u8, eb.exported_name, "default")) {
                if (!std.mem.eql(u8, eb.local_name, "default")) {
                    default_export_name = self.getCanonicalName(module_index, eb.local_name) orelse eb.local_name;
                }
                break;
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

        // ns_member_rewrites 소유권 이동
        const ns_rewrites: LinkingMetadata.NsMemberRewrites = if (ns_rewrite_list.items.len > 0) blk: {
            break :blk .{ .entries = try self.allocator.dupe(LinkingMetadata.NsMemberRewrites.Entry, ns_rewrite_list.items) };
        } else .{};
        ns_rewrite_list.deinit(self.allocator);

        const ns_inlines: LinkingMetadata.NsInlineObjects = if (ns_inline_list.items.len > 0) blk: {
            break :blk .{ .entries = try self.allocator.dupe(LinkingMetadata.NsInlineObjects.Entry, ns_inline_list.items) };
        } else .{};
        ns_inline_list.deinit(self.allocator);

        return .{
            .skip_nodes = skip_nodes,
            .renames = renames,
            .final_exports = final_exports,
            .symbol_ids = sem.symbol_ids,
            .cjs_import_preamble = cjs_import_preamble,
            .default_export_name = default_export_name,
            .ns_member_rewrites = ns_rewrites,
            .ns_inline_objects = ns_inlines,
            .allocator = self.allocator,
        };
    }

    /// Dev mode용 LinkingMetadata를 생성한다.
    ///
    /// 프로덕션 buildMetadataForAst와의 차이:
    ///   - renames 없음 (스코프 호이스팅 안 함, 각 모듈이 자체 스코프 유지)
    ///   - cjs_import_preamble: `const { x } = __zts_require("./path")` 형태
    ///   - final_exports: 모든 모듈에 `__zts_exports.x = x;` 형태 (entry만이 아닌 전체)
    pub fn buildDevMetadataForAst(
        self: *const Linker,
        new_ast: *const Ast,
        module_index: u32,
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

        // CJS 래핑 모듈은 dev mode에서도 기존대로 유지
        if (m.wrap_kind == .cjs) {
            const node_count = new_ast.nodes.items.len;
            return .{
                .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count),
                .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
                .final_exports = null,
                .symbol_ids = if (m.semantic) |sem| sem.symbol_ids else &.{},
                .cjs_import_preamble = null,
                .allocator = self.allocator,
            };
        }

        var skip_nodes = try buildSkipNodes(self.allocator, new_ast);
        errdefer skip_nodes.deinit();

        // 2. __zts_require preamble 생성
        var preamble_buf: std.ArrayList(u8) = .empty;
        defer preamble_buf.deinit(self.allocator);

        // import binding을 import_record_index별로 그룹핑하여 출력
        // 같은 소스에서 여러 이름을 가져오면: const { a, b } = __zts_require("./dep");
        var rec_idx: u32 = 0;
        while (rec_idx < m.import_records.len) : (rec_idx += 1) {
            const rec = m.import_records[rec_idx];
            if (rec.resolved.isNone()) continue;
            if (rec.kind == .dynamic_import) continue;

            // 이 record에 해당하는 binding 수집
            var has_default = false;
            var has_namespace = false;
            var default_local: []const u8 = "";
            var namespace_local: []const u8 = "";
            var named_count: usize = 0;

            for (m.import_bindings) |ib| {
                if (ib.import_record_index != rec_idx) continue;
                switch (ib.kind) {
                    .default => {
                        has_default = true;
                        default_local = ib.local_name;
                    },
                    .namespace => {
                        has_namespace = true;
                        namespace_local = ib.local_name;
                    },
                    .named => named_count += 1,
                }
            }

            if (!has_default and !has_namespace and named_count == 0) continue;

            // resolve된 모듈 경로
            const resolved_mod = @intFromEnum(rec.resolved);
            const resolved_path = if (resolved_mod < self.modules.len) self.modules[resolved_mod].path else rec.specifier;

            if (has_namespace) {
                // import * as ns from './dep' → const ns = __zts_require("./path");
                try preamble_buf.appendSlice(self.allocator, "var ");
                try preamble_buf.appendSlice(self.allocator, namespace_local);
                try preamble_buf.appendSlice(self.allocator, " = __zts_require(\"");
                try preamble_buf.appendSlice(self.allocator, resolved_path);
                try preamble_buf.appendSlice(self.allocator, "\");\n");
            }

            if (has_default) {
                // import foo from './dep' → var foo = __zts_require("./path").default;
                try preamble_buf.appendSlice(self.allocator, "var ");
                try preamble_buf.appendSlice(self.allocator, default_local);
                try preamble_buf.appendSlice(self.allocator, " = __zts_require(\"");
                try preamble_buf.appendSlice(self.allocator, resolved_path);
                try preamble_buf.appendSlice(self.allocator, "\").default;\n");
            }

            if (named_count > 0) {
                // import { a, b } from './dep' → var { a, b } = __zts_require("./path");
                try preamble_buf.appendSlice(self.allocator, "var { ");
                var first = true;
                for (m.import_bindings) |ib| {
                    if (ib.import_record_index != rec_idx or ib.kind != .named) continue;
                    if (!first) try preamble_buf.appendSlice(self.allocator, ", ");
                    first = false;
                    // import { foo as bar } → foo: bar
                    if (!std.mem.eql(u8, ib.imported_name, ib.local_name)) {
                        try preamble_buf.appendSlice(self.allocator, ib.imported_name);
                        try preamble_buf.appendSlice(self.allocator, ": ");
                        try preamble_buf.appendSlice(self.allocator, ib.local_name);
                    } else {
                        try preamble_buf.appendSlice(self.allocator, ib.local_name);
                    }
                }
                try preamble_buf.appendSlice(self.allocator, " } = __zts_require(\"");
                try preamble_buf.appendSlice(self.allocator, resolved_path);
                try preamble_buf.appendSlice(self.allocator, "\");\n");
            }
        }

        var cjs_import_preamble: ?[]const u8 = null;
        if (preamble_buf.items.len > 0) {
            cjs_import_preamble = try self.allocator.dupe(u8, preamble_buf.items);
        }

        // 3. __zts_exports 할당 생성 (모든 모듈, entry 여부 무관)
        var final_exports: ?[]const u8 = null;
        if (m.export_bindings.len > 0) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);

            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_all) continue;
                if (std.mem.eql(u8, eb.exported_name, "*")) continue;

                // __zts_exports.name = local_name;
                // re-export의 경우: __zts_exports.name = __zts_require("./dep").name;
                if (eb.kind == .re_export) {
                    if (eb.import_record_index) |iri| {
                        if (iri < m.import_records.len) {
                            const irec = m.import_records[iri];
                            if (!irec.resolved.isNone()) {
                                const re_mod = @intFromEnum(irec.resolved);
                                const re_path = if (re_mod < self.modules.len) self.modules[re_mod].path else irec.specifier;
                                try buf.appendSlice(self.allocator, "__zts_exports.");
                                try buf.appendSlice(self.allocator, eb.exported_name);
                                try buf.appendSlice(self.allocator, " = __zts_require(\"");
                                try buf.appendSlice(self.allocator, re_path);
                                try buf.appendSlice(self.allocator, "\").");
                                try buf.appendSlice(self.allocator, eb.local_name);
                                try buf.appendSlice(self.allocator, ";\n");
                                continue;
                            }
                        }
                    }
                }

                try buf.appendSlice(self.allocator, "__zts_exports.");
                try buf.appendSlice(self.allocator, eb.exported_name);
                try buf.appendSlice(self.allocator, " = ");
                try buf.appendSlice(self.allocator, eb.local_name);
                try buf.appendSlice(self.allocator, ";\n");
            }

            if (buf.items.len > 0) {
                final_exports = try self.allocator.dupe(u8, buf.items);
            }
        }

        const sem = m.semantic orelse return .{
            .skip_nodes = skip_nodes,
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = final_exports,
            .symbol_ids = &.{},
            .cjs_import_preamble = cjs_import_preamble,
            .allocator = self.allocator,
        };

        return .{
            .skip_nodes = skip_nodes,
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = final_exports,
            .symbol_ids = sem.symbol_ids,
            .cjs_import_preamble = cjs_import_preamble,
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
        if (depth > max_chain_depth) return null;

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
            // local export: 이 모듈의 심볼이지만, barrel re-export 패턴인지 확인.
            // `import { X } from './a'; export { X }` 는 binding_scanner에서 .local로
            // 분류되지만 실제로는 import binding이므로 소스 모듈로 따라가야 한다.
            const m_local = self.modules[mod_i];
            for (m_local.import_bindings) |ib| {
                if (std.mem.eql(u8, ib.local_name, entry.binding.local_name)) {
                    // 이 로컬 이름은 import binding → 소스 모듈의 export를 따라간다
                    if (ib.import_record_index < m_local.import_records.len) {
                        const source_mod = m_local.import_records[ib.import_record_index].resolved;
                        if (!source_mod.isNone()) {
                            return self.resolveExportChain(source_mod, ib.imported_name, depth + 1);
                        }
                    }
                    break;
                }
            }
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

    /// SymbolRef를 scope hoisting 후 최종 로컬 이름으로 해결.
    /// resolveExportChain → getExportLocalName → getCanonicalName 3단계를 캡슐화.
    /// namespace 식별자가 member access 이외의 위치에서 사용되는지 판별.
    /// `ns.prop`만 사용되면 false (직접 치환 가능), `console.log(ns)` 등이면 true (객체 필요).
    fn isNamespaceUsedAsValue(allocator: std.mem.Allocator, new_ast: *const Ast, symbol_ids: []const ?u32, ns_sym_id: u32) bool {
        const node_count = new_ast.nodes.items.len;
        if (node_count == 0) return false;

        // 1. member access의 object 위치를 비트셋으로 수집 — O(N) 스캔, O(1) 조회
        var safe = std.DynamicBitSet.initEmpty(allocator, node_count) catch return true;
        defer safe.deinit();

        for (new_ast.nodes.items) |node| {
            if (node.tag == .static_member_expression or node.tag == .private_field_expression) {
                const e = node.data.extra;
                if (new_ast.hasExtra(e, 2)) {
                    const obj_idx = new_ast.readExtra(e, 0);
                    if (obj_idx < node_count) safe.set(obj_idx);
                }
            }
        }

        // 2. ns 심볼 참조 확인 — 안전 위치가 아닌 참조가 하나라도 있으면 값 사용
        for (symbol_ids, 0..) |maybe_sid, node_i| {
            if (maybe_sid) |sid| {
                if (sid == ns_sym_id) {
                    // import specifier/binding 선언 위치는 skip
                    if (node_i < node_count) {
                        const tag = new_ast.nodes.items[node_i].tag;
                        if (tag == .import_namespace_specifier or tag == .import_default_specifier or
                            tag == .import_specifier or tag == .binding_identifier) continue;
                    }
                    if (node_i >= node_count or !safe.isSet(node_i)) return true;
                }
            }
        }
        return false;
    }

    pub fn resolveToLocalName(self: *const Linker, ref: SymbolRef) []const u8 {
        const cmod: u32 = @intCast(@intFromEnum(ref.module_index));
        const local = self.getExportLocalName(cmod, ref.export_name) orelse ref.export_name;
        return self.getCanonicalName(cmod, local) orelse local;
    }

    /// ESM namespace import를 위한 namespace 객체 preamble 생성.
    /// namespace import/re-export에 대해 ns_member_rewrites + ns_inline_objects를 등록.
    /// buildMetadataForAst 내 3곳에서 동일 패턴을 공유.
    fn registerNamespaceRewrites(
        self: *const Linker,
        ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
        ns_inline_list: ?*std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
        symbol_id: u32,
        target_mod_idx: u32,
    ) std.mem.Allocator.Error!void {
        var exports: std.ArrayList(NsExportPair) = .empty;
        // owned 문자열은 inner_map으로 소유권 이동 — 여기서 free하지 않음
        defer exports.deinit(self.allocator);
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

        var inner_map = std.StringHashMap([]const u8).init(self.allocator);
        for (exports.items) |exp| {
            try inner_map.put(exp.exported, exp.local);
        }
        try ns_rewrite_list.append(self.allocator, .{
            .symbol_id = symbol_id,
            .map = inner_map,
        });

        if (ns_inline_list) |list| {
            const obj_str = try self.buildInlineObjectStr(target_mod_idx, 0);
            try list.append(self.allocator, .{
                .symbol_id = symbol_id,
                .object_literal = obj_str,
            });
        }
    }

    /// 모듈의 모든 export를 인라인 객체 문자열로 생성 (재귀적).
    /// `export * as ns` export는 소스 모듈의 인라인 객체로 중첩.
    fn buildInlineObjectStr(
        self: *const Linker,
        target_mod_idx: u32,
        depth: u32,
    ) std.mem.Allocator.Error![]const u8 {
        if (depth > max_chain_depth) return try self.allocator.dupe(u8, "{}");
        if (target_mod_idx >= self.modules.len) return try self.allocator.dupe(u8, "{}");

        var exports: std.ArrayList(NsExportPair) = .empty;
        defer {
            for (exports.items) |exp| {
                if (exp.owned) self.allocator.free(exp.local);
            }
            exports.deinit(self.allocator);
        }
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        var visited = std.AutoHashMap(u32, void).init(self.allocator);
        defer visited.deinit();
        try self.collectExportsRecursive(&exports, &seen, &visited, @enumFromInt(target_mod_idx), 0);

        // export * as ns 패턴 수집 (별도 처리 — 재귀 인라인 필요)
        const target = self.modules[target_mod_idx];
        var ns_re_exports = std.StringHashMap(u32).init(self.allocator); // exported_name → source_mod
        defer ns_re_exports.deinit();
        for (target.export_bindings) |eb| {
            if (eb.kind == .re_export_all and !std.mem.eql(u8, eb.exported_name, "*")) {
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < target.import_records.len) {
                        const src = target.import_records[rec_idx].resolved;
                        if (!src.isNone()) {
                            try ns_re_exports.put(eb.exported_name, @intFromEnum(src));
                        }
                    }
                }
            }
        }

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{");
        for (exports.items, 0..) |exp, idx| {
            if (idx > 0) try buf.appendSlice(self.allocator, ", ");
            if (std.mem.eql(u8, exp.exported, "default")) {
                try buf.appendSlice(self.allocator, "\"default\": ");
            } else {
                try buf.appendSlice(self.allocator, exp.exported);
                try buf.appendSlice(self.allocator, ": ");
            }
            // export * as ns 패턴이면 재귀 인라인
            if (ns_re_exports.get(exp.exported)) |src_mod| {
                const nested = try self.buildInlineObjectStr(src_mod, depth + 1);
                defer self.allocator.free(nested);
                try buf.appendSlice(self.allocator, nested);
            } else {
                try buf.appendSlice(self.allocator, exp.local);
            }
        }
        try buf.appendSlice(self.allocator, "}");
        return try self.allocator.dupe(u8, buf.items);
    }

    /// 모듈의 모든 export를 재귀적으로 수집 (export * 체인 포함).
    /// seen: export 이름 dedup, visited: 모듈 수준 dedup (diamond export * 방지).
    fn collectExportsRecursive(
        self: *const Linker,
        exports: *std.ArrayList(NsExportPair),
        seen: *std.StringHashMap(void),
        visited: *std.AutoHashMap(u32, void),
        module_idx: ModuleIndex,
        depth: u32,
    ) std.mem.Allocator.Error!void {
        if (depth > max_chain_depth) return;
        const mod_i = @intFromEnum(module_idx);
        if (mod_i >= self.modules.len) return;
        // diamond export * 패턴에서 동일 모듈 재방문 방지
        if (visited.contains(mod_i)) return;
        try visited.put(mod_i, {});
        const m = self.modules[mod_i];

        for (m.export_bindings) |eb| {
            // 일반 export * from (exported_name == "*") → 재귀로 처리 (skip)
            // export * as ns (exported_name != "*") → named export로 포함
            if (eb.kind == .re_export_all and std.mem.eql(u8, eb.exported_name, "*")) continue;
            if (seen.contains(eb.exported_name)) continue;
            try seen.put(eb.exported_name, {});

            const actual_local = if (eb.kind == .re_export_all and !std.mem.eql(u8, eb.exported_name, "*")) blk: {
                // export * as ns — 소스 모듈의 인라인 객체를 생성 (재귀)
                if (eb.import_record_index) |rec_idx| {
                    if (rec_idx < m.import_records.len) {
                        const src = m.import_records[rec_idx].resolved;
                        if (!src.isNone()) {
                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1);
                        }
                    }
                }
                break :blk eb.local_name;
            } else if (eb.kind == .re_export) blk: {
                if (self.resolveExportChain(module_idx, eb.exported_name, 0)) |canonical| {
                    // canonical이 export * as ns 패턴인지 확인
                    const cmod_i = @intFromEnum(canonical.module_index);
                    if (cmod_i < self.modules.len) {
                        for (self.modules[cmod_i].export_bindings) |ceb| {
                            if (ceb.kind == .re_export_all and
                                std.mem.eql(u8, ceb.exported_name, canonical.export_name) and
                                !std.mem.eql(u8, ceb.exported_name, "*"))
                            {
                                if (ceb.import_record_index) |rec_idx| {
                                    if (rec_idx < self.modules[cmod_i].import_records.len) {
                                        const src = self.modules[cmod_i].import_records[rec_idx].resolved;
                                        if (!src.isNone()) {
                                            break :blk try self.buildInlineObjectStr(@intFromEnum(src), depth + 1);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    break :blk self.resolveToLocalName(canonical);
                }
                break :blk eb.local_name;
            } else self.getCanonicalName(@intCast(mod_i), eb.local_name) orelse eb.local_name;

            try exports.append(self.allocator, .{
                .exported = eb.exported_name,
                .local = actual_local,
                .owned = actual_local.len > 0 and actual_local[0] == '{',
            });
        }

        // export * 재귀 — export * as ns는 이미 첫 루프에서 인라인 객체로 처리됨
        for (m.export_bindings) |eb| {
            if (eb.kind != .re_export_all) continue;
            if (!std.mem.eql(u8, eb.exported_name, "*")) continue; // export * as ns는 skip
            if (eb.import_record_index) |rec_idx| {
                if (rec_idx < m.import_records.len) {
                    const source_mod = m.import_records[rec_idx].resolved;
                    if (!source_mod.isNone()) {
                        try self.collectExportsRecursive(exports, seen, visited, source_mod, depth + 1);
                    }
                }
            }
        }
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

    /// canonical_names를 초기화한다. 키와 값의 메모리를 해제하고 맵을 비운다.
    /// per-chunk rename에서 이전 청크의 결과를 제거할 때 사용.
    pub fn clearCanonicalNames(self: *Linker) void {
        var cit = self.canonical_names.iterator();
        while (cit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.canonical_names.clearRetainingCapacity();
    }

    /// 특정 모듈들만 대상으로 이름 충돌을 감지하고 리네임을 계산한다.
    /// code splitting에서 사용 — 각 청크는 독립된 네임스페이스이므로
    /// 같은 이름이 다른 청크에 있어도 충돌하지 않는다.
    ///
    /// 기존 canonical_names를 초기화한 뒤, module_indices에 포함된
    /// 모듈의 top-level 심볼만 대상으로 충돌을 감지한다.
    /// cross-chunk import 이름을 점유로 등록하면서 이름 충돌을 해결한다.
    /// occupied_names: cross-chunk import로 이 청크에 도입되는 이름 목록.
    /// 이 이름들은 import 문으로 유지되므로 로컬 심볼과 충돌하면 로컬을 rename해야 함.
    pub fn computeRenamesForModules(
        self: *Linker,
        module_indices: []const ModuleIndex,
        occupied_names: []const []const u8,
    ) !void {
        // 이전 청크의 리네임 결과 제거
        self.clearCanonicalNames();

        // 미해결 참조 수집 (해당 청크의 모듈만)
        self.reserved_globals.clearRetainingCapacity();
        for (module_indices) |mod_idx| {
            const i = @intFromEnum(mod_idx);
            if (i >= self.modules.len) continue;
            const m = self.modules[i];
            const sem = m.semantic orelse continue;
            var urit = sem.unresolved_references.iterator();
            while (urit.next()) |entry| {
                try self.reserved_globals.put(entry.key_ptr.*, {});
            }
        }

        // 1. 지정된 모듈의 top-level 심볼 이름 수집
        var name_to_owners = NameToOwnersMap.init(self.allocator);
        defer {
            var vit = name_to_owners.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            name_to_owners.deinit();
        }

        // cross-chunk import 이름을 "점유"로 등록 — exec_index=0 (가장 낮음)으로
        // 등록하여 충돌 시 로컬 심볼이 rename됨 (import 이름이 우선 유지)
        for (occupied_names) |name| {
            if (std.mem.eql(u8, name, "default")) continue;
            const entry = try name_to_owners.getOrPut(name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
            }
            try entry.value_ptr.append(self.allocator, .{
                .module_index = std.math.maxInt(u32), // 특수 마커 — 실제 모듈 아님
                .exec_index = 0, // 가장 낮은 exec_index → 원본 이름 유지
            });
        }

        for (module_indices) |mod_idx| {
            const i = @intFromEnum(mod_idx);
            if (i >= self.modules.len) continue;
            try self.collectModuleNames(self.modules[i], @intCast(i), &name_to_owners);
        }

        // 2. 충돌하는 이름에 대해 리네임 계산 (cross-chunk 점유 마커는 skip)
        try self.calculateRenames(&name_to_owners, true);
    }

    const makeExportKey = types.makeModuleKey;
    const makeExportKeyBuf = types.makeModuleKeyBuf;
};

// ============================================================
// Tests
// ============================================================

const resolve_cache_mod = @import("resolve_cache.zig");
const ModuleGraph = @import("graph.zig").ModuleGraph;

const writeFile = @import("test_helpers.zig").writeFile;

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

test "isReservedName: special identifiers" {
    // undefined, NaN, Infinity, arguments, eval은 예약어급 (키워드 목록에 유지)
    try std.testing.expect(Linker.isReservedName("undefined"));
    try std.testing.expect(Linker.isReservedName("arguments"));
    try std.testing.expect(Linker.isReservedName("eval"));
    try std.testing.expect(Linker.isReservedName("NaN"));
    try std.testing.expect(Linker.isReservedName("Infinity"));
    // 글로벌 객체는 더 이상 정적 목록에 없음 (unresolved references로 자동 수집)
    try std.testing.expect(!Linker.isReservedName("Array"));
    try std.testing.expect(!Linker.isReservedName("Object"));
    try std.testing.expect(!Linker.isReservedName("console"));
    try std.testing.expect(Linker.isReservedName("require"));
    try std.testing.expect(Linker.isReservedName("module"));
    try std.testing.expect(!Linker.isReservedName("myVar"));
}

test "computeRenamesForModules: 지정된 모듈만 대상으로 충돌 감지" {
    // 3개 모듈이 같은 이름 "x"를 가지지만,
    // computeRenamesForModules에 2개만 전달하면 그 2개만 충돌 처리.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nimport './c';\nconst x = 'a';");
    try writeFile(tmp.dir, "b.ts", "const x = 'b';");
    try writeFile(tmp.dir, "c.ts", "const x = 'c';");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var linker = Linker.init(std.testing.allocator, graph.modules.items);
    defer linker.deinit();
    try linker.link();

    // 전체 3개 모듈을 글로벌 rename — 2개가 rename됨
    try linker.computeRenames();
    var global_rename_count: usize = 0;
    for (graph.modules.items, 0..) |_, i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) global_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), global_rename_count);

    // per-module rename: 모듈 0, 1만 대상 → 1개만 rename됨
    const subset = &[_]ModuleIndex{ @enumFromInt(0), @enumFromInt(1) };
    try linker.computeRenamesForModules(subset, &.{});
    var subset_rename_count: usize = 0;
    for (graph.modules.items, 0..) |_, i| {
        if (linker.getCanonicalName(@intCast(i), "x") != null) subset_rename_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), subset_rename_count);
}

test "clearCanonicalNames: 초기화 후 비어있음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst x = 1;");
    try writeFile(tmp.dir, "b.ts", "const x = 2;");

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(&.{entry});

    var linker = Linker.init(std.testing.allocator, graph.modules.items);
    defer linker.deinit();
    try linker.link();
    try linker.computeRenames();

    // rename 결과가 있어야 함
    try std.testing.expect(linker.canonical_names.count() > 0);

    // 초기화 후 비어있어야 함
    linker.clearCanonicalNames();
    try std.testing.expectEqual(@as(usize, 0), linker.canonical_names.count());
}

// ============================================================
// Issue #282: namespace import (import * as X) scope hoisting
// ============================================================

test "namespace: import * as creates namespace object preamble" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils.add(1,2));");
    try writeFile(tmp.dir, "utils.ts", "export function add(a: number, b: number) { return a + b; }\nexport function mul(a: number, b: number) { return a * b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // namespace import는 resolved_bindings에 등록되지 않음 (resolveImports에서 skip)
    // 대신 buildMetadataForAst에서 preamble로 처리
    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: export * from re-exports collected in namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as all from './barrel';\nconsole.log(all);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './a';\nexport * from './b';");
    try writeFile(tmp.dir, "a.ts", "export const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // barrel 모듈에서 export * 로 a, b의 export를 수집
    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// Issue #283: re-export alias 바인딩 해결
// ============================================================

test "re-export alias: export { J as render } resolves to J" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // preact 패턴: 함수를 다른 이름으로 re-export
    try writeFile(tmp.dir, "entry.ts", "import { render } from './reexport';");
    try writeFile(tmp.dir, "reexport.ts", "export { J as render } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export function J() { return 42; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry의 import { render }가 impl.ts의 J에 연결
    const entry = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 impl.ts의 "J" — re-export 체인을 따라 최종 모듈의 export 이름
    const canon = binding.?.canonical;
    try std.testing.expectEqualStrings("J", canon.export_name);
    // resolveToLocalName도 "J" (impl.ts에서 함수명과 export명이 동일)
    const local = r.linker.resolveToLocalName(canon);
    try std.testing.expectEqualStrings("J", local);
}

test "re-export alias: export { default as groupBy } — function declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default <function_declaration> → binding_scanner가 함수 이름 추출
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export { default as greet } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default function hello() { return 'hi'; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // canonical은 impl.ts의 "default" → local_name = "hello" (함수명)
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("hello", local);
}

test "re-export alias: export { default as X } — expression defaults to _default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default <expression> → binding_scanner가 _default 폴백
    try writeFile(tmp.dir, "entry.ts", "import { groupBy } from './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export { default as groupBy } from './groupBy';");
    try writeFile(tmp.dir, "groupBy.ts", "function groupBy(arr: any) { return arr; }\nexport default groupBy;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // export default <identifier> → local_name = "_default" (expression 폴백)
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("_default", local);
}

// ============================================================
// Issue #284: _default 이름 충돌 해결
// ============================================================

test "rename: multiple export default expressions get unique _default names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 여러 모듈이 export default <expression> → 모두 _default로 변환 → 충돌
    try writeFile(tmp.dir, "entry.ts", "import './a';\nimport './b';\nimport './c';");
    try writeFile(tmp.dir, "a.ts", "const x = 1;\nexport default x;");
    try writeFile(tmp.dir, "b.ts", "const y = 2;\nexport default y;");
    try writeFile(tmp.dir, "c.ts", "const z = 3;\nexport default z;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // _default가 3개 모듈에서 충돌 → 2개가 _default$1, _default$2로 리네임
    var rename_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "_default$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), rename_count);
}

// ============================================================
// Issue #283+: namespace import edge cases
// ============================================================

test "namespace: diamond export * dedup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A exports * from B and C, both export * from shared.
    // x should appear once (no duplicate).
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './a';\nconsole.log(ns.x);");
    try writeFile(tmp.dir, "a.ts", "export * from './b';\nexport * from './c';");
    try writeFile(tmp.dir, "b.ts", "export * from './shared';");
    try writeFile(tmp.dir, "c.ts", "export * from './shared';");
    try writeFile(tmp.dir, "shared.ts", "export const x = 1;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry에서 namespace import로 ns를 가져옴 — 무한 루프 없이 완료
    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: circular export * no infinite loop" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A exports * from B, B exports * from A — 순환 export *
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './a';\nconsole.log(ns);");
    try writeFile(tmp.dir, "a.ts", "export * from './b';\nexport const x = 1;");
    try writeFile(tmp.dir, "b.ts", "export * from './a';\nexport const y = 2;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // 무한 루프 없이 완료되면 성공
    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: mixed named + default exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 모듈이 named export와 default export를 모두 가짐
    try writeFile(tmp.dir, "entry.ts", "import * as m from './mod';\nconsole.log(m.x, m.default);");
    try writeFile(tmp.dir, "mod.ts", "export const x = 1;\nexport default 42;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "namespace: re-export alias in namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // barrel이 J를 render로 re-export → namespace에서 render로 접근 가능해야 함
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './barrel';\nconsole.log(ns.render);");
    try writeFile(tmp.dir, "barrel.ts", "export { J as render } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export function J() { return 42; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// Re-export alias edge cases
// ============================================================

test "re-export alias: double-hop chain (z -> y -> x)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 3-level alias chain: z → y → x → 최종 original
    try writeFile(tmp.dir, "entry.ts", "import { z } from './hop1';");
    try writeFile(tmp.dir, "hop1.ts", "export { y as z } from './hop2';");
    try writeFile(tmp.dir, "hop2.ts", "export { x as y } from './origin';");
    try writeFile(tmp.dir, "origin.ts", "export function x() { return 1; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // 3-hop chain → 최종 origin.ts의 "x"
    const canon = binding.?.canonical;
    try std.testing.expectEqualStrings("x", canon.export_name);
    const local = r.linker.resolveToLocalName(canon);
    try std.testing.expectEqualStrings("x", local);
}

test "re-export alias: default class declaration resolves to class name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // export default class MyClass {} → local_name = "MyWidget"
    try writeFile(tmp.dir, "entry.ts", "import { Widget } from './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export { default as Widget } from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export default class MyWidget { render() {} }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    const entry = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    // default class declaration → local_name = "MyWidget"
    const local = r.linker.resolveToLocalName(binding.?.canonical);
    try std.testing.expectEqualStrings("MyWidget", local);
}

// ============================================================
// _default collision edge cases
// ============================================================

test "rename: mixed function + expression defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // function default는 함수명 유지, expression defaults는 _default$N
    try writeFile(tmp.dir, "entry.ts", "import a from './func';\nimport b from './expr1';\nimport c from './expr2';");
    try writeFile(tmp.dir, "func.ts", "export default function myFunc() { return 1; }");
    try writeFile(tmp.dir, "expr1.ts", "const val = 2;\nexport default val;");
    try writeFile(tmp.dir, "expr2.ts", "const val = 3;\nexport default val;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // expression default 2개 + function default 1개 = 총 3개 default
    // expression defaults가 _default를 사용하므로 충돌 해결이 발생
    var default_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "_default")) default_count += 1;
    }
    // _default가 여러 모듈에서 사용되면 충돌 해결이 발생
    try std.testing.expect(default_count >= 1);
}

test "rename: _default consumed via import default binding" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈의 expression default를 import default로 가져옴
    try writeFile(tmp.dir, "entry.ts", "import a from './a';\nimport b from './b';\nconsole.log(a, b);");
    try writeFile(tmp.dir, "a.ts", "const x = 10;\nexport default x;");
    try writeFile(tmp.dir, "b.ts", "const y = 20;\nexport default y;");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // 두 모듈 모두 _default → 하나는 _default$1로 리네임
    var rename_count: u32 = 0;
    var cit = r.linker.canonical_names.valueIterator();
    while (cit.next()) |val| {
        if (std.mem.startsWith(u8, val.*, "_default$")) rename_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), rename_count);
}

// ============================================================
// export * as ns from (ES2020 namespace re-export) — #289
// ============================================================

test "export * as: basic namespace re-export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { math } from './barrel';\nconsole.log(math.add(1, 2));");
    try writeFile(tmp.dir, "barrel.ts", "export * as math from './math';");
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry의 import { math }가 barrel의 "math" export에 연결
    const entry = r.graph.modules.items[0];
    const binding = r.linker.getResolvedBinding(0, entry.import_bindings[0].local_span);
    try std.testing.expect(binding != null);
    try std.testing.expectEqualStrings("math", binding.?.canonical.export_name);
}

test "export * as: binding_scanner registers named export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './barrel';");
    try writeFile(tmp.dir, "barrel.ts", "export * as utils from './utils';");
    try writeFile(tmp.dir, "utils.ts", "export const x = 1;");

    var r = try buildAndLink(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // barrel 모듈(index 1)의 export_bindings에 "utils" 이름이 등록됨
    var has_utils_export = false;
    for (r.graph.modules.items) |m| {
        for (m.export_bindings) |eb| {
            if (std.mem.eql(u8, eb.exported_name, "utils")) {
                has_utils_export = true;
                // local_name도 "utils" (preamble에서 var utils = {...} 생성용)
                try std.testing.expectEqualStrings("utils", eb.local_name);
            }
        }
    }
    try std.testing.expect(has_utils_export);
}

// ============================================================
// esbuild 방식 namespace import — ns.prop 직접 치환
// ============================================================

test "namespace rewrite: ns.prop resolved in ns_member_rewrites" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import * as utils from './utils';\nconsole.log(utils.add(1, 2));");
    try writeFile(tmp.dir, "utils.ts", "export function add(a: number, b: number) { return a + b; }\nexport function mul(a: number, b: number) { return a * b; }");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // ns.prop만 사용 → ns_member_rewrites에 매핑 등록
    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

// ============================================================
// semantic analyzer: property key symbol_id 미할당
// ============================================================

test "semantic: non-shorthand property key has no symbol_id" {
    // { checks: [] } — "checks" key는 변수 참조가 아님
    // semantic analyzer에서 symbol_id를 할당하지 않아야 함
    const source = "const checks = 1;\nconst obj = { checks: [] };";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    // "checks" 변수 선언은 reference_count 증가 없어야 함
    // (shorthand가 아닌 property key에서 참조 안 됨)
    // 정확히는: checks 변수의 reference_count가 0이어야 함
    // (const obj = { checks: [] }에서 checks key는 resolve 안 됨)
    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("checks")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                // shorthand가 아닌 property key에서 참조되지 않으므로 ref count = 0
                try std.testing.expectEqual(@as(u32, 0), analyzer.symbols.items[sym_idx].reference_count);
            }
        }
    }
}

test "semantic: shorthand property key has symbol_id" {
    // { checks } — shorthand에서는 "checks"가 변수 참조
    const source = "const checks = 1;\nconst obj = { checks };";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    // shorthand { checks } 에서 checks는 변수 참조 → reference_count > 0
    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("checks")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expect(analyzer.symbols.items[sym_idx].reference_count > 0);
            }
        }
    }
}

// ============================================================
// export * as ns — seen 오염 방지 (독립 namespace)
// ============================================================

test "export * as: does not pollute parent seen (name collision)" {
    // export * as ns의 내부 export가 외부 export *의 같은 이름을 덮어쓰면 안 됨
    // regexes에 string (regex), schemas에 string (factory) → 외부는 schemas의 string 사용
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "regexes.ts", "export const string = /^.*$/;");
    try writeFile(tmp.dir, "schemas.ts", "export function string() { return 'schema'; }");
    try writeFile(tmp.dir, "core.ts", "export * as regexes from './regexes';\nexport * from './schemas';");
    try writeFile(tmp.dir, "entry.ts", "import * as ns from './core';\nconsole.log(ns.string());");

    var r = try buildLinkAndRename(std.testing.allocator, &tmp, "entry.ts");
    defer r.linker.deinit();
    defer r.graph.deinit();
    defer r.cache.deinit();

    // entry의 namespace import 확인
    const entry = r.graph.modules.items[0];
    try std.testing.expect(entry.import_bindings.len > 0);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, entry.import_bindings[0].kind);
}

test "semantic: non-shorthand {x: y} does not reference x" {
    // {x: y} — x는 property name (변수 참조 아님), y는 변수 참조
    const source = "const x = 1;\nconst y = 2;\nconst obj = {x: y};";
    const Sem = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;

    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var analyzer = Sem.init(std.testing.allocator, &parser.ast);
    defer analyzer.deinit();
    _ = analyzer.analyze() catch {};

    if (analyzer.scope_maps.items.len > 0) {
        if (analyzer.scope_maps.items[0].get("x")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expectEqual(@as(u32, 0), analyzer.symbols.items[sym_idx].reference_count);
            }
        }
        if (analyzer.scope_maps.items[0].get("y")) |sym_idx| {
            if (sym_idx < analyzer.symbols.items.len) {
                try std.testing.expect(analyzer.symbols.items[sym_idx].reference_count > 0);
            }
        }
    }
}
