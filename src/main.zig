const std = @import("std");
const lmux = @import("lmux/main.zig");
const protocol = lmux.ipc.protocol;

pub const std_options = @import("main_ghostty.zig").std_options;

const HeadlessHandler = struct {
    state: *lmux.AppState,

    fn handleLine(
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        line: []const u8,
    ) ![]u8 {
        const self: *HeadlessHandler = @ptrCast(@alignCast(ctx));

        var parsed = protocol.parseRequest(alloc, line) catch {
            var out: std.ArrayList(u8) = .{};
            errdefer out.deinit(alloc);
            try protocol.writeError(
                out.writer(alloc),
                null,
                "invalid_json",
                "request must be a JSON object with id, method, and params",
            );
            return try out.toOwnedSlice(alloc);
        };
        defer parsed.deinit();

        const result = try self.state.dispatch(alloc, parsed.method, parsed.params);
        defer switch (result) {
            .success => |payload| alloc.free(payload),
            .failure => {},
        };

        var out: std.ArrayList(u8) = .{};
        errdefer out.deinit(alloc);
        switch (result) {
            .success => |payload| try protocol.writeSuccess(out.writer(alloc), parsed.id, payload),
            .failure => |failure| try protocol.writeError(out.writer(alloc), parsed.id, failure.code, failure.message),
        }
        return try out.toOwnedSlice(alloc);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    if (try lmux.ipc.cli.run(alloc)) |exit_code| {
        std.process.exit(exit_code);
    }

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) {
        var state = try lmux.AppState.init(alloc);
        defer state.deinit();

        var handler = HeadlessHandler{ .state = &state };
        var server = lmux.ipc.server.Server.init(
            alloc,
            state.socketPath().?,
            .{
                .ctx = &handler,
                .handleLine = HeadlessHandler.handleLine,
            },
        );
        try server.serve();
        return;
    }

    try lmux.launch.run(alloc, args[1..]);
}

test {
    _ = lmux;
}
