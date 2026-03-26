//! ES2015 다운레벨링: computed property
//!
//! --target < es2015 일 때 활성화.
//! { [key]: value } → (_o = {}, _o[key] = value, _o)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-object-initialiser (ES2015, computed property names)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/computed_props.rs (~458줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Computed(comptime _: type) type {
    return struct {
        // TODO: lowerComputedProperty
    };
}

test "ES2015 computed module compiles" {
    _ = ES2015Computed;
}
