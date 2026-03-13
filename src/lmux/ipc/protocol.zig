const std = @import("std");

pub const ParsedRequest = struct {
    parsed: std.json.Parsed(std.json.Value),
    id: []const u8,
    method: []const u8,
    params: std.json.Value,

    pub fn deinit(self: *ParsedRequest) void {
        self.parsed.deinit();
    }
};

pub fn parseRequest(alloc: std.mem.Allocator, bytes: []const u8) !ParsedRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidRequest;
    const object = parsed.value.object;
    const id_value = object.get("id") orelse return error.InvalidRequest;
    const method_value = object.get("method") orelse return error.InvalidRequest;
    const params_value = object.get("params") orelse std.json.Value{ .null = {} };

    if (id_value != .string or method_value != .string) return error.InvalidRequest;

    return .{
        .parsed = parsed,
        .id = id_value.string,
        .method = method_value.string,
        .params = params_value,
    };
}

pub fn writeSuccess(writer: anytype, id: []const u8, payload: []const u8) !void {
    try writer.print(
        "{{\"id\":{f},\"ok\":true,\"result\":{s}}}\n",
        .{ std.json.fmt(id, .{}), payload },
    );
}

pub fn writeError(writer: anytype, id: ?[]const u8, code: []const u8, message: []const u8) !void {
    if (id) |value| {
        try writer.print(
            "{{\"id\":{f},\"ok\":false,\"error\":{{\"code\":{f},\"message\":{f}}}}}\n",
            .{
                std.json.fmt(value, .{}),
                std.json.fmt(code, .{}),
                std.json.fmt(message, .{}),
            },
        );
        return;
    }

    try writer.print(
        "{{\"id\":null,\"ok\":false,\"error\":{{\"code\":{f},\"message\":{f}}}}}\n",
        .{
            std.json.fmt(code, .{}),
            std.json.fmt(message, .{}),
        },
    );
}
