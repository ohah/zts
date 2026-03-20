//! ZTS Semantic Early Error Checker
//!
//! AST 노드별 early error 검증 함수 모음 (oxc 방식).
//! analyzer.zig의 visit 함수에서 직접 호출한다.
//! 필요한 데이터만 인자로 받고, SemanticAnalyzer 전체를 참조하지 않는다.
//!
//! ECMAScript 스펙의 Static Semantics: Early Errors를 구현한다.
//!
//! 검증 목록:
//!   - checkDuplicateConstructors: class body에 constructor가 2개 이상이면 에러
//!   - checkPrivateNameStaticConflict: static/instance private name이 같으면 에러
//!   - checkObjectDuplicateProto: object literal에서 __proto__ 중복이면 에러
//!   - checkGetterSetterParams: getter는 0개, setter는 1개 파라미터만 허용

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;

/// Semantic 에러를 수집하기 위한 에러 구조체 (analyzer.zig의 SemanticError와 동일)
const SemanticError = @import("analyzer.zig").SemanticError;

// ====================================================================
// method_definition flags 상수 (parser.zig와 동일)
// extra_data[extra_start + 4]에 저장됨
// ====================================================================
const METHOD_FLAG_STATIC = 0x01;
const METHOD_FLAG_GETTER = 0x02;
const METHOD_FLAG_SETTER = 0x04;
const METHOD_FLAG_ASYNC = 0x08;
const METHOD_FLAG_GENERATOR = 0x10;

// ====================================================================
// 1. 중복 생성자 검증
// ====================================================================

/// class body에서 constructor가 2개 이상 선언되었는지 검사한다.
///
/// ECMAScript 15.7.1:
///   ClassBody : ClassElementList
///     It is a Syntax Error if PrototypePropertyNameList of ClassElementList
///     contains more than one occurrence of "constructor".
///
/// 파라미터:
///   - ast: AST (읽기 전용, 소스 텍스트 + 노드 접근)
///   - class_body_list: class body의 멤버 NodeList
///   - errors: 에러를 추가할 목록
///   - allocator: 에러 메시지 할당용
pub fn checkDuplicateConstructors(
    ast: *const Ast,
    class_body_list: NodeList,
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (class_body_list.len == 0) return;
    if (class_body_list.start + class_body_list.len > ast.extra_data.items.len) return;

    const indices = ast.extra_data.items[class_body_list.start .. class_body_list.start + class_body_list.len];

    var first_constructor_span: ?Span = null;

    for (indices) |raw_idx| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const node = ast.getNode(idx);

        // method_definition만 검사 (property_definition, static_block 등은 스킵)
        if (node.tag != .method_definition) continue;

        const extra_start = node.data.extra;
        if (extra_start + 4 >= ast.extra_data.items.len) continue;
        const key_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra_start]);
        const flags = ast.extra_data.items[extra_start + 4];

        // static 메서드는 constructor가 아님
        if ((flags & METHOD_FLAG_STATIC) != 0) continue;
        // getter/setter/async/generator는 이미 파서에서 에러 처리
        if ((flags & (METHOD_FLAG_GETTER | METHOD_FLAG_SETTER | METHOD_FLAG_ASYNC | METHOD_FLAG_GENERATOR)) != 0) continue;

        // key가 "constructor" 문자열인지 확인
        if (!matchKeyName(ast, key_idx, "constructor")) continue;

        if (first_constructor_span) |_| {
            // 두 번째 constructor → 에러
            addError(errors, node.span, std.fmt.allocPrint(allocator, "A class may only have one constructor", .{}) catch @panic("OOM"));
            return; // 첫 중복만 보고
        } else {
            first_constructor_span = node.span;
        }
    }
}

// ====================================================================
// 공통 헬퍼
// ====================================================================

