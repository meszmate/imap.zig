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

pub fn decodeAlloc(allocator: std.mem.Allocator, text: []const u8) !struct { authzid: []u8, access_token: []u8, host: []u8, port: ?u16 } {
    const raw = try decodeBase64Alloc(allocator, text);
    defer allocator.free(raw);

    const authzid = try parseAuthzidAlloc(allocator, raw);
    errdefer allocator.free(authzid);
    const host = extractFieldAlloc(allocator, raw, "host=") catch try allocator.dupe(u8, "");
    errdefer allocator.free(host);
    const auth_value = try extractFieldAlloc(allocator, raw, "auth=");
    defer allocator.free(auth_value);
    const port_text = extractFieldAlloc(allocator, raw, "port=") catch null;
    defer if (port_text) |value| allocator.free(value);

    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, auth_value, prefix)) return error.InvalidBearerField;

    return .{
        .authzid = authzid,
        .access_token = try allocator.dupe(u8, auth_value[prefix.len..]),
        .host = host,
        .port = if (port_text) |value| try std.fmt.parseInt(u16, value, 10) else null,
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

fn parseAuthzidAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var comma = std.mem.splitScalar(u8, raw, ',');
    _ = comma.next();
    const authzid_part = comma.next() orelse return error.MissingAuthzid;
    if (!std.mem.startsWith(u8, authzid_part, "a=")) return error.MissingAuthzid;
    return allocator.dupe(u8, authzid_part[2..]);
}
