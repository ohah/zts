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

            for (members) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const key: NodeIndex = @enumFromInt(extras[me]);
                    const flags = extras[me + 4];
                    const is_static = (flags & 0x01) != 0;

                    // constructor 감지
                    if (!is_static and isConstructorKey(self, key)) {
                        constructor_idx = @enumFromInt(raw_idx);
                        continue;
                    }

                    try methods.append(self.allocator, .{
                        .member_idx = @enumFromInt(raw_idx),
                        .is_static = is_static,
                    });
                }
                // property_definition, static_block 등은 현재 스킵
            }

            // --- function declaration 생성 (pending_nodes에 추가) ---
            const func_node = if (constructor_idx) |ctor_idx|
                try buildFunctionFromConstructor(self, ctor_idx, new_name, span)
            else
                try buildEmptyFunction(self, new_name, span);

            try self.pending_nodes.append(self.allocator, func_node);

            // --- prototype assignment 생성 (pending_nodes에 추가) ---
            for (methods.items) |info| {
                const proto_assign = try buildPrototypeAssignment(self, info, name_span, span);
                try self.pending_nodes.append(self.allocator, proto_assign);
            }

            // 모든 노드를 pending_nodes에 넣었으므로 .none 반환
            // (class 자리는 비움, visitExtraList가 pending_nodes를 순서대로 삽입)
            return .none;
        }

        const MethodInfo = struct {
            member_idx: NodeIndex,
            is_static: bool,
        };

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
