const std = @import("std");

const modified_base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,";
const modified_no_pad = std.base64.Base64Encoder.init(modified_base64_alphabet.*, null);
const modified_decoder = std.base64.Base64Decoder.init(modified_base64_alphabet.*, null);

pub fn encodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const width = try std.unicode.utf8ByteSequenceLength(input[i]);
        const cp = try std.unicode.utf8Decode(input[i .. i + width]);
        if (isDirect(cp)) {
            if (cp == '&') {
                try out.appendSlice(allocator, "&-");
            } else {
                try appendCodepoint(allocator, &out, cp);
            }
            i += width;
            continue;
        }

        var j = i;
        while (j < input.len) {
            const next_width = try std.unicode.utf8ByteSequenceLength(input[j]);
            const next_cp = try std.unicode.utf8Decode(input[j .. j + next_width]);
            if (isDirect(next_cp)) break;
            j += next_width;
        }

        const segment = input[i..j];
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, segment);
        defer allocator.free(utf16);

        const be_bytes = try allocator.alloc(u8, utf16.len * 2);
        defer allocator.free(be_bytes);
        for (utf16, 0..) |unit, index| {
            const native = std.mem.littleToNative(u16, unit);
            be_bytes[index * 2] = @intCast(native >> 8);
            be_bytes[index * 2 + 1] = @intCast(native & 0xff);
        }

        try out.append(allocator, '&');
        const encoded_len = modified_no_pad.calcSize(be_bytes.len);
        const start = out.items.len;
        try out.resize(allocator, start + encoded_len + 1);
        _ = modified_no_pad.encode(out.items[start .. start + encoded_len], be_bytes);
        out.items[start + encoded_len] = '-';

        i = j;
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] != '&') {
            try out.append(allocator, input[i]);
            i += 1;
            continue;
        }

        const dash = std.mem.indexOfScalarPos(u8, input, i + 1, '-') orelse return error.InvalidModifiedUtf7;
        if (dash == i + 1) {
            try out.append(allocator, '&');
            i = dash + 1;
            continue;
        }

        const encoded = input[i + 1 .. dash];
        const decoded_len = try modified_decoder.calcSizeForSlice(encoded);
        const tmp = try allocator.alloc(u8, decoded_len);
        defer allocator.free(tmp);
        try modified_decoder.decode(tmp, encoded);
        if (tmp.len % 2 != 0) return error.InvalidModifiedUtf7;

        const utf16 = try allocator.alloc(u16, tmp.len / 2);
        defer allocator.free(utf16);
        for (utf16, 0..) |*unit, index| {
            const high = tmp[index * 2];
            const low = tmp[index * 2 + 1];
            const native: u16 = (@as(u16, high) << 8) | low;
            unit.* = std.mem.nativeToLittle(u16, native);
        }

        const decoded_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, utf16);
        defer allocator.free(decoded_utf8);
        try out.appendSlice(allocator, decoded_utf8);
        i = dash + 1;
    }

    return out.toOwnedSlice(allocator);
}

fn isDirect(cp: u21) bool {
    return cp >= 0x20 and cp <= 0x7e and cp != '&';
}

fn appendCodepoint(allocator: std.mem.Allocator, list: *std.ArrayList(u8), cp: u21) !void {
    var buffer: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buffer);
    try list.appendSlice(allocator, buffer[0..len]);
}
