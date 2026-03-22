//! ZTS Bundler — Chunk / ChunkGraph
//!
//! Code splitting의 기본 자료구조: BitSet, Chunk, ChunkGraph.
//!
//! 각 진입점(entry point)마다 하나의 비트를 할당하고,
//! 모듈이 어떤 진입점들에서 도달 가능한지를 BitSet으로 추적한다.
//! 동일한 BitSet을 가진 모듈들은 같은 Chunk로 묶인다.
//!
//! 설계:
//!   - esbuild/Rolldown 방식: 진입점 비트 마스크로 청크 분할
//!   - BitSet: 값 타입, HashMap 키로 사용 가능 (hash/eql 구현)
//!   - ChunkGraph: 청크 목록 + 모듈→청크 매핑
//!
//! 참고:
//!   - references/esbuild/pkg/api/api_impl.go (computeChunks)
//!   - references/rolldown/crates/rolldown/src/chunk_graph/

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ChunkIndex = types.ChunkIndex;

// ============================================================
// BitSet — 진입점 비트 마스크
// ============================================================

/// 고정 크기 비트 집합. 진입점 도달 가능성을 추적하는 데 사용.
/// `[]u8` 슬라이스 기반이라 HashMap 키로 사용 가능 (hash/eql 구현).
pub const BitSet = struct {
    entries: []u8,

    /// max_bits 크기의 빈 BitSet을 생성한다.
    pub fn init(allocator: std.mem.Allocator, max_bits: u32) !BitSet {
        const byte_count = (max_bits + 7) / 8;
        const entries = try allocator.alloc(u8, byte_count);
        @memset(entries, 0);
        return .{ .entries = entries };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *BitSet, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.entries = &.{};
    }

    /// 독립적인 복사본을 만든다.
    pub fn clone(self: BitSet, allocator: std.mem.Allocator) !BitSet {
        return .{ .entries = try allocator.dupe(u8, self.entries) };
    }

    /// 특정 비트가 설정되어 있는지 확인한다.
    pub fn hasBit(self: BitSet, bit: u32) bool {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return false;
        return (self.entries[byte_idx] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
    }

    /// 특정 비트를 설정한다.
    pub fn setBit(self: *BitSet, bit: u32) void {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return;
        self.entries[byte_idx] |= @as(u8, 1) << @intCast(bit % 8);
    }

    /// 특정 비트를 해제한다.
    pub fn clearBit(self: *BitSet, bit: u32) void {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return;
        self.entries[byte_idx] &= ~(@as(u8, 1) << @intCast(bit % 8));
    }

    /// 설정된 비트의 개수를 반환한다.
    pub fn bitCount(self: BitSet) u32 {
        var count: u32 = 0;
        for (self.entries) |byte| {
            count += @popCount(byte);
        }
        return count;
    }

    /// 설정된 비트가 하나도 없는지 확인한다.
    pub fn isEmpty(self: BitSet) bool {
        for (self.entries) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }

    /// other의 비트를 self에 합집합(OR)한다.
    pub fn setUnion(self: *BitSet, other: BitSet) void {
        const len = @min(self.entries.len, other.entries.len);
        for (self.entries[0..len], other.entries[0..len]) |*a, b| {
            a.* |= b;
        }
    }

    /// 두 BitSet이 동일한지 비교한다.
    pub fn eql(self: BitSet, other: BitSet) bool {
        return std.mem.eql(u8, self.entries, other.entries);
    }

    /// 해시값을 계산한다 (HashMap 키로 사용).
    pub fn hash(self: BitSet) u64 {
        return std.hash.Wyhash.hash(0, self.entries);
    }
};

/// BitSet을 HashMap 키로 사용하기 위한 컨텍스트.
pub const BitSetContext = struct {
    pub fn hash(_: BitSetContext, key: BitSet) u64 {
        return key.hash();
    }
    pub fn eql(_: BitSetContext, a: BitSet, b: BitSet) bool {
        return a.eql(b);
    }
};

// ============================================================
// ChunkKind — 청크 종류
// ============================================================

/// 청크의 종류: 진입점(entry_point) 또는 공통 모듈(common).
pub const ChunkKind = union(enum) {
    /// 진입점에서 생성된 청크
    entry_point: struct {
        /// 이 진입점의 비트 인덱스 (BitSet에서의 위치)
        bit: u32,
        /// 진입점 모듈의 인덱스
        module: ModuleIndex,
        /// 동적 import로 생성된 진입점인지 여부
        is_dynamic: bool,
    },
    /// 여러 진입점이 공유하는 공통 청크
    common,
};

// ============================================================
// Chunk — 단일 청크
// ============================================================

/// 번들 출력의 단위. 하나의 JS 파일로 출력된다.
/// 동일한 BitSet(진입점 집합)을 가진 모듈들이 하나의 Chunk에 묶인다.
pub const Chunk = struct {
    /// 청크 그래프에서의 인덱스
    index: ChunkIndex,
    /// 청크 종류 (진입점 / 공통)
    kind: ChunkKind,
    /// 어떤 진입점들에서 도달 가능한지 (비트 마스크)
    bits: BitSet,
    /// 이 청크에 포함된 모듈 목록
    modules: std.ArrayListUnmanaged(ModuleIndex),
    /// 출력 파일명 (stem, 예: "index")
    name: ?[]const u8,
    /// 최종 출력 경로 (예: "dist/index-abc123.js")
    filename: ?[]const u8,
    /// 실행 순서 (exec_index 기준 정렬에 사용)
    exec_order: u32,

    // Cross-chunk linking (PR3에서 사용)
    /// 이 청크가 import하는 다른 청크 목록
    cross_chunk_imports: std.ArrayListUnmanaged(ChunkIndex),
    /// 이 청크가 동적 import하는 다른 청크 목록
    cross_chunk_dynamic_imports: std.ArrayListUnmanaged(ChunkIndex),

    /// 기본값으로 Chunk를 생성한다.
    pub fn init(index: ChunkIndex, kind: ChunkKind, bits: BitSet) Chunk {
        return .{
            .index = index,
            .kind = kind,
            .bits = bits,
            .modules = .empty,
            .name = null,
            .filename = null,
            .exec_order = std.math.maxInt(u32),
            .cross_chunk_imports = .empty,
            .cross_chunk_dynamic_imports = .empty,
        };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.bits.deinit(allocator);
        self.modules.deinit(allocator);
        self.cross_chunk_imports.deinit(allocator);
        self.cross_chunk_dynamic_imports.deinit(allocator);
    }

    /// 청크에 모듈을 추가한다.
    pub fn addModule(self: *Chunk, allocator: std.mem.Allocator, module_idx: ModuleIndex) !void {
        try self.modules.append(allocator, module_idx);
    }

    /// 진입점 청크인지 확인한다.
    pub fn isEntryPoint(self: Chunk) bool {
        return self.kind == .entry_point;
    }
};

// ============================================================
// ChunkGraph — 청크 그래프
// ============================================================

/// 모든 청크와 모듈→청크 매핑을 관리한다.
/// code splitting 알고리즘의 결과를 저장하는 자료구조.
pub const ChunkGraph = struct {
    allocator: std.mem.Allocator,
    /// 모든 청크 목록
    chunks: std.ArrayListUnmanaged(Chunk),
    /// 모듈 인덱스 → 청크 인덱스 매핑 (고정 크기 배열)
    module_to_chunk: []ChunkIndex,

    /// module_count 크기의 빈 ChunkGraph를 생성한다.
    pub fn init(allocator: std.mem.Allocator, module_count: usize) !ChunkGraph {
        const module_to_chunk = try allocator.alloc(ChunkIndex, module_count);
        @memset(module_to_chunk, .none);
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .module_to_chunk = module_to_chunk,
        };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *ChunkGraph) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);
        self.allocator.free(self.module_to_chunk);
    }

    /// 청크를 추가하고 할당된 ChunkIndex를 반환한다.
    pub fn addChunk(self: *ChunkGraph, chunk: Chunk) !ChunkIndex {
        const idx: ChunkIndex = @enumFromInt(@as(u32, @intCast(self.chunks.items.len)));
        var c = chunk;
        c.index = idx;
        try self.chunks.append(self.allocator, c);
        return idx;
    }

    /// 읽기 전용으로 청크를 가져온다.
    pub fn getChunk(self: *const ChunkGraph, idx: ChunkIndex) *const Chunk {
        return &self.chunks.items[@intFromEnum(idx)];
    }

    /// 수정 가능한 청크를 가져온다.
    pub fn getChunkMut(self: *ChunkGraph, idx: ChunkIndex) *Chunk {
        return &self.chunks.items[@intFromEnum(idx)];
    }

    /// 모듈을 청크에 할당한다.
    pub fn assignModuleToChunk(self: *ChunkGraph, module_idx: ModuleIndex, chunk_idx: ChunkIndex) void {
        const mi = @intFromEnum(module_idx);
        if (mi < self.module_to_chunk.len) {
            self.module_to_chunk[mi] = chunk_idx;
        }
    }

    /// 모듈이 속한 청크의 인덱스를 반환한다.
    pub fn getModuleChunk(self: *const ChunkGraph, module_idx: ModuleIndex) ChunkIndex {
        const mi = @intFromEnum(module_idx);
        if (mi >= self.module_to_chunk.len) return .none;
        return self.module_to_chunk[mi];
    }

    /// 총 청크 수를 반환한다.
    pub fn chunkCount(self: *const ChunkGraph) usize {
        return self.chunks.items.len;
    }
};

