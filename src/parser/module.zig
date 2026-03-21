//! Import/Export 파싱
//!
//! ESM import/export 선언, import 호출 표현식, import attributes,
//! 모듈 소스 경로 파싱 등 모듈 관련 함수들.
//! oxc의 js/module.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/js/module.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

/// import() / import.source() / import.defer() 호출의 인자를 파싱한다.
/// `(` 를 소비하고, 1~2개 인자를 파싱하고, `)` 를 기대한다.
/// import() 내부에서는 `in` 연산자를 허용 (+In context).
pub fn parseImportCallArgs(self: *Parser, start: u32) ParseError2!NodeIndex {
    try self.expect(.l_paren);
    const saved_ctx = self.enterAllowInContext(true);
    defer self.restoreContext(saved_ctx);
    const arg = try self.parseAssignmentExpression();
    // 두 번째 인자 (import attributes/options) — 있으면 파싱하고 무시
    if (try self.eat(.comma)) {
        if (self.current() != .r_paren) {
            _ = try self.parseAssignmentExpression();
            _ = try self.eat(.comma); // trailing comma
        }
    }
    try self.expect(.r_paren);
    return try self.ast.addNode(.{
        .tag = .import_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
    });
}

pub fn parseImportDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // ECMAScript 15.2: import 선언은 module의 top-level에서만 허용
    if (!self.is_module) {
        try self.addError(self.currentSpan(), "'import' declaration is only allowed in module code");
    } else if (!self.ctx.is_top_level) {
        try self.addError(self.currentSpan(), "'import' declaration must be at the top level");
    }
    try self.advance(); // skip 'import'

    // import defer / import source — Stage 3 proposals
    // defer/source를 스킵하고 나머지는 일반 import로 처리
    var has_phase_modifier = false;
    if (self.current() == .kw_defer or
        (self.current() == .identifier and
            std.mem.eql(u8, self.ast.source[self.currentSpan().start..self.currentSpan().end], "source")))
    {
        has_phase_modifier = true;
        try self.advance(); // skip defer/source
    }

    // import "module" — side-effect import
    // specs_len=0으로 저장하여 specifier가 있는 import와 같은 extra 형식 사용.
    // unary를 쓰면 extern union의 나머지 바이트가 초기화되지 않아
    // codegen에서 .unary.flags를 읽을 때 플랫폼별 UB 발생 (Linux에서 실패).
    if (self.current() == .string_literal) {
        if (has_phase_modifier) {
            try self.addError(self.currentSpan(), "'import defer/source' requires a binding");
        }
        const source_node = try parseModuleSource(self);
        _ = try self.eat(.semicolon);
        const extra_start = try self.ast.addExtra(0); // specs_start (unused)
        _ = try self.ast.addExtra(0); // specs_len = 0 (side-effect)
        _ = try self.ast.addExtra(@intFromEnum(source_node));
        return try self.ast.addNode(.{
            .tag = .import_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // import(...) — dynamic import는 expression. expression statement로 파싱.
    if (self.current() == .l_paren) {
        // import 키워드는 이미 advance()됨. parsePrimaryExpression에 위임하기 위해
        // 수동으로 import expression 생성.
        try self.expect(.l_paren);
        const arg = try self.parseAssignmentExpression();
        try self.expect(.r_paren);
        const import_expr = try self.ast.addNode(.{
            .tag = .import_expression,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
        // 후속 .then() 등의 member/call 체이닝 처리
        _ = try self.eat(.semicolon);
        return try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = import_expr, .flags = 0 } },
        });
    }

    // 스펙ifier 파싱
    const scratch_top = self.saveScratch();

    // default import: import foo from "module"
    var has_default = false;
    if (self.current() == .identifier) {
        const next = try self.peekNextKind();
        if (next == .comma or next == .kw_from) {
            const spec_span = self.currentSpan();
            try self.advance();
            const spec = try self.ast.addNode(.{
                .tag = .import_default_specifier,
                .span = spec_span,
                .data = .{ .string_ref = spec_span },
            });
            try self.scratch.append(self.allocator, spec);
            has_default = true;

            if (try self.eat(.comma)) {
                // import default, { ... } from "module"
                // import default, * as ns from "module"
            } else {
                // import default from "module"
                try self.expect(.kw_from);
                const source_node = try parseModuleSource(self);
                _ = try self.eat(.semicolon);

                const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                self.restoreScratch(scratch_top);
                const extra_start = try self.ast.addExtra(specifiers.start);
                _ = try self.ast.addExtra(specifiers.len);
                _ = try self.ast.addExtra(@intFromEnum(source_node));

                return try self.ast.addNode(.{
                    .tag = .import_declaration,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .extra = extra_start },
                });
            }
        }
    }

    // namespace import: import * as ns from "module"
    if (self.current() == .star) {
        try self.advance(); // skip *
        try self.expect(.kw_as);
        const local_span = self.currentSpan();
        try self.expect(.identifier);
        const spec = try self.ast.addNode(.{
            .tag = .import_namespace_specifier,
            .span = local_span,
            .data = .{ .string_ref = local_span },
        });
        try self.scratch.append(self.allocator, spec);
    }

    // named imports: import { a, b as c } from "module"
    if (self.current() == .l_curly) {
        try self.advance(); // skip {
        while (self.current() != .r_curly and self.current() != .eof) {
            const spec = try parseImportSpecifier(self);
            try self.scratch.append(self.allocator, spec);
            if (!try self.eat(.comma)) break;
        }
        try self.expect(.r_curly);
    }

    try self.expect(.kw_from);
    const source_node = try parseModuleSource(self);
    _ = try self.eat(.semicolon);

    const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(specifiers.start);
    _ = try self.ast.addExtra(specifiers.len);
    _ = try self.ast.addExtra(@intFromEnum(source_node));

    return try self.ast.addNode(.{
        .tag = .import_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseImportSpecifier(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // inline type import: import { type Config } from './config'
    // 주의: import { type } from ... → 'type'이라는 값을 import (modifier 아님)
    // 주의: import { type as alias } from ... → 'type'을 alias로 import (modifier 아님)
    var is_type_only: u16 = 0;
    if (self.current() == .kw_type) {
        const next = try self.peekNextKind();
        // 다음이 식별자/키워드이고 '}' 이나 ',' 이나 'as'가 아니면 type modifier
        if (next != .r_curly and next != .comma and next != .kw_as and
            (next == .identifier or next == .kw_type or next == .kw_default or
            next == .kw_class or next == .kw_function or next == .kw_const or
            next == .kw_enum or next == .kw_interface or next == .kw_let or
            next == .kw_var or next == .kw_void or next == .kw_null or
            next == .kw_true or next == .kw_false or next == .kw_new or
            next == .kw_return or next == .kw_typeof or next == .kw_delete or
            next == .kw_throw or next == .kw_in or next == .kw_instanceof))
        {
            is_type_only = 1;
            try self.advance(); // skip 'type' modifier
        }
    }

    // imported name — ModuleExportName (identifier or string literal)
    const imported = try self.parseModuleExportName();

    // string literal import 시 반드시 `as` 바인딩 필요:
    // import { "☿" as Ami } from ... (OK)
    // import { "☿" } from ... (Error — string cannot be used as binding)
    var local = imported;
    if (try self.eat(.kw_as)) {
        // `as` 뒤는 반드시 BindingIdentifier (string literal 불가)
        local = try self.parseIdentifierName();
    } else if (!imported.isNone() and @intFromEnum(imported) < self.ast.nodes.items.len and
        self.ast.getNode(imported).tag == .string_literal)
    {
        // string literal without `as` — binding 이름이 없으므로 에러
        try self.addError(self.ast.getNode(imported).span, "String literal in import specifier requires 'as' binding");
    }

    return try self.ast.addNode(.{
        .tag = .import_specifier,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = imported, .right = local, .flags = is_type_only } },
    });
}

