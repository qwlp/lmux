const std = @import("std");

pub const Info = struct {
    ports: []u16 = &.{},
    summary: ?[]const u8 = null,

    pub fn deinit(self: *Info, alloc: std.mem.Allocator) void {
        if (self.ports.len > 0) alloc.free(self.ports);
        if (self.summary) |v| alloc.free(v);
    }
};

pub fn inspect(alloc: std.mem.Allocator, root_pid: ?std.posix.pid_t) Info {
    const pid = root_pid orelse return .{};

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const tmp = arena.allocator();

    var descendants = collectDescendants(tmp, pid) catch return .{};
    var ports = collectListeningPorts(tmp, &descendants) catch return .{};
    if (ports.items.len == 0) return .{};

    std.mem.sort(u16, ports.items, {}, comptime std.sort.asc(u16));
    const owned_ports = ports.toOwnedSlice(alloc) catch return .{};
    errdefer alloc.free(owned_ports);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(alloc);
    var writer = out.writer(alloc);

    const limit = @min(owned_ports.len, 6);
    for (owned_ports[0..limit], 0..) |port, index| {
        if (index > 0) writer.writeAll(", ") catch return .{};
        writer.print("{d}", .{port}) catch return .{};
    }
    if (owned_ports.len > limit) {
        writer.print(" (+{d})", .{owned_ports.len - limit}) catch return .{};
    }

    return .{
        .ports = owned_ports,
        .summary = out.toOwnedSlice(alloc) catch null,
    };
}

fn collectDescendants(
    alloc: std.mem.Allocator,
    root_pid: std.posix.pid_t,
) !std.ArrayList(std.posix.pid_t) {
    var all_processes = std.ArrayList(ProcessInfo).empty;
    defer all_processes.deinit(alloc);

    var proc_dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer proc_dir.close();

    var it = proc_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        const stat_path = try std.fmt.allocPrint(alloc, "/proc/{d}/stat", .{pid});
        defer alloc.free(stat_path);

        const stat_file = std.fs.openFileAbsolute(stat_path, .{}) catch continue;
        defer stat_file.close();
        const stat = stat_file.readToEndAlloc(alloc, 8 * 1024) catch continue;
        const ppid = parseParentPid(stat) catch {
            alloc.free(stat);
            continue;
        };
        alloc.free(stat);

        try all_processes.append(alloc, .{ .pid = pid, .ppid = ppid });
    }

    var descendants = std.ArrayList(std.posix.pid_t).empty;
    try descendants.append(alloc, root_pid);

    var changed = true;
    while (changed) {
        changed = false;
        for (all_processes.items) |process| {
            if (containsPid(descendants.items, process.pid)) continue;
            if (!containsPid(descendants.items, process.ppid)) continue;
            try descendants.append(alloc, process.pid);
            changed = true;
        }
    }

    return descendants;
}

fn collectListeningPorts(
    alloc: std.mem.Allocator,
    descendants: *const std.ArrayList(std.posix.pid_t),
) !std.ArrayList(u16) {
    var socket_inodes = std.StringHashMapUnmanaged(void){};
    defer socket_inodes.deinit(alloc);

    for (descendants.items) |pid| {
        const fd_path = std.fmt.allocPrint(alloc, "/proc/{d}/fd", .{pid}) catch continue;
        defer alloc.free(fd_path);

        var fd_dir = std.fs.openDirAbsolute(fd_path, .{ .iterate = true }) catch continue;
        defer fd_dir.close();

        var fd_it = fd_dir.iterate();
        while (try fd_it.next()) |entry| {
            var target_buf: [256]u8 = undefined;
            const target = fd_dir.readLink(entry.name, &target_buf) catch continue;
            const inode = parseSocketInode(target) orelse continue;
            const gop = try socket_inodes.getOrPut(alloc, inode);
            if (!gop.found_existing) gop.key_ptr.* = try alloc.dupe(u8, inode);
        }
    }

    var ports = std.ArrayList(u16).empty;
    errdefer ports.deinit(alloc);
    try collectPortsFromTable(alloc, "/proc/net/tcp", "0A", &socket_inodes, &ports);
    try collectPortsFromTable(alloc, "/proc/net/tcp6", "0A", &socket_inodes, &ports);
    try collectPortsFromTable(alloc, "/proc/net/udp", null, &socket_inodes, &ports);
    try collectPortsFromTable(alloc, "/proc/net/udp6", null, &socket_inodes, &ports);
    return ports;
}

