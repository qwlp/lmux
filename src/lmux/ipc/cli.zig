const std = @import("std");
const lmux_config = @import("../config.zig");
const key_specs = @import("../keys.zig");

pub fn run(alloc: std.mem.Allocator) !?u8 {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len <= 1) return null;
    if (std.mem.eql(u8, args[1], "serve") or std.mem.eql(u8, args[1], "gui")) return null;

    if (std.mem.eql(u8, args[1], "notify")) {
        return try runNotify(alloc, args[2..]);
    }
    if (std.mem.eql(u8, args[1], "notifications")) {
        return try runNotifications(alloc, args[2..]);
    }
    if (std.mem.eql(u8, args[1], "workspace")) {
        return try runWorkspace(alloc, args[2..]);
    }
    if (std.mem.eql(u8, args[1], "app")) {
        return try runApp(alloc, args[2..]);
    }
    if (std.mem.eql(u8, args[1], "tab")) {
        return try runTab(alloc, args[2..]);
    }
    if (std.mem.eql(u8, args[1], "pane")) {
        return try runPane(alloc, args[2..]);
    }

    return null;
}

fn runWorkspace(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return error.InvalidCommand;
    const action = args[0];
    if (std.mem.eql(u8, action, "create")) {
        if (args.len >= 3 and std.mem.eql(u8, args[1], "--name")) {
            const payload = try std.fmt.allocPrint(
                alloc,
                "{{\"id\":\"cli\",\"method\":\"workspace.create\",\"params\":{{\"name\":{f}}}}}\n",
                .{std.json.fmt(args[2], .{})},
            );
            defer alloc.free(payload);
            try sendRaw(alloc, payload);
            return 0;
        }
        try sendRaw(alloc, "{\"id\":\"cli\",\"method\":\"workspace.create\",\"params\":{}}\n");
        return 0;
    }
    if (std.mem.eql(u8, action, "list")) {
        try sendRaw(alloc, "{\"id\":\"cli\",\"method\":\"workspace.list\",\"params\":{}}\n");
        return 0;
    }
    if (std.mem.eql(u8, action, "focus")) {
        if (args.len < 2) return error.InvalidCommand;
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"workspace.focus\",\"params\":{{\"workspace_id\":{f}}}}}\n",
            .{std.json.fmt(args[1], .{})},
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    return error.InvalidCommand;
}

fn runApp(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0 or std.mem.eql(u8, args[0], "status")) {
        try sendRaw(alloc, "{\"id\":\"cli\",\"method\":\"app.status\",\"params\":{}}\n");
        return 0;
    }
    return error.InvalidCommand;
}