// ============================================================
// Tests — BitSet
// ============================================================

test "BitSet: init and isEmpty" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);
    try std.testing.expect(bs.isEmpty());
}

test "BitSet: setBit and hasBit" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);

    try std.testing.expect(!bs.hasBit(0));
    bs.setBit(0);
    try std.testing.expect(bs.hasBit(0));
    try std.testing.expect(!bs.hasBit(1));

    bs.setBit(5);
    try std.testing.expect(bs.hasBit(5));
    try std.testing.expect(!bs.isEmpty());
}

test "BitSet: clearBit" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(3);
    try std.testing.expect(bs.hasBit(3));
    bs.clearBit(3);
    try std.testing.expect(!bs.hasBit(3));
    try std.testing.expect(bs.isEmpty());
}

test "BitSet: multi-byte boundary (bit 7, 8)" {
    var bs = try BitSet.init(std.testing.allocator, 16);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(7); // 첫 번째 바이트의 마지막 비트
    bs.setBit(8); // 두 번째 바이트의 첫 번째 비트
    try std.testing.expect(bs.hasBit(7));
    try std.testing.expect(bs.hasBit(8));
    try std.testing.expect(!bs.hasBit(6));
    try std.testing.expect(!bs.hasBit(9));
}

test "BitSet: bit 15 and 16 cross byte" {
    var bs = try BitSet.init(std.testing.allocator, 24);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(15); // 두 번째 바이트의 마지막 비트
    bs.setBit(16); // 세 번째 바이트의 첫 번째 비트
    try std.testing.expect(bs.hasBit(15));
    try std.testing.expect(bs.hasBit(16));
    try std.testing.expect(!bs.hasBit(14));
    try std.testing.expect(!bs.hasBit(17));
}

