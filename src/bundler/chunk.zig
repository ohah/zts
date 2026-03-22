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
const Module = @import("module.zig").Module;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const Linker = @import("linker.zig").Linker;

// ============================================================
// BitSet — 진입점 비트 마스크
// ============================================================

/// 고정 크기 비트 집합. 진입점 도달 가능성을 추적하는 데 사용.
/// `[]u8` 기반 — `std.DynamicBitSet`(`[]usize`)와 달리 hash/eql이 바이트 단위로 동작하여
/// 엔디안/패딩 영향 없이 HashMap 키로 안전하게 사용 가능.
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

    /// 두 BitSet이 동일한지 비교한다. 같은 max_bits로 생성된 BitSet끼리 비교해야 정확.
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
    /// 출력 파일명 (stem, 예: "index"). 빌림 — deinit에서 해제하지 않음.
    name: ?[]const u8,
    /// 최종 출력 경로 (예: "dist/index-abc123.js"). 빌림 — deinit에서 해제하지 않음.
    filename: ?[]const u8,
    /// 실행 순서 (exec_index 기준 정렬에 사용)
    exec_order: u32,

    // Cross-chunk linking
    /// 이 청크가 import하는 다른 청크 목록
    cross_chunk_imports: std.ArrayListUnmanaged(ChunkIndex),
    /// 이 청크가 동적 import하는 다른 청크 목록
    cross_chunk_dynamic_imports: std.ArrayListUnmanaged(ChunkIndex),

    /// 심볼 수준 크로스 청크 import: source_chunk_index → 가져올 심볼 이름 목록.
    /// computeCrossChunkLinks에서 linker가 있을 때만 채워진다.
    imports_from: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged([]const u8)),
    /// 이 청크에서 다른 청크로 내보내는 심볼 이름 집합.
    /// 공통 청크에서 export 문을 생성할 때 사용.
    exports_to: std.StringHashMapUnmanaged(void),

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
            .imports_from = .empty,
            .exports_to = .empty,
        };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.bits.deinit(allocator);
        self.modules.deinit(allocator);
        self.cross_chunk_imports.deinit(allocator);
        self.cross_chunk_dynamic_imports.deinit(allocator);
        // imports_from: 각 값(ArrayListUnmanaged)도 해제
        var it = self.imports_from.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.imports_from.deinit(allocator);
        self.exports_to.deinit(allocator);
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
// generateChunks — 모듈 그래프에서 청크 생성
// ============================================================

/// 엔트리 정보. 유저 엔트리와 dynamic import 대상을 구분.
const EntryInfo = struct {
    module_idx: ModuleIndex,
    is_dynamic: bool,
};

