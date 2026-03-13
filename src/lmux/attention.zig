const std = @import("std");
const ids = @import("ids.zig");

pub const Source = enum {
    bell,
    desktop_notification,
    agent,
};

pub const Notification = struct {
    id: ids.UUID,
    timestamp_ms: i64,
    source: Source,
    sticky: bool,
    unread: bool,
    workspace_id: ?[]const u8 = null,
    tab_id: ?[]const u8 = null,
    pane_id: ?[]const u8 = null,
    title: []const u8,
    body: []const u8,
    snippet: []const u8,

    pub fn deinit(self: *Notification, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        alloc.free(self.snippet);
        if (self.workspace_id) |v| alloc.free(v);
        if (self.tab_id) |v| alloc.free(v);
        if (self.pane_id) |v| alloc.free(v);
    }
};
