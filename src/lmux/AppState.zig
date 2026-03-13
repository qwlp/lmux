const std = @import("std");
const attention = @import("attention.zig");
const ids = @import("ids.zig");
const lmux_config = @import("config.zig");
const metadata = @import("metadata.zig");

pub const AppState = @This();
const UUID = ids.UUID;

pub const AttentionKind = enum {
    none,
    agent,
    bell,
    desktop_notification,
    child_exit,
};

alloc: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
config: lmux_config.Config,
focused_workspace: ?UUID = null,
workspaces: std.AutoArrayHashMapUnmanaged(UUID, WorkspaceState) = .{},
tabs: std.AutoArrayHashMapUnmanaged(UUID, TabState) = .{},
panes: std.AutoArrayHashMapUnmanaged(UUID, PaneState) = .{},
notifications: std.ArrayListUnmanaged(attention.Notification) = .{},

pub const WorkspaceState = struct {
    id: UUID,
    name: ?[]const u8 = null,
    tabs: std.ArrayListUnmanaged(UUID) = .{},
    focused_tab: ?UUID = null,

    fn deinit(self: *WorkspaceState, alloc: std.mem.Allocator) void {
        self.tabs.deinit(alloc);
        if (self.name) |v| alloc.free(v);
    }
};

pub const TabState = struct {
    id: UUID,
    workspace_id: UUID,
    title: ?[]const u8 = null,
    runtime_handle: ?usize = null,
    split_root: ?usize = null,
    metadata_summary: ?[]const u8 = null,
    panes: std.ArrayListUnmanaged(UUID) = .{},
    focused_pane: ?UUID = null,
    unread_count: u32 = 0,
    latest_notification: ?[]const u8 = null,

    fn deinit(self: *TabState, alloc: std.mem.Allocator) void {
        self.panes.deinit(alloc);
        if (self.title) |v| alloc.free(v);
        if (self.metadata_summary) |v| alloc.free(v);
        if (self.latest_notification) |v| alloc.free(v);
    }
};

pub const PaneState = struct {
    id: UUID,
    tab_id: UUID,
    runtime_handle: ?usize = null,
    widget_handle: ?usize = null,
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    root_pid: ?std.posix.pid_t = null,
    last_activity_ms: i64 = 0,
    attention: bool = false,
    attention_kind: AttentionKind = .none,
    metadata_snapshot: metadata.Snapshot = .{},

    fn deinit(self: *PaneState, alloc: std.mem.Allocator) void {
        if (self.cwd) |v| alloc.free(v);
        if (self.title) |v| alloc.free(v);
        self.metadata_snapshot.deinit(alloc);
    }
};

const CreatePaneOptions = struct {
    title: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    command: ?[]const u8 = null,
};

pub const DispatchResult = union(enum) {
    success: []u8,
    failure: Failure,
};

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
};

pub fn init(alloc: std.mem.Allocator) !AppState {
    return .{
        .alloc = alloc,
        .config = try lmux_config.load(alloc),
    };
}

pub fn deinit(self: *AppState) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.workspaces.values()) |*workspace| workspace.deinit(self.alloc);
    for (self.tabs.values()) |*tab| tab.deinit(self.alloc);
    for (self.panes.values()) |*pane| pane.deinit(self.alloc);
    for (self.notifications.items) |*item| item.deinit(self.alloc);

    self.notifications.deinit(self.alloc);
    self.workspaces.deinit(self.alloc);
    self.tabs.deinit(self.alloc);
    self.panes.deinit(self.alloc);
    self.config.deinit(self.alloc);
}

pub fn socketPath(self: *const AppState) ?[:0]const u8 {
    return self.config.socket_path;
}