/// 모듈 그래프에서 청크를 생성한다 (esbuild/rolldown 패턴).
///
/// Phase 1: 엔트리 초기화 — 유저 엔트리 + dynamic import 대상을 수집하고,
///          각 엔트리마다 Chunk를 생성한다.
/// Phase 2: 도달 가능성 마킹 — 각 엔트리에서 BFS로 정적 import를 따라가며
///          모듈별 BitSet에 도달 가능한 엔트리 비트를 설정한다.
/// Phase 3: 청크 할당 — 동일한 BitSet을 가진 모듈들을 같은 Chunk에 묶는다.
///          여러 엔트리에서 도달 가능한 모듈은 공통 청크(common chunk)로 분리.
///
/// shaker가 null이 아니면 tree-shaking 결과를 반영하여 미포함 모듈을 스킵한다.
pub fn generateChunks(
    allocator: std.mem.Allocator,
    modules: []const Module,
    entry_points: []const []const u8,
    shaker: ?*const TreeShaker,
) !ChunkGraph {
    // ── Phase 1: 엔트리 수집 ──
    // 유저 엔트리 (CLI 진입점) + dynamic import 대상을 모두 모은다.
    // 각각이 하나의 출력 청크가 된다.
    var entries: std.ArrayList(EntryInfo) = .empty;
    defer entries.deinit(allocator);

    // Phase 1a: 유저 엔트리 — entry_points 경로와 일치하는 모듈을 찾는다.
    for (modules, 0..) |m, i| {
        for (entry_points) |ep| {
            if (std.mem.eql(u8, m.path, ep)) {
                try entries.append(allocator, .{
                    .module_idx = @enumFromInt(@as(u32, @intCast(i))),
                    .is_dynamic = false,
                });
                break;
            }
        }
    }

    // Phase 1b: dynamic import 대상 — 이미 유저 엔트리인 모듈은 스킵.
    // dynamic import 대상은 별도의 청크 경계를 형성한다 (code splitting의 핵심).
    var dynamic_seen: std.AutoHashMap(u32, void) = .init(allocator);
    defer dynamic_seen.deinit();

    for (modules) |m| {
        for (m.dynamic_imports.items) |dyn_idx| {
            const di = @intFromEnum(dyn_idx);
            const gop = try dynamic_seen.getOrPut(di);
            if (!gop.found_existing) {
                // 이미 유저 엔트리로 등록된 모듈인지 확인
                var is_user_entry = false;
                for (entries.items) |e| {
                    if (@intFromEnum(e.module_idx) == di and !e.is_dynamic) {
                        is_user_entry = true;
                        break;
                    }
                }
                if (!is_user_entry) {
                    try entries.append(allocator, .{
                        .module_idx = dyn_idx,
                        .is_dynamic = true,
                    });
                }
            }
        }
    }

    const entry_count = entries.items.len;
    if (entry_count == 0) {
        return ChunkGraph.init(allocator, modules.len);
    }

    // ChunkGraph 생성 — 모듈→청크 매핑 배열을 module_count 크기로 할당.
    var chunk_graph = try ChunkGraph.init(allocator, modules.len);
    errdefer chunk_graph.deinit();

    // 모듈별 도달 가능성 BitSet — splitting_info[module_index]는
    // 그 모듈이 어떤 엔트리들에서 도달 가능한지를 나타낸다.
    var splitting_info = try allocator.alloc(BitSet, modules.len);
    // 안전한 초기값 — init 실패 시 defer에서 deinit 호출해도 안전
    @memset(splitting_info, .{ .entries = &.{} });
    defer {
        for (splitting_info) |*bs| bs.deinit(allocator);
        allocator.free(splitting_info);
    }
    for (splitting_info) |*bs| {
        bs.* = try BitSet.init(allocator, @intCast(entry_count));
    }

    // BitSet → ChunkIndex HashMap (Phase 3에서 O(1) 청크 lookup에 사용)
    var bits_to_chunk: std.HashMapUnmanaged(BitSet, ChunkIndex, BitSetContext, 80) = .empty;
    defer bits_to_chunk.deinit(allocator);

    // Phase 1c: 엔트리별 Chunk 생성
    for (entries.items, 0..) |entry, bit_idx| {
        var bits = try BitSet.init(allocator, @intCast(entry_count));
        errdefer bits.deinit(allocator);
        bits.setBit(@intCast(bit_idx));

        // 출력 파일명 = 모듈 파일명의 stem (확장자 제거)
        const name = std.fs.path.stem(std.fs.path.basename(
            modules[@intFromEnum(entry.module_idx)].path,
        ));

        var chunk = Chunk.init(.none, .{ .entry_point = .{
            .bit = @intCast(bit_idx),
            .module = entry.module_idx,
            .is_dynamic = entry.is_dynamic,
        } }, bits);
        chunk.name = name;

        const ci = try chunk_graph.addChunk(chunk);
        try bits_to_chunk.put(allocator, bits, ci);
    }

    // ── Phase 2: BFS 도달 가능성 마킹 ──
    // 각 엔트리에서 정적 import(dependencies)만 따라가며 BFS 순회.
    // dynamic import는 청크 경계이므로 따라가지 않는다.
    // 결과: splitting_info[모듈]에 도달 가능한 엔트리 비트가 설정됨.
    var queue: std.ArrayList(ModuleIndex) = .empty;
    defer queue.deinit(allocator);

    for (entries.items, 0..) |entry, bit_idx| {
        queue.clearRetainingCapacity();
        try queue.append(allocator, entry.module_idx);

        while (queue.items.len > 0) {
            const mod_idx = queue.pop() orelse break;
            const mi = @intFromEnum(mod_idx);
            if (mi >= modules.len) continue;

            // 이미 이 비트가 설정되어 있으면 스킵 (순환 참조 방지)
            if (splitting_info[mi].hasBit(@intCast(bit_idx))) continue;
            splitting_info[mi].setBit(@intCast(bit_idx));

            // 정적 의존성만 따라감 — dynamic import는 별도 엔트리이므로 BFS 경계
            for (modules[mi].dependencies.items) |dep_idx| {
                const dep_i = @intFromEnum(dep_idx);
                if (dep_i < modules.len and !splitting_info[dep_i].hasBit(@intCast(bit_idx))) {
                    try queue.append(allocator, dep_idx);
                }
            }
        }
    }

    // ── Phase 3: 모듈을 청크에 할당 ──
    // exec_index 순으로 처리하여 청크 내 모듈 순서(=ESM 실행 순서)를 보장.
    // 동일한 BitSet을 가진 모듈들은 같은 청크에 묶인다.
    // 엔트리 청크의 BitSet과 일치하지 않는 새로운 BitSet 패턴이 나오면
    // 공통 청크(common chunk)를 새로 생성한다.
    const sorted_indices = try allocator.alloc(usize, modules.len);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;
    std.mem.sort(usize, sorted_indices, modules, struct {
        fn lessThan(mods: []const Module, a: usize, b: usize) bool {
            return mods[a].exec_index < mods[b].exec_index;
        }
    }.lessThan);

    for (sorted_indices) |mi| {
        // tree-shaking: 미포함 모듈 스킵
        if (shaker) |s| {
            if (!s.isIncluded(@intCast(mi))) continue;
        }

        // JS 모듈만 청크에 할당 (JSON, CSS 등은 별도 처리)
        if (modules[mi].module_type != .javascript) continue;

        // 비트가 비어있으면 어떤 엔트리에서도 도달 불가 → 스킵
        if (splitting_info[mi].isEmpty()) continue;

        // BitSet → ChunkIndex O(1) lookup (esbuild/rolldown 패턴)
        const chunk_idx = if (bits_to_chunk.get(splitting_info[mi])) |ci| ci else blk: {
            // 새로운 BitSet 패턴 → 공통 청크 생성
            var bits = try splitting_info[mi].clone(allocator);
            errdefer bits.deinit(allocator);
            const new_chunk = Chunk.init(.none, .common, bits);
            const ci = try chunk_graph.addChunk(new_chunk);
            try bits_to_chunk.put(allocator, bits, ci);
            break :blk ci;
        };

        chunk_graph.assignModuleToChunk(
            @enumFromInt(@as(u32, @intCast(mi))),
            chunk_idx,
        );
        try chunk_graph.getChunkMut(chunk_idx).addModule(
            allocator,
            @enumFromInt(@as(u32, @intCast(mi))),
        );
    }

    // 엔트리 모듈은 반드시 자신의 엔트리 청크에 할당되어야 함.
    // Phase 3에서 공통 청크에 배정되었을 수 있으므로, 강제로 엔트리 청크로 이동.
    for (entries.items, 0..) |entry, ci| {
        const chunk_idx: ChunkIndex = @enumFromInt(@as(u32, @intCast(ci)));
        const current = chunk_graph.getModuleChunk(entry.module_idx);
        if (current.isNone()) {
            // 아직 미할당 → 엔트리 청크에 할당
            chunk_graph.assignModuleToChunk(entry.module_idx, chunk_idx);
            try chunk_graph.getChunkMut(chunk_idx).addModule(allocator, entry.module_idx);
        } else if (current != chunk_idx) {
            // 공통 청크에 잘못 배정됨 → 이전 청크에서 제거 후 엔트리 청크로 이동
            const old_chunk = chunk_graph.getChunkMut(current);
            removeModuleFromList(&old_chunk.modules, entry.module_idx);
            chunk_graph.assignModuleToChunk(entry.module_idx, chunk_idx);
            try chunk_graph.getChunkMut(chunk_idx).addModule(allocator, entry.module_idx);
        }
    }

    return chunk_graph;
}

