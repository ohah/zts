# ZTS - Zig TypeScript Transpiler

## Project Overview
Zig로 작성하는 JavaScript/TypeScript/Flow 트랜스파일러. SWC/oxc 수준의 프로덕션 레벨 품질을 목표로 하는 학습 + 실용 프로젝트. 추후 번들러까지 확장 예정.

## Tech Stack
- **Language**: Zig 0.15.2
- **Version Manager**: mise
- **Build**: `zig build` (build.zig)
- **Test**: `zig build test`
- **Test262**: `zig build test262`

## Project Structure
```
src/
  main.zig                  # CLI 엔트리포인트 (zts 커맨드)
  root.zig                  # 라이브러리 엔트리포인트 (모든 모듈 re-export)
  diagnostic.zig            # 진단 시스템 (ParseError, SemanticError 통합)
  config.zig                # 설정 구조 (CompilerOptions, ResolverOptions, BundlerOptions)
  lexer/                    # Phase 1: 렉서 ✅
    mod.zig                 #   렉서 엔트리 + re-export
    token.zig               #   토큰 종류(Kind ~208개), Span, Token, 키워드 맵
    scanner.zig             #   스캔 로직 (~2400줄, 모든 토큰 타입 처리)
    unicode.zig             #   유니코드 식별자 (UTF-8 디코딩, ID_Start/ID_Continue)
  parser/                   # Phase 2: 파서 ✅
    mod.zig                 #   파서 엔트리 + re-export
    parser.zig              #   파서 메인 로직 (~4000줄)
    ast.zig                 #   AST 노드 정의 (~200개 Tag, 24B 고정)
    expression.zig          #   표현식 파싱 (precedence climbing, cover grammar)
    statement.zig           #   문 파싱 (if/for/while/switch 등)
    declaration.zig         #   선언 파싱 (function/class/const 등)
    binding.zig             #   바인딩 패턴 (destructuring, rest, default)
    object.zig              #   객체/클래스 멤버 파싱
    jsx.zig                 #   JSX 파싱 (element, fragment, attributes)
    module.zig              #   import/export 파싱
    ts.zig                  #   TypeScript 타입 어노테이션 파싱
  semantic/                 # 의미 분석 ✅
    mod.zig                 #   의미 분석 엔트리 + re-export
    analyzer.zig            #   의미 분석기 (~3000줄, 스코프/심볼 추적)
    checker.zig             #   검증 (~700줄, 엄격 모드, 예약어, 중복)
    scope.zig               #   스코프 체인 (플랫 배열 + 부모 인덱스)
    symbol.zig              #   심볼 테이블 (이름, 종류, 플래그, 참조 수)
  transformer/              # Phase 3: 트랜스포머 ✅ + ES 다운레벨링 ⏳
    mod.zig                 #   트랜스포머 엔트리 + re-export
    transformer.zig         #   Visitor 기반 순회 + AST 변환
    es2022.zig              #   ES2022 다운레벨링 (class static block)
    es2021.zig              #   ES2021 다운레벨링 (??=, ||=, &&=)
    es2020.zig              #   ES2020 다운레벨링 (??, ?.)
    es2016.zig              #   ES2016 다운레벨링 (**)
    es_helpers.zig          #   다운레벨링 헬퍼 유틸
  codegen/                  # Phase 4: 코드 생성 ✅
    mod.zig                 #   코드젠 엔트리 + re-export
    codegen.zig             #   코드 생성 (formatting, minify, indentation)
    sourcemap.zig           #   V3 소스맵 생성 (VLQ 인코딩)
    mangler.zig             #   식별자 축약 (번들러 심볼 데이터 활용)
  bundler/                  # Phase 6a: 번들러 ✅
    mod.zig                 #   번들러 엔트리 + 오케스트레이션
    bundler.zig             #   번들러 메인 로직
    resolver.zig            #   모듈 경로 해석 (node_modules, package.json, tsconfig)
    graph.zig               #   모듈 그래프 (DFS, exec_index, 순환 감지)
    module.zig              #   모듈 데이터 (AST, import/export, 심볼)
    linker.zig              #   스코프 호이스팅 + 이름 충돌 해결
    tree_shaker.zig         #   Tree-shaking (export 추적, @__PURE__, sideEffects)
    chunk.zig               #   Code splitting (BitSet, 공통 청크, cross-chunk)
    emitter.zig             #   출력 생성 (exec_index 순서, ESM/CJS/IIFE)
    types.zig               #   번들러 자료 구조
    package_json.zig        #   package.json 읽기 (exports, browser, sideEffects)
    resolve_cache.zig       #   해석 결과 캐싱 (import kind별)
    import_scanner.zig      #   import/export 문 추출
    binding_scanner.zig     #   심볼 바인딩 추적
  server/                   # Phase 6b: 개발 서버 + HMR ✅
    mod.zig                 #   서버 엔트리 + re-export
    dev_server.zig          #   HTTP + WebSocket 서버 (HMR, Fast Refresh)
    mime.zig                #   MIME 타입 매핑
  regexp/                   # RegExp 검증 ✅
    mod.zig                 #   RegExp 엔트리 + re-export
    parser.zig              #   RegExp 패턴 파서 (~2000줄, comptime 모드 분리)
    ast.zig                 #   RegExp AST
    flags.zig               #   플래그 처리 (g, i, m, u, v, d, s)
    unicode_property.zig    #   유니코드 프로퍼티 (\p{Letter} 등)
    diagnostics.zig         #   RegExp 에러 메시지
  test262/                  # Test262 러너
    mod.zig                 #   Test262 엔트리
    runner.zig              #   메타데이터 파서 + 테스트 실행기
packages/
  integration/              # Bun 기반 CLI 통합 테스트
  e2e/                      # Playwright E2E 테스트 (dev server)
  benchmark/                # 스모크 테스트 + 벤치마크 (smoke.ts)
tests/
  test262/                  # TC39 공식 Test262 (서브모듈)
references/                 # 레퍼런스 프로젝트 (.gitignore, 로컬만)
  bun/                      #   Zig — 파서/렉서/SIMD 참고
  esbuild/                  #   Go — 번들러 아키텍처/모듈 해석/설정 참고
  oxc/                      #   Rust — 트랜스포머/isolated declarations/파서 참고
  swc/                      #   Rust — 전체 기능/Flow 참고
  hermes/                   #   C++ — Flow 파서 임베딩 소스
  metro/                    #   JS — React Native 번들러/Metro 호환 참고
  rolldown/                 #   Rust — Rollup 호환 번들러/Vite 통합 참고
  vite/                     #   JS — 개발 서버/HMR/플러그인 API 참고
  babel/                    #   JS — 플러그인 시스템/스펙 추종 참고
```

## Pipeline Architecture

### 트랜스파일 파이프라인
```
Input (.ts/.tsx/.js/.jsx)
  → Scanner (토큰 스트림, SIMD 최적화)
  → Parser (AST, 24B 고정 노드, 인덱스 기반)
  → Semantic Analyzer (스코프 + 심볼 + 검증)
  → Transformer (TS 스트리핑, ES 다운레벨링, JSX, decorator)
  → Codegen (JavaScript + SourceMap V3)
  → Output (.js + .js.map)
```

### 번들러 파이프라인
```
Entry Points
  → Resolver (경로 → 파일, node_modules, package.json exports)
  → Module Graph (BFS 파싱, DFS exec_index, 순환 감지)
  → Linker (스코프 호이스팅, 심볼 바인딩, 이름 충돌 해결)
  → Tree Shaker (export 추적, @__PURE__, sideEffects, fixpoint)
  → Chunker (BitSet 도달 가능성, 공통 청크 추출)
  → Emitter (모듈별 transform+codegen, ESM/CJS/IIFE 출력)
  → Output (bundle.js + chunks + .map)
```

