//! ES2018 다운레벨링: object spread → Object.assign
//!
//! --target < es2018 일 때 활성화.
//! { ...obj }           → Object.assign({}, obj)
//! { a: 1, ...obj }     → Object.assign({ a: 1 }, obj)
//! { ...obj, b: 2 }     → Object.assign({}, obj, { b: 2 })
//! { a: 1, ...x, b: 2 } → Object.assign({ a: 1 }, x, { b: 2 })
//!
//! 스펙:
//! - object rest/spread: https://tc39.es/ecma262/#sec-object-initializer (ES2018, TC39 Stage 4: 2018-01)
//!                        https://github.com/tc39/proposal-object-rest-spread
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerObjectSpread)
//! - oxc: crates/oxc_transformer/src/es2018/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

/// Transformer 타입 (순환 import 방지를 위해 generic)
pub fn ES2018(comptime Transformer: type) type {
    return struct {
        /// object_expression의 프로퍼티 중 spread_element이 있는지 확인.
        /// 원본 AST를 읽어서 판단한다 (변환 전 스캔).
        pub fn hasSpreadProperty(self: *Transformer, node: Node) bool {
            const indices = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (indices) |raw_idx| {
                const child = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (child.tag == .spread_element) return true;
            }
            return false;
        }

        /// `{ a: 1, ...obj, b: 2 }` → `Object.assign({ a: 1 }, obj, { b: 2 })`
        ///
        /// 알고리즘:
        /// 1. 프로퍼티를 순회하면서 spread/non-spread 그룹으로 분할
        /// 2. 연속된 non-spread 프로퍼티는 하나의 object literal로 묶음
        /// 3. spread 프로퍼티는 피연산자만 추출 (spread를 벗김)
        /// 4. 모든 그룹을 Object.assign(target, ...groups) 인자로 전달
        /// 5. 첫 번째 인자가 이미 object literal이면 그것이 target, 아니면 {}를 삽입
        pub fn lowerObjectSpread(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const old_indices = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];

            // scratch 버퍼를 사용해 Object.assign 인자 수집
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // 상태: 현재 non-spread 그룹을 쌓고 있는지
            var group_start: usize = scratch_top;

            for (old_indices) |raw_idx| {
                const child = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (child.tag == .spread_element) {
                    // 1) 쌓아둔 non-spread 그룹을 object literal로 플러시
                    if (self.scratch.items.len > group_start) {
                        const obj = try buildObjectLiteral(self,node.span, self.scratch.items[group_start..]);
                        // group 영역을 줄이고, 결과 노드를 인자로 추가
                        self.scratch.shrinkRetainingCapacity(group_start);
                        try self.scratch.append(self.allocator, obj);
                        group_start = self.scratch.items.len;
                    }

                    // 2) spread의 피연산자를 방문하여 인자로 추가
                    const operand = try self.visitNode(child.data.unary.operand);
                    try self.scratch.append(self.allocator, operand);
                    group_start = self.scratch.items.len;
                } else {
                    // non-spread: 자식을 방문하고 그룹에 추가
                    const new_child = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_child.isNone()) {
                        try self.scratch.append(self.allocator, new_child);
                    }
                }
            }

            // 마지막 남은 non-spread 그룹 플러시
            if (self.scratch.items.len > group_start) {
                const obj = try buildObjectLiteral(self,node.span, self.scratch.items[group_start..]);
                self.scratch.shrinkRetainingCapacity(group_start);
                try self.scratch.append(self.allocator, obj);
            }

            // 인자 목록: scratch_top..현재
            const args_slice = self.scratch.items[scratch_top..];

            // 첫 인자가 object literal이 아니면 빈 {} 를 앞에 삽입
            // (esbuild 동작: spread만 있거나, 첫 요소가 spread면 {}를 target으로 사용)
            const need_empty_target = args_slice.len == 0 or blk: {
                const first_node = self.new_ast.getNode(args_slice[0]);
                break :blk first_node.tag != .object_expression;
            };

            if (need_empty_target) {
                // 빈 object literal {} 생성
                const empty_obj = try buildObjectLiteral(self,node.span, &.{});
                // args_slice 앞에 삽입: scratch에 빈 obj를 끼워넣기
                // 간단한 방법: 새 scratch 영역에 [empty_obj] + args_slice 복사
                const old_args_len = args_slice.len;
                // 공간 확보
                try self.scratch.ensureUnusedCapacity(self.allocator, 1);
                // 기존 인자를 한 칸 뒤로 밀기
                if (old_args_len > 0) {
                    // ensureUnusedCapacity 후 appendAssumeCapacity로 더미 추가
                    self.scratch.appendAssumeCapacity(.none);
                    const items = self.scratch.items;
                    // scratch_top..(scratch_top + old_args_len) → scratch_top+1..(scratch_top + old_args_len + 1)
                    std.mem.copyBackwards(NodeIndex, items[scratch_top + 1 .. scratch_top + 1 + old_args_len], items[scratch_top .. scratch_top + old_args_len]);
                }
                self.scratch.items[scratch_top] = empty_obj;
            }

            const final_args = self.scratch.items[scratch_top..];

            return buildObjectAssignCall(self, node.span, final_args);
        }

        /// non-spread 프로퍼티 노드 인덱스 배열로 object_expression을 생성.
        fn buildObjectLiteral(self: *Transformer, span: Span, props: []const NodeIndex) Transformer.Error!NodeIndex {
            const list = try self.new_ast.addNodeList(props);
            return self.new_ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = list },
            });
        }

        /// Object.assign(arg0, arg1, ...) 호출 노드를 생성.
        fn buildObjectAssignCall(self: *Transformer, span: Span, args: []const NodeIndex) Transformer.Error!NodeIndex {
            // "Object" 식별자
            const object_span = try self.new_ast.addString("Object");
            const object_node = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = object_span,
                .data = .{ .string_ref = object_span },
            });

            // "assign" 식별자
            const assign_span = try self.new_ast.addString("assign");
            const assign_node = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = assign_span,
                .data = .{ .string_ref = assign_span },
            });

            // Object.assign (static member expression) — extra = [object, property, flags]
            const member_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(object_node),
                @intFromEnum(assign_node),
                0,
            });
            const callee = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });

            // 인자 리스트
            const args_list = try self.new_ast.addNodeList(args);

            // call_expression: extra = [callee, args_start, args_len, flags]
            const call_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(callee),
                args_list.start,
                args_list.len,
                0,
            });
            return self.new_ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call_extra },
            });
        }
    };
}

test "ES2018 module compiles" {
    // 모듈 컴파일 확인용 빈 테스트
    _ = ES2018;
}