pub fn parseExportDeclaration(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    // ECMAScript 15.2: export 선언은 module의 top-level에서만 허용
    if (!self.is_module) {
        try self.addError(self.currentSpan(), "'export' declaration is only allowed in module code");
    } else if (!self.ctx.is_top_level) {
        try self.addError(self.currentSpan(), "'export' declaration must be at the top level");
    }
    try self.advance(); // skip 'export'

    // export default
    if (try self.eat(.kw_default)) {
        const decl = switch (self.current()) {
            // export default function / export default function* — 이름 선택적
            .kw_function => blk: {
                const fn_decl = try self.parseFunctionDeclarationDefaultExport();
                // anonymous function declaration은 호출 불가 (IIFE가 아님)
                // export default function() {}() → SyntaxError
                if (self.current() == .l_paren) {
                    try self.addError(self.currentSpan(), "Anonymous function declaration cannot be invoked");
                }
                break :blk fn_decl;
            },
            .kw_class => try self.parseClassDeclaration(),
            else => blk: {
                // export default async function / export default async function* — 이름 선택적
                if (self.current() == .kw_async) {
                    const peek = try self.peekNext();
                    if (peek.kind == .kw_function and !peek.has_newline_before) {
                        const fn_decl = try self.parseAsyncFunctionDeclarationDefaultExport();
                        if (self.current() == .l_paren) {
                            try self.addError(self.currentSpan(), "Anonymous function declaration cannot be invoked");
                        }
                        break :blk fn_decl;
                    }
                }
                const expr = try self.parseAssignmentExpression();
                try self.expectSemicolon();
                break :blk expr;
            },
        };
        return try self.ast.addNode(.{
            .tag = .export_default_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = decl, .flags = 0 } },
        });
    }

    // export * from "module" / export * as ns from "module"
    if (self.current() == .star) {
        try self.advance(); // skip *
        var exported_name = NodeIndex.none;
        if (try self.eat(.kw_as)) {
            exported_name = try self.parseModuleExportName();
        }
        try self.expect(.kw_from);
        const source_node = try parseModuleSource(self);
        try self.expectSemicolon();

        return try self.ast.addNode(.{
            .tag = .export_all_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = exported_name, .right = source_node, .flags = 0 } },
        });
    }

    // export { a, b } / export { a } from "module"
    if (self.current() == .l_curly) {
        try self.advance(); // skip {

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const spec = try parseExportSpecifier(self);
            try self.scratch.append(self.allocator, spec);
            if (!try self.eat(.comma)) break;
        }
        try self.expect(.r_curly);

        // re-export: export { a } from "module"
        var source_node = NodeIndex.none;
        if (try self.eat(.kw_from)) {
            source_node = try parseModuleSource(self);
        }
        try self.expectSemicolon();

        // export NamedExports ; (without `from`) →
        // local 이름에 string literal 사용 불가
        // (ECMAScript: ReferencedBindings에 StringLiteral이 있으면 SyntaxError)
        if (source_node.isNone()) {
            for (self.scratch.items[scratch_top..]) |spec_idx| {
                if (spec_idx.isNone()) continue;
                if (@intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
                const spec_node = self.ast.getNode(spec_idx);
                if (spec_node.tag == .export_specifier) {
                    const local_idx = spec_node.data.binary.left;
                    if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                        const local_node = self.ast.getNode(local_idx);
                        if (local_node.tag == .string_literal) {
                            try self.addError(local_node.span, "String literal cannot be used as local binding in export");
                        }
                    }
                }
            }
        }

        const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(NodeIndex.none), // declaration 없음
            specifiers.start,
            specifiers.len,
            @intFromEnum(source_node),
        });

        return try self.ast.addNode(.{
            .tag = .export_named_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // export var/let/const/function/class
    // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
    const decl = try self.parseStatement();
    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(decl),
        0, // specifiers_start (사용 안 함)
        0, // specifiers_len = 0
        @intFromEnum(NodeIndex.none), // source 없음
    });
    return try self.ast.addNode(.{
        .tag = .export_named_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseExportSpecifier(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    const local = try self.parseModuleExportName();

    var exported = local;
    if (try self.eat(.kw_as)) {
        exported = try self.parseModuleExportName();
    }

    return try self.ast.addNode(.{
        .tag = .export_specifier,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = local, .right = exported, .flags = 0 } },
    });
}

