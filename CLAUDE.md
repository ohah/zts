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
- Flow: 아래 "Flow 지원 전략" 참조
- Stage 3 decorator: 후순위 (스펙 안정화 후)
- Legacy decorator 우선 구현

### Flow 지원 전략 (미결정 — 검토 필요)

#### 목표
React Native 앱 번들링 (Metro 대체). RN 코어 + 서드파티 라이브러리 전체가 Flow로 작성되어 있으므로 Flow 타입 스트리핑이 필수.

#### Flow 현황 (2024-2025)
- Meta 내부에서 계속 투자 중 — Facebook/Instagram/WhatsApp 전체가 Flow
- Hermes 엔진이 Flow를 네이티브로 실행 (트랜스파일 불필요)
- 최근 추가된 구문: `component` 선언 (2023), `hook` 선언 (2023), `match` 표현식 (2024)
- RN 새 아키텍처 (Fabric/TurboModules) codegen이 Flow 타입에서 네이티브 인터페이스 생성
- **결론: Flow는 죽지 않았고 스펙이 계속 확장 중 → 전체 스펙 지원이 필요할 수 있음**

#### Metro 소스 분석 결과 (520개 JS 파일, 450개 @flow)
```
TIER 1 (필수 — 수천 회 사용):
  타입 어노테이션 (: Type), ?Type (2,094회), 제네릭 <T> (3,176회),
  union |, +prop (covariant, 870회), export type (736회),
  type alias (515회), import type (497회), declare (932회)

TIER 2 (중간 — 수십 회):
  opaque type (12회), interface (19회), /*:: */ 주석 타입 (26회)

TIER 3 (미사용 또는 극히 드뭄):
  component 선언 (0회), hook 선언 (0회), {| exact |} (소스에서 0회),
  $ReadOnly 등 유틸리티 (소스에서 0회), : mixed (3회), : * (1회)
```

#### 선택지 비교
```
┌─────────────────────┬──────────┬──────────┬──────────────────────────┐
│ 방식                 │ 초기 비용 │ 유지보수  │ 특징                      │
├─────────────────────┼──────────┼──────────┼──────────────────────────┤
│ A. ZTS 파서에 직접   │ 1-2주    │ 높음     │ 외부 의존성 0, WASM 그대로 │
│    Flow 구문 추가    │ (TIER1만)│ (스펙 변경│ comptime 분기로 모드 추가  │
│    (Hermes cpp 참고) │ 2-3주    │  시 직접  │ 128개 C++ 파일 불필요      │
│                     │ (전체)   │  수정)   │                          │
├─────────────────────┼──────────┼──────────┼──────────────────────────┤
│ B. Hermes C++ 파서를 │ 2-3주    │ 낮음     │ Flow 100% 커버            │
│    Zig build로 링크  │          │ (Hermes  │ C++ 128개 파일 빌드 필요   │
│    (@cImport C ABI)  │          │  업데이트 │ 크로스 컴파일 복잡         │
│                     │          │  만)     │ 바이너리 +5MB             │
│                     │          │          │ WASM 빌드 시 C++ 체인 필요 │
├─────────────────────┼──────────┼──────────┼──────────────────────────┤
│ C. hermes-parser     │ 2-3주    │ 낮음     │ Flow 100% 커버            │
│    WASM를 wasm3      │          │ (npm     │ wasm3 C 라이브러리 링크    │
│    런타임으로 실행    │          │  업데이트 │ 바이너리 AST 역직렬화 필요 │
│                     │          │  만)     │ 네이티브보다 느림          │
│                     │          │          │ Emscripten 인터페이스 호환 │
└─────────────────────┴──────────┴──────────┴──────────────────────────┘
```

#### 핵심 트레이드오프
- **A (직접 구현)**: 초기 가장 빠르지만, Flow 스펙이 계속 확장되면 유지보수 부담 누적
- **B (Hermes C++ 링크)**: Meta가 스펙을 유지보수하지만, C++ 빌드 시스템 통합이 복잡
- **C (WASM 런타임)**: B와 비슷하지만 성능 오버헤드 + Emscripten 인터페이스 해석 필요
- Zig는 C/C++을 `build.zig`로 직접 컴파일 가능 → B 방식에서 CMake 불필요

