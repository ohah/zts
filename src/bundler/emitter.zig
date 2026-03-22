//! ZTS Bundler — Emitter
//!
//! 모듈 그래프의 모듈들을 exec_index 순서로 변환+코드젠하여
//! 단일 파일 번들로 출력한다.
//!
//! 책임:
//!   - exec_index 순서 정렬
//!   - 각 모듈: Transformer → Codegen
//!   - 포맷별 래핑 (ESM/CJS/IIFE)
//!   - import/export 처리는 linker(별도 PR)에서 담당
//!
//! 설계:
//!   - Rollup 방식: emitter(finaliser)와 linker 분리 (유지보수 우선)
//!   - D058: exec_index 순서 = ESM 실행 순서

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const WrapKind = types.WrapKind;

/// CJS 런타임 헬퍼: __commonJS 팩토리 함수 (esbuild 호환)
const CJS_RUNTIME = "var __commonJS = (cb, mod) => function __require() {\n\treturn mod || (0, cb[Object.keys(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;\n};\n";
const CJS_RUNTIME_MIN = "var __commonJS=(cb,mod)=>function __require(){return mod||(0,cb[Object.keys(cb)[0]])((mod={exports:{}}).exports,mod),mod.exports};";

/// __toESM 런타임 헬퍼: CJS 모듈을 ESM namespace로 변환 (esbuild 호환, 간소화 버전).
/// __esModule 플래그가 설정되어 있으면 모듈 그대로 반환 (babel/SWC 컨벤션),
/// 아니면 { ...mod, default: mod } 형태로 namespace 객체 생성.
const TOESM_RUNTIME = "var __toESM = (mod) => mod && mod.__esModule ? mod : { ...mod, default: mod };\n";
const TOESM_RUNTIME_MIN = "var __toESM=(mod)=>mod&&mod.__esModule?mod:{...mod,default:mod};";
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const Ast = @import("../parser/ast.zig").Ast;
const Transformer = @import("../transformer/transformer.zig").Transformer;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../codegen/codegen.zig").CodegenOptions;
const Linker = @import("linker.zig").Linker;
const LinkingMetadata = @import("linker.zig").LinkingMetadata;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;

pub const EmitOptions = struct {
    format: Format = .esm,
    minify: bool = false,

    pub const Format = enum {
        esm,
        cjs,
        iife,
    };
};

pub const OutputFile = struct {
    path: []const u8,
    contents: []const u8,
};

/// 모듈 그래프를 단일 번들로 출력한다.
/// 반환된 contents는 allocator 소유 (caller가 free).
pub fn emit(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
) ![]const u8 {
    return emitWithTreeShaking(allocator, graph, options, linker, null);
}

