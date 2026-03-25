//! ES 다운레벨링 공통 헬퍼
//!
//! 임시 변수 생성, void 0, null 비교 등 여러 ES 버전 변환에서 공유하는 유틸리티.
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower_class.go (privateTempRef 패턴)
//! - `== null` vs `=== null`: JS에서 `x == null`은 null과 undefined 모두 체크 (loose equality)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

/// 임시 변수명 생성: _a, _b, _c, ..., _a2, _b2, ...
pub fn makeTempVarSpan(self: anytype) !Span {
    const idx = self.temp_var_counter;
    self.temp_var_counter += 1;
    var buf: [16]u8 = undefined;
    const letter: u8 = 'a' + @as(u8, @intCast(idx % 26));
    const cycle = idx / 26;
    const name = if (cycle == 0)
        std.fmt.bufPrint(&buf, "_{c}", .{letter}) catch return error.OutOfMemory
    else
        std.fmt.bufPrint(&buf, "_{c}{d}", .{ letter, cycle + 1 }) catch return error.OutOfMemory;
    return self.new_ast.addString(name);
}

/// 임시 변수 identifier_reference 노드 생성.
pub fn makeTempVarRef(self: anytype, span: Span, node_span: Span) !NodeIndex {
    return self.new_ast.addNode(.{
        .tag = .identifier_reference,
        .span = node_span,
        .data = .{ .string_ref = span },
    });
}

/// left 노드가 단순 식별자(부작용 없음)인지 판단.
pub fn isSimpleIdentifier(self: anytype, left_idx: NodeIndex) bool {
    const left_node = self.old_ast.getNode(left_idx);
    return left_node.tag == .identifier_reference;
}

/// `void 0` 노드를 새 AST에 생성.
pub fn makeVoidZero(self: anytype, span: Span) !NodeIndex {
    const zero_span = try self.new_ast.addString("0");
    const zero_node = try self.new_ast.addNode(.{
        .tag = .numeric_literal,
        .span = zero_span,
        .data = .{ .none = 0 },
    });
    const void_extra = try self.new_ast.addExtras(&.{
        @intFromEnum(zero_node),
        @intFromEnum(token_mod.Kind.kw_void),
    });
    return self.new_ast.addNode(.{
        .tag = .unary_expression,
        .span = span,
        .data = .{ .extra = void_extra },
    });
}

/// `base == null` 노드를 새 AST에 생성.
pub fn makeEqNull(self: anytype, base: NodeIndex, span: Span) !NodeIndex {
    const null_span = try self.new_ast.addString("null");
    const null_node = try self.new_ast.addNode(.{
        .tag = .null_literal,
        .span = null_span,
        .data = .{ .none = 0 },
    });
    return self.new_ast.addNode(.{
        .tag = .binary_expression,
        .span = span,
        .data = .{ .binary = .{
            .left = base,
            .right = null_node,
            .flags = @intFromEnum(token_mod.Kind.eq2),
        } },
    });
}
