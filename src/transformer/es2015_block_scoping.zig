//! ES2015 다운레벨링: let/const → var
//!
//! --target < es2015 일 때 활성화.
//! let x = 1  → var x = 1
//! const y = 2 → var y = 2
//!
//! kind_flags: 0=var, 1=let, 2=const
//! let/const의 kind_flags를 0(var)으로 변경하는 단순 변환.
//!
//! TDZ (Temporal Dead Zone) 에뮬레이션:
//!   현재 미구현. 루프 내 클로저가 let 변수를 캡처하는 경우
//!   IIFE로 감싸야 하지만, 대부분의 코드에서는 불필요.
//!   SWC는 ~1400줄, esbuild는 지원하지만 여기서는 v1으로 키워드만 변환.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-let-and-const-declarations (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/block_scoping/ (~1404줄)

/// let(1) 또는 const(2)이면 var(0)으로 변환.
pub fn lowerKindFlags(kind_flags: u32) u32 {
    return if (kind_flags == 1 or kind_flags == 2) 0 else kind_flags;
}

test "ES2015 block scoping module compiles" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), lowerKindFlags(0)); // var → var
    try std.testing.expectEqual(@as(u32, 0), lowerKindFlags(1)); // let → var
    try std.testing.expectEqual(@as(u32, 0), lowerKindFlags(2)); // const → var
}