test "BitSet: bitCount" {
    var bs = try BitSet.init(std.testing.allocator, 8);
    defer bs.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), bs.bitCount());
    bs.setBit(0);
    try std.testing.expectEqual(@as(u32, 1), bs.bitCount());
    bs.setBit(3);
    bs.setBit(7);
    try std.testing.expectEqual(@as(u32, 3), bs.bitCount());
}

test "BitSet: bitCount multi-byte" {
    var bs = try BitSet.init(std.testing.allocator, 24);
    defer bs.deinit(std.testing.allocator);

    bs.setBit(0);
    bs.setBit(8);
    bs.setBit(16);
    bs.setBit(23);
    try std.testing.expectEqual(@as(u32, 4), bs.bitCount());
}

test "BitSet: setUnion" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(0);
    a.setBit(2);
    b.setBit(1);
    b.setBit(2);
    a.setUnion(b);

    try std.testing.expect(a.hasBit(0));
    try std.testing.expect(a.hasBit(1));
    try std.testing.expect(a.hasBit(2));
    try std.testing.expectEqual(@as(u32, 3), a.bitCount());
}

test "BitSet: eql same bits" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(3);
    a.setBit(10);
    b.setBit(3);
    b.setBit(10);
    try std.testing.expect(a.eql(b));
}