pub fn dispatch(
    self: *AppState,
    alloc: std.mem.Allocator,
    method: []const u8,
    params: std.json.Value,
) !DispatchResult {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (std.mem.eql(u8, method, "workspace.create")) {
        const workspace_id = try self.createWorkspaceLocked(paramString(params, "name"));
        return .{ .success = try std.fmt.allocPrint(
            alloc,
            "{{\"workspace_id\":{f}}}",
            .{std.json.fmt(ids.slice(&workspace_id), .{})},
        ) };
    }
    if (std.mem.eql(u8, method, "workspace.list")) {
        return .{ .success = try self.renderWorkspacesLocked(alloc) };
    }
    if (std.mem.eql(u8, method, "workspace.focus")) {
        const workspace_id_text = paramString(params, "workspace_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "workspace_id is required" },
        };
        const workspace_id = ids.parse(workspace_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "workspace_id must be a UUID" },
        };
        self.focusWorkspaceLocked(workspace_id) catch return .{
            .failure = .{ .code = "not_found", .message = "workspace_id not found" },
        };
        return .{ .success = try alloc.dupe(u8, "{\"focused\":true}") };
    }
    if (std.mem.eql(u8, method, "tab.create")) {
        const workspace_id = if (paramString(params, "workspace_id")) |value|
            ids.parse(value) catch return .{ .failure = .{ .code = "invalid_params", .message = "workspace_id must be a UUID" } }
        else
            null;
        const result = self.createTabLocked(workspace_id, paneOptions(params)) catch |err| switch (err) {
            error.TargetNotFound => return .{ .failure = .{ .code = "not_found", .message = "workspace_id not found" } },
            else => return err,
        };
        return .{ .success = try std.fmt.allocPrint(
            alloc,
            "{{\"workspace_id\":{f},\"tab_id\":{f},\"pane_id\":{f}}}",
            .{
                std.json.fmt(ids.slice(&result.workspace_id), .{}),
                std.json.fmt(ids.slice(&result.tab_id), .{}),
                std.json.fmt(ids.slice(&result.pane_id), .{}),
            },
        ) };
    }
    if (std.mem.eql(u8, method, "tab.focus")) {
        const tab_id_text = paramString(params, "tab_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "tab_id is required" },
        };
        const tab_id = ids.parse(tab_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "tab_id must be a UUID" },
        };
        self.focusTabLocked(tab_id) catch return .{
            .failure = .{ .code = "not_found", .message = "tab_id not found" },
        };
        return .{ .success = try alloc.dupe(u8, "{\"focused\":true}") };
    }
    if (std.mem.eql(u8, method, "pane.split")) {
        const pane_id_text = paramString(params, "pane_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id is required" },
        };
        const direction = paramString(params, "direction") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "direction is required" },
        };
        const pane_id = ids.parse(pane_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id must be a UUID" },
        };
        const new_pane = self.splitPaneLocked(pane_id, direction, paneOptions(params)) catch |err| switch (err) {
            error.InvalidDirection => return .{ .failure = .{ .code = "invalid_params", .message = "direction must be one of left/right/up/down" } },
            error.TargetNotFound => return .{ .failure = .{ .code = "not_found", .message = "pane_id not found" } },
            else => return err,
        };
        return .{ .success = try std.fmt.allocPrint(
            alloc,
            "{{\"pane_id\":{f}}}",
            .{std.json.fmt(ids.slice(&new_pane), .{})},
        ) };
    }
    if (std.mem.eql(u8, method, "pane.focus")) {
        const pane_id_text = paramString(params, "pane_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id is required" },
        };
        const pane_id = ids.parse(pane_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id must be a UUID" },
        };
        self.focusPaneLocked(pane_id) catch return .{
            .failure = .{ .code = "not_found", .message = "pane_id not found" },
        };
        return .{ .success = try alloc.dupe(u8, "{\"focused\":true}") };
    }
    if (std.mem.eql(u8, method, "pane.send_text")) {
        const pane_id_text = paramString(params, "pane_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id is required" },
        };
        const pane_id = ids.parse(pane_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id must be a UUID" },
        };
        _ = paramString(params, "text") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "text is required" },
        };
        if (!self.panes.contains(pane_id)) {
            return .{ .failure = .{ .code = "not_found", .message = "pane_id not found" } };
        }
        return .{ .success = try alloc.dupe(u8, "{\"delivered\":true}") };
    }
    if (std.mem.eql(u8, method, "pane.send_keys")) {
        const pane_id_text = paramString(params, "pane_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id is required" },
        };
        const pane_id = ids.parse(pane_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "pane_id must be a UUID" },
        };
        if (!hasParam(params, "keys")) return .{
            .failure = .{ .code = "invalid_params", .message = "keys is required" },
        };
        if (!self.panes.contains(pane_id)) {
            return .{ .failure = .{ .code = "not_found", .message = "pane_id not found" } };
        }
        return .{ .success = try alloc.dupe(u8, "{\"delivered\":true}") };
    }
    if (std.mem.eql(u8, method, "pane.notify")) {
        const title = paramString(params, "title") orelse "";
        const body = paramString(params, "body") orelse "";
        const sticky = paramBool(params, "sticky") orelse true;
        const source = parseNotificationSource(paramString(params, "source"));
        const pane_id = if (paramString(params, "pane_id")) |value|
            ids.parse(value) catch return .{ .failure = .{ .code = "invalid_params", .message = "pane_id must be a UUID" } }
        else
            self.focusedPaneLocked() orelse return .{ .failure = .{ .code = "no_target", .message = "no pane_id provided and no focused pane exists" } };
        const notification = self.notifyPaneLocked(pane_id, source, title, body, sticky) catch return .{
            .failure = .{ .code = "not_found", .message = "pane_id not found" },
        };
        return .{ .success = try std.fmt.allocPrint(
            alloc,
            "{{\"notification_id\":{f}}}",
            .{std.json.fmt(ids.slice(&notification), .{})},
        ) };
    }
    if (std.mem.eql(u8, method, "notification.list")) {
        return .{ .success = try self.renderNotificationsLocked(alloc) };
    }
    if (std.mem.eql(u8, method, "notification.mark_read")) {
        const notification_id_text = paramString(params, "notification_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "notification_id is required" },
        };
        const notification_id = ids.parse(notification_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "notification_id must be a UUID" },
        };
        if (!self.markNotificationReadLocked(notification_id)) {
            return .{ .failure = .{ .code = "not_found", .message = "notification_id not found" } };
        }
        return .{ .success = try alloc.dupe(u8, "{\"updated\":true}") };
    }
    if (std.mem.eql(u8, method, "notification.activate")) {
        const notification_id_text = paramString(params, "notification_id") orelse return .{
            .failure = .{ .code = "invalid_params", .message = "notification_id is required" },
        };
        const notification_id = ids.parse(notification_id_text) catch return .{
            .failure = .{ .code = "invalid_params", .message = "notification_id must be a UUID" },
        };
        const pane_id = self.activateNotificationLocked(notification_id) orelse return .{
            .failure = .{ .code = "not_found", .message = "notification_id not found" },
        };
        return .{ .success = try std.fmt.allocPrint(
            alloc,
            "{{\"pane_id\":{f}}}",
            .{std.json.fmt(ids.slice(&pane_id), .{})},
        ) };
    }
    if (std.mem.eql(u8, method, "notification.jump_latest")) {
        const pane_id = self.jumpLatestNotificationLocked() orelse return .{
            .failure = .{ .code = "not_found", .message = "no unread notifications" },
        };
        return .{ .success = try std.fmt.allocPrint(
            alloc,
            "{{\"pane_id\":{f}}}",
            .{std.json.fmt(ids.slice(&pane_id), .{})},
        ) };
    }
    if (std.mem.eql(u8, method, "app.status")) {
        return .{ .success = try self.renderStatusLocked(alloc) };
    }

    return .{ .failure = .{ .code = "unsupported_method", .message = "method is not supported" } };
}