/// ArrayListUnmanaged에서 특정 ModuleIndex를 제거한다 (순서 유지).
fn removeModuleFromList(list: *std.ArrayListUnmanaged(ModuleIndex), target: ModuleIndex) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == target) {
            _ = list.orderedRemove(i);
            return; // 중복 없으므로 첫 번째만 제거
        }
        i += 1;
    }
}

// ============================================================
// computeCrossChunkLinks — 크로스 청크 의존성 계산
// ============================================================

/// 각 청크의 크로스 청크 의존성을 계산한다.
///
/// 청크 A의 모듈이 청크 B의 모듈을 정적 import하면 A.cross_chunk_imports에 B가 추가된다.
/// 청크 A의 모듈이 청크 B의 모듈을 동적 import하면 A.cross_chunk_dynamic_imports에 B가 추가된다.
/// 같은 청크 내의 의존성은 무시하고, 중복 청크 인덱스도 제거한다.
///
/// linker가 있으면 심볼 수준 크로스 청크 바인딩도 추적한다:
///   - chunk.imports_from[source_chunk] = 해당 청크에서 가져올 심볼 이름 목록
///   - source_chunk.exports_to에 해당 심볼 이름 추가
/// linker가 null이면 청크 수준 의존성만 계산 (side-effect import).
///
/// 이 함수는 generateChunks 이후에 호출한다.
pub fn computeCrossChunkLinks(
    chunk_graph: *ChunkGraph,
    modules: []const Module,
    allocator: std.mem.Allocator,
    linker: ?*const Linker,
) !void {
    // 먼저 모든 청크의 기존 데이터를 초기화 (exports_to는 다른 청크에서 기록하므로 분리)
    for (chunk_graph.chunks.items) |*chunk| {
        chunk.cross_chunk_imports.clearAndFree(allocator);
        chunk.cross_chunk_dynamic_imports.clearAndFree(allocator);
        {
            var it = chunk.imports_from.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(allocator);
            chunk.imports_from.clearAndFree(allocator);
        }
        chunk.exports_to.clearAndFree(allocator);
    }

    for (chunk_graph.chunks.items) |*chunk| {
        // 중복 방지용 해시맵
        var seen_static: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_static.deinit(allocator);
        var seen_dynamic: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_dynamic.deinit(allocator);

        for (chunk.modules.items) |mod_idx| {
            const mi = @intFromEnum(mod_idx);
            // 청크에 포함된 모듈은 반드시 modules 배열 내에 있어야 함
            std.debug.assert(mi < modules.len);
            const m = &modules[mi];

            // 정적 의존성 → cross_chunk_imports
            for (m.dependencies.items) |dep_idx| {
                if (dep_idx.isNone()) continue;
                const dep_chunk = chunk_graph.getModuleChunk(dep_idx);
                if (dep_chunk.isNone()) continue;
                if (dep_chunk == chunk.index) continue; // 같은 청크 → 스킵
                const dci = @intFromEnum(dep_chunk);
                const gop = try seen_static.getOrPut(allocator, dci);
                if (!gop.found_existing) {
                    try chunk.cross_chunk_imports.append(allocator, dep_chunk);
                }
            }

            // 심볼 수준 크로스 청크 바인딩 추적 (linker가 있을 때만)
            if (linker) |lnk| {
                for (m.import_bindings) |ib| {
                    // resolved binding으로 canonical 모듈을 찾는다
                    const rb = lnk.getResolvedBinding(@intCast(mi), ib.local_span) orelse continue;
                    const canonical_mi = @intFromEnum(rb.canonical.module_index);
                    if (canonical_mi >= modules.len) continue;

                    const src_chunk_idx = chunk_graph.getModuleChunk(rb.canonical.module_index);
                    if (src_chunk_idx.isNone()) continue;
                    if (src_chunk_idx == chunk.index) continue; // 같은 청크 → 스킵

                    const src_ci = @intFromEnum(src_chunk_idx);
                    const export_name = rb.canonical.export_name;

                    // imports_from에 심볼 이름 추가 (중복 방지)
                    const ifgop = try chunk.imports_from.getOrPut(allocator, src_ci);
                    if (!ifgop.found_existing) {
                        ifgop.value_ptr.* = .empty;
                    }
                    // 이미 추가된 이름인지 확인
                    var already = false;
                    for (ifgop.value_ptr.items) |existing| {
                        if (std.mem.eql(u8, existing, export_name)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try ifgop.value_ptr.append(allocator, export_name);
                    }

                    // 소스 청크의 exports_to에 심볼 이름 추가
                    const src_chunk = &chunk_graph.chunks.items[src_ci];
                    try src_chunk.exports_to.put(allocator, export_name, {});
                }
            }

            // 동적 의존성 → cross_chunk_dynamic_imports
            for (m.dynamic_imports.items) |dyn_idx| {
                if (dyn_idx.isNone()) continue;
                const dyn_chunk = chunk_graph.getModuleChunk(dyn_idx);
                if (dyn_chunk.isNone()) continue;
                if (dyn_chunk == chunk.index) continue; // 같은 청크 → 스킵
                const dci = @intFromEnum(dyn_chunk);
                const gop = try seen_dynamic.getOrPut(allocator, dci);
                if (!gop.found_existing) {
                    try chunk.cross_chunk_dynamic_imports.append(allocator, dyn_chunk);
                }
            }
        }
    }
}

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

// ============================================================
// Tests — generateChunks
// ============================================================

/// 테스트용 Module을 생성한다. javascript 타입, exec_index = index.
fn makeTestModule(alloc: std.mem.Allocator, index: u32, path: []const u8) Module {
    var m = Module.init(@enumFromInt(index), path);
    m.module_type = .javascript;
    m.exec_index = index;
    m.state = .ready;
    // ArrayList 필드는 .empty으로 초기화됨 — append 시 allocator를 전달
    _ = alloc;
    return m;
}

test "generateChunks: single entry, no dynamic imports" {
    // 구조: entry(a.ts) → b.ts → c.ts
    // 기대: 모든 모듈이 하나의 엔트리 청크에 포함
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);

    // a → b → c
    try modules[0].dependencies.append(alloc, @enumFromInt(1));
    try modules[1].dependencies.append(alloc, @enumFromInt(2));

    var cg = try generateChunks(alloc, &modules, &.{"a.ts"}, null);
    defer cg.deinit();

    // 엔트리 청크 1개
    try std.testing.expectEqual(@as(usize, 1), cg.chunkCount());

    // 모든 모듈이 청크 0에 할당
    const chunk0: ChunkIndex = @enumFromInt(0);
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(0)));
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(1)));
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(2)));

    // 청크가 엔트리 타입
    try std.testing.expect(cg.getChunk(chunk0).isEntryPoint());

    // 청크 이름 = 진입점 파일의 stem
    try std.testing.expectEqualStrings("a", cg.getChunk(chunk0).name.?);
}

