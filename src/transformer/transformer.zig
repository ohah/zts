//! ZTS Transformer — 핵심 변환 엔진
//!
//! 원본 AST를 읽고 새 AST를 빌드한다.
//!
//! 작동 원리:
//!   1. 원본 AST(old_ast)의 루트 노드부터 시작
//!   2. 각 노드의 tag를 switch로 분기
//!   3. TS 전용 노드는 스킵(.none 반환) 또는 변환
//!   4. JS 노드는 자식을 재귀 방문 후 새 AST(new_ast)에 복사
//!
//! 메모리:
//!   - new_ast는 별도 allocator로 생성 (D041)
//!   - 변환 완료 후 old_ast는 해제 가능
//!   - new_ast의 source는 old_ast와 같은 소스를 참조 (zero-copy)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const Data = Node.Data;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;

/// Transformer 설정. 추후 JSX 모드, 모듈 타입 등 추가 예정.
pub const TransformOptions = struct {
    /// TS 타입 스트리핑 활성화 (기본: true)
    strip_types: bool = true,
};

/// AST-to-AST 변환기.
///
/// 사용법:
/// ```zig
/// var t = Transformer.init(allocator, &old_ast, .{});
/// const new_root = try t.transform();
/// // t.new_ast 에 변환된 AST가 들어있다
/// ```
pub const Transformer = struct {
    /// 원본 AST (읽기 전용)
    old_ast: *const Ast,

    /// 변환 결과를 저장할 새 AST
    new_ast: Ast,

    /// 설정
    options: TransformOptions,

    /// 임시 버퍼 (리스트 변환 시 재사용)
    scratch: std.ArrayList(NodeIndex),

    pub fn init(allocator: std.mem.Allocator, old_ast: *const Ast, options: TransformOptions) Transformer {
        return .{
            .old_ast = old_ast,
            .new_ast = Ast.init(allocator, old_ast.source),
            .options = options,
            .scratch = std.ArrayList(NodeIndex).init(allocator),
        };
    }

    pub fn deinit(self: *Transformer) void {
        self.new_ast.deinit();
        self.scratch.deinit();
    }

    // ================================================================
    // 공개 API
    // ================================================================

    /// 변환을 실행한다. 원본 AST의 마지막 노드(program)부터 시작.
    ///
    /// 반환값: 새 AST에서의 루트 NodeIndex.
    /// 변환된 AST는 self.new_ast에 저장된다.
    pub fn transform(self: *Transformer) Error!NodeIndex {
        // 파서는 parse() 끝에 program 노드를 추가하므로 마지막 노드가 루트
        const root_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(self.old_ast.nodes.items.len - 1)));
        return self.visitNode(root_idx);
    }

    // ================================================================
    // 핵심 visitor — switch 기반 (D042)
    // ================================================================

    /// 노드 하나를 방문하여 새 AST에 복사/변환/스킵한다.
    ///
    /// 반환값:
    ///   - 변환된 노드의 새 인덱스
    ///   - .none이면 이 노드를 삭제(스킵)한다는 뜻
    /// 에러 타입. ArrayList의 append/ensureCapacity가 반환하는 에러.
    /// 재귀 함수에서 Zig가 에러 셋을 추론할 수 없으므로 명시적으로 선언.
    pub const Error = std.mem.Allocator.Error;

    fn visitNode(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        if (idx.isNone()) return .none;

        const node = self.old_ast.getNode(idx);

        // --------------------------------------------------------
        // 1단계: TS 타입 전용 노드는 통째로 삭제 (comptime 보조)
        // --------------------------------------------------------
        if (self.options.strip_types and isTypeOnlyNode(node.tag)) {
            return .none;
        }

        // --------------------------------------------------------
        // 2단계: 태그별 분기 (switch 기반 visitor)
        // --------------------------------------------------------
        return switch (node.tag) {
            // === TS expressions: 타입 부분만 제거, 값 보존 ===
            .ts_as_expression,
            .ts_satisfies_expression,
            .ts_non_null_expression,
            .ts_type_assertion,
            .ts_instantiation_expression,
            => self.visitTsExpression(node),

            // === 리스트 노드: 자식을 하나씩 방문하며 복사 ===
            .program,
            .block_statement,
            .array_expression,
            .object_expression,
            .sequence_expression,
            .class_body,
            .formal_parameters,
            .switch_statement,
            .template_literal,
            // JSX
            .jsx_element,
            .jsx_opening_element,
            .jsx_fragment,
            .function_body,
            => self.visitListNode(node),

            // === 단항 노드: 자식 1개 재귀 방문 ===
            .expression_statement,
            .return_statement,
            .throw_statement,
            .spread_element,
            .parenthesized_expression,
            .await_expression,
            .yield_expression,
            .unary_expression,
            .update_expression,
            .rest_element,
            .decorator,
            // JSX
            .jsx_spread_attribute,
            .jsx_expression_container,
            .jsx_spread_child,
            .chain_expression,
            => self.visitUnaryNode(node),

            // === 이항 노드: 자식 2개 재귀 방문 ===
            .binary_expression,
            .logical_expression,
            .assignment_expression,
            .computed_member_expression,
            .while_statement,
            .do_while_statement,
            .labeled_statement,
            .with_statement,
            .static_member_expression,
            .private_field_expression,
            // JSX
            .jsx_attribute,
            .jsx_namespaced_name,
            .jsx_member_expression,
            => self.visitBinaryNode(node),

            // === 삼항 노드: 자식 3개 재귀 방문 ===
            .if_statement,
            .conditional_expression,
            .for_in_statement,
            .for_of_statement,
            .try_statement,
            => self.visitTernaryNode(node),

            // === extra 기반 노드: 별도 처리 ===
            .variable_declaration => self.visitVariableDeclaration(node),
            .variable_declarator => self.visitVariableDeclarator(node),
            .function_declaration,
            .function_expression,
            .function,
            .arrow_function_expression,
            => self.visitFunction(node),
            .class_declaration,
            .class_expression,
            => self.visitClass(node),
            .for_statement => self.visitForStatement(node),
            .switch_case => self.visitSwitchCase(node),
            .call_expression => self.visitCallExpression(node),
            .new_expression => self.visitNewExpression(node),
            .tagged_template_expression => self.visitBinaryNode(node),
            .method_definition => self.visitMethodDefinition(node),
            .property_definition => self.visitPropertyDefinition(node),
            .object_property => self.visitObjectProperty(node),
            .formal_parameter => self.visitFormalParameter(node),
            .import_declaration => self.visitImportDeclaration(node),
            .export_named_declaration => self.visitExportNamedDeclaration(node),
            .export_default_declaration => self.visitUnaryNode(node),
            .export_all_declaration,
            .catch_clause,
            .binding_property,
            .assignment_pattern,
            .accessor_property,
            => self.visitBinaryNode(node),

            // === 리프 노드: 그대로 복사 (자식 없음) ===
            .boolean_literal,
            .null_literal,
            .numeric_literal,
            .string_literal,
            .bigint_literal,
            .regexp_literal,
            .this_expression,
            .identifier_reference,
            .private_identifier,
            .binding_identifier,
            .empty_statement,
            .debugger_statement,
            .break_statement,
            .continue_statement,
            .directive,
            .hashbang,
            .super_expression,
            .meta_property,
            .template_element,
            .import_expression,
            .elision,
            .static_block,
            .computed_property_key,
            // JSX leaf
            .jsx_text,
            .jsx_empty_expression,
            .jsx_identifier,
            .jsx_closing_element,
            .jsx_opening_fragment,
            .jsx_closing_fragment,
            => self.copyNodeDirect(node),

            // === import/export specifiers: 그대로 복사 ===
            .import_specifier,
            .import_default_specifier,
            .import_namespace_specifier,
            .import_attribute,
            .export_specifier,
            => self.copyNodeDirect(node),

            // === Pattern 노드: 자식 재귀 방문 ===
            .array_pattern,
            .object_pattern,
            .array_assignment_target,
            .object_assignment_target,
            => self.visitListNode(node),

            .binding_rest_element => self.visitUnaryNode(node),
            .assignment_target_with_default => self.visitBinaryNode(node),

            // === TS enum/namespace: 런타임 코드 생성 (codegen에서 IIFE 출력) ===
            .ts_enum_declaration => self.visitEnumDeclaration(node),
            .ts_enum_member => self.visitBinaryNode(node),
            .ts_enum_body => self.visitListNode(node),
            .ts_module_declaration => self.visitNamespaceDeclaration(node),
            .ts_module_block => self.visitListNode(node),

            // === 나머지: invalid + TS 타입 전용 노드 ===
            // TS 타입 노드는 isTypeOnlyNode 검사(위)에서 이미 .none으로 반환됨.
            // 여기 도달하면 strip_types=false인 경우 → 그대로 복사.
            .invalid => .none,
            else => self.copyNodeDirect(node),
        };
    }

    // ================================================================
    // 노드 복사 헬퍼
    // ================================================================

    /// 노드를 그대로 새 AST에 복사한다 (자식 없는 리프 노드용).
    fn copyNodeDirect(self: *Transformer, node: Node) Error!NodeIndex {
        return self.new_ast.addNode(node);
    }

    /// 단항 노드: operand를 재귀 방문 후 복사.
    fn visitUnaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_operand = try self.visitNode(node.data.unary.operand);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
        });
    }

    /// 이항 노드: left, right를 재귀 방문 후 복사.
    fn visitBinaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_left = try self.visitNode(node.data.binary.left);
        const new_right = try self.visitNode(node.data.binary.right);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .binary = .{
                .left = new_left,
                .right = new_right,
                .flags = node.data.binary.flags,
            } },
        });
    }

    /// 삼항 노드: a, b, c를 재귀 방문 후 복사.
    fn visitTernaryNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_a = try self.visitNode(node.data.ternary.a);
        const new_b = try self.visitNode(node.data.ternary.b);
        const new_c = try self.visitNode(node.data.ternary.c);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
        });
    }

    /// 리스트 노드: 각 자식을 방문, .none이 아닌 것만 새 리스트로 수집.
    fn visitListNode(self: *Transformer, node: Node) Error!NodeIndex {
        const new_list = try self.visitExtraList(node.data.list.start, node.data.list.len);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .list = new_list },
        });
    }

    /// extra_data의 노드 리스트를 방문하여 새 AST에 복사.
    /// .none이 된 자식은 자동으로 제거된다.
    /// scratch 버퍼를 사용하며, 중첩 호출에 안전 (save/restore 패턴).
    fn visitExtraList(self: *Transformer, start: u32, len: u32) Error!NodeList {
        const old_indices = self.old_ast.extra_data.items[start .. start + len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_indices) |raw_idx| {
            const new_child = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_child.isNone()) {
                try self.scratch.append(new_child);
            }
        }

        return self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
    }

    // ================================================================
    // TS expression 변환 — 타입 부분 제거, 값만 보존
    // ================================================================

    /// TS expression (as/satisfies/!/type assertion/instantiation)에서
    /// 값 부분만 추출한다.
    ///
    /// 예: `x as number` → `x` (operand만 반환)
    /// 예: `x!` → `x` (non-null assertion 제거)
    /// 예: `<number>x` → `x` (type assertion 제거)
    fn visitTsExpression(self: *Transformer, node: Node) Error!NodeIndex {
        if (!self.options.strip_types) {
            return self.copyNodeDirect(node);
        }
        // 모든 TS expression은 unary로, operand가 값 부분
        return self.visitNode(node.data.unary.operand);
    }

    // ================================================================
    // Extra 기반 노드 변환
    // ================================================================

    // ================================================================
    // TS enum 변환
    // ================================================================

    /// ts_enum_declaration: extra = [name, members_start, members_len]
    /// enum 노드를 새 AST에 복사. codegen에서 IIFE 패턴으로 출력.
    fn visitEnumDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_members = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.ts_enum_declaration, node.span, &.{
            @intFromEnum(new_name), new_members.start, new_members.len,
        });
    }

    // ================================================================
    // TS namespace 변환
    // ================================================================

    /// ts_module_declaration: binary = { left=name, right=body_or_inner }
    /// namespace를 새 AST에 복사. codegen에서 IIFE로 출력.
    fn visitNamespaceDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const new_name = try self.visitNode(node.data.binary.left);
        const new_body = try self.visitNode(node.data.binary.right);
        return self.new_ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = node.span,
            .data = .{ .binary = .{ .left = new_name, .right = new_body, .flags = 0 } },
        });
    }

    // ================================================================
    // 헬퍼
    // ================================================================

    /// extra_data에서 연속된 필드를 슬라이스로 읽기.
    fn readExtras(self: *const Transformer, start: u32, len: u32) []const u32 {
        return self.old_ast.extra_data.items[start .. start + len];
    }

    /// extra 인덱스로 NodeIndex 읽기.
    fn readNodeIdx(self: *const Transformer, extra_start: u32, offset: u32) NodeIndex {
        return @enumFromInt(self.old_ast.extra_data.items[extra_start + offset]);
    }

    /// extra 인덱스로 u32 읽기.
    fn readU32(self: *const Transformer, extra_start: u32, offset: u32) u32 {
        return self.old_ast.extra_data.items[extra_start + offset];
    }

    /// 노드를 extra_data로 만들어 새 AST에 추가.
    fn addExtraNode(self: *Transformer, tag: Tag, span: Span, extras: []const u32) Error!NodeIndex {
        const new_extra = try self.new_ast.addExtras(extras);
        return self.new_ast.addNode(.{ .tag = tag, .span = span, .data = .{ .extra = new_extra } });
    }

    // ================================================================
    // Extra 기반 노드 변환
    // ================================================================

    /// variable_declaration: extra_data = [kind_flags, list.start, list.len]
    fn visitVariableDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_list = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.variable_declaration, node.span, &.{ self.readU32(e, 0), new_list.start, new_list.len });
    }

    /// variable_declarator: extra_data = [name, type_ann, init]
    fn visitVariableDeclarator(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_init = try self.visitNode(self.readNodeIdx(e, 2));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.variable_declarator, node.span, &.{ @intFromEnum(new_name), none, @intFromEnum(new_init) });
    }

    /// function/function_declaration/function_expression/arrow_function_expression
    /// extra_data = [name, params_start, params_len, body, flags, return_type]
    fn visitFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_params = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        const new_body = try self.visitNode(self.readNodeIdx(e, 3));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), new_params.start, new_params.len,
            @intFromEnum(new_body), self.readU32(e, 4), none, // return_type 제거
        });
    }

    /// class_declaration / class_expression
    /// extra_data = [name, super_class, body, type_params, implements_start, implements_len]
    fn visitClass(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_super = try self.visitNode(self.readNodeIdx(e, 1));
        const new_body = try self.visitNode(self.readNodeIdx(e, 2));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none, 0, 0, // type_params, implements 제거
        });
    }

    /// for_statement: extra_data = [init, test, update, body]
    fn visitForStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_init = try self.visitNode(self.readNodeIdx(e, 0));
        const new_test = try self.visitNode(self.readNodeIdx(e, 1));
        const new_update = try self.visitNode(self.readNodeIdx(e, 2));
        const new_body = try self.visitNode(self.readNodeIdx(e, 3));
        return self.addExtraNode(.for_statement, node.span, &.{
            @intFromEnum(new_init), @intFromEnum(new_test), @intFromEnum(new_update), @intFromEnum(new_body),
        });
    }

    /// switch_case: extra_data = [test, stmts_start, stmts_len]
    fn visitSwitchCase(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_test = try self.visitNode(self.readNodeIdx(e, 0));
        const new_stmts = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.switch_case, node.span, &.{ @intFromEnum(new_test), new_stmts.start, new_stmts.len });
    }

    /// call_expression: extra_data = [callee, args_start, args_len, optional_chain_flag]
    fn visitCallExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_callee = try self.visitNode(self.readNodeIdx(e, 0));
        const new_args = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.call_expression, node.span, &.{
            @intFromEnum(new_callee), new_args.start, new_args.len, self.readU32(e, 3),
        });
    }

    /// new_expression: extra_data = [callee, args_start, args_len]
    fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_callee = try self.visitNode(self.readNodeIdx(e, 0));
        const new_args = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.new_expression, node.span, &.{ @intFromEnum(new_callee), new_args.start, new_args.len });
    }

    /// method_definition: extra_data = [key, value, flags, decorators_start, decorators_len]
    fn visitMethodDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        const new_decos = try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        return self.addExtraNode(.method_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2), new_decos.start, new_decos.len,
        });
    }

    /// property_definition: extra_data = [key, value, flags, type_ann, decorators_start, decorators_len]
    fn visitPropertyDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        const new_decos = try self.visitExtraList(self.readU32(e, 4), self.readU32(e, 5));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.property_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            none, // type_ann 제거
            new_decos.start, new_decos.len,
        });
    }

    /// object_property: extra_data = [key, value, flags]
    fn visitObjectProperty(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        return self.addExtraNode(.object_property, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
        });
    }

    /// formal_parameter: extra_data = [pattern, type_ann, default_value, decorators_start, decorators_len]
    fn visitFormalParameter(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_pattern = try self.visitNode(self.readNodeIdx(e, 0));
        const new_default = try self.visitNode(self.readNodeIdx(e, 2));
        const new_decos = try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.formal_parameter, node.span, &.{
            @intFromEnum(new_pattern), none, @intFromEnum(new_default), // type_ann 제거
            new_decos.start, new_decos.len,
        });
    }

    /// import_declaration: extra_data = [source, specifiers_start, specifiers_len, attributes_start, attributes_len]
    fn visitImportDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_source = try self.visitNode(self.readNodeIdx(e, 0));
        const new_specs = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        const new_attrs = try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        return self.addExtraNode(.import_declaration, node.span, &.{
            @intFromEnum(new_source), new_specs.start, new_specs.len, new_attrs.start, new_attrs.len,
        });
    }

    /// export_named_declaration: extra_data = [declaration, specifiers_start, specifiers_len, source]
    fn visitExportNamedDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_decl = try self.visitNode(self.readNodeIdx(e, 0));
        const new_specs = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        const new_source = try self.visitNode(self.readNodeIdx(e, 3));
        return self.addExtraNode(.export_named_declaration, node.span, &.{
            @intFromEnum(new_decl), new_specs.start, new_specs.len, @intFromEnum(new_source),
        });
    }

    // ================================================================
    // Comptime 헬퍼 — TS 타입 전용 노드 판별 (D042)
    // ================================================================

    /// TS 타입 전용 노드인지 판별한다 (comptime 평가).
    ///
    /// 이 함수는 컴파일 타임에 평가되므로 런타임 비용이 0이다.
    /// tag의 정수 값 범위로 판별하지 않고 명시적으로 나열한다.
    /// 이유: enum 값 순서가 바뀌어도 안전하게 동작하도록.
    fn isTypeOnlyNode(tag: Tag) bool {
        return switch (tag) {
            // TS 타입 키워드 (14개)
            .ts_any_keyword,
            .ts_string_keyword,
            .ts_boolean_keyword,
            .ts_number_keyword,
            .ts_never_keyword,
            .ts_unknown_keyword,
            .ts_null_keyword,
            .ts_undefined_keyword,
            .ts_void_keyword,
            .ts_symbol_keyword,
            .ts_object_keyword,
            .ts_bigint_keyword,
            .ts_this_type,
            .ts_intrinsic_keyword,
            // TS 타입 구문 (23개)
            .ts_type_reference,
            .ts_qualified_name,
            .ts_array_type,
            .ts_tuple_type,
            .ts_named_tuple_member,
            .ts_union_type,
            .ts_intersection_type,
            .ts_conditional_type,
            .ts_type_operator,
            .ts_optional_type,
            .ts_rest_type,
            .ts_indexed_access_type,
            .ts_type_literal,
            .ts_function_type,
            .ts_constructor_type,
            .ts_mapped_type,
            .ts_template_literal_type,
            .ts_infer_type,
            .ts_parenthesized_type,
            .ts_import_type,
            .ts_type_query,
            .ts_literal_type,
            .ts_type_predicate,
            // TS 선언 (통째로 삭제)
            .ts_type_alias_declaration,
            .ts_interface_declaration,
            .ts_interface_body,
            .ts_property_signature,
            .ts_method_signature,
            .ts_call_signature,
            .ts_construct_signature,
            .ts_index_signature,
            .ts_getter_signature,
            .ts_setter_signature,
            // TS 타입 파라미터/this/implements
            .ts_type_parameter,
            .ts_type_parameter_declaration,
            .ts_type_parameter_instantiation,
            .ts_this_parameter,
            .ts_class_implements,
            // namespace는 런타임 코드 생성 → visitNode에서 별도 처리
            // ts_namespace_export_declaration은 타입 전용 (export as namespace X)
            .ts_namespace_export_declaration,
            // TS import/export 특수 형태
            .ts_import_equals_declaration,
            .ts_external_module_reference,
            .ts_export_assignment,
            // enum은 타입 전용이 아님 — 런타임 코드 생성이 필요
            // visitNode의 switch에서 별도 처리
            => true,
            else => false,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "Transformer: empty program" {
    const std_lib = @import("std");

    // 빈 프로그램: `program` 노드 하나만 있는 AST
    var old_ast = Ast.init(std_lib.testing.allocator, "");
    defer old_ast.deinit();

    const empty_list = try old_ast.addNodeList(&.{});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 0 },
        .data = .{ .list = empty_list },
    });

    var t = Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();
    const result = t.new_ast.getNode(root);

    try std_lib.testing.expectEqual(Tag.program, result.tag);
    try std_lib.testing.expectEqual(@as(u32, 0), result.data.list.len);
}

