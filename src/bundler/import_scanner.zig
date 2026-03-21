//! ZTS Bundler — Import Scanner
//!
//! 파싱된 AST를 순회하여 모든 import/export 소스 경로를 추출한다 (D079).
//! 파서를 수정하지 않고 AST 노드의 태그만 검사하여 ImportRecord 배열을 생성.
//!
//! 지원하는 구문:
//!   - import "./foo"                     → side_effect
//!   - import x from "./foo"              → static_import
//!   - import { a, b } from "./foo"       → static_import
//!   - import * as ns from "./foo"        → static_import
//!   - export { x } from "./foo"          → re_export
//!   - export * from "./foo"              → re_export
//!   - import("./foo")                    → dynamic_import
//!
//! AST extra_data 레이아웃:
//!   - import_declaration:         [specs_start, specs_len, source_node]
//!   - export_named_declaration:   [declaration, specs_start, specs_len, source]
//!   - export_all_declaration:     binary { left=exported_name, right=source_node }
//!   - import_expression:          unary { operand=arg }

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const ImportRecord = types.ImportRecord;
const ImportKind = types.ImportKind;

/// AST를 순회하여 모든 import/export 소스 경로를 추출한다.
/// 반환된 슬라이스의 specifier는 소스 코드를 가리키는 참조이므로
/// 소스가 유효한 동안만 사용 가능.
pub fn extractImports(allocator: std.mem.Allocator, ast: *const Ast) ![]ImportRecord {
    var records: std.ArrayList(ImportRecord) = .empty;

    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .import_declaration => {
                if (tryExtractImportDecl(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_all_declaration => {
                if (tryExtractExportAll(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_named_declaration => {
                if (tryExtractExportNamed(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .import_expression => {
                if (tryExtractDynamicImport(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            else => {},
        }
    }

    return records.toOwnedSlice(allocator);
}

/// import_declaration: extra [specs_start, specs_len, source_node]
/// specs_len == 0이면 side_effect, 아니면 static_import.
fn tryExtractImportDecl(ast: *const Ast, node: Node) ?ImportRecord {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return null;

    const extras = ast.extra_data.items[e .. e + 3];
    const specs_len = extras[1];
    const source_idx: NodeIndex = @enumFromInt(extras[2]);

    const specifier = getStringLiteralText(ast, source_idx) orelse return null;
    const source_node = ast.getNode(source_idx);

    return .{
        .specifier = specifier,
        .kind = if (specs_len == 0) .side_effect else .static_import,
        .span = source_node.span,
    };
}

/// export * from "./foo": binary { left=exported_name, right=source_node }
fn tryExtractExportAll(ast: *const Ast, node: Node) ?ImportRecord {
    const source_idx = node.data.binary.right;
    const specifier = getStringLiteralText(ast, source_idx) orelse return null;
    const source_node = ast.getNode(source_idx);

    return .{
        .specifier = specifier,
        .kind = .re_export,
        .span = source_node.span,
    };
}

/// export { x } from "./foo": extra [declaration, specs_start, specs_len, source]
/// source가 none이면 re-export가 아님 (export { x } — 로컬 export).
fn tryExtractExportNamed(ast: *const Ast, node: Node) ?ImportRecord {
    const e = node.data.extra;
    if (e + 3 >= ast.extra_data.items.len) return null;

    const source_raw = ast.extra_data.items[e + 3];
    const source_idx: NodeIndex = @enumFromInt(source_raw);
    if (source_idx.isNone()) return null;

    const specifier = getStringLiteralText(ast, source_idx) orelse return null;
    const source_node = ast.getNode(source_idx);

    return .{
        .specifier = specifier,
        .kind = .re_export,
        .span = source_node.span,
    };
}

/// import("./foo"): unary { operand=arg }
/// operand가 string_literal이면 추출, 아니면 null (computed → 정적 분석 불가).
fn tryExtractDynamicImport(ast: *const Ast, node: Node) ?ImportRecord {
    const arg_idx = node.data.unary.operand;
    if (arg_idx.isNone()) return null;

    const arg_node = ast.getNode(arg_idx);
    if (arg_node.tag != .string_literal) return null;

    const specifier = stripQuotes(ast.source[arg_node.span.start..arg_node.span.end]) orelse return null;

    return .{
        .specifier = specifier,
        .kind = .dynamic_import,
        .span = arg_node.span,
    };
}

/// string_literal 노드의 텍스트를 따옴표 없이 반환한다.
/// 소스 코드에서 직접 참조하므로 할당 없음 (zero-copy).
fn getStringLiteralText(ast: *const Ast, idx: NodeIndex) ?[]const u8 {
    if (idx.isNone()) return null;
    if (@intFromEnum(idx) >= ast.nodes.items.len) return null;

    const node = ast.getNode(idx);
    if (node.tag != .string_literal) return null;

    return stripQuotes(ast.source[node.span.start..node.span.end]);
}

/// 따옴표(`'`, `"`)를 벗긴다. 최소 2글자 이상이어야 함.
fn stripQuotes(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;
    const first = text[0];
    if (first == '\'' or first == '"') {
        return text[1 .. text.len - 1];
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;

/// 테스트용 헬퍼. Arena로 파싱 후 import 추출.
/// 반환된 records는 testing.allocator 소유 (caller가 free).
/// Arena는 파싱 완료 후 해제되므로 specifier는 source를 직접 참조해야 동작.
fn parseAndExtract(allocator: std.mem.Allocator, source: []const u8) ![]ImportRecord {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();

    // records는 caller의 allocator로 할당 (arena 해제 후에도 유효).
    // specifier는 source 슬라이스를 참조하므로 arena와 무관.
    return extractImports(allocator, &parser.ast);
}

test "side-effect import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import './styles.css';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./styles.css", records[0].specifier);
    try std.testing.expectEqual(ImportKind.side_effect, records[0].kind);
}

test "default import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import foo from './foo';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./foo", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "named import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import { a, b } from './bar';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./bar", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "namespace import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import * as ns from './baz';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./baz", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "export all (re-export)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export * from './all';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./all", records[0].specifier);
    try std.testing.expectEqual(ImportKind.re_export, records[0].kind);
}

test "export named re-export" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export { x, y } from './utils';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./utils", records[0].specifier);
    try std.testing.expectEqual(ImportKind.re_export, records[0].kind);
}

test "export named local (no source) — not extracted" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const x = 1; export { x };");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "export declaration (no source) — not extracted" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export const x = 1;");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "dynamic import (string literal)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const m = import('./lazy');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./lazy", records[0].specifier);
    try std.testing.expectEqual(ImportKind.dynamic_import, records[0].kind);
}

test "dynamic import (computed) — not extracted" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const m = import(foo);");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "multiple imports" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc,
        \\import './a';
        \\import b from './b';
        \\import { c } from './c';
        \\export * from './d';
        \\export { e } from './e';
    );
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 5), records.len);
    try std.testing.expectEqualStrings("./a", records[0].specifier);
    try std.testing.expectEqualStrings("./b", records[1].specifier);
    try std.testing.expectEqualStrings("./c", records[2].specifier);
    try std.testing.expectEqualStrings("./d", records[3].specifier);
    try std.testing.expectEqualStrings("./e", records[4].specifier);
}

test "no imports" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const x = 1;");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "double-quoted import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import foo from \"./foo\";");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./foo", records[0].specifier);
}

test "bare specifier (npm package)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import React from 'react';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("react", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "export all with alias" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export * as ns from './ns';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./ns", records[0].specifier);
    try std.testing.expectEqual(ImportKind.re_export, records[0].kind);
}

test "stripQuotes" {
    try std.testing.expectEqualStrings("foo", stripQuotes("'foo'").?);
    try std.testing.expectEqualStrings("bar", stripQuotes("\"bar\"").?);
    try std.testing.expect(stripQuotes("x") == null);
    try std.testing.expect(stripQuotes("") == null);
}
