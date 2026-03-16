const std = @import("std");

pub fn encodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(text.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, text);
    return out;
}

pub fn decodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(text);
    const out = try allocator.alloc(u8, len);
    try std.base64.standard.Decoder.decode(out, text);
    return out;
}

pub fn usernamePrompt() []const u8 {
    return "VXNlcm5hbWU6";
}

pub fn passwordPrompt() []const u8 {
    return "UGFzc3dvcmQ6";
}