fn parseModuleSource(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    if (self.current() == .string_literal) {
        try self.advance();
        // import attributes: with { type: 'json' } 또는 assert { type: 'json' }
        try skipImportAttributes(self);
        return try self.ast.addNode(.{
            .tag = .string_literal,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    try self.addError(span, "Module source string expected");
    return NodeIndex.none;
}

/// import attributes (with/assert { ... })를 파싱한다.
/// AST에 저장하지 않고 소비만 한다 (트랜스포머에서 필요 시 추가).
/// 중복 키 검사도 수행한다 (ECMAScript: WithClauseToAttributes 중복 에러).
fn skipImportAttributes(self: *Parser) !void {
    // with { ... }: 줄바꿈 허용 (ECMAScript: AttributesKeyword = with)
    // assert { ... }: 줄바꿈 불허 (ECMAScript: [no LineTerminator here] assert)
    const is_with = self.current() == .kw_with;
    const is_assert = self.current() == .kw_assert and !self.scanner.token.has_newline_before;
    if (!is_with and !is_assert) return;

    try self.advance(); // skip with/assert
    if (self.current() == .l_curly) {
        try self.advance(); // skip {

        // 중복 키 검사를 위한 키 수집 (최대 16개, 초과 시 검사 생략)
        var keys: [16][]const u8 = undefined;
        var key_spans: [16]Span = undefined;
        var key_count: usize = 0;

        while (self.current() != .r_curly and self.current() != .eof) {
            // key: identifier 또는 string literal
            const key_span = self.currentSpan();
            const key_text = self.ast.source[key_span.start..key_span.end];
            try self.advance(); // key

            // 중복 키 검사
            if (key_count < 16) {
                // 키 값 결정: string literal은 따옴표 제거 후 escape 해석
                var decoded_buf: [256]u8 = undefined;
                const effective_key = if (key_text.len >= 2 and (key_text[0] == '\'' or key_text[0] == '"'))
                    decodeStringKey(key_text[1 .. key_text.len - 1], &decoded_buf)
                else
                    key_text;

                for (0..key_count) |i| {
                    if (std.mem.eql(u8, keys[i], effective_key)) {
                        try self.addError(key_span, "Duplicate import attribute key");
                        break;
                    }
                }
                keys[key_count] = effective_key;
                key_spans[key_count] = key_span;
                key_count += 1;
            }

            _ = try self.eat(.colon);
            if (self.current() != .r_curly and self.current() != .eof) {
                try self.advance(); // value
            }
            _ = try self.eat(.comma);
        }
        _ = try self.eat(.r_curly);
    }
}

/// import attribute 키의 unicode escape를 해석한다.
/// 예: "typ\u0065" → "type"
/// buf에 결과를 쓰고, escape가 없으면 원본 슬라이스를 반환.
fn decodeStringKey(input: []const u8, buf: *[256]u8) []const u8 {
    // escape가 없으면 원본 그대로 반환 (빠른 경로)
    if (std.mem.indexOf(u8, input, "\\") == null) return input;

    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len and out < 256) {
        if (input[i] == '\\' and i + 1 < input.len) {
            if (input[i + 1] == 'u') {
                // \uHHHH
                if (i + 5 < input.len) {
                    i += 2; // skip \u
                    var codepoint: u21 = 0;
                    var valid = true;
                    for (0..4) |_| {
                        if (i >= input.len) {
                            valid = false;
                            break;
                        }
                        const c = input[i];
                        const digit: u21 = if (c >= '0' and c <= '9')
                            c - '0'
                        else if (c >= 'a' and c <= 'f')
                            c - 'a' + 10
                        else if (c >= 'A' and c <= 'F')
                            c - 'A' + 10
                        else {
                            valid = false;
                            break;
                        };
                        codepoint = codepoint * 16 + digit;
                        i += 1;
                    }
                    if (valid and codepoint < 128 and out < 256) {
                        buf[out] = @intCast(codepoint);
                        out += 1;
                    }
                    continue;
                }
            }
            // 기타 escape: 그대로 복사
            if (out < 256) {
                buf[out] = input[i + 1];
                out += 1;
            }
            i += 2;
        } else {
            if (out < 256) {
                buf[out] = input[i];
                out += 1;
            }
            i += 1;
        }
    }
    return buf[0..out];
}
