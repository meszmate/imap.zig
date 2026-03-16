const std = @import("std");

pub fn initialResponseAlloc(allocator: std.mem.Allocator, authzid: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(authzid.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, authzid);
    return out;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, len);
    try std.base64.standard.Decoder.decode(out, text);
    return out;
}