test "generateChunks: dynamic import creates separate chunk" {
    // 구조: entry(index.ts) -static→ utils.ts
    //       entry(index.ts) -dynamic→ lazy.ts
    // 기대: index+utils → 청크0, lazy → 청크1
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "index.ts"),
        makeTestModule(alloc, 1, "utils.ts"),
        makeTestModule(alloc, 2, "lazy.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);

    // index → utils (static), index → lazy (dynamic)
    try modules[0].dependencies.append(alloc, @enumFromInt(1));
    try modules[0].dynamic_imports.append(alloc, @enumFromInt(2));

    var cg = try generateChunks(alloc, &modules, &.{"index.ts"}, null);
    defer cg.deinit();

    // 엔트리 청크 1개 + dynamic 청크 1개 = 2개
    try std.testing.expectEqual(@as(usize, 2), cg.chunkCount());

    // index, utils → 청크 0 (유저 엔트리)
    const chunk0: ChunkIndex = @enumFromInt(0);
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(0)));
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(1)));

    // lazy → 청크 1 (dynamic 엔트리)
    const chunk1: ChunkIndex = @enumFromInt(1);
    try std.testing.expectEqual(chunk1, cg.getModuleChunk(@enumFromInt(2)));

    // 청크 1은 dynamic 엔트리
    const lazy_chunk = cg.getChunk(chunk1);
    switch (lazy_chunk.kind) {
        .entry_point => |info| try std.testing.expect(info.is_dynamic),
        .common => return error.TestUnexpectedResult,
    }
}

