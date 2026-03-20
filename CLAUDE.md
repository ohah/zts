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
  bun/                      #   Zig — 파서/렉서/SIMD 참고
  esbuild/                  #   Go — 번들러 아키텍처/모듈 해석/설정 참고
  oxc/                      #   Rust — 트랜스포머/isolated declarations/파서 참고
  swc/                      #   Rust — 전체 기능/Flow 참고
  hermes/                   #   C++ — Flow 파서 임베딩 소스
  metro/                    #   JS — React Native 번들러/Metro 호환 참고
  rollup/                   #   JS — tree-shaking/스코프 호이스팅 원조 참고
  rolldown/                 #   Rust — Rollup 호환 번들러/Vite 통합 참고
  webpack/                  #   JS — code splitting/플러그인 시스템/HMR 참고
  vite/                     #   JS — 개발 서버/HMR/플러그인 API 참고
  turbopack/                #   Rust — 증분 컴파일/캐싱 전략 참고
  rspack/                   #   Rust — Webpack 호환 번들러/CSS 처리/플러그인 참고
  babel/                    #   JS — 플러그인 시스템/스펙 추종 참고
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
- Flow: Hermes C++ 파서를 C ABI로 링크
- Stage 3 decorator: 후순위 (스펙 안정화 후)
- Legacy decorator 우선 구현

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

번들러 선행 인프라 ✅ ───┬──→ tree-shaking (reference_count 활용)
                         ├──→ Transform 분리 (string_table + pending_nodes 활용)
                         └──→ Comment 보존 (번들러 모듈 합칠 때)

독립 (아무 때나): ES 다운레벨링, React Fast Refresh, regexp, SIMD, Flow
```

#### 추천 구현 순서
1. ✅ **Test262 마무리 + regexp validator** — 23,384건 100% 통과 (실패 0건)
2. **Arena allocator 설계 + 도입** — 번들러 전 필수 (1~3단계). 나중에 넣을수록 변경 범위 커짐
   - 1단계: Parser에 Arena 적용 (allocator 교체, 하루 소요)
   - 2단계: Semantic Analyzer에 적용 (스코프/심볼)
   - 3단계: Transformer/Codegen에 적용 (Phase별 Arena 분리)
   - 4단계: 번들러 파일별 Arena (번들러 구현 시 같이)
   - Arena = 소유권 경계. 각 모듈은 할당만, 해제는 호출자가 Arena 단위로
   - `std.heap.ArenaAllocator` 사용, `std.mem.Allocator` 인터페이스 동일하므로 기존 코드 변경 최소
   - **@panic("OOM") 정리**: 현재 44개의 `@panic("OOM")` (parser 6, lexer 5, analyzer 24, checker 9). Arena 도입 시 ArrayList append가 사라지면서 자연스럽게 해결. 번들러에서 파일별 에러 복구하려면 panic 대신 에러 전파 필요
3. **ES 다운레벨링** (ES2024→ES2016 점진적, ES2015 이후, ES5) — 트랜스포머 visitor 추가. 독립적이라 언제든 가능하지만 AST 안정화 후가 이상적
   - 1차 ES2024→ES2020 (~200줄, 1~2일): `??`, `?.`, `??=`/`||=`/`&&=`, class public field
   - 2차 ES2019→ES2016 (~500줄, 3~5일): async/await→generator+Promise, rest/spread properties
   - 3차 ES2015 (~6000줄, 4~6주): class→function/prototype, arrow→bind, let/const→var+IIFE, generator→상태 머신, destructuring, for-of, template literal
   - 4차 ES5 (~2000줄, 1~2주): polyfill + 런타임 헬퍼 (tslib 방식)
   - 참고: oxc `crates/oxc_transformer/src/es20XX/` (버전별 폴더, 가장 구조 유사), Babel `packages/babel-plugin-transform-*/` (ES5까지 완벽), esbuild `pkg/js_parser/js_parser_lower.go` (읽기 쉬움)
   - 런타임 헬퍼: `__extends`, `__awaiter`, `__generator` 등 15개+ — 필요한 것만 주입 (esbuild 방식)
4. **.d.ts 생성** (isolatedDeclarations) — 후순위. 당분간 tsc에 위임 (esbuild/SWC와 동일). 자체 구현 시 AST 순회로 export 타입 추출 (~500줄), 파일별 독립이라 번들러 불필요
5. **번들러 설계** (멀티스레드 모델 포함) — 아래 번들러 상세 참조
6. **번들러 MVP** — Arena + 멀티스레드 + 모듈 해석 통합
7. **프로파일링 → SIMD → 미니파이어** — 번들러 MVP로 현실적 벤치마크 가능. SIMD는 렉서 함수 3개 교체 (공백 스킵, 식별자 스캔, 문자열 스캔), 인터페이스 불변이라 언제 넣어도 비용 동일
   - 미니파이어 3단계: 1) whitespace (✅ 이미 있음, codegen minify) → 2) identifier mangling (번들 크기 70%, 스코프 분석 필수) → 3) syntax 최적화 (if→ternary, dead code 등)
   - mangling은 번들러의 스코프/심볼 데이터를 공유하므로 번들러 후가 효율적
   - 단독 미니파이(`zts --minify`)도 가능하지만 번들+미니파이 통합이 최대 효과
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
1. 모듈 해석 (경로 → 파일)       ← 그래프의 노드를 찾는 법
2. 모듈 그래프 구축               ← 모든 것의 기반 (ESM 순서 보장 여기서 설계)
3. 단일 파일 번들 (연결만)        ← 가장 단순한 출력, 동작 검증
4. 스코프 호이스팅                ← 번들 품질 (변수 충돌 해결)
5. Tree-shaking                  ← 번들 크기 (미사용 export 제거)
6. Code splitting                ← 고급 (청크 분할, 런타임 로더)
```
모듈 그래프가 없으면 4~6 전부 불가능. 1→2가 번들러의 핵심.

