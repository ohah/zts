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

/// define 치환 엔트리. key=식별자 텍스트, value=치환 문자열.
pub const DefineEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Transformer 설정.
pub const TransformOptions = struct {
    /// TS 타입 스트리핑 활성화 (기본: true)
    strip_types: bool = true,
    /// console.* 호출 제거 (--drop=console)
    drop_console: bool = false,
    /// debugger 문 제거 (--drop=debugger)
    drop_debugger: bool = false,
    /// define 글로벌 치환 (D020). 예: process.env.NODE_ENV → "production"
    define: []const DefineEntry = &.{},
    /// React Fast Refresh 활성화. 컴포넌트에 $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
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

    /// allocator (ArrayList 호출에 필요)
    allocator: std.mem.Allocator,

    /// 임시 버퍼 (리스트 변환 시 재사용)
    scratch: std.ArrayList(NodeIndex),

    /// 보류 노드 버퍼 (1→N 노드 확장용).
    /// enum/namespace 변환 시 원래 노드 앞에 삽입할 문장(예: `var Color;`)을 저장.
    /// visitExtraList가 각 자식 방문 후 이 버퍼를 드레인하여 리스트에 삽입한다.
    pending_nodes: std.ArrayList(NodeIndex),

    /// 원본 AST의 symbol_ids (semantic analyzer가 생성). null이면 전파 안 함.
    old_symbol_ids: []const ?u32 = &.{},
    /// 새 AST 기준 symbol_ids. new_ast에 노드 추가 시 자동 전파.
    new_symbol_ids: std.ArrayList(?u32) = .empty,

    /// define value의 string_table Span 캐시. options.define과 동일 인덱스.
    /// transform() 시작 시 한 번 빌드하여, tryDefineReplace에서 addString 중복 호출을 방지.
    define_spans: []Span = &.{},

    /// React Fast Refresh: 감지된 컴포넌트 등록 목록.
    /// transform 완료 후 프로그램 끝에 $RefreshReg$ 호출로 주입.
    refresh_registrations: std.ArrayList(RefreshRegistration) = .empty,

    /// React Fast Refresh: Hook 시그니처 등록 목록.
    /// 프로그램 끝에 var _s = $RefreshSig$(); + _s(Component, "sig") 호출로 주입.
    refresh_signatures: std.ArrayList(RefreshSignature) = .empty,

    const RefreshRegistration = struct {
        /// _c / _c2 핸들 변수의 string_table Span (재사용)
        handle_span: Span,
        /// 컴포넌트 이름 (문자열)
        name: []const u8,
    };

    const RefreshSignature = struct {
        /// _s / _s2 핸들 변수의 string_table Span
        handle_span: Span,
        /// 컴포넌트 이름 (문자열)
        component_name: []const u8,
        /// Hook 시그니처 문자열 ("useState{[foo, setFoo](0)}\nuseEffect{}")
        signature: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, old_ast: *const Ast, options: TransformOptions) Transformer {
        return .{
            .old_ast = old_ast,
            .new_ast = Ast.init(allocator, old_ast.source),
            .options = options,
            .allocator = allocator,
            .scratch = .empty,
            .pending_nodes = .empty,
        };
    }

    pub fn deinit(self: *Transformer) void {
        self.new_ast.deinit();
        self.scratch.deinit(self.allocator);
        self.pending_nodes.deinit(self.allocator);
        if (self.define_spans.len > 0) self.allocator.free(self.define_spans);
        self.refresh_registrations.deinit(self.allocator);
        for (self.refresh_signatures.items) |s| self.allocator.free(s.signature);
        self.refresh_signatures.deinit(self.allocator);
    }

    // ================================================================
    // 공개 API
    // ================================================================

    /// 변환을 실행한다. 원본 AST의 마지막 노드(program)부터 시작.
    ///
    /// 반환값: 새 AST에서의 루트 NodeIndex.
    /// 변환된 AST는 self.new_ast에 저장된다.
    pub fn transform(self: *Transformer) Error!NodeIndex {
        // define value를 미리 string_table에 저장하여 tryDefineReplace에서 중복 addString 방지
        if (self.options.define.len > 0) {
            self.define_spans = self.allocator.alloc(Span, self.options.define.len) catch return Error.OutOfMemory;
            for (self.options.define, 0..) |entry, i| {
                self.define_spans[i] = self.new_ast.addString(entry.value) catch return Error.OutOfMemory;
            }
        }

        // 파서는 parse() 끝에 program 노드를 추가하므로 마지막 노드가 루트
        const root_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(self.old_ast.nodes.items.len - 1)));
        const root = try self.visitNode(root_idx);

        // React Fast Refresh: 컴포넌트 등록 + Hook 시그니처 코드를 프로그램 끝에 추가
        if (self.options.react_refresh and
            (self.refresh_registrations.items.len > 0 or self.refresh_signatures.items.len > 0))
        {
            return try self.appendRefreshRegistrations(root);
        }

        return root;
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
        const new_idx = try self.visitNodeInner(idx);
        // symbol_id 전파: 원본 node_idx → 새 node_idx
        self.propagateSymbolId(idx, new_idx);
        return new_idx;
    }

    fn visitNodeInner(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
        const node = self.old_ast.getNode(idx);

        // --------------------------------------------------------
        // 1단계: TS 타입 전용 노드는 통째로 삭제
        // --------------------------------------------------------
        if (self.options.strip_types and isTypeOnlyNode(node.tag)) {
            return .none;
        }

        // --------------------------------------------------------
        // 2단계: --drop 처리
        // --------------------------------------------------------
        if (self.options.drop_debugger and node.tag == .debugger_statement) {
            return .none;
        }
        if (self.options.drop_console and node.tag == .expression_statement) {
            if (self.isConsoleCall(node)) return .none;
        }

        // --------------------------------------------------------
        // 3단계: define 글로벌 치환
        // --------------------------------------------------------
        if (self.options.define.len > 0) {
            if (self.tryDefineReplace(node)) |new_node| {
                return try new_node;
            }
        }

        // --------------------------------------------------------
        // 4단계: 태그별 분기 (switch 기반 visitor)
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
            .template_literal,
            // JSX — fragment는 .list, element/opening_element는 .extra
            .jsx_fragment,
            .function_body,
            => self.visitListNode(node),

            // JSX element/opening_element: .extra 형식 (tag, attrs, children)
            .jsx_element => self.visitJSXElement(node),
            .jsx_opening_element => self.visitJSXOpeningElement(node),

            // === 단항 노드: 자식 1개 재귀 방문 ===
            .expression_statement,
            .return_statement,
            .throw_statement,
            .spread_element,
            .parenthesized_expression,
            .await_expression,
            .yield_expression,
            .rest_element,
            .decorator,
            // JSX
            .jsx_spread_attribute,
            .jsx_expression_container,
            .jsx_spread_child,
            .chain_expression,
            .computed_property_key,
            .break_statement,
            .continue_statement,
            .import_expression,
            .static_block,
            => self.visitUnaryNode(node),

            // === 이항 노드: 자식 2개 재귀 방문 ===
            .binary_expression,
            .logical_expression,
            .assignment_expression,
            .while_statement,
            .do_while_statement,
            .labeled_statement,
            .with_statement,
            // JSX
            .jsx_attribute,
            .jsx_namespaced_name,
            .jsx_member_expression,
            => self.visitBinaryNode(node),

            // === member expression: extra = [object, property, flags] ===
            .static_member_expression,
            .computed_member_expression,
            .private_field_expression,
            => self.visitMemberExpression(node),

            // === unary/update expression: extra = [operand, operator_and_flags] ===
            .unary_expression,
            .update_expression,
            => self.visitUnaryExtra(node),

            // === 삼항 노드: 자식 3개 재귀 방문 ===
            .if_statement,
            .conditional_expression,
            .for_in_statement,
            .for_of_statement,
            .for_await_of_statement,
            .try_statement,
            => self.visitTernaryNode(node),

            // === extra 기반 노드: 별도 처리 ===
            .variable_declaration => self.visitVariableDeclaration(node),
            .variable_declarator => self.visitVariableDeclarator(node),
            .function_declaration,
            .function_expression,
            .function,
            => self.visitFunction(node),
            .arrow_function_expression => self.visitArrowFunction(node),
            .class_declaration,
            .class_expression,
            => self.visitClass(node),
            .for_statement => self.visitForStatement(node),
            .switch_statement => self.visitSwitchStatement(node),
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
            .export_default_declaration => self.visitUnaryNode(node),
            .export_all_declaration,
            .catch_clause,
            .binding_property,
            .assignment_pattern,
            => self.visitBinaryNode(node),
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
            .directive,
            .hashbang,
            .super_expression,
            .meta_property,
            .template_element,
            .elision,
            // JSX leaf
            .jsx_text,
            .jsx_empty_expression,
            .jsx_identifier,
            .jsx_closing_element,
            .jsx_opening_fragment,
            .jsx_closing_fragment,
            .assignment_target_identifier,
            => self.copyNodeDirect(node),

            // === import/export specifiers ===
            .import_specifier => if (node.data.binary.flags & 1 != 0) .none else self.visitBinaryNode(node),
            .export_specifier => self.visitBinaryNode(node),
            // default/namespace specifier는 string_ref(span) 복사 — 자식 노드 없음
            .import_default_specifier,
            .import_namespace_specifier,
            .import_attribute,
            => self.copyNodeDirect(node),

            // === Pattern 노드: 자식 재귀 방문 ===
            .array_pattern,
            .object_pattern,
            .array_assignment_target,
            .object_assignment_target,
            => self.visitListNode(node),

            .binding_rest_element,
            .assignment_target_rest,
            => self.visitUnaryNode(node),
            .assignment_target_with_default,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            => self.visitBinaryNode(node),
            // assignment_target_identifier: string_ref → 변환 불필요 (identifier와 동일)

            // === TS enum/namespace: 런타임 코드 생성 (codegen에서 IIFE 출력) ===
            .ts_enum_declaration => self.visitEnumDeclaration(node),
            .ts_enum_member => self.visitBinaryNode(node),
            .ts_enum_body => self.visitListNode(node),
            .ts_module_declaration => self.visitNamespaceDeclaration(node),
            .ts_module_block => self.visitListNode(node),

            // import x = require('y') → const x = require('y')
            .ts_import_equals_declaration => self.visitImportEqualsDeclaration(node),

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

    /// 원본 → 새 노드의 symbol_id 전파.
    fn propagateSymbolId(self: *Transformer, old_idx: NodeIndex, new_idx: NodeIndex) void {
        if (self.old_symbol_ids.len == 0) return; // 전파 비활성
        if (new_idx.isNone()) return;

        const old_i = @intFromEnum(old_idx);
        const new_i = @intFromEnum(new_idx);

        // new_symbol_ids를 new_ast 노드 수만큼 확장
        while (self.new_symbol_ids.items.len <= new_i) {
            self.new_symbol_ids.append(self.allocator, null) catch return;
        }

        if (old_i < self.old_symbol_ids.len) {
            self.new_symbol_ids.items[new_i] = self.old_symbol_ids[old_i];
        }
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

    /// unary/update expression: extra = [operand, operator_and_flags]
    fn visitUnaryExtra(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 1 >= extras.len) return NodeIndex.none;
        const new_operand = try self.visitNode(@enumFromInt(extras[e]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_operand), extras[e + 1] });
        return self.new_ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// tagged_template_expression: extra = [tag, template, flags]
    fn visitTaggedTemplate(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 2 >= extras.len) return NodeIndex.none;
        const new_tag = try self.visitNode(@enumFromInt(extras[e]));
        const new_tmpl = try self.visitNode(@enumFromInt(extras[e + 1]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_tag), @intFromEnum(new_tmpl), extras[e + 2] });
        return self.new_ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// member expression: extra = [object, property, flags]
    fn visitMemberExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 2 >= extras.len) return NodeIndex.none;
        const new_left = try self.visitNode(@enumFromInt(extras[e]));
        // computed_member: right는 임의 expression. static_member/private_field: right는 식별자 리프.
        // visitNode가 리프를 copyNodeDirect로 처리하므로 동일하게 visitNode 호출.
        const new_right = try self.visitNode(@enumFromInt(extras[e + 1]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_left), @intFromEnum(new_right), extras[e + 2] });
        return self.new_ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .extra = new_extra } });
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
    ///
    /// pending_nodes 지원: 각 자식 방문 후 pending_nodes에 쌓인 노드를
    /// 해당 자식 앞에 삽입한다. 이를 통해 1→N 노드 확장이 가능하다.
    /// 예: enum 변환 시 visitNode가 IIFE를 반환하면서 `var Color;`을
    ///     pending_nodes에 push → 리스트에 `var Color;` + IIFE 순서로 삽입.
    fn visitExtraList(self: *Transformer, start: u32, len: u32) Error!NodeList {
        const old_indices = self.old_ast.extra_data.items[start .. start + len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // pending_nodes save/restore: 중첩 visitExtraList 호출에 안전.
        // 내부 리스트의 pending_nodes가 외부 리스트로 누출되지 않도록 한다.
        const pending_top = self.pending_nodes.items.len;
        defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

        for (old_indices) |raw_idx| {
            const new_child = try self.visitNode(@enumFromInt(raw_idx));

            // pending_nodes 드레인: visitNode가 추가한 보류 노드를 먼저 삽입
            if (self.pending_nodes.items.len > pending_top) {
                try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                self.pending_nodes.shrinkRetainingCapacity(pending_top);
            }

            if (!new_child.isNone()) {
                try self.scratch.append(self.allocator, new_child);
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
    // --drop 헬퍼
    // ================================================================

    /// expression_statement가 console.* 호출인지 판별.
    /// console.log(...), console.warn(...), console.error(...) 등.
    fn isConsoleCall(self: *const Transformer, node: Node) bool {
        // expression_statement → unary.operand가 call_expression이어야 함
        const expr_idx = node.data.unary.operand;
        if (expr_idx.isNone()) return false;
        const expr = self.old_ast.getNode(expr_idx);
        if (expr.tag != .call_expression) return false;

        // call_expression: extra = [callee, args_start, args_len, flags]
        const ce = expr.data.extra;
        if (ce >= self.old_ast.extra_data.items.len) return false;
        const callee_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[ce]);
        if (callee_idx.isNone()) return false;
        const callee = self.old_ast.getNode(callee_idx);

        // callee가 static_member_expression (console.log)이어야 함
        if (callee.tag != .static_member_expression) return false;

        // left가 identifier "console" — extra = [object, property, flags]
        const me = callee.data.extra;
        if (me >= self.old_ast.extra_data.items.len) return false;
        const obj_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[me]);
        if (obj_idx.isNone()) return false;
        const obj = self.old_ast.getNode(obj_idx);
        if (obj.tag != .identifier_reference) return false;

        const obj_text = self.old_ast.source[obj.data.string_ref.start..obj.data.string_ref.end];
        return std.mem.eql(u8, obj_text, "console");
    }

    // ================================================================
    // define 글로벌 치환
    // ================================================================

    /// 노드가 define 치환 대상이면 새 string_literal 노드를 반환.
    /// 대상: identifier_reference 또는 static_member_expression 체인.
    fn tryDefineReplace(self: *Transformer, node: Node) ?Error!NodeIndex {
        // 노드의 소스 텍스트를 define key와 비교
        const text = self.getNodeText(node) orelse return null;

        for (self.options.define, 0..) |entry, i| {
            if (std.mem.eql(u8, text, entry.key)) {
                // transform() 시작 시 캐싱된 string_table Span 사용 (addString 중복 방지)
                const value_span = self.define_spans[i];
                return self.new_ast.addNode(.{
                    .tag = .string_literal,
                    .span = value_span,
                    .data = .{ .string_ref = value_span },
                });
            }
        }
        return null;
    }

    /// 노드의 소스 텍스트를 반환. identifier_reference와 static_member_expression만 지원.
    fn getNodeText(self: *const Transformer, node: Node) ?[]const u8 {
        return switch (node.tag) {
            .identifier_reference => self.old_ast.source[node.data.string_ref.start..node.data.string_ref.end],
            .static_member_expression => self.old_ast.source[node.span.start..node.span.end],
            else => null,
        };
    }

    // ================================================================
    // TS enum 변환
    // ================================================================

    /// ts_enum_declaration: extra = [name, members_start, members_len]
    /// enum 노드를 새 AST에 복사. codegen에서 IIFE 패턴으로 출력.
    /// extra = [name, members_start, members_len, flags]
    /// flags: 0=일반 enum, 1=const enum
    fn visitEnumDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const flags = self.readU32(e, 3);

        // const enum (flags=1): isolatedModules 모드에서는 삭제 (D011)
        // 같은 파일 내 인라이닝은 향후 구현
        if (flags == 1) {
            return .none; // const enum 선언 삭제
        }

        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_members = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.ts_enum_declaration, node.span, &.{
            @intFromEnum(new_name), new_members.start, new_members.len, flags,
        });
    }

    // ================================================================
    // TS namespace 변환
    // ================================================================

    /// ts_module_declaration: binary = { left=name, right=body_or_inner, flags }
    /// flags=1: ambient module declaration (`declare module "*.css" { ... }`) → strip.
    /// flags=0: 일반 namespace → 새 AST에 복사. codegen에서 IIFE로 출력.
    /// import x = require('y') → const x = require('y')
    /// import x = Namespace.Member → const x = Namespace.Member
    fn visitImportEqualsDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const name_idx = node.data.binary.left;
        const value_idx = node.data.binary.right;
        const new_name = try self.visitNode(name_idx);
        const new_value = try self.visitNode(value_idx);
        // variable_declarator: extra = [name, type_ann(none), init]
        const decl_extra = try self.new_ast.addExtras(&.{
            @intFromEnum(new_name),
            @intFromEnum(NodeIndex.none), // type_ann (stripped)
            @intFromEnum(new_value),
        });
        const declarator = try self.new_ast.addNode(.{
            .tag = .variable_declarator,
            .span = node.span,
            .data = .{ .extra = decl_extra },
        });
        const scratch_top = self.scratch.items.len;
        try self.scratch.append(self.allocator, declarator);
        const list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        self.scratch.shrinkRetainingCapacity(scratch_top);
        // variable_declaration: extra = [kind_flags, list.start, list.len]
        // kind_flags=2: const
        const var_extra = try self.new_ast.addExtras(&.{ 2, list.start, list.len });
        return try self.new_ast.addNode(.{
            .tag = .variable_declaration,
            .span = node.span,
            .data = .{ .extra = var_extra },
        });
    }

    fn visitNamespaceDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        // declare module "*.css" { ... } 같은 ambient module은 런타임 코드 없음 → strip
        if (node.data.binary.flags == 1) return .none;
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
    // JSX 노드 변환
    // ================================================================

    /// jsx_element: extra = [tag_name, attrs_start, attrs_len, children_start, children_len]
    /// 항상 5 fields. self-closing은 children_len=0.
    fn visitJSXElement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        const children_len = self.readU32(e, 4);
        const new_children = if (children_len > 0)
            try self.visitExtraList(self.readU32(e, 3), children_len)
        else
            NodeList{ .start = 0, .len = 0 };
        return self.addExtraNode(.jsx_element, node.span, &.{
            @intFromEnum(new_tag),
            new_attrs.start,
            new_attrs.len,
            new_children.start,
            new_children.len,
        });
    }

    /// jsx_opening_element: extra = [tag_name, attrs_start, attrs_len]
    fn visitJSXOpeningElement(self: *Transformer, node: Node) Error!NodeIndex {
        return self.visitJSXExtraNode(.jsx_opening_element, node);
    }

    /// JSX extra 노드 공통: tag + attrs만 복사 (opening element 등)
    fn visitJSXExtraNode(self: *Transformer, tag: Tag, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_tag = try self.visitNode(self.readNodeIdx(e, 0));
        const new_attrs = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(tag, node.span, &.{
            @intFromEnum(new_tag),
            new_attrs.start,
            new_attrs.len,
        });
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
    ///
    /// parameter property 변환:
    ///   constructor(public x: number) {} →
    ///   constructor(x) { this.x = x; }
    fn visitFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 + parameter property 수집
        const params_start = self.readU32(e, 1);
        const params_len = self.readU32(e, 2);
        const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        const pp = try self.visitParamsCollectProperties(old_params);

        // 바디 방문
        const old_body_idx = self.readNodeIdx(e, 3);
        var new_body = try self.visitNode(old_body_idx);

        // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
        if (pp.prop_count > 0 and !new_body.isNone()) {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names[0..pp.prop_count]);
        }

        // React Fast Refresh: Hook 시그니처 감지 + _s() 호출 삽입
        // 함수 이름을 old_ast에서 추출 (new_name은 아직 extra에 추가 전이므로)
        const old_name_idx = self.readNodeIdx(e, 0);
        const func_name_for_sig: ?[]const u8 = if (!old_name_idx.isNone()) blk: {
            const old_name_node = self.old_ast.getNode(old_name_idx);
            if (old_name_node.tag == .binding_identifier or old_name_node.tag == .identifier_reference) {
                break :blk self.old_ast.getText(old_name_node.data.string_ref);
            }
            break :blk null;
        } else null;
        try self.maybeRegisterRefreshSignature(func_name_for_sig, old_body_idx, &new_body);

        const none = @intFromEnum(NodeIndex.none);
        const result = try self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), pp.new_params.start, pp.new_params.len,
            @intFromEnum(new_body), self.readU32(e, 4),  none,
        });

        // React Fast Refresh: PascalCase 함수 → 컴포넌트 등록
        try self.maybeRegisterRefreshComponent(result);

        return result;
    }

    /// 파라미터 목록을 방문하면서 parameter property (public x 등)를 감지.
    /// modifier를 제거하고 this.x = x 삽입용 이름을 수집한다.
    const ParamPropertyResult = struct {
        new_params: NodeList,
        prop_names: [32]NodeIndex,
        prop_count: usize,
    };

    fn visitParamsCollectProperties(self: *Transformer, old_params: []const u32) Error!ParamPropertyResult {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        var result = ParamPropertyResult{
            .new_params = NodeList{ .start = 0, .len = 0 },
            .prop_names = undefined,
            .prop_count = 0,
        };

        for (old_params) |raw_idx| {
            const param_node = self.old_ast.getNode(@enumFromInt(raw_idx));
            // formal_parameter + unary flags!=0 → parameter property
            if (param_node.tag == .formal_parameter and param_node.data.unary.flags != 0) {
                const inner = try self.visitNode(param_node.data.unary.operand);
                try self.scratch.append(self.allocator, inner);
                if (result.prop_count < result.prop_names.len) {
                    result.prop_names[result.prop_count] = inner;
                    result.prop_count += 1;
                }
            } else {
                const new_param = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_param.isNone()) {
                    try self.scratch.append(self.allocator, new_param);
                }
            }
        }

        result.new_params = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return result;
    }

    /// block_statement 바디 앞에 this.x = x; 문들을 삽입한다.
    fn insertParameterPropertyAssignments(self: *Transformer, body_idx: NodeIndex, prop_names: []const NodeIndex) Error!NodeIndex {
        const body = self.new_ast.getNode(body_idx);
        if (body.tag != .block_statement) return body_idx;

        const old_list = body.data.list;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // this.x = x 문들을 먼저 추가
        for (prop_names) |name_idx| {
            const name_node = self.new_ast.getNode(name_idx);
            // this 노드
            const this_node = try self.new_ast.addNode(.{
                .tag = .this_expression,
                .span = name_node.span,
                .data = .{ .none = 0 },
            });
            // this.x (static member) — extra = [object, property, flags]
            const member_extra = try self.new_ast.addExtras(&.{ @intFromEnum(this_node), @intFromEnum(name_idx), 0 });
            const member = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = name_node.span,
                .data = .{ .extra = member_extra },
            });
            // this.x = x (assignment)
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = name_node.span,
                .data = .{ .binary = .{ .left = member, .right = name_idx, .flags = 0 } },
            });
            // expression_statement
            const stmt = try self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = name_node.span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, stmt);
        }

        // 기존 바디 문들을 추가
        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });
    }

    /// arrow_function_expression: extra = [params, body, flags]
    /// flags: 0x01 = async
    fn visitArrowFunction(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 2 >= extras.len) return NodeIndex.none;
        const new_params = try self.visitNode(@enumFromInt(extras[e]));
        const new_body = try self.visitNode(@enumFromInt(extras[e + 1]));
        const new_extra = try self.new_ast.addExtras(&.{ @intFromEnum(new_params), @intFromEnum(new_body), extras[e + 2] });
        return self.new_ast.addNode(.{ .tag = .arrow_function_expression, .span = node.span, .data = .{ .extra = new_extra } });
    }

    /// class_declaration / class_expression
    /// extra_data = [name, super_class, body, type_params, implements_start, implements_len]
    /// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
    fn visitClass(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_name = try self.visitNode(self.readNodeIdx(e, 0));
        const new_super = try self.visitNode(self.readNodeIdx(e, 1));
        const new_body = try self.visitNode(self.readNodeIdx(e, 2));
        // decorator 리스트 복사
        const new_decos = try self.visitExtraList(self.readU32(e, 6), self.readU32(e, 7));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,            0,             0, // type_params, implements 제거
            new_decos.start, new_decos.len,
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

    /// switch_statement: extra = [discriminant, cases.start, cases.len]
    fn visitSwitchStatement(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_disc = try self.visitNode(self.readNodeIdx(e, 0));
        const new_cases = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.switch_statement, node.span, &.{
            @intFromEnum(new_disc), new_cases.start, new_cases.len,
        });
    }

    /// switch_case: extra_data = [test, stmts_start, stmts_len]
    fn visitSwitchCase(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_test = try self.visitNode(self.readNodeIdx(e, 0));
        const new_stmts = try self.visitExtraList(self.readU32(e, 1), self.readU32(e, 2));
        return self.addExtraNode(.switch_case, node.span, &.{ @intFromEnum(new_test), new_stmts.start, new_stmts.len });
    }

    /// call_expression: extra = [callee, args_start, args_len, flags]
    fn visitCallExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 3 >= extras.len) return NodeIndex.none;
        const callee: NodeIndex = @enumFromInt(extras[e]);
        const args_start = extras[e + 1];
        const args_len = extras[e + 2];
        const flags = extras[e + 3];
        const new_callee = try self.visitNode(callee);
        const new_args = try self.visitExtraList(args_start, args_len);
        const new_extra = try self.new_ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.new_ast.addNode(.{
            .tag = .call_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    /// new_expression: extra = [callee, args_start, args_len, flags]
    fn visitNewExpression(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const extras = self.old_ast.extra_data.items;
        if (e + 3 >= extras.len) return NodeIndex.none;
        const callee: NodeIndex = @enumFromInt(extras[e]);
        const args_start = extras[e + 1];
        const args_len = extras[e + 2];
        const flags = extras[e + 3];
        const new_callee = try self.visitNode(callee);
        const new_args = try self.visitExtraList(args_start, args_len);
        const new_extra = try self.new_ast.addExtras(&.{
            @intFromEnum(new_callee), new_args.start, new_args.len, flags,
        });
        return self.new_ast.addNode(.{
            .tag = .new_expression,
            .span = node.span,
            .data = .{ .extra = new_extra },
        });
    }

    // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
    // constructor의 parameter property (public x: number) 변환도 처리.
    fn visitMethodDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));

        // 파라미터 방문 — parameter property 감지
        const params_start = self.readU32(e, 1);
        const params_len = self.readU32(e, 2);
        const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];
        const pp = try self.visitParamsCollectProperties(old_params);

        var new_body = try self.visitNode(self.readNodeIdx(e, 3));

        // parameter property가 있으면 바디 앞에 this.x = x 문 삽입
        if (pp.prop_count > 0 and !new_body.isNone()) {
            new_body = try self.insertParameterPropertyAssignments(new_body, pp.prop_names[0..pp.prop_count]);
        }

        const new_decos = try self.visitExtraList(self.readU32(e, 5), self.readU32(e, 6));
        return self.addExtraNode(.method_definition, node.span, &.{
            @intFromEnum(new_key), pp.new_params.start, pp.new_params.len, @intFromEnum(new_body),
            self.readU32(e, 4),    new_decos.start,     new_decos.len,
        });
    }

    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
    fn visitPropertyDefinition(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        const new_decos = try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        return self.addExtraNode(.property_definition, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    // accessor_property: extra = [key, init_val, flags, deco_start, deco_len]
    fn visitAccessorProperty(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_key = try self.visitNode(self.readNodeIdx(e, 0));
        const new_value = try self.visitNode(self.readNodeIdx(e, 1));
        const new_decos = try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        return self.addExtraNode(.accessor_property, node.span, &.{
            @intFromEnum(new_key), @intFromEnum(new_value), self.readU32(e, 2),
            new_decos.start,       new_decos.len,
        });
    }

    /// object_property: binary = { left=key, right=value, flags }
    fn visitObjectProperty(self: *Transformer, node: Node) Error!NodeIndex {
        const new_key = try self.visitNode(node.data.binary.left);
        const new_value = try self.visitNode(node.data.binary.right);
        return self.new_ast.addNode(.{
            .tag = .object_property,
            .span = node.span,
            .data = .{ .binary = .{
                .left = new_key,
                .right = new_value,
                .flags = node.data.binary.flags,
            } },
        });
    }

    /// formal_parameter:
    ///   - extra_data = [pattern, type_ann, default_value, decorators_start, decorators_len]
    ///   - 또는 unary = { operand=inner, flags=modifier_flags } (parameter property)
    /// parameter property (unary)는 visitFunction/visitMethodDefinition에서 직접 처리하지만,
    /// 다른 경로에서 도달할 수 있으므로 방어적으로 처리.
    fn visitFormalParameter(self: *Transformer, node: Node) Error!NodeIndex {
        // parameter property (unary 레이아웃): modifier 제거하고 내부 패턴만 반환
        if (node.data.unary.flags != 0) {
            return self.visitNode(node.data.unary.operand);
        }
        const e = node.data.extra;
        const new_pattern = try self.visitNode(self.readNodeIdx(e, 0));
        const new_default = try self.visitNode(self.readNodeIdx(e, 2));
        const new_decos = try self.visitExtraList(self.readU32(e, 3), self.readU32(e, 4));
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(.formal_parameter, node.span, &.{
            @intFromEnum(new_pattern), none,          @intFromEnum(new_default), // type_ann 제거
            new_decos.start,           new_decos.len,
        });
    }

    /// import_declaration:
    ///   모든 import는 extra = [specs_start, specs_len, source_node] 형식.
    ///   side-effect import (import "module")은 specs_len=0.
    fn visitImportDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
        const e = node.data.extra;
        const new_specs = try self.visitExtraList(self.readU32(e, 0), self.readU32(e, 1));
        const new_source = try self.visitNode(self.readNodeIdx(e, 2));
        return self.addExtraNode(.import_declaration, node.span, &.{
            new_specs.start, new_specs.len, @intFromEnum(new_source),
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
            // ts_import_equals_declaration은 런타임 코드 생성 — visitNode에서 별도 처리
            .ts_external_module_reference,
            .ts_export_assignment,
            // enum은 타입 전용이 아님 — 런타임 코드 생성이 필요
            // visitNode의 switch에서 별도 처리
            => true,
            else => false,
        };
    }

    // ================================================================
    // React Fast Refresh — 컴포넌트 등록 주입
    // ================================================================

    /// 함수 이름이 React 컴포넌트 명명 규칙(PascalCase)인지 확인.
    fn isComponentName(name: []const u8) bool {
        if (name.len == 0) return false;
        return name[0] >= 'A' and name[0] <= 'Z';
    }

    /// 함수 노드에서 이름 텍스트를 추출한다.
    /// function_declaration의 extra[0]이 binding_identifier.
    /// new_ast의 extra_data에서 읽음 (visitFunction이 이미 new_ast에 노드를 생성했으므로).
    fn getFunctionName(self: *Transformer, func_node: Node) ?[]const u8 {
        const e = func_node.data.extra;
        if (e >= self.new_ast.extra_data.items.len) return null;
        const name_idx: NodeIndex = @enumFromInt(self.new_ast.extra_data.items[e]);
        if (name_idx.isNone()) return null;
        const name_node = self.new_ast.getNode(name_idx);
        if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) return null;
        return self.new_ast.getText(name_node.data.string_ref);
    }

    /// 변환된 함수 노드가 React 컴포넌트이면 등록 정보를 수집한다.
    /// visitFunction에서 호출.
    fn maybeRegisterRefreshComponent(self: *Transformer, new_func_idx: NodeIndex) Error!void {
        if (!self.options.react_refresh) return;

        const func_node = self.new_ast.getNode(new_func_idx);
        const name = self.getFunctionName(func_node) orelse return;
        if (!isComponentName(name)) return;

        // 핸들 변수명 생성 + 등록 (프로그램 끝에서 일괄 주입)
        const handle_span = try self.makeRefreshHandle();
        try self.refresh_registrations.append(self.allocator, .{
            .handle_span = handle_span,
            .name = name,
        });
    }

    /// _c, _c2, _c3, ... 핸들 변수명 생성
    fn makeRefreshHandle(self: *Transformer) Error!Span {
        const idx = self.refresh_registrations.items.len;
        if (idx == 0) {
            return self.new_ast.addString("_c");
        }
        var buf: [16]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "_c{d}", .{idx + 1}) catch return error.OutOfMemory;
        return self.new_ast.addString(len);
    }

    /// 프로그램 끝에 var _c, _c2; $RefreshReg$(_c, "Name"); ... 를 추가한다.
    fn appendRefreshRegistrations(self: *Transformer, root: NodeIndex) Error!NodeIndex {
        const prog = self.new_ast.getNode(root);
        if (prog.tag != .program) return root;

        const old_list = prog.data.list;
        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // 기존 문장 복사
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        // _c = App; _c2 = Helper; 할당문 (함수 선언 뒤에 실행)
        for (self.refresh_registrations.items) |reg| {
            const assign_stmt = try self.buildRefreshAssignment(reg);
            try self.scratch.append(self.allocator, assign_stmt);
        }

        // var _c, _c2, ...; 선언
        const var_decl = try self.buildRefreshVarDeclaration();
        try self.scratch.append(self.allocator, var_decl);

        // var _s = $RefreshSig$(); 선언들
        const refresh_sig_span = try self.new_ast.addString("$RefreshSig$");
        for (self.refresh_signatures.items) |sig| {
            const sig_decl = try self.buildRefreshSigDeclaration(sig, refresh_sig_span);
            try self.scratch.append(self.allocator, sig_decl);
        }

        // _s(Component, "signature"); 호출들
        for (self.refresh_signatures.items) |sig| {
            const sig_call = try self.buildRefreshSigCall(sig);
            try self.scratch.append(self.allocator, sig_call);
        }

        // $RefreshReg$(_c, "ComponentName"); 호출들
        const refresh_reg_span = try self.new_ast.addString("$RefreshReg$");
        for (self.refresh_registrations.items) |reg| {
            const reg_stmt = try self.buildRefreshRegCall(reg, refresh_reg_span);
            try self.scratch.append(self.allocator, reg_stmt);
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = .program,
            .span = prog.span,
            .data = .{ .list = new_list },
        });
    }

    /// _c = ComponentName; 할당문 생성
    fn buildRefreshAssignment(self: *Transformer, reg: RefreshRegistration) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        const handle_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = reg.handle_span,
            .data = .{ .string_ref = reg.handle_span },
        });
        const comp_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = zero_span,
            .data = .{ .string_ref = try self.new_ast.addString(reg.name) },
        });
        const assign = try self.new_ast.addNode(.{
            .tag = .assignment_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = handle_ref, .right = comp_ref, .flags = 0 } },
        });
        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
    }

    /// var _c, _c2, ...; 선언 노드 생성
    fn buildRefreshVarDeclaration(self: *Transformer) Error!NodeIndex {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);
        const none = @intFromEnum(NodeIndex.none);

        for (self.refresh_registrations.items) |reg| {
            const binding = try self.new_ast.addNode(.{
                .tag = .binding_identifier,
                .span = reg.handle_span,
                .data = .{ .string_ref = reg.handle_span },
            });

            // variable_declarator: extra = [name, type_ann(none), init(none)]
            const declarator = try self.addExtraNode(.variable_declarator, reg.handle_span, &.{
                @intFromEnum(binding),
                none, // type annotation
                none, // initializer
            });
            try self.scratch.append(self.allocator, declarator);
        }

        const decl_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.addExtraNode(.variable_declaration, .{ .start = 0, .end = 0 }, &.{
            0, // var
            decl_list.start,
            decl_list.len,
        });
    }

    /// $RefreshReg$(_c, "ComponentName"); 호출문 생성
    fn buildRefreshRegCall(self: *Transformer, reg: RefreshRegistration, refresh_reg_span: Span) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = refresh_reg_span,
            .data = .{ .string_ref = refresh_reg_span },
        });

        const handle_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = reg.handle_span,
            .data = .{ .string_ref = reg.handle_span },
        });

        // "ComponentName" 문자열 리터럴 (따옴표 포함)
        var quoted_buf: [256]u8 = undefined;
        const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{reg.name}) catch return error.OutOfMemory;
        const quoted_span = try self.new_ast.addString(quoted);
        const name_str = try self.new_ast.addNode(.{
            .tag = .string_literal,
            .span = quoted_span,
            .data = .{ .string_ref = quoted_span },
        });

        const args = try self.new_ast.addNodeList(&.{ handle_ref, name_str });
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            args.start,
            args.len,
            0,
        });

        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = call, .flags = 0 } },
        });
    }

    /// var _s = $RefreshSig$(); 선언 생성
    fn buildRefreshSigDeclaration(self: *Transformer, sig: RefreshSignature, refresh_sig_span: Span) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };
        const none = @intFromEnum(NodeIndex.none);

        // $RefreshSig$() 호출
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = refresh_sig_span,
            .data = .{ .string_ref = refresh_sig_span },
        });
        const empty_args = try self.new_ast.addNodeList(&.{});
        const init_call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            empty_args.start,
            empty_args.len,
            0,
        });

        // var _s = $RefreshSig$();
        const binding = try self.new_ast.addNode(.{
            .tag = .binding_identifier,
            .span = sig.handle_span,
            .data = .{ .string_ref = sig.handle_span },
        });
        const declarator = try self.addExtraNode(.variable_declarator, sig.handle_span, &.{
            @intFromEnum(binding),
            none, // type annotation
            @intFromEnum(init_call),
        });

        const decl_list = try self.new_ast.addNodeList(&.{declarator});
        return self.addExtraNode(.variable_declaration, zero_span, &.{
            0, // var
            decl_list.start,
            decl_list.len,
        });
    }

    /// _s(Component, "signature"); 호출문 생성
    fn buildRefreshSigCall(self: *Transformer, sig: RefreshSignature) Error!NodeIndex {
        const zero_span = Span{ .start = 0, .end = 0 };

        // _s 식별자
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = sig.handle_span,
            .data = .{ .string_ref = sig.handle_span },
        });

        // Component 식별자
        const comp_ref = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = zero_span,
            .data = .{ .string_ref = try self.new_ast.addString(sig.component_name) },
        });

        // "signature" 문자열 리터럴
        var quoted_buf: [1024]u8 = undefined;
        const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{sig.signature}) catch return error.OutOfMemory;
        const quoted_span = try self.new_ast.addString(quoted);
        const sig_str = try self.new_ast.addNode(.{
            .tag = .string_literal,
            .span = quoted_span,
            .data = .{ .string_ref = quoted_span },
        });

        // _s(Component, "signature")
        const args = try self.new_ast.addNodeList(&.{ comp_ref, sig_str });
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            args.start,
            args.len,
            0,
        });

        return self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = call, .flags = 0 } },
        });
    }

    // ================================================================
    // React Fast Refresh — Hook 시그니처 ($RefreshSig$)
    // ================================================================

    /// Hook 호출 이름이 React Hook인지 확인 (use 접두사 + 다음 문자가 대문자).
    fn isHookCall(name: []const u8) bool {
        if (!std.mem.startsWith(u8, name, "use")) return false;
        // "use" 자체도 React 19 hook
        if (name.len == 3) return true;
        // use 다음 문자가 대문자 (useState, useEffect, useMyHook 등)
        return name[3] >= 'A' and name[3] <= 'Z';
    }

    /// old_ast에서 함수 body 내의 Hook 호출을 스캔하여 시그니처 문자열을 생성한다.
    /// Hook이 없으면 null 반환.
    fn scanHookSignature(self: *Transformer, func_body_idx: NodeIndex) Error!?[]const u8 {
        if (!self.options.react_refresh) return null;
        if (func_body_idx.isNone()) return null;

        var sig_buf: std.ArrayList(u8) = .empty;
        defer sig_buf.deinit(self.allocator);

        // old_ast에서 body의 자식 문장들을 순회
        const body_node = self.old_ast.getNode(func_body_idx);
        if (body_node.tag != .block_statement) return null;

        const list = body_node.data.list;
        const stmts = self.old_ast.extra_data.items[list.start .. list.start + list.len];

        for (stmts) |raw_stmt_idx| {
            const stmt_idx: NodeIndex = @enumFromInt(raw_stmt_idx);
            // 재귀적으로 Hook 호출 검색
            try self.findHookCallsInNode(stmt_idx, &sig_buf, null);
        }

        if (sig_buf.items.len == 0) return null;
        return try self.allocator.dupe(u8, sig_buf.items);
    }

    /// Hook 호출을 찾아 시그니처 버퍼에 추가한다 (old_ast 기준).
    /// binding_ctx: 부모 variable_declarator의 LHS 바인딩 텍스트 (null이면 없음).
    fn findHookCallsInNode(self: *Transformer, idx: NodeIndex, sig_buf: *std.ArrayList(u8), binding_ctx: ?[]const u8) Error!void {
        if (idx.isNone()) return;
        if (@intFromEnum(idx) >= self.old_ast.nodes.items.len) return;
        const node = self.old_ast.getNode(idx);

        // call_expression에서 Hook 호출 감지
        if (node.tag == .call_expression) {
            const e = node.data.extra;
            if (self.old_ast.hasExtra(e, 1)) {
                const callee_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[e]);
                if (!callee_idx.isNone() and @intFromEnum(callee_idx) < self.old_ast.nodes.items.len) {
                    const callee = self.old_ast.getNode(callee_idx);
                    var hook_name: ?[]const u8 = null;

                    if (callee.tag == .identifier_reference) {
                        const name = self.old_ast.getText(callee.data.string_ref);
                        if (isHookCall(name)) hook_name = name;
                    } else if (callee.tag == .static_member_expression) {
                        const me = callee.data.binary;
                        if (!me.right.isNone() and @intFromEnum(me.right) < self.old_ast.nodes.items.len) {
                            const prop = self.old_ast.getNode(me.right);
                            if (prop.tag == .identifier_reference) {
                                const name = self.old_ast.getText(prop.data.string_ref);
                                if (isHookCall(name)) hook_name = name;
                            }
                        }
                    }

                    if (hook_name) |name| {
                        if (sig_buf.items.len > 0) {
                            try sig_buf.appendSlice(self.allocator, "\\n");
                        }
                        try sig_buf.appendSlice(self.allocator, name);
                        try sig_buf.append(self.allocator, '{');
                        // 바인딩 패턴 포함: useState{[foo, setFoo](0)}
                        if (binding_ctx) |b| {
                            try sig_buf.appendSlice(self.allocator, b);
                        }
                        // 첫 번째 인자 포함 (useState/useReducer의 초기값)
                        if (self.old_ast.hasExtra(e, 3)) {
                            const args_start = self.old_ast.extra_data.items[e + 1];
                            const args_len = self.old_ast.extra_data.items[e + 2];
                            if (args_len > 0 and args_start < self.old_ast.extra_data.items.len) {
                                const first_arg_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[args_start]);
                                if (!first_arg_idx.isNone() and @intFromEnum(first_arg_idx) < self.old_ast.nodes.items.len) {
                                    const first_arg = self.old_ast.getNode(first_arg_idx);
                                    if (first_arg.span.start < first_arg.span.end and
                                        first_arg.span.start & 0x8000_0000 == 0)
                                    {
                                        try sig_buf.append(self.allocator, '(');
                                        try sig_buf.appendSlice(self.allocator, self.old_ast.source[first_arg.span.start..first_arg.span.end]);
                                        try sig_buf.append(self.allocator, ')');
                                    }
                                }
                            }
                        }
                        try sig_buf.append(self.allocator, '}');
                    }
                }
            }
            return;
        }

        // 중첩 함수는 스킵
        switch (node.tag) {
            .function_declaration, .function_expression, .arrow_function_expression => return,
            else => {},
        }

        // expression_statement → 내부 expression 탐색
        if (node.tag == .expression_statement) {
            try self.findHookCallsInNode(node.data.unary.operand, sig_buf, null);
            return;
        }

        // variable_declaration → declarator들 탐색
        if (node.tag == .variable_declaration) {
            const e = node.data.extra;
            if (self.old_ast.hasExtra(e, 3)) {
                const list_start = self.old_ast.extra_data.items[e + 1];
                const list_len = self.old_ast.extra_data.items[e + 2];
                if (list_start + list_len <= self.old_ast.extra_data.items.len) {
                    const items = self.old_ast.extra_data.items[list_start .. list_start + list_len];
                    for (items) |raw| {
                        try self.findHookCallsInNode(@enumFromInt(raw), sig_buf, null);
                    }
                }
            }
            return;
        }

        // variable_declarator → LHS 바인딩 추출 + init 탐색
        if (node.tag == .variable_declarator) {
            const e = node.data.extra;
            if (self.old_ast.hasExtra(e, 3)) {
                // LHS 바인딩 텍스트 추출 (binding_identifier 또는 array/object pattern)
                const lhs_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[e]);
                var lhs_text: ?[]const u8 = null;
                if (!lhs_idx.isNone() and @intFromEnum(lhs_idx) < self.old_ast.nodes.items.len) {
                    const lhs = self.old_ast.getNode(lhs_idx);
                    if (lhs.span.start < lhs.span.end and lhs.span.start & 0x8000_0000 == 0) {
                        lhs_text = self.old_ast.source[lhs.span.start..lhs.span.end];
                    }
                }

                const init_idx: NodeIndex = @enumFromInt(self.old_ast.extra_data.items[e + 2]);
                try self.findHookCallsInNode(init_idx, sig_buf, lhs_text);
            }
            return;
        }

        // block_statement → 자식 문장들 탐색
        if (node.tag == .block_statement) {
            const l = node.data.list;
            if (l.len > 0 and l.start + l.len <= self.old_ast.extra_data.items.len) {
                const items = self.old_ast.extra_data.items[l.start .. l.start + l.len];
                for (items) |raw| {
                    try self.findHookCallsInNode(@enumFromInt(raw), sig_buf, null);
                }
            }
        }
    }

    /// _s / _s2 핸들 변수명 생성
    fn makeSigHandle(self: *Transformer) Error!Span {
        const idx = self.refresh_signatures.items.len;
        if (idx == 0) {
            return self.new_ast.addString("_s");
        }
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "_s{d}", .{idx + 1}) catch return error.OutOfMemory;
        return self.new_ast.addString(name);
    }

    /// Hook 시그니처가 있는 컴포넌트를 등록하고, body에 _s() 호출을 삽입한다.
    fn maybeRegisterRefreshSignature(
        self: *Transformer,
        func_name: ?[]const u8,
        old_body_idx: NodeIndex,
        new_body: *NodeIndex,
    ) Error!void {
        if (!self.options.react_refresh) return;
        const name = func_name orelse return;
        if (!isComponentName(name)) return;

        const signature = try self.scanHookSignature(old_body_idx) orelse return;

        const handle_span = try self.makeSigHandle();
        try self.refresh_signatures.append(self.allocator, .{
            .handle_span = handle_span,
            .component_name = name,
            .signature = signature,
        });

        // body 시작에 _s(); 호출 삽입
        new_body.* = try self.insertSigCallAtBodyStart(new_body.*, handle_span);
    }

    /// 블록 body 시작에 _s(); 호출문을 삽입한다.
    fn insertSigCallAtBodyStart(self: *Transformer, body_idx: NodeIndex, handle_span: Span) Error!NodeIndex {
        const body = self.new_ast.getNode(body_idx);
        if (body.tag != .block_statement) return body_idx;

        const old_list = body.data.list;
        const old_stmts = self.new_ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // _s() 호출문
        const zero_span = Span{ .start = 0, .end = 0 };
        const callee = try self.new_ast.addNode(.{
            .tag = .identifier_reference,
            .span = handle_span,
            .data = .{ .string_ref = handle_span },
        });
        const empty_args = try self.new_ast.addNodeList(&.{});
        const call = try self.addExtraNode(.call_expression, zero_span, &.{
            @intFromEnum(callee),
            empty_args.start,
            empty_args.len,
            0,
        });
        const call_stmt = try self.new_ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = call, .flags = 0 } },
        });

        // [_s(), ...기존 문장들]
        try self.scratch.append(self.allocator, call_stmt);
        for (old_stmts) |raw_idx| {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }

        const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
        return self.new_ast.addNode(.{
            .tag = .block_statement,
            .span = body.span,
            .data = .{ .list = new_list },
        });
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
    scanner_ptr.* = try Scanner.init(allocator, source);

    const parser_ptr = try allocator.create(Parser);
    parser_ptr.* = Parser.init(allocator, scanner_ptr);

    _ = try parser_ptr.parse();

    var t = Transformer.init(allocator, &parser_ptr.ast, .{});
    const root = try t.transform();
    t.scratch.deinit(allocator);

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
