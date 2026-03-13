const std = @import("std");

pub fn configPath(alloc: std.mem.Allocator, relative: []const u8) ![]const u8 {
    const config_home = std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            const home = try std.process.getEnvVarOwned(alloc, "HOME");
            defer alloc.free(home);
            break :blk try std.fs.path.join(alloc, &.{ home, ".config" });
        },
        else => return err,
    };
    defer alloc.free(config_home);
    return try std.fs.path.join(alloc, &.{ config_home, relative });
}

pub fn runtimeDir(alloc: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(alloc, "XDG_RUNTIME_DIR") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => blk: {
            break :blk try std.fmt.allocPrint(alloc, "/tmp/lmux-{d}", .{std.posix.getuid()});
        },
        else => return err,
    };
}

pub fn ensureParentPath(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
