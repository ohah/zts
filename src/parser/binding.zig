//! Binding Pattern 파싱
//!
//! 바인딩 패턴(destructuring), 식별자, 기본값을 파싱하는 함수들.\n//! oxc의 js/binding.rs에 대응.
//!
//! 참고: references/oxc/crates/oxc_parser/src/js/binding.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

pub fn parseBindingPattern(self: *Parser) ParseError2!NodeIndex {
    // TS parameter property: public x, private x, protected x, readonly x
    // flags 비트: 0x01=public, 0x02=private, 0x04=protected, 0x08=readonly
    if (self.current() == .kw_public or self.current() == .kw_private or
        self.current() == .kw_protected or self.current() == .kw_readonly)
    {
        const modifier_span = self.currentSpan();
        const next = self.peekNextKind();
        // modifier 뒤에 식별자가 오면 parameter property
        if (next == .identifier or next == .l_bracket or next == .l_curly or
            next == .kw_readonly) // public readonly x
        {
            var modifier_flags: u16 = switch (self.current()) {
                .kw_public => 0x01,
                .kw_private => 0x02,
                .kw_protected => 0x04,
                .kw_readonly => 0x08,
                else => 0,
            };
            self.advance(); // skip first modifier

            // 두 번째 modifier: public readonly x
            if (self.current() == .kw_readonly) {
                modifier_flags |= 0x08;
                self.advance();
            }

            const inner = try parseBindingPattern(self);
            return try self.ast.addNode(.{
                .tag = .formal_parameter,
                .span = .{ .start = modifier_span.start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = inner, .flags = modifier_flags } },
            });
        }
    }

    // rest parameter: ...pattern
    if (self.current() == .dot3) {
        const rest_start = self.currentSpan().start;
        self.advance(); // skip '...'
        const pattern = try parseBindingPattern(self);
        self.checkBindingRestInit(pattern);
        return try self.ast.addNode(.{
            .tag = .spread_element,
            .span = .{ .start = rest_start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = pattern, .flags = 0 } },
        });
    }

    switch (self.current()) {
        .identifier => {
            const span = self.currentSpan();
            self.checkStrictBinding(span);
            self.advance();
            const node = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
            // TS: optional (?) + type annotation
            _ = self.eat(.question); // optional parameter
            _ = try self.tryParseTypeAnnotation();
            // default value: pattern = expr
            return tryWrapDefaultValue(self, node);
        },
        .l_bracket => {
            const pat = try parseArrayPattern(self);
            _ = self.eat(.question);
            _ = try self.tryParseTypeAnnotation();
            return tryWrapDefaultValue(self, pat);
        },
        .l_curly => {
            const pat = try parseObjectPattern(self);
            _ = self.eat(.question);
            _ = try self.tryParseTypeAnnotation();
            return tryWrapDefaultValue(self, pat);
        },
        .escaped_keyword => {
            // escaped await (aw\u0061it)은 script mode에서 식별자로 사용 가능.
            // ECMAScript 12.1.1: await는 Module goal에서만 Syntax Error.
            // 다른 reserved keyword의 escaped 형태는 항상 사용 불가.
            const is_escaped_await = self.isEscapedKeyword("await");
            if (!is_escaped_await or self.is_module or self.ctx.in_async) {
                self.addError(self.currentSpan(), "escaped reserved word cannot be used as identifier");
            }
            const span = self.currentSpan();
            self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .escaped_strict_reserved => {
            if (self.is_strict_mode) {
                self.addError(self.currentSpan(), "escaped reserved word cannot be used as identifier in strict mode");
            }
            self.checkYieldAwaitUse(self.currentSpan(), "identifier");
            const span = self.currentSpan();
            self.advance();
            const node = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
            _ = self.eat(.question);
            _ = try self.tryParseTypeAnnotation();
            return tryWrapDefaultValue(self, node);
        },
        else => {
            // contextual 키워드는 바인딩 이름으로 사용 가능 (let, yield, async 등)
            // 단, reserved keyword / yield in generator / await in async 는 불가
            if (self.current().isKeyword()) {
                self.checkKeywordBinding();
                const span = self.currentSpan();
                self.advance();
                const node2 = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
                return tryWrapDefaultValue(self, node2);
            }
            self.addError(self.currentSpan(), "binding pattern expected");
            return NodeIndex.none;
        },
    }
}

