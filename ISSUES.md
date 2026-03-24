# Known Issues

스모크 테스트 + 브라우저 E2E에서 발견된 이슈 목록.

## 번들러 런타임 에러 (scope hoisting)

### ~~zod~~ ✅ #313 | ~~rxjs~~ ✅ #313 | ~~vue~~ ✅ #314 | ~~supabase~~ ✅ #314

## ~~CLI 기능 부재~~ ✅ `--define` PR #312

## ~~메모리 누수~~ ✅ `package_json.zig` PR #313

## ~~브라우저 호환성~~ ✅

- ~~글로벌 충돌 (effect)~~ ✅ #317 + #321 (IIFE 기본 래핑 + isReservedName 확장)
- ~~import.meta polyfill~~ ✅ #317
- ~~auto define process.env.NODE_ENV~~ ✅ #317
- ~~Node 서브패스 external~~ ✅ #319
- ~~cheerio (__copyProps var→let)~~ ✅ #319
- ~~Node 빌트인 빈 모듈 대체~~ ✅ #321
- ~~package.json browser 필드~~ ✅ #321

## ~~파서 버그~~ ✅

- ~~JS destructuring default~~ ✅ #320 (false/true/null이 identifier로 파싱)
- ~~regex 검증 에러~~ ✅ #318 (검증 스킵, esbuild 동일)

## ~~구조적 개선~~ ✅

### ~~zx — ESM 번들에 CJS require 혼입~~ ✅
- linker가 output format을 인식하여 ESM 출력 시 import 문 유지, CJS/IIFE 출력 시 require() preamble 생성 (Rolldown 방식)

### ~~binding_scanner — barrel re-export를 `.local`로 오분류~~ ✅
- binding_scanner에서 import binding 조회하여 barrel re-export를 `.re_export`로 정확히 분류 (Rolldown 방식)
- linker workaround 제거

### ~~ESM→CJS `export *` 지원~~ ✅ PR #314

## 미해결

### zx — CJS 래핑 모듈 내부 require()가 ESM 번들에서 동작 안 함
- **증상**: `ReferenceError: require is not defined in ES module scope`
- **원인**: `__commonJS` 래핑된 모듈이 Node 빌트인(`async_hooks`)을 `require()`로 호출하는데, Node.js가 번들을 ESM으로 파싱하면 `require`가 없음
- **해결 방향**: esbuild처럼 `createRequire(import.meta.url)` 주입하여 CJS 래퍼 내부에서 require 사용 가능하게