fn createWorkspaceLocked(self: *AppState, name: ?[]const u8) !UUID {
    const workspace_id = ids.new();
    try self.workspaces.put(self.alloc, workspace_id, .{
        .id = workspace_id,
        .name = if (name) |v| try self.alloc.dupe(u8, v) else null,
    });
    self.focused_workspace = workspace_id;
    return workspace_id;
}

fn createTabLocked(
    self: *AppState,
    requested_workspace: ?UUID,
    options: CreatePaneOptions,
) !struct { workspace_id: UUID, tab_id: UUID, pane_id: UUID } {
    const workspace_id = requested_workspace orelse self.focused_workspace orelse try self.createWorkspaceLocked(null);
    const workspace = self.workspaces.getPtr(workspace_id) orelse return error.TargetNotFound;

    const tab_id = ids.new();
    const pane_id = ids.new();

    var tab_state = TabState{
        .id = tab_id,
        .workspace_id = workspace_id,
        .title = if (options.title) |v| try self.alloc.dupe(u8, v) else null,
        .focused_pane = pane_id,
    };
    try tab_state.panes.append(self.alloc, pane_id);
    try self.tabs.put(self.alloc, tab_id, tab_state);
    try self.panes.put(self.alloc, pane_id, .{
        .id = pane_id,
        .tab_id = tab_id,
        .cwd = if (options.cwd) |v| try self.alloc.dupe(u8, v) else null,
        .title = if (options.title) |v| try self.alloc.dupe(u8, v) else null,
        .last_activity_ms = std.time.milliTimestamp(),
    });
    try workspace.tabs.append(self.alloc, tab_id);
    workspace.focused_tab = tab_id;
    self.focused_workspace = workspace_id;

    return .{
        .workspace_id = workspace_id,
        .tab_id = tab_id,
        .pane_id = pane_id,
    };
}