/// key 노드의 이름이 target과 일치하는지 확인한다.
/// identifier_reference와 string_literal(따옴표 자동 제거) 모두 처리.
fn matchKeyName(ast: *const Ast, key_idx: NodeIndex, target: []const u8) bool {
    if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return false;
    const key_node = ast.getNode(key_idx);

    if (key_node.tag == .identifier_reference) {
        return std.mem.eql(u8, ast.source[key_node.span.start..key_node.span.end], target);
    }
    if (key_node.tag == .string_literal) {
        // 따옴표 제거: "name" → name
        if (key_node.span.end > key_node.span.start + 2) {
            const inner = ast.source[key_node.span.start + 1 .. key_node.span.end - 1];
            return std.mem.eql(u8, inner, target);
        }
    }
    return false;
}

/// 에러를 errors 목록에 추가한다.
fn addError(errors: *std.ArrayList(SemanticError), span: Span, msg: []const u8) void {
    errors.append(.{ .span = span, .message = msg }) catch @panic("OOM: semantic error list");
}

// ====================================================================
// 2. static/instance private name 충돌 검증
// ====================================================================

/// class body에서 같은 이름의 static/instance private name이 공존하는지 검사한다.
///
/// ECMAScript: private name은 같은 이름으로 static과 instance 동시 선언 불가.
/// 예: `set #f(v) {}` + `static get #f() {}` → SyntaxError
///
/// getter+setter 쌍이어도 static/instance가 다르면 에러.
/// (같은 static 여부의 getter+setter 쌍만 유효)
pub fn checkPrivateNameStaticConflict(
    ast: *const Ast,
    class_body_list: NodeList,
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (class_body_list.len == 0) return;
    if (class_body_list.start + class_body_list.len > ast.extra_data.items.len) return;

    const indices = ast.extra_data.items[class_body_list.start .. class_body_list.start + class_body_list.len];

    // private name → (is_static, span) 매핑
    // 같은 이름이 다른 static 상태로 등장하면 에러
    var declared = std.StringHashMap(PrivateStaticEntry).init(allocator);
    defer declared.deinit();

    for (indices) |raw_idx| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const node = ast.getNode(idx);

        switch (node.tag) {
            .method_definition => {
                const extra_start = node.data.extra;
                if (extra_start + 4 >= ast.extra_data.items.len) continue;
                const key_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra_start]);
                const flags = ast.extra_data.items[extra_start + 4];
                const is_static = (flags & METHOD_FLAG_STATIC) != 0;

                checkPrivateKeyStaticConflict(ast, key_idx, is_static, &declared, errors, allocator);
            },
            .property_definition => {
                // binary: { left = key, right = value, flags }
                // static 비트는 parser.zig에서 flags 0x01로 인코딩 (확인 완료)
                const key_idx = node.data.binary.left;
                const is_static = (node.data.binary.flags & METHOD_FLAG_STATIC) != 0;

                checkPrivateKeyStaticConflict(ast, key_idx, is_static, &declared, errors, allocator);
            },
            else => {},
        }
    }
}

/// private name 선언의 static 여부와 위치를 추적하는 엔트리.
const PrivateStaticEntry = struct {
    is_static: bool,
    span: Span,
};

fn checkPrivateKeyStaticConflict(
    ast: *const Ast,
    key_idx: NodeIndex,
    is_static: bool,
    declared: *std.StringHashMap(PrivateStaticEntry),
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return;
    const key_node = ast.getNode(key_idx);
    if (key_node.tag != .private_identifier) return;

    const name = ast.source[key_node.span.start..key_node.span.end];

    if (declared.get(name)) |existing| {
        // 같은 이름이 이미 등록됨 → static 상태가 다르면 에러
        if (existing.is_static != is_static) {
            addError(errors, key_node.span, std.fmt.allocPrint(
                allocator,
                "Private field '{s}' has already been declared",
                .{name},
            ) catch @panic("OOM"));
        }
    } else {
        declared.put(name, .{ .is_static = is_static, .span = key_node.span }) catch @panic("OOM");
    }
}

// ====================================================================
// 3. object literal __proto__ 중복 검증
// ====================================================================