### 메모리 관리 (파일당 Arena)
```
Per-File Arena (단일 할당자, 파일 처리 후 한 번에 해제)
  ├─ Scanner: comments, line_offsets
  ├─ Parser: AST nodes (인덱스 기반, 24B 고정)
  ├─ Semantic: scope chain, symbols
  ├─ Transformer: new_ast
  └─ Codegen: code string, sourcemap
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
- **Context**: packed struct(u8) — ECMAScript 문법 파라미터 8개만 (allow_in, in_generator, in_async, in_function, is_top_level, in_decorator, in_ambient, disallow_conditional_types). 나머지 파서 상태는 개별 bool 필드. SavedState로 함수 경계 save/restore.
- **Cover Grammar**: expression → assignment target 노드 변환. setTag로 24B 노드의 태그만 교체 (새 노드 할당 불필요). 7개 assignment target 태그 (identifier, array, object, property_identifier, property_property, with_default, rest)

### TypeScript/Flow Handling (D002, D005, D024)
- 타입 체크 안 함 (스트리핑만)
- TS 5.8까지 전체 지원
- Flow: 미지원 (현재 우선순위 낮음, RN 지원 시 결정. 상세: DECISIONS.md)
- ✅ Legacy decorator 구현 완료 (experimentalDecorators)
- Stage 3 decorator: 후순위 (스펙 안정화 후)

### Output (D006, D008, D009, D012)
- ESM + CJS (UMD는 번들러 Phase)
- JSX Classic + Automatic 둘 다
- 소스맵 inline + external + hidden 전부
- 에러 출력: 코드 프레임 + JSON

### Transformer Design (D041-D043)
- 새 AST 생성 + 별도 Codegen (oxc/SWC 방식). in-place 변환 대신 변환된 AST를 새로 빌드
- Switch 기반 visitor + comptime 보조 (esbuild/Bun 방식). 성능 핵심은 메모리 레이아웃
- 단일 패스, 변환 우선순위로 순서 제어

### Codegen Design (D044-D046)
- Tab 기본 + Space 옵션 (oxc 방식). IndentChar enum으로 Tab/Space 선택
- `\n` 정규화 + CRLF 옵션. 크로스 플랫폼 지원
- 소스맵 VLQ 자체 구현 (~30줄). 외부 의존성 없음
- 번들러 소스맵: 전 파이프라인을 자체 소유하므로 AST span으로 원본→최종 직접 매핑 (esbuild 방식, 체이닝 불필요)
- 플러그인 transform 시: 플러그인이 소스맵을 반환하면 VLQ 역추적으로 체이닝 (~200줄). 미반환 시 경고

### Semantic Analysis Design (D051-D055)
- 파서에서 구문 컨텍스트 추적 (strict/async/generator/loop/switch), Semantic 패스에서 스코프/심볼
- 스코프: 플랫 배열 + 부모 인덱스 (D004 일관). 심볼: 최소 모델 (name/scope/kind/flags/span)
- Strict mode는 파서에서 추적 ("use strict" directive + module mode)
- Test262 early phase는 parse와 통합

### Advanced Features (Phase 6) — 구현 순서 및 의존성

#### 번들러 선행 인프라 (✅ 완료)
- ✅ **Symbol Reference Tracking** (PR #198) — `reference_count`로 미사용 심볼 판단, `resolveIdentifier`로 스코프 체인 해결
- ✅ **Ast string_table** (PR #199) — 합성 문자열 저장소 (bit 31 마커), `getText(span)`으로 source/string_table 투명 전환
- ✅ **Transformer pending_nodes** (PR #199) — 1→N 노드 확장 버퍼 (enum `var Color;` + IIFE 등)
- ⏸ **Enum/Namespace IIFE → Transformer** — 번들러 tree-shaking 구현 시 같이 진행 (현재 codegen 방식이 잘 동작하므로 미리 할 필요 없음)
- ⏸ **JSX React.createElement → Transformer** — 번들러 구현 시 같이 진행
- ⏸ **Comment-Node 연결** — 번들러 모듈 합칠 때 같이 진행

#### 의존성 관계
```
AST 안정화 ──────────────┬──→ WASM 공개 AST API
                         └──→ .d.ts (isolatedDeclarations)

Arena allocator ─────────┬──→ 번들러 (파일별 arena reset)
번들러 아키텍처 설계 ────┼──→ 멀티스레드
                         └──→ 미니파이어 (tree-shaking + minify 연동)

번들러 선행 인프라 ✅ ───┬──→ tree-shaking ✅ (reference_count 활용)
                         ├──→ Transform 분리 (string_table + pending_nodes 활용)
                         └──→ Comment 보존 (번들러 모듈 합칠 때)