fn runTab(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return error.InvalidCommand;
    const action = args[0];
    if (std.mem.eql(u8, action, "create")) {
        if (args.len >= 3 and std.mem.eql(u8, args[1], "--workspace")) {
            const payload = try std.fmt.allocPrint(
                alloc,
                "{{\"id\":\"cli\",\"method\":\"tab.create\",\"params\":{{\"workspace_id\":{f}}}}}\n",
                .{std.json.fmt(args[2], .{})},
            );
            defer alloc.free(payload);
            try sendRaw(alloc, payload);
            return 0;
        }
        try sendRaw(alloc, "{\"id\":\"cli\",\"method\":\"tab.create\",\"params\":{}}\n");
        return 0;
    }
    if (std.mem.eql(u8, action, "focus")) {
        if (args.len < 2) return error.InvalidCommand;
        const tab_id = args[1];
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"tab.focus\",\"params\":{{\"tab_id\":{f}}}}}\n",
            .{std.json.fmt(tab_id, .{})},
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    return error.InvalidCommand;
}

fn runPane(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) return error.InvalidCommand;
    const action = args[0];

    if (std.mem.eql(u8, action, "split")) {
        if (args.len < 5 or !std.mem.eql(u8, args[1], "--pane") or !std.mem.eql(u8, args[3], "--direction")) {
            return error.InvalidCommand;
        }
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"pane.split\",\"params\":{{\"pane_id\":{f},\"direction\":{f}}}}}\n",
            .{
                std.json.fmt(args[2], .{}),
                std.json.fmt(args[4], .{}),
            },
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    if (std.mem.eql(u8, action, "focus")) {
        if (args.len < 2) return error.InvalidCommand;
        const pane_id = args[1];
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"pane.focus\",\"params\":{{\"pane_id\":{f}}}}}\n",
            .{std.json.fmt(pane_id, .{})},
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    if (std.mem.eql(u8, action, "send-text")) {
        if (args.len < 3) return error.InvalidCommand;
        const pane_id = args[1];
        const text = args[2];
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"pane.send_text\",\"params\":{{\"pane_id\":{f},\"text\":{f}}}}}\n",
            .{
                std.json.fmt(pane_id, .{}),
                std.json.fmt(text, .{}),
            },
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    if (std.mem.eql(u8, action, "send-keys")) {
        if (args.len < 4 or !std.mem.eql(u8, args[1], "--pane")) return error.InvalidCommand;
        const pane_id = args[2];
        if (!std.mem.eql(u8, args[3], "--key")) return error.InvalidCommand;

        var json_keys: std.ArrayList(u8) = .{};
        defer json_keys.deinit(alloc);
        var writer = json_keys.writer(alloc);
        try writer.writeByte('[');

        var index: usize = 3;
        var count: usize = 0;
        while (index < args.len) {
            if (!std.mem.eql(u8, args[index], "--key")) return error.InvalidCommand;
            if (index + 1 >= args.len) return error.InvalidCommand;
            const parsed = try key_specs.parseCliSpec(args[index + 1]);
            if (count > 0) try writer.writeByte(',');
            try writer.print("{{\"key\":{f}", .{std.json.fmt(parsed.key, .{})});
            if (parsed.mods.ctrl or parsed.mods.alt or parsed.mods.shift or parsed.mods.super) {
                try writer.writeAll(",\"mods\":[");
                var wrote_mod = false;
                if (parsed.mods.ctrl) {
                    try writer.print("{f}", .{std.json.fmt("ctrl", .{})});
                    wrote_mod = true;
                }
                if (parsed.mods.alt) {
                    if (wrote_mod) try writer.writeByte(',');
                    try writer.print("{f}", .{std.json.fmt("alt", .{})});
                    wrote_mod = true;
                }
                if (parsed.mods.shift) {
                    if (wrote_mod) try writer.writeByte(',');
                    try writer.print("{f}", .{std.json.fmt("shift", .{})});
                    wrote_mod = true;
                }
                if (parsed.mods.super) {
                    if (wrote_mod) try writer.writeByte(',');
                    try writer.print("{f}", .{std.json.fmt("super", .{})});
                }
                try writer.writeByte(']');
            }
            if (parsed.action != .press) {
                try writer.print(",\"action\":{f}", .{std.json.fmt(@tagName(parsed.action), .{})});
            }
            try writer.writeByte('}');
            count += 1;
            index += 2;
        }
        try writer.writeByte(']');

        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"pane.send_keys\",\"params\":{{\"pane_id\":{f},\"keys\":{s}}}}}\n",
            .{
                std.json.fmt(pane_id, .{}),
                json_keys.items,
            },
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    return error.InvalidCommand;
}

fn runNotify(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    var sticky = true;
    var pane_id: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len and std.mem.startsWith(u8, args[index], "--")) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--pane")) {
            index += 1;
            pane_id = args[index];
            continue;
        }
        if (std.mem.eql(u8, args[index], "--source")) {
            index += 1;
            source = args[index];
            continue;
        }
        if (std.mem.eql(u8, args[index], "--non-sticky")) {
            sticky = false;
            continue;
        }
        return error.InvalidCommand;
    }

    const title = if (index < args.len) args[index] else "";
    const body = if (index + 1 < args.len) args[index + 1] else "";

    const source_json = if (source) |value|
        try std.fmt.allocPrint(alloc, ",\"source\":{f}", .{std.json.fmt(value, .{})})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(source_json);

    const payload = if (pane_id) |target|
        try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"pane.notify\",\"params\":{{\"pane_id\":{f},\"title\":{f},\"body\":{f},\"sticky\":{}{s}}}}}\n",
            .{
                std.json.fmt(target, .{}),
                std.json.fmt(title, .{}),
                std.json.fmt(body, .{}),
                sticky,
                source_json,
            },
        )
    else
        try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"pane.notify\",\"params\":{{\"title\":{f},\"body\":{f},\"sticky\":{}{s}}}}}\n",
            .{
                std.json.fmt(title, .{}),
                std.json.fmt(body, .{}),
                sticky,
                source_json,
            },
        );
    defer alloc.free(payload);
    try sendRaw(alloc, payload);
    return 0;
}

fn runNotifications(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len == 0) {
        try sendRaw(alloc, "{\"id\":\"cli\",\"method\":\"notification.list\",\"params\":{}}\n");
        return 0;
    }
    if (std.mem.eql(u8, args[0], "jump-latest")) {
        try sendRaw(alloc, "{\"id\":\"cli\",\"method\":\"notification.jump_latest\",\"params\":{}}\n");
        return 0;
    }
    if (std.mem.eql(u8, args[0], "open")) {
        if (args.len < 2) return error.InvalidCommand;
        const notification_id = args[1];
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"notification.activate\",\"params\":{{\"notification_id\":{f}}}}}\n",
            .{std.json.fmt(notification_id, .{})},
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    if (std.mem.eql(u8, args[0], "mark-read")) {
        if (args.len < 2) return error.InvalidCommand;
        const notification_id = args[1];
        const payload = try std.fmt.allocPrint(
            alloc,
            "{{\"id\":\"cli\",\"method\":\"notification.mark_read\",\"params\":{{\"notification_id\":{f}}}}}\n",
            .{std.json.fmt(notification_id, .{})},
        );
        defer alloc.free(payload);
        try sendRaw(alloc, payload);
        return 0;
    }
    return error.InvalidCommand;
}

fn sendRaw(alloc: std.mem.Allocator, payload: []const u8) !void {
    var cfg = try lmux_config.load(alloc);
    defer cfg.deinit(alloc);
    const path = cfg.socket_path orelse return error.SocketPathUnavailable;

    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(fd);

    var addr = std.posix.sockaddr.un{
        .family = std.posix.AF.UNIX,
        .path = [_]u8{0} ** 108,
    };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..path.len], path);

    const len = @as(u32, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + 1));
    try std.posix.connect(fd, @ptrCast(&addr), len);
    _ = try std.posix.write(fd, payload);

    var buf: [4096]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    if (n > 0) try std.fs.File.stdout().writeAll(buf[0..n]);
}
