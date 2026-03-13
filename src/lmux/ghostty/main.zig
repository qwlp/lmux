const std = @import("std");

const GhosttyTab = @import("../../apprt/gtk/class/tab.zig").Tab;
const GhosttySurface = @import("../../apprt/gtk/class/surface.zig").Surface;
const GhosttySplitTree = @import("../../apprt/gtk/class/split_tree.zig").SplitTree;
const ghostty_input = @import("../../input.zig");

const lmux_keys = @import("../keys.zig");

pub const TabRuntime = struct {
    widget: *GhosttyTab,
};

pub const PaneRuntime = struct {
    surface: *GhosttySurface,
};

pub const CreateOptions = struct {
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub fn newTab(
    alloc: std.mem.Allocator,
    options: CreateOptions,
) !TabRuntime {
    return .{
        .widget = GhosttyTab.new(null, .{
            .working_directory = try optionalDupZ(alloc, options.cwd),
            .title = try optionalDupZ(alloc, options.title),
        }),
    };
}

pub fn activePane(tab: *GhosttyTab) ?PaneRuntime {
    const surface = tab.getActiveSurface() orelse return null;
    return .{ .surface = surface };
}

pub fn splitPane(
    alloc: std.mem.Allocator,
    tab: *GhosttyTab,
    direction_name: []const u8,
    parent: *GhosttySurface,
    options: CreateOptions,
) !PaneRuntime {
    const direction = parseDirection(direction_name) orelse return error.InvalidDirection;
    const tree: *GhosttySplitTree = tab.getSplitTree();
    try tree.newSplit(direction, parent, .{
        .working_directory = try optionalDupZ(alloc, options.cwd),
        .title = try optionalDupZ(alloc, options.title),
    });
    const surface = tree.getActiveSurface() orelse return error.SurfaceUnavailable;
    return .{ .surface = surface };
}

pub fn focusPane(surface: *GhosttySurface) void {
    surface.grabFocus();
}

pub fn sendText(
    alloc: std.mem.Allocator,
    surface: *GhosttySurface,
    text: []const u8,
) !void {
    const core_surface = surface.core() orelse return error.SurfaceUnavailable;
    const duped = try alloc.dupe(u8, text);
    defer alloc.free(duped);
    try core_surface.textCallback(duped);
}

pub fn sendKeys(
    alloc: std.mem.Allocator,
    surface: *GhosttySurface,
    strokes: []const lmux_keys.Stroke,
) !void {
    const core_surface = surface.core() orelse return error.SurfaceUnavailable;
    for (strokes) |stroke| {
        if (shouldSendAsText(stroke)) {
            try sendText(alloc, surface, stroke.key);
            continue;
        }

        const utf8 = try utf8ForStroke(alloc, stroke);
        defer if (utf8) |v| alloc.free(v);

        _ = try core_surface.keyCallback(.{
            .action = switch (stroke.action) {
                .press => .press,
                .repeat => .repeat,
                .release => .release,
            },
            .key = try parseKey(stroke.key),
            .mods = .{
                .ctrl = stroke.mods.ctrl,
                .alt = stroke.mods.alt,
                .shift = stroke.mods.shift,
                .super = stroke.mods.super,
            },
            .utf8 = if (utf8) |v| v else "",
            .unshifted_codepoint = unshiftedCodepoint(stroke.key),
        });
    }
}

fn shouldSendAsText(stroke: lmux_keys.Stroke) bool {
    return !stroke.mods.ctrl and
        !stroke.mods.alt and
        !stroke.mods.super and
        stroke.action == .press and
        stroke.key.len > 0 and
        parseKey(stroke.key) == error.UnknownKey;
}

fn utf8ForStroke(
    alloc: std.mem.Allocator,
    stroke: lmux_keys.Stroke,
) !?[]u8 {
    if (stroke.key.len != 1) return null;
    if (stroke.mods.ctrl or stroke.mods.alt or stroke.mods.super) return null;
    return try alloc.dupe(u8, stroke.key);
}

fn unshiftedCodepoint(key: []const u8) u21 {
    if (key.len != 1) return 0;
    return std.ascii.toLower(key[0]);
}

fn parseDirection(name: []const u8) ?GhosttySurface.Tree.Split.Direction {
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "up")) return .up;
    if (std.mem.eql(u8, name, "down")) return .down;
    return null;
}

fn parseKey(name: []const u8) !ghostty_input.Key {
    if (name.len == 1) {
        const ch = std.ascii.toLower(name[0]);
        return switch (ch) {
            'a'...'z' => @enumFromInt(@intFromEnum(ghostty_input.Key.key_a) + (ch - 'a')),
            '0'...'9' => @enumFromInt(@intFromEnum(ghostty_input.Key.digit_0) + (ch - '0')),
            '`' => .backquote,
            '\\' => .backslash,
            '[' => .bracket_left,
            ']' => .bracket_right,
            ',' => .comma,
            '=' => .equal,
            '-' => .minus,
            '.' => .period,
            '\'' => .quote,
            ';' => .semicolon,
            '/' => .slash,
            ' ' => .space,
            else => error.UnknownKey,
        };
    }

    if (std.ascii.eqlIgnoreCase(name, "enter")) return .enter;
    if (std.ascii.eqlIgnoreCase(name, "tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(name, "space")) return .space;
    if (std.ascii.eqlIgnoreCase(name, "backspace")) return .backspace;
    if (std.ascii.eqlIgnoreCase(name, "delete")) return .delete;
    if (std.ascii.eqlIgnoreCase(name, "insert")) return .insert;
    if (std.ascii.eqlIgnoreCase(name, "escape") or std.ascii.eqlIgnoreCase(name, "esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(name, "left")) return .arrow_left;
    if (std.ascii.eqlIgnoreCase(name, "right")) return .arrow_right;
    if (std.ascii.eqlIgnoreCase(name, "up")) return .arrow_up;
    if (std.ascii.eqlIgnoreCase(name, "down")) return .arrow_down;
    if (std.ascii.eqlIgnoreCase(name, "home")) return .home;
    if (std.ascii.eqlIgnoreCase(name, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(name, "pageup")) return .page_up;
    if (std.ascii.eqlIgnoreCase(name, "pagedown")) return .page_down;
    return error.UnknownKey;
}

fn optionalDupZ(
    alloc: std.mem.Allocator,
    value: ?[]const u8,
) !?[:0]const u8 {
    return if (value) |v| try alloc.dupeZ(u8, v) else null;
}
