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
- **결정**: 처음엔 안 함 (TS 변환만). Phase 6에서 ES2024→ES2016 순으로 점진적 하향 추가. ES2015는 그 이후. ES5는 미지원
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

---

## 모든 의사결정 완료

추가 결정이 필요한 경우 구현 중 발생 시 즉시 논의 후 이 문서에 추가.
