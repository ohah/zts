# ZTS Decision Records

프로젝트 진행 중 내려야 할 의사결정 목록과 현재 상태.

---

## 결정 완료

### D001: 프로그래밍 언어
- **결정**: Zig
- **이유**: 학습 목적 + arena allocator가 언어 네이티브, SIMD @Vector 빌트인, 빠른 컴파일, C ABI 호환, 작은 WASM 출력

### D002: 타입 체크
- **결정**: 안 함
- **이유**: SWC/oxc/Bun/esbuild 전부 동일 전략. tsc에 위임

### D003: Stage 3 Decorator
- **결정**: 후순위 (스펙 안정화 후)
- **이유**: oxc와 같은 전략. 스펙 불안정 + 유지보수 부담

### D004: AST 메모리 설계
- **결정**: 인덱스 기반 + arena allocator
- **이유**: 안정성 (use-after-free 방지) + 성능 (캐시 효율)

### D005: TypeScript 버전 지원 범위
- **결정**: TS 5.8 (최신 stable) 전체 지원, 새 버전 나오면 점진적 추가
- **이유**: TS 구문은 누적(상위 호환). 5.8 파서를 만들면 4.x도 자동 파싱. 버전별 차이는 트랜스포머 분기로 처리

### D006: ESM / CJS 출력 형식
- **결정**: ESM + CJS 둘 다 지원. UMD는 Phase 6 (번들러)에서 추가
- **이유**: SWC/oxc 둘 다 지원. UMD는 사용 빈도가 낮아 후순위

### D007: ES 다운레벨링 타겟 범위
- **결정**: 처음엔 안 함 (TS 변환만). Phase 6에서 ES2024→ES2016 순으로 점진적 하향 추가. ES2015는 그 이후. ES5는 미정
- **이유**: oxc와 같은 전략. 최신 변환이 단순하므로 위에서 아래로 내려감. ES2015 변환(클래스, 구조분해 등)은 난이도가 급상승하므로 후순위
- **참고**: oxc는 ES2016 이상 완성, ES2015는 화살표 함수만 지원. SWC는 ES5까지 전부 지원

### D008: JSX Transform 방식
- **결정**: Classic + Automatic 둘 다 지원
- **이유**: 파서에는 영향 없음. JSX 구문 파싱은 동일하고 트랜스포머에서 설정으로 분기. SWC/oxc 둘 다 전부 지원

### D009: 소스맵
- **결정**: inline + external + hidden 전부 지원
- **이유**: 소스맵 코어를 한 번 만들면 출력 방식은 플래그 차이일 뿐. 프로덕션 도구라면 전부 필요
  - inline: JS 파일 끝에 base64로 삽입 (개발용)
  - external: 별도 .map 파일 생성 (프로덕션 표준)
  - hidden: .map 생성하지만 JS에 URL 주석 안 넣음 (Sentry 등 별도 업로드용)

### D010: tsconfig.json 지원 범위
- **결정**: 모든 옵션을 파싱하되, Phase별로 사용 범위를 구분
- **이유**: 추후 번들러 확장 시 tsconfig 파서를 다시 만들지 않도록 미리 전부 파싱

| 옵션 | 트랜스파일러 (Phase 3-5) | 번들러 (Phase 6) |
|------|------------------------|-----------------|
| target | O | O |
| module | O | O |
| jsx / jsxFactory / jsxFragmentFactory / jsxImportSource | O | O |
| experimentalDecorators / emitDecoratorMetadata | O | O |
| useDefineForClassFields | O | O |
| verbatimModuleSyntax | O | O |
| alwaysStrict | O (CJS 출력 시 "use strict" 삽입) | O |
| extends | O (tsconfig 상속) | O |
| isolatedModules | 읽되 false면 경고 출력 (항상 true 동작) | 번들러에서 false 지원 가능 |
| paths / baseUrl | 파싱만, 사용 안 함 | **활성화** |
| moduleResolution | 파싱만, 사용 안 함 | **활성화** |
| strict (하위 옵션들) | 무시 (타입 체크 전용, 출력 JS에 영향 없음) | 무시 |

### D011: isolatedModules 모드
- **결정**: 항상 isolatedModules 모드 (파일 단위 독립 처리)
- **이유**: SWC/oxc/esbuild/Bun 전부 이 방식. 크로스 파일 분석은 번들러 영역. const enum은 같은 파일 내에서만 인라이닝, 크로스 파일은 일반 enum으로 폴백

### D012: 에러 출력 형식
- **결정**: 코드 프레임(기본) + JSON (`--format json`)
- **이유**: CLI 도구의 첫인상이 에러 메시지에서 결정됨. 코드 프레임은 사람이 읽기 좋고, JSON은 에디터/CI 연동용. 렉서부터 line/column 추적 필수

