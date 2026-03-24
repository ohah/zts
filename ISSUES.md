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

## 브라우저 호환성

### scope hoisting에서 글로벌 변수 충돌 (effect)
- **증상**: `Identifier 'window' has already been declared`
- **원인**: deconflict에서 `window`, `document` 등 브라우저 글로벌을 예약하지 않음
- **esbuild**: `SymbolUnbound`(미해석 참조)를 자동 수집하여 예약 — 하드코딩 목록 없음
- **rolldown**: `GLOBAL_OBJECTS` 하드코딩 + 중첩 스코프 확인 (2중 방어)
- **수정 방향**: esbuild 방식(unbound 자동 수집) + rolldown 방식(중첩 스코프 확인)
- **참고**: `references/esbuild/internal/renamer/renamer.go:15` (ComputeReservedNames)
- **참고**: `references/rolldown/crates/rolldown/src/utils/renamer.rs:42`

### `import.meta` outside module (jotai, valtio, fp-ts)
- **증상**: IIFE/script 출력에서 `import.meta` 사용 시 브라우저 에러
- **esbuild/rolldown**: ESM은 유지, CJS는 `require('url').pathToFileURL(__filename).href`로 polyfill
- **rolldown 추가 확장**: `import.meta.dirname`, `import.meta.filename`, `ROLLUP_FILE_URL_*`
- **수정 방향**: ESM 유지, CJS/IIFE에서 platform별 polyfill + rolldown 확장도 지원

### `--platform=browser`에서 `process.env.NODE_ENV` 자동 치환 미구현
- **증상**: vue, react, immer, mobx 등이 브라우저에서 `process is not defined` 에러
- **현재**: 매번 `--define:process.env.NODE_ENV="production"` 수동 전달 필요
- **esbuild**: `--platform=browser`이면 자동으로 `process.env.NODE_ENV`를 치환
- **rolldown/vite**: `mode` 옵션으로 자동 치환
- **webpack**: `DefinePlugin` + `mode: "production"`으로 자동 치환
- **수정 방향**: `--platform=browser`이면 `process.env.NODE_ENV`를 `"production"`으로 자동 define

## 구조적 개선 (후순위)

### `"type": "module"` .js 파일을 ESM으로 인식 못함 (minimatch)
- **증상**: minimatch의 `dist/esm/escape.js`가 스크립트 모드로 파싱 → `export` 에러
- **원인**: graph.zig에서 package.json `"type": "module"` 체크가 파싱 모드에 반영 안 됨
- **esbuild/rolldown**: package.json type 필드를 인식하여 .js를 ESM으로 파싱

### Node 내장 서브패스 미해석 (zx)
- **증상**: `stream/web` 등 Node 내장 모듈의 서브패스를 resolve 못함
- **원인**: resolver가 `stream`, `fs` 등 bare name만 external 처리하고 서브패스는 미처리
- **esbuild**: `stream/web`, `fs/promises` 등 서브패스도 자동 external

### cheerio 번들 실행 시 출력 없음
- **증상**: 번들 성공, 에러 없음, 하지만 `console.log` 출력 안 됨
- **원인**: 미조사

### binding_scanner — barrel re-export를 `.local`로 오분류
- **현상**: `import { X } from './a'; export { X }` 가 `.local` export로 분류됨
- **영향**: `resolveExportChain`에서 import_bindings를 O(N) 선형 탐색으로 보정
- **개선**: binding_scanner에서 `.re_export`로 정확히 분류하면 linker의 탐색 불필요
- **PR #308에서 workaround 적용 완료** (linker에서 import binding 확인)

### ~~ESM→CJS `export *` 지원~~ ✅ PR #314에서 해결