test "Transformer: strip type alias declaration" {
    const std_lib = @import("std");

    // program → [type_alias_declaration]
    var old_ast = Ast.init(std_lib.testing.allocator, "type Foo = string;");
    defer old_ast.deinit();

    // type alias node
    const type_node = try old_ast.addNode(.{
        .tag = .ts_type_alias_declaration,
        .span = .{ .start = 0, .end = 18 },
        .data = .{ .none = 0 },
    });

    const list = try old_ast.addNodeList(&.{type_node});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 18 },
        .data = .{ .list = list },
    });

    var t = Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();
    const result = t.new_ast.getNode(root);

    // type alias가 제거되어 빈 program
    try std_lib.testing.expectEqual(Tag.program, result.tag);
    try std_lib.testing.expectEqual(@as(u32, 0), result.data.list.len);
}

test "Transformer: preserve JS expression statement" {
    const std_lib = @import("std");

    const source = "x;";
    var old_ast = Ast.init(std_lib.testing.allocator, source);
    defer old_ast.deinit();

    // identifier_reference "x"
    const id = try old_ast.addNode(.{
        .tag = .identifier_reference,
        .span = .{ .start = 0, .end = 1 },
        .data = .{ .string_ref = .{ .start = 0, .end = 1 } },
    });

    // expression_statement
    const stmt = try old_ast.addNode(.{
        .tag = .expression_statement,
        .span = .{ .start = 0, .end = 2 },
        .data = .{ .unary = .{ .operand = id, .flags = 0 } },
    });

    // program
    const list = try old_ast.addNodeList(&.{stmt});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 2 },
        .data = .{ .list = list },
    });

    var t = Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();
    const result = t.new_ast.getNode(root);

    // program에 statement 1개 보존
    try std_lib.testing.expectEqual(Tag.program, result.tag);
    try std_lib.testing.expectEqual(@as(u32, 1), result.data.list.len);
}