/// object literal에서 __proto__ 프로퍼티가 2번 이상 초기화되면 에러.
///
/// ECMAScript 12.2.6.1:
///   It is a Syntax Error if PropertyNameList of PropertyDefinitionList
///   contains any duplicate entries for "__proto__" and at least two of
///   those entries were obtained from productions of the form
///   PropertyDefinition : PropertyName : AssignmentExpression
///
/// getter/setter, method shorthand, computed property, spread는 제외.
pub fn checkObjectDuplicateProto(
    ast: *const Ast,
    object_list: NodeList,
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (object_list.len == 0) return;
    if (object_list.start + object_list.len > ast.extra_data.items.len) return;

    const indices = ast.extra_data.items[object_list.start .. object_list.start + object_list.len];

    var first_proto_span: ?Span = null;

    for (indices) |raw_idx| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const node = ast.getNode(idx);

        // object_property만 검사 (method_definition, spread_element 등은 스킵)
        if (node.tag != .object_property) continue;

        // key가 "__proto__" 인지 확인
        const key_idx = node.data.binary.left;
        if (!matchKeyName(ast, key_idx, "__proto__")) continue;

        if (first_proto_span) |_| {
            addError(errors, node.span, std.fmt.allocPrint(allocator, "Property name __proto__ appears more than once in object literal", .{}) catch @panic("OOM"));
            return; // 첫 중복만 보고
        } else {
            first_proto_span = node.span;
        }
    }
}

// ====================================================================
// 4. getter/setter 파라미터 개수 검증
// ====================================================================

/// getter는 파라미터 0개, setter는 정확히 1개만 허용.
///
/// ECMAScript 15.4.1:
///   get PropertyName ( ) { FunctionBody }
///     It is a Syntax Error if FormalParameters is not empty.
///   set PropertyName ( PropertySetParameterList ) { FunctionBody }
///     PropertySetParameterList: FormalParameter (exactly one)
///
/// class 메서드와 object 메서드 모두 적용.
pub fn checkGetterSetterParams(
    ast: *const Ast,
    node: Node,
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (node.tag != .method_definition) return;

    const extra_start = node.data.extra;
    if (extra_start + 4 >= ast.extra_data.items.len) return;

    const flags = ast.extra_data.items[extra_start + 4];
    const params_len = ast.extra_data.items[extra_start + 2];

    if ((flags & METHOD_FLAG_GETTER) != 0 and params_len != 0) {
        addError(errors, node.span, std.fmt.allocPrint(allocator, "Getter must not have any formal parameters", .{}) catch @panic("OOM"));
    }

    if ((flags & METHOD_FLAG_SETTER) != 0 and params_len != 1) {
        addError(errors, node.span, std.fmt.allocPrint(allocator, "Setter must have exactly one formal parameter", .{}) catch @panic("OOM"));
    }
}

// ====================================================================
// 5. 파라미터 중복 검증
// ====================================================================

/// 파라미터 리스트에서 중복된 바인딩 이름이 있으면 에러.
///
/// ECMAScript 14.1.2:
///   UniqueFormalParameters: FormalParameters
///     It is a Syntax Error if BoundNames of FormalParameters contains any duplicate elements.
///
/// 적용 대상 (호출자가 조건 판단):
///   - arrow function 파라미터 (항상 UniqueFormalParameters)
///   - class 메서드 파라미터 (class body는 항상 strict)
///   - strict mode 함수 파라미터
///   - generator/async function 파라미터
pub fn checkDuplicateParams(
    ast: *const Ast,
    params_start: u32,
    params_len: u32,
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (params_len == 0) return;
    if (params_start + params_len > ast.extra_data.items.len) return;

    // 파라미터 이름 → 첫 선언 위치 매핑
    var seen = std.StringHashMap(Span).init(allocator);
    defer seen.deinit();

    const param_indices = ast.extra_data.items[params_start .. params_start + params_len];
    for (param_indices) |raw_idx| {
        collectBindingNames(ast, @enumFromInt(raw_idx), &seen, errors, allocator);
    }
}