##### 번들러 Phase별 기능 분류
```
Phase B1: 기반                    Phase B2: 핵심           Phase B3: 고급
─────────────────                 ──────────────           ──────────────
모듈 해석 (Node/TS)               Tree-shaking             Code splitting
  ├ node_modules 탐색              ├ export 사용 추적       ├ 동적 import 분할
  ├ package.json exports           ├ @__PURE__              ├ 공통 청크 추출
  ├ tsconfig paths/baseUrl         ├ sideEffects 필드       ├ 런타임 로더
  └ 조건부 exports                 └ 깊은 분석 (점진적)     └ CSS code splitting
모듈 그래프                       스코프 호이스팅           플러그인 시스템
  ├ 정적 import/export             ├ 변수 이름 충돌 해결     ├ resolve/load/transform 훅
  ├ 순환 참조 감지                 ├ ESM 실행 순서 보장      ├ Rollup 플러그인 호환
  └ 동적 import                    └ CJS 호환 래핑          └ Vite 플러그인 호환
단일 파일 번들 생성               개발 서버 + HMR          React Native 지원
  └ 진입점 → 단일 출력              ├ HTTP + WebSocket       ├ Metro 호환 해석
                                   ├ import.meta.hot         ├ 플랫폼 확장자 (.ios/.android)
                                   ├ React Fast Refresh      ├ polyfill 주입
                                   └ 증분 재빌드             └ Hermes 타겟 최적화
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
  - `flowStripPlugin` — Flow 타입 제거 (Hermes 소스에서 C ABI 활용 가능)
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
- **스모크 테스트**: three.js, react, lodash 등 실제 프로젝트 빌드 (프로덕션 전)
- **도입 순서**: B1에서 유닛+픽스처 → B2에서 실행 비교+호환 → 프로덕션 전 스모크

##### 실전 검증 로드맵
- **1단계 (지금 가능)**: 실제 .ts/.tsx 파일을 ZTS로 변환, esbuild/SWC 출력과 비교
- **2단계 (Arena 후)**: `hyperfine`으로 대형 파일 벤치마크 (ZTS vs esbuild vs SWC). Arena 없이 벤치마크는 의미 없음
- **3단계 (N-API 후)**: `vite-plugin-zts`로 실제 React/Vue 프로젝트 개발 서버. 첫 실전 사용자 검증
- **4단계 (번들러 MVP)**: three.js, lodash-es, react-todomvc 등 실제 프로젝트 빌드 스모크 테스트

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
1. 모듈 해석         ████░░░░░░  (paths, baseUrl, node_modules, exports 필드)
2. 모듈 그래프 구축   ████░░░░░░  (import/export 관계, 순환 참조 감지)
3. Tree-shaking      ████░░░░░░  (export 사용 추적, @__PURE__ 활용, 사이드 이펙트 분석)
4. 번들 생성         █████░░░░░  (스코프 호이스팅, 네임스페이스 래핑)
5. 플러그인 시스템    ██████░░░░  (resolve/load/transform 훅)
6. HMR              ███████░░░  (모듈 그래프 diff, 핫 리로드 프로토콜)
7. Code splitting    ████████░░  (청크 분할 알고리즘, 공통 청크 추출, 런타임 로더)
8. CSS 번들링        ████████░░  (별도 파서, @import 해석, CSS modules)
```

##### Tree-shaking 구현 전략
- **1단계**: export 사용 추적 — 모듈 그래프에서 미사용 export 제거 (쉬움)
- **2단계**: `@__PURE__` 활용 — 렉서가 이미 추적 중, 순수 호출 제거 (중간)
- **3단계**: 사이드 이펙트 분석 — getter/proxy/global 변수 판단 (어려움)
- ZTS 유리점: semantic analyzer의 스코프/심볼이 이미 있고, `@__PURE__` 렉서 지원, 인덱스 기반 AST로 노드 제거가 태그 변경만으로 가능

##### Code splitting 구현 전략
- 동적 import (`import('./page')`) 기준 청크 분할
- 공통 모듈 추출: 여러 진입점이 공유하는 모듈 → 별도 청크
- 순환 참조: 같은 청크로 묶기
- 런타임 로더: 청크를 동적 로드하는 코드 생성 (ESM 기반)

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
- **단계적 구현**: 최소(바운더리 표시) → 중간(자체 서버) → 풀(프레임워크 통합)
- 번들러가 담당: 모듈 그래프 diff, 변경 모듈 증분 재빌드, `import.meta.hot` API 주입
- 개발 서버: HTTP + WebSocket 내장 (esbuild `--serve` 방식)
- React Fast Refresh와 연동하여 컴포넌트 상태 유지 핫 리로드
- watch 모드 + 증분 재빌드 + 파일 감지 전략을 기반으로 확장

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
- Flow 지원 — Hermes C++ 파서 C ABI 링크
- ✅ regexp validator — 렉서 내부, Test262 100% 통과

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

### 코드젠 + CLI 구현 순서 (PR 단위) — Phase 4 ✅ 완료
1. ✅ Phase 4 의사결정 (D044-D046) — PR #50
2. ✅ 코드 포맷팅 (들여쓰기, 줄바꿈, minify) — PR #51
3. ✅ CLI 기본 (파일 → 파싱 → 변환 → 출력) — PR #52
4. ✅ 소스맵 V3 생성 (VLQ + JSON) — PR #53
5. ✅ --ascii-only (D031) — PR #54
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
