const std = @import("std");
const paths = @import("paths.zig");

pub const Config = struct {
    sidebar_width: u16 = 312,
    notification_panel_width: u16 = 376,
    github_enabled: bool = true,
    listening_ports_enabled: bool = true,
    metadata_refresh_ms: u32 = 5_000,
    socket_path: ?[:0]const u8 = null,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        if (self.socket_path) |v| alloc.free(v);
    }
};

pub fn load(alloc: std.mem.Allocator) !Config {
    const ghostty_path = try paths.configPath(alloc, "ghostty/config");
    defer alloc.free(ghostty_path);

    const lmux_path = try paths.configPath(alloc, "lmux/config");
    defer alloc.free(lmux_path);

    return try loadFromPaths(alloc, ghostty_path, lmux_path);
}

pub fn loadFromPaths(
    alloc: std.mem.Allocator,
    ghostty_path: []const u8,
    lmux_path: []const u8,
) !Config {
    var result: Config = .{};
    var visited = std.StringHashMap(void).init(alloc);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |key| alloc.free(key.*);
        visited.deinit();
    }

    try loadInto(alloc, &result, ghostty_path, &visited);
    try loadInto(alloc, &result, lmux_path, &visited);

    if (result.socket_path == null) {
        result.socket_path = try defaultSocketPath(alloc);
    }
    return result;
}

pub fn defaultSocketPath(alloc: std.mem.Allocator) ![:0]const u8 {
    const runtime_dir = try paths.runtimeDir(alloc);
    defer alloc.free(runtime_dir);

    const full_path = try std.fs.path.join(alloc, &.{ runtime_dir, "socket.v1" });
    defer alloc.free(full_path);
    return try alloc.dupeZ(u8, full_path);
}

fn loadInto(
    alloc: std.mem.Allocator,
    cfg: *Config,
    file_path: []const u8,
    visited: *std.StringHashMap(void),
) !void {
    const gop = try visited.getOrPut(file_path);
    if (gop.found_existing) return;
    gop.key_ptr.* = try alloc.dupe(u8, file_path);

    const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(alloc, 128 * 1024);
    defer alloc.free(bytes);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "config-file")) {
            const include_path = try resolveInclude(alloc, file_path, value);
            defer alloc.free(include_path);
            try loadInto(alloc, cfg, include_path, visited);
            continue;
        }
        if (std.mem.eql(u8, key, "lmux-sidebar-width")) {
            cfg.sidebar_width = std.fmt.parseUnsigned(u16, value, 10) catch cfg.sidebar_width;
            continue;
        }
        if (std.mem.eql(u8, key, "lmux-notification-panel-width")) {
            cfg.notification_panel_width = std.fmt.parseUnsigned(u16, value, 10) catch cfg.notification_panel_width;
            continue;
        }
        if (std.mem.eql(u8, key, "lmux-github-enabled")) {
            cfg.github_enabled = parseBool(value) orelse cfg.github_enabled;
            continue;
        }
        if (std.mem.eql(u8, key, "lmux-listening-ports-enabled")) {
            cfg.listening_ports_enabled = parseBool(value) orelse cfg.listening_ports_enabled;
            continue;
        }
        if (std.mem.eql(u8, key, "lmux-metadata-refresh-ms")) {
            cfg.metadata_refresh_ms = std.fmt.parseUnsigned(u32, value, 10) catch cfg.metadata_refresh_ms;
            continue;
        }
        if (std.mem.eql(u8, key, "lmux-socket-path")) {
            if (cfg.socket_path) |existing| alloc.free(existing);
            cfg.socket_path = try alloc.dupeZ(u8, value);
            continue;
        }
    }
}

fn resolveInclude(
    alloc: std.mem.Allocator,
    current_file: []const u8,
    value: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(value)) return try alloc.dupe(u8, value);

    const parent = std.fs.path.dirname(current_file) orelse return try alloc.dupe(u8, value);
    return try std.fs.path.join(alloc, &.{ parent, value });
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

test "lmux config overrides ghostty config" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("ghostty");
    try tmp.dir.makePath("lmux");

    {
        const file = try tmp.dir.createFile("ghostty/config", .{});
        defer file.close();
        try file.writeAll(
            \\lmux-sidebar-width = 300
            \\lmux-github-enabled = false
            \\
        );
    }
    {
        const file = try tmp.dir.createFile("lmux/config", .{});
        defer file.close();
        try file.writeAll(
            \\lmux-sidebar-width = 420
            \\lmux-listening-ports-enabled = false
            \\lmux-metadata-refresh-ms = 1200
            \\
        );
    }

    const ghostty_path = try tmp.dir.realpathAlloc(alloc, "ghostty/config");
    defer alloc.free(ghostty_path);
    const lmux_path = try tmp.dir.realpathAlloc(alloc, "lmux/config");
    defer alloc.free(lmux_path);

    var cfg = try loadFromPaths(alloc, ghostty_path, lmux_path);
    defer cfg.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 420), cfg.sidebar_width);
    try std.testing.expectEqual(false, cfg.github_enabled);
    try std.testing.expectEqual(false, cfg.listening_ports_enabled);
    try std.testing.expectEqual(@as(u32, 1200), cfg.metadata_refresh_ms);
}