독립 (아무 때나): ES 다운레벨링, React Fast Refresh, regexp, SIMD, Flow
```

#### 추천 구현 순서
1. ✅ **Test262 마무리 + regexp validator** — 50,504건 100% 통과 (language+built-ins+annexB+staging+intl402 전체)
2. ✅ **Arena allocator 설계 + 도입** — 1~3단계 완료
   - ✅ 1단계: transpileFile에서 파일당 Arena 1개 생성, 모든 모듈(Scanner/Parser/Semantic/Transformer/Codegen)에 전달
   - ✅ 2~3단계: Phase별 Arena 분리 불필요 — Scanner의 comments/line_offsets를 Codegen이 참조하므로 파일당 Arena 1개가 최적
   - ✅ @panic("OOM") 전량 제거, 에러 전파로 교체
   - ✅ test262 runner에 arena + reset 패턴 적용 (번들러 파일별 Arena 패턴 검증)
   - 4단계: 번들러 파일별 Arena (번들러 구현 시 같이)
3. ✅ **번들러 Phase B1 (MVP)** — resolver + 모듈 그래프 + 단일 번들 출력 완료
   - ✅ resolver: 상대/절대 경로, node_modules walk-up, package.json exports (와일드카드 포함)
   - ✅ resolve_cache: import kind별 캐싱 + external 글롭 매칭
   - ✅ 모듈 그래프: 반복 DFS, exec_index 후위 순서, 순환 감지
   - ✅ emitter: exec_index 순 변환+코드젠, ESM/CJS/IIFE 포맷
   - ✅ CLI: `zts --bundle entry.ts -o bundle.js --external react --platform=node`
   - ✅ linker: 스코프 호이스팅 (import 제거, export 키워드 제거, symbol_id 기반 리네임)
   - ✅ tree-shaking (모듈 수준): 미사용 export 추적, 자동 순수 판별, package.json sideEffects, fixpoint 분석
   - ✅ `@__PURE__` / `@__NO_SIDE_EFFECTS__`: 렉서 감지 → semantic 전파 → codegen 출력 → tree-shaker 활용
   - ✅ cross-module `@__NO_SIDE_EFFECTS__` 전파: import한 함수의 호출에 `/* @__PURE__ */` 자동 출력 (re-export chain, default export, async function 포함)
   - ✅ 통합 테스트 강화: barrel file, diamond re-export, class extends, export star 등 8개 실전 패턴
4. **번들러 Phase B2 (핵심)** — CJS interop → TLA → Code splitting → HMR
   - ✅ 4a. **CJS interop (입력)** — PR #248-250
     - require() 감지 + __commonJS 래핑 + __toESM 브릿지
     - ExportsKind 승격 (소비 방식 기반), module.exports 파서 수정
   - ✅ 4b. **Top-level await** — PR #251
     - semantic analyzer 기반 감지 (스코프 체인 추적, for_await_of_statement 태그)
     - 전이적 전파 (static import 체인), 비-ESM 경고
   - ✅ 4c. **Code splitting** — PR #252-258
     - BitSet 도달 가능성 알고리즘 (rolldown 패턴)
     - generateChunks (엔트리 초기화 + BFS 마킹 + 청크 할당)
     - computeCrossChunkLinks (청크 간 의존성 + 심볼 수준 import/export)
     - 멀티 파일 emitter + CLI --splitting + --outdir
     - 청크별 scope hoisting (per-chunk computeRenamesForModules)
     - cross-chunk export alias (`export { x$1 as x }`)
     - cross-chunk import/local name 충돌 방지 (occupied names)
     - dynamic import 경로 리라이트 (`import('./page')` → `import('./page.js')`)
     - content hash 파일명 (`chunk-{8자 hex}.js`, 결정론적)
     - 동일 이름 cross-chunk import deconflict (`import { x as x$2 }`)
   - 4d. **Dev server + HMR** — 다음, watch 모드(✅) 위에 확장
     - ✅ **선행: Bun 모노레포 셋업** — PR #259
       - packages/integration (Bun test runner, CLI 통합 테스트)
       - packages/e2e (Playwright, dev server 구현 후 활성화)
       - oxlint + oxfmt 설정
     - **의사결정 완료:**
       - HTTP 서버: `std.http.Server` (Zig 표준 라이브러리). dev server 전용이라 충분, 외부 C/C++ 의존성 불필요
       - HMR API: `import.meta.hot` 기본 (Vite 호환) + RN 타겟 시 `module.hot` 어댑터 추가
       - 참고: 번개(bungae) oxc-bundler 방식 — Rolldown DevEngine + `import.meta.hot` + metro-runtime HMRClient 교체 플러그인
     - **구현 순서:**
       1. ✅ HTTP 정적 서버 — PR #260
       2. ✅ 번들 서빙 (on-the-fly) — PR #261
       3. ✅ WebSocket 서버 — PR #262
       4. ✅ Live Reload (thread-per-connection + watch) — PR #263
       5. ✅ 모듈 그래프 전체 파일 감시 — PR #266
       6. ✅ 에러 오버레이 — PR #267
       7. ✅ 소스맵 서빙 — PR #272
       8. ✅ SPA 폴백 — PR #269
       9. ✅ import.meta.hot API (모듈 래핑 + accept/dispose + 모듈 단위 교체) — PR #270, #271
       10. ✅ React Fast Refresh ($RefreshReg$ 주입 + 런타임 통합) — PR #273, #274
       11. ✅ CSS 핫 리로드 (link tag swap) — PR #275
     - **추가 의사결정 (D059-D060):**
       - D059. 동시성: `std.Thread.spawn` per-connection (esbuild goroutine과 유사)
       - dev server 전용이라 OS 스레드 10-20개면 충분
       - WS 클라이언트 목록: mutex 보호 고정 배열 (Metro와 동일 패턴)
       - D060. import.meta.hot: **모듈 래핑 dev 번들 방식** (A안 채택)
         - dev 모드에서 각 모듈을 함수로 감싸고 레지스트리에 등록
         - 변경 시 해당 모듈 함수만 재실행 (full-reload 대신)
         - emitter에 dev 모드 추가, 프로덕션 빌드(scope hoisting)는 그대로 유지
         - B안(언번들 ESM, Vite 방식) 배제: dev/prod 동작 차이로 인한 버그 위험
         - C안(API 스텁 + full-reload) 배제: 실질적 가치 없음
5. **.d.ts 생성** (isolatedDeclarations) — 후순위. 당분간 tsc에 위임 (esbuild/SWC와 동일). 자체 구현 시 AST 순회로 export 타입 추출 (~500줄), 파일별 독립이라 번들러 불필요
6. **프로파일링 → SIMD → 미니파이어** — 번들러 B2 완료 후 현실적 벤치마크 가능
   - 미니파이어 3단계: 1) whitespace (✅ 이미 있음, codegen minify) → 2) identifier mangling (✅ mangler.zig, computeMangling) → 3) syntax 최적화 (if→ternary, dead code 등)
   - mangling은 번들러의 스코프/심볼 데이터를 공유하므로 번들러 후가 효율적
   - SIMD는 렉서 함수 3개 교체, 인터페이스 불변이라 언제 넣어도 비용 동일
7. **ES 다운레벨링** (ES2024→ES2016 점진적, ES2015 이후, ES5) — ⏳ 진행 중
   - ✅ ES2022: class static block → IIFE
   - ✅ ES2021: `??=`, `||=`, `&&=` (logical assignment)
   - ✅ ES2020: `??` (nullish coalescing), `?.` (optional chaining)
   - ✅ ES2016: `**` → `Math.pow()`
   - ⏳ ES2019: optional catch binding
   - ⬜ ES2018: rest/spread properties, async iteration
   - ⬜ ES2017: async/await → generator+Promise
   - ⬜ ES2015 (~6000줄): class→function/prototype, arrow→bind, let/const→var+IIFE, generator→상태 머신
   - ⬜ ES5 (~2000줄): polyfill + 런타임 헬퍼 (tslib 방식)
   - 참고: oxc `crates/oxc_transformer/src/es20XX/`, Babel `packages/babel-plugin-transform-*/`, esbuild `pkg/js_parser/js_parser_lower.go`
8. **WASM 공개 AST API** — 모든 게 안정화된 후. AST 변동 중 넣으면 매번 breaking change

#### 번들러 상세 설계

##### 경쟁 환경
- **Rolldown** (Rust, oxc 기반): Vite 생태계 백업, Rollup+esbuild 대체 목표. Rollup 플러그인 호환
- **esbuild** (Go): 속도 기준점, 범용 번들러, 플러그인 제한적
- **Bun** (Zig+C++): 런타임 내장 번들러, 속도 최우선
- **Turbopack** (Rust, SWC 기반): Next.js 전용, 증분 컴파일 특화

##### ZTS 번들러 포지셔닝
- **전략: 품질 먼저 → 속도 추가 (방법 B)** — Rollup→Rolldown 전략을 Zig로
  - 1단계: 정확한 파서/트랜스포머 (✅ 완료, Test262 100%)
  - 2단계: 정확한 tree-shaking/스코프 호이스팅 (Rollup 알고리즘 참고)
  - 3단계: Arena + SIMD + 멀티스레드로 속도 확보 (알고리즘 타협 없이)
- **핵심 목표**: React Native 지원 (Metro 대체), ESM 순서 보장, WASM 임베디드 번들러
- **트레이드오프**: 코드베이스 최소화보다 정확도+기능 우선. 기능이 늘면 코드는 커짐을 수용

##### 번들러 핵심 구현 순서 (의존성 순)
```
1. ✅ 모듈 해석 (경로 → 파일)
2. ✅ 모듈 그래프 구축 (ESM 순서 보장)
3. ✅ 단일 파일 번들 (연결만)
4. ✅ 스코프 호이스팅 (변수 충돌 해결)
5. ✅ Tree-shaking (모듈 수준, @__PURE__/@__NO_SIDE_EFFECTS__, sideEffects)
6. ✅ Code splitting (BitSet, 공통 청크, 심볼 cross-chunk, 청크별 scope hoisting, dynamic import 리라이트)
```

##### 번들러 Phase별 기능 분류
```
Phase B1: 기반 (✅ 완료)          Phase B2: 핵심 (✅ 대부분 완료) Phase B3: 고급
─────────────────                 ──────────────────          ──────────────
✅ 모듈 해석 (Node/TS)            ✅ CJS interop (입력)        플러그인 시스템
  ├ node_modules 탐색              ├ require() 감지/래핑        ├ resolve/load/transform 훅
  ├ package.json exports           ├ __commonJS/__toESM         ├ renderChunk/generateBundle 훅
  ├ tsconfig paths/baseUrl         └ ExportsKind 승격           ├ Plugin Context API (emitFile 등)
  └ 조건부 exports                                              ├ Rollup 플러그인 호환
✅ package.json browser 필드      ✅ Top-level await            └ Vite 플러그인 호환 (후순위)
  └ disabled 파일 → 빈 모듈       ✅ Code splitting            로더 시스템 (esbuild/Rolldown 호환)
✅ Node 빌트인 빈 모듈 대체         ├ BitSet 도달 가능성        ├ JSON (named export 지원)
  └ --platform=browser 시           ├ 공통 청크 자동 추출       ├ Text / Base64 / DataURL
    (disabled) CJS wrapper          ├ 멀티 파일 emitter         ├ Binary (Uint8Array)
✅ 모듈 그래프                       └ CLI --splitting          ├ File/Asset (해시 파일명)
  ├ 정적 import/export             개발 서버 + HMR              ├ Copy / Empty
  ├ 순환 참조 감지                  ├ ✅ HTTP + WS + Live Reload └ CLI: --loader:.ext=type
  └ 동적 import                    ├ ✅ 모듈 그래프 파일 감시  특수 기능
✅ 단일 파일 번들 생성              ├ ✅ 에러 오버레이 + 소스맵  ├ import.meta.glob (Vite 호환)
  └ 진입점 → 단일 출력             ├ ✅ import.meta.hot + FR    ├ Dynamic import variables
✅ 스코프 호이스팅                  └ ✅ CSS 핫 리로드           ├ Web Worker 번들링
  ├ 변수 이름 충돌 해결                                          └ Virtual modules (\0 prefix)
  ├ ESM 실행 순서 보장                                          CLI 옵션 확장
  └ CJS 호환 래핑                                                ├ --banner/--footer
✅ Tree-shaking (모듈 수준)                                      ├ --analyze (번들 사이즈)
  ├ export 사용 추적                                             ├ --minify-{whitespace|ids|syntax}
  ├ @__PURE__ / @__NO_SIDE_EFFECTS__                             ├ --pure:Name
  ├ sideEffects 필드                                             ├ --log-level
  └ cross-module 전파                                            ├ --legal-comments
                                                                 ├ --inject:file
                                                                 └ --target (엔진 버전)
                                                                React Native 지원
                                                                 ├ Metro 호환 해석
                                                                 ├ 플랫폼 확장자 (.ios/.android)
                                                                 ├ polyfill 주입
                                                                 └ Hermes 타겟 최적화
                                                                CSS 번들링
                                                                 ├ 별도 파서
                                                                 └ CSS modules