#### Hermes C++ 파서 의존성 (B 방식 시 필요한 파일)
```
lib/Parser/     9개 cpp  — 파서 본체 (Flow/JSX/TS 포함)
lib/AST/       11개 cpp  — AST 노드 정의
lib/Support/   31개 cpp  — 유틸리티
lib/ADT/        1개 cpp  — 자료구조
Platform/Unicode/ 6개 cpp — 유니코드
external/llvh/ 70개 cpp  — LLVM 포크 (SmallVector 등)
합계:         128개 C++ 파일
```

#### 미결정 사항
- [ ] Flow 스펙 전체가 필요한가, Metro 수준(TIER 1+2)이면 충분한가?
- [ ] A/B/C 중 어떤 방식으로 갈 것인가?
- [ ] A 방식 선택 시, 추후 스펙 확장(component/hook/match)은 어떻게 대응?
- [ ] B 방식 선택 시, WASM 빌드에 C++ 체인이 추가되는 것을 수용할 것인가?

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
1. ✅ **Test262 마무리 + regexp validator** — 23,384건 100% 통과 (실패 0건)
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
   - 미니파이어 3단계: 1) whitespace (✅ 이미 있음, codegen minify) → 2) identifier mangling (번들 크기 70%, 스코프 분석 필수) → 3) syntax 최적화 (if→ternary, dead code 등)
   - mangling은 번들러의 스코프/심볼 데이터를 공유하므로 번들러 후가 효율적
   - SIMD는 렉서 함수 3개 교체, 인터페이스 불변이라 언제 넣어도 비용 동일
7. **ES 다운레벨링** (ES2024→ES2016 점진적, ES2015 이후, ES5) — 번들러 완성 후 진행
   - 1차 ES2024→ES2020 (~200줄): `??`, `?.`, `??=`/`||=`/`&&=`, class public field
   - 2차 ES2019→ES2016 (~500줄): async/await→generator+Promise, rest/spread properties
   - 3차 ES2015 (~6000줄): class→function/prototype, arrow→bind, let/const→var+IIFE, generator→상태 머신
   - 4차 ES5 (~2000줄): polyfill + 런타임 헬퍼 (tslib 방식)
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
  ├ package.json exports           ├ __commonJS/__toESM         ├ Rollup 플러그인 호환
  ├ tsconfig paths/baseUrl         └ ExportsKind 승격           └ Vite 플러그인 호환
  └ 조건부 exports                ✅ Top-level await           React Native 지원
✅ 모듈 그래프                     ├ semantic analyzer 감지     ├ Metro 호환 해석
  ├ 정적 import/export              ├ 전이적 전파               ├ 플랫폼 확장자 (.ios/.android)
  ├ 순환 참조 감지                  └ 비-ESM 경고               ├ polyfill 주입
  └ 동적 import                   ✅ Code splitting             └ Hermes 타겟 최적화
✅ 단일 파일 번들 생성              ├ BitSet 도달 가능성        CSS 번들링
  └ 진입점 → 단일 출력               ├ 공통 청크 자동 추출       ├ 별도 파서
✅ 스코프 호이스팅                  ├ 멀티 파일 emitter         └ CSS modules
  ├ 변수 이름 충돌 해결              └ CLI --splitting
  ├ ESM 실행 순서 보장             개발 서버 + HMR
  └ CJS 호환 래핑                   ├ ✅ HTTP + WS + Live Reload
✅ Tree-shaking (모듈 수준)         ├ ✅ 모듈 그래프 파일 감시
  ├ export 사용 추적                 ├ ✅ 에러 오버레이 + 소스맵
  ├ @__PURE__ / @__NO_SIDE_EFFECTS__├ ✅ import.meta.hot + Fast Refresh
  ├ sideEffects 필드                 └ ✅ CSS 핫 리로드
  ├ sideEffects 필드
  └ cross-module 전파
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
- ⬜ **2.5b**: sideEffects 글롭 패턴 — `sideEffects: ["*.css"]` 배열 형태 (작은 작업)
- ⬜ **3단계**: 깊은 사이드 이펙트 분석 — getter/proxy/global 변수 판단 (후순위)
- **문장 수준 tree-shaking은 구현하지 않음** — esbuild/Bun과 동일하게 모듈 수준만 (Rollup만 문장 수준 지원)
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
