# Known Issues

스모크 테스트 + 브라우저 E2E에서 발견된 이슈 목록.

## 번들러 런타임 에러 (scope hoisting)

### ~~zod — `z is not defined`~~ ✅ PR #313에서 해결
### ~~rxjs — `require_rxjs_dist_cjs_index is not defined`~~ ✅ PR #313에서 해결
### ~~vue — 런타임 에러~~ ✅ PR #314에서 해결
### ~~supabase — 런타임 에러~~ ✅ PR #314에서 해결

## ~~CLI 기능 부재~~ ✅

### ~~`--define` 옵션 미구현~~ ✅ PR #312에서 해결

## ~~메모리 누수~~ ✅

### ~~package_json.zig — sideEffects 배열 메모리 릭~~ ✅ PR #313에서 해결

## ~~브라우저 호환성~~ ✅

### ~~scope hoisting에서 글로벌 변수 충돌 (effect)~~ ✅ PR #317에서 해결
### ~~`import.meta` outside module (jotai, valtio, fp-ts)~~ ✅ PR #317에서 해결
### ~~`--platform=browser`에서 `process.env.NODE_ENV` 자동 치환~~ ✅ PR #317에서 해결
### ~~Node 내장 서브패스 미해석 (zx)~~ ✅ PR #319에서 해결
### ~~cheerio 번들 실행 시 출력 없음~~ ✅ PR #319에서 해결 (__copyProps var→let)

## 구조적 개선 (후순위)

### `"type": "module"` .js 파일을 ESM으로 인식 못함 (minimatch)
- **증상**: minimatch의 `dist/esm/escape.js`가 스크립트 모드로 파싱 → `export` 에러
- **원인**: 파서에 `is_module` 플래그를 전달해야 함 (determineExportsKind가 아님)
- **esbuild/rolldown**: package.json type 필드를 파서에 전달하여 .js를 ESM 모드로 파싱
- **주의**: exports_kind를 바꾸면 CJS wrapper 생성에 영향 → regression 위험

### zx — ESM 번들에 CJS require 혼입
- **증상**: ESM 번들에 `require` 호출이 남아있어 Node ESM에서 에러
- **원인**: CJS interop이 ESM 출력에서 require를 제거하지 못함

### binding_scanner — barrel re-export를 `.local`로 오분류
- **현상**: `import { X } from './a'; export { X }` 가 `.local` export로 분류됨
- **영향**: `resolveExportChain`에서 import_bindings를 O(N) 선형 탐색으로 보정
- **개선**: binding_scanner에서 `.re_export`로 정확히 분류하면 linker의 탐색 불필요
- **PR #308에서 workaround 적용 완료** (linker에서 import binding 확인)

### ~~ESM→CJS `export *` 지원~~ ✅ PR #314에서 해결
