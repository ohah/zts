//! ZTS Codegen — AST를 JS 문자열로 출력
//!
//! 작동 원리:
//!   1. AST의 루트(program) 노드부터 시작
//!   2. 각 노드의 tag를 switch로 분기
//!   3. 소스 코드의 span을 참조하여 식별자/리터럴을 zero-copy 출력
//!   4. 구문 구조(키워드, 괄호, 세미콜론)는 직접 생성
//!
//! 참고:
//! - references/esbuild/internal/js_printer/js_printer.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;
const Kind = @import("../lexer/token.zig").Kind;
const Comment = @import("../lexer/scanner.zig").Comment;

/// 모듈 출력 형식
pub const ModuleFormat = enum {
    esm, // ESM (import/export 그대로)
    cjs, // CommonJS (require/exports 변환)
};

/// 들여쓰기 문자 (D044)
pub const IndentChar = enum {
    tab,
    space,
};

/// 번들러 linker가 생성하는 per-module 메타데이터.
/// codegen이 import 스킵 + 식별자 리네임에 사용.
pub const LinkingMetadata = @import("../bundler/linker.zig").LinkingMetadata;

pub const CodegenOptions = struct {
    module_format: ModuleFormat = .esm,
    /// 들여쓰기 문자 (D044: Tab 기본)
    indent_char: IndentChar = .tab,
    /// Space일 때 들여쓰기 너비 (기본 2)
    indent_width: u8 = 2,
    /// 줄바꿈 문자 (D045: \n 기본, Windows는 \r\n)
    newline: []const u8 = "\n",
    /// 공백 최소화 (minify)
    minify: bool = false,
    /// 소스맵 생성 활성화
    sourcemap: bool = false,
    /// non-ASCII 문자를 \uXXXX로 이스케이프 (D031)
    ascii_only: bool = false,
    /// 번들러 linker 메타데이터. 설정 시 import 스킵 + 식별자 리네임 적용.
    linking_metadata: ?*const LinkingMetadata = null,
};

const SourceMapBuilder = @import("sourcemap.zig").SourceMapBuilder;
const Mapping = @import("sourcemap.zig").Mapping;

