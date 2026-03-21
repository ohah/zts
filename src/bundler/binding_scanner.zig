//! ZTS Bundler — Binding Scanner
//!
//! AST에서 import/export의 바인딩 상세를 추출한다.
//! import_scanner.zig는 specifier 경로만 추출하지만,
//! 이 모듈은 "어떤 이름이 어떤 이름으로 바인딩되는지"를 추출한다.
//!
//! 예:
//!   import { foo as bar } from './dep'
//!   → ImportBinding { kind=.named, local_name="bar", imported_name="foo" }
//!
//!   export const x = 1;
//!   → ExportBinding { exported_name="x", local_name="x", kind=.local }

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;

pub const ImportBinding = struct {
    kind: Kind,
    /// 이 모듈에서 사용하는 로컬 이름 (e.g. "bar" in `import { foo as bar }`)
    local_name: []const u8,
    /// 상대 모듈에서 export된 이름 (e.g. "foo", "default", "*")
    imported_name: []const u8,
    /// 로컬 바인딩의 소스 위치 (linker의 rename 키로 사용)
    local_span: Span,
    /// 어떤 import 문에서 왔는지 (ImportRecord 인덱스)
    import_record_index: u32,

    pub const Kind = enum {
        default,
        named,
        namespace,
    };
};

pub const ExportBinding = struct {
    /// 외부에 노출되는 이름 (e.g. "x", "default", "b" in `export { a as b }`)
    exported_name: []const u8,
    /// 모듈 내부 이름 (e.g. "x", "a")
    local_name: []const u8,
    local_span: Span,
    kind: Kind,
    /// re-export 시 소스 모듈의 ImportRecord 인덱스
    import_record_index: ?u32 = null,

    pub const Kind = enum {
        local,
        re_export,
        re_export_all,
    };
};

/// AST에서 import 바인딩 상세를 추출한다.
/// import_record_map: import source span → ImportRecord 인덱스 매핑
pub fn extractImportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    import_records: []const types.ImportRecord,
) ![]ImportBinding {
    var bindings: std.ArrayList(ImportBinding) = .empty;
    errdefer bindings.deinit(allocator);

    // import source span → import_record 인덱스 매핑
    var source_to_record = std.AutoHashMap(u64, u32).init(allocator);
    defer source_to_record.deinit();
    for (import_records, 0..) |rec, i| {
        const key = types.spanKey(rec.span);
        try source_to_record.put(key, @intCast(i));
    }

    for (ast.nodes.items) |node| {
        if (node.tag != .import_declaration) continue;

        const e = node.data.extra;
        if (e + 2 >= ast.extra_data.items.len) continue;

        const extras = ast.extra_data.items[e .. e + 3];
        const specs_start = extras[0];
        const specs_len = extras[1];
        const source_idx: NodeIndex = @enumFromInt(extras[2]);
        if (source_idx.isNone()) continue;

        // source span으로 ImportRecord 인덱스 찾기
        const source_node = ast.getNode(source_idx);
        const rec_idx = source_to_record.get(types.spanKey(source_node.span)) orelse continue;

        if (specs_len == 0) continue; // side-effect import

        const spec_indices = ast.extra_data.items[specs_start .. specs_start + specs_len];
        for (spec_indices) |raw_idx| {
            const spec: NodeIndex = @enumFromInt(raw_idx);
            if (spec.isNone()) continue;
            if (@intFromEnum(spec) >= ast.nodes.items.len) continue;

            const spec_node = ast.getNode(spec);
            switch (spec_node.tag) {
                .import_default_specifier => {
                    const name = ast.source[spec_node.span.start..spec_node.span.end];
                    try bindings.append(allocator, .{
                        .kind = .default,
                        .local_name = name,
                        .imported_name = "default",
                        .local_span = spec_node.span,
                        .import_record_index = rec_idx,
                    });
                },
                .import_namespace_specifier => {
                    const name = ast.source[spec_node.span.start..spec_node.span.end];
                    try bindings.append(allocator, .{
                        .kind = .namespace,
                        .local_name = name,
                        .imported_name = "*",
                        .local_span = spec_node.span,
                        .import_record_index = rec_idx,
                    });
                },
                .import_specifier => {
                    // binary { left=imported, right=local }
                    const imported_idx = spec_node.data.binary.left;
                    const local_idx = spec_node.data.binary.right;
                    if (imported_idx.isNone()) continue;

                    const imported_node = ast.getNode(imported_idx);
                    const imported_name = ast.source[imported_node.span.start..imported_node.span.end];

                    const local_node = if (!local_idx.isNone() and @intFromEnum(local_idx) != @intFromEnum(imported_idx))
                        ast.getNode(local_idx)
                    else
                        imported_node;
                    const local_name = ast.source[local_node.span.start..local_node.span.end];

                    try bindings.append(allocator, .{
                        .kind = .named,
                        .local_name = local_name,
                        .imported_name = imported_name,
                        .local_span = local_node.span,
                        .import_record_index = rec_idx,
                    });
                },
                else => {},
            }
        }
    }

    return bindings.toOwnedSlice(allocator);
}

