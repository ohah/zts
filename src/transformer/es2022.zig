//! ES2022 다운레벨링: class static block
//!
//! --target < es2022 일 때 활성화.
//! class Foo { static { this.x = 1; } }
//! → class Foo {} (() => { Foo.x = 1; })();
//!
//! static block 안의 `this`는 클래스 자체를 참조한다.
//! IIFE로 추출하면 arrow function의 `this`가 outer scope를 가리키게 되므로,
//! `this` → 클래스 이름으로 치환해야 한다 (oxc 방식: this_depth 카운터).
//!
//! - 일반 함수(function)는 자체 `this` 바인딩 → this_depth 증가 → 치환 안 함
//! - arrow function은 `this` 상속 → this_depth 변경 없음 → 치환됨
//! - 익명 클래스는 치환하지 않음 (this가 outer scope 가리킴)
//!
//! 스펙:
//! - class static block: https://tc39.es/ecma262/#sec-static-blocks (ES2022, TC39 Stage 4)
//!                        https://github.com/tc39/proposal-class-static-block
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower_class.go (lowerAllStaticFields)
//! - oxc: crates/oxc_transformer/src/es2022/ (StaticVisitor, this_depth)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2022(comptime Transformer: type) type {
    return struct {
        /// 클래스 바디에서 static block을 제거하고, IIFE로 변환하여 pending_nodes에 추가한다.
        /// 반환값: static block이 있었으면 true, 없었으면 false.
        ///
        /// class_name_span: 클래스 이름의 Span. null이면 익명 클래스 (this 치환 안 함).
        ///
        /// 동작:
        ///   1. 원본 class_body의 멤버를 순회
        ///   2. static_block이 아닌 멤버 → 그대로 방문하여 새 body에 추가
        ///   3. static_block → body에서 제거하고 IIFE로 변환, static_blocks에 수집
        ///   4. 호출자가 class 노드를 pending_nodes에 넣고, static_blocks의 IIFE를 그 뒤에 추가
        pub fn lowerStaticBlocks(
            self: *Transformer,
            body_idx: NodeIndex,
            new_body_out: *NodeIndex,
            static_block_iifes: *std.ArrayList(NodeIndex),
            class_name_span: ?Span,
        ) Transformer.Error!bool {
            const body_node = self.old_ast.getNode(body_idx);
            const body_members = self.old_ast.extra_data.items[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];

            // 먼저 static block이 있는지 빠르게 확인
            var has_static_block = false;
            for (body_members) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .static_block) {
                    has_static_block = true;
                    break;
                }
            }

            if (!has_static_block) return false;

            // static block이 있으면: 멤버를 분류하여 새 body를 생성
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // pending_nodes save/restore: 중첩 호출에 안전
            const pending_top = self.pending_nodes.items.len;
            defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

            for (body_members) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .static_block) {
                    // static block → IIFE로 변환
                    const iife = try buildStaticBlockIIFE(self, member, class_name_span);
                    try static_block_iifes.append(self.allocator, iife);
                } else {
                    // 일반 멤버 → 그대로 방문
                    const new_member = try self.visitNode(@enumFromInt(raw_idx));

                    // pending_nodes 드레인
                    if (self.pending_nodes.items.len > pending_top) {
                        try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                        self.pending_nodes.shrinkRetainingCapacity(pending_top);
                    }

                    if (!new_member.isNone()) {
                        try self.scratch.append(self.allocator, new_member);
                    }
                }
            }

            // 새 class_body 노드 생성
            const new_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            new_body_out.* = try self.new_ast.addNode(.{
                .tag = .class_body,
                .span = body_node.span,
                .data = .{ .list = new_list },
            });

            return true;
        }

        /// static block의 body를 IIFE `(() => { ...body... })()`로 변환.
        /// static block: unary node, operand = block_statement (function_body)
        ///
        /// class_name_span이 있으면 body 안의 this → 클래스 이름으로 치환.
        /// 치환은 transformer의 static_block_class_name / this_depth 필드를 통해
        /// visitNode(.this_expression) 단계에서 수행된다.
        pub fn buildStaticBlockIIFE(self: *Transformer, static_block_node: Node, class_name_span: ?Span) Transformer.Error!NodeIndex {
            // static block body 방문 시 this 치환 컨텍스트 설정
            const saved_class_name = self.static_block_class_name;
            const saved_this_depth = self.this_depth;
            self.static_block_class_name = class_name_span;
            self.this_depth = 0;
            defer {
                self.static_block_class_name = saved_class_name;
                self.this_depth = saved_this_depth;
            }

            // static block의 body를 방문
            const new_body = try self.visitNode(static_block_node.data.unary.operand);

            const span = static_block_node.span;

            // 빈 formal_parameters 노드 생성
            const empty_params_list = try self.new_ast.addNodeList(&.{});
            const params = try self.new_ast.addNode(.{
                .tag = .formal_parameters,
                .span = span,
                .data = .{ .list = empty_params_list },
            });

            // arrow_function_expression: extra = [params, body, flags]
            // flags = 0 (non-async)
            const arrow_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(params),
                @intFromEnum(new_body),
                0, // flags
            });
            const arrow = try self.new_ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = span,
                .data = .{ .extra = arrow_extra },
            });

            // 괄호로 감싸기: (arrow)
            const paren_arrow = try self.new_ast.addNode(.{
                .tag = .parenthesized_expression,
                .span = span,
                .data = .{ .unary = .{ .operand = arrow, .flags = 0 } },
            });

            // call_expression: extra = [callee, args_start, args_len, flags]
            const empty_args = try self.new_ast.addNodeList(&.{});
            const call = try self.new_ast.addExtras(&.{
                @intFromEnum(paren_arrow),
                empty_args.start,
                empty_args.len,
                0, // flags
            });
            const call_node = try self.new_ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call },
            });

            // expression_statement로 감싸기
            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call_node, .flags = 0 } },
            });
        }
    };
}