```

##### React Native 지원 (Rollipop/bungae 방식 — Metro 레거시 불필요)
- **참고**: Rollipop (bungae/reference/rollipop), bungae/oxc-bundler — Rolldown 위에서 Metro를 대체
- **불필요한 Metro 레거시** (구현하지 않음):
  - `__d` 래핑 — 표준 스코프 호이스팅으로 대체
  - Haste 모듈 시스템 — Node.js 표준 해석으로 대체
  - 의존성 맵 (숫자 ID) — 표준 import로 대체
  - RAM 번들 — code splitting으로 대체
- **필요한 RN 특화 기능** (플러그인으로 구현):
  - `platformResolverPlugin` — `.ios.js`/`.android.js` 확장자 + mainFields: `['react-native', 'browser', 'main']`
  - `flowStripPlugin` — Flow 타입 제거 (방식 미결정: 직접 구현 vs Hermes C++ 링크 vs WASM)
  - `preludePlugin` — polyfill/InitializeCore 주입
  - `assetPlugin` — 이미지 등 에셋 처리
  - `hermesCompatPlugin` — Hermes 호환 변환
  - `react-refresh` — HMR (React Fast Refresh)
  - 글로벌 주입: `__DEV__`, `Platform.OS` 등 — define 치환 (이미 ZTS에 구현됨)
- **핵심 설정**: `strictExecutionOrder: true` (ESM 실행 순서 보장 — InitializeCore → react → react-native → App)
- **Hermes 바이트코드**: `.hbc` 출력 — Hermes 컴파일러와 C ABI 연동

##### ESM 실행 순서 보장
- 스코프 호이스팅 시 원본 ESM의 top-level 코드 실행 순서가 바뀌면 안 됨
- 예: `import './a'; import './b';` → a.js의 사이드이펙트가 b.js보다 먼저 실행 보장
- 순환 참조 + 사이드이펙트 + 스코프 호이스팅이 충돌하는 복잡한 문제
- **모듈 그래프 설계 단계에서 잡아야 함** — 나중에 끼워넣기 어려움
- Rollup 참고: `rollup/src/utils/executionOrder.ts` (~100줄, DFS 후위 순서)
- Rolldown 참고: `rolldown/crates/rolldown/src/chunk_graph/`

##### 모듈 그래프 설계 (Rollup 코드 분석 기반)
- Rollup의 `analyseModuleExecution`: DFS 후위 순서로 execIndex 부여
  - 정적 dependencies 재귀 방문
  - 순환 참조 → cyclePaths 기록 (에러 아닌 경고)
  - 동적 import → 별도 Set, 정적 의존성 처리 후 방문
  - top-level await 있는 동적 import → 정적 의존성으로 승격
- Rollup 자체도 "현재 알고리즘이 불완전" 인정 (주석에 명시)

**ZTS 번들러 모듈 설계 (책임 분리):**
```
src/bundler/
  │
  ├─ mod.zig              # 번들러 엔트리 (파이프라인 오케스트레이션만)
  │
  ├─ resolver.zig         # 모듈 해석 (경로 → 파일)
  │   입력: import 경로 + 현재 파일 위치
  │   출력: 절대 파일 경로
  │   책임: node_modules, package.json, tsconfig paths
  │   의존: 파일시스템만. 파서 불필요.
  │
  ├─ graph.zig            # 모듈 그래프
  │   입력: 진입점 목록
  │   출력: 정렬된 모듈 목록 + 의존성 관계
  │   책임: DFS 순회, 순환 참조 감지, exec_index 부여
  │   의존: resolver + parser (파싱은 위임)
  │
  ├─ module.zig           # 모듈 단위 데이터
  │   입력: 파일 내용
  │   출력: AST + import/export 목록 + 심볼 테이블
  │   책임: 단일 모듈의 모든 정보 보유
  │   의존: parser, semantic analyzer
  │
  ├─ linker.zig           # 링킹 (스코프 호이스팅)
  │   입력: 모듈 그래프 + 각 모듈의 심볼
  │   출력: 글로벌 심볼 테이블 + 이름 충돌 해결
  │   책임: 심볼 바인딩, 이름 mangling, import→변수 교체
  │   의존: graph, module
  │
  ├─ tree_shaker.zig      # Tree-shaking
  │   입력: 링킹된 모듈 그래프
  │   출력: 사용/미사용 마킹
  │   책임: export 사용 추적, @__PURE__, sideEffects
  │   의존: linker
  │
  ├─ chunk.zig            # 청크 분할 (Code splitting)
  │   입력: tree-shaking된 모듈 그래프
  │   출력: 청크 목록 (어떤 모듈이 어떤 청크에)
  │   책임: 동적 import 분할, 공통 청크 추출
  │   의존: tree_shaker
  │
  └─ emitter.zig          # 출력 생성
      입력: 청크 목록 + 링킹 정보
      출력: JS 파일 + 소스맵
      책임: exec_index 순서로 코드 배치, 런타임 로더 생성
      의존: codegen (기존 Phase 4 재사용)
