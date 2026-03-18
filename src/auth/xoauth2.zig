const std = @import("std");

pub fn initialResponseAlloc(allocator: std.mem.Allocator, user: []const u8, access_token: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "user={s}\x01auth=Bearer {s}\x01\x01", .{ user, access_token });
    defer allocator.free(raw);
    const len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, text: []const u8) !struct { user: []u8, access_token: []u8 } {
    const raw = try decodeBase64Alloc(allocator, text);
    defer allocator.free(raw);

    const user = try extractFieldAlloc(allocator, raw, "user=");
    errdefer allocator.free(user);
    const auth_value = try extractFieldAlloc(allocator, raw, "auth=");
    defer allocator.free(auth_value);
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth_value, prefix)) return error.InvalidBearerField;

    return .{
        .user = user,
        .access_token = try allocator.dupe(u8, auth_value[prefix.len..]),
    };
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, len);
    try std.base64.standard.Decoder.decode(out, text);
    return out;
}

fn extractFieldAlloc(allocator: std.mem.Allocator, raw: []const u8, prefix: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, raw, 1);
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, prefix)) {
            return allocator.dupe(u8, part[prefix.len..]);
        }
    }
    return error.MissingField;
}
