//! ZTS Parser
//!
//! 토큰 스트림을 AST로 변환하는 재귀 하강(recursive descent) 파서.
//! 2패스 설계: parse → visit (D040).
//! 에러 복구: 다중 에러 수집 (D039).
//!
//! 참고:
//! - references/bun/src/js_parser.zig
//! - references/oxc/crates/oxc_parser/src/

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Token = token_mod.Token;
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;

/// 파서 에러 하나.
pub const ParseError = struct {
    span: Span,
    message: []const u8,
};

/// 재귀 함수용 명시적 에러 타입.
/// Zig는 재귀 함수에서 `!T` (inferred error set)를 사용할 수 없다.
/// 파서의 모든 에러는 메모리 할당 실패뿐이므로 Allocator.Error로 충분하다.
const ParseError2 = std.mem.Allocator.Error;

/// 재귀 하강 파서.
/// Scanner에서 토큰을 하나씩 읽어 AST를 구축한다.
pub const Parser = struct {
    /// 렉서 (토큰 공급)
    scanner: *Scanner,

    /// AST 저장소
    ast: Ast,

    /// 수집된 에러 목록 (D039: 다중 에러)
    errors: std.ArrayList(ParseError),

    /// 재사용 가능한 임시 버퍼 (리스트 수집용). 매 사용 시 clearRetainingCapacity.
    scratch: std.ArrayList(NodeIndex),

    /// arrow 파라미터 중복 검사용 임시 이름 수집 버퍼.
    param_name_spans: std.ArrayList(Span),

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    // ================================================================
    // 컨텍스트 플래그 (D051: 파서에서 구문 컨텍스트 추적)
    // ================================================================
    //
    // Context(u8)는 ECMAScript 문법 파라미터([+In], [+Yield] 등)만 포함한다.
    // 나머지 파서 상태는 개별 bool 필드로 관리한다.
    //
    // is_module은 파싱 시작 시 한 번 결정되고 변하지 않는 불변 설정이므로
    // Context에 포함하지 않고 별도 필드로 관리한다 (oxc/Babel/Hermes 방식).

    /// 파싱 컨텍스트 bitflags — ECMAScript 문법 파라미터만 포함.
    ctx: Context = Context.default,

    /// module 모드인지 (import/export 허용, 항상 strict).
    /// 파싱 시작 시 한 번 결정되는 불변 설정이므로 Context에 포함하지 않음.
    is_module: bool = false,

    // ================================================================
    // 개별 파서 상태 플래그
    // ================================================================

    /// TS 타입 어노테이션 안인지 (렉서 동작 변경: `<`/`>`를 타입 구분자로)
    in_type: bool = false,
    /// 함수 파라미터 안인지
    in_parameters: bool = false,
    /// new.target 허용 여부
    allow_new_target: bool = false,
    /// constructor 안인지
    is_constructor: bool = false,
    /// strict mode 여부 (D054: "use strict" directive 또는 module mode)
    is_strict_mode: bool = false,
    /// 루프 안에 있는지 (continue 유효성 검증용)
    in_loop: bool = false,
    /// switch 안에 있는지 (break 유효성 검증용 — break는 loop OR switch에서 허용)
    in_switch: bool = false,
    /// 현재 파싱 중인 함수의 파라미터가 simple인지 (non-simple이면 "use strict" 금지)
    has_simple_params: bool = true,
    /// for 초기화절 안인지 (for-in/for-of 구분)
    for_loop_init: bool = false,
    /// class 본문 안인지
    in_class: bool = false,
    /// class field 초기값 안인지
    in_class_field: bool = false,
    /// extends 있는 class인지 (super() 허용 판단)
    has_super_class: bool = false,
    /// super() 호출 허용 여부 (constructor + extends)
    allow_super_call: bool = false,
    /// super.x / super[x] 허용 여부
    allow_super_property: bool = false,
    /// static initializer (static { }) 안인지 — arguments 사용 금지
    in_static_initializer: bool = false,
    /// object literal에서 CoverInitializedName (shorthand with default: { x = 1 }) 가 있었는지.
    /// cover grammar 변환(destructuring)에서 소비되지 않으면 에러.
    has_cover_init_name: bool = false,
    /// formal parameter 파싱 중인지 (yield/await expression 금지).
    in_formal_parameters: bool = false,
    /// if/with/labeled body에서 labelled function statement 금지 체크 중인지.
    /// IsLabelledFunction(Statement) is true → SyntaxError
    in_labelled_fn_check: bool = false,

    // ================================================================
    // Context packed struct 정의
    // ================================================================

    /// ECMAScript 문법 파라미터를 추적하는 bitflags.
    ///
    /// packed struct(u8)에는 문법 파라미터(allow_in, in_generator 등)만 포함한다.
    /// 나머지 파서 상태(is_strict_mode, in_loop 등)는 Parser의 개별 필드로 관리.
    ///
    /// 기본값 주의: allow_in, is_top_level은 기본값이 true.
    pub const Context = packed struct(u8) {
        /// `in` 연산자 허용 여부 (for-in/for-of 초기화절에서는 false로 설정하여
        /// `in`을 관계 연산자가 아닌 for-in 키워드로 파싱)
        allow_in: bool = true,
        /// generator 함수 안에 있는지 (yield 키워드 유효성 검증용)
        in_generator: bool = false,
        /// async 함수 안에 있는지 (await 키워드 유효성 검증용)
        in_async: bool = false,
        /// 함수 본문 안에 있는지 (return 유효성 검증용)
        in_function: bool = false,
        /// 최상위 레벨인지 (top-level await 감지용)
        is_top_level: bool = true,
        /// decorator 파싱 중인지
        in_decorator: bool = false,
        /// TS declare 블록 또는 .d.ts 파일 안인지
        in_ambient: bool = false,
        /// TS 조건부 타입 금지 (infer 절에서 extends를 제약으로 파싱)
        disallow_conditional_types: bool = false,

        /// 기본값: allow_in=true, is_top_level=true, 나머지 false.
        pub const default: Context = .{};

        /// 함수 진입 시 Context(문법 파라미터)를 설정한다.
        /// in_function=true, is_top_level=false, async/generator는 인자로 설정.
        pub fn enterFunction(self: Context, is_async: bool, is_generator: bool) Context {
            var new = self;
            new.in_function = true;
            new.in_async = is_async;
            new.in_generator = is_generator;
            new.is_top_level = false;
            return new;
        }
    };

    /// 함수/메서드 진입 시 저장되는 상태.
    /// enterFunctionContext()로 저장, restoreFunctionContext()로 복원.
    const SavedState = struct {
        ctx: Context,
        is_strict_mode: bool,
        in_loop: bool,
        in_switch: bool,
        has_simple_params: bool,
        for_loop_init: bool,
        in_class_field: bool,
        in_static_initializer: bool,
        allow_new_target: bool,
        allow_super_call: bool,
        allow_super_property: bool,
        in_formal_parameters: bool,
    };

    pub fn init(allocator: std.mem.Allocator, scanner: *Scanner) Parser {
        return .{
            .scanner = scanner,
            .ast = Ast.init(allocator, scanner.source),
            .errors = std.ArrayList(ParseError).init(allocator),
            .scratch = std.ArrayList(NodeIndex).init(allocator),
            .param_name_spans = std.ArrayList(Span).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit();
        self.errors.deinit();
        self.scratch.deinit();
        self.param_name_spans.deinit();
    }

    // ================================================================
    // 토큰 접근 헬퍼
    // ================================================================

    /// 현재 토큰의 Kind.
    fn current(self: *const Parser) Kind {
        return self.scanner.token.kind;
    }

    /// 현재 토큰의 Span.
    fn currentSpan(self: *const Parser) Span {
        return self.scanner.token.span;
    }

    /// 다음 토큰으로 전진.
    fn advance(self: *Parser) void {
        self.scanner.next();
    }

    /// 현재 토큰이 expected이면 소비하고 true, 아니면 false.
    fn eat(self: *Parser, expected: Kind) bool {
        if (self.current() == expected) {
            self.advance();
            return true;
        }
        return false;
    }

    /// 현재 토큰이 expected이면 소비, 아니면 에러 추가.
    fn expect(self: *Parser, expected: Kind) void {
        if (!self.eat(expected)) {
            self.addError(self.currentSpan(), expected.symbol());
        }
    }

    /// ASI (Automatic Semicolon Insertion) 규칙으로 세미콜론을 처리한다.
    /// - 세미콜론이 있으면 소비
    /// - 현재 토큰 앞에 개행이 있으면 OK (ASI)
    /// - 현재 토큰이 } 또는 EOF이면 OK (ASI)
    /// - 그 외: 세미콜론이 필요하다는 에러 보고
    fn expectSemicolon(self: *Parser) void {
        if (self.eat(.semicolon)) return;
        if (self.scanner.token.has_newline_before) return;
        if (self.current() == .r_curly or self.current() == .eof) return;
        self.addError(self.currentSpan(), ";");
    }

    /// 에러를 추가한다.
    fn addError(self: *Parser, span: Span, expected: []const u8) void {
        self.errors.append(.{
            .span = span,
            .message = expected,
        }) catch @panic("OOM: parser error list");
    }

    /// scratch 버퍼의 현재 위치를 저장한다. 중첩 사용 시 save/restore 패턴.
    /// 사용법:
    ///   const top = self.saveScratch();
    ///   // ... scratch에 append ...
    ///   const items = self.scratch.items[top..];
    ///   // ... items 사용 후 ...
    ///   self.restoreScratch(top);
    fn saveScratch(self: *const Parser) usize {
        return self.scratch.items.len;
    }

    fn restoreScratch(self: *Parser, top: usize) void {
        self.scratch.shrinkRetainingCapacity(top);
    }

    /// 현재 토큰의 소스 텍스트.
    fn tokenText(self: *const Parser) []const u8 {
        return self.scanner.tokenText();
    }

    /// strict mode에서 eval/arguments를 바인딩 이름으로 사용하면 에러.
    fn checkStrictBinding(self: *Parser, span: Span) void {
        if (!self.is_strict_mode) return;
        const text = self.ast.source[span.start..span.end];
        if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "arguments")) {
            self.addError(span, "assignment to 'eval' or 'arguments' is not allowed in strict mode");
        }
    }

    const rest_init_error = "rest element may not have a default initializer";
    /// object_property의 binary.flags에 설정하여 shorthand-with-default를 표시.
    /// parseObjectProperty에서 마킹, coverObjectExpressionToTarget에서 검증.
    const shorthand_with_default: u16 = 0x01;
    /// spread_element의 unary.flags에 설정하여 trailing comma를 표시.
    /// parseArrayExpression에서 마킹, coverArrayExpressionToTarget에서 검증.
    const spread_trailing_comma: u16 = 0x01;

    /// binding pattern에서 rest element가 assignment_pattern(= initializer)이면 에러.
    /// parseArrayPattern, parseObjectPattern, parseBindingPattern의 rest 처리에서 공통 사용.
    fn checkBindingRestInit(self: *Parser, rest_arg: NodeIndex) void {
        if (rest_arg.isNone()) return;
        const rest_node = self.ast.getNode(rest_arg);
        // binding 위치에서는 assignment_pattern, cover grammar에서는 assignment_expression
        if (rest_node.tag == .assignment_pattern or rest_node.tag == .assignment_expression) {
            self.addError(rest_node.span, rest_init_error);
        }
    }

    /// identifier의 소스 텍스트가 escaped reserved keyword인지 확인.
    /// 소스에 `\`가 있고, 디코딩하면 reserved keyword이면 에러.
    /// cover grammar 함수 내부 + parseObjectProperty에서 사용.
    fn checkIdentifierEscapedKeyword(self: *Parser, span: Span) void {
        const text = self.resolveIdentifierText(span);
        if (token_mod.keywords.get(text)) |kw| {
            // yield/await는 context-dependent keywords — checkYieldAwaitUse에서 별도 검증.
            // 여기서 에러를 내면 generator/async 밖에서도 잘못 에러가 발생한다.
            if (kw == .kw_yield or kw == .kw_await) return;
            if (kw.isReservedKeyword() or kw.isLiteralKeyword()) {
                self.addError(span, "keywords cannot contain escape characters");
            }
        }
    }

    /// identifier span의 소스 텍스트를 반환. escape가 있으면 디코딩한 결과를 반환.
    /// 키워드 매칭에 사용 — escape 유무와 관계없이 동일한 resolved text 반환.
    fn resolveIdentifierText(self: *Parser, span: Span) []const u8 {
        const text = self.ast.source[span.start..span.end];
        if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
        return self.scanner.decodeIdentifierEscapes(text) orelse text;
    }

    // ================================================================
    // Cover Grammar: expression → assignment target 재해석 (oxc 방식)
    // ================================================================
    //
    // ECMAScript의 "cover grammar"은 expression과 pattern이 같은 구문 형태를
    // 공유하기 때문에 파서가 expression으로 먼저 파싱한 후, 문맥에 따라
    // assignment target으로 재해석하는 메커니즘이다.
    //
    // 예: `[a, b] = [1, 2]` — 좌변은 array_expression으로 파싱되지만
    //     `=`를 만나는 순간 array destructuring pattern으로 재해석된다.
    //
    // 기존에는 이 재해석을 위한 검증이 6개 함수에 분산되어 있었다.
    // coverExpressionToAssignmentTarget은 이를 단일 재귀 walk로 통합한다.
    //
    // 한 번의 순회에서 검증하는 규칙:
    // 1. 구조적 유효성: identifier, member expr, destructuring만 assignment target
    // 2. rest/spread initializer 금지: [...x = 1] = arr → SyntaxError
    // 3. escaped keyword 금지: ({ v\u0061r }) = x → SyntaxError
    // 4. strict mode eval/arguments 할당 금지
    // 5. parenthesized destructuring 금지: ({x}) = 1 → SyntaxError

    /// expression을 assignment target으로 검증하는 단일 재귀 walk.
    /// 기존의 isValidAssignmentTarget + checkRestInitInAssignmentPattern +
    /// checkSpreadRestInit + checkEscapedKeywordInPattern +
    /// checkStrictAssignmentTarget 5개 함수를 하나로 통합한다.
    ///
    /// cover grammar: expression → assignment target으로 변환.
    /// 태그를 변환하고 (setTag) 검증도 수행한다.
    /// 반환값: true면 valid assignment target, false면 에러를 이미 추가했거나 invalid.
    /// is_top이 true면 최상위 호출 (invalid일 때 "invalid assignment target" 에러 추가).
    fn coverExpressionToAssignmentTarget(self: *Parser, idx: NodeIndex, is_top: bool) bool {
        if (idx.isNone()) return false;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            // 1) identifier — valid target. 태그를 assignment_target_identifier로 변환.
            .identifier_reference => {
                // escaped keyword 검증: v\u0061r → "var"이면 에러
                self.checkIdentifierEscapedKeyword(node.span);
                // strict mode: eval/arguments에 할당 금지 (checkStrictBinding 내부에서 strict 체크)
                self.checkStrictBinding(node.span);
                self.ast.setTag(idx, .assignment_target_identifier);
                return true;
            },
            .private_identifier, .private_field_expression => true,

            // 2) member expression — optional chaining이 아니면 valid (태그 유지)
            .static_member_expression, .computed_member_expression => {
                if (node.data.binary.flags == 0) return true; // normal
                // optional chaining (a?.b, a?.[b])은 assignment target이 아님
                if (is_top) self.addError(node.span, "invalid assignment target");
                return false;
            },

            // 3) array destructuring — 태그를 array_assignment_target으로 변환 + 자식 재귀
            .array_expression => {
                self.ast.setTag(idx, .array_assignment_target);
                self.coverArrayExpressionToTarget(node);
                return true;
            },

            // 4) object destructuring — 태그를 object_assignment_target으로 변환 + 자식 재귀
            .object_expression => {
                self.ast.setTag(idx, .object_assignment_target);
                self.coverObjectExpressionToTarget(node);
                // CoverInitializedName이 destructuring으로 정상 소비됨
                self.has_cover_init_name = false;
                return true;
            },

            // 5) parenthesized expression — 내부를 벗겨서 검증
            .parenthesized_expression => {
                const inner = node.data.unary.operand;
                if (inner.isNone()) {
                    if (is_top) self.addError(node.span, "invalid assignment target");
                    return false;
                }
                const inner_tag = self.ast.getNode(inner).tag;
                // ({x}) = 1, ([x]) = 1 → parenthesized destructuring 금지
                if (inner_tag == .array_expression or inner_tag == .object_expression) {
                    self.addError(node.span, "invalid assignment target");
                    return false;
                }
                // (x) = 1 → 내부가 simple target이면 OK
                return self.coverExpressionToAssignmentTarget(inner, is_top);
            },

            // 6) 이미 변환된 assignment target 태그는 유지
            .assignment_target_identifier,
            .array_assignment_target,
            .object_assignment_target,
            => true,

            // 7) meta_property (import.meta, new.target) — 절대로 assignment target이 될 수 없음.
            //    is_top 여부와 무관하게 항상 에러. else 분기는 is_top=false일 때 에러를 내지 않으므로
            //    destructuring 내부([import.meta] = arr)에서 잘못 통과하는 것을 방지.
            .meta_property => {
                self.addError(node.span, "invalid assignment target");
                return false;
            },

            else => {
                if (is_top) self.addError(node.span, "invalid assignment target");
                return false;
            },
        };
    }

    /// spread element의 operand를 검증하는 cover grammar 헬퍼.
    /// rest에 initializer가 있으면 에러를 내고, operand를 재귀 검증한다.
    /// coverArrayExpressionToTarget과 coverObjectExpressionToTarget에서 공통 사용.
    fn coverSpreadElementToTarget(self: *Parser, spread_idx: NodeIndex, operand_idx: NodeIndex) void {
        const operand = self.ast.getNode(operand_idx);
        if (operand.tag == .assignment_expression) {
            self.addError(operand.span, rest_init_error);
        }
        // spread_element → assignment_target_rest로 변환
        self.ast.setTag(spread_idx, .assignment_target_rest);
        _ = self.coverExpressionToAssignmentTarget(operand_idx, true);
    }

    /// array expression 내부를 assignment target으로 검증 (coverExpressionToAssignmentTarget 헬퍼).
    /// 각 요소의 spread rest-init 금지 + nested pattern 재귀 검증.
    fn coverArrayExpressionToTarget(self: *Parser, node: Node) void {
        const list = node.data.list;
        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
            if (elem_idx.isNone()) continue; // elision (none)
            const elem = self.ast.getNode(elem_idx);
            if (elem.tag == .elision) continue; // elision node — destructuring에서는 무시
            switch (elem.tag) {
                .spread_element => {
                    // rest는 마지막 요소여야 함: [...x, y] → SyntaxError
                    if (i + 1 < list.len) {
                        self.addError(elem.span, "rest element must be last element");
                    }
                    // rest 뒤 trailing comma 금지: [...x,] → SyntaxError
                    // parseArrayExpression에서 spread_trailing_comma로 마킹됨
                    if ((elem.data.unary.flags & spread_trailing_comma) != 0) {
                        self.addError(elem.span, "rest element may not have a trailing comma");
                    }
                    self.coverSpreadElementToTarget(elem_idx, elem.data.unary.operand);
                },
                .assignment_expression => {
                    // [x = 1] → assignment_target_with_default로 변환
                    self.ast.setTag(elem_idx, .assignment_target_with_default);
                    _ = self.coverExpressionToAssignmentTarget(elem.data.binary.left, true);
                },
                else => {
                    // identifier, nested array/object/member 등 → 재귀 검증
                    _ = self.coverExpressionToAssignmentTarget(elem_idx, true);
                },
            }
        }
    }

    /// object expression 내부를 assignment target으로 검증 (coverExpressionToAssignmentTarget 헬퍼).
    /// 각 프로퍼티의 shorthand escaped keyword + strict eval/arguments + spread rest-init + nested value 재귀 검증.
    fn coverObjectExpressionToTarget(self: *Parser, node: Node) void {
        const list = node.data.list;
        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
            if (elem_idx.isNone()) continue;
            const elem = self.ast.getNode(elem_idx);
            if (elem.tag == .object_property) {
                const is_shorthand_default = (elem.data.binary.flags & shorthand_with_default) != 0;
                if (!elem.data.binary.left.isNone() and elem.data.binary.right.isNone()) {
                    // shorthand without value: { eval } — right가 none인 경우
                    // parseObjectProperty에서 shorthand는 value를 생성하지 않으므로 right=none
                    const key_span = self.ast.getNode(elem.data.binary.left).span;
                    self.checkIdentifierEscapedKeyword(key_span);
                    self.checkStrictBinding(key_span);
                    self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                } else if (!elem.data.binary.left.isNone() and !elem.data.binary.right.isNone()) {
                    // shorthand 검증: key와 value가 같은 span이면 shorthand
                    const key_span = self.ast.getNode(elem.data.binary.left).span;
                    const val_node = self.ast.getNode(elem.data.binary.right);
                    const is_shorthand = key_span.start == val_node.span.start and key_span.end == val_node.span.end;
                    if (is_shorthand) {
                        self.checkIdentifierEscapedKeyword(key_span);
                        // strict mode: shorthand에서 eval/arguments 할당 금지
                        self.checkStrictBinding(key_span);
                        // shorthand → assignment_target_property_identifier
                        self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                    } else if (is_shorthand_default) {
                        // shorthand with default: { eval = 0 } — key가 target, value가 default
                        // key의 eval/arguments 검증이 필요 (strict mode)
                        self.checkIdentifierEscapedKeyword(key_span);
                        self.checkStrictBinding(key_span);
                        self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                        // value(default)는 assignment target이 아니므로 검증하지 않음
                    } else {
                        // long-form → assignment_target_property_property
                        self.ast.setTag(elem_idx, .assignment_target_property_property);
                        // value가 assignment_expression이면 default-value 구문:
                        // { key: target = default } → target을 검증, default는 검증하지 않음
                        if (val_node.tag == .assignment_expression) {
                            self.ast.setTag(elem.data.binary.right, .assignment_target_with_default);
                            _ = self.coverExpressionToAssignmentTarget(val_node.data.binary.left, true);
                        } else {
                            // value를 재귀 검증 (nested pattern일 수 있음)
                            _ = self.coverExpressionToAssignmentTarget(elem.data.binary.right, true);
                        }
                    }
                }
            } else if (elem.tag == .spread_element) {
                // rest는 마지막 요소여야 함: {...x, y} → SyntaxError
                if (i + 1 < list.len) {
                    self.addError(elem.span, "rest element must be last element");
                }
                // object rest: {...x} = obj
                self.coverSpreadElementToTarget(elem_idx, elem.data.unary.operand);
            } else if (elem.tag == .method_definition) {
                // method/getter/setter/async/generator는 destructuring target이 아님
                self.addError(elem.span, "invalid assignment target");
            }
        }
    }

    /// cover grammar 표현식에서 바인딩 이름의 span을 재귀 수집하여 중복 검사한다.
    /// 중복 발견 시 즉시 에러를 추가한다.
    fn collectCoverParamNames(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .identifier_reference, .binding_identifier, .assignment_target_identifier => {
                const name = self.ast.source[node.span.start..node.span.end];
                // 이전에 수집된 이름과 비교하여 중복 검사
                // param_name_spans를 사용 — coverExpressionToArrowParams에서 초기화
                for (self.param_name_spans.items) |prev_span| {
                    const prev_name = self.ast.source[prev_span.start..prev_span.end];
                    if (std.mem.eql(u8, name, prev_name)) {
                        self.addError(node.span, "duplicate parameter name");
                        return;
                    }
                }
                self.param_name_spans.append(node.span) catch @panic("OOM");
            },
            .parenthesized_expression => self.collectCoverParamNames(node.data.unary.operand),
            .sequence_expression => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    self.collectCoverParamNames(elem_idx);
                }
            },
            .object_expression, .array_expression, .object_assignment_target, .array_assignment_target => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    self.collectCoverParamNames(elem_idx);
                }
            },
            .object_property, .assignment_target_property_identifier, .assignment_target_property_property => {
                // shorthand: left=key(identifier_reference), right=none → key is the binding
                if (node.data.binary.right.isNone()) {
                    self.collectCoverParamNames(node.data.binary.left);
                } else {
                    // long-form { key: value } → value is the binding
                    // BUT: for shorthand { x } where key==value (same span), also walk left
                    const key_span = if (!node.data.binary.left.isNone()) self.ast.getNode(node.data.binary.left).span else node.span;
                    const val_span = self.ast.getNode(node.data.binary.right).span;
                    if (key_span.start == val_span.start and key_span.end == val_span.end) {
                        // shorthand with value = same as key (e.g., {x} parsed with both key and value)
                        self.collectCoverParamNames(node.data.binary.right);
                    } else {
                        self.collectCoverParamNames(node.data.binary.right);
                    }
                }
            },
            .binding_property => {
                self.collectCoverParamNames(node.data.binary.right);
            },
            .assignment_expression, .assignment_pattern, .assignment_target_with_default => {
                // default value: left = binding, right = default_value
                self.collectCoverParamNames(node.data.binary.left);
                // default value 내부의 yield/await 검사 (이름 수집하지 않고 검사만)
                self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
            },
            .spread_element, .assignment_target_rest, .binding_rest_element, .rest_element => {
                self.collectCoverParamNames(node.data.unary.operand);
            },
            else => {},
        }
    }

    /// expression이 arrow function 파라미터로 유효한 형태인지 확인한다.
    /// parenthesized_expression, identifier_reference 등만 arrow 파라미터가 될 수 있다.
    /// call_expression, member_expression 등은 불가능.
    fn isValidArrowParamForm(self: *const Parser, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            .parenthesized_expression, .identifier_reference, .binding_identifier => true,
            else => false,
        };
    }

    /// async arrow 파라미터에서 'await' 식별자 사용을 금지한다.
    /// async arrow의 파라미터는 async context 진입 전에 파싱되므로 await가 identifier로 파싱된다.
    /// 이 함수는 cover grammar 변환 후 호출하여 identifier 이름이 "await"인 경우를 검출한다.
    fn checkAsyncArrowParamsForAwait(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .identifier_reference, .binding_identifier, .assignment_target_identifier => {
                const name = self.ast.source[node.span.start..node.span.end];
                if (std.mem.eql(u8, name, "await")) {
                    self.addError(node.span, "'await' is not allowed in async arrow function parameters");
                }
            },
            .parenthesized_expression, .spread_element, .assignment_target_rest => {
                self.checkAsyncArrowParamsForAwait(node.data.unary.operand);
            },
            .sequence_expression,
            .array_expression,
            .object_expression,
            .array_assignment_target,
            .object_assignment_target,
            => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    self.checkAsyncArrowParamsForAwait(elem_idx);
                }
            },
            .assignment_expression,
            .assignment_pattern,
            .assignment_target_with_default,
            .object_property,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            .binding_property,
            => {
                self.checkAsyncArrowParamsForAwait(node.data.binary.left);
                self.checkAsyncArrowParamsForAwait(node.data.binary.right);
            },
            // 중첩 arrow의 파라미터에도 await 사용 금지
            .arrow_function_expression => {
                self.checkAsyncArrowParamsForAwait(node.data.binary.left);
            },
            else => {},
        }
    }

    /// arrow 파라미터 default value 내부에 yield/await가 있는지 검사한다.
    /// 이름 수집은 하지 않고 yield/await expression만 검출한다.
    fn checkCoverParamDefaultForYieldAwait(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .yield_expression => {
                self.addError(node.span, "'yield' is not allowed in arrow function parameters");
            },
            .await_expression => {
                self.addError(node.span, "'await' is not allowed in arrow function parameters");
            },
            // unary node — operand만 검사
            .parenthesized_expression,
            .spread_element,
            .unary_expression,
            .update_expression,
            => self.checkCoverParamDefaultForYieldAwait(node.data.unary.operand),
            // list node — 각 요소 검사
            .sequence_expression,
            .array_expression,
            .object_expression,
            => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    self.checkCoverParamDefaultForYieldAwait(elem_idx);
                }
            },
            // binary node — 양쪽 자식 검사
            .assignment_expression,
            .binary_expression,
            .logical_expression,
            .object_property,
            => {
                self.checkCoverParamDefaultForYieldAwait(node.data.binary.left);
                self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
            },
            // conditional은 ternary이지만 binary data 사용 (condition=left, consequent/alternate 조합=right)
            .conditional_expression => {
                self.checkCoverParamDefaultForYieldAwait(node.data.binary.left);
                self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
            },
            // 리프 노드 (identifier, literal 등)나 기타 — 더 이상 탐색 불필요
            else => {},
        }
    }

    /// arrow function 파라미터를 cover grammar으로 검증.
    /// parenthesized/sequence expression을 풀어서 각 요소에
    /// coverExpressionToAssignmentTarget을 위임한다.
    ///
    /// 기존 checkRestInitInArrowParams를 대체한다.
    fn coverExpressionToArrowParams(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .parenthesized_expression) {
            // (expr) → 내부를 다시 풀기
            self.coverExpressionToArrowParams(node.data.unary.operand);
        } else if (node.tag == .sequence_expression) {
            // (a, b, c) → 각 요소를 개별 검증
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                const elem = self.ast.getNode(elem_idx);
                if (elem.tag == .spread_element) {
                    // rest 파라미터: 마지막 요소여야 하고 initializer 금지, trailing comma 금지
                    if (i + 1 < list.len) {
                        self.addError(elem.span, "rest element must be last element");
                    }
                    if ((elem.data.unary.flags & spread_trailing_comma) != 0) {
                        self.addError(elem.span, "rest element may not have a trailing comma");
                    }
                    self.checkBindingRestInit(elem.data.unary.operand);
                    // rest의 operand도 valid assignment target이어야 함
                    _ = self.coverExpressionToAssignmentTarget(elem.data.unary.operand, false);
                } else {
                    _ = self.coverExpressionToAssignmentTarget(elem_idx, false);
                }
            }
        } else if (node.tag == .spread_element) {
            // 단일 rest 파라미터: (...x) → initializer 금지 + trailing comma 금지
            if ((node.data.unary.flags & spread_trailing_comma) != 0) {
                self.addError(node.span, "rest element may not have a trailing comma");
            }
            self.checkBindingRestInit(node.data.unary.operand);
            _ = self.coverExpressionToAssignmentTarget(node.data.unary.operand, false);
        } else {
            // 단일 expression → 직접 검증
            _ = self.coverExpressionToAssignmentTarget(idx, false);
        }
        // arrow 파라미터 중복 검사: (x, {x}) => 1 등
        // cover grammar 변환 후에 수행 (변환된 태그도 처리하므로)
        self.param_name_spans.clearRetainingCapacity();
        self.collectCoverParamNames(idx);
    }

    /// 키워드를 바인딩 위치에서 사용할 때의 검증.
    /// ECMAScript 12.1.1: reserved keyword, strict mode reserved, contextual keywords.
    fn checkKeywordBinding(self: *Parser) void {
        // await는 조건부 예약어 — async/module에서만 금지, script에서는 식별자로 사용 가능
        // yield도 조건부 — generator/strict에서만 금지
        // 둘 다 checkYieldAwaitUse에서 처리
        if (self.current() == .kw_await or self.current() == .kw_yield) {
            self.checkYieldAwaitUse(self.currentSpan(), "identifier");
        } else if (self.current().isReservedKeyword() or self.current().isLiteralKeyword()) {
            self.addError(self.currentSpan(), "reserved word cannot be used as identifier");
        } else if (self.is_strict_mode and self.current().isStrictModeReserved()) {
            self.addError(self.currentSpan(), "reserved word in strict mode cannot be used as identifier");
        }
    }

    /// yield/await를 식별자/레이블/바인딩으로 사용할 때의 검증.
    /// ECMAScript 13.1.1: yield는 [Yield] 또는 strict mode에서, await는 [Await] 또는 module에서 금지.
    /// context_noun: "identifier", "label" 등 — 에러 메시지에 사용 (comptime 문자열 연결).
    fn checkYieldAwaitUse(self: *Parser, span: Span, comptime context_noun: []const u8) void {
        // yield/await는 escaped 형태(yi\u0065ld)도 동일 규칙 적용 (ECMAScript 12.1.1)
        // await는 reserved keyword이므로 escaped_keyword로 분류됨 → 여기서는 yield만 처리
        const is_yield = self.current() == .kw_yield or
            (self.current() == .escaped_strict_reserved and self.isEscapedKeyword("yield"));
        const is_await = self.current() == .kw_await;

        if (is_yield) {
            if (self.ctx.in_generator) {
                self.addError(span, "'yield' cannot be used as " ++ context_noun ++ " in generator");
            } else if (self.is_strict_mode) {
                self.addError(span, "'yield' cannot be used as " ++ context_noun ++ " in strict mode");
            }
        } else if (is_await) {
            if (self.ctx.in_async) {
                self.addError(span, "'await' cannot be used as " ++ context_noun ++ " in async function");
            } else if (self.is_module) {
                self.addError(span, "'await' cannot be used as " ++ context_noun ++ " in module code");
            }
        }
    }

    /// escaped_strict_reserved 토큰이 특정 키워드인지 확인한다.
    /// Scanner.decodeIdentifierEscapes로 디코딩 후 비교.
    fn isEscapedKeyword(self: *Parser, comptime expected: []const u8) bool {
        const decoded = self.scanner.decodeIdentifierEscapes(self.tokenText()) orelse return false;
        return std.mem.eql(u8, decoded, expected);
    }

    // ================================================================
    // 컨텍스트 저장/복원 (D051: 함수 경계에서 컨텍스트 리셋)
    // ================================================================
    //
    // 함수 진입 시 SavedState로 ctx(u8) + 관련 Parser 필드를 저장/복원한다.
    // allow_in 등 Context만 변경하는 경우는 ctx를 직접 save/restore한다.

    /// 함수 컨텍스트를 설정한다.
    /// 현재 ctx와 관련 Parser 필드를 SavedState에 저장하고, 함수 진입 상태로 변경한다.
    /// 함수/메서드/arrow 진입 시 호출하고, 본문 파싱 후 restoreFunctionContext()로 복원.
    fn enterFunctionContext(self: *Parser, is_async: bool, is_generator: bool) SavedState {
        const saved = SavedState{
            .ctx = self.ctx,
            .is_strict_mode = self.is_strict_mode,
            .in_loop = self.in_loop,
            .in_switch = self.in_switch,
            .has_simple_params = self.has_simple_params,
            .for_loop_init = self.for_loop_init,
            .in_class_field = self.in_class_field,
            .in_static_initializer = self.in_static_initializer,
            .allow_new_target = self.allow_new_target,
            .allow_super_call = self.allow_super_call,
            .allow_super_property = self.allow_super_property,
            .in_formal_parameters = self.in_formal_parameters,
        };
        self.ctx = self.ctx.enterFunction(is_async, is_generator);
        // Parser 필드 리셋 — 함수 경계에서 초기 상태로
        self.in_loop = false;
        self.in_switch = false;
        self.has_simple_params = true; // 기본값은 true (checkSimpleParams에서 갱신)
        self.for_loop_init = false;
        self.allow_super_call = false;
        self.allow_super_property = false;
        self.in_class_field = false;
        self.in_static_initializer = false;
        self.allow_new_target = true; // 일반 함수에서는 new.target 허용
        self.in_formal_parameters = false;
        return saved;
    }

    /// 함수 컨텍스트를 복원한다 (enterFunctionContext와 쌍).
    fn restoreFunctionContext(self: *Parser, saved: SavedState) void {
        self.ctx = saved.ctx;
        self.is_strict_mode = saved.is_strict_mode;
        self.in_loop = saved.in_loop;
        self.in_switch = saved.in_switch;
        self.has_simple_params = saved.has_simple_params;
        self.for_loop_init = saved.for_loop_init;
        self.in_class_field = saved.in_class_field;
        self.in_static_initializer = saved.in_static_initializer;
        self.allow_new_target = saved.allow_new_target;
        self.allow_super_call = saved.allow_super_call;
        self.allow_super_property = saved.allow_super_property;
        self.in_formal_parameters = saved.in_formal_parameters;
    }

    /// Context(u8)를 복원한다 (enterAllowInContext 등과 쌍).
    fn restoreContext(self: *Parser, saved: Context) void {
        self.ctx = saved;
    }

    /// `in` 연산자 허용/금지 컨텍스트에 진입한다.
    /// ECMAScript 문법의 [+In]/[~In] 파라미터 전환에 사용.
    /// 반환값을 restoreContext()에 전달하여 복원.
    fn enterAllowInContext(self: *Parser, allow: bool) Context {
        const saved = self.ctx;
        self.ctx.allow_in = allow;
        return saved;
    }

    /// 현재 토큰이 "use strict" directive인지 확인한다.
    /// directive prologue에서 호출 — tokenText()는 따옴표를 포함하므로 내부를 비교.
    fn isUseStrictDirective(self: *const Parser) bool {
        if (self.current() != .string_literal) return false;
        const text = self.tokenText();
        // "use strict" 또는 'use strict' — 따옴표 포함 길이 = "use strict".len + 2 = 12
        if (text.len < "\"use strict\"".len) return false;
        const inner = text[1 .. text.len - 1];
        return std.mem.eql(u8, inner, "use strict");
    }

    /// 루프 본문을 파싱한다. in_loop를 save/restore.
    fn parseLoopBody(self: *Parser) ParseError2!NodeIndex {
        const saved_in_loop = self.in_loop;
        self.in_loop = true;
        const body = try self.parseStatementChecked(true);
        self.in_loop = saved_in_loop;

        // ECMAScript 14.7.5: It is a Syntax Error if IsLabelledFunction(Statement) is true.
        // 반복문의 body가 labelled function이면 에러 (중첩 label도 재귀 검사).
        // Annex B의 labelled function 예외는 반복문 body에서 적용되지 않는다.
        self.checkLabelledFunction(body);

        return body;
    }

    /// IsLabelledFunction 검사: labeled statement을 재귀적으로 따라가서
    /// 최종 body가 function declaration이면 에러를 발생시킨다.
    fn checkLabelledFunction(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .labeled_statement) {
            // labeled_statement의 body는 binary.right에 저장됨
            const inner = node.data.binary.right;
            const inner_node = self.ast.getNode(inner);
            if (inner_node.tag == .function_declaration) {
                self.addError(inner_node.span, "labelled function declaration is not allowed in loop body");
            } else if (inner_node.tag == .labeled_statement) {
                // 중첩 label: label1: label2: function f() {}
                self.checkLabelledFunction(inner);
            }
        }
    }

    /// 파라미터 리스트가 simple인지 검사한다.
    /// simple = 모든 파라미터가 binding_identifier (destructuring, default, rest 없음)
    /// arrow function의 cover grammar 파라미터가 simple인지 확인한다.
    /// simple = 모든 파라미터가 plain identifier (destructuring, default, rest 없음).
    /// "use strict" + non-simple params → SyntaxError (ECMAScript 14.2.1).
    fn isSimpleArrowParams(self: *const Parser, param_idx: NodeIndex) bool {
        if (param_idx.isNone()) return true; // () → simple
        const node = self.ast.getNode(param_idx);
        return switch (node.tag) {
            // 단일 식별자: x => ... → simple
            .binding_identifier, .identifier_reference, .assignment_target_identifier => true,
            // 괄호 표현식: (x) → 내부 확인
            .parenthesized_expression => {
                if (node.data.unary.operand.isNone()) return true; // () → simple
                return self.isSimpleArrowParams(node.data.unary.operand);
            },
            // 콤마 리스트: (a, b, c) → 각 요소 확인
            .sequence_expression => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    if (!self.isSimpleArrowParams(elem_idx)) return false;
                }
                return true;
            },
            // destructuring, default, rest, spread → non-simple
            else => false,
        };
    }

    fn checkSimpleParams(self: *const Parser, scratch_top: usize) bool {
        const params = self.scratch.items[scratch_top..];
        for (params) |param_idx| {
            if (param_idx.isNone()) continue;
            const node = self.ast.getNode(param_idx);
            switch (node.tag) {
                .binding_identifier => {}, // simple
                else => return false, // destructuring, default, rest, formal_parameter 등
            }
        }
        return true;
    }

    /// 중복 파라미터를 검사한다.
    /// ECMAScript 14.1.2: non-simple params면 항상 에러
    /// ECMAScript 15.4.1/15.5.1: generator/async generator는 항상 에러
    /// strict mode에서도 항상 에러
    /// sloppy mode + simple params인 일반 function만 허용
    fn checkDuplicateParams(self: *Parser, scratch_top: usize) void {
        const must_check = self.is_strict_mode or !self.has_simple_params or
            self.ctx.in_generator or self.ctx.in_async;
        if (!must_check) return;
        const params = self.scratch.items[scratch_top..];
        // O(N²)이지만 파라미터 수가 적으므로 (보통 <10) 충분
        for (params, 0..) |param_idx, i| {
            const name_span = self.extractParamName(param_idx) orelse continue;
            const name = self.ast.source[name_span.start..name_span.end];
            for (params[0..i]) |prev_idx| {
                const prev_span = self.extractParamName(prev_idx) orelse continue;
                const prev_name = self.ast.source[prev_span.start..prev_span.end];
                if (std.mem.eql(u8, name, prev_name)) {
                    self.addError(name_span, "duplicate parameter name");
                    break;
                }
            }
        }
    }

    /// 파라미터 노드에서 바인딩 이름의 Span을 추출한다.
    /// binding_identifier, assignment_pattern(= default), formal_parameter(TS modifier),
    /// spread_element(...rest) 등 다양한 형태를 재귀적으로 처리.
    /// destructuring([a,b], {a,b})은 단일 이름이 아니므로 null 반환.
    fn extractParamName(self: *const Parser, idx: NodeIndex) ?Span {
        if (idx.isNone()) return null;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            .binding_identifier => node.span,
            // x = default → left가 binding name
            .assignment_pattern => self.extractParamName(node.data.binary.left),
            // TS parameter property (public x 등) → operand가 binding
            .formal_parameter => self.extractParamName(node.data.unary.operand),
            // rest parameter (...x) → operand가 binding
            .spread_element => self.extractParamName(node.data.unary.operand),
            // TODO: destructuring([a,b], {a})은 collectBoundNames로 여러 이름을 수집해야 함
            else => null,
        };
    }

    /// "use strict" directive가 발견된 후 함수 이름이 eval/arguments인지 소급 검증.
    /// ECMAScript 14.1.2: strict mode에서 eval/arguments를 바인딩 이름으로 사용 금지.
    fn checkStrictFunctionName(self: *Parser, name_idx: NodeIndex) void {
        if (name_idx.isNone()) return;
        const node = self.ast.getNode(name_idx);
        if (node.tag != .binding_identifier) return;
        self.checkStrictBinding(node.span);
    }

    /// "use strict" directive가 발견된 후 파라미터 이름을 소급 검증.
    /// ECMAScript 14.1.2: strict mode에서 eval/arguments + 중복 파라미터 금지.
    fn checkStrictParamNames(self: *Parser, scratch_top: usize) void {
        const params = self.scratch.items[scratch_top..];
        for (params) |param_idx| {
            const name_span = self.extractParamName(param_idx) orelse continue;
            self.checkStrictBinding(name_span);
        }
        // 중복 파라미터도 소급 검사 (simple params + sloppy에서는 허용이지만 strict에서는 금지)
        self.checkDuplicateParams(scratch_top);
    }

    /// 함수 선언의 본문을 파싱한다 (닫는 `}` 뒤의 `/`는 regexp로 토큰화).
    fn parseFunctionBody(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionBodyInner(false);
    }

    /// 표현식 컨텍스트에서 함수 본문을 파싱한다.
    /// 닫는 `}` 뒤의 `/`가 division으로 올바르게 토큰화된다.
    fn parseFunctionBodyExpr(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionBodyInner(true);
    }

    fn parseFunctionBodyInner(self: *Parser, in_expression: bool) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        // directive prologue: 본문 시작의 문자열 리터럴 expression statement 중 "use strict" 감지
        var in_directive_prologue = true;
        // directive prologue에서 "use strict" 이전의 문자열에 legacy octal이 있으면
        // retroactive하게 에러 보고 (ECMAScript 12.8.4.1)
        var has_prologue_octal = false;
        var prologue_octal_span: Span = Span.EMPTY;

        while (self.current() != .r_curly and self.current() != .eof) {
            if (in_directive_prologue) {
                if (self.isUseStrictDirective()) {
                    // non-simple parameters + "use strict" → 에러
                    // ECMAScript 14.1.2: function with non-simple parameter list
                    // shall not contain a Use Strict Directive
                    if (!self.has_simple_params) {
                        self.addError(self.currentSpan(), "\"use strict\" not allowed in function with non-simple parameters");
                    }
                    self.is_strict_mode = true;
                    // "use strict" 이전에 octal escape가 있었으면 retroactive 에러
                    if (has_prologue_octal) {
                        self.addError(prologue_octal_span, "Octal escape sequences are not allowed in strict mode");
                    }
                } else if (self.current() == .string_literal) {
                    // directive prologue의 문자열 — octal escape 추적
                    if (self.scanner.token.has_legacy_octal and !has_prologue_octal) {
                        has_prologue_octal = true;
                        prologue_octal_span = self.currentSpan();
                    }
                } else {
                    in_directive_prologue = false;
                }
            }

            const stmt = try self.parseStatement();
            if (!stmt.isNone()) try stmts.append(stmt);
        }

        const end = self.currentSpan().end;

        // 표현식 컨텍스트(함수 표현식, 클래스 메서드 등)에서는 닫는 `}` 뒤의 `/`가
        // division이어야 한다. scanner.prev_token_kind를 `.r_paren`으로 설정하면
        // scanSlash()가 slashIsRegex()=false로 판단하여 division으로 토큰화한다.
        // 이 설정은 expect 내부의 advance() → scanner.next()에서 사용된다.
        if (in_expression) {
            self.scanner.prev_token_kind = .r_paren;
        }
        self.expect(.r_curly);

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .block_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    // ================================================================
    // 프로그램 파싱 (최상위)
    // ================================================================

    /// 소스 전체를 파싱하여 AST를 반환한다.
    pub fn parse(self: *Parser) !NodeIndex {
        self.advance(); // 첫 토큰 로드

        // module 모드면 항상 strict (D054)
        if (self.is_module) {
            self.is_strict_mode = true;
        }

        // hashbang (#! ...) 건너뛰기
        if (self.current() == .hashbang_comment) {
            self.advance();
        }

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        // directive prologue 감지: 프로그램 시작 부분의 "use strict"
        var in_directive_prologue = true;

        while (self.current() != .eof) {
            if (in_directive_prologue) {
                if (self.isUseStrictDirective()) {
                    self.is_strict_mode = true;
                } else if (self.current() != .string_literal) {
                    // directive prologue는 문자열 expression statement가 연속되는 동안 유효
                    in_directive_prologue = false;
                }
            }

            const stmt = try self.parseStatement();
            if (!stmt.isNone()) {
                try stmts.append(stmt);
            }
        }

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .program,
            .span = .{ .start = 0, .end = @intCast(self.scanner.source.len) },
            .data = .{ .list = list },
        });
    }

    // ================================================================
    // Statement 파싱
    // ================================================================

    /// statement position에서 lexical/function declaration 금지를 체크한 뒤 parseStatement 호출.
    /// is_loop_body: true면 for/while/do-while/with body (function도 항상 금지)
    ///               false면 if/else/labeled body (function은 Annex B로 non-strict 허용)
    fn parseStatementChecked(self: *Parser, comptime is_loop_body: bool) ParseError2!NodeIndex {
        switch (self.current()) {
            .kw_const => {
                self.addError(self.currentSpan(), "lexical declaration is not allowed in statement position");
            },
            .kw_let => {
                if (self.is_strict_mode) {
                    self.addError(self.currentSpan(), "lexical declaration is not allowed in statement position");
                } else if (self.isLetDeclarationStart()) {
                    // sloppy mode에서도 `let`이 LexicalDeclaration으로 해석되면 에러
                    // isLetDeclarationStart: 줄바꿈 없이 identifier/[/{, 또는 줄바꿈 있어도 [
                    self.addError(self.currentSpan(), "lexical declaration is not allowed in statement position");
                }
            },
            .kw_class => {
                // class declaration은 statement position에서 항상 금지 (Annex B에 class 예외 없음)
                self.addError(self.currentSpan(), "class declaration is not allowed in statement position");
            },
            .kw_function => {
                if (self.peekNextKind() == .star) {
                    // generator는 항상 금지
                    self.addError(self.currentSpan(), "generator declaration is not allowed in statement position");
                } else if (is_loop_body or self.in_labelled_fn_check) {
                    // loop/with body에서 function은 항상 금지 (ECMAScript 13.7.4, Annex B 미적용)
                    // labelled function이 if/with body를 통해 전파된 경우도 금지
                    self.addError(self.currentSpan(), "function declaration is not allowed in statement position");
                } else if (self.is_strict_mode) {
                    // if/else/labeled body에서는 strict mode에서만 금지
                    self.addError(self.currentSpan(), "function declaration is not allowed in statement position in strict mode");
                }
            },
            .kw_async => {
                const peek = self.peekNext();
                if (peek.kind == .kw_function and !peek.has_newline_before) {
                    self.addError(self.currentSpan(), "async function declaration is not allowed in statement position");
                }
            },
            .kw_export => {
                self.addError(self.currentSpan(), "'export' is not allowed in statement position");
            },
            .kw_import => {
                // import()와 import.meta는 expression이므로 제외
                const peek = self.peekNextKind();
                if (peek != .l_paren and peek != .dot) {
                    self.addError(self.currentSpan(), "'import' is not allowed in statement position");
                }
            },
            else => {},
        }
        return self.parseStatement();
    }

    fn parseStatement(self: *Parser) ParseError2!NodeIndex {
        return switch (self.current()) {
            .l_curly => self.parseBlockStatement(),
            .semicolon => self.parseEmptyStatement(),
            .kw_var => self.parseVariableDeclaration(),
            // ECMAScript: sloppy mode에서 `let`은 LexicalDeclaration으로 취급되려면
            // 뒤에 줄바꿈 없이 BindingIdentifier, `[`, `{`가 와야 한다.
            // 그렇지 않으면 식별자로 취급하여 expression statement로 파싱한다.
            .kw_let => if (self.is_strict_mode or self.isLetDeclarationStart())
                self.parseVariableDeclaration()
            else
                self.parseExpressionStatement(),
            .kw_const => if (self.peekNextKind() == .kw_enum)
                self.parseConstEnum()
            else
                self.parseVariableDeclaration(),
            // using declaration (TC39 Stage 3: Explicit Resource Management)
            // `using x = getResource()` — parsed like const
            .kw_using => if (self.isUsingDeclarationStart())
                self.parseVariableDeclaration()
            else
                self.parseExpressionOrLabeledStatement(),
            // await using declaration: `await using x = getResource()`
            .kw_await => if (self.isAwaitUsingDeclarationStart())
                self.parseAwaitUsingDeclaration()
            else
                self.parseExpressionOrLabeledStatement(),
            .kw_return => self.parseReturnStatement(),
            .kw_if => self.parseIfStatement(),
            .kw_while => self.parseWhileStatement(),
            .kw_do => self.parseDoWhileStatement(),
            .kw_for => self.parseForStatement(),
            .kw_switch => self.parseSwitchStatement(),
            .kw_break => self.parseSimpleStatement(.break_statement),
            .kw_continue => self.parseSimpleStatement(.continue_statement),
            .kw_throw => self.parseThrowStatement(),
            .kw_try => self.parseTryStatement(),
            .kw_debugger => self.parseSimpleStatement(.debugger_statement),
            .kw_async => self.parseAsyncStatement(),
            .kw_function => self.parseFunctionDeclaration(),
            .kw_class => self.parseClassDeclaration(),
            .kw_import => blk: {
                const next = self.peekNextKind();
                break :blk if (next == .l_paren or next == .dot)
                    self.parseExpressionStatement()
                else
                    self.parseImportDeclaration();
            },
            .kw_export => self.parseExportDeclaration(),
            // Decorator: @expr class Foo {}
            .at => self.parseDecoratedStatement(),
            // TypeScript declarations
            .kw_type => self.parseTsTypeAliasDeclaration(),
            .kw_interface => self.parseTsInterfaceDeclaration(),
            .kw_enum => self.parseTsEnumDeclaration(),
            .kw_namespace, .kw_module => self.parseTsModuleDeclaration(),
            .kw_declare => self.parseTsDeclareStatement(),
            .kw_abstract => self.parseTsAbstractClass(),
            .kw_with => self.parseWithStatement(),
            else => self.parseExpressionOrLabeledStatement(),
        };
    }

    fn parseBlockStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        // 블록 안에서는 top-level이 아님 (import/export 금지)
        const block_saved = self.ctx;
        self.ctx.is_top_level = false;

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        while (self.current() != .r_curly and self.current() != .eof) {
            const stmt = try self.parseStatement();
            if (!stmt.isNone()) try stmts.append(stmt);
        }

        self.ctx = block_saved;

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .block_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    fn parseEmptyStatement(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        self.advance(); // skip ;
        return try self.ast.addNode(.{
            .tag = .empty_statement,
            .span = span,
            .data = .{ .none = 0 },
        });
    }

    fn parseExpressionStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.has_cover_init_name = false;
        const expr = try self.parseExpression();
        // CoverInitializedName ({ x = 1 }) 이 destructuring으로 소비되지 않았으면 에러
        if (self.has_cover_init_name) {
            self.addError(.{ .start = start, .end = self.currentSpan().start }, "invalid shorthand property initializer");
            self.has_cover_init_name = false;
        }
        const end = self.currentSpan().end;
        self.expectSemicolon(); // ASI 규칙 적용: 개행/}/EOF 있으면 삽입, 아니면 에러
        return try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
        });
    }

    /// expression statement 또는 labeled statement를 파싱한다.
    /// ECMAScript: sloppy mode에서 `let`이 LexicalDeclaration의 시작인지 판별한다.
    /// `let` 뒤에 줄바꿈 없이 BindingIdentifier, `[`, `{`가 오면 LexicalDeclaration이다.
    /// 그 외에는 `let`을 식별자로 취급한다 (expression statement).
    fn isLetDeclarationStart(self: *Parser) bool {
        const next = self.peekNext();
        if (next.has_newline_before) {
            // `let` 뒤에 줄바꿈이 있으면, 일반적으로 ASI가 적용되어 `let`은 식별자.
            // 예외 1: `let [` → ExpressionStatement lookahead 제한으로 항상 LexicalDeclaration.
            // 예외 2: `let\nlet`, `let\nyield`(generator), `let\nawait`(async) →
            //         spec 5.3에 의해 ASI 전에 production 매칭 → LexicalDeclaration으로 해석.
            //         static semantics에서 에러 보고 (let은 binding 불가 등).
            if (next.kind == .l_bracket) return true;
            if (next.kind == .kw_let) return true;
            if (next.kind == .kw_yield and self.ctx.in_generator) return true;
            if (next.kind == .kw_await and self.ctx.in_async) return true;
            return false;
        }
        // 줄바꿈 없이 바로 오는 경우: identifier, [, {, escaped_strict_reserved → LexicalDeclaration
        return next.kind == .identifier or next.kind == .l_bracket or next.kind == .l_curly or
            next.kind == .escaped_strict_reserved or
            (next.kind.isKeyword() and !next.kind.isReservedKeyword() and !next.kind.isLiteralKeyword());
    }

    /// `using` 뒤에 줄바꿈 없이 identifier가 오면 UsingDeclaration으로 해석한다.
    fn isUsingDeclarationStart(self: *Parser) bool {
        const next = self.peekNext();
        if (next.has_newline_before) return false;
        return next.kind == .identifier or
            (next.kind.isKeyword() and !next.kind.isReservedKeyword() and !next.kind.isLiteralKeyword());
    }

    /// `await` + `using` + identifier (줄바꿈 없이) → AwaitUsingDeclaration
    fn isAwaitUsingDeclarationStart(self: *Parser) bool {
        if (!self.ctx.in_async) return false;
        const next = self.peekNext();
        if (next.has_newline_before or next.kind != .kw_using) return false;
        // await using 뒤에 identifier가 와야 함 — 더 앞은 볼 수 없으므로 true 반환
        return true;
    }

    /// `await using x = expr;` 선언을 파싱한다.
    fn parseAwaitUsingDeclaration(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'await'
        return self.parseVariableDeclaration(); // 'using'부터 parseVariableDeclaration 진행
    }

    /// `identifier:` 패턴이면 labeled statement, 아니면 expression statement.
    fn parseExpressionOrLabeledStatement(self: *Parser) ParseError2!NodeIndex {
        // identifier/keyword: statement — labeled statement 판별
        // kw_await/kw_yield도 조건부로 식별자/label 사용 가능 (non-async/non-generator)
        if (self.current() == .identifier or self.current() == .escaped_keyword or
            self.current() == .escaped_strict_reserved or
            self.current() == .kw_await or self.current() == .kw_yield or
            (self.current().isKeyword() and !self.current().isReservedKeyword() and !self.current().isLiteralKeyword()))
        {
            const peek = self.peekNext();
            if (peek.kind == .colon) {
                // yield/await를 label로 사용하면 generator/async에서 에러
                self.checkYieldAwaitUse(self.currentSpan(), "label");
                if (self.current() == .escaped_keyword) {
                    // escaped `await` is only reserved in module/async context
                    const esc_text = self.resolveIdentifierText(self.currentSpan());
                    const is_escaped_await = std.mem.eql(u8, esc_text, "await");
                    if (is_escaped_await) {
                        if (self.is_module or self.ctx.in_async) {
                            self.addError(self.currentSpan(), "escaped reserved word cannot be used as label");
                        }
                    } else {
                        self.addError(self.currentSpan(), "escaped reserved word cannot be used as label");
                    }
                } else if (self.current() == .escaped_strict_reserved and self.is_strict_mode) {
                    self.addError(self.currentSpan(), "escaped reserved word cannot be used as label in strict mode");
                } else if (self.is_strict_mode and self.current().isStrictModeReserved()) {
                    self.addError(self.currentSpan(), "reserved word in strict mode cannot be used as label");
                }
                return self.parseLabeledStatement();
            }
        }
        return self.parseExpressionStatement();
    }

    /// labeled statement: label: statement
    fn parseLabeledStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // label
        const label = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = self.currentSpan(),
            .data = .{ .string_ref = self.currentSpan() },
        });
        self.advance(); // skip label
        self.advance(); // skip ':'
        const body = try self.parseStatementChecked(false);
        return try self.ast.addNode(.{
            .tag = .labeled_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = label, .right = body, .flags = 0 } },
        });
    }

    /// with statement: with (expr) statement
    /// strict mode에서는 SyntaxError (D054)
    fn parseWithStatement(self: *Parser) ParseError2!NodeIndex {
        if (self.is_strict_mode) {
            self.addError(self.currentSpan(), "'with' is not allowed in strict mode");
        }
        const start = self.currentSpan().start;
        self.advance(); // skip 'with'
        self.expect(.l_paren);
        const obj = try self.parseExpression();
        self.expect(.r_paren);
        // with body에서 function declaration은 항상 금지 (Annex B에 with 예외 없음)
        // IsLabelledFunction(Statement) 체크도 필요
        const saved_labelled = self.in_labelled_fn_check;
        self.in_labelled_fn_check = true;
        const body = try self.parseStatementChecked(true);
        self.in_labelled_fn_check = saved_labelled;
        return try self.ast.addNode(.{
            .tag = .with_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = obj, .right = body, .flags = 0 } },
        });
    }

    fn parseVariableDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const kind_flags: u32 = switch (self.current()) {
            .kw_var => 0,
            .kw_let => 1,
            .kw_const => 2,
            .kw_using => 2, // using은 const처럼 동작 (block-scoped, immutable)
            else => 0,
        };
        self.advance(); // skip var/let/const/using

        // let/const 선언에서 바인딩 이름 'let'은 금지 (ECMAScript 14.3.1.1)
        // 'let let = 1' → SyntaxError (non-strict에서도)
        if (kind_flags != 0 and self.current() == .kw_let) {
            self.addError(self.currentSpan(), "'let' is not allowed as variable name in lexical declaration");
        }

        const scratch_top = self.saveScratch();
        while (true) {
            const decl = try self.parseVariableDeclarator();
            // const without initializer → SyntaxError (ECMAScript 14.3.1)
            // for-in/for-of에서는 const 이니셜라이저 불필요 (for (const x of ...))
            // TS declare에서도 불필요 (declare const x: number)
            if (kind_flags == 2 and !decl.isNone() and !self.for_loop_init and !self.ctx.in_ambient) {
                const decl_node = self.ast.getNode(decl);
                if (decl_node.tag == .variable_declarator) {
                    const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decl_node.data.extra + 2]);
                    if (init_idx.isNone()) {
                        self.addError(decl_node.span, "const declarations must be initialized");
                    }
                }
            }
            try self.scratch.append(decl);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        // for 초기화절에서는 세미콜론을 for 루프 파서가 처리한다.
        // 일반 문맥에서는 ASI 규칙으로 세미콜론을 처리한다.
        if (self.for_loop_init) {
            // for(var x = 0; ...) — 세미콜론은 parseForStatement에서 expect
        } else {
            self.expectSemicolon();
        }

        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        // extra_data: [kind_flags, list.start, list.len]
        const extra_start = try self.ast.addExtra(kind_flags);
        _ = try self.ast.addExtra(list.start);
        _ = try self.ast.addExtra(list.len);

        return try self.ast.addNode(.{
            .tag = .variable_declaration,
            .span = .{ .start = start, .end = end },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseVariableDeclarator(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // 바인딩 패턴 (identifier, [array], {object} destructuring)
        // 주의: parseBindingPattern이 아닌 parseBindingName을 사용.
        // parseBindingPattern은 `=`를 default value로 소비하지만,
        // variable declarator에서 `=`는 initializer이므로 여기서 소비하면 안 됨.
        const name = try self.parseBindingName();

        // TS 타입 어노테이션 (: Type)
        const type_ann = try self.tryParseTypeAnnotation();

        // 이니셜라이저 — `in` 연산자를 복원한다 (ECMAScript: Initializer[+In]).
        // for 초기화절에서 allow_in=false여도, 이니셜라이저 안에서는 `in`이 연산자로 동작해야 한다.
        var init_expr = NodeIndex.none;
        if (self.eat(.eq)) {
            const init_saved = self.enterAllowInContext(true);
            init_expr = try self.parseAssignmentExpression();
            self.restoreContext(init_saved);
        }

        // name, type_ann, init_expr → extra_data
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(type_ann));
        _ = try self.ast.addExtra(@intFromEnum(init_expr));

        return try self.ast.addNode(.{
            .tag = .variable_declarator,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseReturnStatement(self: *Parser) ParseError2!NodeIndex {
        // return은 함수 안에서만 허용
        if (!self.ctx.in_function) {
            self.addError(self.currentSpan(), "'return' outside of function");
        }
        const start = self.currentSpan().start;
        self.advance(); // skip 'return'

        var arg = NodeIndex.none;
        if (self.current() != .semicolon and self.current() != .eof and
            self.current() != .r_curly and !self.scanner.token.has_newline_before)
        {
            arg = try self.parseExpression();
        }

        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);

        return try self.ast.addNode(.{
            .tag = .return_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
    }

    fn parseIfStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'if'
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        // ECMAScript 13.6.1: IsLabelledFunction(Statement) → SyntaxError
        const saved_labelled = self.in_labelled_fn_check;
        self.in_labelled_fn_check = true;
        const consequent = try self.parseStatementChecked(false);

        var alternate = NodeIndex.none;
        if (self.eat(.kw_else)) {
            alternate = try self.parseStatementChecked(false);
        }
        self.in_labelled_fn_check = saved_labelled;

        return try self.ast.addNode(.{
            .tag = .if_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = test_expr, .b = consequent, .c = alternate } },
        });
    }

    fn parseWhileStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'while'
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        const body = try self.parseLoopBody();

        return try self.ast.addNode(.{
            .tag = .while_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = test_expr, .right = body, .flags = 0 } },
        });
    }

    fn parseDoWhileStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'do'
        const body = try self.parseLoopBody();
        self.expect(.kw_while);
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        _ = self.eat(.semicolon);

        return try self.ast.addNode(.{
            .tag = .do_while_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = test_expr, .right = body, .flags = 0 } },
        });
    }

    fn parseForStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'for'

        // for await (...) — async iteration
        // TODO: for-of 노드에 await 플래그 전달 (현재 파서 통과만 보장)
        const _is_await = self.eat(.kw_await);
        _ = _is_await;

        self.expect(.l_paren);

        // for문의 init 부분 파싱
        // for(init; ...) or for(left in/of right)
        if (self.current() == .semicolon) {
            // for(; ...) — 빈 init
            self.advance();
            return self.parseForRest(start, NodeIndex.none);
        }

        // for 초기화절에서는 `in` 연산자를 비활성화하고 for_loop_init을 설정한다.
        // for_loop_init: const without init 체크 스킵 (for-in/for-of에서는 init 불필요)
        const for_saved = self.enterAllowInContext(false);
        const saved_for_loop_init = self.for_loop_init;
        self.for_loop_init = true;

        // ECMAScript 14.7.5: for ( [lookahead ∉ { let [ }] LeftHandSideExpression in Expression )
        // sloppy mode에서 `let`이 LexicalDeclaration의 시작이 아닌 경우 식별자로 취급.
        // 예: `for (let in x)`, `for (let of x)`, `for (let; ;)`, `for (let = 3; ;)`
        // sloppy mode에서 isLetDeclarationStart가 false이면 `let`을 식별자로 처리.
        // 예: `for (let in x)` — `let`은 식별자.
        // 특수: `for (let of [])` — `let of`를 선언이 아닌 for-of로 해석 (스펙: SyntaxError).
        //   `let` 뒤에 `of`가 오면 식별자로 취급하여 for-of LHS 검증에서 에러 보고.
        //   단, `for (let of = 1;;)` 같은 경우는 isLetDeclarationStart가 true → 선언 경로.
        //   `kw_of` 뒤에 `=`이 오면 isLetDeclarationStart가 true (keyword + not reserved).
        const is_let_as_identifier = self.current() == .kw_let and !self.is_strict_mode and
            (!self.isLetDeclarationStart() or self.peekNextKind() == .kw_of);

        if ((self.current() == .kw_var or self.current() == .kw_let or self.current() == .kw_const) and !is_let_as_identifier) {
            const init_expr = try self.parseVariableDeclaration();
            self.restoreContext(for_saved);
            self.for_loop_init = saved_for_loop_init;
            // parseVariableDeclaration이 세미콜론을 소비했으면 for(;;)
            // 'in' 또는 'of'가 보이면 for-in/for-of
            if (self.current() == .kw_in or self.current() == .kw_of) {
                self.validateForInOfDeclaration(init_expr);
                if (self.current() == .kw_in) {
                    return self.parseForIn(start, init_expr);
                }
                return self.parseForOf(start, init_expr);
            }
            self.expect(.semicolon); // for 헤더의 첫 번째 세미콜론 (ASI 금지, 7.9.2)
            return self.parseForRest(start, init_expr);
        }

        // for-in/for-of의 variable declaration 검증 (ECMAScript 14.7.5.1)
        // - 단일 바인딩만 허용, initializer 금지
        // - 예외: sloppy mode의 var + for-in은 initializer 허용 (Annex B.3.5)

        // 일반 표현식 init
        const init_expr = try self.parseExpression();
        self.restoreContext(for_saved);
        self.for_loop_init = saved_for_loop_init;
        if (self.current() == .kw_in) {
            _ = self.coverExpressionToAssignmentTarget(init_expr, true);
            return self.parseForIn(start, init_expr);
        }
        if (self.current() == .kw_of) {
            // for (async of [1]) — 'async' 키워드가 for-of의 LHS로 사용되면 에러
            // ECMAScript 14.7.5: [+Await] ForDeclaration에서 async는 금지
            const init_node = self.ast.getNode(init_expr);
            if (init_node.tag == .identifier_reference) {
                const text = self.ast.source[init_node.span.start..init_node.span.end];
                if (std.mem.eql(u8, text, "async")) {
                    self.addError(init_node.span, "'async' is not allowed as identifier in for-of left-hand side");
                }
                // for (let of []) — 'let' 키워드가 for-of의 LHS로 사용되면 에러
                // ECMAScript 14.7.5: [lookahead ≠ let] LeftHandSideExpression of
                if (std.mem.eql(u8, text, "let")) {
                    self.addError(init_node.span, "'let' is not allowed as identifier in for-of left-hand side");
                }
            }
            _ = self.coverExpressionToAssignmentTarget(init_expr, true);
            return self.parseForOf(start, init_expr);
        }
        self.expect(.semicolon); // for 헤더의 첫 번째 세미콜론 (ASI 금지, 7.9.2)
        return self.parseForRest(start, init_expr);
    }

    /// for-in/for-of의 variable declaration을 검증한다.
    /// - 단일 바인딩만 허용 (ECMAScript 14.7.5.1)
    /// - initializer 금지 (for-of는 항상, for-in은 strict + let/const)
    /// - Annex B.3.5: sloppy mode의 var + for-in은 initializer 허용
    fn validateForInOfDeclaration(self: *Parser, init_expr: NodeIndex) void {
        if (init_expr.isNone()) return;
        const init_node = self.ast.getNode(init_expr);
        if (init_node.tag != .variable_declaration) return;

        const extras = self.ast.extra_data.items;
        const kind_flags = extras[init_node.data.extra];
        const list_start = extras[init_node.data.extra + 1];
        const decl_len = extras[init_node.data.extra + 2];

        if (decl_len > 1) {
            self.addError(init_node.span, "only a single variable declaration is allowed in a for-in/for-of statement");
        }
        if (decl_len == 0) return;

        // 첫 번째 declarator의 initializer 체크
        const first_decl: NodeIndex = @enumFromInt(extras[list_start]);
        if (first_decl.isNone()) return;
        const decl_node = self.ast.getNode(first_decl);
        if (decl_node.tag != .variable_declarator) return;

        const decl_init: NodeIndex = @enumFromInt(extras[decl_node.data.extra + 2]);
        if (decl_init.isNone()) return;

        // initializer가 있으면 에러 (예외: sloppy var + for-in)
        const is_var = kind_flags == 0;
        const is_for_in = self.current() == .kw_in;
        if (is_for_in and is_var and !self.is_strict_mode) return; // Annex B.3.5
        self.addError(decl_node.span, "for-in/for-of loop variable declaration may not have an initializer");
    }

    /// for(init; test; update) body — 나머지 파싱
    fn parseForRest(self: *Parser, start: u32, init_expr: NodeIndex) ParseError2!NodeIndex {
        var test_expr = NodeIndex.none;
        if (self.current() != .semicolon) {
            test_expr = try self.parseExpression();
        }
        self.expect(.semicolon); // for 헤더의 두 번째 세미콜론 (ASI 금지, 7.9.2)

        var update_expr = NodeIndex.none;
        if (self.current() != .r_paren) {
            update_expr = try self.parseExpression();
        }
        self.expect(.r_paren);
        const body = try self.parseLoopBody();

        const extra_start = try self.ast.addExtra(@intFromEnum(init_expr));
        _ = try self.ast.addExtra(@intFromEnum(test_expr));
        _ = try self.ast.addExtra(@intFromEnum(update_expr));
        _ = try self.ast.addExtra(@intFromEnum(body));

        return try self.ast.addNode(.{
            .tag = .for_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// for(left in right) body
    fn parseForIn(self: *Parser, start: u32, left: NodeIndex) ParseError2!NodeIndex {
        self.advance(); // skip 'in'
        const right = try self.parseExpression();
        self.expect(.r_paren);
        const body = try self.parseLoopBody();

        return try self.ast.addNode(.{
            .tag = .for_in_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
        });
    }

    /// for(left of right) body
    fn parseForOf(self: *Parser, start: u32, left: NodeIndex) ParseError2!NodeIndex {
        self.advance(); // skip 'of'
        const right = try self.parseAssignmentExpression();
        self.expect(.r_paren);
        const body = try self.parseLoopBody();

        return try self.ast.addNode(.{
            .tag = .for_of_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
        });
    }

    /// break, continue, debugger 등 키워드 + 세미콜론만으로 구성된 단순 문.
    fn parseSimpleStatement(self: *Parser, tag: Tag) ParseError2!NodeIndex {
        const keyword_span = self.currentSpan();
        const start = keyword_span.start;
        self.advance(); // skip break/continue/debugger

        // break/continue 뒤에 줄바꿈 없이 identifier가 오면 label로 소비
        var label = NodeIndex.none;
        if ((tag == .break_statement or tag == .continue_statement) and
            self.current() == .identifier and !self.scanner.token.has_newline_before)
        {
            label = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = self.currentSpan(),
                .data = .{ .string_ref = self.currentSpan() },
            });
            self.advance();
        }

        // continue → label 유무와 관계없이 loop 안에서만 허용
        if (tag == .continue_statement and !self.in_loop) {
            self.addError(keyword_span, "'continue' outside of loop");
        }
        // break → label이 없을 때만 loop 또는 switch 필요
        // label이 있는 break는 labelled statement 안에서 유효 (loop/switch 불필요)
        if (tag == .break_statement and label.isNone() and !self.in_loop and !self.in_switch) {
            self.addError(keyword_span, "'break' outside of loop or switch");
        }

        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{
            .tag = tag,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = label, .flags = 0 } },
        });
    }

    fn parseSwitchStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'switch'
        self.expect(.l_paren);
        const discriminant = try self.parseExpression();
        self.expect(.r_paren);
        self.expect(.l_curly);

        const saved_ctx = self.ctx;
        const saved_in_switch = self.in_switch;
        self.in_switch = true;
        // switch body 안에서는 top-level이 아님 (import/export 금지)
        self.ctx.is_top_level = false;

        const scratch_top = self.saveScratch();
        var has_default = false;
        while (self.current() != .r_curly and self.current() != .eof) {
            // duplicate default 검출 (ECMAScript 14.12.1)
            const is_default = self.current() == .kw_default;
            const default_span = self.currentSpan();
            const case_node = try self.parseSwitchCase();
            if (is_default) {
                if (has_default) {
                    self.addError(default_span, "only one default clause is allowed in a switch statement");
                }
                has_default = true;
            }
            try self.scratch.append(case_node);
        }

        self.restoreContext(saved_ctx);
        self.in_switch = saved_in_switch;

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const cases = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(discriminant));
        _ = try self.ast.addExtra(cases.start);
        _ = try self.ast.addExtra(cases.len);

        return try self.ast.addNode(.{
            .tag = .switch_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseSwitchCase(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        var test_expr = NodeIndex.none;
        if (self.eat(.kw_case)) {
            test_expr = try self.parseExpression();
            self.expect(.colon);
        } else if (self.eat(.kw_default)) {
            self.expect(.colon);
        } else {
            const err_span = self.currentSpan();
            self.addError(err_span, "case or default expected");
            self.advance();
            return try self.ast.addNode(.{ .tag = .invalid, .span = err_span, .data = .{ .none = 0 } });
        }

        // case 본문: 다음 case/default/} 전까지
        const body_top = self.saveScratch();
        while (self.current() != .kw_case and self.current() != .kw_default and
            self.current() != .r_curly and self.current() != .eof)
        {
            const stmt = try self.parseStatement();
            if (!stmt.isNone()) try self.scratch.append(stmt);
        }

        const body = try self.ast.addNodeList(self.scratch.items[body_top..]);
        self.restoreScratch(body_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(test_expr));
        _ = try self.ast.addExtra(body.start);
        _ = try self.ast.addExtra(body.len);

        return try self.ast.addNode(.{
            .tag = .switch_case,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseThrowStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'throw'
        // ECMAScript 14.14: throw [no LineTerminator here] Expression
        if (self.scanner.token.has_newline_before) {
            self.addError(.{ .start = start, .end = self.currentSpan().start }, "no line break is allowed after 'throw'");
        }
        const arg = try self.parseExpression();
        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{
            .tag = .throw_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
    }

    fn parseTryStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'try'

        const block = try self.parseBlockStatement();

        // catch 절 (선택적)
        var handler = NodeIndex.none;
        if (self.current() == .kw_catch) {
            handler = try self.parseCatchClause();
        }

        // finally 절 (선택적)
        var finalizer = NodeIndex.none;
        if (self.eat(.kw_finally)) {
            finalizer = try self.parseBlockStatement();
        }

        // catch도 finally도 없으면 에러
        if (handler.isNone() and finalizer.isNone()) {
            self.addError(.{ .start = start, .end = self.currentSpan().start }, "catch or finally expected");
        }

        return try self.ast.addNode(.{
            .tag = .try_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = block, .b = handler, .c = finalizer } },
        });
    }

    fn parseCatchClause(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'catch'

        // catch 파라미터 (선택적 — ES2019 optional catch binding)
        var param = NodeIndex.none;
        if (self.eat(.l_paren)) {
            param = try self.parseBindingIdentifier();
            self.expect(.r_paren);
        }

        const body = try self.parseBlockStatement();

        return try self.ast.addNode(.{
            .tag = .catch_clause,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = param, .right = body, .flags = 0 } },
        });
    }

    fn parseFunctionDeclaration(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionDeclarationWithFlags(0);
    }

    fn parseFunctionDeclarationWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        // generator: function* name()
        var flags = extra_flags;
        if (self.eat(.star)) {
            flags |= ast_mod.FunctionFlags.is_generator;
        }

        const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
        const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;

        // ECMAScript 14.1: 함수 선언의 BindingIdentifier는 외부 context([?Yield, ?Await])에서 파싱.
        // enterFunctionContext 이전에 이름을 파싱해야 올바른 yield/await 검증이 된다.
        // 예: function* foo() { function yield() {} } — "yield"는 외부(generator) context에서 에러.
        const name = try self.parseBindingIdentifier();

        const saved_ctx = self.enterFunctionContext(is_async, is_generator);

        self.expect(.l_paren);
        self.in_formal_parameters = true;
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
            }
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);
        self.in_formal_parameters = false;

        // TS 리턴 타입 어노테이션
        const return_type = try self.tryParseReturnType();

        self.has_simple_params = self.checkSimpleParams(scratch_top);
        self.checkDuplicateParams(scratch_top);
        const body = try self.parseFunctionBody();

        // retroactive strict mode checks: "use strict" directive가 있으면
        // 함수 이름과 파라미터를 소급 검증 (ECMAScript 14.1.2)
        if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
            self.checkStrictFunctionName(name);
            self.checkStrictParamNames(scratch_top);
        }

        self.restoreFunctionContext(saved_ctx);

        const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(param_list.start);
        _ = try self.ast.addExtra(param_list.len);
        _ = try self.ast.addExtra(@intFromEnum(body));
        _ = try self.ast.addExtra(flags);
        _ = try self.ast.addExtra(@intFromEnum(return_type));

        return try self.ast.addNode(.{
            .tag = .function_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// async function / async arrow를 파싱한다.
    /// async 뒤에 function이 오면 async function declaration,
    /// 그 외는 expression statement로 처리.
    fn parseAsyncStatement(self: *Parser) ParseError2!NodeIndex {
        const peek = self.peekNext();
        // async [no LineTerminator here] function → async function declaration
        if (peek.kind == .kw_function and !peek.has_newline_before) {
            self.advance(); // skip 'async'
            return self.parseFunctionDeclarationWithFlags(ast_mod.FunctionFlags.is_async);
        }
        // async 뒤에 줄바꿈이 있거나 function이 아니면 → expression statement
        return self.parseExpressionStatement();
    }

    /// export default function / function* — 이름이 선택적 (없으면 anonymous)
    /// ECMAScript: HoistableDeclaration[+Default] → function (Params) { Body }
    fn parseFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionDeclarationWithFlagsOptionalName(0);
    }

    /// export default async function / async function* — 이름이 선택적
    fn parseAsyncFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'async'
        return self.parseFunctionDeclarationWithFlagsOptionalName(ast_mod.FunctionFlags.is_async);
    }

    /// parseFunctionDeclarationWithFlags와 동일하지만 이름이 선택적.
    /// export default에서만 사용.
    fn parseFunctionDeclarationWithFlagsOptionalName(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        var flags = extra_flags;
        if (self.eat(.star)) {
            flags |= ast_mod.FunctionFlags.is_generator;
        }

        const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
        const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;

        // 이름은 선택적: identifier가 있으면 외부 context에서 파싱
        const name = if (self.current() == .identifier or
            self.current() == .kw_yield or self.current() == .kw_await or
            self.current() == .escaped_keyword or self.current() == .escaped_strict_reserved)
            try self.parseBindingIdentifier()
        else
            NodeIndex.none;

        const saved_ctx = self.enterFunctionContext(is_async, is_generator);

        self.expect(.l_paren);
        self.in_formal_parameters = true;
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
            }
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);
        self.in_formal_parameters = false;

        const return_type = try self.tryParseReturnType();

        self.has_simple_params = self.checkSimpleParams(scratch_top);
        self.checkDuplicateParams(scratch_top);
        const body = try self.parseFunctionBody();

        // retroactive strict mode checks
        if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
            self.checkStrictFunctionName(name);
            self.checkStrictParamNames(scratch_top);
        }

        self.restoreFunctionContext(saved_ctx);

        const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(param_list.start);
        _ = try self.ast.addExtra(param_list.len);
        _ = try self.ast.addExtra(@intFromEnum(body));
        _ = try self.ast.addExtra(flags);
        _ = try self.ast.addExtra(@intFromEnum(return_type));

        return try self.ast.addNode(.{
            .tag = .function_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseFunctionExpression(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionExpressionWithFlags(0);
    }

    fn parseFunctionExpressionWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        // generator: function* () {}
        var flags: u32 = extra_flags;
        if (self.eat(.star)) {
            flags |= ast_mod.FunctionFlags.is_generator;
        }

        const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
        const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;

        // 함수 컨텍스트 진입 — 이름/파라미터/본문 모두 이 컨텍스트에서 파싱
        const saved_ctx = self.enterFunctionContext(is_async, is_generator);

        var name = NodeIndex.none;
        if (self.current() == .identifier or self.current() == .kw_yield or self.current() == .kw_await) {
            name = try self.parseBindingIdentifier();
        }

        self.expect(.l_paren);
        self.in_formal_parameters = true;
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
            }
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);
        self.in_formal_parameters = false;

        // TS 리턴 타입 어노테이션
        _ = try self.tryParseReturnType();
        self.has_simple_params = self.checkSimpleParams(scratch_top);
        self.checkDuplicateParams(scratch_top);
        const body = try self.parseFunctionBodyExpr();

        // retroactive strict mode checks
        if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
            self.checkStrictFunctionName(name);
            self.checkStrictParamNames(scratch_top);
        }

        self.restoreFunctionContext(saved_ctx);

        const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(param_list.start);
        _ = try self.ast.addExtra(param_list.len);
        _ = try self.ast.addExtra(@intFromEnum(body));
        _ = try self.ast.addExtra(flags);

        return try self.ast.addNode(.{
            .tag = .function_expression,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseClassDeclaration(self: *Parser) ParseError2!NodeIndex {
        return self.parseClassWithDecorators(.class_declaration, .{ .start = 0, .len = 0 });
    }

    fn parseClassExpression(self: *Parser) ParseError2!NodeIndex {
        return self.parseClassWithDecorators(.class_expression, .{ .start = 0, .len = 0 });
    }

    /// class 선언/표현식을 파싱한다.
    /// extra = [name, super_class, body, type_params, implements_start, implements_len, deco_start, deco_len]
    fn parseClassWithDecorators(self: *Parser, tag: Tag, decorators: NodeList) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'class'

        // ECMAScript 10.2.1: "All parts of a ClassDeclaration or a ClassExpression
        // are strict mode code." — 클래스 이름, extends, 본문 모두 strict mode.
        // 이를 통해 yield/let/static 등 strict mode reserved word가 클래스 이름으로
        // 사용되는 것을 금지하고, 본문 내 yield/await 사용도 올바르게 검증한다.
        const saved_strict_mode = self.is_strict_mode;
        self.is_strict_mode = true;

        // 클래스 이름 (선언은 필수, 표현식은 선택)
        // kw_yield/kw_await는 컨텍스트에 따라 식별자로 사용 가능
        var name = NodeIndex.none;
        if (self.current() == .identifier or
            (self.current() == .kw_yield and !self.ctx.in_generator) or
            (self.current() == .kw_await and !self.ctx.in_async and !self.is_module) or
            self.current() == .escaped_keyword or self.current() == .escaped_strict_reserved)
        {
            name = try self.parseBindingIdentifier();
        }

        // TS 제네릭 파라미터: class Foo<T> { }
        var type_params = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_params = try self.parseTsTypeParameterDeclaration();
        }

        // extends 절 (선택)
        var super_class = NodeIndex.none;
        if (self.eat(.kw_extends)) {
            super_class = try self.parseAssignmentExpression();
        }

        // TS implements 절 (선택): class Foo implements Bar, Baz
        if (self.eat(.kw_implements)) {
            _ = try self.parseType();
            while (self.eat(.comma)) {
                _ = try self.parseType();
            }
        }

        // 클래스 본문 — extends 있으면 has_super_class 설정 (super() 허용 판단)
        // 중첩 class에서 외부 has_super_class를 상속하지 않도록 명시적 설정
        const saved_has_super_class = self.has_super_class;
        self.has_super_class = !super_class.isNone();
        const body = try self.parseClassBody();
        self.has_super_class = saved_has_super_class;

        // strict mode 복원 — 클래스 외부의 strict 상태로 되돌림
        self.is_strict_mode = saved_strict_mode;

        const none = @intFromEnum(NodeIndex.none);
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(name),
            @intFromEnum(super_class),
            @intFromEnum(body),
            @intFromEnum(type_params),
            0,                0, // implements (스트리핑 대상이므로 빈 리스트)
            decorators.start, decorators.len,
        });
        _ = none;

        return try self.ast.addNode(.{
            .tag = tag,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseClassBody(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        // class body 안에서는 in_class=true (super 허용 등)
        const saved_in_class = self.in_class;
        self.in_class = true;

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            // 세미콜론 스킵 (클래스 본문에서 허용)
            if (self.current() == .semicolon) {
                self.advance();
                continue;
            }
            const member = try self.parseClassMember();
            if (!member.isNone()) try self.scratch.append(member);
        }

        self.in_class = saved_in_class;

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .class_body,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = members },
        });
    }

    fn parseClassMember(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // 데코레이터 (class member 앞)
        while (self.current() == .at) {
            _ = try self.parseDecorator(); // TODO: 멤버에 연결 (BACKLOG)
        }

        // TS 접근 제어자 (public/private/protected) + readonly + abstract + override
        while (self.current() == .kw_public or self.current() == .kw_private or
            self.current() == .kw_protected or self.current() == .kw_readonly or
            self.current() == .kw_abstract or self.current() == .kw_override or
            self.current() == .kw_declare)
        {
            self.advance(); // skip modifier (스트리핑 대상이므로 AST에 저장 불필요)
        }

        // static 키워드 (선택)
        // static은 멤버 이름으로도 사용 가능: class C { static() {} }
        // static 뒤에 {, (, = 가 오면 이름으로 취급
        var flags: u16 = 0;
        if (self.current() == .kw_static) {
            const next = self.peekNextKind();
            if (next == .l_curly) {
                // static { } — static block
                // static initializer는 자체 arguments 바인딩이 없음.
                // new.target은 허용 (undefined로 평가, ECMAScript 15.7.15)
                self.advance(); // skip 'static'
                const saved_in_static = self.in_static_initializer;
                const saved_new_target = self.allow_new_target;
                const saved_in_function = self.ctx.in_function;
                const saved_in_loop = self.in_loop;
                const saved_in_switch = self.in_switch;
                const saved_in_generator = self.ctx.in_generator;
                const saved_in_async = self.ctx.in_async;
                const saved_super_property = self.allow_super_property;
                self.in_static_initializer = true;
                self.allow_new_target = true;
                self.allow_super_property = true; // static block에서 super.prop 허용 (ECMAScript 15.7.14)
                // static block은 독립 실행 컨텍스트: return/break/continue/yield 금지
                // +Await: await은 binding identifier로 사용 불가 (ECMAScript 15.7.12)
                self.ctx.in_function = false;
                self.in_loop = false;
                self.in_switch = false;
                self.ctx.in_generator = false;
                self.ctx.in_async = true;
                const body = try self.parseBlockStatement();
                self.in_static_initializer = saved_in_static;
                self.allow_new_target = saved_new_target;
                self.ctx.in_function = saved_in_function;
                self.in_loop = saved_in_loop;
                self.in_switch = saved_in_switch;
                self.ctx.in_generator = saved_in_generator;
                self.ctx.in_async = saved_in_async;
                self.allow_super_property = saved_super_property;
                return try self.ast.addNode(.{
                    .tag = .static_block,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = body, .flags = 0 } },
                });
            }
            // static 뒤에 (나 = 가 오면 static은 메서드/프로퍼티 이름
            if (next != .l_paren and next != .eq and next != .semicolon) {
                flags |= 0x01; // static modifier
                self.advance();
            }
        }

        // static 뒤의 TS modifier도 소비 (static readonly x 등)
        while (self.current() == .kw_readonly or self.current() == .kw_abstract or
            self.current() == .kw_override or self.current() == .kw_declare or
            self.current() == .kw_public or self.current() == .kw_private or
            self.current() == .kw_protected)
        {
            self.advance();
        }

        // get/set (선택)
        if (self.current() == .kw_get and self.peekNextKind() != .l_paren) {
            flags |= 0x02; // getter
            self.advance();
        } else if (self.current() == .kw_set and self.peekNextKind() != .l_paren) {
            flags |= 0x04; // setter
            self.advance();
        }

        // async (선택): async [no LineTerminator here] MethodName
        // 스펙: async와 다음 토큰(*/PropertyName) 사이에 줄바꿈이 없어야 함
        if (self.current() == .kw_async and self.peekNextKind() != .l_paren and
            !self.peekNext().has_newline_before)
        {
            flags |= 0x08; // async flag
            self.advance();
        }

        // generator (선택): *method() {}
        if (self.eat(.star)) {
            flags |= 0x10; // generator flag
        }

        // 키
        const key = try self.parsePropertyKey();

        // 제네릭 파라미터: method<T>()
        if (self.current() == .l_angle) {
            _ = try self.parseTsTypeParameterDeclaration();
        }

        // 메서드 (파라미터 리스트가 있으면)
        if (self.current() == .l_paren) {
            // 메서드 파라미터는 자체 arguments 바인딩을 가지므로
            // static initializer/class field의 arguments 제한이 적용되지 않는다.
            const saved_in_static_init = self.in_static_initializer;
            const saved_in_class_field_for_params = self.in_class_field;
            const saved_in_async_for_params = self.ctx.in_async;
            const saved_in_generator_for_params = self.ctx.in_generator;
            const saved_super_prop_for_params = self.allow_super_property;
            self.in_static_initializer = false;
            self.in_class_field = false;
            // 메서드의 파라미터에서 async/generator 컨텍스트 설정
            // 非async/非generator 메서드에서는 await/yield를 식별자로 사용 가능
            self.ctx.in_async = (flags & 0x08) != 0;
            self.ctx.in_generator = (flags & 0x10) != 0;
            // class 메서드의 파라미터에서 super.prop 허용 (ECMAScript 15.7.5)
            self.allow_super_property = true;
            self.expect(.l_paren);
            self.in_formal_parameters = true;
            const param_top = self.saveScratch();
            while (self.current() != .r_paren and self.current() != .eof) {
                const param = try self.parseBindingIdentifier();
                try self.scratch.append(param);
                if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                    self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
                }
                if (!self.eat(.comma)) break;
            }
            self.expect(.r_paren);
            self.in_formal_parameters = false;

            // TS 리턴 타입 어노테이션: (): Type
            _ = try self.tryParseReturnType();

            // static method 'prototype' 금지 (ECMAScript 15.7.1)
            // private method '#constructor' 금지
            if (!key.isNone()) {
                const mk = self.ast.getNode(key);
                const method_name = if (mk.tag == .identifier_reference)
                    self.ast.source[mk.span.start..mk.span.end]
                else if (mk.tag == .string_literal and mk.span.end > mk.span.start + 2)
                    self.ast.source[mk.span.start + 1 .. mk.span.end - 1]
                else
                    @as([]const u8, "");
                if ((flags & 0x01) != 0 and std.mem.eql(u8, method_name, "prototype")) {
                    self.addError(mk.span, "static class method cannot be named 'prototype'");
                }
                // constructor는 일반 method만 가능 — getter/setter/generator/async 금지
                if ((flags & 0x01) == 0 and std.mem.eql(u8, method_name, "constructor")) {
                    // flags: 0x02=getter, 0x04=setter, 0x08=async, 0x10=generator
                    if ((flags & 0x1E) != 0) {
                        self.addError(mk.span, "class constructor cannot be a getter, setter, generator, or async");
                    }
                }
                // private name '#constructor' 금지
                if (mk.tag == .private_identifier) {
                    const pn = self.ast.source[mk.span.start..mk.span.end];
                    if (std.mem.eql(u8, pn, "#constructor")) {
                        self.addError(mk.span, "class member cannot be named '#constructor'");
                    }
                }
            }

            // 바디: abstract 메서드는 바디 없음 (세미콜론으로 끝남)
            // 메서드도 함수이므로 컨텍스트 설정
            var body = NodeIndex.none;
            if (self.current() == .l_curly) {
                // 메서드의 async/generator 플래그는 함수와 비트 위치가 다름 (0x08/0x10)
                const saved_ctx = self.enterFunctionContext((flags & 0x08) != 0, (flags & 0x10) != 0);
                // class 메서드는 super.prop 허용 (ECMAScript 12.3.7)
                self.allow_super_property = true;
                // constructor에서는 super() 호출도 허용
                if (!key.isNone() and (flags & 0x01) == 0) { // non-static
                    const mk = self.ast.getNode(key);
                    const kt = if (mk.tag == .identifier_reference)
                        self.ast.source[mk.span.start..mk.span.end]
                    else if (mk.tag == .string_literal and mk.span.end > mk.span.start + 2)
                        self.ast.source[mk.span.start + 1 .. mk.span.end - 1]
                    else
                        @as([]const u8, "");
                    if (std.mem.eql(u8, kt, "constructor")) {
                        // extends가 있는 class의 constructor에서만 super() 허용
                        if (self.has_super_class) {
                            self.allow_super_call = true;
                        }
                    }
                }
                self.has_simple_params = self.checkSimpleParams(param_top);
                self.checkDuplicateParams(param_top);
                body = try self.parseFunctionBodyExpr();
                self.restoreFunctionContext(saved_ctx);
            } else {
                _ = self.eat(.semicolon);
            }
            // 파라미터 전에 변경한 플래그 복원 (if/else 양쪽 공통)
            // restoreFunctionContext는 enterFunctionContext 시점의 (이미 false인) 값을
            // 복원하므로, 여기서 원래 값으로 다시 복원해야 한다.
            self.in_static_initializer = saved_in_static_init;
            self.in_class_field = saved_in_class_field_for_params;
            self.ctx.in_async = saved_in_async_for_params;
            self.ctx.in_generator = saved_in_generator_for_params;
            self.allow_super_property = saved_super_prop_for_params;
            const param_list = try self.ast.addNodeList(self.scratch.items[param_top..]);
            self.restoreScratch(param_top);

            const extra_start = try self.ast.addExtra(@intFromEnum(key));
            _ = try self.ast.addExtra(param_list.start);
            _ = try self.ast.addExtra(param_list.len);
            _ = try self.ast.addExtra(@intFromEnum(body));

            _ = try self.ast.addExtra(flags);

            return try self.ast.addNode(.{
                .tag = .method_definition,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra_start },
            });
        }

        // class field 이름 검증 (ECMAScript 15.7.1)
        if (!key.isNone()) {
            const key_node = self.ast.getNode(key);
            // identifier 또는 string literal 키에서 이름 추출
            const key_text = if (key_node.tag == .identifier_reference)
                self.ast.source[key_node.span.start..key_node.span.end]
            else if (key_node.tag == .string_literal and key_node.span.end > key_node.span.start + 2)
                self.ast.source[key_node.span.start + 1 .. key_node.span.end - 1] // 따옴표 제거
            else
                @as([]const u8, "");

            if (key_text.len > 0) {
                // class field 이름 'constructor' 금지 — static/non-static 모두 (ECMAScript 15.7.1)
                if (std.mem.eql(u8, key_text, "constructor")) {
                    self.addError(key_node.span, "class field cannot be named 'constructor'");
                }
                if ((flags & 0x01) != 0 and std.mem.eql(u8, key_text, "prototype")) {
                    self.addError(key_node.span, "static class field cannot be named 'prototype'");
                }
            }
            // private field '#constructor' 금지
            if (key_node.tag == .private_identifier) {
                const pn = self.ast.source[key_node.span.start..key_node.span.end];
                if (std.mem.eql(u8, pn, "#constructor")) {
                    self.addError(key_node.span, "class member cannot be named '#constructor'");
                }
            }
        }

        // TS 타입 어노테이션: value: Type
        _ = try self.tryParseTypeAnnotation();

        // 프로퍼티 (= 이니셜라이저) — class field에서 arguments 사용 금지
        var init_val = NodeIndex.none;
        if (self.eat(.eq)) {
            const saved_in_class_field = self.in_class_field;
            const saved_new_target = self.allow_new_target;
            self.in_class_field = true;
            self.allow_new_target = true; // class field에서 new.target 허용 (ECMAScript 15.7.15)
            init_val = try self.parseAssignmentExpression();
            self.in_class_field = saved_in_class_field;
            self.allow_new_target = saved_new_target;
        }
        // class field 끝에서 ASI 규칙 적용: 같은 줄에 다른 멤버가 오면 에러
        self.expectSemicolon();

        return try self.ast.addNode(.{
            .tag = .property_definition,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = init_val, .flags = flags } },
        });
    }

    const PeekResult = struct { kind: Kind, has_newline_before: bool };

    /// 스캐너 상태를 저장한다. lookahead 후 restoreState로 되돌릴 때 사용.
    const ScannerState = struct {
        current: u32,
        start: u32,
        token: Token,
        line: u32,
        line_start: u32,
        brace_depth: u32,
        prev_token_kind: Kind,
        template_depth_len: usize,
    };

    fn saveState(self: *const Parser) ScannerState {
        return .{
            .current = self.scanner.current,
            .start = self.scanner.start,
            .token = self.scanner.token,
            .line = self.scanner.line,
            .line_start = self.scanner.line_start,
            .brace_depth = self.scanner.brace_depth,
            .prev_token_kind = self.scanner.prev_token_kind,
            .template_depth_len = self.scanner.template_depth_stack.items.len,
        };
    }

    fn restoreState(self: *Parser, s: ScannerState) void {
        self.scanner.current = s.current;
        self.scanner.start = s.start;
        self.scanner.token = s.token;
        self.scanner.line = s.line;
        self.scanner.line_start = s.line_start;
        self.scanner.brace_depth = s.brace_depth;
        self.scanner.prev_token_kind = s.prev_token_kind;
        // template_depth_stack은 lookahead 중 push(grow) 또는 pop(shrink) 가능.
        // pop으로 줄어든 경우 saved 길이가 현재보다 크지만, capacity 내이므로
        // items.len 직접 설정으로 안전하게 복구할 수 있다.
        if (s.template_depth_len <= self.scanner.template_depth_stack.items.len) {
            self.scanner.template_depth_stack.shrinkRetainingCapacity(s.template_depth_len);
        } else {
            self.scanner.template_depth_stack.items.len = s.template_depth_len;
        }
    }

    /// 다음 토큰의 Kind와 줄바꿈 여부를 미리 본다 (현재 토큰을 소비하지 않음).
    fn peekNext(self: *Parser) PeekResult {
        const saved = self.saveState();

        self.scanner.next();
        const result = PeekResult{
            .kind = self.scanner.token.kind,
            .has_newline_before = self.scanner.token.has_newline_before,
        };

        self.restoreState(saved);
        return result;
    }

    /// peekNext의 Kind만 반환하는 편의 함수.
    fn peekNextKind(self: *Parser) Kind {
        return self.peekNext().kind;
    }

    /// JSX element 모드에서 다음 토큰의 Kind를 미리 본다 (현재 토큰을 소비하지 않음).
    /// JSX children 파싱 중 '<' 다음이 '/'인지 판별할 때 사용.
    /// normal 모드에서는 '/'가 regex로 해석될 수 있으므로 JSX 전용 peek이 필요하다.
    fn peekNextKindJSX(self: *Parser) Kind {
        const saved = self.saveState();
        self.scanner.nextInsideJSXElement();
        const peek_kind = self.scanner.token.kind;
        self.restoreState(saved);
        return peek_kind;
    }

    // ================================================================
    // Import / Export 파싱
    // ================================================================

    /// import() / import.source() / import.defer() 호출의 인자를 파싱한다.
    /// `(` 를 소비하고, 1~2개 인자를 파싱하고, `)` 를 기대한다.
    /// import() 내부에서는 `in` 연산자를 허용 (+In context).
    fn parseImportCallArgs(self: *Parser, start: u32) ParseError2!NodeIndex {
        self.expect(.l_paren);
        const saved_ctx = self.enterAllowInContext(true);
        defer self.restoreContext(saved_ctx);
        const arg = try self.parseAssignmentExpression();
        // 두 번째 인자 (import attributes/options) — 있으면 파싱하고 무시
        if (self.eat(.comma)) {
            if (self.current() != .r_paren) {
                _ = try self.parseAssignmentExpression();
                _ = self.eat(.comma); // trailing comma
            }
        }
        self.expect(.r_paren);
        return try self.ast.addNode(.{
            .tag = .import_expression,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
    }

    fn parseImportDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // ECMAScript 15.2: import 선언은 module의 top-level에서만 허용
        if (!self.is_module) {
            self.addError(self.currentSpan(), "'import' declaration is only allowed in module code");
        } else if (!self.ctx.is_top_level) {
            self.addError(self.currentSpan(), "'import' declaration must be at the top level");
        }
        self.advance(); // skip 'import'

        // import defer / import source — Stage 3 proposals
        // defer/source를 스킵하고 나머지는 일반 import로 처리
        var has_phase_modifier = false;
        if (self.current() == .kw_defer or
            (self.current() == .identifier and
                std.mem.eql(u8, self.ast.source[self.currentSpan().start..self.currentSpan().end], "source")))
        {
            has_phase_modifier = true;
            self.advance(); // skip defer/source
        }

        // import "module" — side-effect import
        if (self.current() == .string_literal) {
            if (has_phase_modifier) {
                self.addError(self.currentSpan(), "'import defer/source' requires a binding");
            }
            const source_node = try self.parseModuleSource();
            _ = self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .import_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = source_node, .flags = 1 } }, // flags=1: side-effect import
            });
        }

        // import(...) — dynamic import는 expression. expression statement로 파싱.
        if (self.current() == .l_paren) {
            // import 키워드는 이미 advance()됨. parsePrimaryExpression에 위임하기 위해
            // 수동으로 import expression 생성.
            self.expect(.l_paren);
            const arg = try self.parseAssignmentExpression();
            self.expect(.r_paren);
            const import_expr = try self.ast.addNode(.{
                .tag = .import_expression,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
            });
            // 후속 .then() 등의 member/call 체이닝 처리
            _ = self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .expression_statement,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = import_expr, .flags = 0 } },
            });
        }

        // 스펙ifier 파싱
        const scratch_top = self.saveScratch();

        // default import: import foo from "module"
        var has_default = false;
        if (self.current() == .identifier) {
            const next = self.peekNextKind();
            if (next == .comma or next == .kw_from) {
                const spec_span = self.currentSpan();
                self.advance();
                const spec = try self.ast.addNode(.{
                    .tag = .import_default_specifier,
                    .span = spec_span,
                    .data = .{ .string_ref = spec_span },
                });
                try self.scratch.append(spec);
                has_default = true;

                if (self.eat(.comma)) {
                    // import default, { ... } from "module"
                    // import default, * as ns from "module"
                } else {
                    // import default from "module"
                    self.expect(.kw_from);
                    const source_node = try self.parseModuleSource();
                    _ = self.eat(.semicolon);

                    const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    self.restoreScratch(scratch_top);
                    const extra_start = try self.ast.addExtra(specifiers.start);
                    _ = try self.ast.addExtra(specifiers.len);
                    _ = try self.ast.addExtra(@intFromEnum(source_node));

                    return try self.ast.addNode(.{
                        .tag = .import_declaration,
                        .span = .{ .start = start, .end = self.currentSpan().start },
                        .data = .{ .extra = extra_start },
                    });
                }
            }
        }

        // namespace import: import * as ns from "module"
        if (self.current() == .star) {
            self.advance(); // skip *
            self.expect(.kw_as);
            const local_span = self.currentSpan();
            self.expect(.identifier);
            const spec = try self.ast.addNode(.{
                .tag = .import_namespace_specifier,
                .span = local_span,
                .data = .{ .string_ref = local_span },
            });
            try self.scratch.append(spec);
        }

        // named imports: import { a, b as c } from "module"
        if (self.current() == .l_curly) {
            self.advance(); // skip {
            while (self.current() != .r_curly and self.current() != .eof) {
                const spec = try self.parseImportSpecifier();
                try self.scratch.append(spec);
                if (!self.eat(.comma)) break;
            }
            self.expect(.r_curly);
        }

        self.expect(.kw_from);
        const source_node = try self.parseModuleSource();
        _ = self.eat(.semicolon);

        const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(specifiers.start);
        _ = try self.ast.addExtra(specifiers.len);
        _ = try self.ast.addExtra(@intFromEnum(source_node));

        return try self.ast.addNode(.{
            .tag = .import_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseImportSpecifier(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // imported name — ModuleExportName (identifier or string literal)
        const imported = try self.parseModuleExportName();

        // string literal import 시 반드시 `as` 바인딩 필요:
        // import { "☿" as Ami } from ... (OK)
        // import { "☿" } from ... (Error — string cannot be used as binding)
        var local = imported;
        if (self.eat(.kw_as)) {
            // `as` 뒤는 반드시 BindingIdentifier (string literal 불가)
            local = try self.parseIdentifierName();
        } else if (!imported.isNone() and @intFromEnum(imported) < self.ast.nodes.items.len and
            self.ast.getNode(imported).tag == .string_literal)
        {
            // string literal without `as` — binding 이름이 없으므로 에러
            self.addError(self.ast.getNode(imported).span, "string literal in import specifier requires 'as' binding");
        }

        return try self.ast.addNode(.{
            .tag = .import_specifier,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = imported, .right = local, .flags = 0 } },
        });
    }

    fn parseExportDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // ECMAScript 15.2: export 선언은 module의 top-level에서만 허용
        if (!self.is_module) {
            self.addError(self.currentSpan(), "'export' declaration is only allowed in module code");
        } else if (!self.ctx.is_top_level) {
            self.addError(self.currentSpan(), "'export' declaration must be at the top level");
        }
        self.advance(); // skip 'export'

        // export default
        if (self.eat(.kw_default)) {
            const decl = switch (self.current()) {
                // export default function / export default function* — 이름 선택적
                .kw_function => blk: {
                    const fn_decl = try self.parseFunctionDeclarationDefaultExport();
                    // anonymous function declaration은 호출 불가 (IIFE가 아님)
                    // export default function() {}() → SyntaxError
                    if (self.current() == .l_paren) {
                        self.addError(self.currentSpan(), "anonymous function declaration cannot be invoked");
                    }
                    break :blk fn_decl;
                },
                .kw_class => try self.parseClassDeclaration(),
                else => blk: {
                    // export default async function / export default async function* — 이름 선택적
                    if (self.current() == .kw_async) {
                        const peek = self.peekNext();
                        if (peek.kind == .kw_function and !peek.has_newline_before) {
                            const fn_decl = try self.parseAsyncFunctionDeclarationDefaultExport();
                            if (self.current() == .l_paren) {
                                self.addError(self.currentSpan(), "anonymous function declaration cannot be invoked");
                            }
                            break :blk fn_decl;
                        }
                    }
                    const expr = try self.parseAssignmentExpression();
                    self.expectSemicolon();
                    break :blk expr;
                },
            };
            return try self.ast.addNode(.{
                .tag = .export_default_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = decl, .flags = 0 } },
            });
        }

        // export * from "module" / export * as ns from "module"
        if (self.current() == .star) {
            self.advance(); // skip *
            var exported_name = NodeIndex.none;
            if (self.eat(.kw_as)) {
                exported_name = try self.parseModuleExportName();
            }
            self.expect(.kw_from);
            const source_node = try self.parseModuleSource();
            self.expectSemicolon();

            return try self.ast.addNode(.{
                .tag = .export_all_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = exported_name, .right = source_node, .flags = 0 } },
            });
        }

        // export { a, b } / export { a } from "module"
        if (self.current() == .l_curly) {
            self.advance(); // skip {

            const scratch_top = self.saveScratch();
            while (self.current() != .r_curly and self.current() != .eof) {
                const spec = try self.parseExportSpecifier();
                try self.scratch.append(spec);
                if (!self.eat(.comma)) break;
            }
            self.expect(.r_curly);

            // re-export: export { a } from "module"
            var source_node = NodeIndex.none;
            if (self.eat(.kw_from)) {
                source_node = try self.parseModuleSource();
            }
            self.expectSemicolon();

            // export NamedExports ; (without `from`) →
            // local 이름에 string literal 사용 불가
            // (ECMAScript: ReferencedBindings에 StringLiteral이 있으면 SyntaxError)
            if (source_node.isNone()) {
                for (self.scratch.items[scratch_top..]) |spec_idx| {
                    if (spec_idx.isNone()) continue;
                    if (@intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
                    const spec_node = self.ast.getNode(spec_idx);
                    if (spec_node.tag == .export_specifier) {
                        const local_idx = spec_node.data.binary.left;
                        if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                            const local_node = self.ast.getNode(local_idx);
                            if (local_node.tag == .string_literal) {
                                self.addError(local_node.span, "string literal cannot be used as local binding in export");
                            }
                        }
                    }
                }
            }

            const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            self.restoreScratch(scratch_top);

            // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
            const extra_start = try self.ast.addExtras(&.{
                @intFromEnum(NodeIndex.none), // declaration 없음
                specifiers.start,
                specifiers.len,
                @intFromEnum(source_node),
            });

            return try self.ast.addNode(.{
                .tag = .export_named_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra_start },
            });
        }

        // export var/let/const/function/class
        // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
        const decl = try self.parseStatement();
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(decl),
            0, // specifiers_start (사용 안 함)
            0, // specifiers_len = 0
            @intFromEnum(NodeIndex.none), // source 없음
        });
        return try self.ast.addNode(.{
            .tag = .export_named_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseExportSpecifier(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        const local = try self.parseModuleExportName();

        var exported = local;
        if (self.eat(.kw_as)) {
            exported = try self.parseModuleExportName();
        }

        return try self.ast.addNode(.{
            .tag = .export_specifier,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = local, .right = exported, .flags = 0 } },
        });
    }

    fn parseModuleSource(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .string_literal) {
            self.advance();
            // import attributes: with { type: 'json' } 또는 assert { type: 'json' }
            self.skipImportAttributes();
            return try self.ast.addNode(.{
                .tag = .string_literal,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "module source string expected");
        return NodeIndex.none;
    }

    /// import attributes (with/assert { ... })를 파싱한다.
    /// AST에 저장하지 않고 소비만 한다 (트랜스포머에서 필요 시 추가).
    /// 중복 키 검사도 수행한다 (ECMAScript: WithClauseToAttributes 중복 에러).
    fn skipImportAttributes(self: *Parser) void {
        // with { ... }: 줄바꿈 허용 (ECMAScript: AttributesKeyword = with)
        // assert { ... }: 줄바꿈 불허 (ECMAScript: [no LineTerminator here] assert)
        const is_with = self.current() == .kw_with;
        const is_assert = self.current() == .kw_assert and !self.scanner.token.has_newline_before;
        if (!is_with and !is_assert) return;

        self.advance(); // skip with/assert
        if (self.current() == .l_curly) {
            self.advance(); // skip {

            // 중복 키 검사를 위한 키 수집 (최대 16개, 초과 시 검사 생략)
            var keys: [16][]const u8 = undefined;
            var key_spans: [16]Span = undefined;
            var key_count: usize = 0;

            while (self.current() != .r_curly and self.current() != .eof) {
                // key: identifier 또는 string literal
                const key_span = self.currentSpan();
                const key_text = self.ast.source[key_span.start..key_span.end];
                self.advance(); // key

                // 중복 키 검사
                if (key_count < 16) {
                    // 키 값 결정: string literal은 따옴표 제거 후 escape 해석
                    var decoded_buf: [256]u8 = undefined;
                    const effective_key = if (key_text.len >= 2 and (key_text[0] == '\'' or key_text[0] == '"'))
                        decodeStringKey(key_text[1 .. key_text.len - 1], &decoded_buf)
                    else
                        key_text;

                    for (0..key_count) |i| {
                        if (std.mem.eql(u8, keys[i], effective_key)) {
                            self.addError(key_span, "duplicate import attribute key");
                            break;
                        }
                    }
                    keys[key_count] = effective_key;
                    key_spans[key_count] = key_span;
                    key_count += 1;
                }

                _ = self.eat(.colon);
                if (self.current() != .r_curly and self.current() != .eof) {
                    self.advance(); // value
                }
                _ = self.eat(.comma);
            }
            _ = self.eat(.r_curly);
        }
    }

    /// import attribute 키의 unicode escape를 해석한다.
    /// 예: "typ\u0065" → "type"
    /// buf에 결과를 쓰고, escape가 없으면 원본 슬라이스를 반환.
    fn decodeStringKey(input: []const u8, buf: *[256]u8) []const u8 {
        // escape가 없으면 원본 그대로 반환 (빠른 경로)
        if (std.mem.indexOf(u8, input, "\\") == null) return input;

        var out: usize = 0;
        var i: usize = 0;
        while (i < input.len and out < 256) {
            if (input[i] == '\\' and i + 1 < input.len) {
                if (input[i + 1] == 'u') {
                    // \uHHHH
                    if (i + 5 < input.len) {
                        i += 2; // skip \u
                        var codepoint: u21 = 0;
                        var valid = true;
                        for (0..4) |_| {
                            if (i >= input.len) {
                                valid = false;
                                break;
                            }
                            const c = input[i];
                            const digit: u21 = if (c >= '0' and c <= '9')
                                c - '0'
                            else if (c >= 'a' and c <= 'f')
                                c - 'a' + 10
                            else if (c >= 'A' and c <= 'F')
                                c - 'A' + 10
                            else {
                                valid = false;
                                break;
                            };
                            codepoint = codepoint * 16 + digit;
                            i += 1;
                        }
                        if (valid and codepoint < 128 and out < 256) {
                            buf[out] = @intCast(codepoint);
                            out += 1;
                        }
                        continue;
                    }
                }
                // 기타 escape: 그대로 복사
                if (out < 256) {
                    buf[out] = input[i + 1];
                    out += 1;
                }
                i += 2;
            } else {
                if (out < 256) {
                    buf[out] = input[i];
                    out += 1;
                }
                i += 1;
            }
        }
        return buf[0..out];
    }

    // ================================================================
    // Expression 파싱 (Pratt parser / precedence climbing)
    // ================================================================

    /// 콤마 연산자(sequence expression)를 포함한 최상위 표현식 파싱.
    /// ECMAScript: Expression = AssignmentExpression (',' AssignmentExpression)*
    /// 콤마가 없으면 단일 AssignmentExpression을 그대로 반환하고,
    /// 콤마가 있으면 sequence_expression 노드로 감싼다.
    /// parseExpression과 동일하지만 `...`(rest) 요소도 허용한다.
    /// arrow function 파라미터의 cover grammar: `(a, ...b) => {}`.
    /// 일반 expression 위치에서 `...`는 invalid이지만, arrow 파라미터로 재해석될 수 있으므로
    /// 여기서 parseSpreadOrAssignment을 사용하여 spread_element 노드를 생성한다.
    fn parseExpressionOrRest(self: *Parser) ParseError2!NodeIndex {
        const first = try self.parseSpreadOrAssignment();

        if (self.current() != .comma) return first;

        const scratch_top = self.saveScratch();
        try self.scratch.append(first);
        var had_trailing_comma = false;
        while (self.eat(.comma)) {
            if (self.current() == .r_paren) {
                had_trailing_comma = true;
                break;
            }
            const elem = try self.parseSpreadOrAssignment();
            try self.scratch.append(elem);
        }
        // rest element 뒤 trailing comma 감지: (...a,) → SyntaxError
        // 마지막 요소가 spread이고 while이 trailing comma 때문에 break했으면 플래그 설정
        if (had_trailing_comma) {
            const items = self.scratch.items[scratch_top..];
            if (items.len > 0) {
                const last_idx = items[items.len - 1];
                if (!last_idx.isNone() and self.ast.getNode(last_idx).tag == .spread_element) {
                    self.ast.nodes.items[@intFromEnum(last_idx)].data = .{
                        .unary = .{ .operand = self.ast.getNode(last_idx).data.unary.operand, .flags = spread_trailing_comma },
                    };
                }
            }
        }
        const first_span = self.ast.getNode(first).span;
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        return try self.ast.addNode(.{
            .tag = .sequence_expression,
            .span = .{ .start = first_span.start, .end = self.currentSpan().start },
            .data = .{ .list = list },
        });
    }

    fn parseExpression(self: *Parser) ParseError2!NodeIndex {
        const first = try self.parseAssignmentExpression();

        // 콤마가 없으면 단순 표현식
        if (self.current() != .comma) return first;

        // 콤마 연산자 → sequence expression
        const scratch_top = self.saveScratch();
        try self.scratch.append(first);
        while (self.eat(.comma)) {
            // trailing comma: 콤마 뒤에 )가 오면 arrow function 파라미터 trailing comma
            if (self.current() == .r_paren) break;
            const elem = try self.parseAssignmentExpression();
            try self.scratch.append(elem);
        }
        const first_span = self.ast.getNode(first).span;
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        return try self.ast.addNode(.{
            .tag = .sequence_expression,
            .span = .{ .start = first_span.start, .end = self.currentSpan().start },
            .data = .{ .list = list },
        });
    }

    /// arrow function의 body를 파싱한다.
    /// arrow function은 함수이므로 in_function=true, loop/switch 리셋.
    /// block body면 parseFunctionBody(), expression body면 parseAssignmentExpression().
    fn parseArrowBody(self: *Parser, is_async: bool, param_idx: NodeIndex) ParseError2!NodeIndex {
        // arrow function은 generator가 될 수 없으므로 is_generator=false
        const saved_ctx = self.enterFunctionContext(is_async, false);
        // arrow function은 자체 바인딩이 없으므로 외부 컨텍스트를 상속:
        // - in_class_field: arguments 사용 제한 (arrow에는 자체 arguments 없음)
        // - allow_new_target: new.target 허용 여부 (global arrow에서는 false)
        // - allow_super_call/allow_super_property: super 접근 허용 여부 (메서드 내 arrow에서 super 사용)
        // 주의: in_static_initializer는 상속하지 않음 — arrow 내에서 await은 식별자로 사용 가능
        // (ECMAScript ContainsAwait이 ArrowFunction을 면제)
        self.in_class_field = saved_ctx.in_class_field;
        self.allow_new_target = saved_ctx.allow_new_target;
        self.allow_super_call = saved_ctx.allow_super_call;
        self.allow_super_property = saved_ctx.allow_super_property;
        // ECMAScript 14.2.1: non-simple params + "use strict" body → SyntaxError
        // cover grammar에서 파라미터가 simple인지 확인하여 parseFunctionBody에서 검증.
        self.has_simple_params = self.isSimpleArrowParams(param_idx);
        const body = if (self.current() == .l_curly)
            try self.parseFunctionBodyExpr()
        else
            try self.parseAssignmentExpression();
        self.restoreFunctionContext(saved_ctx);
        return body;
    }

    fn parseAssignmentExpression(self: *Parser) ParseError2!NodeIndex {
        // async arrow function 감지 (2가지 형태)
        if (self.current() == .kw_async) {
            const async_span = self.currentSpan();
            const peek = self.peekNext();

            if (!peek.has_newline_before) {
                // 형태 1: async x => body (단순 식별자)
                if (peek.kind == .identifier or (peek.kind.isKeyword() and !peek.kind.isReservedKeyword())) {
                    const saved = self.saveState();
                    self.advance(); // skip 'async'
                    const id_span = self.currentSpan();
                    self.advance(); // skip identifier
                    if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                        // ECMAScript 14.2.1: strict mode에서 eval/arguments를 arrow 파라미터로 사용 금지
                        self.checkStrictBinding(id_span);
                        self.advance(); // skip =>
                        const param = try self.ast.addNode(.{
                            .tag = .binding_identifier,
                            .span = id_span,
                            .data = .{ .string_ref = id_span },
                        });
                        const body = try self.parseArrowBody(true, param);
                        return try self.ast.addNode(.{
                            .tag = .arrow_function_expression,
                            .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = param, .right = body, .flags = 0x01 } },
                        });
                    }
                    self.restoreState(saved);
                }

                // 형태 2: async (...) => body (괄호 형태)
                // async () => {} — 빈 파라미터도 포함
                if (peek.kind == .l_paren) {
                    const saved = self.saveState();
                    self.advance(); // skip 'async'

                    // () 빈 파라미터 체크
                    if (self.current() == .l_paren and self.peekNextKind() == .r_paren) {
                        self.advance(); // skip (
                        self.advance(); // skip )
                        if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                            self.advance(); // skip =>
                            const body = try self.parseArrowBody(true, .none);
                            return try self.ast.addNode(.{
                                .tag = .arrow_function_expression,
                                .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                                .data = .{ .binary = .{ .left = .none, .right = body, .flags = 0x01 } },
                            });
                        }
                        self.restoreState(saved);
                    } else {
                        // 괄호를 expression으로 파싱 (parenthesized_expression)
                        const params_expr = try self.parseConditionalExpression();
                        if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                            self.coverExpressionToArrowParams(params_expr);
                            // async arrow: 파라미터에 'await' 식별자 사용 금지
                            self.checkAsyncArrowParamsForAwait(params_expr);
                            self.advance(); // skip =>
                            const body = try self.parseArrowBody(true, params_expr);
                            return try self.ast.addNode(.{
                                .tag = .arrow_function_expression,
                                .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                                .data = .{ .binary = .{ .left = params_expr, .right = body, .flags = 0x01 } },
                            });
                        }
                        self.restoreState(saved);
                    }
                }
            }
        }

        // 단일 식별자 + => → arrow function (간단한 형태: x => x + 1)
        if (self.current() == .identifier) {
            const id_span = self.currentSpan();
            const saved = self.saveState();

            self.advance(); // skip identifier
            if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                // identifier => body
                // ECMAScript 14.2.1: strict mode에서 eval/arguments를 arrow 파라미터로 사용 금지
                self.checkStrictBinding(id_span);
                self.advance(); // skip =>
                const param = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = id_span,
                    .data = .{ .string_ref = id_span },
                });
                const body = try self.parseArrowBody(false, param);

                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = id_span.start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = param, .right = body, .flags = 0 } },
                });
            }

            // arrow가 아님 → 되돌리기
            self.restoreState(saved);
        }

        // () => body — 빈 파라미터 arrow function
        if (self.current() == .l_paren and self.peekNextKind() == .r_paren) {
            const arrow_start = self.currentSpan().start;
            const saved = self.saveState();
            self.advance(); // skip (
            self.advance(); // skip )
            if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                self.advance(); // skip =>
                const body = try self.parseArrowBody(false, .none);
                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = arrow_start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = .none, .right = body, .flags = 0 } },
                });
            }
            self.restoreState(saved);
        }

        // yield expression — AssignmentExpression 레벨에서만 유효 (ECMAScript 14.4)
        // UnaryExpression 위치에서는 yield가 IdentifierReference로 해석되어야 함
        if (self.current() == .kw_yield and self.ctx.in_generator) {
            // formal parameter 안에서 yield expression 금지 (ECMAScript 14.1.2)
            if (self.in_formal_parameters) {
                self.addError(self.currentSpan(), "'yield' expression is not allowed in formal parameters");
            }
            const yield_start = self.currentSpan().start;
            self.advance();
            // yield* delegate — * 전에 줄바꿈이 있으면 delegate 아님
            var yield_flags: u16 = 0;
            if (!self.scanner.token.has_newline_before and self.eat(.star)) {
                yield_flags = 1; // delegate
            }
            var operand = NodeIndex.none;
            // yield 뒤에 줄바꿈 없이 expression이 오면 yield의 인자
            // 뒤따르는 토큰이 expression 시작이 아니면 bare yield (operand 없음)
            if (!self.scanner.token.has_newline_before and
                self.current() != .semicolon and self.current() != .r_curly and
                self.current() != .r_paren and self.current() != .r_bracket and
                self.current() != .colon and self.current() != .comma and
                self.current() != .kw_in and self.current() != .kw_of and
                self.current() != .template_middle and self.current() != .template_tail and
                self.current() != .eof)
            {
                // yield 뒤의 /는 regexp로 재스캔 (division이 아님)
                // yield의 RHS에서 /abc/i 같은 regexp가 올 수 있다
                if (self.current() == .slash or self.current() == .slash_eq) {
                    self.scanner.rescanAsRegexp();
                }
                operand = try self.parseAssignmentExpression();
            }
            return try self.ast.addNode(.{
                .tag = .yield_expression,
                .span = .{ .start = yield_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = operand, .flags = yield_flags } },
            });
        }

        const left = try self.parseConditionalExpression();

        // => 를 만나면 arrow function (괄호 형태)
        // left가 parenthesized_expression이면 파라미터 리스트로 취급
        // ECMAScript 14.2: [no LineTerminator here] => ConciseBody
        // call_expression 등은 arrow 파라미터가 될 수 없음 (e.g., async() => {})
        if (self.current() == .arrow and !self.scanner.token.has_newline_before and
            self.isValidArrowParamForm(left))
        {
            // arrow 파라미터 cover grammar 검증 (ECMAScript: ArrowFormalParameters)
            self.coverExpressionToArrowParams(left);
            const left_start = self.ast.getNode(left).span.start;
            self.advance(); // skip =>
            const body = try self.parseArrowBody(false, left);

            return try self.ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = body, .flags = 0 } },
            });
        }

        if (self.current().isAssignment()) {
            // cover grammar: expression → assignment target 검증 (ECMAScript 13.15.1)
            // 구조적 유효성 + rest-init + escaped keyword + strict eval/arguments를 단일 walk로 검증
            _ = self.coverExpressionToAssignmentTarget(left, true);
            const left_start = self.ast.getNode(left).span.start;
            const flags: u16 = @intFromEnum(self.current());
            self.advance();
            const right = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = flags } },
            });
        }

        return left;
    }

    fn parseConditionalExpression(self: *Parser) ParseError2!NodeIndex {
        const expr = try self.parseBinaryExpression(0);

        if (self.eat(.question)) {
            const expr_start = self.ast.getNode(expr).span.start;
            // ECMAScript: ConditionalExpression[In] →
            //   ... ? AssignmentExpression[+In] : AssignmentExpression[?In]
            // consequent는 항상 `in` 허용, alternate는 외부 context 유지
            const cond_saved = self.enterAllowInContext(true);
            const consequent = try self.parseAssignmentExpression();
            self.restoreContext(cond_saved); // alternate는 원래 context로 복원
            self.expect(.colon);
            const alternate = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .ternary = .{ .a = expr, .b = consequent, .c = alternate } },
            });
        }

        return expr;
    }

    /// 이항 연산자를 precedence climbing으로 파싱.
    fn parseBinaryExpression(self: *Parser, min_prec: u8) ParseError2!NodeIndex {
        var left = try self.parseUnaryExpression();

        // ?? 와 &&/|| 혼합 감지용 — 괄호 없이 혼합하면 SyntaxError
        var has_coalesce = false;
        var has_logical_or_and = false;

        while (true) {
            // allow_in이 false면 `in`을 이항 연산자로 취급하지 않는다.
            // ECMAScript 13.7.4: for 초기화절에서 `in`은 for-in 키워드이지 연산자가 아니다.
            if (self.current() == .kw_in and !self.ctx.allow_in) break;

            const prec = getBinaryPrecedence(self.current());
            if (prec == 0 or prec <= min_prec) break;

            // ECMAScript 12.6: unary expression ** exponentiation → SyntaxError
            // delete/void/typeof/+/-/~/! 의 결과에 **를 적용할 수 없음
            if (self.current() == .star2 and !left.isNone()) {
                const left_tag = self.ast.getNode(left).tag;
                if (left_tag == .unary_expression) {
                    self.addError(self.currentSpan(), "unary expression cannot be the left operand of '**'");
                }
            }

            const left_start = self.ast.getNode(left).span.start;
            const op_kind = self.current();
            const is_logical = (op_kind == .amp2 or op_kind == .pipe2 or op_kind == .question2);

            // ?? 와 &&/|| 혼합 감지 (ECMAScript: 괄호 없이 혼합 금지)
            if (op_kind == .question2) {
                if (has_logical_or_and) {
                    self.addError(self.currentSpan(), "cannot mix '??' with '&&' or '||' without parentheses");
                }
                has_coalesce = true;
            } else if (op_kind == .amp2 or op_kind == .pipe2) {
                if (has_coalesce) {
                    self.addError(self.currentSpan(), "cannot mix '??' with '&&' or '||' without parentheses");
                }
                has_logical_or_and = true;
            }

            self.advance();

            // ** (star2)는 우결합: prec - 1로 재귀하여 같은 우선순위를 오른쪽에 허용
            const next_prec = if (op_kind == .star2) prec - 1 else prec;
            const right = try self.parseBinaryExpression(next_prec);

            // ?? 의 오른쪽에 괄호 없는 &&/|| 이 있으면 에러 (재귀 호출로 감지 못한 케이스)
            // 예: 0 ?? 0 && true → right = (0 && true) = logical_expression
            if (op_kind == .question2 and !right.isNone()) {
                const right_node = self.ast.getNode(right);
                if (right_node.tag == .logical_expression) {
                    const right_op: Kind = @enumFromInt(right_node.data.binary.flags);
                    if (right_op == .amp2 or right_op == .pipe2) {
                        self.addError(right_node.span, "cannot mix '??' with '&&' or '||' without parentheses");
                    }
                }
            }

            const tag: Tag = if (is_logical) .logical_expression else .binary_expression;

            left = try self.ast.addNode(.{
                .tag = tag,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = @intFromEnum(op_kind) } },
            });
        }

        return left;
    }

    fn parseUnaryExpression(self: *Parser) ParseError2!NodeIndex {
        const kind = self.current();
        switch (kind) {
            .bang, .tilde, .minus, .plus, .kw_typeof, .kw_void, .kw_delete => {
                const start = self.currentSpan().start;
                const is_delete = kind == .kw_delete;
                self.advance();
                const operand = try self.parseUnaryExpression();
                // strict mode: delete identifier → SyntaxError (ECMAScript 12.5.3.1)
                // delete of private field → always SyntaxError (ECMAScript 13.5.1.1)
                // delete (this.#x), delete this?.#x 도 포함
                if (is_delete and !operand.isNone()) {
                    var del_target = operand;
                    // 괄호 unwrap
                    while (!del_target.isNone()) {
                        const dt = self.ast.getNode(del_target);
                        if (dt.tag == .parenthesized_expression) {
                            del_target = dt.data.unary.operand;
                        } else break;
                    }
                    if (!del_target.isNone()) {
                        const del_node = self.ast.getNode(del_target);
                        if (del_node.tag == .static_member_expression or
                            del_node.tag == .computed_member_expression or
                            del_node.tag == .private_field_expression)
                        {
                            const right_idx = del_node.data.binary.right;
                            if (!right_idx.isNone() and @intFromEnum(right_idx) < self.ast.nodes.items.len) {
                                if (self.ast.getNode(right_idx).tag == .private_identifier) {
                                    self.addError(del_node.span, "private fields cannot be deleted");
                                }
                            }
                        }
                    }
                }
                // delete (x) 도 괄호를 통과하여 체크
                if (is_delete and self.is_strict_mode and !operand.isNone()) {
                    var target = operand;
                    while (!target.isNone()) {
                        const t = self.ast.getNode(target);
                        if (t.tag == .identifier_reference) {
                            self.addError(t.span, "delete of an identifier is not allowed in strict mode");
                            break;
                        } else if (t.tag == .parenthesized_expression) {
                            target = t.data.unary.operand;
                        } else break;
                    }
                }
                return try self.ast.addNode(.{
                    .tag = .unary_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = @intFromEnum(kind) } },
                });
            },
            .plus2, .minus2 => {
                const start = self.currentSpan().start;
                self.advance();
                const operand = try self.parseUnaryExpression();
                // ++/-- operand는 유효한 assignment target이어야 함
                _ = self.coverExpressionToAssignmentTarget(operand, true);
                return try self.ast.addNode(.{
                    .tag = .update_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = @intFromEnum(kind) } },
                });
            },
            .kw_await => {
                // static initializer에서 await 사용 금지 (ECMAScript 15.7.14)
                // module mode에서 await expression으로 파싱되기 전에 체크해야 함
                if (self.in_static_initializer) {
                    self.addError(self.currentSpan(), "'await' is not allowed in class static initializer");
                }
                // formal parameter 안에서 await expression 금지 (ECMAScript 14.1.2)
                if (self.in_formal_parameters and self.ctx.in_async) {
                    self.addError(self.currentSpan(), "'await' expression is not allowed in formal parameters");
                }
                // async 함수 안에서는 항상 await_expression.
                // module top-level(함수 밖)에서는 top-level await.
                // module 안 일반 함수 body에서는 await을 식별자로 취급 → strict mode 에러.
                // ECMAScript: FunctionBody[~Yield, ~Await] → await은 keyword가 아님.
                if (self.ctx.in_async or (self.is_module and !self.ctx.in_function)) {
                    const start = self.currentSpan().start;
                    self.advance();
                    const operand = try self.parseUnaryExpression();
                    return try self.ast.addNode(.{
                        .tag = .await_expression,
                        .span = .{ .start = start, .end = self.currentSpan().start },
                        .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                    });
                }
                // module 안 일반 함수에서 await 사용 → strict mode 위반 에러
                if (self.is_module and self.ctx.in_function and !self.ctx.in_async) {
                    self.addError(self.currentSpan(), "'await' is not allowed in non-async function in module code");
                }
                // async 밖 + script mode에서는 식별자로 파싱
                return self.parsePostfixExpression();
            },
            // yield expression은 parseAssignmentExpression에서 처리됨 (ECMAScript 14.4)
            // generator 안에서 여기에 도달하면 identifier reference로 해석 → 에러
            .kw_yield => return self.parsePostfixExpression(),
            else => return self.parsePostfixExpression(),
        }
    }

    fn parsePostfixExpression(self: *Parser) ParseError2!NodeIndex {
        var expr = try self.parseCallExpression();

        // 후위 ++/--
        if ((self.current() == .plus2 or self.current() == .minus2) and
            !self.scanner.token.has_newline_before)
        {
            // ++/-- operand는 유효한 assignment target이어야 함
            _ = self.coverExpressionToAssignmentTarget(expr, true);
            const expr_start = self.ast.getNode(expr).span.start;
            const kind = self.current();
            self.advance();
            expr = try self.ast.addNode(.{
                .tag = .update_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = @as(u16, @intFromEnum(kind)) | 0x100 } }, // 0x100 = postfix
            });
        }

        // TS: non-null assertion (expr!)
        if (self.current() == .bang and !self.scanner.token.has_newline_before) {
            const expr_start = self.ast.getNode(expr).span.start;
            self.advance();
            expr = try self.ast.addNode(.{
                .tag = .ts_non_null_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        }

        // TS: as Type / satisfies Type (체이닝 가능: x as A as B)
        while (self.current() == .kw_as or self.current() == .kw_satisfies) {
            const expr_start = self.ast.getNode(expr).span.start;
            const is_satisfies = self.current() == .kw_satisfies;
            self.advance();
            const ty = try self.parseType();
            expr = try self.ast.addNode(.{
                .tag = if (is_satisfies) .ts_satisfies_expression else .ts_as_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = expr, .right = ty, .flags = 0 } },
            });
        }

        return expr;
    }

    fn parseCallExpression(self: *Parser) ParseError2!NodeIndex {
        var expr = try self.parsePrimaryExpression();
        var after_optional_chain = false;

        while (true) {
            const expr_start = self.ast.getNode(expr).span.start;
            switch (self.current()) {
                .l_paren => {
                    // super() 호출은 constructor에서만 허용
                    if (self.ast.getNode(expr).tag == .super_expression and !self.allow_super_call) {
                        self.addError(self.ast.getNode(expr).span, "'super()' is only allowed in a class constructor");
                    }
                    // 함수 호출
                    self.advance();
                    const arg_list = try self.parseArgumentList();
                    expr = try self.ast.addNode(.{
                        .tag = .call_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len) } },
                    });
                },
                .dot => {
                    // 멤버 접근: a.b
                    self.advance();
                    const prop = try self.parseIdentifierName();
                    // super.#private → SyntaxError (ECMAScript: SuperProperty doesn't include PrivateName)
                    if (!prop.isNone() and self.ast.getNode(prop).tag == .private_identifier) {
                        const obj_node = self.ast.getNode(expr);
                        if (obj_node.tag == .super_expression) {
                            self.addError(self.ast.getNode(prop).span, "private field access on super is not allowed");
                        }
                    }
                    expr = try self.ast.addNode(.{
                        .tag = if (!prop.isNone() and self.ast.getNode(prop).tag == .private_identifier)
                            .private_field_expression
                        else
                            .static_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                .l_bracket => {
                    // 계산된 멤버 접근: a[b] — `in` 연산자 허용 (ECMAScript: [+In])
                    self.advance();
                    const cm_saved = self.enterAllowInContext(true);
                    const prop = try self.parseExpression();
                    self.restoreContext(cm_saved);
                    self.expect(.r_bracket);
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                .question_dot => {
                    // optional chaining: a?.b, a?.[b], a?.()
                    self.advance(); // skip ?.
                    if (self.current() == .l_bracket) {
                        // a?.[expr] — `in` 연산자 허용 (ECMAScript: [+In])
                        self.advance();
                        const oc_saved = self.enterAllowInContext(true);
                        const prop = try self.parseExpression();
                        self.restoreContext(oc_saved);
                        self.expect(.r_bracket);
                        expr = try self.ast.addNode(.{
                            .tag = .computed_member_expression,
                            .span = .{ .start = expr_start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 1 } }, // 1 = optional
                        });
                    } else if (self.current() == .l_paren) {
                        // a?.()
                        self.advance();
                        const arg_list = try self.parseArgumentList();
                        expr = try self.ast.addNode(.{
                            .tag = .call_expression,
                            .span = .{ .start = expr_start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = expr, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len | 0x8000) } }, // 0x8000 = optional
                        });
                    } else {
                        // a?.b
                        const prop = try self.parseIdentifierName();
                        expr = try self.ast.addNode(.{
                            .tag = .static_member_expression,
                            .span = .{ .start = expr_start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 1 } }, // 1 = optional
                        });
                    }
                    after_optional_chain = true;
                    continue;
                },
                .no_substitution_template, .template_head => {
                    // tagged template 금지: a?.b`template` (ECMAScript 12.3.1.1)
                    if (after_optional_chain) {
                        self.addError(self.currentSpan(), "tagged template cannot be used in optional chain");
                    }
                    // tagged template: expr`text` 또는 expr`text${...}...`
                    // tagged template에서는 잘못된 이스케이프 허용 (cooked가 undefined)
                    const tmpl = if (self.current() == .template_head)
                        try self.parseTemplateLiteral(true)
                    else blk: {
                        const tmpl_span = self.currentSpan();
                        self.advance();
                        break :blk try self.ast.addNode(.{
                            .tag = .template_literal,
                            .span = tmpl_span,
                            .data = .{ .none = 0 },
                        });
                    };
                    expr = try self.ast.addNode(.{
                        .tag = .tagged_template_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = tmpl, .flags = 0 } },
                    });
                },
                else => break,
            }
            after_optional_chain = false;
        }

        return expr;
    }

    /// new 표현식의 callee를 파싱한다.
    /// new는 중첩 가능하므로 new를 만나면 재귀한다.
    /// member access (.prop, [expr])만 허용하고 호출 ()은 상위에서 처리.
    fn parseNewCallee(self: *Parser) ParseError2!NodeIndex {
        // ECMAScript: new import(...) 는 금지
        if (self.current() == .kw_import) {
            self.addError(self.currentSpan(), "'import' cannot be used with 'new'");
        }
        if (self.current() == .kw_new) {
            const span = self.currentSpan();
            self.advance(); // skip 'new'
            const callee = try self.parseNewCallee();
            if (self.current() == .l_paren) {
                self.advance();
                const arg_list = try self.parseArgumentList();
                return try self.ast.addNode(.{
                    .tag = .new_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = callee, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len) } },
                });
            }
            return try self.ast.addNode(.{
                .tag = .new_expression,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = callee, .right = NodeIndex.none, .flags = 0 } },
            });
        }

        // primary expression + member chain (호출 제외)
        var expr = try self.parsePrimaryExpression();
        while (true) {
            const expr_start = self.ast.getNode(expr).span.start;
            switch (self.current()) {
                .dot => {
                    self.advance();
                    const prop = try self.parseIdentifierName();
                    expr = try self.ast.addNode(.{
                        .tag = .static_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                .l_bracket => {
                    self.advance();
                    const prop = try self.parseExpression();
                    self.expect(.r_bracket);
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                else => break,
            }
        }
        return expr;
    }

    fn parsePrimaryExpression(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();

        switch (self.current()) {
            .identifier => {
                // class field/static initializer에서 arguments 사용 금지
                // ECMAScript 15.7.1 (class field), 15.7.14 (static block)
                // 이 컨텍스트들은 자체 arguments 바인딩이 없다.
                if (self.in_class_field or self.in_static_initializer) {
                    const text = self.resolveIdentifierText(span);
                    if (std.mem.eql(u8, text, "arguments")) {
                        const msg = if (self.in_static_initializer)
                            "'arguments' is not allowed in class static initializer"
                        else
                            "'arguments' is not allowed in class field initializer";
                        self.addError(span, msg);
                    }
                }
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .decimal, .float, .hex, .octal, .binary, .positive_exponential, .negative_exponential => {
                // strict mode에서 legacy octal 숫자 금지 (ECMAScript 12.8.3.1)
                if (self.scanner.token.has_legacy_octal and self.is_strict_mode) {
                    self.addError(span, "Octal literals are not allowed in strict mode");
                }
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .numeric_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .decimal_bigint, .binary_bigint, .octal_bigint, .hex_bigint => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .bigint_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .string_literal => {
                // strict mode에서 legacy octal escape 금지 (ECMAScript 12.8.4.1)
                if (self.scanner.token.has_legacy_octal and self.is_strict_mode) {
                    self.addError(span, "Octal escape sequences are not allowed in strict mode");
                }
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .kw_true, .kw_false => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .boolean_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .kw_null => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .null_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .kw_this => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .kw_new => {
                // new expression: new Callee(args)
                // new는 중첩 가능: new new Foo()()
                self.advance(); // skip 'new'

                // new.target — 메타 프로퍼티 (함수 안에서만 유효)
                if (self.current() == .dot) {
                    const peek = self.peekNextKind();
                    if (peek == .kw_target) {
                        self.advance(); // skip '.'
                        const target_span = self.currentSpan();
                        self.advance(); // skip 'target'
                        // ECMAScript 15.1.1: new.target은 함수 본문 안에서만 허용
                        // arrow function은 외부의 allow_new_target을 상속
                        if (!self.allow_new_target) {
                            self.addError(.{ .start = span.start, .end = target_span.end }, "'new.target' is not allowed outside of functions");
                        }
                        return try self.ast.addNode(.{
                            .tag = .meta_property,
                            .span = .{ .start = span.start, .end = target_span.end },
                            .data = .{ .none = 1 }, // 1 = new.target (0 = import.meta)
                        });
                    }
                }

                // callee: 재귀적으로 new 또는 primary + member chain
                const callee = try self.parseNewCallee();

                // 인자: (args) — 있으면 소비, 없으면 인자 없는 new (new Foo)
                if (self.current() == .l_paren) {
                    self.advance(); // skip (
                    const arg_list = try self.parseArgumentList();
                    return try self.ast.addNode(.{
                        .tag = .new_expression,
                        .span = .{ .start = span.start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = callee, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len) } },
                    });
                }

                // 인자 없는 new: new Foo
                return try self.ast.addNode(.{
                    .tag = .new_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = callee, .right = NodeIndex.none, .flags = 0 } },
                });
            },
            .kw_super => {
                // super expression: super() 또는 super.prop 또는 super[expr]
                // ECMAScript 12.3.7: super는 메서드 안에서만 허용
                // allow_super_property는 메서드 진입 시 true, 일반 함수 진입 시 false로 리셋
                // arrow function은 외부의 allow_super_property를 상속
                if (!self.allow_super_property and !self.allow_super_call) {
                    self.addError(span, "'super' is not allowed outside of a method");
                }
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .super_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .l_paren => {
                // 괄호 표현식 또는 arrow function 파라미터 리스트.
                // 괄호 안에서는 `in` 연산자가 항상 허용된다 (ECMAScript: [+In] 컨텍스트).
                self.advance(); // skip (

                // 빈 괄호: () → arrow function의 빈 파라미터 리스트
                if (self.current() == .r_paren) {
                    self.advance(); // skip )
                    return try self.ast.addNode(.{
                        .tag = .parenthesized_expression,
                        .span = .{ .start = span.start, .end = self.currentSpan().start },
                        .data = .{ .none = 0 },
                    });
                }

                // `(a, ...b) => {}` 형태의 rest 파라미터를 cover grammar으로 지원.
                // `...`는 일반 expression에서는 나올 수 없으므로 arrow 파라미터로만 해석된다.
                const paren_saved = self.enterAllowInContext(true);
                const expr = try self.parseExpressionOrRest();
                self.restoreContext(paren_saved);
                self.expect(.r_paren);
                return try self.ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
            },
            .kw_class => return self.parseClassExpression(),
            // Decorator on class expression: @decorator class {}
            // ECMAScript: ClassExpression includes optional DecoratorList
            .at => {
                const scratch_top = self.saveScratch();
                while (self.current() == .at) {
                    const dec = try self.parseDecorator();
                    try self.scratch.append(dec);
                }
                const decorators = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                self.restoreScratch(scratch_top);
                if (self.current() != .kw_class) {
                    self.addError(self.currentSpan(), "class expected after decorator");
                }
                return self.parseClassWithDecorators(.class_expression, decorators);
            },
            .kw_function => return self.parseFunctionExpression(),
            .l_angle => return self.parseJSXElement(),
            .kw_import => {
                self.advance(); // skip 'import'
                if (self.current() == .dot) {
                    self.advance(); // skip '.'
                    const prop_span = self.currentSpan();
                    const prop_name = try self.parseIdentifierName();
                    _ = prop_name;

                    // import.meta — module code에서만 허용
                    // import.source(...), import.defer(...) — script에서도 허용 (dynamic import)
                    const prop_text = self.ast.source[prop_span.start..prop_span.end];
                    if (std.mem.eql(u8, prop_text, "meta")) {
                        if (!self.is_module) {
                            self.addError(.{ .start = span.start, .end = prop_span.end }, "'import.meta' is only allowed in module code");
                        }
                        return try self.ast.addNode(.{
                            .tag = .meta_property,
                            .span = .{ .start = span.start, .end = prop_span.end },
                            .data = .{ .none = 0 },
                        });
                    }

                    // import.source / import.defer — source phase imports (Stage 3)
                    // 그 외 import.UNKNOWN은 SyntaxError (ECMAScript ImportCall 문법)
                    const is_source = std.mem.eql(u8, prop_text, "source");
                    const is_defer = std.mem.eql(u8, prop_text, "defer");
                    if (!is_source and !is_defer) {
                        self.addError(.{ .start = span.start, .end = prop_span.end }, "import.meta/source/defer expected, got unknown property");
                        return try self.ast.addNode(.{
                            .tag = .meta_property,
                            .span = .{ .start = span.start, .end = prop_span.end },
                            .data = .{ .none = 0 },
                        });
                    }

                    // import.source(...) / import.defer(...) — dynamic import 변형
                    if (self.current() == .l_paren) {
                        return self.parseImportCallArgs(span.start);
                    }

                    // import.source/defer without () → 에러
                    self.addError(.{ .start = span.start, .end = prop_span.end }, "import.source/defer requires arguments");
                    return try self.ast.addNode(.{
                        .tag = .meta_property,
                        .span = .{ .start = span.start, .end = prop_span.end },
                        .data = .{ .none = 0 },
                    });
                }
                // dynamic import: import("module") or import("module", options)
                return self.parseImportCallArgs(span.start);
            },
            .no_substitution_template => {
                // 보간 없는 템플릿 리터럴: `text`
                // untagged template에서 잘못된 이스케이프는 SyntaxError (ECMAScript 13.2.8.1)
                if (self.scanner.token.has_invalid_escape) {
                    self.addError(span, "invalid escape sequence in template literal");
                }
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .template_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .template_head => {
                // 보간 있는 템플릿 리터럴: `text${expr}...`
                // untagged template에서 잘못된 이스케이프는 SyntaxError
                if (self.scanner.token.has_invalid_escape) {
                    self.addError(span, "invalid escape sequence in template literal");
                }
                return self.parseTemplateLiteral(false);
            },
            .regexp_literal => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .regexp_literal,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .l_bracket => {
                // 배열 리터럴 — 내부에서 `in` 연산자 항상 허용
                const arr_saved = self.enterAllowInContext(true);
                const arr = try self.parseArrayExpression();
                self.restoreContext(arr_saved);
                return arr;
            },
            .l_curly => {
                // 객체 리터럴 — 내부에서 `in` 연산자 항상 허용
                const obj_saved = self.enterAllowInContext(true);
                const obj = try self.parseObjectExpression();
                self.restoreContext(obj_saved);
                return obj;
            },
            .private_identifier => {
                // ECMAScript Ergonomic Brand Checks: `#field in obj`
                // private identifier가 `in` 연산자의 좌변으로 사용되는 경우.
                // 예: `#foo in obj` — obj에 private field #foo가 존재하는지 확인.
                // 멤버 표현식(this.#foo, obj.#foo)이 아닌 독립적인 #identifier를
                // primary expression으로 파싱하면, 이후 parseBinaryExpression에서
                // `in` 연산자와 자연스럽게 결합된다.
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .private_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .kw_async => {
                // async function expression 또는 async arrow
                const peek = self.peekNext();
                if (peek.kind == .kw_function and !peek.has_newline_before) {
                    // async function expression
                    self.advance(); // skip 'async'
                    return self.parseFunctionExpressionWithFlags(ast_mod.FunctionFlags.is_async);
                }
                // async를 일반 식별자로 취급 (async arrow는 parseAssignmentExpression에서 처리)
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            else => {
                // escaped strict reserved → strict mode에서 에러, non-strict에서 identifier
                if (self.current() == .escaped_strict_reserved) {
                    if (self.is_strict_mode) {
                        self.addError(span, "escaped reserved word cannot be used as identifier in strict mode");
                    }
                    self.checkYieldAwaitUse(span, "identifier");
                    self.advance();
                    return try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = span,
                        .data = .{ .string_ref = span },
                    });
                }
                // contextual keyword, strict mode reserved, TS keyword는
                // expression에서 식별자로 사용 가능 (reserved keyword만 불가)
                if (self.current().isKeyword() and
                    (!self.current().isReservedKeyword() or self.current() == .kw_await or self.current() == .kw_yield))
                {
                    if (self.is_strict_mode and self.current().isStrictModeReserved()) {
                        self.addError(span, "reserved word in strict mode cannot be used as identifier");
                    } else {
                        self.checkYieldAwaitUse(span, "identifier");
                    }
                    self.advance();
                    return try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = span,
                        .data = .{ .string_ref = span },
                    });
                }
                // 에러 복구: 알 수 없는 토큰 → 에러 노드 생성 후 건너뜀
                self.addError(span, "expression expected");
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .invalid,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
        }
    }

    /// 보간이 있는 템플릿 리터럴을 파싱한다: `head${expr}middle${expr}tail`
    /// is_tagged가 true이면 tagged template이므로 잘못된 이스케이프를 허용한다.
    fn parseTemplateLiteral(self: *Parser, is_tagged: bool) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const scratch_top = self.saveScratch();

        // template_head: `text${
        try self.scratch.append(try self.ast.addNode(.{
            .tag = .template_element,
            .span = self.currentSpan(),
            .data = .{ .none = 0 },
        }));
        self.advance(); // skip template_head

        while (true) {
            // expression inside ${} — `in` 연산자 항상 허용 (ECMAScript: TemplateMiddleList[+In])
            const tmpl_saved = self.enterAllowInContext(true);
            const expr = try self.parseExpression();
            self.restoreContext(tmpl_saved);
            try self.scratch.append(expr);

            // template_middle: }text${ 또는 template_tail: }text`
            if (self.current() == .template_middle) {
                // untagged template에서 잘못된 이스케이프는 SyntaxError
                if (!is_tagged and self.scanner.token.has_invalid_escape) {
                    self.addError(self.currentSpan(), "invalid escape sequence in template literal");
                }
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .template_element,
                    .span = self.currentSpan(),
                    .data = .{ .none = 0 },
                }));
                self.advance();
            } else if (self.current() == .template_tail) {
                // untagged template에서 잘못된 이스케이프는 SyntaxError
                if (!is_tagged and self.scanner.token.has_invalid_escape) {
                    self.addError(self.currentSpan(), "invalid escape sequence in template literal");
                }
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .template_element,
                    .span = self.currentSpan(),
                    .data = .{ .none = 0 },
                }));
                self.advance();
                break;
            } else {
                // 에러 복구: 닫히지 않은 템플릿
                self.addError(self.currentSpan(), "expected template continuation");
                break;
            }
        }

        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .template_literal,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = list },
        });
    }

    fn parseArrayExpression(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip [

        var elements = std.ArrayList(NodeIndex).init(self.allocator);
        defer elements.deinit();

        while (self.current() != .r_bracket and self.current() != .eof) {
            if (self.current() == .comma) {
                // elision (빈 슬롯)
                const hole_span = self.currentSpan();
                try elements.append(try self.ast.addNode(.{
                    .tag = .elision,
                    .span = hole_span,
                    .data = .{ .none = 0 },
                }));
                self.advance();
                continue;
            }
            const elem = try self.parseSpreadOrAssignment();
            try elements.append(elem);
            if (!self.eat(.comma)) break;
            // spread 뒤에 trailing comma가 있고 바로 ]가 오면 플래그를 설정.
            // 이 정보는 coverArrayExpressionToTarget에서 rest trailing comma 에러에 사용된다.
            if (!elem.isNone() and self.ast.getNode(elem).tag == .spread_element and self.current() == .r_bracket) {
                self.ast.nodes.items[@intFromEnum(elem)].data.unary.flags = spread_trailing_comma;
            }
        }

        const end = self.currentSpan().end;
        self.expect(.r_bracket);

        const list = try self.ast.addNodeList(elements.items);
        return try self.ast.addNode(.{
            .tag = .array_expression,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    fn parseObjectExpression(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip {

        var props = std.ArrayList(NodeIndex).init(self.allocator);
        defer props.deinit();

        while (self.current() != .r_curly and self.current() != .eof) {
            const prop = try self.parseObjectProperty();
            try props.append(prop);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;

        // 객체 리터럴은 표현식이므로, 닫는 `}` 뒤의 `/`는 division이어야 한다.
        // prev_token_kind를 `.r_paren`으로 설정하면 scanSlash()가 division으로 판별한다.
        // 예: `{valueOf: fn} / 1` — object literal 뒤 division
        self.scanner.prev_token_kind = .r_paren;
        self.expect(.r_curly);

        const list = try self.ast.addNodeList(props.items);
        return try self.ast.addNode(.{
            .tag = .object_expression,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    fn parseObjectProperty(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // spread: ...expr
        if (self.current() == .dot3) {
            self.advance();
            const expr = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .spread_element,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        }

        // get/set 메서드 shorthand: { get prop() {}, set prop(v) {} }
        if (self.current() == .kw_get or self.current() == .kw_set) {
            const peek = self.peekNextKind();
            if (peek != .colon and peek != .l_paren and peek != .comma and peek != .r_curly) {
                const method_flags: u16 = if (self.current() == .kw_get) 0x02 else 0x04;
                self.advance(); // skip get/set
                const key = try self.parsePropertyKey();
                return self.parseObjectMethodBody(start, key, method_flags);
            }
        }

        // async 메서드 shorthand: { async foo() {} }
        if (self.current() == .kw_async) {
            const peek = self.peekNext();
            if (peek.kind != .colon and peek.kind != .comma and
                peek.kind != .r_curly and !peek.has_newline_before)
            {
                var method_flags: u16 = 0x08; // async
                self.advance(); // skip 'async'
                // async generator: { async *foo() {} }
                if (self.eat(.star)) method_flags |= 0x10;
                const key = try self.parsePropertyKey();
                return self.parseObjectMethodBody(start, key, method_flags);
            }
        }

        // generator 메서드: { *foo() {} }
        if (self.current() == .star) {
            self.advance(); // skip '*'
            const key = try self.parsePropertyKey();
            return self.parseObjectMethodBody(start, key, 0x10); // generator
        }

        // 키: identifier, string, number, 또는 computed [expr]
        const key = try self.parsePropertyKey();

        // object literal에서 private identifier는 키로 사용 불가
        if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) {
            self.addError(self.ast.getNode(key).span, "private identifier is not allowed as object property key");
        }

        // 메서드 shorthand: { foo() {} }
        if (self.current() == .l_paren) {
            return self.parseObjectMethodBody(start, key, 0);
        }

        // key: value
        var value = NodeIndex.none;
        var prop_flags: u16 = 0;
        if (self.eat(.colon)) {
            value = try self.parseAssignmentExpression();
        } else if (self.eat(.eq)) {
            // shorthand with default: { x = 1 }  (destructuring default)
            // CoverInitializedName — destructuring 변환에서 소비되지 않으면 에러
            value = try self.parseAssignmentExpression();
            prop_flags = shorthand_with_default;
            self.has_cover_init_name = true;
        } else {
            // shorthand: { x } — key가 identifier shorthand로 사용 가능한지 검증
            if (!key.isNone()) {
                const key_node = self.ast.getNode(key);
                switch (key_node.tag) {
                    .identifier_reference => {
                        const key_text = self.resolveIdentifierText(key_node.span);
                        if (token_mod.keywords.get(key_text)) |kw| {
                            // await/yield は contextual keyword — 特定のコンテキストでのみ reserved
                            const is_context_reserved = if (kw == .kw_await)
                                // await은 module 또는 async context에서만 reserved
                                false // kw_await 전용 체크는 아래에서 별도 처리
                            else
                                kw.isReservedKeyword() or kw.isLiteralKeyword();
                            if (is_context_reserved) {
                                self.addError(key_node.span, "reserved word cannot be used as shorthand property");
                            } else if (self.is_strict_mode and kw.isStrictModeReserved()) {
                                self.addError(key_node.span, "reserved word in strict mode cannot be used as shorthand property");
                            } else if (kw == .kw_yield and self.ctx.in_generator) {
                                self.addError(key_node.span, "'yield' cannot be used as shorthand property in generator");
                            } else if (kw == .kw_await and (self.ctx.in_async or self.is_module)) {
                                self.addError(key_node.span, "'await' cannot be used as shorthand property in async/module");
                            }
                        }
                    },
                    // non-identifier keys (numeric, bigint, string, computed) 는 shorthand 불가
                    .numeric_literal, .bigint_literal, .string_literal, .computed_property_key => {
                        self.addError(key_node.span, "expected ':' after property key");
                    },
                    else => {},
                }
            }
        }

        return try self.ast.addNode(.{
            .tag = .object_property,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value, .flags = prop_flags } },
        });
    }

    /// 객체 리터럴 메서드의 파라미터와 본문을 파싱한다.
    /// flags: 0x02=getter, 0x04=setter, 0x08=async, 0x10=generator
    fn parseObjectMethodBody(self: *Parser, start: u32, key: NodeIndex, flags: u16) ParseError2!NodeIndex {
        // 메서드 컨텍스트 진입 — 파라미터/본문 모두 이 컨텍스트에서 파싱
        // flags: 0x02=getter, 0x04=setter, 0x08=async, 0x10=generator
        const saved_ctx = self.enterFunctionContext((flags & 0x08) != 0, (flags & 0x10) != 0);
        // ECMAScript 12.3.7: 객체 리터럴 메서드에서도 super.prop 허용
        self.allow_super_property = true;

        self.expect(.l_paren);
        self.in_formal_parameters = true;
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
            }
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);
        self.in_formal_parameters = false;

        // TS 리턴 타입
        _ = try self.tryParseReturnType();
        self.has_simple_params = self.checkSimpleParams(scratch_top);
        self.checkDuplicateParams(scratch_top);
        const body = try self.parseFunctionBodyExpr();

        // retroactive strict mode checks for object methods
        if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
            self.checkStrictParamNames(scratch_top);
        }

        self.restoreFunctionContext(saved_ctx);

        const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        const extra_start = try self.ast.addExtra(@intFromEnum(key));
        _ = try self.ast.addExtra(param_list.start);
        _ = try self.ast.addExtra(param_list.len);
        _ = try self.ast.addExtra(@intFromEnum(body));
        _ = try self.ast.addExtra(flags);

        return try self.ast.addNode(.{
            .tag = .method_definition,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// 바인딩 패턴을 파싱한다: identifier, [destructuring], {destructuring}
    fn parseBindingPattern(self: *Parser) ParseError2!NodeIndex {
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

                const inner = try self.parseBindingPattern();
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
            const pattern = try self.parseBindingPattern();
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
                return self.tryWrapDefaultValue(node);
            },
            .l_bracket => {
                const pat = try self.parseArrayPattern();
                _ = self.eat(.question);
                _ = try self.tryParseTypeAnnotation();
                return self.tryWrapDefaultValue(pat);
            },
            .l_curly => {
                const pat = try self.parseObjectPattern();
                _ = self.eat(.question);
                _ = try self.tryParseTypeAnnotation();
                return self.tryWrapDefaultValue(pat);
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
                return self.tryWrapDefaultValue(node);
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
                    return self.tryWrapDefaultValue(node2);
                }
                self.addError(self.currentSpan(), "binding pattern expected");
                return NodeIndex.none;
            },
        }
    }

    /// 하위 호환: 식별자만 필요한 곳에서 호출
    fn parseBindingIdentifier(self: *Parser) ParseError2!NodeIndex {
        return self.parseBindingPattern();
    }

    /// `= expr` 이 있으면 assignment_pattern으로 감싼다. 없으면 원본 반환.
    /// 기본값 표현식에서는 `in` 연산자가 항상 허용된다 (ECMAScript: Initializer[+In]).
    fn tryWrapDefaultValue(self: *Parser, node: NodeIndex) ParseError2!NodeIndex {
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
    fn parseBindingName(self: *Parser) ParseError2!NodeIndex {
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
            .l_bracket => return self.parseArrayPattern(),
            .l_curly => return self.parseObjectPattern(),
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
    fn parseSimpleIdentifier(self: *Parser) ParseError2!NodeIndex {
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

    fn parseArrayPattern(self: *Parser) ParseError2!NodeIndex {
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
                const rest_arg = try self.parseBindingPattern();
                self.checkBindingRestInit(rest_arg);
                const rest = try self.ast.addNode(.{
                    .tag = .rest_element,
                    .span = .{ .start = rest_start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
                });
                try self.scratch.append(rest);
                break; // rest는 항상 마지막
            }
            const elem_raw = try self.parseBindingName();
            // default value: pattern = expr (배열/객체 패턴 뒤의 = default)
            var elem = try self.tryWrapDefaultValue(elem_raw);
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

    fn parseObjectPattern(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip {

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            if (self.current() == .dot3) {
                // rest element: ...pattern
                const rest_start = self.currentSpan().start;
                self.advance(); // skip ...
                const rest_arg = try self.parseBindingPattern();
                self.checkBindingRestInit(rest_arg);
                const rest = try self.ast.addNode(.{
                    .tag = .rest_element,
                    .span = .{ .start = rest_start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
                });
                try self.scratch.append(rest);
                break;
            }

            const prop = try self.parseBindingProperty();
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

    fn parseBindingProperty(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // shorthand: { x } = { x: x } 또는 { x = defaultVal }
        if (self.current() == .identifier) {
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
                const value = try self.tryWrapDefaultValue(key);
                return try self.ast.addNode(.{
                    .tag = .binding_property,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
                });
            }
        }

        // key: pattern = default
        const key = try self.parsePropertyKey();
        self.expect(.colon);
        const value_raw = try self.parseBindingPattern();
        // { x: pattern = defaultValue } 형태
        const value = try self.tryWrapDefaultValue(value_raw);

        return try self.ast.addNode(.{
            .tag = .binding_property,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
        });
    }

    fn parseIdentifierName(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .identifier or self.current() == .escaped_keyword or
            self.current() == .escaped_strict_reserved or self.current().isKeyword())
        {
            // IdentifierName: 예약어도 property name으로 사용 가능 (escaped 포함)
            self.advance();
            return try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        if (self.current() == .private_identifier) {
            self.advance();
            return try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "identifier expected");
        self.advance();
        return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
    }

    /// ModuleExportName을 파싱한다.
    /// ECMAScript: ModuleExportName = IdentifierName | StringLiteral
    /// export { "☿" }, import { "☿" as x } 등에서 사용.
    /// StringLiteral의 경우 IsStringWellFormedUnicode 검사를 수행한다 (lone surrogate 금지).
    fn parseModuleExportName(self: *Parser) ParseError2!NodeIndex {
        if (self.current() == .string_literal) {
            const span = self.currentSpan();
            // lone surrogate 검사: \uD800-\uDFFF가 쌍을 이루지 않으면 에러
            const str_content = self.ast.source[span.start + 1 .. if (span.end > 0) span.end - 1 else span.end];
            if (containsLoneSurrogate(str_content)) {
                self.addError(span, "string literal contains lone surrogate");
            }
            self.advance();
            return try self.ast.addNode(.{
                .tag = .string_literal,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        return self.parseIdentifierName();
    }

    /// 문자열에 lone surrogate escape (\uD800-\uDFFF)가 있는지 검사한다.
    /// \uHHHH 형태의 escape만 체크 (raw UTF-8은 이미 인코딩됨).
    fn containsLoneSurrogate(s: []const u8) bool {
        var i: usize = 0;
        while (i + 5 < s.len) : (i += 1) {
            if (s[i] == '\\' and s[i + 1] == 'u' and s[i + 2] != '{') {
                // \uHHHH — 4자리 hex 파싱
                if (i + 5 < s.len) {
                    const codepoint = parseHex4(s[i + 2 .. i + 6]) orelse continue;
                    if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                        // high surrogate — 뒤에 \uDC00-\uDFFF가 있으면 쌍
                        if (i + 11 < s.len and s[i + 6] == '\\' and s[i + 7] == 'u') {
                            const low = parseHex4(s[i + 8 .. i + 12]) orelse {
                                return true; // invalid low → lone
                            };
                            if (low >= 0xDC00 and low <= 0xDFFF) {
                                i += 11; // skip surrogate pair
                                continue;
                            }
                        }
                        return true; // lone high surrogate
                    } else if (codepoint >= 0xDC00 and codepoint <= 0xDFFF) {
                        return true; // lone low surrogate
                    }
                }
            }
        }
        // 마지막 몇 바이트도 체크
        while (i < s.len) : (i += 1) {
            if (s[i] == '\\' and i + 5 < s.len and s[i + 1] == 'u' and s[i + 2] != '{') {
                const codepoint = parseHex4(s[i + 2 .. i + 6]) orelse continue;
                if (codepoint >= 0xD800 and codepoint <= 0xDFFF) {
                    if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
                        // check for low surrogate
                        if (i + 11 < s.len and s[i + 6] == '\\' and s[i + 7] == 'u') {
                            const low = parseHex4(s[i + 8 .. i + 12]) orelse return true;
                            if (low >= 0xDC00 and low <= 0xDFFF) {
                                i += 11;
                                continue;
                            }
                        }
                    }
                    return true;
                }
            }
        }
        return false;
    }

    /// 4자리 hex 문자열을 u16으로 파싱한다.
    fn parseHex4(s: []const u8) ?u16 {
        if (s.len < 4) return null;
        var result: u16 = 0;
        for (s[0..4]) |c| {
            const digit: u16 = if (c >= '0' and c <= '9')
                c - '0'
            else if (c >= 'a' and c <= 'f')
                c - 'a' + 10
            else if (c >= 'A' and c <= 'F')
                c - 'A' + 10
            else
                return null;
            result = result * 16 + digit;
        }
        return result;
    }

    /// 객체 프로퍼티 키를 파싱한다.
    /// 허용: identifier, string literal, numeric literal, computed [expr].
    /// spread (...expr) 또는 assignment expression을 파싱. ...가 있으면 spread_element로 감싼다.
    /// 인자 리스트를 파싱한다: (arg1, arg2, ...) → NodeList
    /// 여는 괄호 `(`는 이미 소비된 상태에서 호출.
    /// 닫는 괄호 `)`까지 소비한다.
    fn parseArgumentList(self: *Parser) ParseError2!NodeList {
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const arg = try self.parseSpreadOrAssignment();
            try self.scratch.append(arg);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        return list;
    }

    /// 함수 인자 하나를 파싱한다. `in` 연산자 허용 (ECMAScript: Arguments[+In]).
    fn parseSpreadOrAssignment(self: *Parser) ParseError2!NodeIndex {
        const arg_saved = self.enterAllowInContext(true);
        defer self.restoreContext(arg_saved);
        if (self.current() == .dot3) {
            const start = self.currentSpan().start;
            self.advance(); // skip ...
            const arg = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .spread_element,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
            });
        }
        return self.parseAssignmentExpression();
    }

    fn parsePropertyKey(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        switch (self.current()) {
            .identifier, .escaped_keyword, .escaped_strict_reserved => {
                // property key: 예약어도 사용 가능 (obj.let, class { yield() {} })
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .private_identifier => {
                // #private 필드/메서드
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .private_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .string_literal => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .decimal, .float, .hex, .octal, .binary, .positive_exponential, .negative_exponential => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .numeric_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .decimal_bigint, .binary_bigint, .octal_bigint, .hex_bigint => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .bigint_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .l_bracket => {
                // computed property: [expr] — `in` 연산자 허용 (ECMAScript: ComputedPropertyName[+In])
                self.advance();
                const cpk_saved = self.enterAllowInContext(true);
                const expr = try self.parseAssignmentExpression();
                self.restoreContext(cpk_saved);
                self.expect(.r_bracket);
                return try self.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
            },
            else => {
                // 다른 키워드도 프로퍼티 키로 허용 (class, return 등)
                if (self.current().isKeyword()) {
                    self.advance();
                    return try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = span,
                        .data = .{ .string_ref = span },
                    });
                }
                self.addError(span, "property key expected");
                self.advance();
                return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
            },
        }
    }

    // ================================================================
    // 연산자 우선순위
    // ================================================================

    fn getBinaryPrecedence(kind: Kind) u8 {
        return switch (kind) {
            .pipe2 => 1, // ||
            .question2 => 1, // ??
            .amp2 => 2, // &&
            .pipe => 3, // |
            .caret => 4, // ^
            .amp => 5, // &
            .eq2, .neq, .eq3, .neq2 => 6, // == != === !==
            .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_instanceof, .kw_in => 7, // < > <= >= instanceof in
            .shift_left, .shift_right, .shift_right3 => 8, // << >> >>>
            .plus, .minus => 9, // + -
            .star, .slash, .percent => 10, // * / %
            .star2 => 11, // ** (우결합)
            else => 0, // 이항 연산자 아님
        };
    }

    // ================================================================
    // JSX 파싱
    // ================================================================

    /// <Tag ...>children</Tag> 또는 <Tag ... /> 또는 <>...</>
    fn parseJSXElement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.scanner.nextInsideJSXElement(); // '<' 이후 JSX 모드

        // Fragment: <>
        if (self.current() == .r_angle) {
            self.scanner.nextJSXChild(); // '>' 이후 children 모드
            return self.parseJSXFragment(start);
        }

        // Opening tag: <TagName
        const tag_name = try self.parseJSXTagName();

        // Attributes
        const scratch_top = self.saveScratch();
        while (self.current() != .r_angle and self.current() != .slash and self.current() != .eof) {
            const attr = try self.parseJSXAttribute();
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
                const child = try self.parseJSXElement();
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
                const child = try self.parseJSXElement();
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
            self.addError(self.currentSpan(), "spread expected");
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

    // ================================================================
    // TypeScript Declarations
    // ================================================================

    /// type Foo = Type;
    fn parseTsTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'type'

        const name = try self.parseSimpleIdentifier();

        // 제네릭 파라미터: type Foo<T> = ...
        var type_params = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_params = try self.parseTsTypeParameterDeclaration();
        }

        self.expect(.eq);
        const ty = try self.parseType();
        _ = self.eat(.semicolon);

        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(type_params));
        _ = try self.ast.addExtra(@intFromEnum(ty));

        return try self.ast.addNode(.{
            .tag = .ts_type_alias_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// interface Foo { ... }
    fn parseTsInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'interface'

        const name = try self.parseSimpleIdentifier();

        // 제네릭 파라미터
        var type_params = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_params = try self.parseTsTypeParameterDeclaration();
        }

        // extends (콤마 구분 리스트: interface Foo extends Bar, Baz)
        var extends_node = NodeIndex.none;
        if (self.eat(.kw_extends)) {
            // 첫 번째 타입은 항상 파싱
            extends_node = try self.parseType();
            // 추가 extends 타입들은 무시 (BACKLOG: 리스트로 변환)
            while (self.eat(.comma)) {
                _ = try self.parseType();
            }
        }

        // interface body
        const body = try self.parseObjectType();

        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(type_params));
        _ = try self.ast.addExtra(@intFromEnum(extends_node));
        _ = try self.ast.addExtra(@intFromEnum(body));

        return try self.ast.addNode(.{
            .tag = .ts_interface_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// const enum Foo { A, B, C }
    /// const enum은 일반 enum과 동일하게 파싱하되, flags=1로 표시.
    fn parseConstEnum(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'const'
        return self.parseTsEnumDeclarationWithFlags(1);
    }

    /// enum Foo { A, B, C }
    fn parseTsEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
        return self.parseTsEnumDeclarationWithFlags(0);
    }

    /// enum 파싱. flags: 0=일반 enum, 1=const enum.
    /// extra = [name, members_start, members_len, flags]
    fn parseTsEnumDeclarationWithFlags(self: *Parser, flags: u32) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'enum'

        const name = try self.parseSimpleIdentifier();
        self.expect(.l_curly);

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const member = try self.parseTsEnumMember();
            try self.scratch.append(member);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(name), members.start, members.len, flags,
        });

        return try self.ast.addNode(.{
            .tag = .ts_enum_declaration,
            .span = .{ .start = start, .end = end },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseTsEnumMember(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const name = try self.parsePropertyKey();

        var init_val = NodeIndex.none;
        if (self.eat(.eq)) {
            init_val = try self.parseAssignmentExpression();
        }

        return try self.ast.addNode(.{
            .tag = .ts_enum_member,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = init_val, .flags = 0 } },
        });
    }

    /// namespace Foo { ... } / module "name" { ... }
    fn parseTsModuleDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'namespace' or 'module'
        return self.parseTsModuleBody(start);
    }

    /// namespace body (재귀: A.B.C 중첩 처리). keyword는 이미 소비된 상태.
    fn parseTsModuleBody(self: *Parser, start: u32) ParseError2!NodeIndex {
        const name = try self.parseSimpleIdentifier();

        // 중첩: namespace A.B.C { }
        if (self.eat(.dot)) {
            const inner = try self.parseTsModuleBody(start);
            return try self.ast.addNode(.{
                .tag = .ts_module_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = name, .right = inner, .flags = 0 } },
            });
        }

        const body = try self.parseBlockStatement();

        return try self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = body, .flags = 0 } },
        });
    }

    /// declare var/let/const/function/class/...
    fn parseTsDeclareStatement(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'declare'
        // declare 뒤의 선언은 ambient context (const 이니셜라이저 불필요 등)
        const saved = self.ctx;
        self.ctx.in_ambient = true;
        const result = try self.parseStatement();
        self.ctx = saved;
        return result;
    }

    /// abstract class Foo { }
    fn parseTsAbstractClass(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'abstract'
        return self.parseClassDeclaration();
    }

    /// @decorator 파싱 후 class/export 문을 파싱
    fn parseDecoratedStatement(self: *Parser) ParseError2!NodeIndex {
        // 데코레이터 수집
        const scratch_top = self.saveScratch();
        while (self.current() == .at) {
            const dec = try self.parseDecorator();
            try self.scratch.append(dec);
        }
        const decorators = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        // 데코레이터 뒤에 올 수 있는 것: class, export, abstract
        return switch (self.current()) {
            .kw_class => self.parseClassWithDecorators(.class_declaration, decorators),
            .kw_export => self.parseExportDeclaration(),
            .kw_abstract => self.parseTsAbstractClass(),
            else => {
                self.addError(self.currentSpan(), "class or export expected after decorator");
                return self.parseExpressionStatement();
            },
        };
    }

    /// @expr — 단일 데코레이터 파싱
    fn parseDecorator(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip @
        const expr = try self.parseCallExpression();

        return try self.ast.addNode(.{
            .tag = .decorator,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
        });
    }

    /// <T, U extends V = W>
    fn parseTsTypeParameterDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip <

        const scratch_top = self.saveScratch();
        while (self.current() != .r_angle and self.current() != .eof) {
            const param = try self.parseTsTypeParameter();
            try self.scratch.append(param);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_angle);

        const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_type_parameter_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = params },
        });
    }

    fn parseTsTypeParameter(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const name = try self.parseSimpleIdentifier();

        // T extends U
        var constraint = NodeIndex.none;
        if (self.eat(.kw_extends)) {
            constraint = try self.parseType();
        }

        // T = DefaultType
        var default_type = NodeIndex.none;
        if (self.eat(.eq)) {
            default_type = try self.parseType();
        }

        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(constraint));
        _ = try self.ast.addExtra(@intFromEnum(default_type));

        return try self.ast.addNode(.{
            .tag = .ts_type_parameter,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // ================================================================
    // TypeScript Type 파싱
    // ================================================================

    /// `: Type` 어노테이션이 있으면 파싱하고 노드 반환. 없으면 none.
    fn tryParseTypeAnnotation(self: *Parser) ParseError2!NodeIndex {
        if (self.current() != .colon) return NodeIndex.none;
        // 타입 어노테이션이 아닌 colon인 경우 구분 필요:
        // object literal `{ key: value }`, ternary `? : `, switch `case:` 등
        // 여기서는 binding pattern/variable declarator 컨텍스트에서만 호출되므로 안전
        self.advance(); // skip ':'
        return self.parseType();
    }

    /// 리턴 타입 어노테이션 (`: Type`). 함수 선언에서 사용.
    fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
        if (self.current() != .colon) return NodeIndex.none;
        self.advance();
        return self.parseType();
    }

    /// TS 타입을 파싱한다. 유니온/인터섹션을 포함.
    fn parseType(self: *Parser) ParseError2!NodeIndex {
        var left = try self.parseIntersectionType();

        // 유니온: A | B | C
        while (self.current() == .pipe) {
            const start = self.ast.getNode(left).span.start;
            self.advance(); // skip |
            const right = try self.parseIntersectionType();
            left = try self.ast.addNode(.{
                .tag = .ts_union_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
            });
        }

        return left;
    }

    fn parseIntersectionType(self: *Parser) ParseError2!NodeIndex {
        var left = try self.parsePostfixType();

        // 인터섹션: A & B & C
        while (self.current() == .amp) {
            const start = self.ast.getNode(left).span.start;
            self.advance(); // skip &
            const right = try self.parsePostfixType();
            left = try self.ast.addNode(.{
                .tag = .ts_intersection_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
            });
        }

        return left;
    }

    fn parsePostfixType(self: *Parser) ParseError2!NodeIndex {
        var base = try self.parsePrimaryType();

        while (self.current() == .l_bracket) {
            const start = self.ast.getNode(base).span.start;
            if (self.peekNextKind() == .r_bracket) {
                // 배열 타입: T[]
                self.advance(); // [
                self.advance(); // ]
                base = try self.ast.addNode(.{
                    .tag = .ts_array_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = base, .flags = 0 } },
                });
            } else {
                // 인덱스 접근 타입: T[K]
                self.advance(); // [
                const index_type = try self.parseType();
                self.expect(.r_bracket);
                base = try self.ast.addNode(.{
                    .tag = .ts_indexed_access_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = base, .right = index_type, .flags = 0 } },
                });
            }
        }

        return base;
    }

    fn parsePrimaryType(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();

        // TS 키워드 타입
        if (self.current().isTypeScriptKeyword()) {
            const tag: Tag = switch (self.current()) {
                .kw_any => .ts_any_keyword,
                .kw_string => .ts_string_keyword,
                .kw_number => .ts_number_keyword,
                .kw_boolean => .ts_boolean_keyword,
                .kw_bigint => .ts_bigint_keyword,
                .kw_symbol => .ts_symbol_keyword,
                .kw_object => .ts_object_keyword,
                .kw_never => .ts_never_keyword,
                .kw_unknown => .ts_unknown_keyword,
                .kw_undefined => .ts_undefined_keyword,
                else => .ts_type_reference, // 다른 TS 키워드는 타입 참조로
            };
            if (tag != .ts_type_reference) {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = tag,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            }
        }

        switch (self.current()) {
            // void
            .kw_void => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_void_keyword,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            // null
            .kw_null => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_null_keyword,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            // this
            .kw_this => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_this_type,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            // 리터럴 타입 (true, false, 숫자, 문자열)
            .kw_true, .kw_false => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_literal_type,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .decimal, .float, .hex, .string_literal => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_literal_type,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            // 타입 참조: Foo, Foo.Bar, Foo<T>
            .identifier => return self.parseTypeReference(),
            // 괄호 타입: (Type) 또는 함수 타입: (a: T) => R
            .l_paren => return self.parseParenOrFunctionType(),
            // 객체 타입 리터럴: { x: number, y: string }
            .l_curly => return self.parseObjectType(),
            // 튜플 타입: [T, U]
            .l_bracket => return self.parseTupleType(),
            // typeof T
            .kw_typeof => {
                self.advance();
                const operand = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_type_query,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                });
            },
            // keyof T
            .kw_keyof => {
                self.advance();
                const operand = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_type_operator,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                });
            },
            else => {
                // 다른 TS 키워드가 타입 위치에 온 경우 타입 참조로 처리
                if (self.current().isKeyword()) {
                    return self.parseTypeReference();
                }
                self.addError(span, "type expected");
                self.advance();
                return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
            },
        }
    }

    fn parseTypeReference(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const name_span = self.currentSpan();
        self.advance(); // type name

        // Foo.Bar 형태
        var name_end = name_span.end;
        while (self.eat(.dot)) {
            name_end = self.currentSpan().end;
            self.advance(); // Bar
        }

        // 제네릭: Foo<T, U>
        var type_args = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_args = try self.parseTypeArguments();
        }

        const extra_start = try self.ast.addExtra(name_span.start);
        _ = try self.ast.addExtra(name_end);
        _ = try self.ast.addExtra(@intFromEnum(type_args));

        return try self.ast.addNode(.{
            .tag = .ts_type_reference,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseTypeArguments(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip <

        const scratch_top = self.saveScratch();
        while (self.current() != .r_angle and self.current() != .eof) {
            const ty = try self.parseType();
            try self.scratch.append(ty);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_angle);

        const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_type_parameter_instantiation,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = types },
        });
    }

    fn parseParenOrFunctionType(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip (

        // 빈 괄호 + => → 함수 타입 () => R
        if (self.current() == .r_paren) {
            self.advance();
            if (self.current() == .arrow) {
                self.advance();
                const return_type = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_function_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = return_type, .flags = 0 } },
                });
            }
            // 빈 괄호 — 에러 또는 void
            return try self.ast.addNode(.{ .tag = .ts_void_keyword, .span = .{ .start = start, .end = self.currentSpan().start }, .data = .{ .none = 0 } });
        }

        // 파라미터가 있는 경우 — 단순히 첫 번째 타입을 파싱하고 ) 뒤에 =>가 있으면 함수 타입
        const inner = try self.parseType();
        if (self.current() == .r_paren) {
            self.advance();
            if (self.current() == .arrow) {
                self.advance();
                const return_type = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_function_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = inner, .right = return_type, .flags = 0 } },
                });
            }
        } else {
            self.expect(.r_paren);
        }

        // 괄호 타입: (Type)
        return try self.ast.addNode(.{
            .tag = .ts_parenthesized_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
        });
    }

    fn parseObjectType(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip {

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const member = try self.parseTypeMember();
            try self.scratch.append(member);
            // ; 또는 , 로 구분
            if (!self.eat(.semicolon) and !self.eat(.comma)) {
                if (self.current() != .r_curly) break;
            }
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_type_literal,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = members },
        });
    }

    fn parseTypeMember(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // 간단: key: Type 또는 key?: Type
        const key = try self.parsePropertyKey();
        _ = self.eat(.question); // optional
        self.expect(.colon);
        const value_type = try self.parseType();

        return try self.ast.addNode(.{
            .tag = .ts_property_signature,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value_type, .flags = 0 } },
        });
    }

    fn parseTupleType(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip [

        const scratch_top = self.saveScratch();
        while (self.current() != .r_bracket and self.current() != .eof) {
            const ty = try self.parseType();
            try self.scratch.append(ty);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_bracket);

        const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_tuple_type,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = types },
        });
    }
};

