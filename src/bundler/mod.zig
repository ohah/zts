//! ZTS Bundler
//!
//! 여러 JS/TS 파일을 하나의 번들로 합치는 모듈 번들러.
//! Phase 6 — resolver, 모듈 그래프, 스코프 호이스팅, tree-shaking, code splitting.
//!
//! 설계:
//!   - D056: 품질 먼저 → 속도 추가 (Rolldown 전략)
//!   - D057: 모듈 그래프가 모든 기능의 기반
//!   - D081: 3계층 resolver (resolver + cache + plugin)
//!
//! 사용법:
//!   const bundler = @import("bundler/mod.zig");
//!   // (Phase B1 완성 후)
//!   // var b = bundler.Bundler.init(allocator, options);
//!   // const result = try b.bundle();

pub const types = @import("types.zig");

// 공개 타입 re-export
pub const ModuleIndex = types.ModuleIndex;
pub const ImportKind = types.ImportKind;
pub const ModuleType = types.ModuleType;
pub const ImportRecord = types.ImportRecord;
pub const BundlerDiagnostic = types.BundlerDiagnostic;

test {
    _ = types;
}