```
설계 원칙:
- **단방향 의존**: resolver → graph → linker → tree_shaker → chunk → emitter
- **독립 테스트 가능**: 각 모듈이 입력/출력 명확, 다른 모듈의 내부를 모름
- **기존 코드 재사용**: parser, semantic, codegen, transformer를 도구로 위임

##### 번들러 테스트 전략 (TDD)
- **원칙**: 버그 하나 = 테스트 하나. 이슈 재현 테스트 먼저 → 수정 → 같은 버그 재발 방지
- **모듈별 유닛 테스트**: 파일시스템 없이 가짜 데이터로 격리 테스트
  - resolver ~50개 (확장자 해석, package.json exports, tsconfig paths, node_modules 탐색)
  - graph ~40개 (실행 순서, 순환 참조, 동적 import, re-export 체인)
  - linker ~30개 (이름 충돌, import 교체, CJS 래핑)
  - tree_shaker ~30개 (미사용 export, sideEffects, @__PURE__)
  - emitter ~50개 (실행 비교, 소스맵, edge case)
- **픽스처 테스트**: `tests/bundler/fixtures/` — 입력 파일 → 기대 출력 비교
- **실행 비교 테스트 (핵심)**: 번들 결과를 실행해서 동작 확인 (출력 형태보다 실행 결과가 중요)
- **호환 테스트**: 같은 입력으로 Rollup과 실행 결과 비교 (Rolldown 방식)
- ✅ **스모크 테스트**: 29개 패키지 빌드+실행 검증 (CI 통합, packages/benchmark/smoke.ts)
- **도입 순서**: B1에서 유닛+픽스처 → B2에서 실행 비교+호환 → ✅ 프로덕션 전 스모크

##### 실전 검증 로드맵
- **1단계 (지금 가능)**: 실제 .ts/.tsx 파일을 ZTS로 변환, esbuild/SWC 출력과 비교
- **2단계 (Arena 후)**: `hyperfine`으로 대형 파일 벤치마크 (ZTS vs esbuild vs SWC). Arena 없이 벤치마크는 의미 없음
- **3단계 (N-API 후)**: `vite-plugin-zts`로 실제 React/Vue 프로젝트 개발 서버. 첫 실전 사용자 검증
- ✅ **4단계 (번들러 MVP)**: 실제 프로젝트 빌드 스모크 테스트 — 29/29 통과, CI 통합 완료

**Module에 필요한 정보 (Rollup 분석 결과):**
```zig
const Module = struct {
    path: []const u8,
    ast: ?Ast,                     // 파싱된 AST (파싱 전에는 null)
    dependencies: []ModuleIndex,   // 정적 import (순서 보장 — 배열)
    dynamic_imports: []ModuleIndex,// 동적 import (별도 관리)
    implicit_before: []ModuleIndex,// 암시적 로딩 순서
    exports: ExportMap,            // export 이름 → 심볼
    side_effects: bool,            // tree-shaking 판단
    exec_index: u32,               // DFS 후위 순서 = 실행 순서
    cycle_group: u32,              // 순환 참조 그룹 ID
    uses_top_level_await: bool,    // 동적→정적 승격 판단
    state: enum { reserved, parsing, ready },
};
```

**병렬 파싱 + 순서 보장 전략 (Rolldown 방식):**
1. 진입점 파싱 → import 발견 → 그래프에 슬롯 예약 (import 순서대로)
2. 예약된 모듈을 병렬 파싱 (파일별 Arena, 멀티스레드)
3. 파싱 완료 → 예약 슬롯에 AST 채움 → 새로운 import 발견 → 다시 슬롯 예약
4. 모든 파싱 완료 후 DFS 후위 순서로 exec_index 부여 (싱글스레드)
5. 슬롯 예약 순서가 import 순서를 보장 → exec_index가 ESM 실행 순서 보장

##### 성능 저하 위험 포인트
| 기능 | 위험도 | 원인 | 대응 |
|------|--------|------|------|
| 모듈 해석 | **높음** | 파일시스템 I/O 폭발 (node_modules 탐색) | 해석 결과 캐시, 병렬 I/O |
| Tree-shaking (깊은) | **높음** | 전체 AST 재순회 | 1단계는 export 추적만, 점진적 |
| Code splitting | **높음** | 청크 분할이 NP-hard에 근접 | esbuild처럼 단순 자동 분리 먼저 |
| 스코프 호이스팅 | 중간 | 변수 충돌 해결에 심볼 테이블 필요 | semantic analyzer 재활용 |
| 모듈 그래프 | 중간 | 파싱 대기 | 파싱과 동시 구축 (esbuild 방식) |

##### 번들러 핵심 기능 (구현 난이도 순)
```
1. ✅ 모듈 해석      ████░░░░░░  (paths, baseUrl, node_modules, exports 필드)
2. ✅ 모듈 그래프     ████░░░░░░  (import/export 관계, 순환 참조 감지)
3. ✅ Tree-shaking   ████░░░░░░  (모듈 수준, @__PURE__, @__NO_SIDE_EFFECTS__, sideEffects)
4. ✅ 번들 생성      █████░░░░░  (스코프 호이스팅, 네임스페이스 래핑)
5. 플러그인 시스템    ██████░░░░  (resolve/load/transform 훅)
6. HMR              ███████░░░  (모듈 그래프 diff, 핫 리로드 프로토콜)
7. Code splitting    ████████░░  (청크 분할 알고리즘, 공통 청크 추출, 런타임 로더)
8. CSS 번들링        ████████░░  (별도 파서, @import 해석, CSS modules)
```

##### Tree-shaking 구현 전략
- ✅ **1단계**: export 사용 추적 — 모듈 수준 tree-shaking (미사용 모듈 제거, fixpoint 분석)
- ✅ **2단계**: `@__PURE__` / `@__NO_SIDE_EFFECTS__` 활용 — 렉서 감지 → semantic/cross-module 전파 → 순수 호출 판별
- ✅ **2.5단계**: sideEffects 지원 — package.json `sideEffects: false` + 자동 순수 판별
- ✅ **2.5b**: sideEffects 글롭 패턴 — `sideEffects: ["*.css"]` 배열 형태 (matchGlob 기반)
- ⬜ **3단계**: 깊은 사이드 이펙트 분석 — getter/proxy/global 변수 판단 (후순위)
- **문장 수준 tree-shaking은 구현하지 않음** — esbuild/Bun과 동일하게 모듈 수준만 (Rollup만 문장 수준 지원)
- ZTS 유리점: semantic analyzer의 스코프/심볼이 이미 있고, `@__PURE__` 렉서 지원, 인덱스 기반 AST로 노드 제거가 태그 변경만으로 가능

##### 스코프 호이스팅 deconflict 개선 (TODO — 구조적 수정 필요)
현재: well-known global 이름 목록(`isReservedName`)을 상수로 관리. 모듈의 top-level 변수가 글로벌을 shadowing하면 리네임.
- **문제**: 목록이 환경마다 다르고 (브라우저 vs Node.js), 수동 관리 필요. 누락 시 TDZ 버그.
- **목표**: Rolldown 방식 — `root_unresolved_references()` (실제 사용된 글로벌)를 자동 수집하여 예약. 상수 목록 불필요.
  - esbuild: `SymbolUnbound` (미해석 참조 = 글로벌)를 자동 예약 + 모듈 래핑으로 TDZ 방지
  - Rolldown: 2-phase renaming — root scope 글로벌 예약 → nested scope 캡처 방지 리네임
  - 참고: `references/rolldown/crates/rolldown/src/utils/renamer.rs`, `references/rolldown/crates/rolldown/src/utils/chunk/deconflict_chunk_symbols.rs`
  - 참고: `references/esbuild/internal/renamer/renamer.go` (ComputeReservedNames)
- **구현 시점**: semantic analyzer의 스코프/심볼 데이터가 이미 있으므로, 번들러 안정화 후 진행

##### Code splitting 구현 전략
- 동적 import (`import('./page')`) 기준 청크 분할
- 공통 모듈 추출: 여러 진입점이 공유하는 모듈 → 별도 청크
- 순환 참조: 같은 청크로 묶기
- 런타임 로더: 청크를 동적 로드하는 코드 생성 (ESM 기반)

##### 플러그인 시스템 설계 (Rollup/Vite 호환)

**설계 원칙:**
- Rollup 플러그인 API 호환 (resolveId, load, transform, renderChunk, generateBundle)
- Vite 플러그인 확장 지원 (config, configureServer, hotUpdate 등은 후순위)
- N-API 바인딩을 통해 JS 플러그인 실행 (Phase 6)
- Builtin 플러그인은 Zig로 구현하여 최고 성능

**Build Hooks (빌드 단계):**
```
┌──────────────┬─────────────────────────────────────────┬──────────┐
│ 훅           │ 용도                                     │ 우선순위  │
├──────────────┼─────────────────────────────────────────┼──────────┤
│ buildStart   │ 빌드 시작 시점 (캐시 초기화 등)           │ 필수      │
│ resolveId    │ 모듈 경로 해석 커스텀 (alias, virtual)    │ 필수      │
│ load         │ 모듈 내용 로딩 (virtual module, 로더)     │ 필수      │
│ transform    │ 코드 변환 (Babel, PostCSS 등)            │ 필수      │
│ moduleParsed │ 모듈 파싱 완료 알림 (moduleInfo)          │ 중간      │
│ buildEnd     │ 빌드 종료 시점                           │ 필수      │
│ watchChange  │ watch 모드에서 파일 변경 감지             │ 중간      │
│ onLog        │ 로그/경고 필터링 및 조작                  │ 낮음      │
└──────────────┴─────────────────────────────────────────┴──────────┘
```

**Output Hooks (출력 단계):**
```
┌──────────────────┬──────────────────────────────────────┬──────────┐
│ 훅               │ 용도                                  │ 우선순위  │
├──────────────────┼──────────────────────────────────────┼──────────┤
│ renderStart      │ 출력 생성 시작                        │ 필수      │
│ renderChunk      │ 청크 코드 후처리 (banner/footer 등)    │ 필수      │
│ generateBundle   │ 번들 생성 완료 (에셋 추가/수정)        │ 필수      │
│ writeBundle      │ 디스크 쓰기 완료 후 콜백               │ 중간      │
│ augmentChunkHash │ 청크 해시에 추가 정보                  │ 낮음      │
│ closeBundle      │ 번들 완전 종료                        │ 낮음      │
└──────────────────┴──────────────────────────────────────┴──────────┘
```

**Plugin Context API (플러그인 내부에서 사용 가능한 API):**
```
this.emitFile({ type, name, source })  — 에셋/청크 동적 생성
this.getFileName(referenceId)          — emitFile로 만든 파일 이름 조회
this.resolve(source, importer)         — 다른 플러그인의 resolveId 호출
this.parse(code)                       — AST 파싱
this.warn(message) / this.error(msg)   — 진단 메시지
this.addWatchFile(path)                — watch 대상 추가
this.getModuleInfo(id)                 — 모듈 메타데이터 조회
```

**파이프라인 훅 삽입 지점 (코드베이스 분석 완료):**

현재 번들러 파이프라인과 각 훅이 삽입될 구체적 위치:
```
파일 읽기
  ↓
resolver.resolve()          ← [resolveId 훅] resolver.zig:69, resolve() 시작
  ↓
graph.parseModule()         ← [load 훅] graph.zig:238, readFileAlloc() 직전
  ↓
Transformer.transform()     AST-to-AST 변환 (TS 스트리핑, define 치환)
  ↓
Codegen.generate()          AST → JS 문자열
  ↓                         ← [transform 훅] emitter.zig:1148, codegen 직후
CJS 래핑 등
  ↓                         ← [renderChunk 훅] emitter.zig:700, 청크 완성 후