fn focusWorkspaceLocked(self: *AppState, workspace_id: UUID) !void {
    const workspace = self.workspaces.getPtr(workspace_id) orelse return error.TargetNotFound;
    self.focused_workspace = workspace.id;
}

fn focusTabLocked(self: *AppState, tab_id: UUID) !void {
    const tab = self.tabs.getPtr(tab_id) orelse return error.TargetNotFound;
    const workspace = self.workspaces.getPtr(tab.workspace_id) orelse return error.TargetNotFound;
    workspace.focused_tab = tab_id;
    self.focused_workspace = tab.workspace_id;
}

fn splitPaneLocked(
    self: *AppState,
    pane_id: UUID,
    direction: []const u8,
    options: CreatePaneOptions,
) !UUID {
    if (!isValidDirection(direction)) return error.InvalidDirection;

    const current_pane = self.panes.getPtr(pane_id) orelse return error.TargetNotFound;
    const tab = self.tabs.getPtr(current_pane.tab_id) orelse return error.TargetNotFound;

    const new_pane_id = ids.new();
    try self.panes.put(self.alloc, new_pane_id, .{
        .id = new_pane_id,
        .tab_id = current_pane.tab_id,
        .cwd = if (options.cwd) |v|
            try self.alloc.dupe(u8, v)
        else if (current_pane.cwd) |cwd|
            try self.alloc.dupe(u8, cwd)
        else
            null,
        .title = if (options.title) |v| try self.alloc.dupe(u8, v) else null,
        .last_activity_ms = std.time.milliTimestamp(),
    });
    try tab.panes.append(self.alloc, new_pane_id);
    tab.focused_pane = new_pane_id;
    return new_pane_id;
}

fn focusPaneLocked(self: *AppState, pane_id: UUID) !void {
    const pane = self.panes.getPtr(pane_id) orelse return error.TargetNotFound;
    const tab = self.tabs.getPtr(pane.tab_id) orelse return error.TargetNotFound;
    const workspace = self.workspaces.getPtr(tab.workspace_id) orelse return error.TargetNotFound;

    tab.focused_pane = pane_id;
    workspace.focused_tab = tab.id;
    self.focused_workspace = workspace.id;
    self.clearPaneAttentionLocked(tab.id, pane_id);
}

fn focusedPaneLocked(self: *AppState) ?UUID {
    const workspace_id = self.focused_workspace orelse return null;
    const workspace = self.workspaces.getPtr(workspace_id) orelse return null;
    const tab_id = workspace.focused_tab orelse return null;
    const tab = self.tabs.getPtr(tab_id) orelse return null;
    return tab.focused_pane;
}