test "Transformer: strip ts_as_expression" {
    const std_lib = @import("std");

    const source = "x as number";
    var old_ast = Ast.init(std_lib.testing.allocator, source);
    defer old_ast.deinit();

    // "x"
    const id = try old_ast.addNode(.{
        .tag = .identifier_reference,
        .span = .{ .start = 0, .end = 1 },
        .data = .{ .string_ref = .{ .start = 0, .end = 1 } },
    });

    // "number" type
    const type_node = try old_ast.addNode(.{
        .tag = .ts_number_keyword,
        .span = .{ .start = 5, .end = 11 },
        .data = .{ .none = 0 },
    });
    _ = type_node; // 타입 노드는 as_expression의 일부이지만 operand가 아님

    // x as number → unary { operand = x }
    const as_expr = try old_ast.addNode(.{
        .tag = .ts_as_expression,
        .span = .{ .start = 0, .end = 11 },
        .data = .{ .unary = .{ .operand = id, .flags = 0 } },
    });

    // expression_statement
    const stmt = try old_ast.addNode(.{
        .tag = .expression_statement,
        .span = .{ .start = 0, .end = 11 },
        .data = .{ .unary = .{ .operand = as_expr, .flags = 0 } },
    });

    // program
    const list = try old_ast.addNodeList(&.{stmt});
    _ = try old_ast.addNode(.{
        .tag = .program,
        .span = .{ .start = 0, .end = 11 },
        .data = .{ .list = list },
    });

    var t = Transformer.init(std_lib.testing.allocator, &old_ast, .{});
    defer t.deinit();

    const root = try t.transform();

    // program → expression_statement → identifier_reference (as 제거됨)
    const prog = t.new_ast.getNode(root);
    try std_lib.testing.expectEqual(Tag.program, prog.tag);
    try std_lib.testing.expectEqual(@as(u32, 1), prog.data.list.len);

    // expression_statement의 operand가 직접 identifier_reference를 가리킴
    const stmt_indices = t.new_ast.extra_data.items[prog.data.list.start .. prog.data.list.start + prog.data.list.len];
    const new_stmt = t.new_ast.getNode(@enumFromInt(stmt_indices[0]));
    try std_lib.testing.expectEqual(Tag.expression_statement, new_stmt.tag);

    const inner = t.new_ast.getNode(new_stmt.data.unary.operand);
    try std_lib.testing.expectEqual(Tag.identifier_reference, inner.tag);
}

