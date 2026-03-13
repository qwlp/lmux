const std = @import("std");
const paths = @import("../paths.zig");

pub const Server = struct {
    pub const Handler = struct {
        ctx: *anyopaque,
        handleLine: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            line: []const u8,
        ) anyerror![]u8,
    };

    alloc: std.mem.Allocator,
    handler: Handler,
    socket_path: [:0]const u8,

    pub fn init(
        alloc: std.mem.Allocator,
        socket_path: [:0]const u8,
        handler: Handler,
    ) Server {
        return .{
            .alloc = alloc,
            .handler = handler,
            .socket_path = socket_path,
        };
    }

    pub fn serve(self: *Server) !void {
        try paths.ensureParentPath(std.mem.sliceTo(self.socket_path, 0));
        std.posix.unlinkZ(self.socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(fd);

        var addr = std.posix.sockaddr.un{
            .family = std.posix.AF.UNIX,
            .path = [_]u8{0} ** 108,
        };
        if (self.socket_path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);
        const len = @as(u32, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + self.socket_path.len + 1));
        try std.posix.bind(fd, @ptrCast(&addr), len);
        try std.posix.listen(fd, 128);

        while (true) {
            const client_fd = try std.posix.accept(fd, null, null, 0);
            self.handleClient(client_fd) catch {};
            std.posix.close(client_fd);
        }
    }

    fn handleClient(self: *Server, client_fd: std.posix.fd_t) !void {
        var reader_buf: [8192]u8 = undefined;
        var message: std.ArrayList(u8) = .{};
        defer message.deinit(self.alloc);

        while (true) {
            const count = try std.posix.read(client_fd, &reader_buf);
            if (count == 0) break;
            try message.appendSlice(self.alloc, reader_buf[0..count]);
            if (std.mem.indexOfScalar(u8, message.items, '\n') != null) break;
            if (message.items.len > 64 * 1024) return error.MessageTooLarge;
        }

        const line = std.mem.trim(u8, message.items, " \t\r\n");
        if (line.len == 0) return;
        const response = try self.handler.handleLine(self.handler.ctx, self.alloc, line);
        defer self.alloc.free(response);
        _ = try std.posix.write(client_fd, response);
    }
};