test "generateChunks: shared module creates common chunk" {
    // 구조: entry A(a.ts) → shared.ts
    //       entry B(b.ts) → shared.ts
    // 기대: a → 청크0, b → 청크1, shared → 공통 청크2
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "shared.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);

    // a → shared, b → shared
    try modules[0].dependencies.append(alloc, @enumFromInt(2));
    try modules[1].dependencies.append(alloc, @enumFromInt(2));

    var cg = try generateChunks(alloc, &modules, &.{ "a.ts", "b.ts" }, null);
    defer cg.deinit();

    // 엔트리 2개 + 공통 1개 = 3개
    try std.testing.expectEqual(@as(usize, 3), cg.chunkCount());

    // a → 청크0, b → 청크1
    const chunk0: ChunkIndex = @enumFromInt(0);
    const chunk1: ChunkIndex = @enumFromInt(1);
    try std.testing.expectEqual(chunk0, cg.getModuleChunk(@enumFromInt(0)));
    try std.testing.expectEqual(chunk1, cg.getModuleChunk(@enumFromInt(1)));

    // shared → 청크2 (공통 청크)
    const shared_chunk_idx = cg.getModuleChunk(@enumFromInt(2));
    try std.testing.expect(!shared_chunk_idx.isNone());
    try std.testing.expect(!cg.getChunk(shared_chunk_idx).isEntryPoint());
}