fn notifyPaneLocked(
    self: *AppState,
    pane_id: UUID,
    source: attention.Source,
    title: []const u8,
    body: []const u8,
    sticky: bool,
) !UUID {
    const pane = self.panes.getPtr(pane_id) orelse return error.TargetNotFound;
    const tab = self.tabs.getPtr(pane.tab_id) orelse return error.TargetNotFound;
    const notification_id = ids.new();

    const snippet_src = if (body.len > 0) body else title;
    const snippet = snippet_src[0..@min(snippet_src.len, 96)];

    try self.notifications.insert(self.alloc, 0, .{
        .id = notification_id,
        .timestamp_ms = std.time.milliTimestamp(),
        .source = source,
        .sticky = sticky,
        .unread = true,
        .workspace_id = try self.alloc.dupe(u8, ids.slice(&tab.workspace_id)),
        .tab_id = try self.alloc.dupe(u8, ids.slice(&tab.id)),
        .pane_id = try self.alloc.dupe(u8, ids.slice(&pane.id)),
        .title = try self.alloc.dupe(u8, title),
        .body = try self.alloc.dupe(u8, body),
        .snippet = try self.alloc.dupe(u8, snippet),
    });

    tab.unread_count += 1;
    if (tab.latest_notification) |existing| self.alloc.free(existing);
    tab.latest_notification = try self.alloc.dupe(u8, snippet);
    pane.attention = true;
    pane.attention_kind = switch (source) {
        .agent => .agent,
        .bell => .bell,
        .desktop_notification => .desktop_notification,
    };

    return notification_id;
}

fn clearPaneAttentionLocked(self: *AppState, tab_id: UUID, pane_id: UUID) void {
    const pane = self.panes.getPtr(pane_id) orelse return;
    const tab = self.tabs.getPtr(tab_id) orelse return;

    pane.attention = false;
    pane.attention_kind = .none;

    for (self.notifications.items) |*item| {
        const target_pane_id = item.pane_id orelse continue;
        if (!std.mem.eql(u8, target_pane_id, ids.slice(&pane.id))) continue;
        item.unread = false;
    }
    self.recomputeUnreadCountLocked(tab);
}

fn markNotificationReadLocked(self: *AppState, notification_id: UUID) bool {
    for (self.notifications.items) |*item| {
        if (!std.mem.eql(u8, ids.slice(&item.id), ids.slice(&notification_id))) continue;
        item.unread = false;
        if (item.tab_id) |tab_id_text| {
            const tab_id = ids.parse(tab_id_text) catch return true;
            if (self.tabs.getPtr(tab_id)) |tab| self.recomputeUnreadCountLocked(tab);
        }
        return true;
    }
    return false;
}

fn activateNotificationLocked(self: *AppState, notification_id: UUID) ?UUID {
    for (self.notifications.items) |*item| {
        if (!std.mem.eql(u8, ids.slice(&item.id), ids.slice(&notification_id))) continue;
        item.unread = false;
        const pane_id_text = item.pane_id orelse return null;
        const pane_id = ids.parse(pane_id_text) catch return null;
        self.focusPaneLocked(pane_id) catch return null;
        return pane_id;
    }
    return null;
}

fn renderWorkspacesLocked(self: *AppState, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    var writer = out.writer(alloc);

    try writer.writeAll("{\"workspaces\":[");
    var index: usize = 0;
    var it = self.workspaces.iterator();
    while (it.next()) |entry| {
        if (index > 0) try writer.writeByte(',');
        const workspace = entry.value_ptr;
        try writer.print(
            "{{\"workspace_id\":{f},\"name\":",
            .{
                std.json.fmt(ids.slice(&workspace.id), .{}),
            },
        );
        try writeNullableJsonString(&writer, workspace.name);
        try writer.print(",\"focused\":{},\"tab_ids\":[", .{
            if (self.focused_workspace) |focused| std.mem.eql(u8, ids.slice(&focused), ids.slice(&workspace.id)) else false,
        });
        for (workspace.tabs.items, 0..) |tab_id, tab_index| {
            if (tab_index > 0) try writer.writeByte(',');
            try writer.print("{f}", .{std.json.fmt(ids.slice(&tab_id), .{})});
        }
        try writer.writeAll("]}");
        index += 1;
    }
    try writer.writeAll("]}");
    return try out.toOwnedSlice(alloc);
}