fn collectPortsFromTable(
    alloc: std.mem.Allocator,
    path: []const u8,
    required_state: ?[]const u8,
    socket_inodes: *const std.StringHashMapUnmanaged(void),
    ports: *std.ArrayList(u16),
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch return;
    defer file.close();
    const data = file.readToEndAlloc(alloc, 256 * 1024) catch return;
    defer alloc.free(data);

    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    _ = lines.next();
    while (lines.next()) |line| {
        const parsed = parseSocketTableLine(line) orelse continue;
        if (required_state) |state| {
            if (!std.mem.eql(u8, parsed.state, state)) continue;
        }
        if (!socket_inodes.contains(parsed.inode)) continue;
        if (!containsPort(ports.items, parsed.port)) {
            try ports.append(alloc, parsed.port);
        }
    }
}

fn parseParentPid(stat: []const u8) !std.posix.pid_t {
    const close_idx = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.InvalidStat;
    const tail = std.mem.trimLeft(u8, stat[close_idx + 1 ..], " ");
    var tokens = std.mem.tokenizeScalar(u8, tail, ' ');
    _ = tokens.next() orelse return error.InvalidStat;
    const ppid_text = tokens.next() orelse return error.InvalidStat;
    return try std.fmt.parseInt(std.posix.pid_t, ppid_text, 10);
}

fn parseSocketInode(target: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, target, "socket:[")) return null;
    if (target.len < 9 or target[target.len - 1] != ']') return null;
    return target[8 .. target.len - 1];
}

fn parseSocketTableLine(line: []const u8) ?struct { port: u16, state: []const u8, inode: []const u8 } {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    _ = tokens.next() orelse return null;
    const local_addr = tokens.next() orelse return null;
    const state = tokens.next() orelse return null;
    _ = tokens.next() orelse return null;
    _ = tokens.next() orelse return null;
    _ = tokens.next() orelse return null;
    _ = tokens.next() orelse return null;
    _ = tokens.next() orelse return null;
    _ = tokens.next() orelse return null;
    const inode = tokens.next() orelse return null;

    const colon = std.mem.lastIndexOfScalar(u8, local_addr, ':') orelse return null;
    const port = std.fmt.parseInt(u16, local_addr[colon + 1 ..], 16) catch return null;
    return .{ .port = port, .state = state, .inode = inode };
}

fn containsPid(pids: []const std.posix.pid_t, needle: std.posix.pid_t) bool {
    for (pids) |pid| {
        if (pid == needle) return true;
    }
    return false;
}

fn containsPort(ports: []const u16, needle: u16) bool {
    for (ports) |port| {
        if (port == needle) return true;
    }
    return false;
}

const ProcessInfo = struct {
    pid: std.posix.pid_t,
    ppid: std.posix.pid_t,
};

test "parse parent pid from proc stat" {
    const stat = "1234 (node) S 4321 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 1";
    try std.testing.expectEqual(@as(std.posix.pid_t, 4321), try parseParentPid(stat));
}

test "parse proc socket line" {
    const line = "  0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 12345 1 0000000000000000 100 0 0 10 0";
    const parsed = parseSocketTableLine(line).?;
    try std.testing.expectEqual(@as(u16, 3000), parsed.port);
    try std.testing.expectEqualStrings("0A", parsed.state);
    try std.testing.expectEqualStrings("12345", parsed.inode);
}

test "info deinit frees retained ports" {
    const alloc = std.testing.allocator;
    var info = Info{
        .ports = try alloc.dupe(u16, &.{ 3000, 8080 }),
        .summary = try alloc.dupe(u8, "3000, 8080"),
    };
    info.deinit(alloc);
}
