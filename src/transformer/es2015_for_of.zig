//! ES2015 다운레벨링: for-of loop
//!
//! --target < es2015 일 때 활성화.
//! for (const x of arr) { } → for (var _i = 0; _i < arr.length; _i++) { var x = arr[_i]; }
//! for (const x of iterable) { } → iterator protocol 사용 (try/catch/finally)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-for-in-and-for-of-statements (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/for_of.rs (~724줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015ForOf(comptime _: type) type {
    return struct {
        // TODO: lowerForOfStatement
    };
}

test "ES2015 for-of module compiles" {
    _ = ES2015ForOf;
}