fn renderStatusLocked(self: *AppState, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    var writer = out.writer(alloc);

    try writer.writeAll("{\"focused_workspace\":");
    if (self.focused_workspace) |workspace_id| {
        try writer.print("{f}", .{std.json.fmt(ids.slice(&workspace_id), .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"workspaces\":[");

    var workspace_it = self.workspaces.iterator();
    var workspace_index: usize = 0;
    while (workspace_it.next()) |workspace_entry| {
        if (workspace_index > 0) try writer.writeByte(',');
        const workspace = workspace_entry.value_ptr;
        try writer.print(
            "{{\"workspace_id\":{f},\"name\":",
            .{std.json.fmt(ids.slice(&workspace.id), .{})},
        );
        try writeNullableJsonString(&writer, workspace.name);
        try writer.writeAll(",\"tabs\":[");
        for (workspace.tabs.items, 0..) |tab_id, tab_index| {
            if (tab_index > 0) try writer.writeByte(',');
            const tab = self.tabs.getPtr(tab_id) orelse continue;
            try writer.print(
                "{{\"tab_id\":{f},\"title\":",
                .{std.json.fmt(ids.slice(&tab.id), .{})},
            );
            try writeNullableJsonString(&writer, tab.title);
            try writer.print(
                ",\"unread_count\":{d},\"focused\":{},\"metadata_summary\":",
                .{
                    tab.unread_count,
                    workspace.focused_tab != null and std.mem.eql(u8, ids.slice(&workspace.focused_tab.?), ids.slice(&tab.id)),
                },
            );
            try writeNullableJsonString(&writer, tab.metadata_summary);
            try writer.writeAll(",\"pane_ids\":[");
            for (tab.panes.items, 0..) |pane_id, pane_index| {
                if (pane_index > 0) try writer.writeByte(',');
                try writer.print("{f}", .{std.json.fmt(ids.slice(&pane_id), .{})});
            }
            try writer.writeAll("]}");
        }
        try writer.writeAll("]}");
        workspace_index += 1;
    }

    try writer.writeAll("],\"panes\":[");
    var pane_it = self.panes.iterator();
    var pane_index: usize = 0;
    while (pane_it.next()) |pane_entry| {
        if (pane_index > 0) try writer.writeByte(',');
        const pane = pane_entry.value_ptr;
        const tab = self.tabs.getPtr(pane.tab_id) orelse continue;
        try writer.print(
            "{{\"pane_id\":{f},\"tab_id\":{f},\"cwd\":",
            .{
                std.json.fmt(ids.slice(&pane.id), .{}),
                std.json.fmt(ids.slice(&tab.id), .{}),
            },
        );
        try writeNullableJsonString(&writer, pane.cwd);
        try writer.writeAll(",\"title\":");
        try writeNullableJsonString(&writer, pane.title);
        try writer.print(
            ",\"attention\":{},\"attention_kind\":{f},\"root_pid\":",
            .{
                pane.attention,
                std.json.fmt(@tagName(pane.attention_kind), .{}),
            },
        );
        if (pane.root_pid) |pid| {
            try writer.print("{d}", .{pid});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeByte('}');
        pane_index += 1;
    }
    try writer.writeAll("],\"notifications\":");
    const notifications_json = try self.renderNotificationsLocked(alloc);
    defer alloc.free(notifications_json);
    try writer.writeAll(notifications_json);
    try writer.writeByte('}');
    return try out.toOwnedSlice(alloc);
}

fn renderNotificationsLocked(self: *AppState, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(alloc);
    var writer = out.writer(alloc);

    try writer.writeAll("{\"notifications\":[");
    for (self.notifications.items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"notification_id\":{f},\"unread\":{},\"sticky\":{},\"source\":{f},\"timestamp_ms\":{d},\"workspace_id\":",
            .{
                std.json.fmt(ids.slice(&item.id), .{}),
                item.unread,
                item.sticky,
                std.json.fmt(@tagName(item.source), .{}),
                item.timestamp_ms,
            },
        );
        try writeNullableJsonString(&writer, item.workspace_id);
        try writer.writeAll(",\"tab_id\":");
        try writeNullableJsonString(&writer, item.tab_id);
        try writer.writeAll(",\"pane_id\":");
        try writeNullableJsonString(&writer, item.pane_id);
        try writer.print(
            ",\"title\":{f},\"body\":{f},\"snippet\":{f}}}",
            .{
                std.json.fmt(item.title, .{}),
                std.json.fmt(item.body, .{}),
                std.json.fmt(item.snippet, .{}),
            },
        );
    }
    try writer.writeAll("]}");
    return try out.toOwnedSlice(alloc);
}

fn paramString(params: std.json.Value, key: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const value = params.object.get(key) orelse return null;
    return switch (value) {
        .string => value.string,
        else => null,
    };
}

fn paramBool(params: std.json.Value, key: []const u8) ?bool {
    if (params != .object) return null;
    const value = params.object.get(key) orelse return null;
    return switch (value) {
        .bool => value.bool,
        else => null,
    };
}

fn hasParam(params: std.json.Value, key: []const u8) bool {
    if (params != .object) return false;
    return params.object.get(key) != null;
}

fn paneOptions(params: std.json.Value) CreatePaneOptions {
    return .{
        .title = paramString(params, "title"),
        .cwd = paramString(params, "cwd"),
        .command = paramString(params, "command"),
    };
}

fn parseNotificationSource(source: ?[]const u8) attention.Source {
    const value = source orelse return .agent;
    if (std.mem.eql(u8, value, "bell")) return .bell;
    if (std.mem.eql(u8, value, "desktop_notification")) return .desktop_notification;
    return .agent;
}

fn jumpLatestNotificationLocked(self: *AppState) ?UUID {
    for (self.notifications.items) |*item| {
        if (!item.unread) continue;
        item.unread = false;
        const pane_id_text = item.pane_id orelse continue;
        const pane_id = ids.parse(pane_id_text) catch continue;
        self.focusPaneLocked(pane_id) catch continue;
        return pane_id;
    }
    return null;
}

fn recomputeUnreadCountLocked(self: *AppState, tab: *TabState) void {
    tab.unread_count = 0;
    for (self.notifications.items) |item| {
        if (!item.unread) continue;
        const target_tab_id = item.tab_id orelse continue;
        if (!std.mem.eql(u8, target_tab_id, ids.slice(&tab.id))) continue;
        tab.unread_count += 1;
    }
}

fn isValidDirection(direction: []const u8) bool {
    return std.mem.eql(u8, direction, "left") or
        std.mem.eql(u8, direction, "right") or
        std.mem.eql(u8, direction, "up") or
        std.mem.eql(u8, direction, "down");
}

fn writeNullableJsonString(
    writer: anytype,
    value: ?[]const u8,
) !void {
    if (value) |text| {
        try writer.print("{f}", .{std.json.fmt(text, .{})});
        return;
    }
    try writer.writeAll("null");
}

test "dispatch creates workspace and tab" {
    const alloc = std.testing.allocator;
    var state = try AppState.init(alloc);
    defer state.deinit();

    const workspace_result = try state.dispatch(alloc, "workspace.create", .{ .object = .init(alloc) });
    defer switch (workspace_result) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };
    try std.testing.expectEqual(.success, workspace_result);

    var params = std.json.ObjectMap.init(alloc);
    defer params.deinit();
    const tab_result = try state.dispatch(alloc, "tab.create", .{ .object = params });
    defer switch (tab_result) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };
    try std.testing.expectEqual(.success, tab_result);
}

test "notification activate focuses pane and clears unread" {
    const alloc = std.testing.allocator;
    var state = try AppState.init(alloc);
    defer state.deinit();

    var create_params = std.json.ObjectMap.init(alloc);
    defer create_params.deinit();
    const initial = try state.dispatch(alloc, "tab.create", .{ .object = create_params });
    defer switch (initial) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };

    const first_payload = switch (initial) {
        .success => |payload| payload,
        .failure => unreachable,
    };
    var parsed_first = try std.json.parseFromSlice(std.json.Value, alloc, first_payload, .{});
    defer parsed_first.deinit();
    const first_pane_id = try ids.parse(parsed_first.value.object.get("pane_id").?.string);

    var split_params = std.json.ObjectMap.init(alloc);
    defer split_params.deinit();
    try split_params.put("pane_id", .{ .string = ids.slice(&first_pane_id) });
    try split_params.put("direction", .{ .string = "right" });
    const split = try state.dispatch(alloc, "pane.split", .{ .object = split_params });
    defer switch (split) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };

    const split_payload = switch (split) {
        .success => |payload| payload,
        .failure => unreachable,
    };
    var parsed_split = try std.json.parseFromSlice(std.json.Value, alloc, split_payload, .{});
    defer parsed_split.deinit();
    const second_pane_id = try ids.parse(parsed_split.value.object.get("pane_id").?.string);

    var notify_params = std.json.ObjectMap.init(alloc);
    defer notify_params.deinit();
    try notify_params.put("pane_id", .{ .string = ids.slice(&first_pane_id) });
    try notify_params.put("title", .{ .string = "Agent" });
    try notify_params.put("body", .{ .string = "Needs attention" });
    const notified = try state.dispatch(alloc, "pane.notify", .{ .object = notify_params });
    defer switch (notified) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };

    const notify_payload = switch (notified) {
        .success => |payload| payload,
        .failure => unreachable,
    };
    var parsed_notify = try std.json.parseFromSlice(std.json.Value, alloc, notify_payload, .{});
    defer parsed_notify.deinit();
    const notification_id = try ids.parse(parsed_notify.value.object.get("notification_id").?.string);

    try std.testing.expect(state.tabs.values()[0].unread_count > 0);
    try std.testing.expectEqual(second_pane_id, state.tabs.values()[0].focused_pane.?);

    var activate_params = std.json.ObjectMap.init(alloc);
    defer activate_params.deinit();
    try activate_params.put("notification_id", .{ .string = ids.slice(&notification_id) });
    const activated = try state.dispatch(alloc, "notification.activate", .{ .object = activate_params });
    defer switch (activated) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };

    try std.testing.expectEqual(first_pane_id, state.tabs.values()[0].focused_pane.?);
    try std.testing.expectEqual(@as(u32, 0), state.tabs.values()[0].unread_count);
    try std.testing.expect(!state.panes.getPtr(first_pane_id).?.attention);
    try std.testing.expect(!state.notifications.items[0].unread);
}

