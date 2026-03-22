const std = @import("std");
const http = std.http;
const mime = @import("mime.zig");
const lib = @import("../root.zig");
const Bundler = lib.bundler.Bundler;

fn getLog() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

pub const DevServer = struct {
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    root_path: []const u8,
    port: u16,
    tcp_server: ?std.net.Server,
    entry_point: ?[]const u8,
    /// init에서 해결한 절대 경로. entry_point가 있을 때만 유효.
    abs_entry: ?[]const u8,

    pub const Options = struct {
        root_dir: []const u8 = ".",
        port: u16 = 3000,
        entry_point: ?[]const u8 = null,
    };

    const max_file_size: u64 = 50 * 1024 * 1024;
    const bundle_path = "/bundle.js";

    const js_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
    };

    const html_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !DevServer {
        const root_dir = std.fs.cwd().openDir(options.root_dir, .{}) catch |err| {
            getLog().print("zts: cannot open directory '{s}': {}\n", .{ options.root_dir, err }) catch {};
            return err;
        };

        var abs_entry: ?[]const u8 = null;
        if (options.entry_point) |ep| {
            abs_entry = std.fs.cwd().realpathAlloc(allocator, ep) catch |err| {
                getLog().print("zts: cannot resolve entry '{s}': {}\n", .{ ep, err }) catch {};
                var dir_copy = root_dir;
                dir_copy.close();
                return err;
            };
        }

        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .root_path = options.root_dir,
            .port = options.port,
            .tcp_server = null,
            .entry_point = options.entry_point,
            .abs_entry = abs_entry,
        };
    }

    pub fn deinit(self: *DevServer) void {
        if (self.tcp_server) |*s| s.deinit();
        if (self.abs_entry) |ae| self.allocator.free(ae);
        self.root_dir.close();
    }

    pub fn start(self: *DevServer) !void {
        const address = std.net.Address.parseIp4("0.0.0.0", self.port) catch unreachable;
        self.tcp_server = address.listen(.{
            .reuse_address = true,
        }) catch |err| {
            getLog().print("zts: failed to listen on port {d}: {}\n", .{ self.port, err }) catch {};
            return err;
        };

        const w = getLog();
        w.print("\n  zts dev server\n\n", .{}) catch {};
        w.print("  Local: http://localhost:{d}/\n", .{self.port}) catch {};
        w.print("  Root:  {s}\n", .{self.root_path}) catch {};
        if (self.entry_point) |ep| {
            w.print("  Entry: {s}\n", .{ep}) catch {};
        }
        w.print("\n", .{}) catch {};

        self.acceptLoop();
    }

    fn acceptLoop(self: *DevServer) void {
        while (true) {
            const connection = self.tcp_server.?.accept() catch |err| {
                getLog().print("zts: accept failed: {}\n", .{err}) catch {};
                continue;
            };
            self.handleConnection(connection);
        }
    }

    fn handleConnection(self: *DevServer, connection: std.net.Server.Connection) void {
        defer connection.stream.close();

        var send_buf: [8192]u8 = undefined;
        var recv_buf: [8192]u8 = undefined;
        var conn_reader = connection.stream.reader(&recv_buf);
        var conn_writer = connection.stream.writer(&send_buf);
        var server: http.Server = .init(conn_reader.interface(), &conn_writer.interface);

        while (true) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => {
                    getLog().print("zts: receiveHead failed: {}\n", .{err}) catch {};
                    return;
                },
            };

            self.handleRequest(&request) catch |err| {
                getLog().print("zts: request '{s}' failed: {}\n", .{ request.head.target, err }) catch {};
                return;
            };
        }
    }

    fn handleRequest(self: *DevServer, request: *http.Server.Request) !void {
        if (request.head.method == .OPTIONS) {
            try request.respond("", .{
                .status = .no_content,
                .extra_headers = &cors_headers,
            });
            return;
        }

        if (request.head.method != .GET and request.head.method != .HEAD) {
            try request.respond("405 Method Not Allowed", .{
                .status = .method_not_allowed,
                .extra_headers = &cors_headers,
            });
            return;
        }

        const target = request.head.target;
        const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const raw_path = target[0..path_end];

        const rel_path = sanitizePath(raw_path) orelse {
            try request.respond("403 Forbidden", .{
                .status = .forbidden,
                .extra_headers = &cors_headers,
            });
            return;
        };

        if (self.entry_point != null) {
            if (std.mem.eql(u8, raw_path, bundle_path)) {
                self.serveBundle(request) catch |err| {
                    getLog().print("zts: bundle failed: {}\n", .{err}) catch {};
                    // best-effort 500 응답 — 클라이언트가 이미 끊었을 수 있음
                    request.respond("500 Bundle Error", .{
                        .status = .internal_server_error,
                        .extra_headers = &cors_headers,
                    }) catch {};
                };
                return;
            }

            // / 요청 시 index.html이 없으면 자동 HTML 생성
            if (std.mem.eql(u8, rel_path, "index.html")) {
                self.serveStaticFile(request, rel_path) catch |err| switch (err) {
                    error.FileNotFound => {
                        try self.serveAutoHtml(request);
                    },
                    else => return err,
                };
                return;
            }
        }

        self.serveStaticFile(request, rel_path) catch |err| switch (err) {
            error.FileNotFound => {
                try request.respond("404 Not Found", .{
                    .status = .not_found,
                    .extra_headers = &cors_headers,
                });
            },
            else => return err,
        };
    }

    fn serveBundle(self: *DevServer, request: *http.Server.Request) !void {
        const abs_entry = self.abs_entry orelse unreachable;

        var bundler = Bundler.init(self.allocator, .{
            .entry_points = &.{abs_entry},
            .platform = .browser,
        });
        defer bundler.deinit();

        const result = try bundler.bundle();
        defer result.deinit(self.allocator);

        if (result.hasErrors()) {
            const diags = result.getDiagnostics();
            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(self.allocator);
            const w = msg.writer(self.allocator);
            try w.print("// ZTS Bundle Error\n", .{});
            for (diags) |d| {
                try w.print("// [{s}] {s}: {s}\n", .{
                    @tagName(d.severity),
                    d.file_path,
                    d.message,
                });
            }
            try w.print("console.error('ZTS: bundle failed, see server logs');\n", .{});

            try request.respond(msg.items, .{
                .status = .internal_server_error,
                .extra_headers = &js_headers,
            });

            getLog().print("  500 {s} (bundle errors)\n", .{abs_entry}) catch {};
            return;
        }

        try request.respond(result.output, .{
            .extra_headers = &js_headers,
        });

        getLog().print("  200 {s} (bundled)\n", .{bundle_path}) catch {};
    }

    fn serveAutoHtml(_: *DevServer, request: *http.Server.Request) !void {
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head><meta charset="utf-8"><title>ZTS Dev Server</title></head>
            \\<body>
            \\<div id="root"></div>
            \\<script type="module" src="/bundle.js"></script>
            \\</body>
            \\</html>
        ;

        try request.respond(html, .{
            .extra_headers = &html_headers,
        });

        getLog().print("  200 / (auto html)\n", .{}) catch {};
    }

    fn serveStaticFile(self: *DevServer, request: *http.Server.Request, rel_path: []const u8) !void {
        const file = try self.root_dir.openFile(rel_path, .{});
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, max_file_size) catch |err| switch (err) {
            error.FileTooBig => {
                try request.respond("413 Payload Too Large", .{
                    .status = .payload_too_large,
                    .extra_headers = &cors_headers,
                });
                return;
            },
            else => return err,
        };
        defer self.allocator.free(content);

        const content_type = mime.fromExtension(rel_path);
        const headers = cors_headers ++ [_]http.Header{
            .{ .name = "Content-Type", .value = content_type },
        };

        try request.respond(content, .{
            .extra_headers = &headers,
        });

        getLog().print("  200 {s}\n", .{rel_path}) catch {};
    }

    const cors_headers = [_]http.Header{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        .{ .name = "Access-Control-Allow-Methods", .value = "GET, HEAD, OPTIONS" },
        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
        .{ .name = "Cache-Control", .value = "no-cache, no-store, must-revalidate" },
    };
};

