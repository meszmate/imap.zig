const std = @import("std");

pub fn responseAlloc(allocator: std.mem.Allocator, username: []const u8, password: []const u8, challenge_b64: []const u8) ![]u8 {
    const challenge = try decodeBase64Alloc(allocator, challenge_b64);
    defer allocator.free(challenge);

    var mac: [std.crypto.auth.hmac.HmacMd5.mac_length]u8 = undefined;
    std.crypto.auth.hmac.HmacMd5.create(mac[0..], challenge, password);

    var hex: [std.crypto.auth.hmac.HmacMd5.mac_length * 2]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (mac, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    const raw = try std.fmt.allocPrint(allocator, "{s} {s}", .{ username, hex });
    defer allocator.free(raw);
    return encodeBase64Alloc(allocator, raw);
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