/// tree-shaking 적용된 번들 출력. shaker가 null이면 모든 모듈 포함 (기존 동작).
pub fn emitWithTreeShaking(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
    shaker: ?*const TreeShaker,
) ![]const u8 {
    // 1. JS 모듈만 필터 + exec_index 순으로 정렬
    var sorted: std.ArrayList(*const Module) = .empty;
    defer sorted.deinit(allocator);

    for (graph.modules.items, 0..) |*m, i| {
        if (m.module_type == .javascript and m.ast != null) {
            // tree-shaking: 미포함 모듈 스킵
            if (shaker) |s| {
                if (!s.isIncluded(@intCast(i))) continue;
            }
            try sorted.append(allocator, m);
        }
    }

    std.mem.sort(*const Module, sorted.items, {}, struct {
        fn lessThan(_: void, a: *const Module, b: *const Module) bool {
            return a.exec_index < b.exec_index;
        }
    }.lessThan);

    // 2. 각 모듈을 변환 + 코드젠
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // 포맷별 prologue
    switch (options.format) {
        .iife => try output.appendSlice(allocator, "(function() {\n"),
        .cjs => try output.appendSlice(allocator, "'use strict';\n"),
        .esm => {},
    }

    // CJS 런타임 헬퍼 주입: CJS 래핑 모듈이 하나라도 있으면 주입
    var needs_cjs_runtime = false;
    for (sorted.items) |m| {
        if (m.wrap_kind == .cjs) {
            needs_cjs_runtime = true;
            break;
        }
    }
    if (needs_cjs_runtime) {
        if (options.minify) {
            try output.appendSlice(allocator, CJS_RUNTIME_MIN);
            try output.appendSlice(allocator, TOESM_RUNTIME_MIN);
        } else {
            try output.appendSlice(allocator, CJS_RUNTIME);
            try output.appendSlice(allocator, TOESM_RUNTIME);
        }
    }

    // 엔트리 모듈 인덱스 (final exports용)
    const entry_idx: ?u32 = if (sorted.items.len > 0)
        @intFromEnum(sorted.items[sorted.items.len - 1].index)
    else
        null;

    for (sorted.items) |m| {
        const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;
        const code = try emitModule(allocator, m, options, linker, is_entry) orelse continue;
        defer allocator.free(code);

        if (!options.minify) {
            // 모듈 경계 주석 (디버깅용)
            try output.appendSlice(allocator, "// --- ");
            try output.appendSlice(allocator, std.fs.path.basename(m.path));
            try output.appendSlice(allocator, " ---\n");
        }

        try output.appendSlice(allocator, code);
        if (!options.minify) {
            try output.append(allocator, '\n');
        }
    }

    // 포맷별 epilogue
    switch (options.format) {
        .iife => try output.appendSlice(allocator, "})();\n"),
        .cjs, .esm => {},
    }

    return output.toOwnedSlice(allocator);
}

/// 단일 모듈을 Transformer → Codegen 파이프라인으로 처리.
/// 모듈별 arena에 AST가 보존되어 있으므로 재파싱 불필요.
fn emitModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
) !?[]const u8 {
    const ast = &(module.ast orelse return null);

    // 변환용 arena (Transformer/Codegen 내부 메모리)
    var emit_arena = std.heap.ArenaAllocator.init(allocator);
    defer emit_arena.deinit();
    const arena_alloc = emit_arena.allocator();

    // Transformer: TS 타입 스트리핑 등
    var transformer = Transformer.init(arena_alloc, ast, .{});
    // symbol_ids 전파: semantic analyzer가 생성한 원본 AST의 symbol_ids를
    // transformer가 new_ast 기준으로 재매핑
    if (module.semantic) |sem| {
        transformer.old_symbol_ids = sem.symbol_ids;
    }
    const root = try transformer.transform();

    // Linker 메타데이터 생성 (있으면) — new_ast 기준으로 구축
    var metadata: ?LinkingMetadata = null;
    defer if (metadata) |*m| m.deinit();

    if (linker) |l| {
        // new_ast 기준으로 skip_nodes 구축 (transformer 이후이므로 노드 인덱스가 new_ast와 일치)
        var md = try l.buildMetadataForAst(
            &transformer.new_ast,
            @intFromEnum(module.index),
            is_entry,
        );
        // transformer가 전파한 new_symbol_ids를 메타데이터에 설정
        if (transformer.new_symbol_ids.items.len > 0) {
            md.symbol_ids = transformer.new_symbol_ids.items;
        }
        metadata = md;
    }

    // Cross-module @__NO_SIDE_EFFECTS__ 전파:
    // import한 함수가 원본 모듈에서 no_side_effects로 선언되었으면
    // 현재 모듈의 해당 호출에 is_pure 플래그를 자동 설정한다.
    if (linker) |l| {
        const sym_ids = if (metadata) |md| md.symbol_ids else &.{};
        propagateCrossModulePurity(l, module, &transformer.new_ast, sym_ids, arena_alloc);
    }

    // Codegen: AST → JS 문자열
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
        .minify = options.minify,
        .module_format = switch (options.format) {
            .cjs => .cjs,
            else => .esm,
        },
        .linking_metadata = if (metadata) |*m| m else null,
    });
    const code = try cg.generate(root);

    // CJS 래핑: __commonJS 팩토리 함수로 감싸기
    if (module.wrap_kind == .cjs) {
        const basename = std.fs.path.basename(module.path);

        const var_name = try types.makeRequireVarName(allocator, module.path);
        defer allocator.free(var_name);

        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);

        if (options.minify) {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, "=__commonJS({\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports,module){");
            try wrapped.appendSlice(allocator, code);
            try wrapped.appendSlice(allocator, "}});");
        } else {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, " = __commonJS({\n\t\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports, module) {\n");
            // 내부 코드 들여쓰기
            for (code) |c| {
                try wrapped.append(allocator, c);
                if (c == '\n') try wrapped.append(allocator, '\t');
            }
            try wrapped.appendSlice(allocator, "\n\t}\n});\n");
        }

        return try allocator.dupe(u8, wrapped.items);
    }

    // CJS import preamble + final_exports를 하나의 concat으로 합침 (중간 할당 누수 방지)
    const preamble = if (metadata) |md| md.cjs_import_preamble else null;
    const final_exports = if (metadata) |md| md.final_exports else null;

    if (preamble != null or final_exports != null) {
        return try std.mem.concat(allocator, u8, &.{
            preamble orelse "",
            code,
            final_exports orelse "",
        });
    }

    // arena 해제 전에 복사 (caller 소유)
    return try allocator.dupe(u8, code);
}

