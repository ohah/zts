//! ES2015 다운레벨링: class → function + prototype
//!
//! --target < es2015 일 때 활성화.
//!
//! class Foo { constructor(x) { this.x = x; } method() {} }
//! → function Foo(x) { this.x = x; }
//!   Foo.prototype.method = function() {};
//!
//! static method() {} → Foo.method = function() {};
//!
//! 제한사항 (v1):
//!   - extends / super: 미지원
//!   - getter/setter: 미지원 (Object.defineProperty 필요)
//!   - private members (#field): 미지원
//!   - class expression: 미지원 (declaration만)
//!   - static blocks: 무시 (ES2022 변환이 먼저 처리)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-class-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/classes/ (~1620줄)
//! - esbuild: pkg/js_parser/js_parser_lower_class.go (~2578줄)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Class(comptime Transformer: type) type {
    return struct {
        /// class_declaration을 function + prototype assignment로 변환.
        ///
        /// class: extra = [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len]
        /// 반환: function_declaration. 나머지 prototype assignment는 pending_nodes에 추가.
        pub fn lowerClassDeclaration(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = @enumFromInt(extras[e]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 2]);

            // 클래스 이름 추출
            const new_name = try self.visitNode(name_idx);
            const name_span = if (!new_name.isNone())
                self.new_ast.getNode(new_name).data.string_ref
            else
                try self.new_ast.addString("_Class");

            // 클래스 바디 멤버 분류
            const body_node = self.old_ast.getNode(body_idx);
            const members = self.old_ast.extra_data.items[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];

            var constructor_idx: ?NodeIndex = null;
            var methods: std.ArrayList(MethodInfo) = .empty;
            defer methods.deinit(self.allocator);
            var instance_fields: std.ArrayList(NodeIndex) = .empty;
            defer instance_fields.deinit(self.allocator);
            var static_fields: std.ArrayList(FieldInfo) = .empty;
            defer static_fields.deinit(self.allocator);

            for (members) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const key: NodeIndex = @enumFromInt(extras[me]);
                    const flags = extras[me + 4];
                    const is_static = (flags & 0x01) != 0;

                    if (!is_static and isConstructorKey(self, key)) {
                        constructor_idx = @enumFromInt(raw_idx);
                        continue;
                    }

                    try methods.append(self.allocator, .{
                        .member_idx = @enumFromInt(raw_idx),
                        .is_static = is_static,
                    });
                } else if (member.tag == .property_definition) {
                    // property_definition: extra = [key, init_val, flags, deco_start, deco_len]
                    const pe = member.data.extra;
                    const key: NodeIndex = @enumFromInt(extras[pe]);
                    const init_val: NodeIndex = @enumFromInt(extras[pe + 1]);
                    const flags = extras[pe + 2];
                    const is_static = (flags & 0x01) != 0;

                    if (is_static and !init_val.isNone()) {
                        try static_fields.append(self.allocator, .{ .key = key, .init = init_val });
                    } else if (!is_static and !init_val.isNone()) {
                        // this.key = init → constructor body에 삽입
                        const this_node = try self.new_ast.addNode(.{
                            .tag = .this_expression,
                            .span = span,
                            .data = .{ .none = 0 },
                        });
                        const field_stmt = try buildFieldAssign(self, this_node, key, init_val, span);
                        try instance_fields.append(self.allocator, field_stmt);
                    }
                }
                // static_block 등은 ES2022 변환이 먼저 처리
            }

            // --- function declaration 생성 (pending_nodes에 추가) ---
            var func_node = if (constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, new_name, span)
            else
                try buildEmptyFunction(self, new_name, span);

            // instance fields → constructor body 앞에 삽입
            if (instance_fields.items.len > 0) {
                func_node = try prependToFunctionBody(self, func_node, instance_fields.items);
            }

            try self.pending_nodes.append(self.allocator, func_node);

            // --- prototype assignment 생성 (pending_nodes에 추가) ---
            for (methods.items) |info| {
                const proto_assign = try buildPrototypeAssignment(self, info, name_span, span);
                try self.pending_nodes.append(self.allocator, proto_assign);
            }

            // --- static fields → ClassName.field = value ---
            for (static_fields.items) |field| {
                const class_ref = try self.new_ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = name_span,
                    .data = .{ .string_ref = name_span },
                });
                const static_assign = try buildFieldAssign(self, class_ref, field.key, field.init, span);
                try self.pending_nodes.append(self.allocator, static_assign);
            }

            // 모든 노드를 pending_nodes에 넣었으므로 .none 반환
            return .none;
        }

        const MethodInfo = struct {
            member_idx: NodeIndex,
            is_static: bool,
        };

        const FieldInfo = struct {
            key: NodeIndex,
            init: NodeIndex,
        };

        /// obj.key = init expression_statement 생성.
        /// instance field: obj = this, static field: obj = ClassName identifier.
        fn buildFieldAssign(self: *Transformer, obj: NodeIndex, key_idx: NodeIndex, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const new_key = try self.visitNode(key_idx);
            const me = try self.new_ast.addExtras(&.{ @intFromEnum(obj), @intFromEnum(new_key), 0 });
            const member = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = me },
            });
            const new_init = try self.visitNode(init_idx);
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member, .right = new_init, .flags = 0 } },
            });
            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// function_declaration의 body 앞에 문들을 삽입
        fn prependToFunctionBody(self: *Transformer, func_idx: NodeIndex, stmts: []const NodeIndex) Transformer.Error!NodeIndex {
            const func = self.new_ast.getNode(func_idx);
            const extras = self.new_ast.extra_data.items;
            const fe = func.data.extra;

            // function: extra = [name, params_start, params_len, body, flags, return_type]
            const body_idx: NodeIndex = @enumFromInt(extras[fe + 3]);
            const new_body = try self.prependStatementsToBody(body_idx, stmts);

            // function 노드를 새 body로 재생성
            const none = @intFromEnum(NodeIndex.none);
            const new_extra = try self.new_ast.addExtras(&.{
                extras[fe], // name
                extras[fe + 1], // params_start
                extras[fe + 2], // params_len
                @intFromEnum(new_body),
                extras[fe + 4], // flags
                none,
            });
            return self.new_ast.addNode(.{
                .tag = func.tag,
                .span = func.span,
                .data = .{ .extra = new_extra },
            });
        }

        /// constructor인지 확인 (key가 "constructor" identifier)
        fn isConstructorKey(self: *const Transformer, key_idx: NodeIndex) bool {
            if (key_idx.isNone()) return false;
            const key = self.old_ast.getNode(key_idx);
            if (key.tag != .identifier_reference and key.tag != .binding_identifier) return false;
            const text = self.old_ast.source[key.data.string_ref.start..key.data.string_ref.end];
            return std.mem.eql(u8, text, "constructor");
        }

        /// constructor method_definition에서 function_declaration 생성.
        /// method_definition: extra = [key, params_start, params_len, body, flags, ...]
        fn buildFunctionFromConstructor(self: *Transformer, ctor_idx: NodeIndex, name: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const ctor = self.old_ast.getNode(ctor_idx);
            const extras = self.old_ast.extra_data.items;
            const me = ctor.data.extra;

            const params_start = extras[me + 1];
            const params_len = extras[me + 2];
            const body_idx: NodeIndex = @enumFromInt(extras[me + 3]);

            const new_params = try self.visitExtraList(params_start, params_len);
            const new_body = try self.visitNode(body_idx);

            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(name),
                new_params.start,
                new_params.len,
                @intFromEnum(new_body),
                0, // flags (no async/generator)
                none, // return_type
            });
            return self.new_ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// 빈 function declaration (constructor가 없는 경우)
        fn buildEmptyFunction(self: *Transformer, name: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // 빈 body
            const empty_list = try self.new_ast.addNodeList(&.{});
            const empty_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = empty_list },
            });

            const empty_params = try self.new_ast.addNodeList(&.{});
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(name),
                empty_params.start,
                empty_params.len,
                @intFromEnum(empty_body),
                0,
                none,
            });
            return self.new_ast.addNode(.{
                .tag = .function_declaration,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// method → ClassName.prototype.method = function() {} (expression_statement)
        /// static method → ClassName.method = function() {}
        fn buildPrototypeAssignment(self: *Transformer, info: MethodInfo, class_name_span: Span, span: Span) Transformer.Error!NodeIndex {
            const member = self.old_ast.getNode(info.member_idx);
            const extras = self.old_ast.extra_data.items;
            const me = member.data.extra;

            const key_idx: NodeIndex = @enumFromInt(extras[me]);
            const params_start = extras[me + 1];
            const params_len = extras[me + 2];
            const body_idx: NodeIndex = @enumFromInt(extras[me + 3]);
            const flags = extras[me + 4];

            // function expression 생성
            const new_params = try self.visitExtraList(params_start, params_len);
            const new_body = try self.visitNode(body_idx);

            const func_flags: u32 = blk: {
                var f: u32 = 0;
                if (flags & 0x08 != 0) f |= 0x01; // async
                if (flags & 0x10 != 0) f |= 0x02; // generator
                break :blk f;
            };

            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                none, // anonymous
                new_params.start,
                new_params.len,
                @intFromEnum(new_body),
                func_flags,
                none,
            });
            const func_expr = try self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // ClassName 또는 ClassName.prototype
            const class_ref = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = class_name_span,
                .data = .{ .string_ref = class_name_span },
            });

            const target = if (info.is_static)
                class_ref
            else blk: {
                // ClassName.prototype
                const proto_span = try self.new_ast.addString("prototype");
                const proto_prop = try self.new_ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = proto_span,
                    .data = .{ .string_ref = proto_span },
                });
                const proto_extra = try self.new_ast.addExtras(&.{
                    @intFromEnum(class_ref), @intFromEnum(proto_prop), 0,
                });
                break :blk try self.new_ast.addNode(.{
                    .tag = .static_member_expression,
                    .span = span,
                    .data = .{ .extra = proto_extra },
                });
            };

            // target.methodName
            const new_key = try self.visitNode(key_idx);
            const member_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(target), @intFromEnum(new_key), 0,
            });
            const member_access = try self.new_ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });

            // target.methodName = function() {}
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member_access, .right = func_expr, .flags = 0 } },
            });

            // expression_statement
            return self.new_ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }
    };
}

test "ES2015 class module compiles" {
    _ = ES2015Class;
}
