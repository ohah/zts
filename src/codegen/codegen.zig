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

pub const Codegen = struct {
    ast: *const Ast,
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) Codegen {
        return .{
            .ast = ast,
            .buf = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.buf.deinit();
    }

    /// AST를 JS 문자열로 출력한다.
    pub fn generate(self: *Codegen, root: NodeIndex) ![]const u8 {
        try self.emitNode(root);
        return self.buf.items;
    }

    // ================================================================
    // 출력 헬퍼
    // ================================================================

    fn write(self: *Codegen, s: []const u8) !void {
        try self.buf.appendSlice(s);
    }

    fn writeByte(self: *Codegen, b: u8) !void {
        try self.buf.append(b);
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
            .template_literal => try self.emitTemplateLiteral(node),
            .template_element => try self.writeNodeSpan(node),
            .tagged_template_expression => try self.emitTaggedTemplate(node),
            .import_expression => try self.emitImportExpr(node),
            .meta_property => try self.writeNodeSpan(node),
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
            .import_specifier => try self.emitImportSpec(node),
            .import_default_specifier => try self.emitImportDefault(node),
            .import_namespace_specifier => try self.emitImportNamespace(node),
            .import_attribute => try self.writeNodeSpan(node),
            .export_named_declaration => try self.emitExportNamed(node),
            .export_default_declaration => try self.emitExportDefault(node),
            .export_all_declaration => try self.emitExportAll(node),
            .export_specifier => try self.emitExportSpec(node),

            // Formal parameters
            .formal_parameters, .function_body => try self.emitList(node, ", "),

            .formal_parameter => try self.emitFormalParam(node),

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
            if (i > 0) try self.writeByte('\n');
            try self.emitNode(@enumFromInt(raw_idx));
        }
    }

    fn emitBlock(self: *Codegen, node: Node) !void {
        try self.writeByte('{');
        const list = node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            try self.emitNode(@enumFromInt(raw_idx));
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

    fn emitCall(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 4];
        const callee: NodeIndex = @enumFromInt(extras[0]);
        const args_start = extras[1];
        const args_len = extras[2];

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

    fn emitTemplateLiteral(self: *Codegen, node: Node) !void {
        try self.writeNodeSpan(node);
    }

    fn emitTaggedTemplate(self: *Codegen, node: Node) !void {
        try self.emitNode(node.data.binary.left);
        try self.emitNode(node.data.binary.right);
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

    fn emitClass(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 6];
        const name: NodeIndex = @enumFromInt(extras[0]);
        const super_class: NodeIndex = @enumFromInt(extras[1]);
        const body: NodeIndex = @enumFromInt(extras[2]);

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
        try self.writeByte('{');
        const list = node.data.list;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            try self.emitNode(@enumFromInt(raw_idx));
        }
        try self.writeByte('}');
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
            try self.writeByte('=');
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

        try self.write("import ");
        if (specs_len > 0) {
            try self.emitNodeList(specs_start, specs_len, ",");
            try self.write(" from ");
        }
        try self.emitNode(source);
        try self.writeByte(';');
    }

    fn emitImportSpec(self: *Codegen, node: Node) !void {
        try self.writeNodeSpan(node);
    }

    fn emitImportDefault(self: *Codegen, node: Node) !void {
        try self.writeNodeSpan(node);
    }

    fn emitImportNamespace(self: *Codegen, node: Node) !void {
        try self.writeNodeSpan(node);
    }

    fn emitExportNamed(self: *Codegen, node: Node) !void {
        const e = node.data.extra;
        const extras = self.ast.extra_data.items[e .. e + 4];
        const decl: NodeIndex = @enumFromInt(extras[0]);
        const specs_start = extras[1];
        const specs_len = extras[2];
        const source: NodeIndex = @enumFromInt(extras[3]);

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

    fn emitExportDefault(self: *Codegen, node: Node) !void {
        try self.write("export default ");
        try self.emitNode(node.data.unary.operand);
        try self.writeByte(';');
    }

    fn emitExportAll(self: *Codegen, node: Node) !void {
        try self.write("export * from ");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(';');
    }

    fn emitExportSpec(self: *Codegen, node: Node) !void {
        try self.writeNodeSpan(node);
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

fn e2e(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    const result = try generateJS(allocator, source);
    return .{
        .output = result.output,
        .scanner = result.scanner,
        .parser = result.parser,
        .codegen_inst = result.codegen_inst,
        .transformed_ast = result.transformed_ast,
        .allocator = allocator,
    };
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