test "jump latest unread picks newest notification" {
    const alloc = std.testing.allocator;
    var state = try AppState.init(alloc);
    defer state.deinit();

    var create_params = std.json.ObjectMap.init(alloc);
    defer create_params.deinit();
    const created = try state.dispatch(alloc, "tab.create", .{ .object = create_params });
    defer switch (created) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };

    const created_payload = switch (created) {
        .success => |payload| payload,
        .failure => unreachable,
    };
    var parsed_created = try std.json.parseFromSlice(std.json.Value, alloc, created_payload, .{});
    defer parsed_created.deinit();
    const pane_a = try ids.parse(parsed_created.value.object.get("pane_id").?.string);

    var split_params = std.json.ObjectMap.init(alloc);
    defer split_params.deinit();
    try split_params.put("pane_id", .{ .string = ids.slice(&pane_a) });
    try split_params.put("direction", .{ .string = "down" });
    const split = try state.dispatch(alloc, "pane.split", .{ .object = split_params });
    defer switch (split) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };

    const split_payload = switch (split) {
        .success => |payload| payload,
        .failure => unreachable,
    };
    var parsed_split = try std.json.parseFromSlice(std.json.Value, alloc, split_payload, .{});
    defer parsed_split.deinit();
    const pane_b = try ids.parse(parsed_split.value.object.get("pane_id").?.string);

    var notify_first = std.json.ObjectMap.init(alloc);
    defer notify_first.deinit();
    try notify_first.put("pane_id", .{ .string = ids.slice(&pane_a) });
    try notify_first.put("title", .{ .string = "Old" });
    _ = try state.dispatch(alloc, "pane.notify", .{ .object = notify_first });

    var notify_second = std.json.ObjectMap.init(alloc);
    defer notify_second.deinit();
    try notify_second.put("pane_id", .{ .string = ids.slice(&pane_b) });
    try notify_second.put("title", .{ .string = "New" });
    _ = try state.dispatch(alloc, "pane.notify", .{ .object = notify_second });

    var jump_params = std.json.ObjectMap.init(alloc);
    defer jump_params.deinit();
    const jumped = try state.dispatch(alloc, "notification.jump_latest", .{ .object = jump_params });
    defer switch (jumped) {
        .success => |payload| alloc.free(payload),
        .failure => {},
    };

    try std.testing.expectEqual(pane_b, state.tabs.values()[0].focused_pane.?);
}