/// AST에서 export 바인딩 상세를 추출한다.
pub fn extractExportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    import_records: []const types.ImportRecord,
) ![]ExportBinding {
    var bindings: std.ArrayList(ExportBinding) = .empty;
    errdefer bindings.deinit(allocator);

    // import source span → import_record 인덱스 매핑 (re-export용)
    var source_to_record = std.AutoHashMap(u64, u32).init(allocator);
    defer source_to_record.deinit();
    for (import_records, 0..) |rec, i| {
        const key = types.spanKey(rec.span);
        try source_to_record.put(key, @intCast(i));
    }

    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .export_named_declaration => {
                const e = node.data.extra;
                if (e + 3 >= ast.extra_data.items.len) continue;

                const extras = ast.extra_data.items[e .. e + 4];
                const decl_idx: NodeIndex = @enumFromInt(extras[0]);
                const specs_start = extras[1];
                const specs_len = extras[2];
                const source_idx: NodeIndex = @enumFromInt(extras[3]);

                // export const x = 1; / export function f() {}
                if (!decl_idx.isNone()) {
                    const decl_node = ast.getNode(decl_idx);
                    // variable_declaration은 여러 declarator를 가질 수 있음 (export const x=1, y=2)
                    const names = try extractDeclExportNames(allocator, ast, decl_node);
                    defer allocator.free(names);
                    for (names) |name_info| {
                        try bindings.append(allocator, .{
                            .exported_name = name_info.name,
                            .local_name = name_info.name,
                            .local_span = name_info.span,
                            .kind = .local,
                        });
                    }
                    continue;
                }

                // export { a, b } 또는 export { a } from './dep'
                const has_source = !source_idx.isNone();
                const rec_idx: ?u32 = if (has_source) blk: {
                    const src_node = ast.getNode(source_idx);
                    break :blk source_to_record.get(types.spanKey(src_node.span));
                } else null;

                if (specs_len > 0) {
                    const spec_indices = ast.extra_data.items[specs_start .. specs_start + specs_len];
                    for (spec_indices) |raw_idx| {
                        const spec: NodeIndex = @enumFromInt(raw_idx);
                        if (spec.isNone()) continue;
                        if (@intFromEnum(spec) >= ast.nodes.items.len) continue;
                        const spec_node = ast.getNode(spec);
                        if (spec_node.tag != .export_specifier) continue;

                        // binary { left=local, right=exported }
                        const local_idx = spec_node.data.binary.left;
                        const exported_idx = spec_node.data.binary.right;
                        if (local_idx.isNone()) continue;

                        const local_node = ast.getNode(local_idx);
                        const local_name = ast.source[local_node.span.start..local_node.span.end];

                        const exported_node = if (!exported_idx.isNone() and @intFromEnum(exported_idx) != @intFromEnum(local_idx))
                            ast.getNode(exported_idx)
                        else
                            local_node;
                        const exported_name = ast.source[exported_node.span.start..exported_node.span.end];

                        try bindings.append(allocator, .{
                            .exported_name = exported_name,
                            .local_name = local_name,
                            .local_span = local_node.span,
                            .kind = if (has_source) .re_export else .local,
                            .import_record_index = rec_idx,
                        });
                    }
                }
            },
            .export_default_declaration => {
                try bindings.append(allocator, .{
                    .exported_name = "default",
                    .local_name = "default",
                    .local_span = node.span,
                    .kind = .local,
                });
            },
            .export_all_declaration => {
                // binary { left=exported_name, right=source_node }
                const source_idx = node.data.binary.right;
                if (source_idx.isNone()) continue;
                const src_node = ast.getNode(source_idx);
                const rec_idx = source_to_record.get(types.spanKey(src_node.span));

                try bindings.append(allocator, .{
                    .exported_name = "*",
                    .local_name = "*",
                    .local_span = node.span,
                    .kind = .re_export_all,
                    .import_record_index = rec_idx,
                });
            },
            else => {},
        }
    }

    return bindings.toOwnedSlice(allocator);
}

const NameInfo = struct { name: []const u8, span: Span };