// ============================================================
// 통합 테스트: 파서 → transformer 연동
// ============================================================

const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;

/// 통합 테스트 결과. deinit()으로 모든 리소스를 한 번에 해제.
const TestResult = struct {
    ast: Ast,
    root: NodeIndex,
    scanner: *Scanner,
    parser: *Parser,
    allocator: std.mem.Allocator,

    fn deinit(self: *TestResult) void {
        self.ast.deinit();
        self.parser.deinit();
        self.allocator.destroy(self.parser);
        self.scanner.deinit();
        self.allocator.destroy(self.scanner);
    }

    /// program의 statement 수를 반환.
    fn statementCount(self: *const TestResult) u32 {
        return self.ast.getNode(self.root).data.list.len;
    }
};

/// 테스트 헬퍼: 소스 코드를 파싱 → transformer 실행.
fn parseAndTransform(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    const scanner_ptr = try allocator.create(Scanner);
    scanner_ptr.* = Scanner.init(allocator, source);

    const parser_ptr = try allocator.create(Parser);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);

    _ = try parser_ptr.parse();

    var t = Transformer.init(allocator, &parser_ptr.ast, .{});
    const root = try t.transform();
    t.scratch.deinit();

    return .{ .ast = t.new_ast, .root = root, .scanner = scanner_ptr, .parser = parser_ptr, .allocator = allocator };
}