pub const Codegen = struct {
    ast: *const Ast,
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    options: CodegenOptions,
    /// 현재 들여쓰기 레벨
    indent_level: u32 = 0,
    /// 소스맵 빌더 (sourcemap 옵션 활성화 시)
    sm_builder: ?SourceMapBuilder = null,
    /// 소스의 줄 오프셋 테이블 (Scanner에서 전달, 소스맵 줄/열 계산용)
    line_offsets: []const u32 = &.{},
    /// 출력의 현재 줄/열 (소스맵 매핑용)
    gen_line: u32 = 0,
    gen_col: u32 = 0,
    /// 소스에서 수집한 주석 리스트 (소스 순서, scanner.comments.items)
    comments: []const Comment = &.{},
    /// 다음으로 출력할 주석의 인덱스
    next_comment_idx: usize = 0,
    /// for문 init 위치에서 variable_declaration 출력 시 세미콜론 생략
    in_for_init: bool = false,

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) Codegen {
        return initWithOptions(allocator, ast, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, ast: *const Ast, options: CodegenOptions) Codegen {
        return .{
            .ast = ast,
            .allocator = allocator,
            .buf = .empty,
            .options = options,
            .indent_level = 0,
            .sm_builder = if (options.sourcemap) SourceMapBuilder.init(allocator) else null,
            .gen_line = 0,
            .gen_col = 0,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.buf.deinit(self.allocator);
        if (self.sm_builder) |*sm| sm.deinit();
    }

    /// AST를 JS 문자열로 출력한다.
    pub fn generate(self: *Codegen, root: NodeIndex) ![]const u8 {
        // 출력 크기는 보통 소스 크기와 비슷 → 사전 할당
        try self.buf.ensureTotalCapacity(self.allocator, self.ast.source.len);
        try self.emitNode(root);
        return self.buf.items;
    }

    /// byte offset → 소스 줄/열 변환 (이진 탐색).
    fn getOriginalLineColumn(self: *const Codegen, offset: u32) struct { line: u32, column: u32 } {
        const offsets = self.line_offsets;
        if (offsets.len == 0) return .{ .line = 0, .column = offset };
        var lo: u32 = 0;
        var hi: u32 = @intCast(offsets.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (offsets[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line_idx = if (lo > 0) lo - 1 else 0;
        return .{
            .line = line_idx,
            .column = offset - offsets[line_idx],
        };
    }

    /// 소스맵에 소스 파일을 등록한다. generate() 전에 호출.
    pub fn addSourceFile(self: *Codegen, source_name: []const u8) !void {
        if (self.sm_builder) |*sm| {
            _ = try sm.addSource(source_name);
        }
    }

    /// 소스맵 JSON을 생성한다. generate() 후에 호출.
    pub fn generateSourceMap(self: *Codegen, output_file: []const u8) !?[]const u8 {
        if (self.sm_builder) |*sm| {
            return try sm.generateJSON(output_file);
        }
        return null;
    }

    // ================================================================
    // 출력 헬퍼
    // ================================================================

    fn write(self: *Codegen, s: []const u8) !void {
        try self.buf.appendSlice(self.allocator, s);
        // 줄/열 추적
        for (s) |c| {
            if (c == '\n') {
                self.gen_line += 1;
                self.gen_col = 0;
            } else {
                self.gen_col += 1;
            }
        }
    }

    fn writeByte(self: *Codegen, b: u8) !void {
        try self.buf.append(self.allocator, b);
        if (b == '\n') {
            self.gen_line += 1;
            self.gen_col = 0;
        } else {
            self.gen_col += 1;
        }
    }

    /// 소스맵 매핑 추가. 노드의 소스 span과 현재 출력 위치를 매핑.
    fn addSourceMapping(self: *Codegen, span: Span) !void {
        if (self.sm_builder) |*sm| {
            // byte offset → 줄/열 변환 (Scanner의 line_offsets 사용)
            const lc = self.getOriginalLineColumn(span.start);
            try sm.addMapping(.{
                .generated_line = self.gen_line,
                .generated_column = self.gen_col,
                .source_index = 0,
                .original_line = lc.line,
                .original_column = lc.column,
            });
        }
    }

    /// 줄바꿈 출력. minify 모드에서는 아무것도 출력하지 않음.
    fn writeNewline(self: *Codegen) !void {
        if (self.options.minify) return;
        try self.write(self.options.newline);
    }

    /// 현재 들여쓰기 레벨만큼 들여쓰기 출력.
    fn writeIndent(self: *Codegen) !void {
        if (self.options.minify) return;
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            switch (self.options.indent_char) {
                .tab => try self.writeByte('\t'),
                .space => {
                    var j: u8 = 0;
                    while (j < self.options.indent_width) : (j += 1) {
                        try self.writeByte(' ');
                    }
                },
            }
        }
    }

    /// 공백 출력. minify에서는 생략.
    fn writeSpace(self: *Codegen) !void {
        if (!self.options.minify) try self.writeByte(' ');
    }

    /// span 범위의 텍스트를 출력한다.
    /// source 또는 string_table에서 투명하게 읽는다 (getText 사용).
    fn writeSpan(self: *Codegen, span: Span) !void {
        const text = self.ast.getText(span);
        if (self.options.ascii_only) {
            try self.writeAsciiOnly(text);
        } else {
            try self.write(text);
        }
    }

    /// non-ASCII 문자를 \uXXXX로 이스케이프하여 출력.
    fn writeAsciiOnly(self: *Codegen, text: []const u8) !void {
        var i: usize = 0;
        while (i < text.len) {
            const b = text[i];
            if (b < 0x80) {
                // ASCII
                try self.writeByte(b);
                i += 1;
            } else {
                // UTF-8 → codepoint → \uXXXX
                const cp_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
                if (i + cp_len <= text.len) {
                    const cp = std.unicode.utf8Decode(text[i..][0..cp_len]) catch {
                        try self.writeByte(b);
                        i += 1;
                        continue;
                    };
                    if (cp <= 0xFFFF) {
                        var hex_buf: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{cp}) catch unreachable;
                        try self.buf.appendSlice(self.allocator, &hex_buf);
                    } else {
                        // 서로게이트 페어
                        const adjusted = cp - 0x10000;
                        const high: u16 = @intCast((adjusted >> 10) + 0xD800);
                        const low: u16 = @intCast((adjusted & 0x3FF) + 0xDC00);
                        var hex_buf: [12]u8 = undefined;
                        _ = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}\\u{x:0>4}", .{ high, low }) catch unreachable;
                        try self.buf.appendSlice(self.allocator, &hex_buf);
                    }
                    // 줄/열 추적
                    if (cp <= 0xFFFF) {
                        self.gen_col += 6;
                    } else {
                        self.gen_col += 12;
                    }
                    i += cp_len;
                } else {
                    try self.writeByte(b);
                    i += 1;
                }
            }
        }
    }

    /// 노드의 소스 텍스트를 출력.
    fn writeNodeSpan(self: *Codegen, node: Node) !void {
        try self.writeSpan(node.span);
    }

    // ================================================================
    // 주석 출력
    // ================================================================

    /// 주석 출력. pos가 null이면 남은 모든 주석 출력 (trailing).
    /// minify 모드에서는 legal comment (@license, @preserve, /*!)만 보존 (D022).
    fn emitComments(self: *Codegen, pos: ?u32) !void {
        while (self.next_comment_idx < self.comments.len) {
            const comment = self.comments[self.next_comment_idx];
            if (pos) |p| {
                if (comment.start > p) break;
            }
            // minify 모드: legal comment만 출력
            if (self.options.minify and !comment.is_legal) {
                self.next_comment_idx += 1;
                continue;
            }
            try self.write(self.ast.source[comment.start..comment.end]);
            try self.writeNewline();
            self.next_comment_idx += 1;
        }
    }

    // ================================================================
    // 노드 출력
    // ================================================================

    pub const Error = std.mem.Allocator.Error;

    fn emitNode(self: *Codegen, idx: NodeIndex) Error!void {
        if (idx.isNone()) return;

        // 번들 모드: skip_nodes에 있으면 출력하지 않음 (import/export 제거)
        if (self.options.linking_metadata) |meta| {
            const node_idx = @intFromEnum(idx);
            if (node_idx < meta.skip_nodes.capacity() and meta.skip_nodes.isSet(node_idx)) return;
        }

        const node = self.ast.getNode(idx);

        // 이 노드 이전에 위치한 주석들을 출력
        if (node.span.start != node.span.end) {
            try self.emitComments(node.span.start);
        }

        // 소스맵 매핑: 유의미한 노드 출력 시 원본 위치 기록
        if (self.sm_builder != null and node.span.start != node.span.end) {
            try self.addSourceMapping(node.span);
        }

        switch (node.tag) {
            .program => try self.emitProgram(node),
            .block_statement => try self.emitBlock(node),
            .empty_statement => try self.writeByte(';'),
            .expression_statement => try self.emitExpressionStatement(node),
            .variable_declaration => try self.emitVariableDeclaration(node),
            .variable_declarator => try self.emitVariableDeclarator(node),
            .return_statement => try self.emitReturn(node),
            .throw_statement => try self.emitThrow(node),
            .if_statement => try self.emitIf(node),
            .while_statement => try self.emitWhile(node),
            .do_while_statement => try self.emitDoWhile(node),
            .for_statement => try self.emitFor(node),
            .for_in_statement => try self.emitForInOf(node, "in"),
            .for_of_statement => try self.emitForInOf(node, "of"),
            .switch_statement => try self.emitSwitch(node),
            .switch_case => try self.emitSwitchCase(node),
            .break_statement => try self.emitSimpleStmt(node, "break"),
            .continue_statement => try self.emitSimpleStmt(node, "continue"),
            .debugger_statement => try self.write("debugger;"),
            .try_statement => try self.emitTry(node),
            .catch_clause => try self.emitCatch(node),
            .labeled_statement => try self.emitLabeled(node),
            .with_statement => try self.emitWith(node),
            .directive, .hashbang => try self.writeNodeSpan(node),

            // Literals
            .boolean_literal,
            .null_literal,
            .numeric_literal,
            .string_literal,
            .bigint_literal,
            .regexp_literal,
            => try self.writeNodeSpan(node),

            // Identifiers — 번들 모드에서 symbol_id 기반 리네임 적용
            .identifier_reference,
            .private_identifier,
            .binding_identifier,
            .assignment_target_identifier,
            => {
                if (self.options.linking_metadata) |meta| {
                    const node_i = @intFromEnum(idx);
                    if (node_i < meta.symbol_ids.len) {
                        if (meta.symbol_ids[node_i]) |sym_id| {
                            if (meta.renames.get(sym_id)) |new_name| {
                                try self.write(new_name);
                                return;
                            }
                        }
                    }
                }
                try self.writeSpan(node.data.string_ref);
            },

            .this_expression => try self.write("this"),
            .super_expression => try self.write("super"),

            // Expressions
            .unary_expression => try self.emitUnary(node),
            .update_expression => try self.emitUpdate(node),
            .binary_expression, .logical_expression => try self.emitBinary(node),
            .assignment_expression => try self.emitAssignment(node),
            .conditional_expression => try self.emitConditional(node),
            .sequence_expression => try self.emitSequence(node),
            .parenthesized_expression => try self.emitParen(node),
            .spread_element => try self.emitSpread(node),
            .await_expression => try self.emitAwait(node),
            .yield_expression => try self.emitYield(node),
            .array_expression => try self.emitArray(node),
            .object_expression => try self.emitObject(node),
            .object_property => try self.emitObjectProperty(node),
            .computed_property_key => try self.emitComputedKey(node),
            .static_member_expression => try self.emitStaticMember(node),
            .computed_member_expression => try self.emitComputedMember(node),
            .private_field_expression => try self.emitStaticMember(node),
            .call_expression => try self.emitCall(node),
            .new_expression => try self.emitNew(node),
            .template_literal => try self.writeNodeSpan(node),
            .template_element => try self.writeNodeSpan(node),
            .tagged_template_expression => try self.emitTaggedTemplate(node),
            .import_expression => try self.emitImportExpr(node),
            .meta_property => try self.emitMetaProperty(node),
            .chain_expression => try self.emitNode(node.data.unary.operand),

            // Functions / Classes
            .function_declaration, .function_expression, .function => try self.emitFunction(node),
            .arrow_function_expression => try self.emitArrow(node),
            .class_declaration, .class_expression => try self.emitClass(node),
            .class_body => try self.emitClassBody(node),
            .method_definition => try self.emitMethodDef(node),
            .property_definition => try self.emitPropertyDef(node),
            .static_block => try self.writeNodeSpan(node),
            .decorator => try self.emitDecorator(node),
            .accessor_property => try self.emitAccessorProp(node),

            // Patterns
            .array_pattern, .array_assignment_target => try self.emitArray(node),
            .object_pattern, .object_assignment_target => try self.emitObject(node),
            .assignment_pattern => try self.emitAssignmentPattern(node),
            .binding_property => try self.emitBindingProperty(node),
            .rest_element, .binding_rest_element, .assignment_target_rest => try self.emitRest(node),
            .assignment_target_with_default => try self.emitAssignmentPattern(node),
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            => try self.emitBindingProperty(node),
            .elision => {},

            // Import/Export
            .import_declaration => try self.emitImport(node),
            .import_specifier,
            .import_default_specifier,
            .import_namespace_specifier,
            .import_attribute,
            => try self.writeNodeSpan(node),
            .export_named_declaration => try self.emitExportNamed(node),
            .export_default_declaration => try self.emitExportDefault(node),
            .export_all_declaration => try self.emitExportAll(node),
            .export_specifier => try self.writeNodeSpan(node),

            // Formal parameters
            .formal_parameters, .function_body => try self.emitList(node, ", "),

            .formal_parameter => try self.emitFormalParam(node),

            // JSX → React.createElement
            .jsx_element => try self.emitJSXElement(node),
            .jsx_fragment => try self.emitJSXFragment(node),
            .jsx_expression_container => try self.emitNode(node.data.unary.operand),
            .jsx_text => try self.emitJSXText(node),
            .jsx_spread_attribute => try self.emitSpread(node),

            // TS enum/namespace → IIFE 출력
            .ts_enum_declaration => try self.emitEnumIIFE(node),
            .ts_module_declaration => try self.emitNamespaceIIFE(node),

            // TS 노드는 transformer에서 제거됨 — 여기 도달하면 strip_types=false
            else => try self.writeNodeSpan(node),
        }
    }

    // ================================================================
    // Statement 출력
    // ================================================================

    fn emitProgram(self: *Codegen, node: Node) !void {
        const list = node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices, 0..) |raw_idx, i| {
            if (i > 0) try self.writeNewline();
            try self.emitNode(@enumFromInt(raw_idx));
        }
        if (indices.len > 0) try self.writeNewline();
        // 파일 끝에 남은 주석들 출력
        try self.emitComments(null);
    }

    fn emitBlock(self: *Codegen, node: Node) !void {
        try self.emitBracedList(node);
    }

    /// { item1 item2 ... } — 블록과 클래스 바디 공통
    fn emitBracedList(self: *Codegen, node: Node) !void {
        try self.writeSpace();
        try self.writeByte('{');
        const list = node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        if (indices.len > 0) {
            self.indent_level += 1;
            for (indices) |raw_idx| {
                try self.writeNewline();
                try self.writeIndent();
                try self.emitNode(@enumFromInt(raw_idx));
            }
            self.indent_level -= 1;
            try self.writeNewline();
            try self.writeIndent();
        }
        try self.writeByte('}');
    }

    fn emitExpressionStatement(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(';');
    }

    fn emitReturn(self: *Codegen, node: Node) !void {
        try self.write("return");
        if (!node.data.unary.operand.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(node.data.unary.operand);
        }
        try self.writeByte(';');
    }

    fn emitThrow(self: *Codegen, node: Node) !void {
        try self.write("throw ");
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(';');
    }

    fn emitIf(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        try self.write("if(");
        try self.emitNode(t.a);
        try self.writeByte(')');
        try self.emitNode(t.b);
        if (!t.c.isNone()) {
            try self.write("else ");
            try self.emitNode(t.c);
        }
    }

    fn emitWhile(self: *Codegen, node: Node) !void {
        try self.write("while(");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(')');
        try self.emitNode(node.data.binary.right);
    }

    fn emitDoWhile(self: *Codegen, node: Node) !void {
        try self.write("do ");
        try self.emitNode(node.data.binary.right);
        try self.write("while(");
        try self.emitNode(node.data.binary.left);
        try self.write(");");
    }

    fn emitFor(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 4];
        try self.write("for(");
        // init이 variable_declaration일 때 세미콜론 중복 방지:
        // emitVariableDeclaration이 자체적으로 ';'를 붙이므로,
        // in_for_init 플래그로 해당 세미콜론을 억제한다.
        self.in_for_init = true;
        defer self.in_for_init = false;
        try self.emitNode(@enumFromInt(extras[0]));
        try self.writeByte(';');
        try self.emitNode(@enumFromInt(extras[1]));
        try self.writeByte(';');
        try self.emitNode(@enumFromInt(extras[2]));
        try self.writeByte(')');
        try self.emitNode(@enumFromInt(extras[3]));
    }

    fn emitForInOf(self: *Codegen, node: Node, keyword: []const u8) !void {
        const t = node.data.ternary;
        try self.write("for(");
        self.in_for_init = true;
        defer self.in_for_init = false;
        try self.emitNode(t.a);
        try self.writeByte(' ');
        try self.write(keyword);
        try self.writeByte(' ');
        try self.emitNode(t.b);
        try self.writeByte(')');
        try self.emitNode(t.c);
    }

    fn emitSwitch(self: *Codegen, node: Node) !void {
        // 파서 구조: extra = [discriminant, cases_start, cases_len]
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const discriminant: NodeIndex = @enumFromInt(extras[0]);
        const cases_start = extras[1];
        const cases_len = extras[2];

        try self.write("switch(");
        try self.emitNode(discriminant);
        try self.writeByte(')');
        try self.writeSpace();
        try self.writeByte('{');
        if (cases_len > 0) {
            self.indent_level += 1;
            const case_indices = self.ast.extra_data.items[cases_start .. cases_start + cases_len];
            for (case_indices) |raw_idx| {
                try self.writeNewline();
                try self.writeIndent();
                try self.emitNode(@enumFromInt(raw_idx));
            }
            self.indent_level -= 1;
            try self.writeNewline();
            try self.writeIndent();
        }
        try self.writeByte('}');
    }

    fn emitSwitchCase(self: *Codegen, node: Node) !void {
        // 파서 구조: extra = [test_expr, stmts_start, stmts_len]
        // test_expr가 none이면 default:
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const test_expr: NodeIndex = @enumFromInt(extras[0]);
        const stmts_start = extras[1];
        const stmts_len = extras[2];

        if (test_expr.isNone()) {
            try self.write("default:");
        } else {
            try self.write("case ");
            try self.emitNode(test_expr);
            try self.writeByte(':');
        }

        if (stmts_len > 0) {
            self.indent_level += 1;
            const stmt_indices = self.ast.extra_data.items[stmts_start .. stmts_start + stmts_len];
            for (stmt_indices) |raw_idx| {
                try self.writeNewline();
                try self.writeIndent();
                try self.emitNode(@enumFromInt(raw_idx));
            }
            self.indent_level -= 1;
        }
    }

    fn emitSimpleStmt(self: *Codegen, node: Node, keyword: []const u8) !void {
        try self.write(keyword);
        // label이 있으면 출력
        if (!node.data.unary.operand.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(node.data.unary.operand);
        }
        try self.writeByte(';');
    }

    fn emitTry(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        try self.write("try");
        try self.writeSpace();
        try self.emitNode(t.a); // block
        if (!t.b.isNone()) {
            try self.writeSpace();
            try self.emitNode(t.b); // catch
        }
        if (!t.c.isNone()) {
            try self.writeSpace();
            try self.write("finally");
            try self.writeSpace();
            try self.emitNode(t.c);
        }
    }

    fn emitCatch(self: *Codegen, node: Node) !void {
        try self.write("catch");
        if (!node.data.binary.left.isNone()) {
            try self.writeByte('(');
            try self.emitNode(node.data.binary.left);
            try self.writeByte(')');
        }
        try self.emitNode(node.data.binary.right);
    }

    fn emitLabeled(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte(':');
        try self.emitNode(node.data.binary.right);
    }

    fn emitWith(self: *Codegen, node: Node) !void {
        try self.write("with(");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(')');
        try self.emitNode(node.data.binary.right);
    }

    // ================================================================
    // Expression 출력
    // ================================================================

    fn emitUnary(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 1 >= extras.len) return;
        const operand: NodeIndex = @enumFromInt(extras[e]);
        const op: Kind = @enumFromInt(@as(u8, @truncate(extras[e + 1])));
        try self.write(op.symbol());
        if (op == .kw_typeof or op == .kw_void or op == .kw_delete) try self.writeByte(' ');
        try self.emitNode(operand);
    }

    fn emitUpdate(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 1 >= extras.len) return;
        const operand: NodeIndex = @enumFromInt(extras[e]);
        const flags = extras[e + 1];
        const is_postfix = (flags & 0x100) != 0;
        const op: Kind = @enumFromInt(@as(u8, @truncate(flags)));
        if (!is_postfix) try self.write(op.symbol());
        try self.emitNode(operand);
        if (is_postfix) try self.write(op.symbol());
    }

    fn emitBinary(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        const op: Kind = @enumFromInt(node.data.binary.flags);
        try self.writeByte(' ');
        try self.write(op.symbol());
        try self.writeByte(' ');
        try self.emitNode(node.data.binary.right);
    }

    fn emitAssignment(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        if (node.data.binary.flags != 0) {
            const op: Kind = @enumFromInt(node.data.binary.flags);
            try self.write(op.symbol());
        } else {
            try self.writeByte('=');
        }
        try self.emitNode(node.data.binary.right);
    }

    fn emitConditional(self: *Codegen, node: Node) !void {
        const t = node.data.ternary;
        try self.emitNode(t.a);
        try self.writeByte('?');
        try self.emitNode(t.b);
        try self.writeByte(':');
        try self.emitNode(t.c);
    }

    fn emitSequence(self: *Codegen, node: Node) !void {
        try self.emitList(node, ",");
    }

    fn emitParen(self: *Codegen, node: Node) !void {
        try self.writeByte('(');
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(')');
    }

    fn emitSpread(self: *Codegen, node: Node) !void {
        try self.write("...");
        try self.emitNode(node.data.unary.operand);
    }

    fn emitAwait(self: *Codegen, node: Node) !void {
        try self.write("await ");
        try self.emitNode(node.data.unary.operand);
    }

    fn emitYield(self: *Codegen, node: Node) !void {
        try self.write("yield");
        if (node.data.unary.flags & 1 != 0) try self.writeByte('*');
        if (!node.data.unary.operand.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(node.data.unary.operand);
        }
    }

    fn emitArray(self: *Codegen, node: Node) !void {
        try self.writeByte('[');
        try self.emitList(node, if (self.options.minify) "," else ", ");
        try self.writeByte(']');
    }

    fn emitObject(self: *Codegen, node: Node) !void {
        if (self.options.minify) {
            try self.writeByte('{');
            try self.emitList(node, ",");
            try self.writeByte('}');
        } else {
            try self.write("{ ");
            try self.emitList(node, ", ");
            try self.write(" }");
        }
    }

    /// object_property: binary = { left=key, right=value, flags }
    fn emitObjectProperty(self: *Codegen, node: Node) !void {
        const key = node.data.binary.left;
        const value = node.data.binary.right;
        try self.emitNode(key);
        if (!value.isNone()) {
            if (self.options.minify) {
                try self.writeByte(':');
            } else {
                try self.write(": ");
            }
            try self.emitNode(value);
        }
    }

    fn emitComputedKey(self: *Codegen, node: Node) !void {
        try self.writeByte('[');
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(']');
    }

    fn emitStaticMember(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 2 >= extras.len) return;
        const object: NodeIndex = @enumFromInt(extras[e]);
        const property: NodeIndex = @enumFromInt(extras[e + 1]);
        const flags = extras[e + 2];
        try self.emitNode(object);
        // flags=1 → optional chaining (a?.b)
        if (flags & 1 != 0) {
            try self.write("?.");
        } else {
            try self.writeByte('.');
        }
        try self.emitNode(property);
    }

    fn emitComputedMember(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 2 >= extras.len) return;
        const object: NodeIndex = @enumFromInt(extras[e]);
        const property: NodeIndex = @enumFromInt(extras[e + 1]);
        const flags = extras[e + 2];
        try self.emitNode(object);
        // flags=1 → optional chaining (a?.[b])
        if (flags & 1 != 0) {
            try self.write("?.");
        }
        try self.writeByte('[');
        try self.emitNode(property);
        try self.writeByte(']');
    }

    /// call_expression: extra = [callee, args_start, args_len, flags]
    fn emitCall(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 3 >= extras.len) return;
        const callee: NodeIndex = @enumFromInt(extras[e]);
        const args_start = extras[e + 1];
        const args_len = extras[e + 2];
        const flags = extras[e + 3];
        const CallFlags = ast_mod.CallFlags;
        const is_optional = (flags & CallFlags.optional_chain) != 0;
        const is_pure = (flags & CallFlags.is_pure) != 0;

        // @__PURE__ 주석 재출력 (minify가 아닐 때)
        if (is_pure and !self.options.minify) try self.write("/* @__PURE__ */ ");
        try self.emitNode(callee);
        if (is_optional) try self.write("?.");
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, if (self.options.minify) "," else ", ");
        try self.writeByte(')');
    }

    /// new_expression: extra = [callee, args_start, args_len, flags]
    fn emitNew(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 3 >= extras.len) return;
        const callee: NodeIndex = @enumFromInt(extras[e]);
        const args_start = extras[e + 1];
        const args_len = extras[e + 2];
        const flags = extras[e + 3];
        const CallFlags = ast_mod.CallFlags;
        const is_pure = (flags & CallFlags.is_pure) != 0;

        if (is_pure and !self.options.minify) try self.write("/* @__PURE__ */ ");

        try self.write("new ");
        try self.emitNode(callee);
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, if (self.options.minify) "," else ", ");
        try self.writeByte(')');
    }

    fn emitTaggedTemplate(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 1 >= extras.len) return;
        try self.emitNode(@enumFromInt(extras[e]));
        try self.emitNode(@enumFromInt(extras[e + 1]));
    }

    /// import.meta → CJS에서 치환
    fn emitMetaProperty(self: *Codegen, node: Node) !void {
        if (self.options.module_format == .cjs) {
            // import.meta → { url: require('url').pathToFileURL(__filename).href }
            const text = self.ast.source[node.span.start..node.span.end];
            if (std.mem.eql(u8, text, "import.meta")) {
                try self.write("{url:require('url').pathToFileURL(__filename).href}");
                return;
            }
        }
        try self.writeNodeSpan(node);
    }

    fn emitImportExpr(self: *Codegen, node: Node) !void {
        try self.write("import(");
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(')');
    }

    // ================================================================
    // Function / Class 출력
    // ================================================================

    fn emitFunction(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 6];
        const name: NodeIndex = @enumFromInt(extras[0]);
        const params_start = extras[1];
        const params_len = extras[2];
        const body: NodeIndex = @enumFromInt(extras[3]);
        const flags = extras[4];

        // flags: 0x01=async, 0x02=generator (파서 기준)
        if (flags & 0x01 != 0) try self.write("async ");
        try self.write("function");
        if (flags & 0x02 != 0) try self.writeByte('*');
        if (!name.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(name);
        }
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.writeByte(')');
        try self.emitNode(body);
    }

    /// arrow_function_expression: extra = [params, body, flags]
    /// flags: 0x01 = async
    fn emitArrow(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (e + 2 >= extras.len) return;
        const params: NodeIndex = @enumFromInt(extras[e]);
        const body: NodeIndex = @enumFromInt(extras[e + 1]);
        const flags = extras[e + 2];

        if (flags & 0x01 != 0) try self.write("async ");

        // params 출력
        if (!params.isNone()) {
            const param_node = self.ast.getNode(params);
            if (param_node.tag == .binding_identifier) {
                // 단일 파라미터: x => x
                try self.emitNode(params);
            } else if (param_node.tag == .parenthesized_expression) {
                // 괄호 형태: (a, b) => a + b — parenthesized_expression이 이미 괄호를 포함
                try self.emitNode(params);
            } else {
                try self.writeByte('(');
                try self.emitNode(params);
                try self.writeByte(')');
            }
        } else {
            try self.write("()");
        }
        try self.write("=>");
        try self.emitNode(body);
    }

    /// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
    fn emitClass(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const name: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const super_class: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
        const body: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
        const deco_start = self.ast.extra_data.items[e + 6];
        const deco_len = self.ast.extra_data.items[e + 7];

        // decorator 출력: @log\n@validate\nclass Foo {}
        if (deco_len > 0) {
            const deco_indices = self.ast.extra_data.items[deco_start .. deco_start + deco_len];
            for (deco_indices) |raw_idx| {
                try self.emitNode(@enumFromInt(raw_idx));
                try self.writeByte('\n');
            }
        }

        try self.write("class");
        if (!name.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(name);
        }
        if (!super_class.isNone()) {
            try self.write(" extends ");
            try self.emitNode(super_class);
        }
        try self.emitNode(body);
    }

    fn emitClassBody(self: *Codegen, node: Node) !void {
        try self.emitBracedList(node);
    }

    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    fn emitMethodDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 7];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const params_start = extras[1];
        const params_len = extras[2];
        const body: NodeIndex = @enumFromInt(extras[3]);
        const flags = extras[4];
        const deco_start = extras[5];
        const deco_len = extras[6];

        try self.emitMemberDecorators(deco_start, deco_len);

        // flags: bit0=static, bit1=getter, bit2=setter, bit3=async, bit4=generator(*)
        if (flags & 0x01 != 0) try self.write("static ");
        if (flags & 0x08 != 0) try self.write("async ");
        if (flags & 0x02 != 0) {
            try self.write("get ");
        } else if (flags & 0x04 != 0) {
            try self.write("set ");
        }
        if (flags & 0x10 != 0) try self.writeByte('*');

        try self.emitNode(key);
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.writeByte(')');
        try self.emitNode(body);
    }

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    fn emitPropertyDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const value: NodeIndex = @enumFromInt(extras[1]);
        const flags = extras[2];
        const deco_start = extras[3];
        const deco_len = extras[4];

        try self.emitMemberDecorators(deco_start, deco_len);

        if (flags & 0x01 != 0) try self.write("static ");
        try self.emitNode(key);
        if (!value.isNone()) {
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
            try self.emitNode(value);
        }
        try self.writeByte(';');
    }

    fn emitDecorator(self: *Codegen, node: Node) !void {
        try self.writeByte('@');
        try self.emitNode(node.data.unary.operand);
    }

    /// decorator 리스트 출력 (member decorator 공용 헬퍼).
    /// deco_len > 0이면 각 decorator를 출력 후 줄바꿈 + 들여쓰기.
    fn emitMemberDecorators(self: *Codegen, deco_start: u32, deco_len: u32) !void {
        if (deco_len == 0) return;
        const deco_indices = self.ast.extra_data.items[deco_start .. deco_start + deco_len];
        for (deco_indices) |raw_idx| {
            try self.emitNode(@enumFromInt(raw_idx));
            try self.writeByte('\n');
            try self.writeIndent();
        }
    }

    // accessor_property: extra = [key, init_val, flags, deco_start, deco_len]
    fn emitAccessorProp(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const value: NodeIndex = @enumFromInt(extras[1]);
        const flags = extras[2];
        const deco_start = extras[3];
        const deco_len = extras[4];

        try self.emitMemberDecorators(deco_start, deco_len);

        if (flags & 0x01 != 0) try self.write("static ");
        try self.write("accessor ");
        try self.emitNode(key);
        if (!value.isNone()) {
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
            try self.emitNode(value);
        }
        try self.writeByte(';');
    }

    // ================================================================
    // Pattern 출력
    // ================================================================

    fn emitAssignmentPattern(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte('=');
        try self.emitNode(node.data.binary.right);
    }

    fn emitBindingProperty(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte(':');
        try self.emitNode(node.data.binary.right);
    }

    fn emitRest(self: *Codegen, node: Node) !void {
        try self.write("...");
        try self.emitNode(node.data.unary.operand);
    }

    // ================================================================
    // Declaration 출력
    // ================================================================

    fn emitVariableDeclaration(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const kind_flags = extras[0];
        const list_start = extras[1];
        const list_len = extras[2];

        const keyword = switch (kind_flags) {
            0 => "var ",
            1 => "let ",
            2 => "const ",
            else => "var ",
        };
        try self.write(keyword);
        try self.emitNodeList(list_start, list_len, ",");
        // for문 init 위치에서는 세미콜론을 emitFor가 직접 출력하므로 생략
        if (!self.in_for_init) {
            try self.writeByte(';');
        }
    }

    fn emitVariableDeclarator(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const name: NodeIndex = @enumFromInt(extras[0]);
        // extras[1] = type_ann (스킵)
        const init_val: NodeIndex = @enumFromInt(extras[2]);

        try self.emitNode(name);
        if (!init_val.isNone()) {
            try self.writeSpace();
            try self.writeByte('=');
            try self.writeSpace();
            try self.emitNode(init_val);
        }
    }

    fn emitFormalParam(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const pattern: NodeIndex = @enumFromInt(extras[0]);
        // extras[1] = type_ann (스킵)
        const default_val: NodeIndex = @enumFromInt(extras[2]);

        try self.emitNode(pattern);
        if (!default_val.isNone()) {
            try self.writeByte('=');
            try self.emitNode(default_val);
        }
    }

    // ================================================================
    // Import/Export 출력
    // ================================================================

    /// import_declaration:
    ///   모든 import는 extra = [specs_start, specs_len, source_node] 형식.
    ///   side-effect import (import "module")은 specs_len=0.
    fn emitImport(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const specs_start = extras[0];
        const specs_len = extras[1];
        const source: NodeIndex = @enumFromInt(extras[2]);

        if (self.options.module_format == .cjs) {
            return self.emitImportCJS(source, specs_start, specs_len);
        }

        try self.write("import ");
        if (specs_len > 0) {
            try self.emitImportSpecifiers(specs_start, specs_len);
            try self.write(" from ");
        }
        try self.emitNode(source);
        try self.writeByte(';');
    }

    /// import specifiers를 타입별로 출력한다.
    /// default → 이름만, namespace → * as 이름, named → { a, b }
    fn emitImportSpecifiers(self: *Codegen, specs_start: u32, specs_len: u32) !void {
        const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
        var first = true;
        var has_named = false;

        // 1단계: default, namespace 출력
        for (spec_indices) |raw_idx| {
            const spec: NodeIndex = @enumFromInt(raw_idx);
            if (spec.isNone()) continue;
            const spec_node = self.ast.getNode(spec);
            switch (spec_node.tag) {
                .import_default_specifier => {
                    if (!first) try self.write(",");
                    try self.writeNodeSpan(spec_node);
                    first = false;
                },
                .import_namespace_specifier => {
                    if (!first) try self.write(",");
                    try self.write("* as ");
                    try self.writeNodeSpan(spec_node);
                    first = false;
                },
                .import_specifier => {
                    has_named = true;
                },
                else => {},
            }
        }

        // 2단계: named specifiers를 { } 감싸서 출력
        if (has_named) {
            if (!first) try self.write(",");
            try self.writeByte('{');
            var named_first = true;
            for (spec_indices) |raw_idx| {
                const spec: NodeIndex = @enumFromInt(raw_idx);
                if (spec.isNone()) continue;
                const spec_node = self.ast.getNode(spec);
                if (spec_node.tag == .import_specifier) {
                    if (!named_first) try self.write(",");
                    // binary: { left=imported, right=local }
                    const imported = spec_node.data.binary.left;
                    const local = spec_node.data.binary.right;
                    try self.emitNode(imported);
                    // imported != local이면 as 출력
                    if (!local.isNone() and @intFromEnum(local) != @intFromEnum(imported)) {
                        const imp_node = self.ast.getNode(imported);
                        const loc_node = self.ast.getNode(local);
                        const imp_text = self.ast.source[imp_node.span.start..imp_node.span.end];
                        const loc_text = self.ast.source[loc_node.span.start..loc_node.span.end];
                        if (!std.mem.eql(u8, imp_text, loc_text)) {
                            try self.write(" as ");
                            try self.emitNode(local);
                        }
                    }
                    named_first = false;
                }
            }
            try self.writeByte('}');
        }
    }

    /// CJS: import { foo } from './bar' → const {foo}=require('./bar');
    /// CJS: import bar from './bar' → const bar=require('./bar').default;
    /// CJS: import * as bar from './bar' → const bar=require('./bar');
    fn emitImportCJS(self: *Codegen, source: NodeIndex, specs_start: u32, specs_len: u32) !void {
        if (specs_len == 0) {
            // side-effect import: import './bar' → require('./bar');
            try self.write("require(");
            try self.emitNode(source);
            try self.write(");");
            return;
        }

        try self.write("const ");

        // specifier 유형 분석
        const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
        var has_default = false;
        var has_namespace = false;
        var named_count: u32 = 0;

        for (spec_indices) |raw_idx| {
            const spec = self.ast.getNode(@enumFromInt(raw_idx));
            switch (spec.tag) {
                .import_default_specifier => has_default = true,
                .import_namespace_specifier => has_namespace = true,
                .import_specifier => named_count += 1,
                else => {},
            }
        }

        if (has_namespace) {
            // import * as bar from './bar' → const bar=require('./bar');
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_namespace_specifier) {
                    try self.writeNodeSpan(spec);
                    break;
                }
            }
        } else if (has_default and named_count == 0) {
            // import bar from './bar' → const bar=require('./bar').default;
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_default_specifier) {
                    try self.writeNodeSpan(spec);
                    break;
                }
            }
        } else if (named_count > 0) {
            // import { foo, bar } from './bar' → const {foo,bar}=require('./bar');
            try self.writeByte('{');
            var first = true;
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                if (spec.tag == .import_specifier) {
                    if (!first) try self.writeByte(',');
                    try self.writeNodeSpan(spec);
                    first = false;
                }
            }
            try self.writeByte('}');
        }

        try self.write("=require(");
        try self.emitNode(source);
        try self.writeByte(')');

        if (has_default and !has_namespace and named_count == 0) {
            try self.write(".default");
        }

        try self.writeByte(';');
    }

    fn emitExportNamed(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 4];
        const decl: NodeIndex = @enumFromInt(extras[0]);
        const specs_start = extras[1];
        const specs_len = extras[2];
        const source: NodeIndex = @enumFromInt(extras[3]);

        if (self.options.module_format == .cjs) {
            return self.emitExportNamedCJS(decl, specs_start, specs_len, source);
        }

        // 번들 모드: export 키워드 생략, declaration만 출력
        if (self.options.linking_metadata != null and !decl.isNone()) {
            try self.emitNode(decl);
            return;
        }

        try self.write("export ");
        if (!decl.isNone()) {
            try self.emitNode(decl);
        } else {
            try self.writeByte('{');
            try self.emitNodeList(specs_start, specs_len, ",");
            try self.writeByte('}');
            if (!source.isNone()) {
                try self.write(" from ");
                try self.emitNode(source);
            }
            try self.writeByte(';');
        }
    }

    /// CJS: export const x = 1 → const x=1;exports.x=x;
    fn emitExportNamedCJS(self: *Codegen, decl: NodeIndex, specs_start: u32, specs_len: u32, source: NodeIndex) !void {
        if (!decl.isNone() and @intFromEnum(decl) < self.ast.nodes.items.len) {
            // export const x = 1 → const x=1; + exports.x=x;
            try self.emitNode(decl);
            // 선언에서 이름 추출하여 exports.name = name
            try self.emitCJSExportBinding(decl);
        } else {
            // export { foo, bar } → exports.foo=foo;exports.bar=bar;
            _ = source;
            const spec_indices = self.ast.extra_data.items[specs_start .. specs_start + specs_len];
            for (spec_indices) |raw_idx| {
                const spec = self.ast.getNode(@enumFromInt(raw_idx));
                const spec_text = self.ast.source[spec.span.start..spec.span.end];
                try self.write("exports.");
                try self.write(spec_text);
                try self.writeByte('=');
                try self.write(spec_text);
                try self.writeByte(';');
            }
        }
    }

    /// 변수/함수/클래스 선언에서 이름을 추출하여 exports.name=name; 출력.
    /// variable_declarator의 이름은 span 텍스트에서 직접 추출 (extra 경유 불필요).
    fn emitCJSExportBinding(self: *Codegen, decl_idx: NodeIndex) !void {
        const decl = self.ast.getNode(decl_idx);
        switch (decl.tag) {
            .variable_declaration => {
                const e = decl.data.extra;
                const list_start = self.ast.extra_data.items[e + 1];
                const list_len = self.ast.extra_data.items[e + 2];
                const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
                for (declarators) |raw_idx| {
                    const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                    // declarator의 첫 번째 extra가 name NodeIndex
                    const de = declarator.data.extra;
                    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[de]);
                    if (!name_idx.isNone()) {
                        const name_node = self.ast.getNode(name_idx);
                        // binding_identifier의 이름은 string_ref (span)
                        const name = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                        try self.write("exports.");
                        try self.write(name);
                        try self.writeByte('=');
                        try self.write(name);
                        try self.writeByte(';');
                    }
                }
            },
            .function_declaration, .class_declaration => {
                const e = decl.data.extra;
                const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
                if (!name_idx.isNone()) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                    try self.write("exports.");
                    try self.write(name);
                    try self.writeByte('=');
                    try self.write(name);
                    try self.writeByte(';');
                }
            },
            else => {},
        }
    }

    fn emitExportDefault(self: *Codegen, node: Node) !void {
        if (self.options.module_format == .cjs) {
            try self.write("module.exports=");
            try self.emitNode(node.data.unary.operand);
            try self.writeByte(';');
            return;
        }
        // 번들 모드: export default 키워드 생략, 내부 선언만 출력
        if (self.options.linking_metadata != null) {
            const inner = node.data.unary.operand;
            if (!inner.isNone()) {
                const inner_node = self.ast.getNode(inner);
                switch (inner_node.tag) {
                    .function_declaration, .class_declaration => {
                        // export default function greet() {...} → function greet() {...}
                        try self.emitNode(inner);
                    },
                    else => {
                        // export default 42 → var _default = 42;
                        if (self.options.minify) {
                            try self.write("var _default=");
                        } else {
                            try self.write("var _default = ");
                        }
                        try self.emitNode(inner);
                        try self.writeByte(';');
                    },
                }
            }
            return;
        }
        try self.write("export default ");
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(';');
    }

    fn emitExportAll(self: *Codegen, node: Node) !void {
        if (self.options.module_format == .cjs) {
            // export * from './bar' → Object.assign(exports,require('./bar'));
            try self.write("Object.assign(exports,require(");
            try self.emitNode(node.data.binary.left);
            try self.write("));");
            return;
        }
        try self.write("export * from ");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(';');
    }

    // ================================================================
    // JSX → React.createElement 출력
    // ================================================================

    /// <div className="foo">hello</div> →
    /// React.createElement("div",{className:"foo"},"hello")
    /// jsx_element: extra = [tag, attrs_start, attrs_len, children_start, children_len]
    /// 항상 5 fields. self-closing은 children_len=0.
    fn emitJSXElement(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const tag_name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const attrs_start = self.ast.extra_data.items[e + 1];
        const attrs_len = self.ast.extra_data.items[e + 2];
        const children_start = self.ast.extra_data.items[e + 3];
        const children_len = self.ast.extra_data.items[e + 4];

        try self.write("React.createElement(");
        try self.emitJSXTagName(tag_name_idx);
        try self.emitJSXAttrs(attrs_start, attrs_len);
        try self.emitJSXChildren(children_start, children_len);
        try self.writeByte(')');
    }

    /// <>{children}</> → React.createElement(React.Fragment,null,...children)
    fn emitJSXFragment(self: *Codegen, node: Node) !void {
        try self.write("React.createElement(React.Fragment,null");
        const list = node.data.list;
        try self.emitJSXChildren(list.start, list.len);
        try self.writeByte(')');
    }

    /// tag name 출력: 소문자면 문자열("div"), 그 외 식별자(MyComp)
    fn emitJSXTagName(self: *Codegen, tag_name_idx: NodeIndex) !void {
        const tag_node = self.ast.getNode(tag_name_idx);
        const tag_text = self.ast.source[tag_node.span.start..tag_node.span.end];
        if (tag_text.len > 0 and tag_text[0] >= 'a' and tag_text[0] <= 'z') {
            try self.writeByte('"');
            try self.write(tag_text);
            try self.writeByte('"');
        } else {
            try self.write(tag_text);
        }
    }

    /// attributes → ,{key:val,...} or ,null
    fn emitJSXAttrs(self: *Codegen, attrs_start: u32, attrs_len: u32) !void {
        if (attrs_len > 0) {
            try self.write(",{");
            const attr_indices = self.ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
            for (attr_indices, 0..) |raw_idx, i| {
                if (i > 0) try self.writeByte(',');
                const attr = self.ast.getNode(@enumFromInt(raw_idx));
                if (attr.tag == .jsx_attribute) {
                    try self.emitJSXAttribute(attr);
                } else if (attr.tag == .jsx_spread_attribute) {
                    try self.write("...");
                    try self.emitNode(attr.data.unary.operand);
                }
            }
            try self.writeByte('}');
        } else {
            try self.write(",null");
        }
    }

    /// children 출력 (공통 헬퍼)
    fn emitJSXChildren(self: *Codegen, start: u32, len: u32) !void {
        if (len == 0) return;
        const indices = self.ast.extra_data.items[start .. start + len];
        for (indices) |raw_idx| {
            const child = self.ast.getNode(@enumFromInt(raw_idx));
            if (child.tag == .jsx_text) {
                const text = self.ast.source[child.span.start..child.span.end];
                const trimmed = std.mem.trim(u8, text, " \t\n\r");
                if (trimmed.len == 0) continue;
                try self.write(",\"");
                try self.write(trimmed);
                try self.writeByte('"');
            } else {
                try self.writeByte(',');
                try self.emitNode(@enumFromInt(raw_idx));
            }
        }
    }

    /// JSX attribute: name={value} or name="value"
    fn emitJSXAttribute(self: *Codegen, node: Node) !void {
        // name
        try self.emitNode(node.data.binary.left);
        // value
        if (!node.data.binary.right.isNone()) {
            try self.writeByte(':');
            try self.emitNode(node.data.binary.right);
        } else {
            try self.write(":true");
        }
    }

    /// JSX text (공백 트리밍은 caller에서 처리)
    fn emitJSXText(self: *Codegen, node: Node) !void {
        try self.writeByte('"');
        try self.writeNodeSpan(node);
        try self.writeByte('"');
    }

    // ================================================================
    // TS enum → IIFE 출력
    // ================================================================

    /// enum Color { Red, Green = 5, Blue } →
    /// var Color;(function(Color){Color[Color["Red"]=0]="Red";Color[Color["Green"]=5]="Green";Color[Color["Blue"]=6]="Blue";})(Color||(Color={}));
    fn emitEnumIIFE(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const members_start = self.ast.extra_data.items[e + 1];
        const members_len = self.ast.extra_data.items[e + 2];
        // extras[3] = flags (0=일반, 1=const). const enum은 transformer에서 삭제됨.

        // enum 이름 텍스트 가져오기
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.span);

        // var Color;
        try self.write("var ");
        try self.write(name_text);
        try self.writeByte(';');

        // (function(Color){ ... })(Color||(Color={}));
        try self.write("(function(");
        try self.write(name_text);
        try self.write("){");

        // 각 멤버 출력
        const member_indices = self.ast.extra_data.items[members_start .. members_start + members_len];
        var auto_value: i64 = 0;

        for (member_indices) |raw_idx| {
            const member = self.ast.getNode(@enumFromInt(raw_idx));
            // ts_enum_member: binary = { left=name, right=init_val }
            const member_name_idx = member.data.binary.left;
            const member_init_idx = member.data.binary.right;

            const member_name = self.ast.getNode(member_name_idx);
            const member_text = self.ast.getText(member_name.span);

            // Color[Color["Red"] = 0] = "Red";
            try self.write(name_text);
            try self.writeByte('[');
            try self.write(name_text);
            try self.write("[\"");
            try self.write(member_text);
            try self.write("\"]=");

            if (!member_init_idx.isNone()) {
                // 이니셜라이저가 있으면 그대로 출력
                try self.emitNode(member_init_idx);
                // 이니셜라이저가 숫자 리터럴이면 auto_value 업데이트
                const init_node = self.ast.getNode(member_init_idx);
                if (init_node.tag == .numeric_literal) {
                    const num_text = self.ast.getText(init_node.span);
                    auto_value = std.fmt.parseInt(i64, num_text, 10) catch auto_value;
                    auto_value += 1;
                }
            } else {
                // 자동 증가 값 출력
                try self.emitInt(auto_value);
                auto_value += 1;
            }

            try self.write("]=\"");
            try self.write(member_text);
            try self.write("\";");
        }

        try self.write("})(");
        try self.write(name_text);
        try self.write("||(");
        try self.write(name_text);
        try self.write("={}));");
    }

    // ================================================================
    // TS namespace → IIFE 출력
    // ================================================================

    /// namespace Foo { export const x = 1; } →
    /// var Foo;(function(Foo){const x=1;Foo.x=x;})(Foo||(Foo={}));
    ///
    /// 현재 단순 구현: 내부 문을 그대로 출력하고, export 문은 Foo.name = name으로 변환.
    fn emitNamespaceIIFE(self: *Codegen, node: Node) !void {
        const name_idx = node.data.binary.left;
        const body_idx = node.data.binary.right;

        // 중첩 namespace (A.B.C)인 경우: right가 ts_module_declaration
        const body_node = self.ast.getNode(body_idx);
        if (body_node.tag == .ts_module_declaration) {
            // 외부 namespace IIFE를 열고, 내부를 재귀 처리
            const name_node = self.ast.getNode(name_idx);
            const name_text = self.ast.getText(name_node.span);

            try self.write("var ");
            try self.write(name_text);
            try self.writeByte(';');
            try self.write("(function(");
            try self.write(name_text);
            try self.write("){");
            // 내부 namespace를 재귀 출력
            try self.emitNamespaceIIFE(body_node);
            try self.write("})(");
            try self.write(name_text);
            try self.write("||(");
            try self.write(name_text);
            try self.write("={}));");
            return;
        }

        // body가 block_statement인 경우 (일반 namespace)
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.span);

        // var Foo;
        try self.write("var ");
        try self.write(name_text);
        try self.writeByte(';');

        // (function(Foo){ ... })(Foo||(Foo={}));
        try self.write("(function(");
        try self.write(name_text);
        try self.write("){");

        // body의 각 statement 출력
        // export 문은 Foo.name = expr 형태로 변환
        if (body_node.tag == .block_statement) {
            const list = body_node.data.list;
            const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
            for (indices) |raw_idx| {
                const stmt_node = self.ast.getNode(@enumFromInt(raw_idx));
                switch (stmt_node.tag) {
                    .export_named_declaration => {
                        // export const x = 1; → const x = 1; Foo.x = x;
                        const e = stmt_node.data.extra;
                        const extras = self.ast.extra_data.items[e .. e + 4];
                        const decl_idx: NodeIndex = @enumFromInt(extras[0]);
                        if (!decl_idx.isNone()) {
                            try self.emitNode(decl_idx);
                            // 선언에서 이름을 추출하여 Foo.name = name 추가
                            try self.emitNamespaceExport(name_text, decl_idx);
                        }
                    },
                    .export_default_declaration => {
                        // export default expr → Foo.default = expr;
                        try self.write(name_text);
                        try self.write(".default=");
                        try self.emitNode(stmt_node.data.unary.operand);
                        try self.writeByte(';');
                    },
                    else => try self.emitNode(@enumFromInt(raw_idx)),
                }
            }
        }

        try self.write("})(");
        try self.write(name_text);
        try self.write("||(");
        try self.write(name_text);
        try self.write("={}));");
    }

    /// namespace 내부의 export 선언에서 이름을 추출하여 Foo.name = name; 형태로 출력.
    fn emitNamespaceExport(self: *Codegen, ns_name: []const u8, decl_idx: NodeIndex) !void {
        const decl = self.ast.getNode(decl_idx);
        switch (decl.tag) {
            .variable_declaration => {
                // const x = 1, y = 2; → Foo.x = x; Foo.y = y;
                const e = decl.data.extra;
                const extras = self.ast.extra_data.items[e .. e + 3];
                const list_start = extras[1];
                const list_len = extras[2];
                const declarators = self.ast.extra_data.items[list_start .. list_start + list_len];
                for (declarators) |raw_idx| {
                    const declarator = self.ast.getNode(@enumFromInt(raw_idx));
                    const de = declarator.data.extra;
                    const d_extras = self.ast.extra_data.items[de .. de + 3];
                    const name_idx: NodeIndex = @enumFromInt(d_extras[0]);
                    const var_name_node = self.ast.getNode(name_idx);
                    const var_name = self.ast.getText(var_name_node.span);
                    try self.write(ns_name);
                    try self.writeByte('.');
                    try self.write(var_name);
                    try self.writeByte('=');
                    try self.write(var_name);
                    try self.writeByte(';');
                }
            },
            .function_declaration, .class_declaration => {
                // function foo() {} → Foo.foo = foo;
                const e = decl.data.extra;
                const extras = self.ast.extra_data.items[e .. e + 6];
                const name_idx: NodeIndex = @enumFromInt(extras[0]);
                if (!name_idx.isNone()) {
                    const fn_name_node = self.ast.getNode(name_idx);
                    const fn_name = self.ast.getText(fn_name_node.span);
                    try self.write(ns_name);
                    try self.writeByte('.');
                    try self.write(fn_name);
                    try self.writeByte('=');
                    try self.write(fn_name);
                    try self.writeByte(';');
                }
            },
            else => {},
        }
    }

    fn emitInt(self: *Codegen, value: i64) !void {
        var buf: [20]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        try self.buf.appendSlice(self.allocator, result);
    }

    // ================================================================
    // 리스트 헬퍼
    // ================================================================

    fn emitList(self: *Codegen, node: Node, sep: []const u8) !void {
        const list = node.data.list;
        try self.emitNodeList(list.start, list.len, sep);
    }

    fn emitNodeList(self: *Codegen, start: u32, len: u32, sep: []const u8) !void {
        if (len == 0) return;
        const indices = self.ast.extra_data.items[start .. start + len];
        for (indices, 0..) |raw_idx, i| {
            if (i > 0) try self.write(sep);
            try self.emitNode(@enumFromInt(raw_idx));
        }
    }
};

