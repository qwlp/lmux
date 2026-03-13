const std = @import("std");

pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

pub const Action = enum {
    press,
    repeat,
    release,
};

pub const Stroke = struct {
    key: []const u8,
    mods: Mods = .{},
    action: Action = .press,
};

pub fn parseCliSpec(spec: []const u8) !Stroke {
    var result: Stroke = .{ .key = "" };
    var parts = std.mem.tokenizeScalar(u8, spec, '+');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        if (asciiEql(part, "ctrl") or asciiEql(part, "control")) {
            result.mods.ctrl = true;
            continue;
        }
        if (asciiEql(part, "alt") or asciiEql(part, "option")) {
            result.mods.alt = true;
            continue;
        }
        if (asciiEql(part, "shift")) {
            result.mods.shift = true;
            continue;
        }
        if (asciiEql(part, "super") or asciiEql(part, "meta") or asciiEql(part, "cmd")) {
            result.mods.super = true;
            continue;
        }
        if (asciiEql(part, "repeat")) {
            result.action = .repeat;
            continue;
        }
        if (asciiEql(part, "release")) {
            result.action = .release;
            continue;
        }
        result.key = part;
    }

    if (result.key.len == 0) return error.InvalidKeySpec;
    return result;
}

pub fn parseJsonValue(
    alloc: std.mem.Allocator,
    value: std.json.Value,
) ![]Stroke {
    switch (value) {
        .string => {
            const parsed = try parseCliSpec(value.string);
            const out = try alloc.alloc(Stroke, 1);
            out[0] = .{
                .key = try alloc.dupe(u8, parsed.key),
                .mods = parsed.mods,
                .action = parsed.action,
            };
            return out;
        },
        .array => {
            const out = try alloc.alloc(Stroke, value.array.items.len);
            errdefer {
                for (out[0..value.array.items.len]) |item| {
                    if (item.key.len > 0) alloc.free(item.key);
                }
                alloc.free(out);
            }
            for (value.array.items, 0..) |item, index| {
                out[index] = try parseJsonStroke(alloc, item);
            }
            return out;
        },
        else => return error.InvalidKeySpec,
    }
}

pub fn deinitOwned(alloc: std.mem.Allocator, strokes: []Stroke) void {
    for (strokes) |stroke| alloc.free(stroke.key);
    alloc.free(strokes);
}

fn parseJsonStroke(
    alloc: std.mem.Allocator,
    value: std.json.Value,
) !Stroke {
    switch (value) {
        .string => {
            const parsed = try parseCliSpec(value.string);
            return .{
                .key = try alloc.dupe(u8, parsed.key),
                .mods = parsed.mods,
                .action = parsed.action,
            };
        },
        .object => {
            const key_value = value.object.get("key") orelse return error.InvalidKeySpec;
            if (key_value != .string) return error.InvalidKeySpec;
            var result: Stroke = .{
                .key = try alloc.dupe(u8, key_value.string),
            };

            if (value.object.get("mods")) |mods_value| {
                switch (mods_value) {
                    .string => try applyMod(&result.mods, mods_value.string),
                    .array => {
                        for (mods_value.array.items) |mod_value| {
                            if (mod_value != .string) return error.InvalidKeySpec;
                            try applyMod(&result.mods, mod_value.string);
                        }
                    },
                    else => return error.InvalidKeySpec,
                }
            }

            if (value.object.get("action")) |action_value| {
                if (action_value != .string) return error.InvalidKeySpec;
                result.action = parseAction(action_value.string) orelse return error.InvalidKeySpec;
            }

            return result;
        },
        else => return error.InvalidKeySpec,
    }
}

fn parseAction(value: []const u8) ?Action {
    if (asciiEql(value, "press")) return .press;
    if (asciiEql(value, "repeat")) return .repeat;
    if (asciiEql(value, "release")) return .release;
    return null;
}

fn applyMod(mods: *Mods, value: []const u8) !void {
    if (asciiEql(value, "ctrl") or asciiEql(value, "control")) {
        mods.ctrl = true;
        return;
    }
    if (asciiEql(value, "alt") or asciiEql(value, "option")) {
        mods.alt = true;
        return;
    }
    if (asciiEql(value, "shift")) {
        mods.shift = true;
        return;
    }
    if (asciiEql(value, "super") or asciiEql(value, "meta") or asciiEql(value, "cmd")) {
        mods.super = true;
        return;
    }
    return error.InvalidKeySpec;
}

fn asciiEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "parse cli key spec" {
    const parsed = try parseCliSpec("ctrl+shift+c");
    try std.testing.expect(parsed.mods.ctrl);
    try std.testing.expect(parsed.mods.shift);
    try std.testing.expectEqualStrings("c", parsed.key);
}

test "parse json key array" {
    const alloc = std.testing.allocator;
    var mods = std.json.Array.init(alloc);
    defer mods.deinit();
    try mods.append(.{ .string = "ctrl" });

    var entry = std.json.ObjectMap.init(alloc);
    defer entry.deinit();
    try entry.put("key", .{ .string = "c" });
    try entry.put("mods", .{ .array = mods });

    var array = std.json.Array.init(alloc);
    defer array.deinit();
    try array.append(.{ .object = entry });

    const parsed = try parseJsonValue(alloc, .{ .array = array });
    defer deinitOwned(alloc, parsed);

    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    try std.testing.expect(parsed[0].mods.ctrl);
    try std.testing.expectEqualStrings("c", parsed[0].key);
}
