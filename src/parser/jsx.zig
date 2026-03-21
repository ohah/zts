//! JSX 파싱
//!
//! JSX element, fragment, attribute를 파싱하는 함수들.
//! oxc의 jsx/mod.rs에 대응.
//!
//! 참고: references/oxc/crates/oxc_parser/src/jsx/mod.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;
const Kind = @import("../lexer/token.zig").Kind;

/// JSX children 루프: <tag>...</tag> 또는 <>...</> 내부의 자식 노드들을 파싱.
/// element와 fragment에서 공유.
fn parseJSXChildren(self: *Parser) ParseError2!ast_mod.NodeList {
    const children_top = self.saveScratch();
    while (self.current() != .eof) {
        if (self.current() == .l_angle) {
            if (try self.peekNextKindJSX() == .slash) break;
            const child = try parseJSXElement(self);
            try self.scratch.append(self.allocator, child);
        } else if (self.current() == .l_curly) {
            const expr_start = self.currentSpan().start;
            try self.advance(); // skip {
            const expr = try self.parseExpression();
            // expect(.r_curly) 대신 수동 체크: JSX children에서는 nextJSXChild()로 스캔해야 함
            if (self.current() != .r_curly) {
                try self.errors.append(self.allocator, .{
                    .span = self.currentSpan(),
                    .message = Kind.r_curly.symbol(),
                    .found = self.current().symbol(),
                });
            }
            const container = try self.ast.addNode(.{
                .tag = .jsx_expression_container,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
            try self.scratch.append(self.allocator, container);
            try self.scanner.nextJSXChild();
        } else if (self.current() == .jsx_text) {
            const text_span = self.currentSpan();
            try self.scratch.append(self.allocator, try self.ast.addNode(.{
                .tag = .jsx_text,
                .span = text_span,
                .data = .{ .string_ref = text_span },
            }));
            try self.scanner.nextJSXChild();
        } else {
            break;
        }
    }
    const children = try self.ast.addNodeList(self.scratch.items[children_top..]);
    self.restoreScratch(children_top);
    return children;
}

/// <Tag ...>children</Tag> 또는 <Tag ... /> 또는 <>...</>
pub fn parseJSXElement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    try self.scanner.nextInsideJSXElement(); // '<' 이후 JSX 모드

    // Fragment: <>
    if (self.current() == .r_angle) {
        try self.scanner.nextJSXChild(); // '>' 이후 children 모드
        return parseJSXFragment(self, start);
    }

    // Opening tag: <TagName
    const tag_name = try parseJSXTagName(self);

    // Attributes
    const scratch_top = self.saveScratch();
    while (self.current() != .r_angle and self.current() != .slash and self.current() != .eof) {
        const attr = try parseJSXAttribute(self);
        try self.scratch.append(self.allocator, attr);
    }
    const attrs = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    // Self-closing: />
    if (self.current() == .slash) {
        try self.scanner.nextInsideJSXElement(); // skip /
        // expect >
        try self.scanner.next(); // back to normal mode after >

        // 항상 5 fields: [tag, attrs_start, attrs_len, children_start, children_len]
        // self-closing은 children_len=0으로 통일하여 transformer에서 heuristic 불필요
        const extra_start = try self.ast.addExtra(@intFromEnum(tag_name));
        _ = try self.ast.addExtra(attrs.start);
        _ = try self.ast.addExtra(attrs.len);
        _ = try self.ast.addExtra(0); // children_start (unused)
        _ = try self.ast.addExtra(0); // children_len = 0

        return try self.ast.addNode(.{
            .tag = .jsx_element,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // > children </tag>
    try self.scanner.nextJSXChild(); // '>' 이후 children 모드

    const children = try parseJSXChildren(self);

    // Closing tag: </TagName>
    try self.scanner.nextInsideJSXElement(); // skip <
    try self.scanner.nextInsideJSXElement(); // skip /
    // skip tag name
    if (self.current() == .jsx_identifier or self.current() == .identifier) {
        try self.scanner.nextInsideJSXElement();
    }
    // expect >
    try self.scanner.next(); // back to normal mode

    const extra_start = try self.ast.addExtra(@intFromEnum(tag_name));
    _ = try self.ast.addExtra(attrs.start);
    _ = try self.ast.addExtra(attrs.len);
    _ = try self.ast.addExtra(children.start);
    _ = try self.ast.addExtra(children.len);

    return try self.ast.addNode(.{
        .tag = .jsx_element,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

fn parseJSXFragment(self: *Parser, start: u32) ParseError2!NodeIndex {
    const children = try parseJSXChildren(self);

    // </>
    try self.scanner.nextInsideJSXElement(); // <
    try self.scanner.nextInsideJSXElement(); // /
    try self.scanner.next(); // >

    return try self.ast.addNode(.{
        .tag = .jsx_fragment,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = children },
    });
}

fn parseJSXTagName(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    if (self.current() == .jsx_identifier or self.current() == .identifier) {
        try self.scanner.nextInsideJSXElement();
        return try self.ast.addNode(.{
            .tag = .jsx_identifier,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    try self.addError(span, "JSX tag name expected");
    return NodeIndex.none;
}

fn parseJSXAttribute(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // spread attribute: {...expr}
    if (self.current() == .l_curly) {
        try self.advance();
        if (self.current() == .dot3) {
            try self.advance();
            const expr = try self.parseAssignmentExpression();
            try self.expect(.r_curly);
            return try self.ast.addNode(.{
                .tag = .jsx_spread_attribute,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        }
        try self.addError(self.currentSpan(), "Spread expected");
        return NodeIndex.none;
    }

    // name="value" or name={expr}
    const name_span = self.currentSpan();
    try self.scanner.nextInsideJSXElement(); // skip attribute name

    const name = try self.ast.addNode(.{
        .tag = .jsx_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });

    var value = NodeIndex.none;
    if (self.current() == .eq) {
        try self.scanner.nextInsideJSXElement(); // skip =
        if (self.current() == .string_literal) {
            const val_span = self.currentSpan();
            try self.scanner.nextInsideJSXElement();
            value = try self.ast.addNode(.{
                .tag = .string_literal,
                .span = val_span,
                .data = .{ .string_ref = val_span },
            });
        } else if (self.current() == .l_curly) {
            try self.advance();
            value = try self.parseAssignmentExpression();
            try self.expect(.r_curly);
        }
    }

    return try self.ast.addNode(.{
        .tag = .jsx_attribute,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = value, .flags = 0 } },
    });
}