/// Cross-module @__NO_SIDE_EFFECTS__ 전파.
///
/// 단일 모듈 내에서는 semantic analyzer가 callee symbol의 no_side_effects 플래그를 보고
/// call_expression에 is_pure를 자동 설정한다 (analyzer.zig:863-876).
/// 하지만 cross-module import의 경우, importing 모듈의 semantic analyzer는 원본 모듈의
/// symbol을 모르므로 is_pure가 설정되지 않는다.
///
/// 이 함수는 linker가 해석한 import→export 바인딩을 활용하여:
/// 1. import한 symbol이 원본 모듈에서 no_side_effects로 선언되었는지 확인
/// 2. 해당 symbol을 callee로 사용하는 call_expression에 is_pure 플래그 설정
fn propagateCrossModulePurity(
    linker: *const Linker,
    module: *const Module,
    new_ast: *Ast,
    symbol_ids: []const ?u32,
    allocator: std.mem.Allocator,
) void {
    const sem = module.semantic orelse return;
    if (sem.scope_maps.len == 0) return;
    if (module.import_bindings.len == 0) return;
    const module_scope = sem.scope_maps[0];
    const module_index: u32 = @intFromEnum(module.index);

    // 1단계: no_side_effects인 import binding의 local symbol_id를 수집한다.
    // 비트셋 대신 bool 배열 사용 — 스택 256개, 초과 시 arena fallback.
    var has_any_pure = false;
    const sym_count = sem.symbols.len;
    if (sym_count == 0) return;

    var pure_flags_buf: [256]bool = .{false} ** 256;
    const pure_flags: []bool = if (sym_count <= 256)
        pure_flags_buf[0..sym_count]
    else
        allocator.alloc(bool, sym_count) catch return;
    defer if (sym_count > 256) allocator.free(pure_flags);
    if (sym_count > 256) @memset(pure_flags, false);

    for (module.import_bindings) |ib| {
        if (ib.kind == .namespace) continue;

        const resolved = linker.getResolvedBinding(module_index, ib.local_span) orelse continue;

        const canon_mod_idx = @intFromEnum(resolved.canonical.module_index);
        if (canon_mod_idx >= linker.modules.len) continue;
        const target_module = linker.modules[canon_mod_idx];
        const target_sem = target_module.semantic orelse continue;

        if (target_sem.scope_maps.len == 0) continue;
        const target_scope = target_sem.scope_maps[0];

        // default export는 local_name이 다를 수 있음 ("default" → 실제 함수명)
        const target_sym_name = if (std.mem.eql(u8, resolved.canonical.export_name, "default"))
            linker.getExportLocalName(canon_mod_idx, "default") orelse resolved.canonical.export_name
        else
            resolved.canonical.export_name;

        const target_sym_idx = target_scope.get(target_sym_name) orelse continue;
        if (target_sym_idx >= target_sem.symbols.len) continue;
        if (!target_sem.symbols[target_sym_idx].decl_flags.no_side_effects) continue;

        const local_sym_idx = module_scope.get(ib.local_name) orelse continue;
        if (local_sym_idx >= sym_count) continue;

        pure_flags[local_sym_idx] = true;
        has_any_pure = true;
    }

    if (!has_any_pure) return;

    // 2단계: new_ast의 call/new expression 중 callee가 pure import이면 is_pure 설정
    const CallFlags = @import("../parser/ast.zig").CallFlags;

    for (new_ast.nodes.items) |node| {
        if (node.tag != .call_expression and node.tag != .new_expression) continue;

        const e = node.data.extra;
        if (!new_ast.hasExtra(e, 3)) continue;

        const callee_idx = new_ast.readExtraNode(e, 0);
        if (callee_idx.isNone()) continue;
        const callee_ni = @intFromEnum(callee_idx);

        if (callee_ni >= new_ast.nodes.items.len) continue;
        if (new_ast.nodes.items[callee_ni].tag != .identifier_reference) continue;

        if (callee_ni >= symbol_ids.len) continue;
        const sym_idx = symbol_ids[callee_ni] orelse continue;
        if (sym_idx >= sym_count) continue;

        if (pure_flags[sym_idx]) {
            new_ast.extra_data.items[e + 3] |= CallFlags.is_pure;
        }
    }
}