/// export 선언에서 이름들을 추출. export const x, y / export function f / export class C
fn extractDeclExportNames(allocator: std.mem.Allocator, ast: *const Ast, decl: Node) ![]NameInfo {
    var names: std.ArrayList(NameInfo) = .empty;
    errdefer names.deinit(allocator);

    switch (decl.tag) {
        .variable_declaration => {
            // extra [kind_flags, list.start, list.len]
            const e = decl.data.extra;
            if (e + 2 >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const list_start = ast.extra_data.items[e + 1];
            const list_len = ast.extra_data.items[e + 2];
            if (list_len == 0) return names.toOwnedSlice(allocator);

            // 모든 declarator 순회
            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const idx = list_start + i;
                if (idx >= ast.extra_data.items.len) break;
                const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[idx]);
                if (decl_idx.isNone()) continue;
                if (@intFromEnum(decl_idx) >= ast.nodes.items.len) continue;
                const decl_node = ast.getNode(decl_idx);
                if (decl_node.tag != .variable_declarator) continue;
                // variable_declarator: extra [name, type_ann, init_expr]
                const de = decl_node.data.extra;
                if (de >= ast.extra_data.items.len) continue;
                const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de]);
                if (name_idx.isNone()) continue;
                if (@intFromEnum(name_idx) >= ast.nodes.items.len) continue;
                const name_node = ast.getNode(name_idx);
                try names.append(allocator, .{
                    .name = ast.source[name_node.span.start..name_node.span.end],
                    .span = name_node.span,
                });
            }
        },
        .function_declaration => {
            const e = decl.data.extra;
            if (e >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
            if (name_idx.isNone()) return names.toOwnedSlice(allocator);
            const name_node = ast.getNode(name_idx);
            try names.append(allocator, .{
                .name = ast.source[name_node.span.start..name_node.span.end],
                .span = name_node.span,
            });
        },
        .class_declaration => {
            const e = decl.data.extra;
            if (e >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
            if (name_idx.isNone()) return names.toOwnedSlice(allocator);
            const name_node = ast.getNode(name_idx);
            try names.append(allocator, .{
                .name = ast.source[name_node.span.start..name_node.span.end],
                .span = name_node.span,
            });
        },
        else => {},
    }

    return names.toOwnedSlice(allocator);
}

// ============================================================
// Tests
// ============================================================

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const import_scanner = @import("import_scanner.zig");

fn parseAndExtractBindings(allocator: std.mem.Allocator, source: []const u8) !struct {
    import_bindings: []ImportBinding,
    export_bindings: []ExportBinding,
    import_records: []types.ImportRecord,
    arena: std.heap.ArenaAllocator,
} {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    const records = try import_scanner.extractImports(allocator, &parser.ast);

    const import_bindings = try extractImportBindings(allocator, &parser.ast, records);
    const export_bindings = try extractExportBindings(allocator, &parser.ast, records);

    return .{
        .import_bindings = import_bindings,
        .export_bindings = export_bindings,
        .import_records = records,
        .arena = arena,
    };
}

test "import binding: named import" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import { foo } from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("foo", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("foo", r.import_bindings[0].imported_name);
    try std.testing.expectEqual(ImportBinding.Kind.named, r.import_bindings[0].kind);
}

test "import binding: named import with alias" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import { foo as bar } from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("bar", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("foo", r.import_bindings[0].imported_name);
}

test "import binding: default import" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import myDefault from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("myDefault", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("default", r.import_bindings[0].imported_name);
    try std.testing.expectEqual(ImportBinding.Kind.default, r.import_bindings[0].kind);
}

test "import binding: namespace import" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import * as ns from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("ns", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("*", r.import_bindings[0].imported_name);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, r.import_bindings[0].kind);
}

test "import binding: side-effect import — no bindings" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import './side-effect';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 0), r.import_bindings.len);
}

test "export binding: export const" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export const x = 1;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].local_name);
    try std.testing.expectEqual(ExportBinding.Kind.local, r.export_bindings[0].kind);
}

test "export binding: export { a as b }" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "const a = 1; export { a as b };");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("b", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("a", r.export_bindings[0].local_name);
}

test "export binding: re-export" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export { x } from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.re_export, r.export_bindings[0].kind);
    try std.testing.expect(r.export_bindings[0].import_record_index != null);
}

test "export binding: export default" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export default 42;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("default", r.export_bindings[0].exported_name);
}

test "export binding: export all" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export * from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("*", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.re_export_all, r.export_bindings[0].kind);
}

test "export binding: export function" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export function greet() { return 'hi'; }");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("greet", r.export_bindings[0].exported_name);
}

test "export binding: multi-declarator (export const x=1, y=2)" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export const x = 1, y = 2;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 2), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("y", r.export_bindings[1].exported_name);
}

test "mixed: import + export" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import { x } from './a'; export const y = x + 1;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("y", r.export_bindings[0].exported_name);
}
