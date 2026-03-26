//! ES2015 다운레벨링: generator function → 상태 머신
//!
//! --target < es2015 일 때 활성화.
//!
//! function* gen() { yield 1; var x = yield 2; return x; }
//! → function gen() {
//!     return __generator(function(_state) {
//!       switch (_state.label) {
//!         case 0: return [4, 1];
//!         case 1: x = _state.sent(); return [4, 2];
//!         case 2: return [2, _state.sent()];
//!       }
//!     });
//!   }
//!
//! 상태 머신 instruction 코드:
//!   [4, value] — yield (일시정지, value 반환)
//!   [2, value] — return (완료)
//!   [3, label] — break/jump (다른 case로 이동)
//!   [5, iter]  — yield* (위임)
//!
//! __generator 런타임 헬퍼:
//!   _state.label — 현재 case 번호
//!   _state.sent() — .next(value)로 전달된 값
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-generator-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/generator.rs (~3778줄)
//! - TypeScript: src/compiler/transformers/generators.ts
//! - esbuild: 미지원

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

/// 상태 머신의 개별 연산.
const OpCode = enum {
    statement, // 일반 문
    yield_op, // yield value → [4, value]
    yield_star, // yield* iter → [5, iter]
    return_op, // return value → [2, value]
    break_op, // goto label → [3, label]
    break_when_true, // if (expr) goto label
    break_when_false, // if (!expr) goto label
    nop, // case 경계 강제 (빈 연산)
};

/// 연산의 인자.
const OpArg = union(enum) {
    none: void,
    node: NodeIndex, // statement, yield, return의 값
    label: u32, // break_op의 대상 label
    label_and_node: struct { label: u32, node: NodeIndex }, // break_when_true/false
};

/// 하나의 연산 (opcode + 인자).
const Operation = struct {
    code: OpCode,
    arg: OpArg,
};

