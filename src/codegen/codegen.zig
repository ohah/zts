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
};

const SourceMapBuilder = @import("sourcemap.zig").SourceMapBuilder;
const Mapping = @import("sourcemap.zig").Mapping;

pub const Codegen = struct {
    ast: *const Ast,
    buf: std.ArrayList(u8),
    options: CodegenOptions,
    /// 현재 들여쓰기 레벨
    indent_level: u32 = 0,
    /// 소스맵 빌더 (sourcemap 옵션 활성화 시)
    sm_builder: ?SourceMapBuilder = null,
    /// 출력의 현재 줄/열 (소스맵 매핑용)
    gen_line: u32 = 0,
    gen_col: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) Codegen {
        return initWithOptions(allocator, ast, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, ast: *const Ast, options: CodegenOptions) Codegen {
        return .{
            .ast = ast,
            .buf = std.ArrayList(u8).init(allocator),
            .options = options,
            .indent_level = 0,
            .sm_builder = if (options.sourcemap) SourceMapBuilder.init(allocator) else null,
            .gen_line = 0,
            .gen_col = 0,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.buf.deinit();
        if (self.sm_builder) |*sm| sm.deinit();
    }

    /// AST를 JS 문자열로 출력한다.
    pub fn generate(self: *Codegen, root: NodeIndex) ![]const u8 {
        // 출력 크기는 보통 소스 크기와 비슷 → 사전 할당
        try self.buf.ensureTotalCapacity(self.ast.source.len);
        try self.emitNode(root);
        return self.buf.items;
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
        try self.buf.appendSlice(s);
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
        try self.buf.append(b);
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
            // span의 byte offset → 소스의 줄/열 변환
            // 현재는 Scanner의 line offset table이 없으므로 byte offset을 직접 사용
            // TODO: Scanner에서 line offset table을 가져와 정확한 줄/열 계산
            const src_line = span.start; // 임시: byte offset을 줄로 사용
            const src_col: u32 = 0; // 임시
            _ = src_line;
            _ = src_col;
            try sm.addMapping(.{
                .generated_line = self.gen_line,
                .generated_column = self.gen_col,
                .source_index = 0,
                .original_line = 0, // TODO: 정확한 줄/열 계산
                .original_column = span.start,
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

    /// 소스 코드의 span 범위를 그대로 출력 (zero-copy).
    fn writeSpan(self: *Codegen, span: Span) !void {
        try self.buf.appendSlice(self.ast.source[span.start..span.end]);
    }

    /// 노드의 소스 텍스트를 출력.
    fn writeNodeSpan(self: *Codegen, node: Node) !void {
        try self.writeSpan(node.span);
    }

    // ================================================================
    // 노드 출력
    // ================================================================

    pub const Error = std.mem.Allocator.Error;

    fn emitNode(self: *Codegen, idx: NodeIndex) Error!void {
        if (idx.isNone()) return;

        const node = self.ast.getNode(idx);

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

            // Identifiers
            .identifier_reference,
            .private_identifier,
            .binding_identifier,
            => try self.writeSpan(node.data.string_ref),

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
            .rest_element, .binding_rest_element => try self.emitRest(node),
            .assignment_target_with_default => try self.emitAssignmentPattern(node),
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
        try self.emitNode(t.a);
        try self.writeByte(' ');
        try self.write(keyword);
        try self.writeByte(' ');
        try self.emitNode(t.b);
        try self.writeByte(')');
        try self.emitNode(t.c);
    }

    fn emitSwitch(self: *Codegen, node: Node) !void {
        // switch_statement uses list: [discriminant, ...cases]
        // 실제로는 extra로 저장됨 — 구현에 따라 다름
        // 현재 파서에서 list로 저장: [discriminant_expr, case1, case2, ...]
        // TODO: 파서의 실제 구조 확인 필요
        try self.writeNodeSpan(node);
    }

    fn emitSwitchCase(self: *Codegen, node: Node) !void {
        try self.writeNodeSpan(node);
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
        try self.emitNode(t.a); // block
        if (!t.b.isNone()) try self.emitNode(t.b); // catch
        if (!t.c.isNone()) {
            try self.write("finally");
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
        const op: Kind = @enumFromInt(node.data.unary.flags);
        try self.write(op.symbol());
        if (op == .kw_typeof or op == .kw_void or op == .kw_delete) try self.writeByte(' ');
        try self.emitNode(node.data.unary.operand);
    }

    fn emitUpdate(self: *Codegen, node: Node) !void {
        const flags = node.data.unary.flags;
        const is_postfix = (flags & 0x100) != 0;
        const op: Kind = @enumFromInt(@as(u8, @truncate(flags)));
        if (!is_postfix) try self.write(op.symbol());
        try self.emitNode(node.data.unary.operand);
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
        try self.emitList(node, ",");
        try self.writeByte(']');
    }

    fn emitObject(self: *Codegen, node: Node) !void {
        try self.writeByte('{');
        try self.emitList(node, ",");
        try self.writeByte('}');
    }

    fn emitObjectProperty(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const value: NodeIndex = @enumFromInt(extras[1]);
        try self.emitNode(key);
        if (!value.isNone()) {
            try self.writeByte(':');
            try self.emitNode(value);
        }
    }

    fn emitComputedKey(self: *Codegen, node: Node) !void {
        try self.writeByte('[');
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(']');
    }

    fn emitStaticMember(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte('.');
        try self.emitNode(node.data.binary.right);
    }

    fn emitComputedMember(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte('[');
        try self.emitNode(node.data.binary.right);
        try self.writeByte(']');
    }

    /// call_expression: binary = { left=callee, right=@enumFromInt(args_start), flags=args_len }
    fn emitCall(self: *Codegen, node: Node) !void {
        const callee = node.data.binary.left;
        const args_start: u32 = @intFromEnum(node.data.binary.right);
        const args_len: u32 = node.data.binary.flags;

        try self.emitNode(callee);
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, ",");
        try self.writeByte(')');
    }

    fn emitNew(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 3];
        const callee: NodeIndex = @enumFromInt(extras[0]);
        const args_start = extras[1];
        const args_len = extras[2];

        try self.write("new ");
        try self.emitNode(callee);
        try self.writeByte('(');
        try self.emitNodeList(args_start, args_len, ",");
        try self.writeByte(')');
    }

    fn emitTaggedTemplate(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.emitNode(node.data.binary.right);
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

        if (flags & 2 != 0) try self.write("async ");
        try self.write("function");
        if (flags & 1 != 0) try self.writeByte('*');
        if (!name.isNone()) {
            try self.writeByte(' ');
            try self.emitNode(name);
        }
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.writeByte(')');
        try self.emitNode(body);
    }

    fn emitArrow(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 6];
        const params_start = extras[1];
        const params_len = extras[2];
        const body: NodeIndex = @enumFromInt(extras[3]);
        const flags = extras[4];

        if (flags & 2 != 0) try self.write("async ");
        try self.writeByte('(');
        try self.emitNodeList(params_start, params_len, ",");
        try self.write(")=>");
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

    fn emitMethodDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const value: NodeIndex = @enumFromInt(extras[1]);
        _ = extras[2]; // flags — static/getter/setter 등
        try self.emitNode(key);
        try self.emitNode(value);
    }

    fn emitPropertyDef(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 6];
        const key: NodeIndex = @enumFromInt(extras[0]);
        const value: NodeIndex = @enumFromInt(extras[1]);
        try self.emitNode(key);
        if (!value.isNone()) {
            try self.writeByte('=');
            try self.emitNode(value);
        }
        try self.writeByte(';');
    }

    fn emitDecorator(self: *Codegen, node: Node) !void {
        try self.writeByte('@');
        try self.emitNode(node.data.unary.operand);
    }

    fn emitAccessorProp(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.writeByte('=');
        try self.emitNode(node.data.binary.right);
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
        try self.writeByte(';');
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

    fn emitImport(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 5];
        const source: NodeIndex = @enumFromInt(extras[0]);
        const specs_start = extras[1];
        const specs_len = extras[2];

        if (self.options.module_format == .cjs) {
            return self.emitImportCJS(source, specs_start, specs_len);
        }

        try self.write("import ");
        if (specs_len > 0) {
            try self.emitNodeList(specs_start, specs_len, ",");
            try self.write(" from ");
        }
        try self.emitNode(source);
        try self.writeByte(';');
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
    fn emitJSXElement(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const tag_name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
        const attrs_start = self.ast.extra_data.items[e + 1];
        const attrs_len = self.ast.extra_data.items[e + 2];

        // self-closing은 extra 3개, with-children은 5개
        // extra_data 배열에서 이 노드 다음에 다른 노드의 데이터가 올 수 있으므로
        // children 유무는 파서가 저장한 extra 개수로 판단해야 한다.
        // self-closing: extra = [tag, attrs_start, attrs_len]
        // with-children: extra = [tag, attrs_start, attrs_len, children_start, children_len]
        // 판별: children_len > 0 이면 children 있음. self-closing이면 e+3, e+4가 다른 노드 데이터.
        // 안전한 방법: 노드의 span으로 self-closing 여부 판별하거나, 파서에서 명시적으로 구분.
        // 현재: extra_data[e+3]을 읽되, 값이 합리적인 범위인지 검증.
        var children_start: u32 = 0;
        var children_len: u32 = 0;
        if (e + 5 <= self.ast.extra_data.items.len) {
            const maybe_len = self.ast.extra_data.items[e + 4];
            // children_len이 0이면 실질적으로 children 없음
            if (maybe_len > 0 and maybe_len <= self.ast.extra_data.items.len) {
                children_start = self.ast.extra_data.items[e + 3];
                children_len = maybe_len;
            }
        }

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
        const extras = self.ast.extra_data.items[e .. e + 3];
        const name_idx: NodeIndex = @enumFromInt(extras[0]);
        const members_start = extras[1];
        const members_len = extras[2];

        // enum 이름 텍스트 가져오기
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.source[name_node.span.start..name_node.span.end];

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
            const member_text = self.ast.source[member_name.span.start..member_name.span.end];

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
                    const num_text = self.ast.source[init_node.span.start..init_node.span.end];
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
            const name_text = self.ast.source[name_node.span.start..name_node.span.end];

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
        const name_text = self.ast.source[name_node.span.start..name_node.span.end];

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
                    const var_name = self.ast.source[var_name_node.span.start..var_name_node.span.end];
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
                    const fn_name = self.ast.source[fn_name_node.span.start..fn_name_node.span.end];
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
        const len = std.fmt.formatIntBuf(&buf, value, 10, .lower, .{});
        try self.buf.appendSlice(buf[0..len]);
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

/// end-to-end 헬퍼: 소스 → 파싱 → 변환 → codegen → JS 문자열
fn generateJS(allocator: std.mem.Allocator, source: []const u8) !struct { output: []const u8, scanner: *Scanner, parser: *Parser, codegen_inst: *Codegen, transformed_ast: Ast } {
    const scanner_ptr = try allocator.create(Scanner);
    scanner_ptr.* = Scanner.init(allocator, source);

    const parser_ptr = try allocator.create(Parser);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);
    _ = try parser_ptr.parse();

    var t = Transformer.init(allocator, &parser_ptr.ast, .{});
    const root = try t.transform();
    t.scratch.deinit();

    const cg = try allocator.create(Codegen);
    cg.* = Codegen.init(allocator, &t.new_ast);
    // new_ast는 cg가 참조하므로 여기서 해제하면 안 됨
    // transformed_ast를 반환하여 caller가 관리

    const output = try cg.generate(root);
    return .{ .output = output, .scanner = scanner_ptr, .parser = parser_ptr, .codegen_inst = cg, .transformed_ast = t.new_ast };
}

const TestResult = struct {
    output: []const u8,
    scanner: *Scanner,
    parser: *Parser,
    codegen_inst: *Codegen,
    transformed_ast: Ast,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestResult) void {
        self.codegen_inst.deinit();
        self.allocator.destroy(self.codegen_inst);
        self.transformed_ast.deinit();
        self.parser.deinit();
        self.allocator.destroy(self.parser);
        self.scanner.deinit();
        self.allocator.destroy(self.scanner);
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
fn e2eFull(allocator: std.mem.Allocator, source: []const u8, t_options: TransformOptions, cg_options: CodegenOptions) !TestResult {
    const scanner_ptr = try allocator.create(Scanner);
    scanner_ptr.* = Scanner.init(allocator, source);

    const parser_ptr = try allocator.create(Parser);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);
    _ = try parser_ptr.parse();

    var t = Transformer.init(allocator, &parser_ptr.ast, t_options);
    const root = try t.transform();
    t.scratch.deinit();

    const cg = try allocator.create(Codegen);
    cg.* = Codegen.initWithOptions(allocator, &t.new_ast, cg_options);

    const output = try cg.generate(root);
    return .{
        .output = output,
        .scanner = scanner_ptr,
        .parser = parser_ptr,
        .codegen_inst = cg,
        .transformed_ast = t.new_ast,
        .allocator = allocator,
    };
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
