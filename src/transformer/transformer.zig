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
            .tagged_template_expression => self.visitTaggedTemplate(node),
            .method_definition => self.visitMethodDefinition(node),
            .property_definition => self.visitPropertyDefinition(node),
            .object_property => self.visitObjectProperty(node),
            .formal_parameter => self.visitFormalParameter(node),
            .import_declaration => self.visitImportDeclaration(node),
            .export_named_declaration => self.visitExportNamedDeclaration(node),
            .export_default_declaration => self.visitExportDefaultDeclaration(node),
            .export_all_declaration => self.visitExportAllDeclaration(node),
            .catch_clause => self.visitCatchClause(node),
            .binding_property => self.visitBindingProperty(node),
            .assignment_pattern => self.visitAssignmentPattern(node),
            .accessor_property => self.visitAccessorProperty(node),

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

            // === TS 선언 노드: 통째로 삭제 ===
            // (isTypeOnlyNode에서 이미 걸러지지만, 혹시 모를 누락 방지)
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
            .ts_module_declaration,
            .ts_module_block,
            .ts_namespace_export_declaration,
            .ts_type_parameter,
            .ts_type_parameter_declaration,
            .ts_type_parameter_instantiation,
            .ts_this_parameter,
            .ts_class_implements,
            .ts_export_assignment,
            .ts_import_equals_declaration,
            .ts_external_module_reference,
            => if (self.options.strip_types) .none else self.copyNodeDirect(node),

            // === TS enum/const enum: 향후 IIFE 변환. 지금은 삭제 ===
            .ts_enum_declaration,
            .ts_enum_body,
            .ts_enum_member,
            => if (self.options.strip_types) .none else self.copyNodeDirect(node),

            // === 모든 TS 타입 노드: 삭제 (isTypeOnlyNode에서 처리됨) ===
            // 여기에 도달하면 strip_types=false인 경우
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
            => self.copyNodeDirect(node),

            // === 나머지: invalid 등 ===
            .invalid => .none,

            // 누락된 태그가 있으면 컴파일 에러
            // (새 태그 추가 시 여기서 잡힘)
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
    ///
    /// TS 타입 노드가 리스트 안에 있으면 자연스럽게 제거된다.
    /// 예: program의 statement 중 `type Foo = ...` 같은 것은 visitNode에서
    ///     .none을 반환하므로 새 리스트에서 빠진다.
    fn visitListNode(self: *Transformer, node: Node) Error!NodeIndex {
        const old_list = node.data.list;
        const old_indices = self.old_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_indices) |raw_idx| {
            const child_idx: NodeIndex = @enumFromInt(raw_idx);
            const new_child = try self.visitNode(child_idx);
            if (!new_child.isNone()) {
                try self.scratch.append(new_child);
            }
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .list = new_list },
        });
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

    /// variable_declaration: extra_data = [kind_flags, list.start, list.len]
    fn visitVariableDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const kind_flags = self.old_ast.extra_data.items[extra_start];
        const list_start = self.old_ast.extra_data.items[extra_start + 1];
        const list_len = self.old_ast.extra_data.items[extra_start + 2];

        const old_indices = self.old_ast.extra_data.items[list_start .. list_start + list_len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_indices) |raw_idx| {
            const new_child = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_child.isNone()) {
                try self.scratch.append(new_child);
            }
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(kind_flags);
        _ = try self.new_ast.addExtra(new_list.start);
        _ = try self.new_ast.addExtra(new_list.len);

        return self.new_ast.addNode(.{
            .tag = .variable_declaration,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// variable_declarator: extra_data = [name, type_ann, init]
    /// type_ann은 TS에서만 사용 → 제거.
    fn visitVariableDeclarator(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const name_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        // type_ann (extra_start + 1)은 스킵
        const init_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 2]);

        const new_name = try self.visitNode(name_idx);
        const new_init = try self.visitNode(init_idx);

        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_name));
        _ = try self.new_ast.addExtra(@intFromEnum(NodeIndex.none)); // type_ann 제거
        _ = try self.new_ast.addExtra(@intFromEnum(new_init));

        return self.new_ast.addNode(.{
            .tag = .variable_declarator,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// function/function_declaration/function_expression/arrow_function_expression
    /// extra_data = [name, params_start, params_len, body, flags, return_type]
    fn visitFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const name_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const params_start = self.old_ast.extra_data.items[extra_start + 1];
        const params_len = self.old_ast.extra_data.items[extra_start + 2];
        const body_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 3]);
        const flags = self.old_ast.extra_data.items[extra_start + 4];
        // return_type (extra_start + 5)는 TS 전용 → 스킵

        // 이름 방문
        const new_name = try self.visitNode(name_idx);

        // 파라미터 방문 (ts_this_parameter는 visitNode에서 .none으로 필터됨)
        const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_params) |raw_idx| {
            const new_param = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_param.isNone()) {
                try self.scratch.append(new_param);
            }
        }

        // 바디 방문
        const new_body = try self.visitNode(body_idx);

        const new_params = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_name));
        _ = try self.new_ast.addExtra(new_params.start);
        _ = try self.new_ast.addExtra(new_params.len);
        _ = try self.new_ast.addExtra(@intFromEnum(new_body));
        _ = try self.new_ast.addExtra(flags);
        _ = try self.new_ast.addExtra(@intFromEnum(NodeIndex.none)); // return_type 제거

        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// class_declaration / class_expression
    /// extra_data = [name, super_class, body, type_params, implements_start, implements_len]
    fn visitClass(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const name_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const super_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 1]);
        const body_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 2]);
        // type_params (extra_start + 3)은 TS → 스킵
        // implements (extra_start + 4, +5)은 TS → 스킵

        const new_name = try self.visitNode(name_idx);
        const new_super = try self.visitNode(super_idx);
        const new_body = try self.visitNode(body_idx);

        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_name));
        _ = try self.new_ast.addExtra(@intFromEnum(new_super));
        _ = try self.new_ast.addExtra(@intFromEnum(new_body));
        _ = try self.new_ast.addExtra(@intFromEnum(NodeIndex.none)); // type_params 제거
        _ = try self.new_ast.addExtra(0); // implements_start = 0
        _ = try self.new_ast.addExtra(0); // implements_len = 0

        return self.new_ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// for_statement: extra_data = [init, test, update, body]
    fn visitForStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const init_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const test_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 1]);
        const update_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 2]);
        const body_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 3]);

        const new_init = try self.visitNode(init_idx);
        const new_test = try self.visitNode(test_idx);
        const new_update = try self.visitNode(update_idx);
        const new_body = try self.visitNode(body_idx);

        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_init));
        _ = try self.new_ast.addExtra(@intFromEnum(new_test));
        _ = try self.new_ast.addExtra(@intFromEnum(new_update));
        _ = try self.new_ast.addExtra(@intFromEnum(new_body));

        return self.new_ast.addNode(.{
            .tag = .for_statement,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// switch_case: extra_data = [test, stmts_start, stmts_len]
    fn visitSwitchCase(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const test_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const stmts_start = self.old_ast.extra_data.items[extra_start + 1];
        const stmts_len = self.old_ast.extra_data.items[extra_start + 2];

        const new_test = try self.visitNode(test_idx);

        const old_stmts = self.old_ast.extra_data.items[stmts_start .. stmts_start + stmts_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_stmts) |raw_idx| {
            const new_stmt = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_stmt.isNone()) {
                try self.scratch.append(new_stmt);
            }
        }

        const new_stmts = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_test));
        _ = try self.new_ast.addExtra(new_stmts.start);
        _ = try self.new_ast.addExtra(new_stmts.len);

        return self.new_ast.addNode(.{
            .tag = .switch_case,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// call_expression: extra_data = [callee, args_start, args_len, optional_chain_flag]
    fn visitCallExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const callee_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const args_start = self.old_ast.extra_data.items[extra_start + 1];
        const args_len = self.old_ast.extra_data.items[extra_start + 2];
        const opt_chain = self.old_ast.extra_data.items[extra_start + 3];

        const new_callee = try self.visitNode(callee_idx);

        const old_args = self.old_ast.extra_data.items[args_start .. args_start + args_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_args) |raw_idx| {
            const new_arg = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_arg.isNone()) {
                try self.scratch.append(new_arg);
            }
        }

        const new_args = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_callee));
        _ = try self.new_ast.addExtra(new_args.start);
        _ = try self.new_ast.addExtra(new_args.len);
        _ = try self.new_ast.addExtra(opt_chain);

        return self.new_ast.addNode(.{
            .tag = .call_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// new_expression: extra_data = [callee, args_start, args_len]
    fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const callee_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const args_start = self.old_ast.extra_data.items[extra_start + 1];
        const args_len = self.old_ast.extra_data.items[extra_start + 2];

        const new_callee = try self.visitNode(callee_idx);

        const old_args = self.old_ast.extra_data.items[args_start .. args_start + args_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_args) |raw_idx| {
            const new_arg = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_arg.isNone()) {
                try self.scratch.append(new_arg);
            }
        }

        const new_args = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_callee));
        _ = try self.new_ast.addExtra(new_args.start);
        _ = try self.new_ast.addExtra(new_args.len);

        return self.new_ast.addNode(.{
            .tag = .new_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// tagged_template_expression: binary = { left=tag, right=template }
    fn visitTaggedTemplate(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitBinaryNode(node);
    }

    /// method_definition: extra_data = [key, value, flags, decorators_start, decorators_len]
    fn visitMethodDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const key_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const value_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 1]);
        const flags = self.old_ast.extra_data.items[extra_start + 2];
        const deco_start = self.old_ast.extra_data.items[extra_start + 3];
        const deco_len = self.old_ast.extra_data.items[extra_start + 4];

        const new_key = try self.visitNode(key_idx);
        const new_value = try self.visitNode(value_idx);

        // decorator 리스트 방문
        const old_decos = self.old_ast.extra_data.items[deco_start .. deco_start + deco_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_decos) |raw_idx| {
            const new_deco = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_deco.isNone()) {
                try self.scratch.append(new_deco);
            }
        }

        const new_decos = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_key));
        _ = try self.new_ast.addExtra(@intFromEnum(new_value));
        _ = try self.new_ast.addExtra(flags);
        _ = try self.new_ast.addExtra(new_decos.start);
        _ = try self.new_ast.addExtra(new_decos.len);

        return self.new_ast.addNode(.{
            .tag = .method_definition,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// property_definition: extra_data = [key, value, flags, type_ann, decorators_start, decorators_len]
    fn visitPropertyDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const key_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const value_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 1]);
        const flags = self.old_ast.extra_data.items[extra_start + 2];
        // type_ann (extra_start + 3)은 TS → 스킵
        const deco_start = self.old_ast.extra_data.items[extra_start + 4];
        const deco_len = self.old_ast.extra_data.items[extra_start + 5];

        const new_key = try self.visitNode(key_idx);
        const new_value = try self.visitNode(value_idx);

        // decorator 리스트 방문
        const old_decos = self.old_ast.extra_data.items[deco_start .. deco_start + deco_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_decos) |raw_idx| {
            const new_deco = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_deco.isNone()) {
                try self.scratch.append(new_deco);
            }
        }

        const new_decos = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_key));
        _ = try self.new_ast.addExtra(@intFromEnum(new_value));
        _ = try self.new_ast.addExtra(flags);
        _ = try self.new_ast.addExtra(@intFromEnum(NodeIndex.none)); // type_ann 제거
        _ = try self.new_ast.addExtra(new_decos.start);
        _ = try self.new_ast.addExtra(new_decos.len);

        return self.new_ast.addNode(.{
            .tag = .property_definition,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// object_property: extra_data = [key, value, flags]
    fn visitObjectProperty(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const key_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const value_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 1]);
        const flags = self.old_ast.extra_data.items[extra_start + 2];

        const new_key = try self.visitNode(key_idx);
        const new_value = try self.visitNode(value_idx);

        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_key));
        _ = try self.new_ast.addExtra(@intFromEnum(new_value));
        _ = try self.new_ast.addExtra(flags);

        return self.new_ast.addNode(.{
            .tag = .object_property,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// formal_parameter: extra_data = [pattern, type_ann, default_value, decorators_start, decorators_len]
    fn visitFormalParameter(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const pattern_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        // type_ann (extra_start + 1)은 TS → 스킵
        const default_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 2]);
        const deco_start = self.old_ast.extra_data.items[extra_start + 3];
        const deco_len = self.old_ast.extra_data.items[extra_start + 4];

        const new_pattern = try self.visitNode(pattern_idx);
        const new_default = try self.visitNode(default_idx);

        // decorator 리스트 방문
        const old_decos = self.old_ast.extra_data.items[deco_start .. deco_start + deco_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_decos) |raw_idx| {
            const new_deco = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_deco.isNone()) {
                try self.scratch.append(new_deco);
            }
        }

        const new_decos = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_pattern));
        _ = try self.new_ast.addExtra(@intFromEnum(NodeIndex.none)); // type_ann 제거
        _ = try self.new_ast.addExtra(@intFromEnum(new_default));
        _ = try self.new_ast.addExtra(new_decos.start);
        _ = try self.new_ast.addExtra(new_decos.len);

        return self.new_ast.addNode(.{
            .tag = .formal_parameter,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// import_declaration: extra_data = [source, specifiers_start, specifiers_len, attributes_start, attributes_len]
    fn visitImportDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const source_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const specs_start = self.old_ast.extra_data.items[extra_start + 1];
        const specs_len = self.old_ast.extra_data.items[extra_start + 2];
        const attrs_start = self.old_ast.extra_data.items[extra_start + 3];
        const attrs_len = self.old_ast.extra_data.items[extra_start + 4];

        const new_source = try self.visitNode(source_idx);

        // specifiers 복사
        const old_specs = self.old_ast.extra_data.items[specs_start .. specs_start + specs_len];
        const scratch_top = self.scratch.items.len;

        for (old_specs) |raw_idx| {
            const new_spec = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_spec.isNone()) {
                try self.scratch.append(new_spec);
            }
        }
        const new_specs = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        self.scratch.shrinkRetainingCapacity(scratch_top);

        // attributes 복사
        const old_attrs = self.old_ast.extra_data.items[attrs_start .. attrs_start + attrs_len];
        const scratch_top2 = self.scratch.items.len;

        for (old_attrs) |raw_idx| {
            const new_attr = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_attr.isNone()) {
                try self.scratch.append(new_attr);
            }
        }
        const new_attrs = try self.new_ast.addNodeList(self.scratch.items[scratch_top2..]);
        self.scratch.shrinkRetainingCapacity(scratch_top2);

        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_source));
        _ = try self.new_ast.addExtra(new_specs.start);
        _ = try self.new_ast.addExtra(new_specs.len);
        _ = try self.new_ast.addExtra(new_attrs.start);
        _ = try self.new_ast.addExtra(new_attrs.len);

        return self.new_ast.addNode(.{
            .tag = .import_declaration,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// export_named_declaration: extra_data = [declaration, specifiers_start, specifiers_len, source]
    fn visitExportNamedDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const extra_start = node.data.extra;
        const decl_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start]);
        const specs_start = self.old_ast.extra_data.items[extra_start + 1];
        const specs_len = self.old_ast.extra_data.items[extra_start + 2];
        const source_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[extra_start + 3]);

        const new_decl = try self.visitNode(decl_idx);
        const new_source = try self.visitNode(source_idx);

        // specifiers 복사
        const old_specs = self.old_ast.extra_data.items[specs_start .. specs_start + specs_len];
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        for (old_specs) |raw_idx| {
            const new_spec = try self.visitNode(@enumFromInt(raw_idx));
            if (!new_spec.isNone()) {
                try self.scratch.append(new_spec);
            }
        }
        const new_specs = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);

        const new_extra = try self.new_ast.addExtra(@intFromEnum(new_decl));
        _ = try self.new_ast.addExtra(new_specs.start);
        _ = try self.new_ast.addExtra(new_specs.len);
        _ = try self.new_ast.addExtra(@intFromEnum(new_source));

        return self.new_ast.addNode(.{
            .tag = .export_named_declaration,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// export_default_declaration: unary = { operand = declaration }
    fn visitExportDefaultDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitUnaryNode(node);
    }

    /// export_all_declaration: binary = { left = source, right = exported_name }
    fn visitExportAllDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitBinaryNode(node);
    }

    /// catch_clause: binary = { left = param, right = body }
    fn visitCatchClause(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitBinaryNode(node);
    }

    /// binding_property: binary = { left = key, right = value }
    fn visitBindingProperty(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitBinaryNode(node);
    }

    /// assignment_pattern: binary = { left = target, right = default_value }
    fn visitAssignmentPattern(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitBinaryNode(node);
    }

    /// accessor_property: extra_data와 유사, 지금은 binary 처리
    fn visitAccessorProperty(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitBinaryNode(node);
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
            // TS module/namespace 선언
            .ts_module_declaration,
            .ts_module_block,
            .ts_namespace_export_declaration,
            // TS import/export 특수 형태
            .ts_import_equals_declaration,
            .ts_external_module_reference,
            .ts_export_assignment,
            // TS enum (향후 IIFE 변환, 지금은 삭제)
            .ts_enum_declaration,
            .ts_enum_body,
            .ts_enum_member,
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
    try std_lib.testing.expect(Transformer.isTypeOnlyNode(.ts_enum_declaration));
}
