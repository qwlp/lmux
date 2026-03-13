const std = @import("std");

pub const UUID = [36:0]u8;

pub fn new() UUID {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    var result: UUID = undefined;
    var i: usize = 0;
    var out: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (out == 8 or out == 13 or out == 18 or out == 23) {
            result[out] = '-';
            out += 1;
        }

        result[out] = hex(bytes[i] >> 4);
        result[out + 1] = hex(bytes[i] & 0x0F);
        out += 2;
    }
    result[36] = 0;
    return result;
}

pub fn parse(value: []const u8) !UUID {
    if (value.len != 36) return error.InvalidUUID;
    var result: UUID = undefined;
    @memcpy(result[0..36], value[0..36]);
    result[36] = 0;
    return result;
}

pub fn slice(value: *const UUID) []const u8 {
    return std.mem.sliceTo(value, 0);
}

fn hex(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + (v - 10);
}

test "uuid parse roundtrip" {
    const id = new();
    const parsed = try parse(slice(&id));
    try std.testing.expectEqualStrings(slice(&id), slice(&parsed));
}
