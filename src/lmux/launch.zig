const std = @import("std");
const gui = @import("gui.zig");

pub fn run(alloc: std.mem.Allocator, args: []const []const u8) !void {
    try gui.run(alloc, args);
}