최종 출력                    ← [generateBundle 훅] bundler.zig:273, 번들 완료 시점
```

**수정 대상 파일:**
```
┌──────────────────────┬───────────────────────────────────────┬──────────┐
│ 파일                  │ 변경 내용                              │ 난이도    │
├──────────────────────┼───────────────────────────────────────┼──────────┤
│ bundler.zig          │ BundleOptions에 plugins 배열 추가 + 전파│ 쉬움     │
│ resolver.zig:69      │ resolve() 시작에 resolveId 훅 호출     │ 쉬움     │
│ graph.zig:238        │ parseModule()에 load 훅 호출           │ 중간     │
│ emitter.zig:1148     │ codegen 후 transform 훅 호출           │ 쉬움     │
│ emitter.zig:700      │ 청크 완성 후 renderChunk 훅 호출       │ 중간     │
└──────────────────────┴───────────────────────────────────────┴──────────┘
```

**구현 전략 — 2단계 접근:**

1단계: Zig Builtin 플러그인 (N-API 불필요, 즉시 가능)
- 플러그인 인터페이스를 Zig 함수 포인터로 정의
- JSON/Text/Asset 로더를 Zig builtin 플러그인으로 구현 (최고 성능)
- resolveId 훅으로 alias, virtual module 지원
- 파이프라인 단방향 구조(resolver → graph → emitter)라 훅 삽입 용이

2단계: JS 플러그인 위임 (N-API 필요)
- N-API C ABI로 Zig ↔ Node.js 바인딩
- "문자열 in, 문자열 out" — Zig와 JS가 AST를 공유하지 않음, 소스 코드 문자열만 주고받음
- Zig → N-API → JS(Babel/PostCSS) → N-API → Zig 왕복
- 성능 트레이드오프: 가능하면 Zig builtin 우선, 안 되는 것만 JS 플러그인으로 위임

**플러그인 인터페이스 예시:**
```zig
pub const Plugin = struct {
    name: []const u8,
    resolveId: ?*const fn (specifier: []const u8, importer: ?[]const u8, allocator: Allocator) !?ResolveResult = null,
    load: ?*const fn (path: []const u8, allocator: Allocator) !?[]const u8 = null,
    transform: ?*const fn (code: []const u8, id: []const u8, allocator: Allocator) !?[]const u8 = null,
    renderChunk: ?*const fn (code: []const u8, chunk_name: []const u8, allocator: Allocator) !?[]const u8 = null,
    generateBundle: ?*const fn (output_files: []const OutputFile) void = null,
};
```

**훅 실행 순서 (다중 플러그인):**
- resolveId/load: 첫 번째 non-null 반환 플러그인이 승리 (Rollup first 모드)
- transform/renderChunk: 순차 체이닝 — 이전 플러그인 출력이 다음 플러그인 입력
- generateBundle: 모두 실행 (Rollup parallel 모드)

**Builtin 플러그인 (Zig 구현):**
```
┌────────────────────────┬───────────────────────────────────────┐
│ 플러그인               │ 기능                                   │
├────────────────────────┼───────────────────────────────────────┤
│ json                   │ JSON → export default + named exports  │
│ asset                  │ 이미지/폰트 → 해시 파일명 + URL export │
│ text                   │ 텍스트 파일 → 문자열 export            │
│ glob-import            │ import.meta.glob(...) 처리             │
│ dynamic-import-vars    │ import(`./pages/${name}.ts`) 처리     │
│ wasm                   │ WASM 파일 로딩                         │
└────────────────────────┴───────────────────────────────────────┘
```

**Vite 호환 확장 (후순위):**
- config / configResolved — 설정 변환
- configureServer — 서버 커스텀
- transformIndexHtml — HTML 변환
- hotUpdate — HMR 업데이트 커스터마이징

**구현 순서:**
1. 플러그인 인터페이스 정의 (Zig struct)
2. 파이프라인에 훅 호출 삽입 (resolver, graph, emitter)
3. Builtin 플러그인 (json, text, asset)
4. N-API 바인딩 (JS 플러그인 실행)
5. Vite 호환 확장

**참고:**
- Rollup/Rolldown: `references/rolldown/packages/rolldown/src/plugin/index.ts`
- Vite: `references/vite/packages/vite/src/node/plugin.ts`
- esbuild: `references/esbuild/pkg/api/api.go` (OnResolve, OnLoad)

##### 로더 시스템 (esbuild/Rolldown 호환)

현재 ZTS는 .ts/.tsx/.js/.jsx만 처리. 플러그인의 load 훅으로 구현:
- **JSON**: `import pkg from './package.json'` → `export default {...}` + named exports
- **Text**: 파일 내용을 문자열로 `export default "..."`
- **Base64**: 파일을 base64 인코딩 `export default "data:...;base64,..."`
- **DataURL**: 파일을 data URL로 export
- **Binary**: 파일을 Uint8Array로 export
- **File/Asset**: 파일을 출력 디렉토리에 복사, 해시 파일명 URL 반환
- **Copy**: 파일을 그대로 복사
- **Empty**: 빈 모듈로 처리 (tree-shaking 대상)

CLI: `--loader:.json=json --loader:.txt=text --loader:.png=file`

##### 특수 기능 (Vite/Rolldown 호환)

**import.meta.glob (Vite 킬러 기능):**
```typescript
// 기본 — lazy import
const modules = import.meta.glob('./modules/*.ts')
// → { './modules/a.ts': () => import('./modules/a.ts'), ... }

// eager — 빌드타임 인라인
const modules = import.meta.glob('./modules/*.ts', { eager: true })

// named import만
const defaults = import.meta.glob('./modules/*.ts', { import: 'default' })