/// 파라미터 이름을 seen 맵에 기록하고, 이미 있으면 중복 에러를 추가한다.
fn recordSeenName(
    name: []const u8,
    span: Span,
    seen: *std.StringHashMap(Span),
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (seen.get(name)) |_| {
        addError(errors, span, std.fmt.allocPrint(
            allocator,
            "Duplicate parameter name '{s}'",
            .{name},
        ) catch @panic("OOM"));
    } else {
        seen.put(name, span) catch @panic("OOM");
    }
}

/// 바인딩 패턴에서 이름을 재귀적으로 추출하여 중복 체크한다.
fn collectBindingNames(
    ast: *const Ast,
    idx: NodeIndex,
    seen: *std.StringHashMap(Span),
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return;
    const node = ast.getNode(idx);

    switch (node.tag) {
        .binding_identifier => {
            recordSeenName(ast.source[node.span.start..node.span.end], node.span, seen, errors, allocator);
        },
        .array_pattern, .object_pattern => {
            // list of elements/properties
            if (node.data.list.len == 0) return;
            if (node.data.list.start + node.data.list.len > ast.extra_data.items.len) return;
            const indices = ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (indices) |raw_idx| {
                collectBindingNames(ast, @enumFromInt(raw_idx), seen, errors, allocator);
            }
        },
        .binding_property => {
            // binary: { left = key, right = value }
            collectBindingNames(ast, node.data.binary.right, seen, errors, allocator);
        },
        .assignment_pattern => {
            // binary: { left = binding, right = default_value }
            collectBindingNames(ast, node.data.binary.left, seen, errors, allocator);
        },
        .binding_rest_element, .rest_element => {
            // unary: { operand = binding }
            collectBindingNames(ast, node.data.unary.operand, seen, errors, allocator);
        },
        else => {},
    }
}

/// arrow function의 파라미터 노드에서 중복 바인딩을 검사한다.
/// arrow function의 left는 단일 binding_identifier 또는 parenthesized_expression,
/// 또는 cover grammar에서 변환된 array_pattern/object_pattern일 수 있다.
pub fn checkDuplicateArrowParams(
    ast: *const Ast,
    param_idx: NodeIndex,
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (param_idx.isNone() or @intFromEnum(param_idx) >= ast.nodes.items.len) return;

    // fast path: 단일 파라미터는 중복 불가능
    const node = ast.getNode(param_idx);
    if (node.tag == .binding_identifier or node.tag == .identifier_reference or node.tag == .assignment_target_identifier) return;

    var seen = std.StringHashMap(Span).init(allocator);
    defer seen.deinit();

    collectArrowParamNames(ast, param_idx, &seen, errors, allocator);
}

/// arrow 파라미터 노드에서 바인딩 이름을 재귀 수집한다.
fn collectArrowParamNames(
    ast: *const Ast,
    idx: NodeIndex,
    seen: *std.StringHashMap(Span),
    errors: *std.ArrayList(SemanticError),
    allocator: std.mem.Allocator,
) void {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return;
    const node = ast.getNode(idx);

    switch (node.tag) {
        // 단일 파라미터 (post-cover-grammar)
        .binding_identifier => {
            recordSeenName(ast.source[node.span.start..node.span.end], node.span, seen, errors, allocator);
        },
        // cover grammar에서 변환된 파라미터 리스트
        .parenthesized_expression, .sequence_expression => {
            if (node.tag == .parenthesized_expression) {
                collectArrowParamNames(ast, node.data.unary.operand, seen, errors, allocator);
            } else {
                if (node.data.list.len == 0) return;
                if (node.data.list.start + node.data.list.len > ast.extra_data.items.len) return;
                const indices = ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                for (indices) |raw_idx| {
                    collectArrowParamNames(ast, @enumFromInt(raw_idx), seen, errors, allocator);
                }
            }
        },
        // identifier를 파라미터로 사용 (cover grammar 변환 전후 모두 처리)
        .identifier_reference, .assignment_target_identifier => {
            recordSeenName(ast.source[node.span.start..node.span.end], node.span, seen, errors, allocator);
        },
        // destructuring 패턴 (cover grammar 변환 전후 모두 처리)
        .array_pattern,
        .object_pattern,
        .array_expression,
        .object_expression,
        .array_assignment_target,
        .object_assignment_target,
        => {
            if (node.data.list.len == 0) return;
            if (node.data.list.start + node.data.list.len > ast.extra_data.items.len) return;
            const indices = ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (indices) |raw_idx| {
                collectArrowParamNames(ast, @enumFromInt(raw_idx), seen, errors, allocator);
            }
        },
        .assignment_expression, .assignment_pattern, .assignment_target_with_default => {
            // left = binding, right = default value
            collectArrowParamNames(ast, node.data.binary.left, seen, errors, allocator);
        },
        .binding_property,
        .object_property,
        .assignment_target_property_identifier,
        .assignment_target_property_property,
        => {
            // binary: { left = key, right = value }
            collectArrowParamNames(ast, node.data.binary.right, seen, errors, allocator);
        },
        .spread_element, .binding_rest_element, .rest_element, .assignment_target_rest => {
            collectArrowParamNames(ast, node.data.unary.operand, seen, errors, allocator);
        },
        else => {},
    }
}

