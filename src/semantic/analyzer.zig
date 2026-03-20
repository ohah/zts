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

    /// module의 exported name 추적 (중복 export 검사).
    /// key: 내보낸 이름 (default 포함), value: 첫 선언의 span.
    exported_names: std.StringHashMap(Span),

    /// class private name 스택 (중첩 class 지원, oxc 방식).
    /// 각 항목은 해당 class body에서 선언된 private name 집합.
    class_private_declared: std.ArrayList(std.StringHashMap(PrivateNameInfo)),

    /// class private name 참조 스택.
    /// 각 항목은 해당 class body에서 참조된 private name 목록 (검증 대기).
    class_private_refs: std.ArrayList(std.ArrayList(PrivateRef)),

    /// label 스택. labeled statement 진입 시 push, 퇴장 시 pop.
    /// 함수 경계에서 saved_label_len으로 저장/복원 (label은 함수를 넘지 못함).
    labels: std.ArrayList(LabelEntry) = undefined,

    const PrivateRef = struct {
        name: []const u8,
        span: Span,
    };

    /// private name의 종류 (중복 검사에서 getter+setter 쌍을 허용하기 위해 구분).
    const PrivateNameKind = enum {
        field,
        method,
        getter,
        setter,
    };

    /// private name 선언 정보 (span + kind).
    const PrivateNameInfo = struct {
        span: Span,
        kind: PrivateNameKind,
    };

    const LabelEntry = struct {
        name: []const u8,
        span: Span,
        is_loop: bool,
    };

    pub fn init(allocator: std.mem.Allocator, ast: *const Ast) SemanticAnalyzer {
        return .{
            .ast = ast,
            .scopes = std.ArrayList(Scope).init(allocator),
            .symbols = std.ArrayList(Symbol).init(allocator),
            .exported_names = std.StringHashMap(Span).init(allocator),
            .class_private_declared = std.ArrayList(std.StringHashMap(PrivateNameInfo)).init(allocator),
            .class_private_refs = std.ArrayList(std.ArrayList(PrivateRef)).init(allocator),
            .labels = std.ArrayList(LabelEntry).init(allocator),
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
        self.exported_names.deinit();
        self.labels.deinit();
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

    // ================================================================
    // Label 관리
    // ================================================================

    /// label 스택의 현재 길이를 저장한다. 함수 경계에서 복원용.
    fn saveLabelLen(self: *const SemanticAnalyzer) usize {
        return self.labels.items.len;
    }

    /// label 스택을 저장된 길이로 복원한다.
    fn restoreLabelLen(self: *SemanticAnalyzer, saved: usize) void {
        self.labels.shrinkRetainingCapacity(saved);
    }

    /// label 이름으로 검색한다. 없으면 null.
    fn findLabel(self: *const SemanticAnalyzer, name: []const u8) ?LabelEntry {
        var i = self.labels.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.labels.items[i].name, name)) {
                return self.labels.items[i];
            }
        }
        return null;
    }

    /// 현재 스코프가 strict mode인지 확인한다.
    fn isCurrentStrict(self: *const SemanticAnalyzer) bool {
        if (self.is_strict_mode or self.is_module) return true;
        if (!self.current_scope.isNone()) {
            return self.scopes.items[self.current_scope.toIndex()].is_strict;
        }
        return false;
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
        self.class_private_declared.append(std.StringHashMap(PrivateNameInfo).init(self.allocator)) catch @panic("OOM");
        self.class_private_refs.append(std.ArrayList(PrivateRef).init(self.allocator)) catch @panic("OOM");
    }

    /// class body 퇴장 시 private name 참조를 검증하고 pop한다.
    fn popClassScope(self: *SemanticAnalyzer) void {
        if (self.class_private_declared.items.len == 0) return;

        var declared = self.class_private_declared.pop() orelse return;
        defer declared.deinit();
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
    }

    /// private name을 현재 class scope에 선언 등록한다.
    fn declarePrivateName(self: *SemanticAnalyzer, name: []const u8, span: Span, kind: PrivateNameKind) void {
        if (self.class_private_declared.items.len == 0) return;
        var current = &self.class_private_declared.items[self.class_private_declared.items.len - 1];

        if (current.get(name)) |existing| {
            // getter+setter 쌍은 허용 (순서 무관)
            const is_accessor_pair = (existing.kind == .getter and kind == .setter) or
                (existing.kind == .setter and kind == .getter);
            if (!is_accessor_pair) {
                self.addErrorMsg(span, std.fmt.allocPrint(
                    self.allocator,
                    "Private field '{s}' has already been declared",
                    .{name},
                ) catch @panic("OOM"));
                return;
            }
        }
        current.put(name, .{ .span = span, .kind = kind }) catch @panic("OOM");
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

        // function-like 선언의 스코핑 규칙:
        // - var scope(global/function/module) 안에서 직접 선언: var scope에 등록 (호이스팅)
        // - 블록 스코프 안에서 선언: 블록 스코프에 등록 (ECMAScript B.3.2, 13.2.14)
        //   블록 안의 function/generator/async function은 LexicallyDeclaredNames에 포함
        const target_scope = if (kind == .variable_var)
            self.findVarScope()
        else if (kind.isFunctionLike()) blk: {
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
            if (!self.canRedeclare(existing.kind, kind, target_scope)) {
                self.addError(decl_span, name_text);
                return;
            }
        }

        // var/function-like의 경우 블록 스코프 체인에서도 충돌 체크
        // let x; { var x; } → 에러 (var가 호이스팅되어 let과 같은 스코프에 도달)
        if (kind == .variable_var or kind.isFunctionLike()) {
            if (self.checkVarHoistingConflict(target_scope, name_text, decl_span)) return;
        }

        // 역방향: let/const/class/function-like 선언 시,
        // 같은 block 경로에서 선언된 var가 있으면 충돌 (LexicallyDeclaredNames ∩ VarDeclaredNames)
        // { var f; let f; } → 에러, but { let f; } 밖의 var f → 충돌 아님
        if (kind.isBlockScoped() or (kind.isFunctionLike() and !target_scope.isNone() and
            !self.scopes.items[target_scope.toIndex()].kind.isVarScope()))
        {
            if (self.checkLexicalVarConflict(target_scope, name_text, decl_span)) return;
        }

        self.symbols.append(.{
            .name = name_span,
            .scope_id = target_scope,
            .kind = kind,
            .decl_flags = kind.declFlags(),
            .declaration_span = decl_span,
            .origin_scope = self.current_scope,
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
                // block scope의 let/const/class와 충돌하거나,
                // block scope의 function-like 선언과도 충돌
                if (existing.kind.isBlockScoped() or existing.kind.isFunctionLike()) {
                    self.addError(decl_span, name);
                    return true;
                }
            }
            scope_id = self.scopes.items[scope_id.toIndex()].parent;
        }
        return false;
    }

    /// 두 심볼 종류의 재선언 가능 여부를 판단한다.
    /// target_scope: 심볼이 등록되는 대상 스코프 (block/var scope 구분에 필요)
    /// let/const/class/function-like 선언 시, 같은 block 경로에서 선언된 var가 있으면 충돌.
    /// origin_scope를 사용하여 var가 실제로 현재 scope 경로에서 선언되었는지 확인.
    /// ECMAScript: "LexicallyDeclaredNames ∩ VarDeclaredNames of StatementList"
    fn checkLexicalVarConflict(self: *SemanticAnalyzer, lexical_scope: ScopeId, name: []const u8, decl_span: Span) bool {
        const var_scope = self.findVarScope();
        // var scope에서 같은 이름의 var를 찾는다
        for (self.symbols.items) |sym| {
            if (@intFromEnum(sym.scope_id) != @intFromEnum(var_scope)) continue;
            if (sym.kind != .variable_var) continue;
            const sym_name = self.ast.source[sym.name.start..sym.name.end];
            if (!std.mem.eql(u8, sym_name, name)) continue;

            // var의 origin_scope가 현재 lexical_scope의 ancestor 경로에 있는지 확인
            // { var f; let f; } → var의 origin=block, let의 scope=block → 같으므로 충돌
            // { { var f; } let f; } → var의 origin=inner, let의 scope=outer → inner는 outer의 자식이므로 충돌
            // { let f; } 밖의 var f → var의 origin=global, let의 scope=block → 충돌 아님
            if (self.isScopeDescendantOf(sym.origin_scope, lexical_scope)) {
                self.addError(decl_span, name);
                return true;
            }
        }
        return false;
    }

    /// child_scope가 parent_scope와 같거나 그 자손인지 확인한다.
    /// child가 parent와 같거나 그 자손인지 확인한다 (scope chain 순회).
    fn isScopeDescendantOf(self: *const SemanticAnalyzer, child: ScopeId, parent: ScopeId) bool {
        var scope_id = child;
        while (!scope_id.isNone()) {
            if (@intFromEnum(scope_id) == @intFromEnum(parent)) return true;
            scope_id = self.scopes.items[scope_id.toIndex()].parent;
        }
        return false;
    }

    /// 두 심볼 종류의 재선언 가능 여부를 판단한다.
    /// DeclFlags.excludes() 비트마스크를 사용하여 O(1) 판단 후, 특수 규칙만 추가 체크.
    fn canRedeclare(self: *const SemanticAnalyzer, existing: SymbolKind, new: SymbolKind, target_scope: ScopeId) bool {
        const existing_flags = existing.declFlags();
        const new_flags = new.declFlags();

        // 기본 규칙: 비트플래그 excludes로 충돌 판단
        // existing의 flags가 new의 excludes와 겹치면 재선언 불가
        if (existing_flags.intersects(new_flags.excludes())) {
            // 특수 케이스: parameter + parameter → non-strict에서 허용 (function f(a, a) {})
            if (existing == .parameter and new == .parameter and !self.is_strict_mode) {
                return true;
            }
            return false;
        }

        // module scope에서의 특별 규칙:
        // ECMAScript: "At the top level of a Module, function declarations are treated
        // like lexical declarations rather than like var declarations."
        // → function + function 재선언 불가
        // → var + function, function + var 충돌
        if (self.is_module and !target_scope.isNone()) {
            const scope = self.scopes.items[target_scope.toIndex()];
            if (scope.kind == .module) {
                // module top-level: function은 lexical → 같은 이름 재선언 불가
                if (existing.isFunctionLike() and new.isFunctionLike()) return false;
                if (existing.isFunctionLike() and new == .variable_var) return false;
                if (existing == .variable_var and new.isFunctionLike()) return false;
            }
        }

        // block scope에서의 특별 규칙:
        // function + function → sloppy mode block에서만 허용 (ECMAScript B.3.2)
        // strict mode block에서는 duplicate lexical → 에러
        const in_block_scope = if (!target_scope.isNone()) blk: {
            break :blk !self.scopes.items[target_scope.toIndex()].kind.isVarScope();
        } else false;

        if (in_block_scope and existing.isFunctionLike() and new.isFunctionLike()) {
            // 양쪽 다 plain function이고 sloppy mode일 때만 허용
            if (existing == .function_decl and new == .function_decl and !self.isCurrentStrict()) {
                return true;
            }
            return false;
        }

        return true;
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
            .labeled_statement => self.visitLabeledStatement(node),
            .break_statement, .continue_statement => self.visitBreakContinue(node),
            .with_statement => {
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },
            .switch_case => self.visitSwitchCase(node),
            .try_statement => self.visitTryStatement(node),
            .export_named_declaration => self.visitExportNamedDeclaration(node),
            .export_default_declaration => self.visitExportDefaultDeclaration(node),
            .export_all_declaration => self.visitExportAllDeclaration(node),

            // ---- private name 참조 ----
            .private_field_expression, .static_member_expression => {
                // binary: { left = object, right = identifier/private_identifier }
                const prop_idx = node.data.binary.right;
                if (!prop_idx.isNone() and @intFromEnum(prop_idx) < self.ast.nodes.items.len) {
                    const prop_node = self.ast.getNode(prop_idx);
                    if (prop_node.tag == .private_identifier) {
                        const name = self.ast.source[prop_node.span.start..prop_node.span.end];
                        self.usePrivateName(name, prop_node.span);
                    }
                }
                self.visitNode(node.data.binary.left);
            },
            .computed_member_expression => {
                // binary: { left = object, right = expression }
                // right는 임의 expression (a[expr]) — 양쪽 모두 순회
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },

            // ---- method_definition/property_definition 내부 순회 ----
            .method_definition => {
                // extra: [key, params.start, params.len, body, flags]
                const extra_start = node.data.extra;
                const extras = self.ast.extra_data.items;
                if (extra_start + 3 < extras.len) {
                    // key 순회 — 객체 리터럴의 private name 메서드 검출에 필요
                    // (class body에서는 collectPrivateNames가 이미 선언을 등록하므로
                    //  여기서 usePrivateName이 호출되어도 정상 통과)
                    const key_idx: NodeIndex = @enumFromInt(extras[extra_start]);
                    self.visitNode(key_idx);

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
                // key도 순회 (computed property의 표현식, class 밖 private name 검출)
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },
            .static_block => {
                // static block은 함수와 같은 경계 — label은 넘지 못함
                const saved_labels = self.saveLabelLen();
                self.visitNode(node.data.unary.operand);
                self.restoreLabelLen(saved_labels);
            },

            // ---- 일반 표현식 순회 (private name 참조 등을 위해) ----
            .assignment_expression,
            .binary_expression,
            .logical_expression,
            .conditional_expression,
            => {
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },
            .unary_expression,
            .update_expression,
            .yield_expression,
            .await_expression,
            .parenthesized_expression,
            .spread_element,
            => {
                self.visitNode(node.data.unary.operand);
            },
            .call_expression,
            .new_expression,
            => {
                // binary: { left = callee, right = @enumFromInt(args_start), flags = args_len }
                // callee 순회
                self.visitNode(node.data.binary.left);
                // 인자 순회 — right를 extra_data 시작 인덱스, flags를 길이로 사용
                const args_start = @intFromEnum(node.data.binary.right);
                const args_len = node.data.binary.flags & 0x7FFF; // 상위 비트는 optional 플래그
                if (args_len > 0 and args_start + args_len <= self.ast.extra_data.items.len) {
                    const arg_indices = self.ast.extra_data.items[args_start .. args_start + args_len];
                    for (arg_indices) |raw_idx| {
                        self.visitNode(@enumFromInt(raw_idx));
                    }
                }
            },
            .tagged_template_expression => {
                // binary: { left = tag, right = template, flags = 0 }
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },
            .sequence_expression => {
                self.visitNodeList(node.data.list);
            },
            .array_expression => {
                self.visitNodeList(node.data.list);
            },
            .object_expression => {
                self.visitNodeList(node.data.list);
            },
            .object_property => {
                // binary: { left = key, right = value }
                // key도 순회 (computed property에 표현식이 들어갈 수 있음)
                self.visitNode(node.data.binary.left);
                self.visitNode(node.data.binary.right);
            },
            .template_literal => {
                // list: [template_element, expression, template_element, ...]
                // 표현식 내부에 private name 참조 등이 있을 수 있으므로 순회
                self.visitNodeList(node.data.list);
            },

            // ---- private_identifier 단독 노드 ----
            // method_definition/property_definition의 key로 직접 방문될 수 있음
            // class body 안이면 collectPrivateNames가 선언을 등록했으므로 usePrivateName 통과,
            // class 밖이면 에러 보고
            .private_identifier => {
                const name = self.ast.source[node.span.start..node.span.end];
                self.usePrivateName(name, node.span);
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
        const flags = extras[extra_start + 4];

        // flags에서 async/generator 판별하여 적절한 SymbolKind 결정
        const FnFlags = ast_mod.FunctionFlags;
        const is_async = (flags & FnFlags.is_async) != 0;
        const is_generator = (flags & FnFlags.is_generator) != 0;
        const symbol_kind: SymbolKind = if (is_async and is_generator)
            .async_generator_decl
        else if (is_async)
            .async_function_decl
        else if (is_generator)
            .generator_decl
        else
            .function_decl;

        // 함수 이름을 현재 스코프(외부)에 등록
        if (!name_idx.isNone()) {
            const name_node = self.ast.getNode(name_idx);
            self.declareSymbol(name_node.span, symbol_kind, node.span);
        }

        // 함수 본문 — 새 function 스코프 (부모의 strict mode 상속)
        const saved = self.enterScope(.function, self.is_strict_mode);
        const saved_labels = self.saveLabelLen(); // label은 함수 경계를 넘지 못함

        // 파라미터를 function 스코프에 등록
        const params_start = extras[extra_start + 1];
        const params_len = extras[extra_start + 2];
        self.registerParams(params_start, params_len);

        // 본문 순회
        self.visitFunctionBodyInner(body_idx);
        self.restoreLabelLen(saved_labels);
        self.exitScope(saved);
    }

    fn visitFunctionExpression(self: *SemanticAnalyzer, node: Node) void {
        // extra: [name, params.start, params.len, body, flags]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 4 >= extras.len) return;
        const body_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);

        const saved = self.enterScope(.function, self.is_strict_mode);
        const saved_labels = self.saveLabelLen();

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
        self.restoreLabelLen(saved_labels);
        self.exitScope(saved);
    }

    fn visitArrowFunction(self: *SemanticAnalyzer, node: Node) void {
        // binary: { left = param/params, right = body, flags }
        const saved = self.enterScope(.function, self.is_strict_mode);
        const saved_labels = self.saveLabelLen();
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

        self.restoreLabelLen(saved_labels);
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
                    // flags는 extra_start + 4: 0x02=getter, 0x04=setter
                    const kind: PrivateNameKind = blk: {
                        if (extra_start + 4 < self.ast.extra_data.items.len) {
                            const flags = self.ast.extra_data.items[extra_start + 4];
                            if (flags & 0x02 != 0) break :blk .getter;
                            if (flags & 0x04 != 0) break :blk .setter;
                        }
                        break :blk .method;
                    };
                    self.tryRegisterPrivateKey(key_idx, kind);
                },
                .property_definition => {
                    // binary: { left = key, right = value, flags }
                    self.tryRegisterPrivateKey(node.data.binary.left, .field);
                },
                else => {},
            }
        }
    }

    /// key가 private_identifier이면 선언 등록한다.
    fn tryRegisterPrivateKey(self: *SemanticAnalyzer, key_idx: NodeIndex, kind: PrivateNameKind) void {
        if (key_idx.isNone() or @intFromEnum(key_idx) >= self.ast.nodes.items.len) return;
        const key_node = self.ast.getNode(key_idx);
        if (key_node.tag == .private_identifier) {
            const name = self.ast.source[key_node.span.start..key_node.span.end];
            self.declarePrivateName(name, key_node.span, kind);
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

    /// labeled statement: label 등록 → body 순회 → label 해제.
    fn visitLabeledStatement(self: *SemanticAnalyzer, node: Node) void {
        // binary: { left = label identifier, right = body }
        const label_idx = node.data.binary.left;
        const body_idx = node.data.binary.right;

        if (!label_idx.isNone()) {
            const label_node = self.ast.getNode(label_idx);
            const name = self.ast.source[label_node.span.start..label_node.span.end];

            // 중복 label 체크 (같은 label 이름이 현재 스택에 있으면 에러)
            if (self.findLabel(name) != null) {
                self.addErrorMsg(label_node.span, std.fmt.allocPrint(self.allocator, "Label '{s}' has already been declared", .{name}) catch @panic("OOM"));
            }

            // body가 loop인지 판별 (continue label에 필요)
            const is_loop = if (!body_idx.isNone()) blk: {
                const body_tag = self.ast.getNode(body_idx).tag;
                break :blk body_tag == .for_statement or body_tag == .for_in_statement or
                    body_tag == .for_of_statement or body_tag == .while_statement or
                    body_tag == .do_while_statement;
            } else false;

            self.labels.append(.{ .name = name, .span = label_node.span, .is_loop = is_loop }) catch @panic("OOM");
            self.visitNode(body_idx);
            _ = self.labels.pop();
        } else {
            self.visitNode(body_idx);
        }
    }

    /// break/continue with label: label 존재 여부 + continue는 loop label만 가능.
    fn visitBreakContinue(self: *SemanticAnalyzer, node: Node) void {
        // unary: { operand = label identifier or none }
        const label_idx = node.data.unary.operand;
        if (label_idx.isNone()) return; // label 없는 break/continue는 파서에서 이미 검증

        const label_node = self.ast.getNode(label_idx);
        const name = self.ast.source[label_node.span.start..label_node.span.end];

        if (self.findLabel(name)) |entry| {
            // continue는 loop label만 가능
            if (node.tag == .continue_statement and !entry.is_loop) {
                self.addErrorMsg(label_node.span, std.fmt.allocPrint(self.allocator, "Cannot continue to non-loop label '{s}'", .{name}) catch @panic("OOM"));
            }
        } else {
            // label이 존재하지 않음
            self.addErrorMsg(label_node.span, std.fmt.allocPrint(self.allocator, "Undefined label '{s}'", .{name}) catch @panic("OOM"));
        }
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
                    self.checkStrictBindingName(spec_node.span);
                    self.declareSymbol(spec_node.span, .import_binding, spec_node.span);
                },
                .import_namespace_specifier => {
                    // string_ref — span 자체가 식별자 이름
                    self.checkStrictBindingName(spec_node.span);
                    self.declareSymbol(spec_node.span, .import_binding, spec_node.span);
                },
                .import_specifier => {
                    // binary: { left = imported, right = local } — local이 바인딩
                    const local_idx = spec_node.data.binary.right;
                    if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                        const local_node = self.ast.getNode(local_idx);
                        self.checkStrictBindingName(local_node.span);
                        self.declareSymbol(local_node.span, .import_binding, spec_node.span);
                    }
                },
                else => {},
            }
        }
    }

    /// strict mode에서 eval/arguments를 바인딩 이름으로 사용할 수 없다.
    /// module code는 항상 strict mode.
    fn checkStrictBindingName(self: *SemanticAnalyzer, span: Span) void {
        if (!self.isCurrentStrict()) return;
        const name = self.ast.source[span.start..span.end];
        if (std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments")) {
            self.addErrorMsg(span, std.fmt.allocPrint(
                self.allocator,
                "'{s}' cannot be used as a binding identifier in strict mode",
                .{name},
            ) catch @panic("OOM"));
        }
    }

    fn visitExportNamedDeclaration(self: *SemanticAnalyzer, node: Node) void {
        // extra: [declaration, specifiers_start, specifiers_len, source]
        const extra_start = node.data.extra;
        const extras = self.ast.extra_data.items;
        if (extra_start + 3 >= extras.len) return;
        const decl_idx: NodeIndex = @enumFromInt(extras[extra_start]);
        const specs_start = extras[extra_start + 1];
        const specs_len = extras[extra_start + 2];
        const source_idx: NodeIndex = @enumFromInt(extras[extra_start + 3]);

        // export { a, b as c } — specifier로 내보낸 이름 추적
        if (specs_len > 0 and specs_start + specs_len <= extras.len) {
            const spec_indices = extras[specs_start .. specs_start + specs_len];
            for (spec_indices) |raw_idx| {
                const spec_idx: NodeIndex = @enumFromInt(raw_idx);
                if (spec_idx.isNone() or @intFromEnum(spec_idx) >= self.ast.nodes.items.len) continue;
                const spec_node = self.ast.getNode(spec_idx);
                if (spec_node.tag == .export_specifier) {
                    // exported name = right (the "as" name, or same as local if no "as")
                    const exported_idx = spec_node.data.binary.right;
                    if (!exported_idx.isNone() and @intFromEnum(exported_idx) < self.ast.nodes.items.len) {
                        const exported_node = self.ast.getNode(exported_idx);
                        const name = self.ast.source[exported_node.span.start..exported_node.span.end];
                        // string literal은 따옴표 제거
                        const effective_name = if (name.len >= 2 and (name[0] == '\'' or name[0] == '"'))
                            name[1 .. name.len - 1]
                        else
                            name;
                        self.registerExportedName(effective_name, exported_node.span);
                    }

                    // source 없는 export { x } — local 바인딩이 존재하는지 검증 필요
                    if (source_idx.isNone() and self.is_module) {
                        const local_idx = spec_node.data.binary.left;
                        if (!local_idx.isNone() and @intFromEnum(local_idx) < self.ast.nodes.items.len) {
                            const local_node = self.ast.getNode(local_idx);
                            if (local_node.tag != .string_literal) {
                                const local_name = self.ast.source[local_node.span.start..local_node.span.end];
                                self.checkExportBinding(local_name, local_node.span);
                            }
                        }
                    }
                }
            }
        }

        // export declaration (export var/let/const/function/class)
        if (!decl_idx.isNone() and @intFromEnum(decl_idx) < self.ast.nodes.items.len) {
            const decl_node = self.ast.getNode(decl_idx);
            // 선언에서 내보내는 이름 추적
            self.collectExportedDeclNames(decl_node);
        }

        self.visitNode(decl_idx);
    }

    /// export default 시 "default" 이름을 등록한다.
    fn visitExportDefaultDeclaration(self: *SemanticAnalyzer, node: Node) void {
        self.registerExportedName("default", node.span);
        // 내부 선언 순회
        self.visitNode(node.data.unary.operand);
    }

    /// export * as name — name을 등록한다.
    fn visitExportAllDeclaration(self: *SemanticAnalyzer, node: Node) void {
        // binary: { left = exported_name, right = source }
        const name_idx = node.data.binary.left;
        if (!name_idx.isNone() and @intFromEnum(name_idx) < self.ast.nodes.items.len) {
            const name_node = self.ast.getNode(name_idx);
            const name = self.ast.source[name_node.span.start..name_node.span.end];
            const effective_name = if (name.len >= 2 and (name[0] == '\'' or name[0] == '"'))
                name[1 .. name.len - 1]
            else
                name;
            self.registerExportedName(effective_name, name_node.span);
        }
    }

    /// 선언에서 내보내는 이름을 추적한다 (export var x, export function f, etc.)
    fn collectExportedDeclNames(self: *SemanticAnalyzer, node: Node) void {
        switch (node.tag) {
            .variable_declaration => {
                // variable_declaration → declarator → binding name
                const extra_start = node.data.extra;
                const extras = self.ast.extra_data.items;
                if (extra_start + 2 >= extras.len) return;
                const decl_start = extras[extra_start + 1];
                const decl_len = extras[extra_start + 2];
                if (decl_start + decl_len > extras.len) return;
                for (extras[decl_start .. decl_start + decl_len]) |raw_idx| {
                    const decl_idx: NodeIndex = @enumFromInt(raw_idx);
                    if (decl_idx.isNone() or @intFromEnum(decl_idx) >= self.ast.nodes.items.len) continue;
                    const decl_node = self.ast.getNode(decl_idx);
                    if (decl_node.tag == .variable_declarator) {
                        const binding_idx: NodeIndex = @enumFromInt(extras[decl_node.data.extra]);
                        self.collectBindingExportNames(binding_idx);
                    }
                }
            },
            .function_declaration => {
                const extras = self.ast.extra_data.items;
                if (node.data.extra >= extras.len) return;
                const name_idx: NodeIndex = @enumFromInt(extras[node.data.extra]);
                if (!name_idx.isNone() and @intFromEnum(name_idx) < self.ast.nodes.items.len) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.source[name_node.span.start..name_node.span.end];
                    self.registerExportedName(name, name_node.span);
                }
            },
            .class_declaration => {
                const extras = self.ast.extra_data.items;
                if (node.data.extra >= extras.len) return;
                const name_idx: NodeIndex = @enumFromInt(extras[node.data.extra]);
                if (!name_idx.isNone() and @intFromEnum(name_idx) < self.ast.nodes.items.len) {
                    const name_node = self.ast.getNode(name_idx);
                    const name = self.ast.source[name_node.span.start..name_node.span.end];
                    self.registerExportedName(name, name_node.span);
                }
            },
            else => {},
        }
    }

    /// 바인딩 패턴에서 내보내는 이름을 수집한다.
    fn collectBindingExportNames(self: *SemanticAnalyzer, idx: NodeIndex) void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .binding_identifier) {
            const name = self.ast.source[node.span.start..node.span.end];
            self.registerExportedName(name, node.span);
        }
    }

    /// 내보낸 이름을 등록한다. 중복이면 에러.
    fn registerExportedName(self: *SemanticAnalyzer, name: []const u8, span: Span) void {
        if (!self.is_module) return;
        if (self.exported_names.get(name)) |_| {
            self.addErrorMsg(span, std.fmt.allocPrint(
                self.allocator,
                "Duplicate export name '{s}'",
                .{name},
            ) catch @panic("OOM"));
        } else {
            self.exported_names.put(name, span) catch @panic("OOM");
        }
    }

    /// export { x } (without from) — x가 선언된 바인딩인지 검증한다.
    /// module scope에서 VarDeclaredNames + LexicallyDeclaredNames에 없으면 에러.
    fn checkExportBinding(self: *SemanticAnalyzer, name: []const u8, span: Span) void {
        // 현재 module scope에서 해당 이름의 심볼을 찾는다
        for (self.symbols.items) |sym| {
            const sym_name = self.ast.source[sym.name.start..sym.name.end];
            if (std.mem.eql(u8, sym_name, name)) return; // 존재
        }
        // 찾지 못함 → 에러
        self.addErrorMsg(span, std.fmt.allocPrint(
            self.allocator,
            "Export '{s}' is not defined",
            .{name},
        ) catch @panic("OOM"));
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

// ============================================================
// Private Name 검증 테스트
// ============================================================

test "SemanticAnalyzer: declared private name is valid" {
    var scanner = Scanner.init(std.testing.allocator, "class C { #x = 1; foo() { this.#x; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: undeclared private name is error" {
    var scanner = Scanner.init(std.testing.allocator, "class C { foo() { this.#x; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private name outside class is error" {
    var scanner = Scanner.init(std.testing.allocator, "this.#x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private method is valid" {
    var scanner = Scanner.init(std.testing.allocator, "class C { #foo() {} bar() { this.#foo(); } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: nested class private name" {
    // 내부 class에서 외부 class의 private name 접근은 불가
    var scanner = Scanner.init(std.testing.allocator, "class Outer { #x; foo() { class Inner { bar() { this.#y; } } } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    // #y는 어디에도 선언 안 됨 → 에러
    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: inner class can access outer private name" {
    var scanner = Scanner.init(std.testing.allocator, "class Outer { #x; foo() { class Inner { bar() { this.#x; } } } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    // #x는 Outer에 선언됨 → 에러 없음
    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: duplicate private method is error" {
    // 같은 이름의 private method 두 번 선언 → 에러
    var scanner = Scanner.init(std.testing.allocator, "class C { #m() {} #m() {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: duplicate private field is error" {
    // 같은 이름의 private field 두 번 선언 → 에러
    var scanner = Scanner.init(std.testing.allocator, "class C { #x; #x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private getter+setter pair is valid" {
    // getter와 setter 쌍은 중복이 아님
    var scanner = Scanner.init(std.testing.allocator, "class C { get #x() { return 1; } set #x(v) {} }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len == 0);
}

test "SemanticAnalyzer: private method+getter duplicate is error" {
    // method와 getter는 쌍이 아님 → 에러
    var scanner = Scanner.init(std.testing.allocator, "class C { #m() {} get #m() { return 1; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    try std.testing.expect(ana.errors.items.len > 0);
}

test "SemanticAnalyzer: private name in object literal method is error" {
    // 객체 리터럴에서 private name 메서드는 SyntaxError
    // 이 테스트는 method_definition key 순회 + private_identifier 검출이 동작하는지 확인
    var scanner = Scanner.init(std.testing.allocator, "var o = { #m() {} };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    // 파서가 에러를 보고할 수도 있으므로 semantic까지 도달하는 경우만 체크
    if (parser.errors.items.len == 0) {
        var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
        defer ana.deinit();
        ana.analyze();
        // class 밖에서 private name 사용 → 에러
        try std.testing.expect(ana.errors.items.len > 0);
    }
}

test "SemanticAnalyzer: call expression args are visited" {
    // 함수 호출 인자 내부의 함수 표현식이 스코프를 생성하는지 확인
    var scanner = Scanner.init(std.testing.allocator, "f(function() { let x = 1; });");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    // 에러 없이 분석 완료 (스코프: global + function)
    try std.testing.expect(ana.errors.items.len == 0);
    try std.testing.expect(ana.scopes.items.len >= 2);
}

test "SemanticAnalyzer: template literal expressions are visited" {
    // 템플릿 리터럴 내부 표현식이 순회되는지 확인
    var scanner = Scanner.init(std.testing.allocator, "let x = `${function() { let y = 1; }()}`;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var ana = SemanticAnalyzer.init(std.testing.allocator, &parser.ast);
    defer ana.deinit();
    ana.analyze();

    // 에러 없이 분석 완료
    try std.testing.expect(ana.errors.items.len == 0);
}
