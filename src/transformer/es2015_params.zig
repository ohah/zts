//! ES2015 다운레벨링: default parameters + rest parameters
//!
//! --target < es2015 일 때 활성화.
//! function f(x = 1) {} → function f(x) { x = x === void 0 ? 1 : x; }
//! function f(...args) {} → function f() { var args = [].slice.call(arguments); }
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
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Params(comptime _: type) type {
    return struct {
        // TODO: lowerDefaultParams
        // TODO: lowerRestParams
    };
}

test "ES2015 params module compiles" {
    _ = ES2015Params;
}