test "BitSet: eql different bits" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(3);
    b.setBit(4);
    try std.testing.expect(!a.eql(b));
}

test "BitSet: eql different lengths" {
    var a = try BitSet.init(std.testing.allocator, 8);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    // 바이트 길이가 다르면 false
    try std.testing.expect(!a.eql(b));
}

test "BitSet: hash same bits same hash" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(5);
    a.setBit(12);
    b.setBit(5);
    b.setBit(12);
    try std.testing.expectEqual(a.hash(), b.hash());
}

test "BitSet: hash different bits different hash" {
    var a = try BitSet.init(std.testing.allocator, 16);
    defer a.deinit(std.testing.allocator);
    var b = try BitSet.init(std.testing.allocator, 16);
    defer b.deinit(std.testing.allocator);

    a.setBit(0);
    b.setBit(1);
    // 해시 충돌 가능성은 있지만, 이 경우는 다를 것
    try std.testing.expect(a.hash() != b.hash());
}

test "BitSet: clone is independent" {
    var original = try BitSet.init(std.testing.allocator, 16);
    defer original.deinit(std.testing.allocator);
    original.setBit(3);

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    // 복사본은 동일한 비트를 가짐
    try std.testing.expect(cloned.hasBit(3));

    // 원본을 수정해도 복사본은 영향 없음
    original.setBit(7);
    try std.testing.expect(!cloned.hasBit(7));

    // 복사본을 수정해도 원본은 영향 없음
    cloned.clearBit(3);
    try std.testing.expect(original.hasBit(3));
}

test "BitSet: out of range setBit is no-op" {
    var bs = try BitSet.init(std.testing.allocator, 8);
    defer bs.deinit(std.testing.allocator);

    // 범위 밖 setBit은 무시됨 (패닉 없음)
    bs.setBit(100);
    try std.testing.expect(bs.isEmpty());
}

test "BitSet: out of range hasBit returns false" {
    var bs = try BitSet.init(std.testing.allocator, 8);
    defer bs.deinit(std.testing.allocator);

    // 범위 밖 hasBit은 false 반환
    try std.testing.expect(!bs.hasBit(100));
}

// ============================================================
// Tests — ChunkGraph
// ============================================================

test "ChunkGraph: init and deinit" {
    var cg = try ChunkGraph.init(std.testing.allocator, 10);
    defer cg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cg.chunkCount());
    try std.testing.expectEqual(@as(usize, 10), cg.module_to_chunk.len);
}

test "ChunkGraph: addChunk returns sequential indices" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    var bits0 = try BitSet.init(std.testing.allocator, 4);
    bits0.setBit(0);
    const idx0 = try cg.addChunk(Chunk.init(.none, .common, bits0));

    var bits1 = try BitSet.init(std.testing.allocator, 4);
    bits1.setBit(1);
    const idx1 = try cg.addChunk(Chunk.init(.none, .common, bits1));

    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(idx0));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(idx1));
}

test "ChunkGraph: assignModuleToChunk and getModuleChunk" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    const mod0: ModuleIndex = @enumFromInt(0);
    const mod2: ModuleIndex = @enumFromInt(2);
    const chunk0: ChunkIndex = @enumFromInt(0);
    const chunk1: ChunkIndex = @enumFromInt(1);

    cg.assignModuleToChunk(mod0, chunk0);
    cg.assignModuleToChunk(mod2, chunk1);

    try std.testing.expectEqual(chunk0, cg.getModuleChunk(mod0));
    try std.testing.expectEqual(chunk1, cg.getModuleChunk(mod2));
}

test "ChunkGraph: unassigned module returns ChunkIndex.none" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    const mod0: ModuleIndex = @enumFromInt(0);
    try std.testing.expect(cg.getModuleChunk(mod0).isNone());

    // 범위 밖 모듈도 .none 반환
    const mod_oob: ModuleIndex = @enumFromInt(100);
    try std.testing.expect(cg.getModuleChunk(mod_oob).isNone());
}

