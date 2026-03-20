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

/// <Tag ...>children</Tag> 또는 <Tag ... /> 또는 <>...</>
pub fn parseJSXElement(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.scanner.nextInsideJSXElement(); // '<' 이후 JSX 모드

    // Fragment: <>
    if (self.current() == .r_angle) {
        self.scanner.nextJSXChild(); // '>' 이후 children 모드
        return parseJSXFragment(self, start);
    }

    // Opening tag: <TagName
    const tag_name = try parseJSXTagName(self);

    // Attributes
    const scratch_top = self.saveScratch();
    while (self.current() != .r_angle and self.current() != .slash and self.current() != .eof) {
        const attr = try parseJSXAttribute(self);
        try self.scratch.append(attr);
    }
    const attrs = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    // Self-closing: />
    if (self.current() == .slash) {
        self.scanner.nextInsideJSXElement(); // skip /
        // expect >
        self.scanner.next(); // back to normal mode after >

        const extra_start = try self.ast.addExtra(@intFromEnum(tag_name));
        _ = try self.ast.addExtra(attrs.start);
        _ = try self.ast.addExtra(attrs.len);

        return try self.ast.addNode(.{
            .tag = .jsx_element,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // > children </tag>
    self.scanner.nextJSXChild(); // '>' 이후 children 모드

    // Children
    const children_top = self.saveScratch();
    while (self.current() != .eof) {
        if (self.current() == .l_angle) {
            // 다음 토큰이 / 이면 닫는 태그 (JSX 모드로 peek)
            if (self.peekNextKindJSX() == .slash) break;
            // 중첩 JSX element
            const child = try parseJSXElement(self);
            try self.scratch.append(child);
        } else if (self.current() == .l_curly) {
            // JSX expression: {expr}
            self.advance(); // skip {
            const expr = try self.parseExpression();
            self.expect(.r_curly);
            const container = try self.ast.addNode(.{
                .tag = .jsx_expression_container,
                .span = .{ .start = 0, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
            try self.scratch.append(container);
            self.scanner.nextJSXChild(); // '{expr}' 이후 다시 children 모드
        } else if (self.current() == .jsx_text) {
            const text_span = self.currentSpan();
            try self.scratch.append(try self.ast.addNode(.{
                .tag = .jsx_text,
                .span = text_span,
                .data = .{ .string_ref = text_span },
            }));
            self.scanner.nextJSXChild();
        } else {
            break;
        }
    }
    const children = try self.ast.addNodeList(self.scratch.items[children_top..]);
    self.restoreScratch(children_top);

    // Closing tag: </TagName>
    self.scanner.nextInsideJSXElement(); // skip <
    self.scanner.nextInsideJSXElement(); // skip /
    // skip tag name
    if (self.current() == .jsx_identifier or self.current() == .identifier) {
        self.scanner.nextInsideJSXElement();
    }
    // expect >
    self.scanner.next(); // back to normal mode

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
    // Children
    const children_top = self.saveScratch();
    while (self.current() != .eof) {
        if (self.current() == .l_angle) {
            // JSX 모드로 peek (normal 모드에서는 /가 regex로 해석될 수 있음)
            if (self.peekNextKindJSX() == .slash) break;
            const child = try parseJSXElement(self);
            try self.scratch.append(child);
        } else if (self.current() == .l_curly) {
            self.advance();
            const expr = try self.parseExpression();
            self.expect(.r_curly);
            const container = try self.ast.addNode(.{
                .tag = .jsx_expression_container,
                .span = .{ .start = 0, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
            try self.scratch.append(container);
            self.scanner.nextJSXChild();
        } else if (self.current() == .jsx_text) {
            const text_span = self.currentSpan();
            try self.scratch.append(try self.ast.addNode(.{
                .tag = .jsx_text,
                .span = text_span,
                .data = .{ .string_ref = text_span },
            }));
            self.scanner.nextJSXChild();
        } else {
            break;
        }
    }
    const children = try self.ast.addNodeList(self.scratch.items[children_top..]);
    self.restoreScratch(children_top);

    // </>
    self.scanner.nextInsideJSXElement(); // <
    self.scanner.nextInsideJSXElement(); // /
    self.scanner.next(); // >

    return try self.ast.addNode(.{
        .tag = .jsx_fragment,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .list = children },
    });
}

fn parseJSXTagName(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    if (self.current() == .jsx_identifier or self.current() == .identifier) {
        self.scanner.nextInsideJSXElement();
        return try self.ast.addNode(.{
            .tag = .jsx_identifier,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    self.addError(span, "JSX tag name expected");
    return NodeIndex.none;
}

fn parseJSXAttribute(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // spread attribute: {...expr}
    if (self.current() == .l_curly) {
        self.advance();
        if (self.current() == .dot3) {
            self.advance();
            const expr = try self.parseAssignmentExpression();
            self.expect(.r_curly);
            return try self.ast.addNode(.{
                .tag = .jsx_spread_attribute,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        }
        self.addError(self.currentSpan(), "Spread expected");
        return NodeIndex.none;
    }

    // name="value" or name={expr}
    const name_span = self.currentSpan();
    self.scanner.nextInsideJSXElement(); // skip attribute name

    const name = try self.ast.addNode(.{
        .tag = .jsx_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });

    var value = NodeIndex.none;
    if (self.current() == .eq) {
        self.scanner.nextInsideJSXElement(); // skip =
        if (self.current() == .string_literal) {
            const val_span = self.currentSpan();
            self.scanner.nextInsideJSXElement();
            value = try self.ast.addNode(.{
                .tag = .string_literal,
                .span = val_span,
                .data = .{ .string_ref = val_span },
            });
        } else if (self.current() == .l_curly) {
            self.advance();
            value = try self.parseAssignmentExpression();
            self.expect(.r_curly);
        }
    }

    return try self.ast.addNode(.{
        .tag = .jsx_attribute,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = name, .right = value, .flags = 0 } },
    });
}