pub fn ES2015Generator(comptime Transformer: type) type {
    return struct {
        /// generator function을 상태 머신으로 변환.
        /// function*: extra = [name, params_start, params_len, body, flags, return_type]
        pub fn lowerGeneratorFunction(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = @enumFromInt(extras[e]);
            const params_start = extras[e + 1];
            const params_len = extras[e + 2];
            const body_idx: NodeIndex = @enumFromInt(extras[e + 3]);
            const flags = extras[e + 4];

            const new_name = try self.visitNode(name_idx);
            const new_params = try self.visitExtraList(params_start, params_len);

            // generator body를 상태 머신으로 변환
            const state_machine_body = try buildStateMachine(self, body_idx, span);

            // __generator(function(_state) { switch ... }) 호출 생성
            const gen_call = try buildGeneratorHelperCall(self, state_machine_body, span);

            // return __generator(...) 문
            const ret_stmt = try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = gen_call, .flags = 0 } },
            });
            const body_list = try self.new_ast.addNodeList(&.{ret_stmt});
            const new_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // 일반 function으로 변환 (generator 플래그 제거)
            const new_flags = flags & ~@as(u32, ast_mod.FunctionFlags.is_generator);
            const none = @intFromEnum(NodeIndex.none);
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(new_name),
                new_params.start,
                new_params.len,
                @intFromEnum(new_body),
                new_flags,
                none,
            });
            return self.new_ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        /// generator body를 switch 문 기반 상태 머신으로 변환.
        fn buildStateMachine(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (body_idx.isNone()) return NodeIndex.none;

            const body = self.old_ast.getNode(body_idx);
            if (body.tag != .block_statement and body.tag != .function_body) return NodeIndex.none;

            const stmts = self.old_ast.extra_data.items[body.data.list.start .. body.data.list.start + body.data.list.len];

            // Phase 1: 연산 수집 (yield/return/statement를 Operation으로 변환)
            var ops: std.ArrayList(Operation) = .empty;
            defer ops.deinit(self.allocator);

            var next_label: u32 = 1; // label 0은 시작

            for (stmts) |raw_idx| {
                try collectOperations(self, @enumFromInt(raw_idx), &ops, &next_label);
            }

            // 암시적 return (마지막에 return이 없으면 추가)
            if (ops.items.len == 0 or ops.items[ops.items.len - 1].code != .return_op) {
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .none = {} } });
            }

            // Phase 2: 연산을 switch case로 변환
            return buildSwitchFromOps(self, ops.items, span);
        }

        /// AST 문을 순회하며 연산을 수집.
        fn collectOperations(self: *Transformer, stmt_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            if (stmt_idx.isNone()) return;
            const stmt = self.old_ast.getNode(stmt_idx);

            switch (stmt.tag) {
                .expression_statement => {
                    // expression_statement 안의 yield 감지
                    const expr_idx = stmt.data.unary.operand;
                    const expr = self.old_ast.getNode(expr_idx);

                    if (expr.tag == .yield_expression) {
                        // yield value → [4, value], 다음 case에서 재개
                        const value_idx = expr.data.unary.operand;
                        const new_value = if (!value_idx.isNone()) try self.visitNode(value_idx) else NodeIndex.none;
                        try ops.append(self.allocator, .{ .code = .yield_op, .arg = .{ .node = new_value } });
                        next_label.* += 1;
                        // yield 후 재개 지점 (nop으로 case 경계 생성)
                        try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                    } else if (expr.tag == .assignment_expression) {
                        // x = yield value 패턴 감지
                        const right_idx = expr.data.binary.right;
                        const right = self.old_ast.getNode(right_idx);
                        if (right.tag == .yield_expression) {
                            const yield_value_idx = right.data.unary.operand;
                            const new_yield_value = if (!yield_value_idx.isNone()) try self.visitNode(yield_value_idx) else NodeIndex.none;
                            try ops.append(self.allocator, .{ .code = .yield_op, .arg = .{ .node = new_yield_value } });
                            next_label.* += 1;
                            // x = _state.sent() (nop + assign)
                            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                            // assignment: left = _state.sent()
                            const new_left = try self.visitNode(expr.data.binary.left);
                            const sent_call = try buildSentCall(self, stmt.span);
                            const assign = try self.new_ast.addNode(.{
                                .tag = .assignment_expression,
                                .span = stmt.span,
                                .data = .{ .binary = .{ .left = new_left, .right = sent_call, .flags = 0 } },
                            });
                            const assign_stmt = try self.new_ast.addNode(.{
                                .tag = .expression_statement,
                                .span = stmt.span,
                                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
                            });
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                        } else {
                            const new_stmt = try self.visitNode(stmt_idx);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    }
                },
                .return_statement => {
                    const value_idx = stmt.data.unary.operand;
                    const new_value = if (!value_idx.isNone()) try self.visitNode(value_idx) else NodeIndex.none;
                    try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
                },
                .variable_declaration => {
                    // variable_declaration 안에서 yield가 있는지 확인
                    // 간소화: 통째로 visit
                    const new_stmt = try self.visitNode(stmt_idx);
                    if (!new_stmt.isNone()) {
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    }
                },
                .if_statement => {
                    try collectIfOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .for_statement => {
                    try collectForOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .while_statement => {
                    try collectWhileOperations(self, stmt_idx, stmt, ops, next_label);
                },
                else => {
                    // 기타 문: 그대로 visit
                    const new_stmt = try self.visitNode(stmt_idx);
                    if (!new_stmt.isNone()) {
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    }
                },
            }
        }

        /// if문의 연산 수집.
        fn collectIfOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.ternary.a;
            const then_body = stmt.data.ternary.b;
            const else_body = stmt.data.ternary.c;

            // yield가 if 안에 있는지 빠른 체크
            if (!containsYield(self, then_body) and !containsYield(self, else_body)) {
                // yield 없으면 그대로 visit
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const new_cond = try self.visitNode(condition);
            const else_label = next_label.*;
            next_label.* += 1;
            const end_label = next_label.*;
            next_label.* += 1;

            // if (!cond) goto else_label
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{
                    .label = if (!else_body.isNone()) else_label else end_label,
                    .node = new_cond,
                } },
            });

            // then body
            const then_node = self.old_ast.getNode(then_body);
            if (then_node.tag == .block_statement) {
                const then_stmts = self.old_ast.extra_data.items[then_node.data.list.start .. then_node.data.list.start + then_node.data.list.len];
                for (then_stmts) |raw_idx| {
                    try collectOperations(self, @enumFromInt(raw_idx), ops, next_label);
                }
            } else {
                try collectOperations(self, then_body, ops, next_label);
            }

            // goto end
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_label } });

            // else label
            if (!else_body.isNone()) {
                // mark else_label (nop으로 case 경계)
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                const else_node = self.old_ast.getNode(else_body);
                if (else_node.tag == .block_statement) {
                    const else_stmts = self.old_ast.extra_data.items[else_node.data.list.start .. else_node.data.list.start + else_node.data.list.len];
                    for (else_stmts) |raw_idx| {
                        try collectOperations(self, @enumFromInt(raw_idx), ops, next_label);
                    }
                } else {
                    try collectOperations(self, else_body, ops, next_label);
                }
            }

            // mark end_label
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// for문의 연산 수집.
        fn collectForOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const extras = self.old_ast.extra_data.items;
            const e = stmt.data.extra;
            const init_idx: NodeIndex = @enumFromInt(extras[e]);
            const test_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const update_idx: NodeIndex = @enumFromInt(extras[e + 2]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 3]);

            if (!containsYield(self, body_idx)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // init
            if (!init_idx.isNone()) {
                const new_init = try self.visitNode(init_idx);
                if (!new_init.isNone()) {
                    const init_stmt = try self.new_ast.addNode(.{
                        .tag = .expression_statement,
                        .span = stmt.span,
                        .data = .{ .unary = .{ .operand = new_init, .flags = 0 } },
                    });
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = init_stmt } });
                }
            }

            // loop condition label
            const cond_label = next_label.*;
            next_label.* += 1;
            const end_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            // test
            if (!test_idx.isNone()) {
                const new_test = try self.visitNode(test_idx);
                try ops.append(self.allocator, .{
                    .code = .break_when_false,
                    .arg = .{ .label_and_node = .{ .label = end_label, .node = new_test } },
                });
            }

            // body
            const body_node = self.old_ast.getNode(body_idx);
            if (body_node.tag == .block_statement) {
                const body_stmts = self.old_ast.extra_data.items[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];
                for (body_stmts) |raw_idx| {
                    try collectOperations(self, @enumFromInt(raw_idx), ops, next_label);
                }
            } else {
                try collectOperations(self, body_idx, ops, next_label);
            }

            // update
            if (!update_idx.isNone()) {
                const new_update = try self.visitNode(update_idx);
                if (!new_update.isNone()) {
                    const update_stmt = try self.new_ast.addNode(.{
                        .tag = .expression_statement,
                        .span = stmt.span,
                        .data = .{ .unary = .{ .operand = new_update, .flags = 0 } },
                    });
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = update_stmt } });
                }
            }

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // mark end_label
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// while문의 연산 수집.
        fn collectWhileOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            if (!containsYield(self, body_idx)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const cond_label = next_label.*;
            next_label.* += 1;
            const end_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            const new_cond = try self.visitNode(condition);
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = end_label, .node = new_cond } },
            });

            // body
            const body_node = self.old_ast.getNode(body_idx);
            if (body_node.tag == .block_statement) {
                const body_stmts = self.old_ast.extra_data.items[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];
                for (body_stmts) |raw_idx| {
                    try collectOperations(self, @enumFromInt(raw_idx), ops, next_label);
                }
            } else {
                try collectOperations(self, body_idx, ops, next_label);
            }

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // mark end_label
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// AST 서브트리에 yield_expression이 있는지 빠른 체크.
        fn containsYield(self: *const Transformer, idx: NodeIndex) bool {
            if (idx.isNone()) return false;
            const node = self.old_ast.getNode(idx);
            if (node.tag == .yield_expression) return true;
            // function/arrow 경계에서는 중단 (nested generator/arrow의 yield는 다른 스코프)
            if (node.tag == .function_declaration or node.tag == .function_expression or
                node.tag == .arrow_function_expression) return false;

            // 자식 순회
            return switch (node.tag) {
                .block_statement,
                .function_body,
                .array_expression,
                .sequence_expression,
                .formal_parameters,
                .class_body,
                => {
                    const members = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                    for (members) |raw_idx| {
                        if (containsYield(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .expression_statement,
                .return_statement,
                .throw_statement,
                .spread_element,
                .rest_element,
                .parenthesized_expression,
                => containsYield(self, node.data.unary.operand),
                .assignment_expression,
                .binary_expression,
                .logical_expression,
                => containsYield(self, node.data.binary.left) or containsYield(self, node.data.binary.right),
                .conditional_expression,
                .if_statement,
                .for_in_statement,
                .for_of_statement,
                => containsYield(self, node.data.ternary.a) or containsYield(self, node.data.ternary.b) or containsYield(self, node.data.ternary.c),
                .while_statement,
                .do_while_statement,
                => containsYield(self, node.data.binary.left) or containsYield(self, node.data.binary.right),
                .for_statement => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 3 >= extras.len) return false;
                    return containsYield(self, @enumFromInt(extras[e + 3])); // body
                },
                .variable_declaration => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    const list_start = extras[e + 1];
                    const list_len = extras[e + 2];
                    const decls = extras[list_start .. list_start + list_len];
                    for (decls) |raw_idx| {
                        if (containsYield(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .variable_declarator => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    return containsYield(self, @enumFromInt(extras[e + 2])); // init
                },
                else => false,
            };
        }

        /// 연산 리스트를 switch case로 변환.
        fn buildSwitchFromOps(self: *Transformer, ops: []const Operation, span: Span) Transformer.Error!NodeIndex {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // case별 statements 수집
            var case_stmts: std.ArrayList(NodeIndex) = .empty;
            defer case_stmts.deinit(self.allocator);

            var case_num: u32 = 0;
            // label → case_num 매핑 (nop마다 case_num 증가)
            var label_to_case: std.ArrayList(u32) = .empty;
            defer label_to_case.deinit(self.allocator);

            // Phase 1: label 매핑 생성
            var nop_count: u32 = 0;
            for (ops) |op| {
                if (op.code == .nop) {
                    try label_to_case.append(self.allocator, nop_count);
                    nop_count += 1;
                }
            }
            // break_op의 label이 nop의 인덱스를 참조
            // label N → case_num = label_to_case[N] (사실 nop 순서대로 번호 매김)
            // 간소화: label = case number 직접 사용

            // Phase 2: case 생성
            var current_case_stmts: std.ArrayList(NodeIndex) = .empty;
            defer current_case_stmts.deinit(self.allocator);

            for (ops) |op| {
                switch (op.code) {
                    .nop => {
                        // 이전 case 마무리 (문이 있으면)
                        if (current_case_stmts.items.len > 0) {
                            const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                            try self.scratch.append(self.allocator, case_node);
                            current_case_stmts.clearRetainingCapacity();
                            case_num += 1;
                        }
                    },
                    .statement => {
                        if (op.arg == .node and !op.arg.node.isNone()) {
                            try current_case_stmts.append(self.allocator, op.arg.node);
                        }
                    },
                    .yield_op => {
                        // return [4, value]
                        const ret = try buildInstructionReturn(self, 4, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                        // case 마무리 (다음 nop에서 새 case가 시작됨)
                    },
                    .return_op => {
                        // return [2, value]
                        const ret = try buildInstructionReturn(self, 2, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_op => {
                        // return [3, label]
                        const label = if (op.arg == .label) op.arg.label else 0;
                        var label_buf: [16]u8 = undefined;
                        const label_str = std.fmt.bufPrint(&label_buf, "{d}", .{label}) catch "0";
                        const label_span = try self.new_ast.addString(label_str);
                        const label_node = try self.new_ast.addNode(.{
                            .tag = .numeric_literal,
                            .span = label_span,
                            .data = .{ .none = 0 },
                        });
                        const ret = try buildInstructionReturn(self, 3, label_node, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_when_false => {
                        if (op.arg == .label_and_node) {
                            const label = op.arg.label_and_node.label;
                            const cond = op.arg.label_and_node.node;
                            // if (!(cond)) return [3, label]
                            // 괄호로 감싸서 우선순위 보장
                            const paren_cond = try self.new_ast.addNode(.{
                                .tag = .parenthesized_expression,
                                .span = span,
                                .data = .{ .unary = .{ .operand = cond, .flags = 0 } },
                            });
                            const neg = try self.new_ast.addNode(.{
                                .tag = .unary_expression,
                                .span = span,
                                .data = .{ .extra = try self.new_ast.addExtras(&.{
                                    @intFromEnum(paren_cond),
                                    @intFromEnum(token_mod.Kind.bang),
                                }) },
                            });
                            var buf: [16]u8 = undefined;
                            const label_str = std.fmt.bufPrint(&buf, "{d}", .{label}) catch "0";
                            const label_span = try self.new_ast.addString(label_str);
                            const label_node = try self.new_ast.addNode(.{
                                .tag = .numeric_literal,
                                .span = label_span,
                                .data = .{ .none = 0 },
                            });
                            const break_ret = try buildInstructionReturn(self, 3, label_node, span);
                            // if (!cond) { return [3, label]; }
                            const if_body_list = try self.new_ast.addNodeList(&.{break_ret});
                            const if_body = try self.new_ast.addNode(.{
                                .tag = .block_statement,
                                .span = span,
                                .data = .{ .list = if_body_list },
                            });
                            const if_stmt = try self.new_ast.addNode(.{
                                .tag = .if_statement,
                                .span = span,
                                .data = .{ .ternary = .{ .a = neg, .b = if_body, .c = .none } },
                            });
                            try current_case_stmts.append(self.allocator, if_stmt);
                        }
                    },
                    .break_when_true => {
                        // 유사한 패턴 (조건 반전 없음)
                        if (op.arg == .label_and_node) {
                            const label = op.arg.label_and_node.label;
                            const cond = op.arg.label_and_node.node;
                            var buf: [16]u8 = undefined;
                            const label_str = std.fmt.bufPrint(&buf, "{d}", .{label}) catch "0";
                            const label_span = try self.new_ast.addString(label_str);
                            const label_node = try self.new_ast.addNode(.{
                                .tag = .numeric_literal,
                                .span = label_span,
                                .data = .{ .none = 0 },
                            });
                            const break_ret = try buildInstructionReturn(self, 3, label_node, span);
                            const if_body_list = try self.new_ast.addNodeList(&.{break_ret});
                            const if_body = try self.new_ast.addNode(.{
                                .tag = .block_statement,
                                .span = span,
                                .data = .{ .list = if_body_list },
                            });
                            const if_stmt = try self.new_ast.addNode(.{
                                .tag = .if_statement,
                                .span = span,
                                .data = .{ .ternary = .{ .a = cond, .b = if_body, .c = .none } },
                            });
                            try current_case_stmts.append(self.allocator, if_stmt);
                        }
                    },
                    .yield_star => {
                        // return [5, iter]
                        const ret = try buildInstructionReturn(self, 5, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                }
            }

            // 마지막 case
            if (current_case_stmts.items.len > 0) {
                const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                try self.scratch.append(self.allocator, case_node);
            }

            // switch(_state.label) { cases... }
            const state_ref = try buildStateRef(self, span);
            const label_span_str = try self.new_ast.addString("label");
            const label_prop = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = label_span_str,
                .data = .{ .string_ref = label_span_str },
            });
            const member_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(state_ref), @intFromEnum(label_prop), 0,
            });
            const discriminant = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });

            // switch_statement: extra = [discriminant, cases_start, cases_len]
            const cases_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const switch_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(discriminant),
                cases_list.start,
                cases_list.len,
            });
            return self.new_ast.addNode(.{
                .tag = .switch_statement,
                .span = span,
                .data = .{ .extra = switch_extra },
            });
        }

        /// switch case 노드 생성: case N: stmts...
        /// switch_case: extra = [test_expr, stmts_start, stmts_len]
        fn buildSwitchCase(self: *Transformer, case_num: u32, stmts: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            var buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&buf, "{d}", .{case_num}) catch "0";
            const num_span = try self.new_ast.addString(num_str);
            const test_node = try self.new_ast.addNode(.{
                .tag = .numeric_literal,
                .span = num_span,
                .data = .{ .none = 0 },
            });

            const body_list = try self.new_ast.addNodeList(stmts);
            const case_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(test_node),
                body_list.start,
                body_list.len,
            });

            return self.new_ast.addNode(.{
                .tag = .switch_case,
                .span = span,
                .data = .{ .extra = case_extra },
            });
        }

        /// return [instruction, value] 문 생성.
        fn buildInstructionReturn(self: *Transformer, instruction: u32, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            var buf: [16]u8 = undefined;
            const inst_str = std.fmt.bufPrint(&buf, "{d}", .{instruction}) catch "0";
            const inst_span = try self.new_ast.addString(inst_str);
            const inst_node = try self.new_ast.addNode(.{
                .tag = .numeric_literal,
                .span = inst_span,
                .data = .{ .none = 0 },
            });

            const arr_items = if (!value.isNone())
                try self.new_ast.addNodeList(&.{ inst_node, value })
            else
                try self.new_ast.addNodeList(&.{inst_node});

            const arr = try self.new_ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_items },
            });

            return self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = arr, .flags = 0 } },
            });
        }

        /// _state.sent() 호출 생성.
        fn buildSentCall(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const state_ref = try buildStateRef(self, span);
            const sent_span = try self.new_ast.addString("sent");
            const sent_prop = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = sent_span,
                .data = .{ .string_ref = sent_span },
            });
            const member_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(state_ref), @intFromEnum(sent_prop), 0,
            });
            const sent_member = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });
            const call_args = try self.new_ast.addNodeList(&.{});
            const call_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(sent_member), call_args.start, call_args.len, 0,
            });
            return self.new_ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call_extra },
            });
        }

        /// _state identifier reference 생성.
        fn buildStateRef(self: *Transformer, _: Span) Transformer.Error!NodeIndex {
            const state_span = try self.new_ast.addString("_state");
            return self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = state_span,
                .data = .{ .string_ref = state_span },
            });
        }

        /// __generator(function(_state) { switch_body }) 호출 생성.
        fn buildGeneratorHelperCall(self: *Transformer, switch_body: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.generator = true;

            // _state 파라미터
            const state_span = try self.new_ast.addString("_state");
            const state_param = try self.new_ast.addNode(.{
                .tag = .binding_identifier,
                .span = state_span,
                .data = .{ .string_ref = state_span },
            });

            // function body: switch_body를 block으로 감싸기
            const body_list = try self.new_ast.addNodeList(&.{switch_body});
            const body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // function(_state) { ... }
            const params = try self.new_ast.addNodeList(&.{state_param});
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                none, // anonymous
                params.start,
                params.len,
                @intFromEnum(body),
                0, // flags
                none,
            });
            const func_expr = try self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // __generator(func)
            const gen_span = try self.new_ast.addString("__generator");
            const gen_ref = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = gen_span,
                .data = .{ .string_ref = gen_span },
            });
            const call_args = try self.new_ast.addNodeList(&.{func_expr});
            const call_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(gen_ref), call_args.start, call_args.len, 0,
            });
            return self.new_ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call_extra },
            });
        }
    };
}

test "ES2015 generator module compiles" {
    _ = ES2015Generator;
}