test "generateChunks: diamond dependency" {
    // 구조: A(a.ts) → B(b.ts) → D(d.ts)
    //       A(a.ts) → C(c.ts) → D(d.ts)
    //       두 엔트리: A, C
    // 기대: A,B → 청크0 (A 엔트리에서만 도달), C → 청크1,
    //       D → 공통 청크 (A와 C 둘 다에서 도달)
    const alloc = std.testing.allocator;

    var modules: [4]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
        makeTestModule(alloc, 3, "d.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);

    // A → B, A → C, B → D, C → D
    try modules[0].dependencies.append(alloc, @enumFromInt(1));
    try modules[0].dependencies.append(alloc, @enumFromInt(2));
    try modules[1].dependencies.append(alloc, @enumFromInt(3));
    try modules[2].dependencies.append(alloc, @enumFromInt(3));

    var cg = try generateChunks(alloc, &modules, &.{ "a.ts", "c.ts" }, null);
    defer cg.deinit();

    // D가 양쪽 엔트리에서 도달 가능 → 공통 청크 생성
    const d_chunk_idx = cg.getModuleChunk(@enumFromInt(3));
    try std.testing.expect(!d_chunk_idx.isNone());
    try std.testing.expect(!cg.getChunk(d_chunk_idx).isEntryPoint());

    // C는 엔트리 청크1에 할당 (C가 두 번째 엔트리이므로 bit 1)
    // A 엔트리(bit 0)에서도 C에 도달하므로, C의 BitSet = {0,1}
    // 이는 D와 동일한 BitSet → 같은 공통 청크에 묶임
    const c_chunk_idx = cg.getModuleChunk(@enumFromInt(2));
    try std.testing.expect(!c_chunk_idx.isNone());

    // B는 A에서만 도달 → A 엔트리 청크에 묶임
    const b_chunk_idx = cg.getModuleChunk(@enumFromInt(1));
    const a_chunk_idx = cg.getModuleChunk(@enumFromInt(0));
    try std.testing.expectEqual(a_chunk_idx, b_chunk_idx);
}

test "generateChunks: no modules" {
    // 빈 모듈 배열 → 빈 ChunkGraph (청크 0개)
    const alloc = std.testing.allocator;
    const empty_modules: []const Module = &.{};

    var cg = try generateChunks(alloc, empty_modules, &.{"entry.ts"}, null);
    defer cg.deinit();

    try std.testing.expectEqual(@as(usize, 0), cg.chunkCount());
}

test "generateChunks: circular dependency stays in same chunk" {
    // 구조: entry(a.ts) → b.ts → c.ts → b.ts (순환)
    // 기대: 모두 같은 엔트리 청크 (순환이 BitSet에 영향 없음)
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
    };
    // a → b, b → c, c → b (순환)
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);
    try modules[1].addDependency(alloc, @enumFromInt(2), &modules);
    try modules[2].addDependency(alloc, @enumFromInt(1), &modules);
    defer for (&modules) |*m| m.deinit(alloc);

    var cg = try generateChunks(alloc, &modules, &.{"a.ts"}, null);
    defer cg.deinit();

    // 1 엔트리 청크, 모든 모듈 포함
    try std.testing.expectEqual(@as(usize, 1), cg.chunkCount());
    for (0..3) |i| {
        try std.testing.expect(!cg.getModuleChunk(@enumFromInt(@as(u32, @intCast(i)))).isNone());
    }
}

test "generateChunks: static + dynamic import same module" {
    // 구조: entry(a.ts) → static b.ts, a.ts → dynamic b.ts
    // 기대: b.ts는 static import 경로로 엔트리 청크에 포함 (dynamic 엔트리도 생성되지만 b가 이미 엔트리 청크에 있음)
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);
    try modules[0].addDynamicImport(alloc, @enumFromInt(1));
    defer for (&modules) |*m| m.deinit(alloc);

    var cg = try generateChunks(alloc, &modules, &.{"a.ts"}, null);
    defer cg.deinit();

    // b.ts는 엔트리 청크에 포함 (static이 우선)
    const b_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(!b_chunk.isNone());
}

test "generateChunks: three entries sharing a module" {
    // 구조: a.ts, b.ts, c.ts 모두 → shared.ts
    // 기대: 3개 엔트리 청크 + 1개 공통 청크 (shared.ts: BitSet = {0,1,2})
    const alloc = std.testing.allocator;

    var modules: [4]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
        makeTestModule(alloc, 3, "shared.ts"),
    };
    // 3개 엔트리가 모두 dynamic import로 생성됨
    // a→shared, b→shared, c→shared (static deps)
    try modules[0].addDependency(alloc, @enumFromInt(3), &modules);
    try modules[1].addDependency(alloc, @enumFromInt(3), &modules);
    try modules[2].addDependency(alloc, @enumFromInt(3), &modules);
    defer for (&modules) |*m| m.deinit(alloc);

    var cg = try generateChunks(alloc, &modules, &.{ "a.ts", "b.ts", "c.ts" }, null);
    defer cg.deinit();

    // 3 엔트리 + 1 공통 = 4 청크
    try std.testing.expectEqual(@as(usize, 4), cg.chunkCount());

    // shared.ts는 공통 청크에 할당
    const shared_chunk_idx = cg.getModuleChunk(@enumFromInt(3));
    try std.testing.expect(!shared_chunk_idx.isNone());
    const shared_chunk = cg.getChunk(shared_chunk_idx);
    try std.testing.expect(shared_chunk.kind == .common);
    // 3개 엔트리에서 모두 도달 가능
    try std.testing.expectEqual(@as(u32, 3), shared_chunk.bits.bitCount());
}

test "generateChunks: entry imports another entry statically" {
    // 구조: a.ts (엔트리) → b.ts (엔트리)
    // 기대: 각 엔트리는 자신의 청크를 가짐. b.ts는 두 엔트리에서 도달 가능 → 공통 청크 또는 b 엔트리 청크에 포함
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);
    defer for (&modules) |*m| m.deinit(alloc);

    var cg = try generateChunks(alloc, &modules, &.{ "a.ts", "b.ts" }, null);
    defer cg.deinit();

    // 2개 엔트리 청크 생성
    try std.testing.expect(cg.chunkCount() >= 2);
    // 두 모듈 모두 할당됨
    try std.testing.expect(!cg.getModuleChunk(@enumFromInt(0)).isNone());
    try std.testing.expect(!cg.getModuleChunk(@enumFromInt(1)).isNone());
}

