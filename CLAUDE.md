# ZTS - Zig TypeScript Transpiler

## Project Overview
Zig로 작성하는 JavaScript/TypeScript/Flow 트랜스파일러. SWC/oxc 수준의 프로덕션 레벨 품질을 목표로 하는 학습 + 실용 프로젝트. 추후 번들러까지 확장 예정.

## Tech Stack
- **Language**: Zig 0.14.0
- **Version Manager**: mise
- **Build**: `zig build` (build.zig)
- **Test**: `zig build test`
- **Test262**: `zig build test262`

## Project Structure
```
src/
  main.zig                  # CLI 엔트리포인트
  root.zig                  # 라이브러리 엔트리포인트 (모든 모듈 re-export)
  lexer/                    # Phase 1: 렉서 (토크나이저) ✅ 완료
    mod.zig                 #   렉서 엔트리 + re-export
    token.zig               #   토큰 종류(Kind ~130개), Span, Token, 키워드 맵
    scanner.zig             #   스캔 로직 (~2400줄, 모든 토큰 타입 처리)
    unicode.zig             #   유니코드 식별자 (UTF-8 디코딩, ID_Start/ID_Continue)
  parser/                   # Phase 2: 파서 (AST 생성)
    mod.zig                 #   파서 엔트리
  transformer/              # Phase 3: 트랜스포머 (TS→JS 변환)
    mod.zig                 #   트랜스포머 엔트리
  codegen/                  # Phase 4: 코드 생성 (AST→JS + 소스맵)
    mod.zig                 #   코드젠 엔트리
  test262/                  # Test262 러너
    mod.zig                 #   Test262 엔트리
    runner.zig              #   메타데이터 파서 + 테스트 실행기
tests/
  test262/                  # TC39 공식 Test262 (서브모듈)
references/                 # 레퍼런스 프로젝트 (.gitignore, 로컬만)
  bun/                      #   Zig — 파서/렉서 참고
  esbuild/                  #   Go — 아키텍처/설정 참고
  oxc/                      #   Rust — 트랜스포머/isolated declarations 참고
  swc/                      #   Rust — 전체 기능/Flow 참고
  hermes/                   #   C++ — Flow 파서 임베딩 소스
  metro/                    #   JS — React Native 번들러 참고
```

## Architecture Decisions (요약, 전체는 DECISIONS.md 참조)

### Lexer Design (D015, D019, D025, D026, D034-D036)
- **토큰 enum**: oxc 방식 — ~208개 u8 플랫 enum. TS 키워드 개별 토큰, 숫자 11가지 세분화
- **소스 위치**: start + end byte offset (8바이트). line/column은 line offset 테이블에서 lazy 계산
- **문자열 인코딩**: UTF-8 기본, lazy UTF-16 (Bun 방식)
- **렉서-파서 연동**: 파서가 렉서 호출 + 옵션으로 토큰 저장
- **SIMD**: Zig @Vector로 공백 스킵, 식별자 스캔, 문자열 스캔
- **추가 기능**: hashbang, BOM, 유니코드 식별자, import attributes, `@__PURE__` 추적, JSX pragma 감지

### Memory Strategy (D004)
- Phase-based arena allocator
- AST 노드는 포인터 대신 인덱스 기반 참조 (use-after-free 방지)

### Parser Design
- comptime으로 JS/JSX/TS/TSX/Flow 파서 각각 생성 (런타임 분기 없음)
- 에러 복구 지원 (첫 에러에서 멈추지 않음)
- Test262로 정합성 검증

### TypeScript/Flow Handling (D002, D005, D024)
- 타입 체크 안 함 (스트리핑만)
- TS 5.8까지 전체 지원
- Flow: Hermes C++ 파서를 C ABI로 링크
- Stage 3 decorator: 후순위 (스펙 안정화 후)
- Legacy decorator 우선 구현

### Output (D006, D008, D009, D012)
- ESM + CJS (UMD는 번들러 Phase)
- JSX Classic + Automatic 둘 다
- 소스맵 inline + external + hidden 전부
- 에러 출력: 코드 프레임 + JSON

### Advanced Features (Phase 6)
- ES 다운레벨링: ES2024→ES2016 점진적, ES2015는 그 이후, ES5는 미정
- WASM 플러그인, WASM 공개 AST API
- .d.ts 생성 (isolatedDeclarations)
- React Fast Refresh
- 미니파이어 (whitespace/syntax/identifiers 개별)
- 번들러 (paths/baseUrl/moduleResolution 활성화)

## Commands
```bash
zig build          # 빌드
zig build run      # 실행
zig build test     # 유닛 테스트
zig build test262  # Test262 러너 테스트
```