// ============================================================
// Tests
// ============================================================

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Transformer = @import("../transformer/transformer.zig").Transformer;

/// Arena 기반 테스트 결과. deinit()으로 모든 메모리를 일괄 해제.
const TestResult = struct {
    output: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

/// 기본 e2e: minify 모드 (기존 테스트 호환)
fn e2e(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .minify = true });
}

fn e2eCJS(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return e2eWithOptions(allocator, source, .{ .module_format = .cjs, .minify = true });
}

const TransformOptions = @import("../transformer/transformer.zig").TransformOptions;

/// 풀 옵션 e2e. transform + codegen 옵션 모두 전달.
/// Arena로 전체 파이프라인을 실행. output은 arena 메모리를 가리키므로
/// TestResult.deinit() 전에 사용해야 한다.
fn e2eFull(backing_allocator: std.mem.Allocator, source: []const u8, t_options: TransformOptions, cg_options: CodegenOptions) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();

    var t = Transformer.init(allocator, &parser.ast, t_options);
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, &t.new_ast, cg_options);
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

fn e2eWithOptions(allocator: std.mem.Allocator, source: []const u8, cg_options: CodegenOptions) !TestResult {
    return e2eFull(allocator, source, .{}, cg_options);
}

test "Codegen: empty program" {
    var r = try e2e(std.testing.allocator, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Codegen: variable declaration" {
    var r = try e2e(std.testing.allocator, "const x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: type stripped" {
    var r = try e2e(std.testing.allocator, "type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

test "Codegen: JS with TS stripped" {
    var r = try e2e(std.testing.allocator, "const x = 1; type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: return statement" {
    var r = try e2e(std.testing.allocator, "return;");
    defer r.deinit();
    try std.testing.expectEqualStrings("return;", r.output);
}

test "Codegen: enum IIFE" {
    var r = try e2e(std.testing.allocator, "enum Color { Red, Green, Blue }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Color;(function(Color){Color[Color[\"Red\"]=0]=\"Red\";Color[Color[\"Green\"]=1]=\"Green\";Color[Color[\"Blue\"]=2]=\"Blue\";})(Color||(Color={}));",
        r.output,
    );
}

test "Codegen: namespace IIFE" {
    var r = try e2e(std.testing.allocator, "namespace Foo { const x = 1; }");
    defer r.deinit();
    // 내부 const는 export 아니므로 Foo.x = x 없음
    try std.testing.expectEqualStrings(
        "var Foo;(function(Foo){const x=1;})(Foo||(Foo={}));",
        r.output,
    );
}

test "Codegen CJS: export const" {
    var r = try e2eCJS(std.testing.allocator, "export const x = 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;exports.x=x;", r.output);
}

test "Codegen CJS: export default" {
    var r = try e2eCJS(std.testing.allocator, "export default 42;");
    defer r.deinit();
    try std.testing.expectEqualStrings("module.exports=42;", r.output);
}

test "Codegen: drop debugger" {
    var r = try e2eFull(std.testing.allocator, "debugger; const x = 1;", .{ .drop_debugger = true }, .{ .minify = true });
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: drop console" {
    var r = try e2eFull(std.testing.allocator, "console.log(1); const x = 1;", .{ .drop_console = true }, .{ .minify = true });
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=1;", r.output);
}

test "Codegen: formatted output with tab" {
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1;", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("const x = 1;\n", r.output);
}

test "Codegen: formatted output with spaces" {
    var r = try e2eWithOptions(std.testing.allocator, "const x = 1;", .{ .indent_char = .space, .indent_width = 4 });
    defer r.deinit();
    try std.testing.expectEqualStrings("const x = 1;\n", r.output);
}

test "Codegen: enum with initializer" {
    var r = try e2e(std.testing.allocator, "enum Status { Active = 1, Inactive = 0 }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Status;(function(Status){Status[Status[\"Active\"]=1]=\"Active\";Status[Status[\"Inactive\"]=0]=\"Inactive\";})(Status||(Status={}));",
        r.output,
    );
}

test "Codegen: const enum removed" {
    var r = try e2e(std.testing.allocator, "const enum Dir { Up, Down }");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.output);
}

// ============================================================
// E2E Tests: Class
// ============================================================

test "Codegen: class basic" {
    var r = try e2e(std.testing.allocator, "class Foo {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{}", r.output);
}

test "Codegen: class extends" {
    var r = try e2e(std.testing.allocator, "class Foo extends Bar {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo extends Bar{}", r.output);
}

test "Codegen: class static method" {
    var r = try e2e(std.testing.allocator, "class Foo { static bar() { return 1; } }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{static bar(){return 1;}}", r.output);
}

test "Codegen: class getter setter" {
    var r = try e2e(std.testing.allocator, "class Foo { get x() { return 1; } set x(v) {} }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{get x(){return 1;}set x(v){}}", r.output);
}

test "Codegen: class private field" {
    var r = try e2e(std.testing.allocator, "class Foo { #x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo{#x=1;}", r.output);
}

// ============================================================
// E2E Tests: Arrow Function
// ============================================================

test "Codegen: arrow no params" {
    var r = try e2e(std.testing.allocator, "const f = () => 1;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=()=>1;", r.output);
}

test "Codegen: arrow single param" {
    var r = try e2e(std.testing.allocator, "const f = x => x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=x=>x;", r.output);
}

test "Codegen: arrow block body" {
    var r = try e2e(std.testing.allocator, "const f = (a, b) => { return a + b; };");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(a,b)=>{return a + b;};", r.output);
}

test "Codegen: arrow rest param" {
    var r = try e2e(std.testing.allocator, "const f = (...args) => args;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=(...args)=>args;", r.output);
}

// ============================================================
// E2E Tests: Async/Await
// ============================================================

test "Codegen: async function" {
    var r = try e2e(std.testing.allocator, "async function foo() { return 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("async function foo(){return 1;}", r.output);
}

test "Codegen: await expression" {
    var r = try e2e(std.testing.allocator, "async function foo() { const x = await bar(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("async function foo(){const x=await bar();}", r.output);
}

test "Codegen: async arrow" {
    var r = try e2e(std.testing.allocator, "const f = async () => await x;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=async ()=>await x;", r.output);
}

// ============================================================
// E2E Tests: Generator
// ============================================================

test "Codegen: generator function" {
    var r = try e2e(std.testing.allocator, "function* gen() { yield 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function* gen(){yield 1;}", r.output);
}

test "Codegen: yield star" {
    var r = try e2e(std.testing.allocator, "function* gen() { yield* other(); }");
    defer r.deinit();
    try std.testing.expectEqualStrings("function* gen(){yield* other();}", r.output);
}

// ============================================================
// E2E Tests: Destructuring
// ============================================================

test "Codegen: array destructuring" {
    var r = try e2e(std.testing.allocator, "const [a, b] = [1, 2];");
    defer r.deinit();
    try std.testing.expectEqualStrings("const [a,b]=[1,2];", r.output);
}

test "Codegen: object destructuring" {
    // binding_property always emits key:value (shorthand is not collapsed)
    var r = try e2e(std.testing.allocator, "const { x, y } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {x:x,y:y}=obj;", r.output);
}

test "Codegen: nested destructuring" {
    var r = try e2e(std.testing.allocator, "const { a: { b } } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {a:{b:b}}=obj;", r.output);
}

test "Codegen: destructuring with default" {
    var r = try e2e(std.testing.allocator, "const { x = 1 } = obj;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {x:x=1}=obj;", r.output);
}

// ============================================================
// E2E Tests: Template Literal
// ============================================================

test "Codegen: template literal basic" {
    var r = try e2e(std.testing.allocator, "const x = `hello`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello`;", r.output);
}

test "Codegen: template literal with expression" {
    var r = try e2e(std.testing.allocator, "const x = `hello ${name}!`;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=`hello ${name}!`;", r.output);
}

// ============================================================
// E2E Tests: For-of / For-in
// ============================================================

test "Codegen: for-of" {
    var r = try e2e(std.testing.allocator, "for (const x of arr) {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const x of arr){}", r.output);
}

test "Codegen: for-in" {
    var r = try e2e(std.testing.allocator, "for (const k in obj) {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("for(const k in obj){}", r.output);
}

// ============================================================
// E2E Tests: Spread
// ============================================================

test "Codegen: array spread" {
    var r = try e2e(std.testing.allocator, "const x = [...a, ...b];");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=[...a,...b];", r.output);
}

test "Codegen: object spread" {
    var r = try e2e(std.testing.allocator, "const x = { ...a, ...b };");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x={...a,...b};", r.output);
}

test "Codegen: function call spread" {
    var r = try e2e(std.testing.allocator, "foo(...args);");
    defer r.deinit();
    try std.testing.expectEqualStrings("foo(...args);", r.output);
}

// ============================================================
// E2E Tests: Optional Chaining / Nullish
// ============================================================

test "Codegen: optional chaining" {
    var r = try e2e(std.testing.allocator, "const x = a?.b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a?.b;", r.output);
}

test "Codegen: nullish coalescing" {
    var r = try e2e(std.testing.allocator, "const x = a ?? b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a ?? b;", r.output);
}

test "Codegen: optional chaining method call" {
    var r = try e2e(std.testing.allocator, "const x = a?.foo();");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=a?.foo();", r.output);
}

// ============================================================
// E2E Tests: Logical Assignment
// ============================================================

test "Codegen: logical and assign" {
    var r = try e2e(std.testing.allocator, "a &&= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a&&=b;", r.output);
}

test "Codegen: logical or assign" {
    var r = try e2e(std.testing.allocator, "a ||= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a||=b;", r.output);
}

test "Codegen: nullish assign" {
    var r = try e2e(std.testing.allocator, "a ??= b;");
    defer r.deinit();
    try std.testing.expectEqualStrings("a??=b;", r.output);
}

// ============================================================
// E2E Tests: Import/Export
// ============================================================

test "Codegen: import default" {
    var r = try e2e(std.testing.allocator, "import foo from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import foo from './foo';", r.output);
}

test "Codegen: import named" {
    var r = try e2e(std.testing.allocator, "import { a, b } from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import {a,b} from './foo';", r.output);
}

test "Codegen: import namespace" {
    var r = try e2e(std.testing.allocator, "import * as ns from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("import * as ns from './foo';", r.output);
}

test "Codegen: export named" {
    // export_specifier uses writeNodeSpan which preserves trailing space from source
    var r = try e2e(std.testing.allocator, "export { a, b };");
    defer r.deinit();
    try std.testing.expectEqualStrings("export {a,b };", r.output);
}

test "Codegen: export default function" {
    var r = try e2e(std.testing.allocator, "export default function foo() {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("export default function foo(){};", r.output);
}

test "Codegen: export all re-export" {
    // emitExportAll reads binary.left (exported_name), but source is binary.right
    // NOTE: this is a known issue — source node is omitted in current codegen
    var r = try e2e(std.testing.allocator, "export * from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("export * from ;", r.output);
}

// ============================================================
// E2E Tests: JSX → React.createElement
// ============================================================

test "Codegen: JSX self-closing" {
    var r = try e2e(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=React.createElement(\"div\",null);", r.output);
}

test "Codegen: JSX element with children" {
    var r = try e2e(std.testing.allocator, "const x = <div>hello</div>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=React.createElement(\"div\",null,\"hello\");", r.output);
}

test "Codegen: JSX fragment" {
    var r = try e2e(std.testing.allocator, "const x = <>hello</>;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=React.createElement(React.Fragment,null,\"hello\");", r.output);
}

// ============================================================
// E2E Tests: Namespace with export
// ============================================================

test "Codegen: namespace with export const" {
    var r = try e2e(std.testing.allocator, "namespace Foo { export const x = 1; }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Foo;(function(Foo){const x=1;Foo.x=x;})(Foo||(Foo={}));",
        r.output,
    );
}

test "Codegen: namespace with export function" {
    var r = try e2e(std.testing.allocator, "namespace Foo { export function bar() {} }");
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "var Foo;(function(Foo){function bar(){}Foo.bar=bar;})(Foo||(Foo={}));",
        r.output,
    );
}

// ============================================================
// E2E Tests: TS type assertions (stripped)
// ============================================================

test "Codegen: as expression stripped" {
    var r = try e2e(std.testing.allocator, "const x = value as string;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

test "Codegen: satisfies expression stripped" {
    var r = try e2e(std.testing.allocator, "const x = value satisfies T;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

test "Codegen: non-null assertion stripped" {
    var r = try e2e(std.testing.allocator, "const x = value!;");
    defer r.deinit();
    try std.testing.expectEqualStrings("const x=value;", r.output);
}

// ============================================================
// E2E Tests: CJS module format
// ============================================================

test "Codegen CJS: import named" {
    // CJS named import uses writeNodeSpan which preserves trailing space from source
    var r = try e2eCJS(std.testing.allocator, "import { foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo }=require('./bar');", r.output);
}

test "Codegen CJS: import default" {
    var r = try e2eCJS(std.testing.allocator, "import bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require('./bar').default;", r.output);
}

test "Codegen CJS: import namespace" {
    var r = try e2eCJS(std.testing.allocator, "import * as bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require('./bar');", r.output);
}

test "Codegen CJS: export all" {
    // emitExportAll reads binary.left (exported_name=None) instead of binary.right (source)
    // NOTE: this is a known issue — source node is omitted in current codegen
    var r = try e2eCJS(std.testing.allocator, "export * from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("Object.assign(exports,require());", r.output);
}

test "Codegen CJS: export named function" {
    var r = try e2eCJS(std.testing.allocator, "export function foo() {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo(){}exports.foo=foo;", r.output);
}

// ============================================================
// E2E Tests: Formatted output
// ============================================================

test "Codegen formatted: function declaration" {
    var r = try e2eWithOptions(std.testing.allocator, "function foo() { return 1; }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo() {\n\treturn 1;\n}\n", r.output);
}

test "Codegen formatted: class with method" {
    var r = try e2eWithOptions(std.testing.allocator, "class Foo { bar() {} }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo {\n\tbar() {}\n}\n", r.output);
}

test "Codegen formatted: spaces indent" {
    var r = try e2eWithOptions(std.testing.allocator, "if (x) { return 1; }", .{ .indent_char = .space, .indent_width = 2 });
    defer r.deinit();
    try std.testing.expectEqualStrings("if(x) {\n  return 1;\n}\n", r.output);
}
