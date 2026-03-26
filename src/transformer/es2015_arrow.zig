//! ES2015 다운레벨링: arrow function
//!
//! --target < es2015 일 때 활성화.
//! () => expr       → function() { return expr; }
//! () => { stmts }  → function() { stmts }
//! (x) => x + 1     → function(x) { return x + 1; }
//! x => x + 1       → function(x) { return x + 1; }
//!
//! 파서에서 arrow의 params 슬롯은 세 가지 형태:
//!   1. NodeIndex.none → 빈 파라미터 (() => ...)
//!   2. binding_identifier → 단일 파라미터 (x => ...)
//!   3. formal_parameters(list) → 괄호 형태 ((x, y) => ...)
//!
//! this/arguments 캡처:
//!   arrow body 안의 this → _this, arguments → _arguments로 치환.
//!   외부 함수(visitFunction)에서 var _this = this; / var _arguments = arguments; 삽입.
//!   중첩 arrow는 같은 _this를 공유, 내부 일반 함수는 별도 스코프.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-arrow-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/arrow.rs (~253줄)
//! - ZTS ES2017: es2017.zig lowerAsyncArrow

const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;

pub fn ES2015Arrow(comptime Transformer: type) type {
    return struct {
        /// arrow_function_expression → function_expression 변환.
        /// arrow body 안의 this → _this, arguments → _arguments 치환을 위해
        /// arrow_this_depth를 증가시킨 상태로 body를 방문한다.
        pub fn lowerArrowFunction(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            if (e + 2 >= extras.len) return NodeIndex.none;

            const params_idx: NodeIndex = @enumFromInt(extras[e]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const flags = extras[e + 2];

            // params 슬롯의 형태:
            //   1. none → () => ... (빈 파라미터)
            //   2. formal_parameters(list) → <T>(x, y) => ... (TS 제네릭 arrow)
            //   3. binding_identifier → x => ... (단일 파라미터, 괄호 없음)
            //   4. parenthesized_expression → (x) => ... (cover grammar)
            //      내부: identifier_reference (단일) 또는 sequence_expression (복수)
            const param_list: NodeList = if (params_idx.isNone())
                try self.new_ast.addNodeList(&.{})
            else blk: {
                const params_node = self.old_ast.getNode(params_idx);
                switch (params_node.tag) {
                    .formal_parameters => {
                        break :blk try self.visitExtraList(
                            params_node.data.list.start,
                            params_node.data.list.len,
                        );
                    },
                    .parenthesized_expression => {
                        // cover grammar: (x) 또는 (a, b, ...rest)
                        const inner_idx = params_node.data.unary.operand;
                        if (inner_idx.isNone()) {
                            break :blk try self.new_ast.addNodeList(&.{});
                        }
                        const inner = self.old_ast.getNode(inner_idx);
                        if (inner.tag == .sequence_expression) {
                            // (a, b, c) → sequence_expression의 list에서 추출
                            break :blk try self.visitExtraList(
                                inner.data.list.start,
                                inner.data.list.len,
                            );
                        } else {
                            // (x) → 단일 파라미터
                            const new_param = try self.visitNode(inner_idx);
                            break :blk try self.new_ast.addNodeList(
                                if (!new_param.isNone()) &.{new_param} else &.{},
                            );
                        }
                    },
                    else => {
                        // x => ... — 단일 binding_identifier
                        const new_param = try self.visitNode(params_idx);
                        break :blk try self.new_ast.addNodeList(
                            if (!new_param.isNone()) &.{new_param} else &.{},
                        );
                    },
                }
            };

            // arrow body 안의 this/arguments를 캡처하기 위해 depth 증가.
            // visitNode에서 this → _this, arguments → _arguments로 치환된다.
            self.arrow_this_depth += 1;
            const new_body = try self.visitNode(body_idx);
            self.arrow_this_depth -= 1;

            // expression body → { return expr; }
            const func_body = blk: {
                if (new_body.isNone()) break :blk new_body;
                const body_node = self.new_ast.getNode(new_body);
                if (body_node.tag != .block_statement and body_node.tag != .function_body) {
                    const ret = try self.new_ast.addNode(.{
                        .tag = .return_statement,
                        .span = node.span,
                        .data = .{ .unary = .{ .operand = new_body, .flags = 0 } },
                    });
                    const list = try self.new_ast.addNodeList(&.{ret});
                    break :blk try self.new_ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = list },
                    });
                }
                break :blk new_body;
            };

            // function_expression: extra = [name, params_start, params_len, body, flags, return_type]
            const func_flags: u32 = if (flags & ast_mod.ArrowFlags.is_async != 0)
                ast_mod.FunctionFlags.is_async
            else
                0;

            const none = @intFromEnum(NodeIndex.none);
            const new_extra = try self.new_ast.addExtras(&.{
                none, // name (anonymous)
                param_list.start,
                param_list.len,
                @intFromEnum(func_body),
                func_flags,
                none, // return_type
            });

            return self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = node.span,
                .data = .{ .extra = new_extra },
            });
        }
    };
}

test "ES2015 arrow module compiles" {
    _ = ES2015Arrow;
}
