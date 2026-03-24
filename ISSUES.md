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

## 구조적 개선 (후순위)

### zx — ESM 번들에 CJS require 혼입
- **증상**: ESM 번들에 `require` 호출이 남아있어 Node ESM에서 에러
- **원인**: CJS interop이 ESM 출력에서 require를 제거하지 못함

### binding_scanner — barrel re-export를 `.local`로 오분류
- **현상**: `import { X } from './a'; export { X }` 가 `.local` export로 분류됨
- **PR #308에서 workaround 적용 완료**

### ~~ESM→CJS `export *` 지원~~ ✅ PR #314