// ============================================================
// Tests
// ============================================================

const resolve_cache_mod = @import("resolve_cache.zig");

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    dir.writeFile(.{ .sub_path = path, .data = data }) catch |err| return err;
}

fn buildGraph(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !struct { graph: ModuleGraph, cache: resolve_cache_mod.ResolveCache } {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .browser, &.{});
    var graph = ModuleGraph.init(allocator, &cache);
    try graph.build(&.{entry});
    return .{ .graph = graph, .cache = cache };
}

test "emitter: single module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // TS 타입 스트리핑: "const x: number = 1;" → "const x = 1;"
    try std.testing.expect(std.mem.indexOf(u8, output, "const x = 1;") != null);
}

test "emitter: two modules exec order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 1;");
    try writeFile(tmp.dir, "b.ts", "const b = 2;");

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // b.ts가 a.ts보다 먼저 출력 (exec_index 순서)
    const b_pos = std.mem.indexOf(u8, output, "const b = 2;") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, output, "const a = 1;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b_pos < a_pos);
}

test "emitter: minified output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .minify = true }, null);
    defer std.testing.allocator.free(output);

    // minify: 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, output, "// ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const x=1;") != null);
}

test "emitter: IIFE format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .iife }, null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n"));
}

test "emitter: CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .cjs }, null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "'use strict';\n"));
}

test "emitter: empty graph" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    const output = try emit(std.testing.allocator, &graph, .{}, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "emitter: chain A → B → C order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 'a';");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconst b = 'b';");
    try writeFile(tmp.dir, "c.ts", "const c = 'c';");

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // C → B → A 순서
    const c_pos = std.mem.indexOf(u8, output, "const c = 'c';") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, output, "const b = 'b';") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, output, "const a = 'a';") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c_pos < b_pos);
    try std.testing.expect(b_pos < a_pos);
}

test "emitter: TS enum and interface stripping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\interface Foo { x: number; }
        \\enum Color { Red, Green, Blue }
        \\const x: Foo = { x: 1 };
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // interface 제거됨
    try std.testing.expect(std.mem.indexOf(u8, output, "interface") == null);
    // enum → IIFE 변환
    try std.testing.expect(std.mem.indexOf(u8, output, "Color") != null);
    // 일반 코드 유지
    try std.testing.expect(std.mem.indexOf(u8, output, "const x") != null);
}
