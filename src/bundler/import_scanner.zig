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
//!   - require("./foo")                   → require (CJS)
//!   - module.exports = ...              → CJS 신호 (has_module_exports)
//!   - exports.x = ...                   → CJS 신호 (has_exports_dot)
//!
//! AST extra_data 레이아웃:
//!   - import_declaration:         [specs_start, specs_len, source_node]
//!   - export_named_declaration:   [declaration, specs_start, specs_len, source]
//!   - export_all_declaration:     binary { left=exported_name, right=source_node }
//!   - import_expression:          unary { operand=arg }
//!   - call_expression:            extra [callee, args_start, args_len, flags]
//!   - assignment_expression:      binary { left, right, flags }
//!   - static_member_expression:   extra [object, property, flags]

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const ImportRecord = types.ImportRecord;
const ImportKind = types.ImportKind;

/// CJS 감지를 포함한 스캔 결과.
pub const ScanResult = struct {
    /// 추출된 import/export/require 레코드
    records: []ImportRecord,
    /// ESM 구문 (import/export) 존재 여부
    has_esm_syntax: bool,
    /// require("...") 호출 존재 여부
    has_cjs_require: bool,
    /// module.exports = ... 할당 존재 여부
    has_module_exports: bool,
    /// exports.xxx = ... 할당 존재 여부
    has_exports_dot: bool,
};

/// AST를 순회하여 import/export/require를 추출하고 CJS 신호를 감지한다.
/// ESM과 CJS 판별에 필요한 모든 정보를 한 번의 순회로 수집.
pub fn extractImportsWithCjsDetection(allocator: std.mem.Allocator, ast: *const Ast) !ScanResult {
    var records: std.ArrayList(ImportRecord) = .empty;
    var has_esm_syntax = false;
    var has_cjs_require = false;
    var has_module_exports = false;
    var has_exports_dot = false;

    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .import_declaration => {
                has_esm_syntax = true;
                if (tryExtractImportDecl(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_all_declaration => {
                has_esm_syntax = true;
                if (tryExtractExportAll(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_named_declaration => {
                has_esm_syntax = true;
                if (tryExtractExportNamed(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .export_default_declaration => {
                has_esm_syntax = true;
            },
            .import_expression => {
                if (tryExtractDynamicImport(ast, node)) |record| {
                    try records.append(allocator, record);
                }
            },
            .call_expression => {
                if (tryExtractRequire(ast, node)) |record| {
                    has_cjs_require = true;
                    try records.append(allocator, record);
                }
            },
            .assignment_expression => {
                if (!has_module_exports and isModuleExportsAssign(ast, node)) {
                    has_module_exports = true;
                }
                if (!has_exports_dot and isExportsDotAssign(ast, node)) {
                    has_exports_dot = true;
                }
            },
            else => {},
        }
    }

    return .{
        .records = try records.toOwnedSlice(allocator),
        .has_esm_syntax = has_esm_syntax,
        .has_cjs_require = has_cjs_require,
        .has_module_exports = has_module_exports,
        .has_exports_dot = has_exports_dot,
    };
}

/// AST를 순회하여 모든 import/export 소스 경로를 추출한다.
/// 반환된 슬라이스의 specifier는 소스 코드를 가리키는 참조이므로
/// 소스가 유효한 동안만 사용 가능.
/// CJS 감지가 불필요한 경우의 간편 API (binding_scanner 등에서 사용).
pub fn extractImports(allocator: std.mem.Allocator, ast: *const Ast) ![]ImportRecord {
    const result = try extractImportsWithCjsDetection(allocator, ast);
    return result.records;
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

/// require("string_literal") 호출을 감지하여 ImportRecord로 변환.
/// call_expression extra: [callee, args_start, args_len, flags]
/// callee가 identifier_reference "require"이고 인수가 string_literal 1개인 경우만 추출.
fn tryExtractRequire(ast: *const Ast, node: Node) ?ImportRecord {
    const e = node.data.extra;
    // extra에 최소 3개 (callee, args_start, args_len)가 필요
    if (!ast.hasExtra(e, 2)) return null;

    // callee가 identifier_reference "require"인지 확인
    const callee_idx = ast.readExtraNode(e, 0);
    if (callee_idx.isNone()) return null;
    const callee_ni = @intFromEnum(callee_idx);
    if (callee_ni >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[callee_ni];
    if (callee.tag != .identifier_reference) return null;

    const callee_text = ast.getText(callee.span);
    if (!std.mem.eql(u8, callee_text, "require")) return null;

    // 인수가 정확히 1개인지 확인
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1) return null;

    // 인수가 string_literal인지 확인
    const args_start = ast.readExtra(e, 1);
    if (args_start >= ast.extra_data.items.len) return null;
    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);

    const specifier = getStringLiteralText(ast, arg_idx) orelse return null;
    const arg_node = ast.getNode(arg_idx);

    return .{
        .specifier = specifier,
        .kind = .require,
        .span = arg_node.span,
    };
}

/// assignment_expression의 left가 `obj.prop` 형태의 static_member_expression인지 확인하고,
/// object의 identifier 텍스트를 반환한다. property 텍스트도 함께 반환.
fn getAssignMemberParts(ast: *const Ast, node: Node) ?struct { object: []const u8, property: []const u8 } {
    const left_idx = node.data.binary.left;
    if (left_idx.isNone()) return null;
    const left_ni = @intFromEnum(left_idx);
    if (left_ni >= ast.nodes.items.len) return null;
    const left = ast.nodes.items[left_ni];
    if (left.tag != .static_member_expression) return null;

    const me = left.data.extra;
    if (!ast.hasExtra(me, 1)) return null;

    const obj_idx = ast.readExtraNode(me, 0);
    if (obj_idx.isNone()) return null;
    const obj_ni = @intFromEnum(obj_idx);
    if (obj_ni >= ast.nodes.items.len) return null;
    const obj = ast.nodes.items[obj_ni];
    if (obj.tag != .identifier_reference) return null;

    const prop_idx = ast.readExtraNode(me, 1);
    if (prop_idx.isNone()) return null;
    const prop_ni = @intFromEnum(prop_idx);
    if (prop_ni >= ast.nodes.items.len) return null;
    const prop = ast.nodes.items[prop_ni];

    return .{
        .object = ast.getText(obj.span),
        .property = ast.getText(prop.span),
    };
}

/// assignment_expression의 left가 module.exports인지 확인.
fn isModuleExportsAssign(ast: *const Ast, node: Node) bool {
    const parts = getAssignMemberParts(ast, node) orelse return false;
    return std.mem.eql(u8, parts.object, "module") and std.mem.eql(u8, parts.property, "exports");
}

/// assignment_expression의 left가 exports.xxx인지 확인.
fn isExportsDotAssign(ast: *const Ast, node: Node) bool {
    const parts = getAssignMemberParts(ast, node) orelse return false;
    return std.mem.eql(u8, parts.object, "exports");
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
    scanner.is_module = true;
    _ = try parser.parse();

    // records는 caller의 allocator로 할당 (arena 해제 후에도 유효).
    // specifier는 source 슬라이스를 참조하므로 arena와 무관.
    return extractImports(allocator, &parser.ast);
}

/// 테스트용 헬퍼. CJS 감지를 포함한 전체 스캔 결과 반환.
/// CJS 코드는 is_module=false로 파싱해야 정확한 AST가 생성됨.
fn parseAndExtractFull(allocator: std.mem.Allocator, source: []const u8) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    // CJS 테스트를 위해 is_module을 설정하지 않음 (기본값 false)
    _ = try parser.parse();

    return extractImportsWithCjsDetection(allocator, &parser.ast);
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

// ============================================================
// CJS 감지 테스트
// ============================================================

test "CJS: require() call detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "const x = require('./foo');");
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqualStrings("./foo", result.records[0].specifier);
    try std.testing.expectEqual(ImportKind.require, result.records[0].kind);
    try std.testing.expect(result.has_cjs_require);
    try std.testing.expect(!result.has_esm_syntax);
}

test "CJS: require with non-string argument ignored" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "const x = require(variable);");
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 0), result.records.len);
    try std.testing.expect(!result.has_cjs_require);
}

test "CJS: module.exports detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "module.exports = {};");
    defer alloc.free(result.records);

    try std.testing.expect(result.has_module_exports);
    try std.testing.expect(!result.has_esm_syntax);
}

test "CJS: exports.x detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "exports.x = 1;");
    defer alloc.free(result.records);

    try std.testing.expect(result.has_exports_dot);
    try std.testing.expect(!result.has_module_exports);
    try std.testing.expect(!result.has_esm_syntax);
}

