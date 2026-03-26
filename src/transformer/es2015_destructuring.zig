//! ES2015 다운레벨링: destructuring
//!
//! --target < es2015 일 때 활성화.
//! const { a, b } = obj → var _obj = obj, a = _obj.a, b = _obj.b
//! const [x, y] = arr → var _arr = arr, x = _arr[0], y = _arr[1]
//! const { a, ...rest } = obj → var _obj = obj, a = _obj.a, rest = __rest(_obj, ["a"])
//! function f({ x, y }) {} → function f(_ref) { var x = _ref.x, y = _ref.y; }
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-destructuring-assignment (ES2015)
//! - https://tc39.es/ecma262/#sec-destructuring-binding-patterns (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/destructuring.rs (~1388줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Destructuring(comptime _: type) type {
    return struct {
        // TODO: lowerObjectDestructuring
        // TODO: lowerArrayDestructuring
        // TODO: lowerDestructuringAssignment
        // TODO: lowerDestructuringParam
    };
}

test "ES2015 destructuring module compiles" {
    _ = ES2015Destructuring;
}
