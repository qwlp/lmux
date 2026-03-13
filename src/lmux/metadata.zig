const std = @import("std");
const git = @import("git.zig");
const github = @import("github.zig");
const ports = @import("ports.zig");

pub const Snapshot = struct {
    cwd: ?[]const u8 = null,
    cwd_basename: ?[]const u8 = null,
    git_info: git.Info = .{},
    github_info: github.Info = .{},
    ports_info: ports.Info = .{},

    pub fn deinit(self: *Snapshot, alloc: std.mem.Allocator) void {
        if (self.cwd) |v| alloc.free(v);
        if (self.cwd_basename) |v| alloc.free(v);
        self.git_info.deinit(alloc);
        self.github_info.deinit(alloc);
        self.ports_info.deinit(alloc);
    }
};

pub fn collect(
    alloc: std.mem.Allocator,
    cwd: ?[]const u8,
    root_pid: ?std.posix.pid_t,
    enable_github: bool,
    enable_ports: bool,
) Snapshot {
    var result: Snapshot = .{};
    if (cwd) |cwd_value| {
        result.cwd = alloc.dupe(u8, cwd_value) catch null;
        result.cwd_basename = basenameOwned(alloc, cwd_value) catch null;
        result.git_info = git.inspect(alloc, cwd_value);
        if (enable_github) result.github_info = github.inspect(alloc, cwd_value);
    }
    if (enable_ports) result.ports_info = ports.inspect(alloc, root_pid);
    return result;
}

fn basenameOwned(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try alloc.dupe(u8, std.fs.path.basename(path));
}