test "CJS: ESM syntax flag set" {
    const alloc = std.testing.allocator;
    // is_module=false에서도 ESM 구문 감지 테스트를 위해 parseAndExtract 사용
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, "import x from './foo';");
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const result = try extractImportsWithCjsDetection(alloc, &parser.ast);
    defer alloc.free(result.records);

    try std.testing.expect(result.has_esm_syntax);
    try std.testing.expectEqual(@as(usize, 1), result.records.len);
}

test "CJS: mixed ESM and CJS" {
    const alloc = std.testing.allocator;
    // ESM + CJS 혼용 — is_module=true로 파싱해야 import 구문이 인식됨
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, "import './a'; const b = require('./b');");
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const result = try extractImportsWithCjsDetection(alloc, &parser.ast);
    defer alloc.free(result.records);

    try std.testing.expect(result.has_esm_syntax);
    try std.testing.expect(result.has_cjs_require);
    try std.testing.expectEqual(@as(usize, 2), result.records.len);
}

test "CJS: multiple require calls" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc,
        \\const a = require('./a');
        \\const b = require('./b');
    );
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 2), result.records.len);
    try std.testing.expectEqualStrings("./a", result.records[0].specifier);
    try std.testing.expectEqual(ImportKind.require, result.records[0].kind);
    try std.testing.expectEqualStrings("./b", result.records[1].specifier);
    try std.testing.expectEqual(ImportKind.require, result.records[1].kind);
    try std.testing.expect(result.has_cjs_require);
}
