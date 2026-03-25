//! ES2024 다운레벨링
//!
//! --target < es2024 일 때 활성화.
//!
//! 현재 변환 대상:
//! - (없음 — ES2024 신규 문법은 대부분 런타임 API이므로 구문 변환 불필요)
//!
//! 스펙:
//! - https://tc39.es/ecma262/ (ES2024)
//! - Array.groupBy, Promise.withResolvers 등은 polyfill 영역
//!
//! 참고:
//! - esbuild: ES2024 구문 변환 없음
//! - oxc: crates/oxc_transformer/src/es2024/ (비어 있음)
