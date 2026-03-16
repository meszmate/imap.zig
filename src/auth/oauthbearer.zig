const std = @import("std");

pub fn initialResponseAlloc(allocator: std.mem.Allocator, user: []const u8, access_token: []const u8, host: ?[]const u8, port: ?u16) ![]u8 {
    const raw = try std.fmt.allocPrint(
        allocator,
        "n,a={s},\x01host={s}\x01port={d}\x01auth=Bearer {s}\x01\x01",
        .{ user, host orelse "", port orelse 0, access_token },
    );
    defer allocator.free(raw);
    const len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}