test "generateChunks: deep chain with dynamic import at middle" {
    // 구조: a.ts → b.ts → dynamic c.ts → d.ts
    // 기대: a,b는 엔트리 청크, c,d는 dynamic 엔트리 청크
    const alloc = std.testing.allocator;

    var modules: [4]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
        makeTestModule(alloc, 3, "d.ts"),
    };
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);
    try modules[1].addDynamicImport(alloc, @enumFromInt(2));
    try modules[2].addDependency(alloc, @enumFromInt(3), &modules);
    defer for (&modules) |*m| m.deinit(alloc);

    var cg = try generateChunks(alloc, &modules, &.{"a.ts"}, null);
    defer cg.deinit();

    // 2개 청크: a엔트리(a,b), c엔트리(c,d)
    try std.testing.expectEqual(@as(usize, 2), cg.chunkCount());

    // a,b는 같은 청크 (엔트리)
    const a_chunk = cg.getModuleChunk(@enumFromInt(0));
    const b_chunk = cg.getModuleChunk(@enumFromInt(1));
    try std.testing.expect(!a_chunk.isNone());
    try std.testing.expectEqual(a_chunk, b_chunk);

    // c,d는 같은 청크 (dynamic 엔트리)
    const c_chunk = cg.getModuleChunk(@enumFromInt(2));
    const d_chunk = cg.getModuleChunk(@enumFromInt(3));
    try std.testing.expect(!c_chunk.isNone());
    try std.testing.expectEqual(c_chunk, d_chunk);

    // a,b 청크와 c,d 청크는 다름
    try std.testing.expect(a_chunk != c_chunk);
}

// ============================================================
// Tests — computeCrossChunkLinks
// ============================================================

test "computeCrossChunkLinks: no cross-chunk deps — 모든 모듈이 같은 청크" {
    // 구조: 모듈 0,1 모두 청크 0에 속함. 0 → 1 의존성.
    // 같은 청크 내 의존성이므로 cross_chunk_imports는 비어야 한다.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);

    // 청크 하나에 모듈 0,1 할당
    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    var bits = try BitSet.init(alloc, 1);
    bits.setBit(0);
    const ci = try cg.addChunk(Chunk.init(.none, .common, bits));
    cg.assignModuleToChunk(@enumFromInt(0), ci);
    cg.assignModuleToChunk(@enumFromInt(1), ci);
    try cg.getChunkMut(ci).addModule(alloc, @enumFromInt(0));
    try cg.getChunkMut(ci).addModule(alloc, @enumFromInt(1));

    try computeCrossChunkLinks(&cg, &modules, alloc, null);

    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(ci).cross_chunk_imports.items.len);
    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(ci).cross_chunk_dynamic_imports.items.len);
}

test "computeCrossChunkLinks: static cross-chunk import" {
    // 구조: 청크 A(모듈 0), 청크 B(모듈 1). 모듈 0 → 모듈 1 정적 의존.
    // 기대: A.cross_chunk_imports에 B가 포함.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);

    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    // 청크 A: 모듈 0
    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));

    // 청크 B: 모듈 1
    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(1), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(1));

    try computeCrossChunkLinks(&cg, &modules, alloc, null);

    // A → B 정적 import
    const a_imports = cg.getChunk(chunk_a).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_imports.len);
    try std.testing.expectEqual(chunk_b, a_imports[0]);

    // B는 A를 import하지 않음
    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(chunk_b).cross_chunk_imports.items.len);
}

test "computeCrossChunkLinks: dynamic cross-chunk import" {
    // 구조: 청크 A(모듈 0), 청크 B(모듈 1). 모듈 0이 모듈 1을 동적 import.
    // 기대: A.cross_chunk_dynamic_imports에 B가 포함.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);
    try modules[0].addDynamicImport(alloc, @enumFromInt(1));

    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));

    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(1), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(1));

    try computeCrossChunkLinks(&cg, &modules, alloc, null);

    // A의 동적 import에 B가 있어야 함
    const a_dyn = cg.getChunk(chunk_a).cross_chunk_dynamic_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_dyn.len);
    try std.testing.expectEqual(chunk_b, a_dyn[0]);

    // A의 정적 import는 비어야 함
    try std.testing.expectEqual(@as(usize, 0), cg.getChunk(chunk_a).cross_chunk_imports.items.len);
}

