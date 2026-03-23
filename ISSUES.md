# Known Issues

스모크 테스트 + 브라우저 E2E에서 발견된 이슈 목록.

## 번들러 런타임 에러 (scope hoisting)

### ~~zod — `z is not defined`~~ ✅ PR #313에서 해결
- namespace re-export에서 resolveExportChain이 "*"를 찾아 null 반환하는 버그 수정

### ~~rxjs — `require_rxjs_dist_cjs_index is not defined`~~ ✅ PR #313에서 해결
- CJS 모듈이 sideEffects:false로 tree-shaking 제거되는 버그 수정

### vue — 런타임 에러
- **증상**: vue 번들 (1593KB) 빌드 성공, 실행 시 `ref is not defined`
- **원인**: `export * from './index.js'` (CJS) — ESM→CJS export * chain에서 named export를 해석 못함
- **필요**: `__reExport` 런타임 헬퍼 또는 CJS namespace 객체 preamble 생성
- **esbuild**: `__reExport(vue_exports, __toESM(require_vue()))` 패턴으로 처리
- **참고**: esbuild `pkg/js_parser/js_parser_lower.go`, rolldown `crates/rolldown/src/utils/`

### supabase — 런타임 에러
- **증상**: tslib(CJS)의 `__awaiter` 등이 정의되지 않음
- **원인**: vue와 동일 — ESM 모듈이 CJS를 `import default`로 가져올 때 scope hoisting이 올바르게 처리 못함
- **esbuild/rolldown**: 정상

## ~~CLI 기능 부재~~ ✅

### ~~`--define` 옵션 미구현~~ ✅ PR #312에서 해결

## ~~메모리 누수~~ ✅

### ~~package_json.zig — sideEffects 배열 메모리 릭~~ ✅ PR #313에서 해결

## 구조적 개선 (후순위)

### binding_scanner — barrel re-export를 `.local`로 오분류
- **현상**: `import { X } from './a'; export { X }` 가 `.local` export로 분류됨
- **영향**: `resolveExportChain`에서 import_bindings를 O(N) 선형 탐색으로 보정
- **개선**: binding_scanner에서 `.re_export`로 정확히 분류하면 linker의 탐색 불필요
- **PR #308에서 workaround 적용 완료** (linker에서 import binding 확인)

### ESM→CJS `export *` 지원 (vue, supabase 해결에 필요)
- **현상**: `export * from CJS_MODULE` 에서 CJS의 export를 정적으로 알 수 없어 scope hoisting 실패
- **필요**: esbuild 방식의 `__reExport` 런타임 헬퍼 구현
- **범위**: emitter에 런타임 헬퍼 코드 생성 + linker에서 CJS export * 감지