## Development Workflow

### 구현 규칙
1. **작업 단위를 최대한 작게 나눈다** — 하나의 PR이 하나의 기능/토큰 그룹을 담당
2. **서브에이전트로 병렬 구현** — 독립적인 작업은 서브에이전트를 활용해 병렬 진행
3. **PR 단위로 올린다** — main에 직접 push하지 않고 feature branch → PR → merge
4. **`/simplify` 리뷰** — PR 올린 후 반드시 `/simplify`로 코드 품질 점검
   - 코드 재사용, 품질, 효율성 검토
   - 발견된 이슈 수정 후 merge
5. **테스트 먼저** — 구현 전에 해당 Test262 카테고리 또는 유닛 테스트 작성
6. **Zig 초보자에게 자세히 설명** — 모든 코드 작성 시 왜 이렇게 하는지 설명

### PR 네이밍 규칙
```
feat(lexer): add numeric literal tokenization
feat(lexer): add string literal and escape sequences
feat(lexer): add SIMD whitespace skipping
feat(parser): add expression parsing
fix(lexer): handle edge case in template literal nesting
```

### 브랜치 전략
```
main ← feature/lexer-token-enum
     ← feature/lexer-numeric-literals
     ← feature/lexer-string-literals
     ← feature/lexer-comments
     ← feature/lexer-simd
     ...
```

### 렉서 구현 순서 (PR 단위) — ✅ Phase 1 완료
1. ✅ 토큰 enum 정의 (~130개) — PR #1
2. ✅ 디렉토리 구조 (모듈별 분리) — PR #2
3. ✅ Scanner 기본 (공백, 연산자, 식별자) — PR #3
4. ✅ 주석 + @__PURE__ 감지 — PR #4
5. ✅ 숫자 리터럴 (11가지 세분화) — PR #5
6. ✅ 문자열 리터럴 (이스케이프, 에러) — PR #6
7. ✅ 템플릿 리터럴 (중첩, brace stack) — PR #7
8. ✅ 정규식 리터럴 (컨텍스트 판별) — PR #8
9. ✅ 유니코드 식별자 — PR #9
10. ✅ JSX 모드 — PR #10
11. ✅ JSX pragma — PR #11
12. ✅ Test262 러너 + CLI — PR #12
13. ✅ 숫자 유효성 검증 — PR #13
14. ✅ /simplify 리뷰 수정 + Test262 개선 — PR #14
15. ⬜ SIMD 최적화 — 프로파일링 후 (BACKLOG)

### 파서 구현 순서 (PR 단위) — Phase 2 핵심 완료, 후반 작업 남음
1. ✅ Phase 2 의사결정 (D037-D040) — PR #16
2. ✅ AST 노드 정의 (~200개 Tag, 24B 고정) — PR #17
3. ✅ 파서 기본 (statement + expression + precedence climbing) — PR #18
4. ✅ 리뷰 수정 (variable_declaration, property key) — PR #19
5. ✅ for-in/for-of + do-while + switch/case — PR #21
6. ✅ try/catch/finally — PR #22
7. ✅ arrow function + spread — PR #23
8. ✅ class (extends, static, getter/setter, static block) — PR #24
9. ✅ destructuring (array/object, nested, rest, default) — PR #25
10. ✅ import/export (ESM 전체) — PR #26
11. ✅ async/await + generator (yield, yield*) — PR #27
12. ✅ BACKLOG (#private, import.meta, elision) — PR #28-#29
13. ✅ TS 타입 어노테이션 (union, intersection, array, tuple, generic, typeof, keyof, as, satisfies, !) — PR #30
14. ✅ TS 선언 (interface, type alias, enum, namespace, declare, abstract) — PR #31
15. ✅ TS 변환 대상 (parameter property, decorator, implements, class generics) — PR #32
16. ✅ JSX 파싱 (element, fragment, attributes, expression, text) — PR #33
17. ⬜ 에러 복구 강화 + Test262 파서 통과율 — Phase 2 후반
18. ⬜ semantic analysis (스코프/심볼, 별도 패스, D038) — Phase 2 후반

## References
- Bun JS Parser: github.com/oven-sh/bun (src/js_parser.zig, src/js_lexer.zig)
- oxc: github.com/oxc-project/oxc (crates/oxc_parser/src/lexer/kind.rs — 토큰 enum 참고)
- SWC: github.com/swc-project/swc
- esbuild: github.com/evanw/esbuild
- Hermes: github.com/facebook/hermes (Flow 파서)
- Metro: github.com/facebook/metro (RN 번들러)
- Test262: github.com/tc39/test262
- ECMAScript Spec: tc39.es/ecma262