// ============================================================
// Tests
// ============================================================

test "Parser: empty program" {
    var scanner = Scanner.init(std.testing.allocator, "");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
}

test "Parser: variable declaration" {
    var scanner = Scanner.init(std.testing.allocator, "const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: binary expression" {
    var scanner = Scanner.init(std.testing.allocator, "1 + 2 * 3;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const program = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, program.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: if statement" {
    var scanner = Scanner.init(std.testing.allocator, "function f(x) { if (x) { return 1; } else { return 2; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function declaration" {
    var scanner = Scanner.init(std.testing.allocator, "function add(a, b) { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: call expression" {
    var scanner = Scanner.init(std.testing.allocator, "foo(1, 2, 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: member access" {
    var scanner = Scanner.init(std.testing.allocator, "a.b.c;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array and object literals" {
    var scanner = Scanner.init(std.testing.allocator, "[1, 2, 3];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: error recovery" {
    var scanner = Scanner.init(std.testing.allocator, "@@@;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: do-while statement" {
    var scanner = Scanner.init(std.testing.allocator, "do { x++; } while (x < 10);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-in statement" {
    var scanner = Scanner.init(std.testing.allocator, "for (var key in obj) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-of statement" {
    var scanner = Scanner.init(std.testing.allocator, "for (const item of arr) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: switch statement" {
    var scanner = Scanner.init(std.testing.allocator,
        \\function f(x) {
        \\  switch (x) {
        \\    case 1: break;
        \\    case 2: return 2;
        \\    default: return 0;
        \\  }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for with empty parts" {
    var scanner = Scanner.init(std.testing.allocator, "for (;;) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: switch with var in case body (scratch nesting)" {
    // 이 테스트는 scratch save/restore가 올바르게 동작하는지 검증한다.
    // case 본문에 var 선언이 있으면 scratch를 중첩 사용하게 되는데,
    // save/restore 없이 clearRetainingCapacity를 쓰면 이전 case가 사라진다.
    var scanner = Scanner.init(std.testing.allocator,
        \\switch (x) {
        \\  case 1:
        \\    var a = 1;
        \\    break;
        \\  case 2:
        \\    var b = 2;
        \\    break;
        \\  default:
        \\    break;
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: nested call in var initializer (scratch nesting)" {
    // var x = foo(bar(1, 2), 3); — 중첩 호출에서 scratch가 안전한지 검증
    var scanner = Scanner.init(std.testing.allocator, "var x = foo(bar(1, 2), 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-finally" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch-finally" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try without catch or finally is error" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional catch binding (ES2019)" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } catch { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (simple)" {
    var scanner = Scanner.init(std.testing.allocator, "const f = x => x + 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (parenthesized)" {
    var scanner = Scanner.init(std.testing.allocator, "const f = (a, b) => a + b;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function with block body" {
    var scanner = Scanner.init(std.testing.allocator, "const f = (x) => { return x * 2; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in array" {
    var scanner = Scanner.init(std.testing.allocator, "[1, ...arr, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in call" {
    var scanner = Scanner.init(std.testing.allocator, "foo(...args);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class declaration" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Foo {
        \\  constructor(x) { this.x = x; }
        \\  getX() { return this.x; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with extends" {
    var scanner = Scanner.init(std.testing.allocator, "class Bar extends Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with static method and property" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Config {
        \\  static defaultValue = 42;
        \\  static create() { return 1; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class expression" {
    var scanner = Scanner.init(std.testing.allocator, "const Foo = class { bar() { } };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function expression" {
    var scanner = Scanner.init(std.testing.allocator, "const f = function(x) { return x; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array destructuring" {
    var scanner = Scanner.init(std.testing.allocator, "const [a, b, c] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: object destructuring" {
    var scanner = Scanner.init(std.testing.allocator, "const { x, y } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with default values" {
    var scanner = Scanner.init(std.testing.allocator, "const [a = 1, b = 2] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: nested destructuring" {
    var scanner = Scanner.init(std.testing.allocator, "const { a: { b } } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with rest" {
    var scanner = Scanner.init(std.testing.allocator, "const [first, ...rest] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function with destructuring params" {
    var scanner = Scanner.init(std.testing.allocator, "function foo({ x, y }, [a, b]) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// Import / Export tests
// ============================================================

test "Parser: import side-effect" {
    var scanner = Scanner.init(std.testing.allocator, "import 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default" {
    var scanner = Scanner.init(std.testing.allocator, "import foo from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import named" {
    var scanner = Scanner.init(std.testing.allocator, "import { a, b as c } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import namespace" {
    var scanner = Scanner.init(std.testing.allocator, "import * as ns from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default + named" {
    var scanner = Scanner.init(std.testing.allocator, "import React, { useState } from 'react';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default" {
    var scanner = Scanner.init(std.testing.allocator, "export default 42;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named" {
    var scanner = Scanner.init(std.testing.allocator, "export { a, b as c };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export declaration" {
    var scanner = Scanner.init(std.testing.allocator, "export const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export all re-export" {
    var scanner = Scanner.init(std.testing.allocator, "export * from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named re-export" {
    var scanner = Scanner.init(std.testing.allocator, "export { foo } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default function" {
    var scanner = Scanner.init(std.testing.allocator, "export default function foo() { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: dynamic import expression" {
    var scanner = Scanner.init(std.testing.allocator, "const m = import('module');");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async function declaration" {
    var scanner = Scanner.init(std.testing.allocator, "async function fetchData() { return await fetch(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: generator function" {
    var scanner = Scanner.init(std.testing.allocator, "function* gen() { yield 1; yield 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: yield delegate" {
    var scanner = Scanner.init(std.testing.allocator, "function* gen() { yield* other(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async arrow function" {
    var scanner = Scanner.init(std.testing.allocator, "const f = async () => { await fetch(); };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    // async arrow는 현재 async가 expression statement로 파싱됨
    // 완전한 async arrow는 추후 구현 (BACKLOG #35)
}

test "Parser: class with private field and method" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Counter {
        \\  #count = 0;
        \\  #increment() { this.#count++; }
        \\  get value() { return this.#count; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: private field access" {
    var scanner = Scanner.init(std.testing.allocator, "this.#name;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (array)" {
    // 배열 대입 구조분해 — 현재 array_expression + assignment로 파싱됨
    // semantic analysis에서 assignment target으로 변환 예정
    var scanner = Scanner.init(std.testing.allocator, "[a, b] = [1, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (object)" {
    var scanner = Scanner.init(std.testing.allocator, "({ x, y } = obj);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import.meta" {
    var scanner = Scanner.init(std.testing.allocator, "const url = import.meta.url;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array elision [, , x]" {
    var scanner = Scanner.init(std.testing.allocator, "const [, , x] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// TypeScript type tests
// ============================================================

test "Parser: TS variable with type annotation" {
    var scanner = Scanner.init(std.testing.allocator, "const x: number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS function with typed params and return" {
    var scanner = Scanner.init(std.testing.allocator, "function add(a: number, b: number): number { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS union type" {
    var scanner = Scanner.init(std.testing.allocator, "const x: string | number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS array type" {
    var scanner = Scanner.init(std.testing.allocator, "const arr: number[] = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type" {
    var scanner = Scanner.init(std.testing.allocator, "const arr: Array<string> = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS as expression" {
    var scanner = Scanner.init(std.testing.allocator, "const x = value as string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS non-null assertion" {
    var scanner = Scanner.init(std.testing.allocator, "const x = value!;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS object type literal" {
    var scanner = Scanner.init(std.testing.allocator, "const obj: { x: number; y: string } = { x: 1, y: 'a' };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS tuple type" {
    var scanner = Scanner.init(std.testing.allocator, "const t: [string, number] = ['a', 1];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS typeof and keyof" {
    var scanner = Scanner.init(std.testing.allocator, "const k: keyof typeof obj = 'x';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// TypeScript declaration tests
// ============================================================

test "Parser: TS type alias" {
    var scanner = Scanner.init(std.testing.allocator, "type StringOrNumber = string | number;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type alias" {
    var scanner = Scanner.init(std.testing.allocator, "type Result<T, E> = { ok: T } | { err: E };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS interface" {
    var scanner = Scanner.init(std.testing.allocator,
        \\interface User {
        \\  name: string;
        \\  age: number;
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS interface extends" {
    var scanner = Scanner.init(std.testing.allocator, "interface Admin extends User { role: string; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS enum" {
    var scanner = Scanner.init(std.testing.allocator,
        \\enum Color {
        \\  Red,
        \\  Green = 10,
        \\  Blue
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS namespace" {
    var scanner = Scanner.init(std.testing.allocator, "namespace Utils { const x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS declare" {
    var scanner = Scanner.init(std.testing.allocator, "declare const VERSION: string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS abstract class" {
    var scanner = Scanner.init(std.testing.allocator, "abstract class Shape { abstract area(): number; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type parameter with constraint and default" {
    var scanner = Scanner.init(std.testing.allocator, "type Foo<T extends string = 'hello'> = T;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS parameter property" {
    var scanner = Scanner.init(std.testing.allocator, "class Foo { constructor(public x: number, private y: string) { } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class" {
    var scanner = Scanner.init(std.testing.allocator, "@Component class Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator with arguments" {
    var scanner = Scanner.init(std.testing.allocator, "@Injectable() class Service { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class member" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  public greet(): void { }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class implements" {
    var scanner = Scanner.init(std.testing.allocator, "class Foo implements Bar, Baz { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: static readonly member" {
    var scanner = Scanner.init(std.testing.allocator, "class Foo { static readonly MAX = 100; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with generics" {
    var scanner = Scanner.init(std.testing.allocator, "class Box<T> { value: T; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// JSX tests
// ============================================================

test "Parser: JSX self-closing element" {
    var scanner = Scanner.init(std.testing.allocator, "const x = <br />;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX element with children" {
    var scanner = Scanner.init(std.testing.allocator,
        \\const x = <div>hello</div>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with attributes" {
    var scanner = Scanner.init(std.testing.allocator,
        \\const x = <div className="foo" id="bar" />;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with expression" {
    var scanner = Scanner.init(std.testing.allocator,
        \\const x = <span>{name}</span>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function call with division in args" {
    // arrow lookahead가 prev_token_kind를 복구하지 않으면
    // / 가 regex로 해석되어 실패하던 버그 테스트
    const source = "truncate(x / y)";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ================================================================
// 컨텍스트 검증 테스트 (D051)
// ================================================================

test "Parser: return outside function is error" {
    var scanner = Scanner.init(std.testing.allocator, "return 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'return' outside of function", parser.errors.items[0].message);
}

test "Parser: return inside function is valid" {
    var scanner = Scanner.init(std.testing.allocator, "function f() { return 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: return inside arrow function is valid" {
    var scanner = Scanner.init(std.testing.allocator, "const f = () => { return 1; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break outside loop/switch is error" {
    var scanner = Scanner.init(std.testing.allocator, "break;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: break inside loop is valid" {
    var scanner = Scanner.init(std.testing.allocator, "while (true) { break; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break inside switch is valid" {
    var scanner = Scanner.init(std.testing.allocator, "function f(x) { switch (x) { case 1: break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: continue outside loop is error" {
    var scanner = Scanner.init(std.testing.allocator, "continue;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'continue' outside of loop", parser.errors.items[0].message);
}

test "Parser: continue inside for loop is valid" {
    var scanner = Scanner.init(std.testing.allocator, "for (var i = 0; i < 10; i++) { continue; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break in nested function inside loop is error" {
    // 함수 경계에서 loop 컨텍스트가 리셋되므로, 내부 함수의 break는 에러
    var scanner = Scanner.init(std.testing.allocator, "while (true) { function f() { break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: with statement in strict mode is error" {
    var scanner = Scanner.init(std.testing.allocator,
        \\"use strict";
        \\with (obj) { x; }
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

test "Parser: with statement in non-strict mode is valid" {
    var scanner = Scanner.init(std.testing.allocator, "with (obj) { x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: use strict in function body" {
    // 함수 내부 "use strict"가 strict mode를 설정하는지 확인
    var scanner = Scanner.init(std.testing.allocator,
        \\function f() {
        \\  "use strict";
        \\  with (obj) { x; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

test "Parser: module mode is always strict" {
    var scanner = Scanner.init(std.testing.allocator, "with (obj) { x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

// ================================================================
// 예약어 검증 테스트
// ================================================================

test "Parser: reserved word as variable name is error" {
    var scanner = Scanner.init(std.testing.allocator, "var var = 123;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: strict mode reserved word as binding in strict mode is error" {
    var scanner = Scanner.init(std.testing.allocator,
        \\"use strict";
        \\var implements = 1;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: strict mode reserved word as binding in non-strict is valid" {
    var scanner = Scanner.init(std.testing.allocator, "var implements = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: let as variable name is valid in non-strict" {
    var scanner = Scanner.init(std.testing.allocator, "var let = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// 검증 로직 유닛 테스트
// ============================================================

test "Parser: ++this is invalid assignment target" {
    var scanner = Scanner.init(std.testing.allocator, "++this;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: delete identifier in strict mode is error" {
    var scanner = Scanner.init(std.testing.allocator, "\"use strict\"; delete x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: const without initializer is error" {
    var scanner = Scanner.init(std.testing.allocator, "const x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: for-of const without init is valid" {
    var scanner = Scanner.init(std.testing.allocator, "for (const x of [1]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import/export only at module top-level" {
    // import in function body — error even in module
    var scanner = Scanner.init(std.testing.allocator, "function f() { import 'x'; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: function in loop body is error" {
    var scanner = Scanner.init(std.testing.allocator, "for (;;) function f() {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: yield is identifier outside generator" {
    var scanner = Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is identifier in script mode" {
    var scanner = Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is reserved in module mode" {
    var scanner = Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: super outside method is error" {
    var scanner = Scanner.init(std.testing.allocator, "super.x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: new.target outside function is error" {
    var scanner = Scanner.init(std.testing.allocator, "new.target;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: object shorthand reserved word is error" {
    var scanner = Scanner.init(std.testing.allocator, "({true});");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional chaining is not assignment target" {
    var scanner = Scanner.init(std.testing.allocator, "x?.y = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: parenthesized destructuring is not assignment target" {
    var scanner = Scanner.init(std.testing.allocator, "({}) = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: arguments in class field initializer is error" {
    // class field에서 arguments 직접 사용 — SyntaxError
    {
        var scanner = Scanner.init(std.testing.allocator, "var C = class { x = arguments; };");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len > 0);
    }
    // arrow function 안에서 arguments 사용 — arrow는 자체 arguments가 없으므로 SyntaxError
    {
        var scanner = Scanner.init(std.testing.allocator, "class C { x = () => arguments; }");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len > 0);
    }
    // 일반 function 안에서 arguments 사용 — 자체 arguments 바인딩이 있으므로 OK
    {
        var scanner = Scanner.init(std.testing.allocator, "class C { x = function() { return arguments; }; }");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len == 0);
    }
}

// ============================================================
// Cover Grammar 유닛 테스트
// ============================================================

test "CoverGrammar: rest element with initializer in array destructuring" {
    // [...x = 1] = arr → rest에 initializer 금지
    var scanner = Scanner.init(std.testing.allocator, "[...x = 1] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    // "rest element may not have a default initializer" 에러가 포함되어야 함
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CoverGrammar: valid array destructuring" {
    // [a, b, ...c] = arr → 에러 없음
    var scanner = Scanner.init(std.testing.allocator, "[a, b, ...c] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "CoverGrammar: valid object destructuring" {
    // ({ a, b: c } = obj) → 에러 없음
    var scanner = Scanner.init(std.testing.allocator, "({ a, b: c } = obj);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "CoverGrammar: strict mode eval assignment" {
    // "use strict"; eval = 1 → 에러
    var scanner = Scanner.init(std.testing.allocator, "\"use strict\"; eval = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: parenthesized destructuring is invalid" {
    // ([x]) = 1 → parenthesized destructuring 금지
    var scanner = Scanner.init(std.testing.allocator, "([x]) = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: for-in with rest-init is error" {
    // for ([...x = 1] in obj) {} → rest-init 금지
    var scanner = Scanner.init(std.testing.allocator, "for ([...x = 1] in obj) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CoverGrammar: arrow params rest-init is error" {
    // ([...x = 1]) => {} → rest-init 금지
    var scanner = Scanner.init(std.testing.allocator, "([...x = 1]) => {};");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
