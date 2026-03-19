//! ZTS Semantic Analyzer
//!
//! AST를 순회하면서 스코프 트리를 구축하고 심볼(변수/함수/클래스 선언)을 수집한다.
//! 수집된 정보로 재선언 에러 등을 검증한다.
//!
//! 설계 (D038, D051):
//!   - 파서와 분리된 별도 패스 (oxc 방식)
//!   - Switch 기반 visitor (D042)
//!   - 파서가 이미 처리한 것: strict mode, break/continue/return 검증
//!   - 이 모듈이 처리하는 것: 스코프/심볼 수집, 재선언 검증

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;
const scope_mod = @import("scope.zig");
const ScopeId = scope_mod.ScopeId;
const ScopeKind = scope_mod.ScopeKind;
const Scope = scope_mod.Scope;
const symbol_mod = @import("symbol.zig");
const SymbolId = symbol_mod.SymbolId;
const SymbolKind = symbol_mod.SymbolKind;
const Symbol = symbol_mod.Symbol;

/// Semantic 분석 에러.
pub const SemanticError = struct {
    span: Span,
    message: []const u8,
};

/// Semantic Analyzer.
///
/// 사용법:
/// ```zig
/// var analyzer = SemanticAnalyzer.init(allocator, &ast);
/// defer analyzer.deinit();
/// analyzer.analyze();
/// // analyzer.errors에 에러가 있으면 출력
/// ```
pub const SemanticAnalyzer = struct {
    /// 분석 대상 AST (읽기 전용)
    ast: *const Ast,

    /// 스코프 배열 (플랫, D052)
    scopes: std.ArrayList(Scope),

    /// 심볼 배열 (플랫, D053)
    symbols: std.ArrayList(Symbol),

    /// 수집된 에러 목록
    errors: std.ArrayList(SemanticError),

    /// 현재 스코프 (스코프 스택 대신 인덱스 하나로 추적)
    current_scope: ScopeId = .none,

    /// strict mode 여부 (파서에서 전달받음, 스코프 진입 시 전파)
    is_strict_mode: bool = false,

    /// module 모드 여부 (파서에서 전달받음)
    is_module: bool = false,

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    /// class private name 스택 (중첩 class 지원, oxc 방식).
    /// 각 항목은 해당 class body에서 선언된 private name 집합.
    class_private_declared: std.ArrayList(std.StringHashMap(Span)),

    /// class private name 참조 스택.
    /// 각 항목은 해당 class body에서 참조된 private name 목록 (검증 대기).
    class_private_refs: std.ArrayList(std.ArrayList(PrivateRef)),

    const PrivateRef = struct {
        name: []const u8,
        span: Span,
    };

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) SemanticAnalyzer {
        return .{
            .ast = ast,
            .scopes = std.ArrayList(Scope).init(allocator),
            .symbols = std.ArrayList(Symbol).init(allocator),
            .class_private_declared = std.ArrayList(std.StringHashMap(Span)).init(allocator),
            .class_private_refs = std.ArrayList(std.ArrayList(PrivateRef)).init(allocator),
            .errors = std.ArrayList(SemanticError).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SemanticAnalyzer) void {
        // allocPrint으로 할당된 에러 메시지 해제
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.scopes.deinit();
        self.symbols.deinit();
        self.errors.deinit();
        for (self.class_private_declared.items) |*map| map.deinit();
        self.class_private_declared.deinit();
        for (self.class_private_refs.items) |*list| list.deinit();
        self.class_private_refs.deinit();
    }

    // ================================================================
    // 공개 API
    // ================================================================

    /// 분석을 실행한다. AST의 루트(마지막 노드 = program)부터 시작.
    pub fn analyze(self: *SemanticAnalyzer) void {
        if (self.ast.nodes.items.len == 0) return;
        const root_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(self.ast.nodes.items.len - 1)));
        self.visitNode(root_idx);
    }

    // ================================================================
    // 스코프 관리
    // ================================================================

    /// 새 스코프를 생성하고 진입한다. 반환값: 이전 스코프 ID (나갈 때 복원용).
    fn enterScope(self: *SemanticAnalyzer, kind: ScopeKind, is_strict: bool) ScopeId {
        const parent = self.current_scope;
        const new_id: ScopeId = @enumFromInt(@as(u32, @intCast(self.scopes.items.len)));
        self.scopes.append(.{
            .parent = parent,
            .kind = kind,
            .is_strict = is_strict,
        }) catch @panic("OOM: scope list");
        self.current_scope = new_id;
        return parent;
    }

    /// 스코프에서 나간다. enterScope의 반환값을 전달.
    fn exitScope(self: *SemanticAnalyzer, saved_scope: ScopeId) void {
        self.current_scope = saved_scope;
    }

    // ================================================================
    // Class Private Name 추적 (oxc 방식)
    // ================================================================

    /// class body 진입 시 private name 스코프를 push한다.
    fn pushClassScope(self: *SemanticAnalyzer) void {
        self.class_private_declared.append(std.StringHashMap(Span).init(self.allocator)) catch @panic("OOM");
        self.class_private_refs.append(std.ArrayList(PrivateRef).init(self.allocator)) catch @panic("OOM");
    }

    /// class body 퇴장 시 private name 참조를 검증하고 pop한다.
    fn popClassScope(self: *SemanticAnalyzer) void {
        if (self.class_private_declared.items.len == 0) return;

        var declared = self.class_private_declared.pop() orelse return;
        var refs = self.class_private_refs.pop() orelse return;
        defer refs.deinit();

        // 참조된 private name이 선언되었는지 확인
        for (refs.items) |ref| {
            if (!declared.contains(ref.name)) {
                // 외부 class에 선언되어 있는지 확인 (중첩 class)
                var found = false;
                for (self.class_private_declared.items) |outer| {
                    if (outer.contains(ref.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    self.addPrivateNameError(ref.span, ref.name);
                }
            }
        }

        declared.deinit();
    }

    /// private name을 현재 class scope에 선언 등록한다.
    fn declarePrivateName(self: *SemanticAnalyzer, name: []const u8, span: Span) void {
        if (self.class_private_declared.items.len == 0) return;
        var current = &self.class_private_declared.items[self.class_private_declared.items.len - 1];
        current.put(name, span) catch @panic("OOM");
    }

    /// private name 참조를 기록한다 (class body 퇴장 시 검증).
    fn usePrivateName(self: *SemanticAnalyzer, name: []const u8, span: Span) void {
        if (self.class_private_refs.items.len == 0) {
            // class 밖에서 private name 참조 → 즉시 에러
            self.addPrivateNameError(span, name);
            return;
        }
        var current = &self.class_private_refs.items[self.class_private_refs.items.len - 1];
        current.append(.{ .name = name, .span = span }) catch @panic("OOM");
    }

    /// 현재 class scope 안에 있는지 (private name 참조 가능 여부).
    fn inClassScope(self: *const SemanticAnalyzer) bool {
        return self.class_private_declared.items.len > 0;
    }

    // ================================================================
    // 심볼 등록 + 재선언 검증
    // ================================================================

    /// 심볼을 현재 스코프에 등록한다.
    /// var는 가장 가까운 var scope(function/global/module)에 등록.
    /// let/const/class는 현재 블록 스코프에 등록.
    /// 중복 선언이면 에러를 추가한다.
    fn declareSymbol(self: *SemanticAnalyzer, name_span: Span, kind: SymbolKind, decl_span: Span) void {
        const name_text = self.ast.source[name_span.start..name_span.end];

        // function_decl의 스코핑 규칙:
        // - var scope(global/function/module) 안에서 직접 선언: var scope에 등록 (호이스팅)
        // - 블록 스코프 안에서 선언: 블록 스코프에 등록 (ECMAScript B.3.2, 13.2.14)
        //   블록 안의 function은 LexicallyDeclaredNames에 포함되어 let/const와 충돌 감지
        const target_scope = if (kind == .variable_var)
            self.findVarScope()
        else if (kind == .function_decl) blk: {
            // 현재 스코프가 var scope이면 그대로, 아니면 현재 블록 스코프에 등록
            if (!self.current_scope.isNone()) {
                const current = self.scopes.items[self.current_scope.toIndex()];
                if (!current.kind.isVarScope()) {
                    break :blk self.current_scope;
                }
            }
            break :blk self.findVarScope();
        } else self.current_scope;

        // 재선언 검증: 같은 스코프에서 같은 이름의 심볼이 있는지 확인
        if (self.findSymbolInScope(target_scope, name_text)) |existing| {
            if (!self.canRedeclare(existing.kind, kind)) {
                self.addError(decl_span, name_text);
                return;
            }
        }

        // var의 경우 블록 스코프 체인에서도 충돌 체크
        // let x; { var x; } → 에러 (var가 호이스팅되어 let과 같은 스코프에 도달)
        if (kind == .variable_var or kind == .function_decl) {
            if (self.checkVarHoistingConflict(target_scope, name_text, decl_span)) return;
        }

        self.symbols.append(.{
            .name = name_span,
            .scope_id = target_scope,
            .kind = kind,
            .declaration_span = decl_span,
        }) catch @panic("OOM: symbol list");

        if (!target_scope.isNone()) {
            self.scopes.items[target_scope.toIndex()].symbol_count += 1;
        }
    }

    /// 가장 가까운 var scope(function/global/module)를 찾는다.
    fn findVarScope(self: *const SemanticAnalyzer) ScopeId {
        var scope_id = self.current_scope;
        while (!scope_id.isNone()) {
            const scope = self.scopes.items[scope_id.toIndex()];
            if (scope.kind.isVarScope()) return scope_id;
            scope_id = scope.parent;
        }
        return self.current_scope; // fallback (shouldn't happen)
    }

    /// 특정 스코프에서 이름으로 심볼을 찾는다.
    /// TODO: O(N) 선형 스캔 → per-scope HashMap으로 개선 필요 (대규모 파일에서 O(N²))
    fn findSymbolInScope(self: *const SemanticAnalyzer, scope_id: ScopeId, name: []const u8) ?Symbol {
        for (self.symbols.items) |sym| {
            if (@intFromEnum(sym.scope_id) == @intFromEnum(scope_id)) {
                const sym_name = self.ast.source[sym.name.start..sym.name.end];
                if (std.mem.eql(u8, sym_name, name)) return sym;
            }
        }
        return null;
    }

    /// var 호이스팅이 블록 스코프의 let/const와 충돌하는지 체크.
    /// 예: let x = 1; { var x = 2; } → 에러 (var x가 함수 스코프로 호이스팅되면서 let x와 충돌)
    fn checkVarHoistingConflict(self: *SemanticAnalyzer, var_scope: ScopeId, name: []const u8, decl_span: Span) bool {
        // current_scope부터 var_scope까지의 중간 블록 스코프에서 let/const 선언을 찾는다
        var scope_id = self.current_scope;
        while (!scope_id.isNone() and @intFromEnum(scope_id) != @intFromEnum(var_scope)) {
            if (self.findSymbolInScope(scope_id, name)) |existing| {
                if (existing.kind.isBlockScoped()) {
                    self.addError(decl_span, name);
                    return true;
                }
            }
            scope_id = self.scopes.items[scope_id.toIndex()].parent;
        }
        return false;
    }

    /// 두 심볼 종류의 재선언 가능 여부를 판단한다.
    fn canRedeclare(self: *const SemanticAnalyzer, existing: SymbolKind, new: SymbolKind) bool {
        // import는 항상 재선언 불가
        if (existing == .import_binding) return false;

        // 기존이 재선언 가능(var/function)이고 새것도 재선언 가능이면 허용
        if (existing.allowsRedeclaration() and new.allowsRedeclaration()) return true;

        // parameter + var/function → 허용 (var/function이 parameter를 덮어씀)
        if (existing == .parameter and new.allowsRedeclaration()) return true;

        // parameter + parameter → non-strict에서만 허용 (function f(a, a) {})
        if (existing == .parameter and new == .parameter and !self.is_strict_mode) return true;

        // catch_binding + var → 허용 (var가 catch 스코프 밖으로 호이스팅)
        if (existing == .catch_binding and new == .variable_var) return true;

        // 그 외는 모두 에러
        return false;
    }

    // ================================================================
    // 에러 추가
    // ================================================================

    fn addError(self: *SemanticAnalyzer, span: Span, name: []const u8) void {
        self.addErrorMsg(span, std.fmt.allocPrint(self.allocator, "Identifier '{s}' has already been declared", .{name}) catch @panic("OOM"));
    }

    fn addPrivateNameError(self: *SemanticAnalyzer, span: Span, name: []const u8) void {
        self.addErrorMsg(span, std.fmt.allocPrint(self.allocator, "Private field '{s}' must be declared in an enclosing class", .{name}) catch @panic("OOM"));
    }

    fn addErrorMsg(self: *SemanticAnalyzer, span: Span, msg: []const u8) void {
        self.errors.append(.{
            .span = span,
            .message = msg,
        }) catch @panic("OOM: semantic error list");
    }

    // ================================================================
    // AST Visitor — switch 기반 (D042)
    // ================================================================

    fn visitNode(self: *SemanticAnalyzer, idx: NodeIndex) void {
        if (idx.isNone()) return;
        // 바운드 체크: 잘못된 인덱스 방어
        if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;

        const node = self.ast.getNode(idx);
        switch (node.tag) {
            // ---- 스코프 생성 노드 ----
            .program => self.visitProgram(node),
            .block_statement => self.visitBlockStatement(node),
            .function_declaration => self.visitFunctionDeclaration(node),
            .function_expression => self.visitFunctionExpression(node),
            .arrow_function_expression => self.visitArrowFunction(node),
            .class_declaration => self.visitClassDeclaration(node),
            .class_expression => self.visitClassExpression(node),
            .for_statement => self.visitForStatement(node),
            .for_in_statement => self.visitForInOf(node),
            .for_of_statement => self.visitForInOf(node),
            .switch_statement => self.visitSwitchStatement(node),
            .catch_clause => self.visitCatchClause(node),

            // ---- 선언 노드 ----
            .variable_declaration => self.visitVariableDeclaration(node),
            .import_declaration => self.visitImportDeclaration(node),

            // ---- 자식 순회만 필요한 노드 ----
            .expression_statement => self.visitNode(node.data.unary.operand),
            .return_statement => self.visitNode(node.data.unary.operand),
            .throw_statement => self.visitNode(node.data.unary.operand),
            .if_statement => {
                self.visitNode(node.data.ternary.a);
                self.visitNode(node.data.ternary.b);
                self.visitNode(node.data.ternary.c);
            },
            .while_statement, .do_while_statement => {
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },
            .labeled_statement, .with_statement => {
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },
            .switch_case => self.visitSwitchCase(node),
            .try_statement => self.visitTryStatement(node),
            .export_named_declaration => self.visitExportNamedDeclaration(node),
            .export_default_declaration => {
                // unary: { operand = declaration }
                self.visitNode(node.data.unary.operand);
            },

            // ---- private name 참조 ----
            .private_field_expression, .static_member_expression, .computed_member_expression => {
                // binary: { left = object, right = property }
                // right가 private_identifier이면 참조 등록
                const prop_idx = node.data.binary.right;
                if (!prop_idx.isNone() and @intFromEnum(prop_idx) < self.ast.nodes.items.len) {
                    const prop_node = self.ast.getNode(prop_idx);
                    if (prop_node.tag == .private_identifier) {
                        const name = self.ast.source[prop_node.span.start..prop_node.span.end];
                        self.usePrivateName(name, prop_node.span);
                    }
                }
                // object 쪽도 순회
                self.visitNode(node.data.binary.left);
            },

            // ---- method_definition/property_definition 내부 순회 ----
            .method_definition => {
                // extra: [key, params.start, params.len, body, flags]
                const extra_start = node.data.extra;
                const extras = self.ast.extra_data.items;
                if (extra_start + 3 < extras.len) {
                    const body_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);
                    // 함수 본문을 function scope로 감싸서 순회
                    const scope_saved = self.enterScope(.function, self.is_strict_mode);
                    const params_start = extras[extra_start + 1];
                    const params_len = extras[extra_start + 2];
                    self.registerParams(params_start, params_len);
                    self.visitFunctionBodyInner(body_idx);
                    self.exitScope(scope_saved);
                }
            },
            .property_definition => {
                // binary: { left = key, right = value }
                self.visitNode(node.data.binary.right);
            },
            .static_block => {
                // unary: { operand = body }
                self.visitNode(node.data.unary.operand);
            },

            // ---- 스킵 (TS 타입 노드, 리터럴, 식별자 등) ----
            else => {},
        }
    }

    fn visitNodeList(self: *SemanticAnalyzer, list: NodeList) void {
        if (list.len == 0) return;
        if (list.start + list.len > self.ast.extra_data.items.len) return; // 바운드 방어
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const idx: NodeIndex = @enumFromInt(raw_idx);
            self.visitNode(idx);
        }
    }

    // ================================================================
    // Visitor 구현 — 스코프 생성 노드
    // ================================================================

    fn visitProgram(self: *SemanticAnalyzer, node: Node) void {
        // module이면 module 스코프 (항상 strict), 아니면 global 스코프
        const scope_kind: ScopeKind = if (self.is_module) .module else .global;
        const saved = self.enterScope(scope_kind, self.is_strict_mode);
        self.visitNodeList(node.data.list);
        self.exitScope(saved);
    }

    fn visitBlockStatement(self: *SemanticAnalyzer, node: Node) void {
        const saved = self.enterScope(.block, self.is_strict_mode);
        self.visitNodeList(node.data.list);
        self.exitScope(saved);
    }

    fn visitFunctionDeclaration(self: *SemanticAnalyzer, node: Node) void {
        // extra: [name, params.start, params.len, body, flags, return_type]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 5 >= extras.len) return;
        const name_idx: NodeIndex = @enumFromInt(extras[extra_start]);
        const body_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);

        // 함수 이름을 현재 스코프(외부)에 등록
        if (!name_idx.isNone()) {
            const name_node = self.ast.getNode(name_idx);
            self.declareSymbol(name_node.span, .function_decl, node.span);
        }

        // 함수 본문 — 새 function 스코프 (부모의 strict mode 상속)
        const saved = self.enterScope(.function, self.is_strict_mode);

        // 파라미터를 function 스코프에 등록
        const params_start = extras[extra_start + 1];
        const params_len = extras[extra_start + 2];
        self.registerParams(params_start, params_len);

        // 본문 순회 (block_statement가 또 스코프를 만들지만, function body는 이미 function 스코프)
        self.visitFunctionBodyInner(body_idx);
        self.exitScope(saved);
    }

    fn visitFunctionExpression(self: *SemanticAnalyzer, node: Node) void {
        // extra: [name, params.start, params.len, body, flags]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 4 >= extras.len) return;
        const body_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);

        const saved = self.enterScope(.function, self.is_strict_mode);

        // 함수 표현식의 이름은 자체 스코프에만 등록 (외부에서 접근 불가)
        const name_idx: NodeIndex = @enumFromInt(extras[extra_start]);
        if (!name_idx.isNone()) {
            const name_node = self.ast.getNode(name_idx);
            self.declareSymbol(name_node.span, .function_decl, node.span);
        }

        const params_start = extras[extra_start + 1];
        const params_len = extras[extra_start + 2];
        self.registerParams(params_start, params_len);

        self.visitFunctionBodyInner(body_idx);
        self.exitScope(saved);
    }

    fn visitArrowFunction(self: *SemanticAnalyzer, node: Node) void {
        // binary: { left = param/params, right = body, flags }
        const saved = self.enterScope(.function, self.is_strict_mode);
        const body_idx = node.data.binary.right;

        // left가 단일 파라미터(binding_identifier) 또는 파라미터 리스트일 수 있음
        const param_idx = node.data.binary.left;
        if (!param_idx.isNone()) {
            const param_node = self.ast.getNode(param_idx);
            if (param_node.tag == .binding_identifier) {
                self.declareSymbol(param_node.span, .parameter, param_node.span);
            }
            // parenthesized_expression인 경우 파라미터 추출은 복잡 — 추후 구현
        }

        if (!body_idx.isNone()) {
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .block_statement) {
                // block body — 내부를 직접 순회 (block_statement가 스코프를 또 만들지 않도록)
                self.visitNodeList(body_node.data.list);
            } else {
                // expression body
                self.visitNode(body_idx);
            }
        }

        self.exitScope(saved);
    }

    fn visitClassDeclaration(self: *SemanticAnalyzer, node: Node) void {
        // extra: [name, super_class, body, ...]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        const name_idx: NodeIndex = @enumFromInt(extras[extra_start]);

        // 클래스 이름을 현재 스코프(외부)에 등록
        if (!name_idx.isNone()) {
            const name_node = self.ast.getNode(name_idx);
            self.declareSymbol(name_node.span, .class_decl, node.span);
        }

        self.visitClassBodyNode(@enumFromInt(extras[extra_start + 2]));
    }

    fn visitClassExpression(self: *SemanticAnalyzer, node: Node) void {
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        self.visitClassBodyNode(@enumFromInt(extras[extra_start + 2]));
    }

    /// class body를 스코프로 감싸서 순회한다.
    /// private name 수집/검증도 여기서 처리 (oxc 방식).
    fn visitClassBodyNode(self: *SemanticAnalyzer, body_idx: NodeIndex) void {
        // class body는 항상 strict mode (ECMAScript 10.2.1)
        const saved = self.enterScope(.class_body, true);
        self.pushClassScope();

        if (!body_idx.isNone() and @intFromEnum(body_idx) < self.ast.nodes.items.len) {
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .class_body) {
                // 1차: private name 선언 수집 (멤버 순회)
                self.collectPrivateNames(body_node.data.list);
                // 2차: 전체 순회 (참조 검증 포함)
                self.visitNodeList(body_node.data.list);
            }
        }

        self.popClassScope();
        self.exitScope(saved);
    }

    /// class body 멤버에서 private name 선언을 수집한다 (1차 패스).
    fn collectPrivateNames(self: *SemanticAnalyzer, list: NodeList) void {
        if (list.len == 0) return;
        if (list.start + list.len > self.ast.extra_data.items.len) return;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            const idx: NodeIndex = @enumFromInt(raw_idx);
            if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
            const node = self.ast.getNode(idx);
            switch (node.tag) {
                .method_definition => {
                    // extra: [key, params.start, params.len, body, flags]
                    const extra_start = node.data.extra;
                    if (extra_start >= self.ast.extra_data.items.len) continue;
                    const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra_start]);
                    self.tryRegisterPrivateKey(key_idx);
                },
                .property_definition => {
                    // binary: { left = key, right = value, flags }
                    self.tryRegisterPrivateKey(node.data.binary.left);
                },
                else => {},
            }
        }
    }

    /// key가 private_identifier이면 선언 등록한다.
    fn tryRegisterPrivateKey(self: *SemanticAnalyzer, key_idx: NodeIndex) void {
        if (key_idx.isNone() or @intFromEnum(key_idx) >= self.ast.nodes.items.len) return;
        const key_node = self.ast.getNode(key_idx);
        if (key_node.tag == .private_identifier) {
            const name = self.ast.source[key_node.span.start..key_node.span.end];
            self.declarePrivateName(name, key_node.span);
        }
    }

    fn visitForStatement(self: *SemanticAnalyzer, node: Node) void {
        // extra: [init, test, update, body]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 3 >= extras.len) return;

        // for문은 블록 스코프를 생성 (for(let i=0; ...) 의 i가 블록 스코프)
        const saved = self.enterScope(.block, self.is_strict_mode);
        self.visitNode(@enumFromInt(extras[extra_start])); // init
        self.visitNode(@enumFromInt(extras[extra_start + 1])); // test
        self.visitNode(@enumFromInt(extras[extra_start + 2])); // update
        self.visitNode(@enumFromInt(extras[extra_start + 3])); // body
        self.exitScope(saved);
    }

    fn visitForInOf(self: *SemanticAnalyzer, node: Node) void {
        // ternary: { a = left, b = right, c = body }
        const saved = self.enterScope(.block, self.is_strict_mode);
        self.visitNode(node.data.ternary.a);
        self.visitNode(node.data.ternary.b);
        self.visitNode(node.data.ternary.c);
        self.exitScope(saved);
    }

    fn visitSwitchStatement(self: *SemanticAnalyzer, node: Node) void {
        // extra: [discriminant, cases.start, cases.len]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        self.visitNode(@enumFromInt(extras[extra_start])); // discriminant

        // switch body는 하나의 블록 스코프 (모든 case가 같은 스코프)
        const saved = self.enterScope(.switch_block, self.is_strict_mode);
        const cases_start = extras[extra_start + 1];
        const cases_len = extras[extra_start + 2];
        const case_list = NodeList{ .start = cases_start, .len = cases_len };
        self.visitNodeList(case_list);
        self.exitScope(saved);
    }

    fn visitCatchClause(self: *SemanticAnalyzer, node: Node) void {
        // binary: { left = param, right = body, flags }
        const saved = self.enterScope(.catch_clause, self.is_strict_mode);
        const param_idx = node.data.binary.left;
        if (!param_idx.isNone()) {
            const param_node = self.ast.getNode(param_idx);
            if (param_node.tag == .binding_identifier) {
                self.declareSymbol(param_node.span, .catch_binding, param_node.span);
            }
        }
        self.visitNode(node.data.binary.right); // body
        self.exitScope(saved);
    }

    fn visitSwitchCase(self: *SemanticAnalyzer, node: Node) void {
        // extra: [test_expr, body.start, body.len]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;
        // test_expr은 순회 불필요 (리터럴/식별자)
        const body_start = extras[extra_start + 1];
        const body_len = extras[extra_start + 2];
        self.visitNodeList(.{ .start = body_start, .len = body_len });
    }

    fn visitTryStatement(self: *SemanticAnalyzer, node: Node) void {
        // ternary: { a = try_block, b = catch_clause, c = finally_block }
        self.visitNode(node.data.ternary.a);
        self.visitNode(node.data.ternary.b);
        self.visitNode(node.data.ternary.c);
    }

    // ================================================================
    // Visitor 구현 — 선언 노드
    // ================================================================

    fn visitVariableDeclaration(self: *SemanticAnalyzer, node: Node) void {
        // extra: [kind_flags, declarators.start, declarators.len]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return; // 바운드 방어
        const kind_flags = extras[extra_start];
        const decl_start = extras[extra_start + 1];
        const decl_len = extras[extra_start + 2];

        const sym_kind: SymbolKind = switch (kind_flags) {
            0 => .variable_var,
            1 => .variable_let,
            2 => .variable_const,
            else => .variable_var,
        };

        // 각 declarator에서 바인딩 이름 추출
        // variable_declarator의 data는 extra: [name, type_ann, init_expr]
        const decl_indices = self.ast.extra_data.items[decl_start .. decl_start + decl_len];
        for (decl_indices) |raw_idx| {
            const decl_idx: NodeIndex = @enumFromInt(raw_idx);
            if (decl_idx.isNone()) continue;
            const decl_node = self.ast.getNode(decl_idx);
            if (decl_node.tag == .variable_declarator) {
                // extra: [name, type_ann, init_expr]
                const decl_extra = decl_node.data.extra;
                const decl_extras = self.ast.extra_data.items;
                const binding_idx: NodeIndex = @enumFromInt(decl_extras[decl_extra]);
                const init_idx: NodeIndex = @enumFromInt(decl_extras[decl_extra + 2]);

                self.registerBinding(binding_idx, sym_kind);
                // init 표현식도 순회 (내부에 함수 표현식 등이 있을 수 있음)
                self.visitNode(init_idx);
            }
        }
    }

    fn visitImportDeclaration(self: *SemanticAnalyzer, node: Node) void {
        // side-effect import: flags=1 (import "module") — 바인딩 없음
        if (node.data.unary.flags == 1) return;

        // extra_data에서 specifiers 리스트 추출
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 2 >= extras.len) return;

        const specs_start = extras[extra_start];
        const specs_len = extras[extra_start + 1];
        if (specs_len == 0) return;
        if (specs_start + specs_len > extras.len) return;

        const spec_indices = extras[specs_start .. specs_start + specs_len];
        for (spec_indices) |raw_idx| {
            const spec_idx: NodeIndex = @enumFromInt(raw_idx);
            if (spec_idx.isNone()) continue;
            if (@intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;

            const spec_node = self.ast.getNode(spec_idx);
            switch (spec_node.tag) {
                .import_default_specifier => {
                    // string_ref — span 자체가 식별자 이름
                    self.declareSymbol(spec_node.span, .import_binding, spec_node.span);
                },
                .import_namespace_specifier => {
                    // string_ref — span 자체가 식별자 이름
                    self.declareSymbol(spec_node.span, .import_binding, spec_node.span);
                },
                .import_specifier => {
                    // binary: { left = imported, right = local } — local이 바인딩
                    const local_idx = spec_node.data.binary.right;
                    if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                        const local_node = self.ast.getNode(local_idx);
                        self.declareSymbol(local_node.span, .import_binding, spec_node.span);
                    }
                },
                else => {},
            }
        }
    }

    fn visitExportNamedDeclaration(self: *SemanticAnalyzer, node: Node) void {
        // extra: [declaration, specifiers_start, specifiers_len, source]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 3 >= extras.len) return;
        const decl_idx: NodeIndex = @enumFromInt(extras[extra_start]);
        self.visitNode(decl_idx);
    }

    // ================================================================
    // 헬퍼
    // ================================================================

    /// 바인딩 패턴에서 이름을 추출하여 심볼로 등록한다.
    /// 단순 식별자, 배열 패턴, 객체 패턴을 재귀적으로 처리.
    fn registerBinding(self: *SemanticAnalyzer, idx: NodeIndex, kind: SymbolKind) void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .binding_identifier => {
                self.declareSymbol(node.span, kind, node.span);
            },
            .array_pattern => {
                // list of elements
                self.registerBindingList(node.data.list, kind);
            },
            .object_pattern => {
                // list of binding_property
                self.registerBindingList(node.data.list, kind);
            },
            .binding_property => {
                // binary: { left = key, right = value }
                self.registerBinding(node.data.binary.right, kind);
            },
            .assignment_pattern => {
                // binary: { left = binding, right = default_value }
                self.registerBinding(node.data.binary.left, kind);
            },
            .binding_rest_element, .rest_element => {
                // unary: { operand = binding }
                self.registerBinding(node.data.unary.operand, kind);
            },
            else => {},
        }
    }

    fn registerBindingList(self: *SemanticAnalyzer, list: NodeList, kind: SymbolKind) void {
        if (list.len == 0) return;
        if (list.start + list.len > self.ast.extra_data.items.len) return;
        const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
        for (indices) |raw_idx| {
            self.registerBinding(@enumFromInt(raw_idx), kind);
        }
    }

    /// 함수 파라미터를 현재 스코프에 등록한다.
    fn registerParams(self: *SemanticAnalyzer, params_start: u32, params_len: u32) void {
        if (params_len == 0) return;
        if (params_start + params_len > self.ast.extra_data.items.len) return;
        const param_indices = self.ast.extra_data.items[params_start .. params_start + params_len];
        for (param_indices) |raw_idx| {
            self.registerBinding(@enumFromInt(raw_idx), .parameter);
        }
    }

    /// 함수 본문 내부를 순회한다 (block_statement의 스코프 중복 생성 방지).
    fn visitFunctionBodyInner(self: *SemanticAnalyzer, body_idx: NodeIndex) void {
        if (body_idx.isNone()) return;
        const body_node = self.ast.getNode(body_idx);
        if (body_node.tag == .block_statement) {
            // function 스코프가 이미 생성되었으므로 block_statement의 내용만 순회
            self.visitNodeList(body_node.data.list);
        } else {
            self.visitNode(body_idx);
        }
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("../parser/parser.zig").Parser;
const Scanner = @import("../lexer/scanner.zig").Scanner;

test "SemanticAnalyzer: var declaration creates symbol" {
    var scanner = Scanner.init(std.testing.allocator, "var x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.symbols.items.len == 1);
    try std.testing.expectEqual(SymbolKind.variable_var, ana.symbols.items[0].kind);
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: let redeclaration is error" {
    var scanner = Scanner.init(std.testing.allocator, "let x = 1; let x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: var redeclaration is allowed" {
    var scanner = Scanner.init(std.testing.allocator, "var x = 1; var x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: function declaration creates symbol" {
    var scanner = Scanner.init(std.testing.allocator, "function foo() {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.symbols.items.len >= 1);
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: scopes are created" {
    var scanner = Scanner.init(std.testing.allocator, "{ let x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    // global + block = 최소 2개 스코프
    try std.testing.expect(ana.scopes.items.len >= 2);
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: let and var conflict is error" {
    var scanner = Scanner.init(std.testing.allocator, "let x = 1; var x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: const redeclaration is error" {
    var scanner = Scanner.init(std.testing.allocator, "const x = 1; const x = 2;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}