/// 하위 호환: 식별자만 필요한 곳에서 호출
pub fn parseBindingIdentifier(self: *Parser) ParseError2!NodeIndex {
    return parseBindingPattern(self);
}

/// `= expr` 이 있으면 assignment_pattern으로 감싼다. 없으면 원본 반환.
/// 기본값 표현식에서는 `in` 연산자가 항상 허용된다 (ECMAScript: Initializer[+In]).
pub fn tryWrapDefaultValue(self: *Parser, node: NodeIndex) ParseError2!NodeIndex {
    if (self.eat(.eq)) {
        const def_saved = self.enterAllowInContext(true);
        const default_val = try self.parseAssignmentExpression();
        self.restoreContext(def_saved);
        return try self.ast.addNode(.{
            .tag = .assignment_pattern,
            .span = .{ .start = self.ast.getNode(node).span.start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = node, .right = default_val, .flags = 0 } },
        });
    }
    return node;
}

/// 바인딩 이름만 파싱한다 (identifier, [array], {object}).
/// `?`, 타입 어노테이션, default value `=`를 소비하지 않는다.
/// variable declarator에서 사용 — `=`는 initializer이므로 여기서 소비하면 안 됨.
pub fn parseBindingName(self: *Parser) ParseError2!NodeIndex {
    switch (self.current()) {
        .identifier => {
            const span = self.currentSpan();
            self.checkStrictBinding(span);
            self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .l_bracket => return parseArrayPattern(self),
        .l_curly => return parseObjectPattern(self),
        .escaped_keyword => {
            // escaped await (aw\u0061it)은 script mode에서 식별자로 사용 가능.
            // ECMAScript 12.1.1: await는 Module goal에서만 Syntax Error.
            // 다른 reserved keyword의 escaped 형태는 항상 사용 불가.
            const is_escaped_await = self.isEscapedKeyword("await");
            if (!is_escaped_await or self.is_module or self.ctx.in_async) {
                self.addError(self.currentSpan(), "escaped reserved word cannot be used as identifier");
            }
            const span = self.currentSpan();
            self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        .escaped_strict_reserved => {
            if (self.is_strict_mode) {
                self.addError(self.currentSpan(), "escaped reserved word cannot be used as identifier in strict mode");
            }
            self.checkYieldAwaitUse(self.currentSpan(), "identifier");
            const span = self.currentSpan();
            self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        },
        else => {
            if (self.current().isKeyword()) {
                self.checkKeywordBinding();
                const span = self.currentSpan();
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            }
            self.addError(self.currentSpan(), "binding pattern expected");
            return NodeIndex.none;
        },
    }
}

/// 단순 식별자 이름만 파싱한다 (타입 어노테이션/기본값 없이).
/// type alias, interface, enum 등 선언 이름에 사용.
pub fn parseSimpleIdentifier(self: *Parser) ParseError2!NodeIndex {
    const span = self.currentSpan();
    if (self.current() == .identifier or self.current() == .escaped_keyword or
        self.current() == .escaped_strict_reserved or self.current().isKeyword())
    {
        if (self.current() == .escaped_keyword) {
            self.addError(span, "escaped reserved word cannot be used as identifier");
        } else if (self.current() == .escaped_strict_reserved and self.is_strict_mode) {
            self.addError(span, "escaped reserved word cannot be used as identifier in strict mode");
        } else {
            self.checkKeywordBinding();
        }
        self.advance();
        return try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = span,
            .data = .{ .string_ref = span },
        });
    }
    self.addError(span, "identifier expected");
    return NodeIndex.none;
}