// ====================================================================
// Tests
// ====================================================================

const Parser = @import("../parser/parser.zig").Parser;
const Scanner = @import("../lexer/scanner.zig").Scanner;

test "checker: duplicate constructor is error" {
    var scanner = Scanner.init(std.testing.allocator, "class C { constructor() {} constructor() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs = std.ArrayList(SemanticError).init(std.testing.allocator);
    defer {
        for (errs.items) |e| std.testing.allocator.free(e.message);
        errs.deinit();
    }

    // class body를 찾아서 검사
    // AST 마지막 노드는 program, 그 안에 class_declaration이 있음
    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            checkDuplicateConstructors(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len > 0);
}

test "checker: single constructor is valid" {
    var scanner = Scanner.init(std.testing.allocator, "class C { constructor() {} foo() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs = std.ArrayList(SemanticError).init(std.testing.allocator);
    defer errs.deinit();

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            checkDuplicateConstructors(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len == 0);
}

test "checker: static/instance private name conflict is error" {
    var scanner = Scanner.init(std.testing.allocator, "class C { set #f(v) {} static get #f() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs = std.ArrayList(SemanticError).init(std.testing.allocator);
    defer {
        for (errs.items) |e| std.testing.allocator.free(e.message);
        errs.deinit();
    }

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            checkPrivateNameStaticConflict(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len > 0);
}

test "checker: same static private getter+setter is valid" {
    var scanner = Scanner.init(std.testing.allocator, "class C { static get #f() {} static set #f(v) {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs = std.ArrayList(SemanticError).init(std.testing.allocator);
    defer errs.deinit();

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .class_body) {
            checkPrivateNameStaticConflict(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len == 0);
}

test "checker: duplicate __proto__ is error" {
    var scanner = Scanner.init(std.testing.allocator, "var o = { __proto__: null, __proto__: null };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs = std.ArrayList(SemanticError).init(std.testing.allocator);
    defer {
        for (errs.items) |e| std.testing.allocator.free(e.message);
        errs.deinit();
    }

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .object_expression) {
            checkObjectDuplicateProto(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len > 0);
}

test "checker: single __proto__ is valid" {
    var scanner = Scanner.init(std.testing.allocator, "var o = { __proto__: null, x: 1 };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var errs = std.ArrayList(SemanticError).init(std.testing.allocator);
    defer errs.deinit();

    const ast = &parser.ast;
    for (ast.nodes.items) |node| {
        if (node.tag == .object_expression) {
            checkObjectDuplicateProto(ast, node.data.list, &errs, std.testing.allocator);
            break;
        }
    }

    try std.testing.expect(errs.items.len == 0);
}

test "checker: duplicate arrow params is error" {
    var scanner = Scanner.init(std.testing.allocator, "var f = (x, x) => x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    const SemanticAnalyzer = @import("analyzer.zig").SemanticAnalyzer;
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "checker: duplicate method params is error" {
    var scanner = Scanner.init(std.testing.allocator, "class C { foo(a, a) {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    const SemanticAnalyzer = @import("analyzer.zig").SemanticAnalyzer;
    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}