// 부정 패턴
const modules = import.meta.glob(['./src/**/*.ts', '!**/*.test.ts'])
```
구현: 렉서에서 `import.meta.glob` 감지 → 파서에서 인자 분석 → 트랜스포머에서 glob 매칭 + 코드 생성

**Dynamic Import Variables:**
```typescript
import(`./pages/${name}.ts`)
// → glob 패턴으로 확대하여 가능한 모듈 전부 번들에 포함
```

**Web Workers:**
```typescript
new Worker(new URL('./worker.ts', import.meta.url))
// → 워커 파일을 별도 엔트리로 번들링
```

**Virtual Modules:**
- resolveId 훅에서 `\0` 프리픽스로 가상 모듈 마킹
- load 훅에서 가상 모듈 내용 반환
- 파일시스템에 존재하지 않는 모듈 생성 가능

##### CLI 옵션 추가 계획 (esbuild/Rolldown 호환)

**Tier 1 (높은 우선순위 — 자주 사용됨):**
- `--banner:js=...` / `--footer:js=...` — 출력 앞뒤 텍스트 추가
- `--analyze` — 번들 사이즈 리포트
- `--minify-whitespace` / `--minify-identifiers` / `--minify-syntax` — 세분화 minify
- `--pure:Name` — 함수 단위 pure 마킹 (tree-shaking)
- `--log-level` (verbose|debug|info|warning|error|silent)
- `--legal-comments` (none|inline|eof|linked|external)
- `--servedir` — 추가 정적 디렉토리

**Tier 2 (중간 우선순위):**
- `--target` 엔진 버전 (chrome58, node10 등) — 현재 ES 타겟만
- `--keep-names` — minify 시 함수/클래스 이름 보존
- `--out-extension:.js=.mjs` — 출력 확장자 변경
- `--outbase` — 엔트리 출력 경로 기준
- `--charset=utf8` — UTF-8 코드포인트 이스케이프 안 함
- `--sources-content=false` — 소스맵에서 소스 내용 제외
- `--source-root` — 소스맵 sourceRoot 필드
- `--public-path` — 에셋 기본 URL (CDN 배포용)
- `--inject:file` — 모든 입력에 파일 자동 import
- HTTPS dev server (--certfile, --keyfile)
- CORS 설정

**Tier 3 (낮은 우선순위):**
- `--mangle-props` + `--mangle-cache` — 프로퍼티 맹글링
- `--reserve-props` — 맹글링 예외
- `--ignore-annotations` — tree-shaking 어노테이션 무시
- `--preserve-symlinks` — 심링크 해석 비활성화
- `--tsconfig-raw` — tsconfig JSON 문자열 오버라이드
- `--watch-delay` — 리빌드 디바운스
- `--log-limit` / `--log-override` — 세분화 로깅

##### 멀티스레드 모델
- **파일 파싱**: 파일별 독립 Arena → lock-free 병렬 파싱
- **모듈 그래프**: 싱글 스레드 (의존성 순서가 중요)
- **변환/코드젠**: 파일별 병렬
- Zig의 `std.Thread.Pool` + 파일별 Arena 독립으로 Rust 대비 lock contention 최소화 가능

##### 파일 변경 감지 전략
- **현재**: OS 파일시스템 이벤트 (macOS kqueue, Linux inotify, Windows ReadDirectoryChangesW) — Phase 5에서 구현 완료
- **추가 예정**:
  - 폴링 폴백: Docker 볼륨/NFS 등 OS 이벤트가 불안정한 환경 대응 (mtime 비교)
  - LSP 연동: 에디터 didSave/didChange 이벤트로 파일 저장 전에도 감지 가능
  - io_uring (Linux): inotify보다 시스템콜 오버헤드 적은 비동기 I/O (성능 최적화 시점)
- **증분 재빌드**: 파일 변경 → 모듈 그래프에서 영향받는 모듈만 재빌드 → HMR 전송 (번들러와 같이 구현)

##### HMR (Hot Module Replacement)

###### 의사결정 (D056-D058)

**D056. HTTP 서버**: `std.http.Server` (Zig 표준 라이브러리)
- Bun은 uWebSockets(C++) 사용하지만, Bun.serve()가 프로덕션 서버를 겸하기 때문
- ZTS dev server는 로컬 개발 전용 (동시 접속 1-2개) → std.http.Server로 충분
- 외부 C/C++ 의존성 없음, WASM 빌드 영향 없음
- 나중에 성능 병목 시 uWebSockets로 교체 가능 (인터페이스 동일하게 설계)

**D057. HMR API**: `import.meta.hot` 기본 + `module.hot` 어댑터
- 웹 타겟: `import.meta.hot` (Vite 호환, ESM 네이티브)
- RN 타겟: `module.hot` (Metro 호환, RN 내장 HMRClient 재사용)
- 내부 HMR 엔진은 하나, API 표면만 다름
- 번개(bungae) oxc-bundler가 동일 방식: `import.meta.hot` 기본 + metro-runtime HMRClient 교체 플러그인

**D058. HMR 프로토콜**: Vite 호환 + Metro 어댑터
- 웹: Vite HMR 프로토콜 (WebSocket JSON 메시지)
- RN: Metro HMR 프로토콜 (`update-start` → `update` → `update-done`)
- 롤리팝(rollipop)은 자체 프로토콜이지만 RN 업데이트마다 호환성 검증 필요 → Metro 호환이 유지보수 비용 낮음

```
HMR API 비교:
┌─────────────┬─────────────────────┬─────────────────────────────┐
│ 번들러       │ HMR API             │ 이유                         │
├─────────────┼─────────────────────┼─────────────────────────────┤
│ Webpack 5   │ module.hot          │ CJS 레거시                   │
│ Rspack      │ module.hot          │ Webpack 호환                 │
│ Turbopack   │ module.hot          │ Webpack 호환 (Next.js)       │
│ Vite        │ import.meta.hot     │ ESM 네이티브                 │
│ Rolldown    │ import.meta.hot     │ Vite 호환                    │
│ Metro       │ module.hot (커스텀)  │ CJS + RN 내장 HMRClient     │
│ 번개(oxc)   │ import.meta.hot     │ Rolldown DevEngine + 어댑터  │
│ ZTS (결정)  │ import.meta.hot 기본 │ Vite 호환 + RN module.hot   │
└─────────────┴─────────────────────┴─────────────────────────────┘
```

###### 구현 순서
```
기반 인프라 (✅ 완료):
  1. ✅ HTTP 정적 서버 (std.http.Server) — PR #260
  2. ✅ 번들 서빙 (on-the-fly 번들링) — PR #261
  3. ✅ WebSocket 서버 (RFC 6455) — PR #262
  4. ✅ Live Reload (thread-per-connection + watch → full-reload) — PR #263
  5. ✅ 모듈 그래프 전체 파일 감시 — PR #266
  ✅ TS non-null assertion 체이닝 수정 — PR #265
  ✅ E2E 테스트 활성화 (Playwright 5개) — PR #264, #268

즉시 가치 (작은 작업):
  6. ✅ 에러 오버레이 — PR #267
  7. ✅ 소스맵 서빙 — PR #272 (번들 레벨 V3 소스맵 + /bundle.js.map 엔드포인트)
  8. ✅ SPA 폴백 — PR #269

핵심 HMR (큰 작업):
  9. ✅ import.meta.hot API — PR #270 (모듈 래핑 dev 번들), PR #271 (모듈 단위 WS update)
  10. ✅ React Fast Refresh — PR #273 ($RefreshReg$ 주입), PR #274 (런타임 통합 + hot.accept)
  11. ✅ CSS 핫 리로드 — PR #275 (link tag swap + CSS 파일 감시)
```

###### 아키텍처
```
브라우저/RN 앱
    │
    ├─ HTTP GET /bundle.js ──→ ZTS Dev Server ──→ on-the-fly 번들링 ──→ 응답
    │
    └─ WebSocket /__hmr ─────→ HMR 채널
                                  │
         파일 변경 감지 (watch) ──→ 모듈 그래프 diff
                                  │
                                  ├─ 변경 모듈만 재빌드
                                  ├─ HMR 업데이트 메시지 전송
                                  └─ 클라이언트: accept → 모듈 재실행 → React Refresh
```

###### 참고 프로젝트
- **번개(bungae)**: `../bungae/` — oxc-bundler HMR (Rolldown DevEngine, `import.meta.hot`)
- **롤리팝(rollipop)**: `../bungae/reference/rollipop/` — 자체 HMR 프로토콜
- **Metro**: `references/metro/packages/metro-runtime/` — `module.hot`, Metro HMR 프로토콜
- **Vite**: `references/vite/packages/vite/src/client/` — `import.meta.hot`, Vite HMR 프로토콜
- **esbuild**: `--serve` 모드 — 최소 구현 참고

##### 외부 통합 (플러그인/라이브러리)
ZTS 코어를 외부 빌드 도구에서 사용할 수 있도록 다층 인터페이스 제공:
```
Zig 코어 (parser + transformer + codegen)
    │
    ├─ CLI (직접 사용) — ✅ 이미 구현
    ├─ C ABI (.so/.dylib) — Zig export fn으로 노출
    │   └─ N-API 네이티브 모듈 (npm 패키지, 최고 속도)
    │       ├─ vite-plugin-zts    (esbuild 자리 대체)
    │       ├─ zts-loader         (swc-loader 자리 대체)
    │       └─ rollup-plugin-zts
    └─ WASM (.wasm) — ✅ 빌드 이미 가능
        └─ @zts/wasm (npm 패키지)
            ├─ 브라우저 playground / 온라인 REPL
            └─ Deno/Bun/Cloudflare Workers 호환