### D013: Plugin / 확장 시스템
- **결정**: WASM 플러그인 (Phase 6)
- **이유**: 초기에는 코어에 집중. WASM 플러그인은 언어 무관 + 샌드박싱 가능. SWC도 WASM 플러그인 방식

### D014: 공개 AST API 제공 여부
- **결정**: WASM으로 공개 (Phase 6)
- **이유**: 브라우저 플레이그라운드, JS에서 AST 직접 조작 가능. Bun이 안 하는 것을 해서 차별화. linter/formatter/codemod가 zts 위에 올라올 수 있는 생태계 기반

### D015: 소스 위치 저장 방식
- **결정**: start + end byte offset (8바이트, oxc 방식). line/column은 별도 line offset 테이블에서 lazy 계산
- **이유**: 코드 프레임 에러 출력(D012)에서 밑줄(`^^^^`) 표시에 end가 필요. esbuild/Bun은 start만(4바이트)이지만 에러 범위 표시가 제한적. oxc/SWC도 start+end 방식
- **참고**: line/column은 AST 노드에 저장하지 않음 (4개 도구 모두 동일). 에러 출력이나 소스맵 생성 시 line offset 테이블에서 계산

### D016: 헬퍼 함수 전략
- **결정**: 인라인 + 외부(tslib) 둘 다 지원
- **이유**: 인라인은 의존성 없이 동작, 외부는 출력 크기 절약. SWC도 둘 다 지원 (`externalHelpers` 옵션)
  - 기본: 인라인 (파일마다 필요한 헬퍼를 삽입)
  - 옵션: 외부 (`import { __awaiter } from "tslib"`)

### D017: .d.ts 생성 (isolatedDeclarations)
- **결정**: 지원 (Phase 5)
- **이유**: TS 5.5의 isolatedDeclarations로 타입 체크 없이 .d.ts 생성 가능. oxc만 지원하고 SWC/esbuild는 미지원 → 큰 차별화 포인트. 파서가 타입 어노테이션을 AST에 보존해야 하므로 파서 설계에 영향

### D018: loose 모드
- **결정**: Phase 6에서 추가
- **이유**: 스펙 준수가 우선. loose 모드는 비표준이지만 빠른 출력이 필요한 프로젝트를 위해 추후 제공. Babel/SWC는 지원, esbuild는 미지원

### D019: 렉서 추가 기능
- **결정**: 아래 항목 전부 지원
  - **Hashbang (`#!`)**: 첫 줄의 `#!/usr/bin/env node`를 주석으로 인식 + 출력에 보존
  - **BOM 처리**: UTF-8 BOM(0xEF 0xBB 0xBF)을 파일 시작에서 스킵, 출력에는 넣지 않음
  - **줄 끝 문자**: `\n`, `\r\n`, `\r`, U+2028, U+2029 전부 줄바꿈으로 인식
  - **유니코드 식별자**: `\uXXXX`, `\u{XXXX}` 이스케이프 시퀀스 지원 + 정규화
  - **import attributes**: `with { type: "json" }` + deprecated `assert { type: "json" }` 둘 다 파싱
  - **direct eval 감지**: `eval()` 직접 호출 감지 → 해당 스코프 변수 최적화 비활성화

### D020: define (전역 치환)
- **결정**: 지원 (Phase 3)
- **이유**: `process.env.NODE_ENV` → `"production"` 등 거의 모든 프로젝트에서 필요. esbuild의 킬러 피처

### D021: import.meta CJS 변환
- **결정**: 지원 (Phase 3)
- **이유**: ESM→CJS 변환 시 `import.meta.url` → `require('url').pathToFileURL(__filename).href` 등 변환 필요. esbuild 방식 참고

### D022: Legal 코멘트 처리
- **결정**: 지원 (Phase 4)
- **이유**: `@license`, `@preserve` 주석 처리. esbuild의 `--legal-comments` 옵션 참고 (none/inline/eof/external)

### D023: --platform 옵션
- **결정**: browser / node / neutral 3가지 (Phase 5)
- **이유**: `import.meta`, `__dirname`, `require` 등의 변환 동작이 플랫폼에 따라 다름. esbuild와 동일

### D024: Flow 타입 시스템 지원
- **결정**: 지원 (Hermes C++ 파서를 Zig에서 C ABI로 링크)
- **이유**: React Native 프로젝트에서 Flow를 사용. 자체 구현 대신 Hermes 파서 임베딩으로 작업량 최소화
- **방식**: Hermes C++ 파서를 static library로 빌드 → Zig에서 @cImport로 호출 → ESTree AST 반환 → zts가 변환/코드젠
- **참고**: hermes-parser(npm)는 이미 WASM 빌드 존재. SWC는 자체 Flow 스트리핑 구현, oxc는 미지원

