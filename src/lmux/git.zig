const std = @import("std");

pub const Info = struct {
    repo_root: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    dirty: bool = false,

    pub fn deinit(self: *Info, alloc: std.mem.Allocator) void {
        if (self.repo_root) |v| alloc.free(v);
        if (self.branch) |v| alloc.free(v);
    }
};

pub fn inspect(alloc: std.mem.Allocator, cwd: []const u8) Info {
    var result: Info = .{};
    result.repo_root = runTrimmed(alloc, cwd, &.{ "git", "rev-parse", "--show-toplevel" }) catch null;
    result.branch = runTrimmed(alloc, cwd, &.{ "git", "branch", "--show-current" }) catch null;
    const dirty = runTrimmed(alloc, cwd, &.{ "git", "status", "--porcelain", "--untracked-files=no" }) catch null;
    if (dirty) |v| {
        defer alloc.free(v);
        result.dirty = v.len > 0;
    }
    return result;
}

fn runTrimmed(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 32 * 1024,
    });
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);
    if (result.term != .Exited or result.term.Exited != 0) {
        alloc.free(result.stdout);
        return error.CommandFailed;
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == result.stdout.len) return result.stdout;
    const copy = try alloc.dupe(u8, trimmed);
    alloc.free(result.stdout);
    return copy;
}