```
- **도입 시점**: Phase 6 초반에 C ABI 노출 → N-API 바인딩 → npm 패키지 → 플러그인 래퍼
- **핵심**: N-API 바인딩 하나만 만들면 Vite/Webpack/Rollup 플러그인은 JS 래퍼 수십 줄
- esbuild, SWC가 동일한 구조로 생태계 확장에 성공한 검증된 패턴

#### 성능 최적화 도입 시기
| 최적화 | 추천 시점 | 이유 |
|--------|-----------|------|
| Arena allocator | Phase 6 시작 전 | 번들러에 필수, 늦을수록 비용 증가 |
| SIMD | 번들러 MVP 후 | 프로파일링 후 적용이 정석, 렉서만 건드려서 언제든 동일 비용 |
| 멀티스레드 | 번들러 설계 시 | 아키텍처에 스레드 모델 포함해야 함 |
| 프로파일링 | 2단계 (번들러 MVP 후 + 프로덕션 전) | 실제 워크로드 필요 |

#### 독립 기능 (아무 단계에 끼워 넣기 가능)
- React Fast Refresh — 트랜스포머에 HMR boundary 주입
- Flow 지원 — 방식 미결정 (위 "Flow 지원 전략" 참조)
- ✅ regexp validator — 렉서 내부, Test262 100% 통과

## Commands
```bash
zig build          # 빌드
zig build run      # 실행
zig build test     # 유닛 테스트
zig build test262  # Test262 러너 테스트
```

## ZTS CLI 옵션 (현재 지원)

### 트랜스파일
```bash
zts <file.ts>                    # 트랜스파일 → stdout
zts <file.ts> -o <out.js>       # 트랜스파일 → 파일
zts <dir/> --outdir <out/>      # 디렉토리 재귀 변환
zts - < input.ts                # stdin 입력
```

### 번들
```bash
zts --bundle <entry.ts>                          # 번들 → stdout
zts --bundle <entry.ts> -o out.js                # 번들 → 파일
zts --bundle <entry.ts> --splitting --outdir dist  # 코드 스플리팅
```

### 공통 옵션
```
--format=esm|cjs|iife            모듈 포맷 (기본: esm, --platform=browser 시 iife)
--platform=browser|node|neutral  타겟 플랫폼 (기본: browser)
--minify                         출력 압축
--sourcemap                      소스맵 생성 (.js.map)
--ascii-only                     non-ASCII를 \uXXXX로 이스케이프
--quotes=<style>                 문자열 따옴표 (double|single|preserve, 기본: double)
--drop=console                   console.* 호출 제거
--drop=debugger                  debugger 문 제거
--define:KEY=VALUE               글로벌 치환 (예: --define:DEBUG=false)
--external <pkg>                 패키지를 번들에서 제외 (반복 가능)
--experimental-decorators        legacy decorator 변환 (tsconfig compilerOptions 지원)
--use-define-for-class-fields=false  class field → constructor this.x = v 변환
-w, --watch                      파일 변경 감시
-p, --project <path>             tsconfig.json 경로
```

### Dev 서버
```
--serve [dir]                    정적 파일 서버 (기본: .)
--serve --bundle <entry.ts>      번들+서빙 (HMR 지원)
--port <number>                  서버 포트 (기본: 3000)
```

### 자동 동작 (esbuild 호환)
- `--platform=browser` + `--bundle` → format 기본값 IIFE (글로벌 스코프 오염 방지)
- `--platform=browser` + `--bundle` → `process.env.NODE_ENV`를 `"production"`으로 자동 define
- `--platform=browser` → Node 내장 모듈(fs, path, util 등) 빈 모듈로 대체
- `--platform=browser` → `package.json "browser"` 필드에서 disabled 파일 감지
- `--platform=node` → Node 내장 모듈 + 서브패스(fs/promises, stream/web) 자동 external
- `import.meta` → CJS+node: `require("url").pathToFileURL(__filename).href` / CJS+browser: `""`

## Test Suite

### Test262 (TC39 정합성)
```bash
zig build test262                       # 전체 실행 (50,504건)
zig build test262 -- --filter=language  # 언어 기능만
zig build test262 -- --verbose          # 상세 출력
```

### 유닛 테스트
```bash
zig build test                          # 모든 모듈 테스트
```
테스트 위치: 각 모듈 파일 하단 (`test "..." { ... }` 블록)
- `src/lexer/scanner.zig` — 렉서 유닛 테스트
- `src/parser/parser.zig` — 파서 유닛 테스트
- `src/transformer/transformer.zig` — 변환기 유닛 테스트
- `src/codegen/codegen.zig` — 코드젠 형식 테스트
- `src/bundler/bundler.zig` — 번들러 통합 테스트
- `src/semantic/analyzer.zig` — 의미 분석 테스트

### 통합 테스트 (Bun)
```bash
cd packages/integration && bun test     # CLI 통합 테스트
cd packages/e2e && bun test             # Playwright E2E (dev server)
```

### 스모크 테스트 (실제 패키지 빌드)
```bash
cd packages/benchmark && bun run smoke.ts  # 111개 패키지 빌드+실행 검증
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

### 파서 구현 순서 (PR 단위) — Phase 2 ✅ 완료
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
    - ✅ 타입 파서 전면 보강 — PR #324 (적합성 14.2%→19.4%, 에러 527→242)
      - 타입 리터럴 시그니처 7종 (콜/컨스트럭트/인덱스/getter/setter/메서드/프로퍼티)
      - 함수/컨스트럭터 타입 (new, abstract new, 제네릭, 다중 파라미터)
      - 타입 프레디케이트 (x is Type, asserts x is Type)
      - 매핑 타입 lookahead (checkpoint/rewind), 타입 파라미터 수정자 (const/in/out)
      - 제네릭 arrow function (<T>() => body), 클래스 optional 필드, import/export type
      - import x = require('y'), 함수 오버로드 시그니처, namespace export 허용
14. ✅ TS 선언 (interface, type alias, enum, namespace, declare, abstract) — PR #31
15. ✅ TS 변환 대상 (parameter property, decorator, implements, class generics) — PR #32
16. ✅ JSX 파싱 (element, fragment, attributes, expression, text) — PR #33
17. ✅ 에러 복구 강화 + Test262 파서 통과율 — Phase 2 후반
    - ✅ 에러 메시지 개선: "Expected X but found Y", 괄호 매칭 "opened here", 세미콜론 hint
    - ✅ ParseError/SemanticError → 공통 Diagnostic 타입 통합 (semantic 에러 CLI 표시 포함)
18. ✅ semantic analysis (D038, D051-D055) — Phase 2 후반
    - ✅ 파서 컨텍스트 추적 (strict/function/async/generator/loop/switch)
    - ✅ strict mode 에러 (with문), break/continue/return 검증
    - ✅ Test262 early phase 통합
    - ✅ semantic 모듈 (scope + symbol + analyzer) — PR #163
    - ✅ 변수 재선언 검증 (let/const/var 충돌)
    - ✅ checker.zig: 중복 생성자, private static 충돌, __proto__ 중복, getter/setter 파라미터 — PR #164
    - ✅ strict mode legacy octal 검증 (숫자 + 문자열 escape) — PR #165
    - ✅ 중복 파라미터 검증 (arrow/method/async/generator/strict) — PR #166
    - ✅ ?? + &&/|| 혼용 금지 — PR #167
    - ✅ Context u8 분리 + cover grammar 변환 — PR #168~#174
    - ✅ 예약어/contextual keyword 검증 (escaped keyword, strict mode, eval/arguments)

### 트랜스포머 구현 순서 (PR 단위) — Phase 3 ✅ 완료
1. ✅ Phase 3 의사결정 (D041-D043) — PR #36
2. ✅ Visitor/순회 인프라 + 새 AST 빌더 + Node 24B 수정 — PR #37
3. ✅ 타입 스트리핑 + 통합 테스트 — PR #38
4. ✅ TS expression 변환 (as, satisfies, !) — PR #37에서 구현
5. ✅ 기본 codegen (AST→JS 문자열) — PR #39
6. ✅ enum → IIFE — PR #40
7. ✅ namespace → IIFE — PR #41
8. ✅ JSX → React.createElement — PR #42
9. ✅ ESM → CJS 모듈 변환 — PR #43
10. ✅ 파서 테스트 6개 수정 — PR #44
11. ✅ parameter property 변환 — PR #45
12. ✅ CJS export const segfault 수정 — PR #46
13. ✅ decorator 지원 (class에 연결 + 출력) — PR #47
14. ✅ --drop console/debugger + define 글로벌 치환 — PR #48
15. ✅ import.meta CJS 변환 (D021) — PR #49
16. ✅ abstract 멤버 + declare 필드 스트리핑 — PR #358
17. ✅ useDefineForClassFields=false (assign semantics) — PR #360
18. ✅ experimentalDecorators (legacy decorator → __decorateClass) — PR #360
19. ✅ 적합성 파싱 에러 수정 (import attributes, named construct, 제네릭 메서드, as assignment, override param, class index signature, arrow return type, parameter decorator, postfix !) — PR #347-#362

### 코드젠 + CLI 구현 순서 (PR 단위) — Phase 4 ✅ 완료
1. ✅ Phase 4 의사결정 (D044-D046) — PR #50
2. ✅ 코드 포맷팅 (들여쓰기, 줄바꿈, minify) — PR #51
3. ✅ CLI 기본 (파일 → 파싱 → 변환 → 출력) — PR #52
4. ✅ 소스맵 V3 생성 (VLQ + JSON) — PR #53
5. ✅ --ascii-only (D031) — PR #54
    - ✅ --quotes=double|single|preserve (기본: 쌍따옴표, esbuild/oxc 호환) — PR #325
6. ✅ legal comments (@license, @preserve) — 렉서 single-line 감지 + codegen minify 보존

### CLI 고급 기능 (PR 단위) — Phase 5 완료
1. ✅ Phase 5 의사결정 (D047-D050) — PR #60
2. ✅ stdin 파이프 지원 — PR #61
3. ✅ 에러 코드 프레임 출력 (D012) — PR #62
4. ✅ 디렉토리 단위 변환 (--outdir) — PR #63
5. ✅ tsconfig.json 읽기 (--project) — PR #64
6. ✅ watch 모드 (--watch) — PR #65

## References
- Bun JS Parser: github.com/oven-sh/bun (src/js_parser.zig, src/js_lexer.zig)
- oxc: github.com/oxc-project/oxc (crates/oxc_parser/src/lexer/kind.rs — 토큰 enum 참고)
- SWC: github.com/swc-project/swc
- esbuild: github.com/evanw/esbuild
- Hermes: github.com/facebook/hermes (Flow 파서)
- Metro: github.com/facebook/metro (RN 번들러)
- Test262: github.com/tc39/test262
- ECMAScript Spec: tc39.es/ecma262