### D025: `@__PURE__` / `@__NO_SIDE_EFFECTS__` 주석 추적
- **결정**: 렉서에서 지원
- **이유**: 트리쉐이킹의 핵심. esbuild/Bun/oxc 전부 렉서에서 이 주석을 토큰에 달아줌. 함수 호출이 부작용 없음을 표시하는 사실상 표준

### D026: JSX pragma 주석 감지
- **결정**: 렉서에서 지원
- **이유**: `/** @jsx h */`, `/** @jsxRuntime automatic */` 등 파일 상단 주석에서 JSX 설정 오버라이드. esbuild/Bun/SWC 전부 지원. 렉서가 파일 시작 주석에서 추출

### D027: AMD / SystemJS 모듈 출력
- **결정**: 미지원
- **이유**: 거의 사장된 형식. SWC만 지원하고 esbuild/oxc/Bun은 미지원

### D028: Compiler Assumptions (Babel 호환)
- **결정**: Phase 6에서 점진적 추가
- **이유**: pure_getters, set_public_class_fields 등 20개+ 가정. 다운레벨링할 때만 의미 있으므로 ES 다운레벨링과 함께 추가. oxc 6개, SWC 20개+ 지원

### D029: React Fast Refresh
- **결정**: Phase 5에서 지원
- **이유**: HMR 필수. $RefreshReg$, $RefreshSig$ 헬퍼 삽입. Bun/SWC/oxc 전부 지원. 개발 서버(Vite, Next.js, Metro) 연동에 필요

### D030: 미니파이 세분화
- **결정**: Phase 6, 3가지 개별 제어 (whitespace / syntax / identifiers)
- **이유**: esbuild/Bun 방식. 디버깅용 공백만 제거, 프로덕션용 전부 등 유스케이스별 조합 가능

### D031: `--ascii-only` (ASCII 전용 출력)
- **결정**: Phase 4 코드젠에서 지원
- **이유**: non-ASCII를 `\uXXXX`로 이스케이프. 레거시 환경/빌드 파이프라인 호환. esbuild/SWC 지원

### D032: `--drop` (코드 제거)
- **결정**: Phase 3에서 지원 (console, debugger, labels)
- **이유**: 프로덕션 빌드 필수. `--drop=console`, `--drop=debugger`, `--drop-labels=DEV`. esbuild 방식 참고

### D033: `--keep-names` (함수/클래스 이름 보존)
- **결정**: Phase 6 미니파이어와 함께
- **이유**: 미니파이 시 Function.name 보존. React DevTools, 에러 스택트레이스에 필요. Object.defineProperty로 원래 이름 복원

---

### D034: 토큰 enum 설계
- **결정**: oxc 방식 — 세분화 `#[repr(u8)]` 플랫 enum (~208개)
- **이유**: TS 키워드를 개별 토큰으로 (파서에서 문자열 비교 불필요), 숫자를 11가지로 세분화 (Decimal/Float/Hex/Octal/Binary/BigInt 등), JSXText 전용 토큰. linter/AST API(D014) 확장 시 풍부한 토큰 정보가 유리. 208개도 u8에 들어가므로 성능 차이 없음
- **참고**: esbuild/Bun은 ~86-107개 (미니멀), SWC는 ~120개 (Token + TokenValue 분리)

### D035: 문자열 인코딩
- **결정**: UTF-8 기본, lazy UTF-16 변환 (Bun 방식)
- **이유**: 실제 JS 코드의 95%+가 ASCII라 변환 거의 안 일어남. UTF-8이면 소스를 슬라이스로 참조 가능 (복사 없음). 정확한 JS 문자열 시맨틱이 필요한 경우에만 UTF-16 변환

### D036: 렉서-파서 연동 방식
- **결정**: 파서가 렉서 호출 (esbuild/Bun 방식) + 옵션으로 토큰 저장 (oxc 방식)
- **이유**: 메모리 효율 (토큰 배열 없음), regex/JSX 컨텍스트 피드백이 자연스러움. 나중에 AST API(D014)/linter에서 토큰 저장 모드를 옵션으로 추가

---

## 전략적 의사결정 완료 (D001-D036)

---

## Phase별 미래 결정 사항 (구현 시작 시 논의)

### Phase 2 (파서) — 결정 완료

### D037: AST 노드 설계
- **결정**: 고정 24바이트 + 인덱스 참조 (Bun 방식)
- **이유**: 연속 메모리 배치 → 캐시 효율 최고. 작은 데이터는 인라인, 큰 데이터는 포인터로 arena에. 인덱스 참조로 use-after-free 원천 차단. Bun이 Zig로 검증. 나중에 C(16B 사이드 테이블)로 전환하기 어렵지만, 이미 최적에 가까움
- **참고**: oxc는 가변 크기(40-96B), esbuild는 Go GC

