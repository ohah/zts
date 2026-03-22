const std = @import("std");
const http = std.http;
const mime = @import("mime.zig");
const lib = @import("../root.zig");
const Bundler = lib.bundler.Bundler;

fn getLog() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

/// WS 클라이언트 목록 — 여러 스레드에서 접근하므로 mutex로 보호
const WsClients = struct {
    mutex: std.Thread.Mutex = .{},
    /// WebSocket output writer 포인터 목록. handleWebSocket 스택에서 소유.
    items: [max_clients]*std.Io.Writer = undefined,
    len: usize = 0,

    const max_clients = 64;

    fn add(self: *WsClients, writer: *std.Io.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len < max_clients) {
            self.items[self.len] = writer;
            self.len += 1;
        }
    }

    fn remove(self: *WsClients, writer: *std.Io.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items[0..self.len], 0..) |item, i| {
            if (item == writer) {
                self.len -= 1;
                self.items[i] = self.items[self.len];
                return;
            }
        }
    }

    fn broadcast(self: *WsClients, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items[0..self.len]) |writer| {
            // WebSocket text frame: FIN + opcode=text, then length, then payload
            writeWsFrame(writer, data) catch {};
        }
    }
};

/// WebSocket text frame을 직접 인코딩하여 writer에 쓴다.
/// std.http.Server.WebSocket.writeMessage와 동일한 형식이지만,
/// WebSocket 구조체 없이 raw writer로 전송할 수 있다.
fn writeWsFrame(writer: *std.Io.Writer, data: []const u8) !void {
    // FIN=1, opcode=text(1)
    try writer.writeByte(0x81);
    // payload length (mask=0, server→client이므로 mask 불필요)
    if (data.len < 126) {
        try writer.writeByte(@intCast(data.len));
    } else if (data.len <= 65535) {
        try writer.writeByte(126);
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(data.len))));
    } else {
        try writer.writeByte(127);
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @intCast(data.len))));
    }
    try writer.writeAll(data);
    try writer.flush();
}

pub const DevServer = struct {
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    root_path: []const u8,
    port: u16,
    tcp_server: ?std.net.Server,
    entry_point: ?[]const u8,
    abs_entry: ?[]const u8,
    ws_clients: WsClients = .{},

    pub const Options = struct {
        root_dir: []const u8 = ".",
        port: u16 = 3000,
        entry_point: ?[]const u8 = null,
    };

    const max_file_size: u64 = 50 * 1024 * 1024;
    const bundle_path = "/bundle.js";
    const hmr_path = "/__hmr";
    const watch_interval_ms = 500;

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

        // entry가 있으면 watch 스레드 시작
        if (self.abs_entry != null) {
            const watch_thread = std.Thread.spawn(.{}, watchLoop, .{self}) catch |err| {
                getLog().print("zts: failed to start watch thread: {}\n", .{err}) catch {};
                return err;
            };
            watch_thread.detach();
        }

        self.acceptLoop();
    }

    fn acceptLoop(self: *DevServer) void {
        while (true) {
            const connection = self.tcp_server.?.accept() catch |err| {
                getLog().print("zts: accept failed: {}\n", .{err}) catch {};
                continue;
            };
            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, connection }) catch {
                connection.stream.close();
                continue;
            };
            thread.detach();
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

            switch (request.upgradeRequested()) {
                .websocket => |opt_key| {
                    const key = opt_key orelse {
                        getLog().print("zts: WebSocket upgrade missing key\n", .{}) catch {};
                        return;
                    };

                    // /__hmr 경로에서만 WebSocket 허용
                    const target = request.head.target;
                    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
                    if (!std.mem.eql(u8, target[0..path_end], hmr_path)) {
                        request.respond("400 Bad Request", .{
                            .status = .bad_request,
                            .extra_headers = &cors_headers,
                        }) catch {};
                        return;
                    }

                    var ws = request.respondWebSocket(.{ .key = key }) catch {
                        getLog().print("zts: WebSocket handshake failed\n", .{}) catch {};
                        return;
                    };
                    self.handleWebSocket(&ws, &conn_writer.interface);
                    return;
                },
                .other => {
                    request.respond("400 Bad Request", .{
                        .status = .bad_request,
                        .extra_headers = &cors_headers,
                    }) catch {};
                    return;
                },
                .none => {},
            }

            self.handleRequest(&request) catch |err| {
                getLog().print("zts: request '{s}' failed: {}\n", .{ request.head.target, err }) catch {};
                return;
            };
        }
    }

    fn handleWebSocket(self: *DevServer, ws: *http.Server.WebSocket, writer: *std.Io.Writer) void {
        getLog().print("  [ws] client connected\n", .{}) catch {};

        // broadcast 리스트에 등록
        self.ws_clients.add(writer);
        defer self.ws_clients.remove(writer);

        ws.writeMessage("{\"type\":\"connected\"}", .text) catch {
            getLog().print("  [ws] failed to send connected message\n", .{}) catch {};
            return;
        };

        // 클라이언트 메시지 수신 루프 (ping/pong은 std.http가 자동 처리)
        while (true) {
            const msg = ws.readSmallMessage() catch |err| {
                switch (err) {
                    error.ConnectionClose => {},
                    else => getLog().print("  [ws] read error: {}\n", .{err}) catch {},
                }
                break;
            };

            switch (msg.opcode) {
                .text => {
                    getLog().print("  [ws] recv: {s}\n", .{msg.data}) catch {};
                },
                .connection_close => break,
                else => {},
            }
        }

        getLog().print("  [ws] client disconnected\n", .{}) catch {};
    }

    fn watchLoop(self: *DevServer) void {
        getLog().print("  [watch] watching for changes...\n", .{}) catch {};

        var last_mtime = getEntryMtime(self) orelse return;

        while (true) {
            std.Thread.sleep(watch_interval_ms * std.time.ns_per_ms);

            const current_mtime = getEntryMtime(self) orelse continue;
            if (current_mtime != last_mtime) {
                last_mtime = current_mtime;
                getLog().print("  [watch] file changed, sending full-reload\n", .{}) catch {};
                self.ws_clients.broadcast("{\"type\":\"full-reload\"}");
            }
        }
    }

    fn getEntryMtime(self: *DevServer) ?i128 {
        const entry = self.abs_entry orelse return null;
        const stat = std.fs.cwd().statFile(entry) catch return null;
        return stat.mtime;
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
                    request.respond("500 Bundle Error", .{
                        .status = .internal_server_error,
                        .extra_headers = &cors_headers,
                    }) catch {};
                };
                return;
            }

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
            \\<script>
            \\(function() {
            \\  var ws, timer;
            \\  function connect() {
            \\    ws = new WebSocket('ws://' + location.host + '/__hmr');
            \\    ws.onopen = function() { console.log('[zts] HMR connected'); };
            \\    ws.onmessage = function(e) {
            \\      var msg = JSON.parse(e.data);
            \\      if (msg.type === 'full-reload') { location.reload(); }
            \\    };
            \\    ws.onclose = function() {
            \\      console.log('[zts] HMR disconnected, reconnecting...');
            \\      clearTimeout(timer);
            \\      timer = setTimeout(connect, 1000);
            \\    };
            \\  }
            \\  connect();
            \\})();
            \\</script>
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