/// URL path를 안전한 상대 경로로 변환한다.
/// `..` 세그먼트나 의심스러운 경로는 null을 반환한다.
/// `/` → `index.html`, `/foo/bar` → `foo/bar`
fn sanitizePath(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return "index.html";

    var path = raw;
    while (path.len > 0 and path[0] == '/') {
        path = path[1..];
    }

    if (path.len == 0) return "index.html";

    // null 바이트, 백슬래시 — path traversal 방지
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;

    // `..` 세그먼트 — 디렉토리 탈출 방지
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return null;
    }

    return path;
}

test "sanitizePath: 루트 경로" {
    const testing = std.testing;
    try testing.expectEqualStrings("index.html", sanitizePath("/").?);
    try testing.expectEqualStrings("index.html", sanitizePath("").?);
    try testing.expectEqualStrings("index.html", sanitizePath("///").?);
}

test "sanitizePath: 일반 경로" {
    const testing = std.testing;
    try testing.expectEqualStrings("app.js", sanitizePath("/app.js").?);
    try testing.expectEqualStrings("src/main.ts", sanitizePath("/src/main.ts").?);
    try testing.expectEqualStrings("assets/logo.png", sanitizePath("/assets/logo.png").?);
}

test "sanitizePath: 디렉토리 탈출 차단" {
    const testing = std.testing;
    try testing.expect(sanitizePath("/../etc/passwd") == null);
    try testing.expect(sanitizePath("/..") == null);
    try testing.expect(sanitizePath("/../..") == null);
    try testing.expect(sanitizePath("/foo/../../etc/passwd") == null);
}

test "sanitizePath: null 바이트 차단" {
    const testing = std.testing;
    try testing.expect(sanitizePath("/foo\x00bar") == null);
}

test "sanitizePath: 백슬래시 차단" {
    const testing = std.testing;
    try testing.expect(sanitizePath("/foo\\bar") == null);
    try testing.expect(sanitizePath("\\..\\etc\\passwd") == null);
}
