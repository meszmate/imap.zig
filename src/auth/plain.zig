const std = @import("std");

pub fn rawInitialResponseAlloc(allocator: std.mem.Allocator, authzid: []const u8, username: []const u8, password: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}", .{ authzid, username, password });
}

pub fn initialResponseAlloc(allocator: std.mem.Allocator, authzid: []const u8, username: []const u8, password: []const u8) ![]u8 {
    const raw = try rawInitialResponseAlloc(allocator, authzid, username, password);
    defer allocator.free(raw);
    return encodeBase64Alloc(allocator, raw);
}

pub fn decodeResponseAlloc(allocator: std.mem.Allocator, b64: []const u8) !struct { authzid: []u8, username: []u8, password: []u8 } {
    const raw = try decodeBase64Alloc(allocator, b64);
    errdefer allocator.free(raw);
    var parts = std.mem.splitScalar(u8, raw, 0);
    const authzid = try allocator.dupe(u8, parts.next() orelse "");
    errdefer allocator.free(authzid);
    const username = try allocator.dupe(u8, parts.next() orelse "");
    errdefer allocator.free(username);
    const password = try allocator.dupe(u8, parts.next() orelse "");
    allocator.free(raw);
    return .{ .authzid = authzid, .username = username, .password = password };
}

fn encodeBase64Alloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(raw.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, raw);
    return out;
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, len);
    try std.base64.standard.Decoder.decode(out, text);
    return out;
}