### D038: 스코프/심볼 테이블
- **결정**: 별도 패스 (파서와 분리, oxc 방식)
- **이유**: 파서는 AST만 생성, semantic analysis가 스코프/심볼을 구축. 관심사 분리로 유지보수/확장성 우수. linter/formatter/type checker가 semantic 모듈을 독립 재사용 가능. 속도 차이 30-50%이지만 oxc가 이 방식으로 SWC보다 3배 빠름 — 전체 아키텍처가 성능을 결정
- **참고**: Bun/esbuild는 파싱 중 구축 (A 방식)

### D039: 에러 복구 전략
- **결정**: 계속 파싱 (다중 에러 수집)
- **이유**: SWC/oxc/Bun/esbuild 전부 이 방식. 에러를 만나면 동기화 토큰(; } EOF)까지 스킵하고 계속 파싱. 한 번 실행에 여러 에러를 보여줘서 사용자 경험 좋음

### D040: 파서 패스 수
- **결정**: 2패스 (parse → visit, Bun 방식)
- **이유**: 각 패스가 한 가지 일만 해서 유지보수 쉬움. 새 변환 추가 시 visit에만 추가하면 됨. 속도 차이 20-30%이지만 Bun이 2패스로도 esbuild보다 빠름. 나중에 성능이 필요하면 패스 합치기 가능 (반대 방향은 재작성)

### Phase 3 (트랜스포머) — 결정 완료

### D041: Transformer 전략
- **결정**: 새 AST 생성 + 별도 Codegen (oxc/SWC 방식)
- **이유**: Phase 6에서 .d.ts 생성, 미니파이어, 번들러가 변환된 AST를 재사용해야 함. 24B 고정 노드 + ArrayList 구조에서 in-place 변환(노드 수 증가)은 매우 어려움. arena allocator로 원본 AST를 변환 후 한 번에 해제하면 메모리 2배 문제 완화
- **비교**: esbuild는 변환+출력 합침(빠르지만 확장 어려움), in-place 수정은 노드 증가 변환에 부적합
- **참고**: oxc(Visit+Traverse 분리), SWC(Fold+VisitMut) 모두 이 방식

### D042: Visitor 패턴
- **결정**: Switch 기반 + comptime 보조 (esbuild/Bun 방식)
- **이유**: 큰 switch문이 가장 단순하고 유지보수 쉬움. 새 변환 = case 추가. 점프 테이블 성능은 comptime 인라인과 실측 차이 미미 (노드당 3-5사이클, 초대형 파일에서 ~0.4ms). oxc를 이기는 핵심은 visitor 패턴이 아니라 메모리 레이아웃과 할당 최적화. comptime은 타입 삭제 대상 그룹 판별 등 반복적인 부분에만 보조 사용
- **비교**: comptime visitor(A)는 ~190개 인라인 함수로 icache 압박 위험. enter/exit 콜백(C)은 Zig에서 함수 포인터 간접 호출 오버헤드 + 과설계
- **참고**: esbuild(순수 switch), Bun(switch+comptime), oxc(trait visitor 코드생성), SWC(trait Fold/VisitMut)

### D043: 변환 순서 및 패스 전략
- **결정**: 단일 패스, 변환 우선순위로 순서 제어
- **이유**: 대부분의 변환이 독립적 (타입 스트리핑, JSX, 모듈). 의존성이 있는 경우(decorator→class) switch 내에서 순서 제어. 멀티 패스는 AST를 여러 번 순회하므로 성능 손해
- **변환 우선순위**: (1) 타입 스트리핑 (2) TS expression (as/satisfies/!) (3) enum→IIFE (4) namespace→IIFE (5) parameter property (6) JSX (7) ESM→CJS (8) decorator

### Phase 4 (코드젠) 시작 시
- 들여쓰기 방식 (탭 vs 스페이스, 기본값)
- 줄바꿈 처리 (원본 보존? 정규화?)
- 소스맵 v3 인코딩 세부 (VLQ 구현 방식)

### Phase 5 (CLI) 시작 시
- 설정 파일 (tsconfig만? zts.config.json 별도?)
- watch 구현 방식 (polling vs fsevents/inotify)
- 출력 디렉토리 전략 (rootDir/outDir 미러링 세부 규칙)
- stdin/stdout 프로토콜 (JSON-RPC? 단순 파이프?)

### Phase 6 (Advanced) 시작 시
- 번들러 아키텍처 (의존성 그래프, 청크 분할)
- 트리쉐이킹 수준 (문/식/프로퍼티)
- WASM 플러그인 인터페이스 (ABI 설계, 데이터 직렬화)
- WASM AST API 직렬화 (ESTree 호환? 자체 포맷?)
