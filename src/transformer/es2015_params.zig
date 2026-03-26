//! ES2015 다운레벨링: default parameters + rest parameters
//!
//! --target < es2015 일 때 활성화.
//!
//! Default parameters:
//!   function f(x = 1) {} → function f(x) { x = x === void 0 ? 1 : x; }
//!
//! Rest parameters:
//!   function f(a, ...rest) {} → function f(a) { var rest = [].slice.call(arguments, 1); }
//!
//! 두 변환 모두 파라미터 목록을 수정하고 함수 바디 앞에 문을 삽입한다.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-function-definitions (ES2015, default/rest)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/parameters.rs (~845줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go (lowerFunction)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015Params(comptime Transformer: type) type {
    return struct {
        /// 파라미터 목록에서 default/rest 파라미터가 있는지 검사한다.
        pub fn hasDefaultOrRest(self: *const Transformer, params_start: u32, params_len: u32) bool {
            const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];
            for (old_params) |raw_idx| {
                const param = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (param.tag == .spread_element or param.tag == .rest_element) return true;
                if (param.tag == .formal_parameter) {
                    // extra = [pattern, type_ann, default, flags, deco_start, deco_len]
                    const extras = self.old_ast.extra_data.items;
                    const pe = param.data.extra;
                    const default_val: NodeIndex = @enumFromInt(extras[pe + 2]);
                    if (!default_val.isNone()) return true;
                }
                // assignment_pattern도 default를 의미
                if (param.tag == .assignment_pattern) return true;
            }
            return false;
        }

        /// default/rest 파라미터를 변환한다.
        /// 파라미터 목록에서 default와 rest를 제거하고,
        /// 함수 바디 앞에 초기화 문을 삽입한다.
        ///
        /// 반환: { new_params, body_prepend_stmts }
        pub fn lowerParams(
            self: *Transformer,
            params_start: u32,
            params_len: u32,
            span: Span,
        ) Transformer.Error!LowerResult {
            const old_params = self.old_ast.extra_data.items[params_start .. params_start + params_len];

            const param_scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(param_scratch_top);

            var body_stmts: std.ArrayList(NodeIndex) = .empty;

            var param_index: usize = 0; // arguments index tracking

            for (old_params) |raw_idx| {
                const param = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (param.tag == .spread_element or param.tag == .rest_element) {
                    // rest parameter: ...args → var args = [].slice.call(arguments, N)
                    const rest_binding = try self.visitNode(param.data.unary.operand);
                    const rest_stmt = try buildRestSlice(self, rest_binding, param_index, span);
                    try body_stmts.append(self.allocator, rest_stmt);
                    // rest를 params에 넣지 않음
                    continue;
                }

                if (param.tag == .formal_parameter) {
                    // extra = [pattern, type_ann, default, flags, deco_start, deco_len]
                    const pe = param.data.extra;
                    const extras = self.old_ast.extra_data.items;
                    const pattern_idx: NodeIndex = @enumFromInt(extras[pe]);
                    const default_idx: NodeIndex = @enumFromInt(extras[pe + 2]);

                    if (!default_idx.isNone()) {
                        // default parameter: x = val → x; body에 x = x === void 0 ? val : x 삽입
                        const new_pattern = try self.visitNode(pattern_idx);
                        try self.scratch.append(self.allocator, new_pattern);

                        const new_default = try self.visitNode(default_idx);
                        const default_stmt = try buildDefaultCheck(self, new_pattern, new_default, span);
                        try body_stmts.append(self.allocator, default_stmt);
                        param_index += 1;
                        continue;
                    }
                }

                if (param.tag == .assignment_pattern) {
                    // assignment_pattern: binary { left=pattern, right=default }
                    const new_pattern = try self.visitNode(param.data.binary.left);
                    try self.scratch.append(self.allocator, new_pattern);

                    const new_default = try self.visitNode(param.data.binary.right);
                    const default_stmt = try buildDefaultCheck(self, new_pattern, new_default, span);
                    try body_stmts.append(self.allocator, default_stmt);
                    param_index += 1;
                    continue;
                }

                // 일반 파라미터: 그대로 방문
                const new_param = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_param.isNone()) {
                    try self.scratch.append(self.allocator, new_param);
                }
                param_index += 1;
            }

            const new_params = try self.new_ast.addNodeList(self.scratch.items[param_scratch_top..]);

            return .{
                .new_params = new_params,
                .body_stmts = body_stmts,
            };
        }

        pub const LowerResult = struct {
            new_params: NodeList,
            body_stmts: std.ArrayList(NodeIndex),
        };

        /// x = x === void 0 ? default_value : x
        /// → expression_statement 생성
        fn buildDefaultCheck(self: *Transformer, pattern: NodeIndex, default_val: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // void 0
            const void_zero = try es_helpers.makeVoidZero(self, span);

            // x === void 0
            const pattern_ref = try copyIdentifier(self, pattern);
            const eq_check = try self.new_ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = pattern_ref,
                    .right = void_zero,
                    .flags = @intFromEnum(token_mod.Kind.eq3),
                } },
            });

            // x === void 0 ? default_value : x
            const pattern_ref2 = try copyIdentifier(self, pattern);
            const conditional = try self.new_ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{
                    .a = eq_check,
                    .b = default_val,
                    .c = pattern_ref2,
                } },
            });

            // x = (conditional)
            const pattern_ref3 = try copyIdentifier(self, pattern);
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = pattern_ref3, .right = conditional, .flags = 0 } },
            });

            // expression_statement
            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// var rest = [].slice.call(arguments, N)
        fn buildRestSlice(self: *Transformer, binding: NodeIndex, start_index: usize, span: Span) Transformer.Error!NodeIndex {
            // [] (empty array)
            const empty_arr_list = try self.new_ast.addNodeList(&.{});
            const empty_arr = try self.new_ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = empty_arr_list },
            });

            // [].slice
            const slice_span = try self.new_ast.addString("slice");
            const slice_prop = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = slice_span,
                .data = .{ .string_ref = slice_span },
            });
            const member_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(empty_arr), @intFromEnum(slice_prop), 0,
            });
            const slice_member = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });

            // [].slice.call
            const call_span = try self.new_ast.addString("call");
            const call_prop = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = call_span,
                .data = .{ .string_ref = call_span },
            });
            const call_member_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(slice_member), @intFromEnum(call_prop), 0,
            });
            const slice_call = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = call_member_extra },
            });

            // arguments
            const args_span = try self.new_ast.addString("arguments");
            const args_ref = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = args_span,
                .data = .{ .string_ref = args_span },
            });

            // start_index number
            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{start_index}) catch "0";
            const idx_span = try self.new_ast.addString(idx_str);
            const idx_node = try self.new_ast.addNode(.{
                .tag = .numeric_literal,
                .span = idx_span,
                .data = .{ .none = 0 },
            });

            // [].slice.call(arguments, N)
            const call_args = try self.new_ast.addNodeList(&.{ args_ref, idx_node });
            const call_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(slice_call),
                call_args.start,
                call_args.len,
                0,
            });
            const call_node = try self.new_ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call_extra },
            });

            // var rest = [].slice.call(arguments, N)
            const declarator_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(binding),
                @intFromEnum(NodeIndex.none),
                @intFromEnum(call_node),
            });
            const declarator = try self.new_ast.addNode(.{
                .tag = .variable_declarator,
                .span = span,
                .data = .{ .extra = declarator_extra },
            });

            // variable_declaration: extra = [kind_flags, list_start, list_len]
            // kind_flags: 0 = var
            const decl_list = try self.new_ast.addNodeList(&.{declarator});
            const var_extra = try self.new_ast.addExtras(&.{
                0, // var
                decl_list.start,
                decl_list.len,
            });
            return self.new_ast.addNode(.{
                .tag = .variable_declaration,
                .span = span,
                .data = .{ .extra = var_extra },
            });
        }

        /// identifier 노드를 복제한다 (같은 이름의 새 노드).
        fn copyIdentifier(self: *Transformer, node_idx: NodeIndex) Transformer.Error!NodeIndex {
            const node = self.new_ast.getNode(node_idx);
            return self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = node.span,
                .data = .{ .string_ref = node.data.string_ref },
            });
        }
    };
}

test "ES2015 params module compiles" {
    _ = ES2015Params;
}
