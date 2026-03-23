const std = @import("std");

/// 테스트용 헬퍼: tmpDir에 파일 생성 + 내용 쓰기 (부모 디렉토리 자동 생성)
pub fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    try dir.writeFile(.{ .sub_path = path, .data = data });
}
