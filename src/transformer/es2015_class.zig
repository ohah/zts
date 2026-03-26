//! ES2015 다운레벨링: class
//!
//! --target < es2015 일 때 활성화.
//! class Foo { constructor(x) { this.x = x; } method() {} }
//! → function Foo(x) { this.x = x; } Foo.prototype.method = function() {};
//!
//! class Bar extends Foo { constructor() { super(); } }
//! → function Bar() { Foo.call(this); } __extends(Bar, Foo);
//!
//! 런타임 헬퍼: __extends (prototype chain + constructor 설정)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-class-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/classes/ (~1620줄)
//! - esbuild: pkg/js_parser/js_parser_lower_class.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Class(comptime _: type) type {
    return struct {
        // TODO: lowerClassDeclaration
        // TODO: lowerClassExpression
        // TODO: buildConstructorFunction
        // TODO: buildPrototypeAssignment
        // TODO: buildExtendsHelper
    };
}

test "ES2015 class module compiles" {
    _ = ES2015Class;
}