pub fn parseArrayPattern(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.advance(); // skip [

    const scratch_top = self.saveScratch();
    while (self.current() != .r_bracket and self.current() != .eof) {
        if (self.current() == .comma) {
            // elision (빈 슬롯) — placeholder 노드 추가
            const hole_span = self.currentSpan();
            try self.scratch.append(try self.ast.addNode(.{
                .tag = .elision,
                .span = hole_span,
                .data = .{ .none = 0 },
            }));
            self.advance();
            continue;
        }
        if (self.current() == .dot3) {
            // rest element: ...pattern
            const rest_start = self.currentSpan().start;
            self.advance(); // skip ...
            const rest_arg = try parseBindingPattern(self);
            self.checkBindingRestInit(rest_arg);
            const rest = try self.ast.addNode(.{
                .tag = .rest_element,
                .span = .{ .start = rest_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
            });
            try self.scratch.append(rest);
            break; // rest는 항상 마지막
        }
        const elem_raw = try parseBindingName(self);
        // default value: pattern = expr (배열/객체 패턴 뒤의 = default)
        var elem = try tryWrapDefaultValue(self, elem_raw);
        // TS: optional (?) + type annotation — 배열 패턴 요소에도 가능
        _ = self.eat(.question);
        _ = try self.tryParseTypeAnnotation();
        if (!elem.isNone()) try self.scratch.append(elem);
        if (!self.eat(.comma)) break;
    }

    const end = self.currentSpan().end;
    self.expect(.r_bracket);

    const elements = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .array_pattern,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = elements },
    });
}

pub fn parseObjectPattern(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.advance(); // skip {

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        if (self.current() == .dot3) {
            // rest element: ...pattern
            const rest_start = self.currentSpan().start;
            self.advance(); // skip ...
            const rest_arg = try parseBindingPattern(self);
            self.checkBindingRestInit(rest_arg);
            const rest = try self.ast.addNode(.{
                .tag = .rest_element,
                .span = .{ .start = rest_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
            });
            try self.scratch.append(rest);
            break;
        }

        const prop = try parseBindingProperty(self);
        if (!prop.isNone()) try self.scratch.append(prop);
        if (!self.eat(.comma)) break;
    }

    const end = self.currentSpan().end;
    self.expect(.r_curly);

    const props = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);

    return try self.ast.addNode(.{
        .tag = .object_pattern,
        .span = .{ .start = start, .end = end },
        .data = .{ .list = props },
    });
}

pub fn parseBindingProperty(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // shorthand: { x } = { x: x } 또는 { x = defaultVal }
    // 컨텍스트에 따라 식별자로 사용 가능한 키워드도 shorthand로 처리:
    // - await: async 함수 밖에서 식별자 가능 (ECMAScript 12.1.1)
    // - yield: generator 밖에서 식별자 가능
    const is_shorthand_eligible = self.current() == .identifier or
        (self.current() == .kw_await and !self.ctx.in_async and (!self.is_module or self.ctx.in_function)) or
        (self.current() == .kw_yield and !self.ctx.in_generator and !self.is_strict_mode);
    if (is_shorthand_eligible) {
        const id_span = self.currentSpan();
        const next = self.peekNextKind();
        if (next == .comma or next == .r_curly or next == .eq) {
            // shorthand property
            self.advance();
            const key = try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = id_span,
                .data = .{ .string_ref = id_span },
            });
            const value = try tryWrapDefaultValue(self, key);
            return try self.ast.addNode(.{
                .tag = .binding_property,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
            });
        }
    }

    // key: pattern = default
    const key = try self.parsePropertyKey();
    // private name (#x) 은 object destructuring pattern에서 사용 불가
    // ECMAScript: ObjectAssignmentPattern의 PropertyName은 PrivateName을 포함하지 않음
    if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) {
        self.addError(self.ast.getNode(key).span, "private name is not allowed in destructuring pattern");
    }
    self.expect(.colon);
    const value_raw = try parseBindingPattern(self);
    // { x: pattern = defaultValue } 형태
    const value = try tryWrapDefaultValue(self, value_raw);

    return try self.ast.addNode(.{
        .tag = .binding_property,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
    });
}
