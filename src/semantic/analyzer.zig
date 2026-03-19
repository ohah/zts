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

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) SemanticAnalyzer {
        return .{
            .ast = ast,
            .scopes = std.ArrayList(Scope).init(allocator),
            .symbols = std.ArrayList(Symbol).init(allocator),
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
    // 심볼 등록 + 재선언 검증
    // ================================================================

    /// 심볼을 현재 스코프에 등록한다.
    /// var는 가장 가까운 var scope(function/global/module)에 등록.
    /// let/const/class는 현재 블록 스코프에 등록.
    /// 중복 선언이면 에러를 추가한다.
    fn declareSymbol(self: *SemanticAnalyzer, name_span: Span, kind: SymbolKind, decl_span: Span) void {
        // var는 호이스팅 — 가장 가까운 var scope까지 올라감
        const target_scope = if (kind == .variable_var or kind == .function_decl)
            self.findVarScope()
        else
            self.current_scope;

        // 재선언 검증: 같은 스코프에서 같은 이름의 심볼이 있는지 확인
        const name_text = self.ast.source[name_span.start..name_span.end];
        if (self.findSymbolInScope(target_scope, name_text)) |existing| {
            // 재선언 가능 여부 체크
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

        // 스코프의 심볼 카운트 증가
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
    fn canRedeclare(_: *const SemanticAnalyzer, existing: SymbolKind, new: SymbolKind) bool {
        // import는 항상 재선언 불가
        if (existing == .import_binding) return false;

        // 기존이 재선언 가능(var/function)이고 새것도 재선언 가능이면 허용
        if (existing.allowsRedeclaration() and new.allowsRedeclaration()) return true;

        // 그 외는 모두 에러
        return false;
    }

    // ================================================================
    // 에러 추가
    // ================================================================

    fn addError(self: *SemanticAnalyzer, span: Span, name: []const u8) void {
        const msg = std.fmt.allocPrint(self.allocator, "Identifier '{s}' has already been declared", .{name}) catch @panic("OOM: error message");
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
        // 프로그램은 global 스코프 (module이면 module 스코프)
        // 파서가 이미 strict mode를 설정했으므로 여기선 스코프 종류만 결정
        // TODO: module/script 구분은 파서의 is_module 플래그로 판단해야 함
        const saved = self.enterScope(.global, false);
        self.visitNodeList(node.data.list);
        self.exitScope(saved);
    }

    fn visitBlockStatement(self: *SemanticAnalyzer, node: Node) void {
        const saved = self.enterScope(.block, false);
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

        // 함수 본문 — 새 function 스코프
        const saved = self.enterScope(.function, false);

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

        const saved = self.enterScope(.function, false);

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
        const saved = self.enterScope(.function, false);
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
    fn visitClassBodyNode(self: *SemanticAnalyzer, body_idx: NodeIndex) void {
        const saved = self.enterScope(.class_body, false);
        if (!body_idx.isNone() and @intFromEnum(body_idx) < self.ast.nodes.items.len) {
            const body_node = self.ast.getNode(body_idx);
            if (body_node.tag == .class_body) {
                self.visitNodeList(body_node.data.list);
            }
        }
        self.exitScope(saved);
    }

    fn visitForStatement(self: *SemanticAnalyzer, node: Node) void {
        // extra: [init, test, update, body]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 3 >= extras.len) return;

        // for문은 블록 스코프를 생성 (for(let i=0; ...) 의 i가 블록 스코프)
        const saved = self.enterScope(.block, false);
        self.visitNode(@enumFromInt(extras[extra_start])); // init
        self.visitNode(@enumFromInt(extras[extra_start + 1])); // test
        self.visitNode(@enumFromInt(extras[extra_start + 2])); // update
        self.visitNode(@enumFromInt(extras[extra_start + 3])); // body
        self.exitScope(saved);
    }

    fn visitForInOf(self: *SemanticAnalyzer, node: Node) void {
        // ternary: { a = left, b = right, c = body }
        const saved = self.enterScope(.block, false);
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
        const saved = self.enterScope(.switch_block, false);
        const cases_start = extras[extra_start + 1];
        const cases_len = extras[extra_start + 2];
        const case_list = NodeList{ .start = cases_start, .len = cases_len };
        self.visitNodeList(case_list);
        self.exitScope(saved);
    }

    fn visitCatchClause(self: *SemanticAnalyzer, node: Node) void {
        // binary: { left = param, right = body, flags }
        const saved = self.enterScope(.catch_clause, false);
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
        // import 선언의 extra 구조가 경로에 따라 다름 (side-effect, default, namespace, named).
        // side-effect import (import "module")는 unary 형태로 extra가 없음.
        // 나머지는 extra: [specifiers.start, specifiers.len, source] 구조.
        // TODO: import 바인딩 심볼 등록은 extra 구조 정규화 후 구현
        _ = self;
        _ = node;
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