test "ChunkGraph: chunkCount" {
    var cg = try ChunkGraph.init(std.testing.allocator, 2);
    defer cg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cg.chunkCount());

    var bits = try BitSet.init(std.testing.allocator, 2);
    bits.setBit(0);
    _ = try cg.addChunk(Chunk.init(.none, .common, bits));
    try std.testing.expectEqual(@as(usize, 1), cg.chunkCount());

    var bits2 = try BitSet.init(std.testing.allocator, 2);
    bits2.setBit(1);
    _ = try cg.addChunk(Chunk.init(.none, .common, bits2));
    try std.testing.expectEqual(@as(usize, 2), cg.chunkCount());
}

test "ChunkGraph: getChunk retrieves correct chunk" {
    var cg = try ChunkGraph.init(std.testing.allocator, 4);
    defer cg.deinit();

    const mod0: ModuleIndex = @enumFromInt(0);
    var bits0 = try BitSet.init(std.testing.allocator, 4);
    bits0.setBit(0);
    const idx0 = try cg.addChunk(Chunk.init(.none, .{ .entry_point = .{
        .bit = 0,
        .module = mod0,
        .is_dynamic = false,
    } }, bits0));

    var bits1 = try BitSet.init(std.testing.allocator, 4);
    bits1.setBit(1);
    const idx1 = try cg.addChunk(Chunk.init(.none, .common, bits1));

    const chunk0 = cg.getChunk(idx0);
    try std.testing.expect(chunk0.isEntryPoint());

    const chunk1 = cg.getChunk(idx1);
    try std.testing.expect(!chunk1.isEntryPoint());
}

test "Chunk: init sets defaults" {
    var bits = try BitSet.init(std.testing.allocator, 8);
    defer bits.deinit(std.testing.allocator);

    const chunk = Chunk.init(.none, .common, bits);
    try std.testing.expect(chunk.name == null);
    try std.testing.expect(chunk.filename == null);
    try std.testing.expectEqual(std.math.maxInt(u32), chunk.exec_order);
    try std.testing.expectEqual(@as(usize, 0), chunk.modules.items.len);
    try std.testing.expectEqual(@as(usize, 0), chunk.cross_chunk_imports.items.len);
    try std.testing.expectEqual(@as(usize, 0), chunk.cross_chunk_dynamic_imports.items.len);
}

test "Chunk: addModule" {
    const bits = try BitSet.init(std.testing.allocator, 8);
    var chunk = Chunk.init(.none, .common, bits);
    defer chunk.deinit(std.testing.allocator);

    const mod0: ModuleIndex = @enumFromInt(0);
    const mod5: ModuleIndex = @enumFromInt(5);

    try chunk.addModule(std.testing.allocator, mod0);
    try chunk.addModule(std.testing.allocator, mod5);

    try std.testing.expectEqual(@as(usize, 2), chunk.modules.items.len);
    try std.testing.expectEqual(mod0, chunk.modules.items[0]);
    try std.testing.expectEqual(mod5, chunk.modules.items[1]);
}

test "Chunk: isEntryPoint" {
    const mod0: ModuleIndex = @enumFromInt(0);

    const bits_entry = try BitSet.init(std.testing.allocator, 8);
    var entry = Chunk.init(.none, .{ .entry_point = .{
        .bit = 0,
        .module = mod0,
        .is_dynamic = false,
    } }, bits_entry);
    defer entry.deinit(std.testing.allocator);
    try std.testing.expect(entry.isEntryPoint());

    const bits_common = try BitSet.init(std.testing.allocator, 8);
    var common = Chunk.init(.none, .common, bits_common);
    defer common.deinit(std.testing.allocator);
    try std.testing.expect(!common.isEntryPoint());
}

test "ChunkKind: entry_point vs common" {
    const mod0: ModuleIndex = @enumFromInt(0);

    const ep: ChunkKind = .{ .entry_point = .{
        .bit = 2,
        .module = mod0,
        .is_dynamic = true,
    } };

    switch (ep) {
        .entry_point => |info| {
            try std.testing.expectEqual(@as(u32, 2), info.bit);
            try std.testing.expectEqual(mod0, info.module);
            try std.testing.expect(info.is_dynamic);
        },
        .common => unreachable,
    }

    const cm: ChunkKind = .common;
    try std.testing.expect(cm == .common);
}