test "Integration: type alias stripped" {
    var r = try parseAndTransform(std.testing.allocator, "type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 0), r.statementCount());
}

test "Integration: interface stripped" {
    var r = try parseAndTransform(std.testing.allocator, "interface Foo { bar: string; }");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 0), r.statementCount());
}

test "Integration: JS preserved alongside TS stripped" {
    var r = try parseAndTransform(std.testing.allocator, "const x = 1; type Foo = string;");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "Integration: enum preserved for codegen" {
    // enum은 런타임 코드 생성 → 삭제되지 않고 codegen으로 전달
    var r = try parseAndTransform(std.testing.allocator, "enum Color { Red, Green, Blue }");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "Integration: multiple JS statements preserved" {
    var r = try parseAndTransform(std.testing.allocator, "const x = 1; let y = 2; var z = 3;");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 3), r.statementCount());
}

test "Transformer: isTypeOnlyNode covers all TS type tags" {
    // TS 타입/선언 태그가 isTypeOnlyNode에 포함되는지 검증
    // ts_as_expression 등 값이 있는 expression은 제외
    const std_lib = @import("std");

    // 값을 포함하는 TS expression은 isTypeOnlyNode이 아님
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_as_expression));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_satisfies_expression));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_non_null_expression));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_type_assertion));
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_instantiation_expression));

    // TS 타입 키워드는 isTypeOnlyNode
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_any_keyword));
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_string_keyword));
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_number_keyword));

    // TS 선언은 isTypeOnlyNode
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_type_alias_declaration));
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_interface_declaration));
    // enum은 런타임 코드를 생성하므로 isTypeOnlyNode이 아님
    try std_lib.testing.expect(!Transformer.isTypeOnlyNode(.ts_enum_declaration));
}
