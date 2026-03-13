const std = @import("std");

pub const Info = struct {
    number: ?u32 = null,
    status: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    unavailable: bool = false,

    pub fn deinit(self: *Info, alloc: std.mem.Allocator) void {
        if (self.status) |v| alloc.free(v);
        if (self.summary) |v| alloc.free(v);
    }
};

pub fn inspect(alloc: std.mem.Allocator, cwd: []const u8) Info {
    var result: Info = .{};
    const cmd = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "gh", "pr", "view", "--json", "number,state,title" },
        .cwd = cwd,
        .max_output_bytes = 64 * 1024,
    }) catch {
        result.unavailable = true;
        return result;
    };
    defer alloc.free(cmd.stderr);
    defer alloc.free(cmd.stdout);
    if (cmd.term != .Exited or cmd.term.Exited != 0) {
        result.unavailable = true;
        return result;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, cmd.stdout, .{}) catch {
        result.unavailable = true;
        return result;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    if (obj.get("number")) |number_val| {
        switch (number_val) {
            .integer => |v| result.number = @intCast(v),
            else => {},
        }
    }
    if (obj.get("state")) |state_val| {
        if (state_val == .string) result.status = alloc.dupe(u8, state_val.string) catch null;
    }
    if (result.number) |n| {
        if (obj.get("title")) |title_val| {
            if (title_val == .string) {
                result.summary = std.fmt.allocPrint(alloc, "PR #{d}: {s}", .{ n, title_val.string }) catch null;
            }
        }
        if (result.summary == null) {
            result.summary = std.fmt.allocPrint(alloc, "PR #{d}", .{n}) catch null;
        }
    }
    if (result.number == null and result.status == null) result.unavailable = true;
    return result;
}