test "computeCrossChunkLinks: deduplication — 여러 모듈이 같은 청크를 import" {
    // 구조: 청크 A(모듈 0, 모듈 1), 청크 B(모듈 2).
    //       모듈 0 → 모듈 2, 모듈 1 → 모듈 2.
    // 기대: A.cross_chunk_imports에 B가 한 번만 포함.
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
        makeTestModule(alloc, 2, "c.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);
    try modules[0].addDependency(alloc, @enumFromInt(2), &modules);
    try modules[1].addDependency(alloc, @enumFromInt(2), &modules);

    var cg = try ChunkGraph.init(alloc, 3);
    defer cg.deinit();

    // 청크 A: 모듈 0, 1
    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    cg.assignModuleToChunk(@enumFromInt(1), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(1));

    // 청크 B: 모듈 2
    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(2), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(2));

    try computeCrossChunkLinks(&cg, &modules, alloc, null);

    // B가 정확히 1번만 나와야 함 (중복 제거)
    const a_imports = cg.getChunk(chunk_a).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_imports.len);
    try std.testing.expectEqual(chunk_b, a_imports[0]);
}

test "computeCrossChunkLinks: bidirectional — A↔B 상호 의존" {
    // 구조: 청크 A(모듈 0), 청크 B(모듈 1). 모듈 0 → 모듈 1, 모듈 1 → 모듈 0.
    // 기대: A.cross_chunk_imports에 B, B.cross_chunk_imports에 A.
    const alloc = std.testing.allocator;

    var modules: [2]Module = .{
        makeTestModule(alloc, 0, "a.ts"),
        makeTestModule(alloc, 1, "b.ts"),
    };
    defer for (&modules) |*m| m.deinit(alloc);
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);
    try modules[1].addDependency(alloc, @enumFromInt(0), &modules);

    var cg = try ChunkGraph.init(alloc, 2);
    defer cg.deinit();

    var bits_a = try BitSet.init(alloc, 2);
    bits_a.setBit(0);
    const chunk_a = try cg.addChunk(Chunk.init(.none, .common, bits_a));
    cg.assignModuleToChunk(@enumFromInt(0), chunk_a);
    try cg.getChunkMut(chunk_a).addModule(alloc, @enumFromInt(0));

    var bits_b = try BitSet.init(alloc, 2);
    bits_b.setBit(1);
    const chunk_b = try cg.addChunk(Chunk.init(.none, .common, bits_b));
    cg.assignModuleToChunk(@enumFromInt(1), chunk_b);
    try cg.getChunkMut(chunk_b).addModule(alloc, @enumFromInt(1));

    try computeCrossChunkLinks(&cg, &modules, alloc, null);

    // A → B
    const a_imports = cg.getChunk(chunk_a).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), a_imports.len);
    try std.testing.expectEqual(chunk_b, a_imports[0]);

    // B → A
    const b_imports = cg.getChunk(chunk_b).cross_chunk_imports.items;
    try std.testing.expectEqual(@as(usize, 1), b_imports.len);
    try std.testing.expectEqual(chunk_a, b_imports[0]);
}

test "generateChunks: entry module reassignment removes from old chunk" {
    // 엔트리 C가 다른 엔트리 A에서 static import → C의 BitSet이 공통 패턴과 일치
    // → Phase 3에서 공통 청크에 배정 → 후처리에서 엔트리 청크로 이동
    // → 이전 청크의 modules에서 제거되어야 함
    const alloc = std.testing.allocator;

    var modules: [3]Module = .{
        makeTestModule(alloc, 0, "a.ts"), // 엔트리 0
        makeTestModule(alloc, 1, "b.ts"), // 공유 모듈
        makeTestModule(alloc, 2, "c.ts"), // 엔트리 1 + A가 static import
    };
    // a → b (static), a → c (static), c → b (static)
    try modules[0].addDependency(alloc, @enumFromInt(1), &modules);
    try modules[0].addDependency(alloc, @enumFromInt(2), &modules);
    try modules[2].addDependency(alloc, @enumFromInt(1), &modules);
    defer for (&modules) |*m| m.deinit(alloc);

    var cg = try generateChunks(alloc, &modules, &.{ "a.ts", "c.ts" }, null);
    defer cg.deinit();

    // c.ts는 엔트리 청크에 있어야 함 (공통 청크 아님)
    const c_chunk = cg.getModuleChunk(@enumFromInt(2));
    try std.testing.expect(!c_chunk.isNone());

    // c.ts가 하나의 청크에만 존재하는지 확인 (중복 방지)
    var count: u32 = 0;
    for (cg.chunks.items) |chunk| {
        for (chunk.modules.items) |mod_idx| {
            if (@intFromEnum(mod_idx) == 2) count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), count);
}
