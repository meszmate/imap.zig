const std = @import("std");

pub fn initialResponseAlloc(allocator: std.mem.Allocator, user: []const u8, access_token: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "user={s}\x01auth=Bearer {s}\x01\x01", .{ user, access_token });
    defer allocator.free(raw);
    const len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}
