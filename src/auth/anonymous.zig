const std = @import("std");

pub fn initialResponseAlloc(allocator: std.mem.Allocator, trace: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(trace.len);
    const out = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(out, trace);
    return out;
}
