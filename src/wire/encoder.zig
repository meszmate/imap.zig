const std = @import("std");

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn clear(self: *Encoder) void {
        self.bytes.clearRetainingCapacity();
    }

    pub fn atom(self: *Encoder, value: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, value);
    }

    pub fn sp(self: *Encoder) !void {
        try self.bytes.append(self.allocator, ' ');
    }

    pub fn quoted(self: *Encoder, value: []const u8) !void {
        try self.bytes.append(self.allocator, '"');
        for (value) |byte| {
            switch (byte) {
                '\\', '"' => {
                    try self.bytes.append(self.allocator, '\\');
                    try self.bytes.append(self.allocator, byte);
                },
                else => try self.bytes.append(self.allocator, byte),
            }
        }
        try self.bytes.append(self.allocator, '"');
    }

    pub fn nil(self: *Encoder) !void {
        try self.atom("NIL");
    }

    pub fn listStart(self: *Encoder) !void {
        try self.bytes.append(self.allocator, '(');
    }

    pub fn listEnd(self: *Encoder) !void {
        try self.bytes.append(self.allocator, ')');
    }

    pub fn literalPrefix(self: *Encoder, len: usize) !void {
        try self.bytes.writer(self.allocator).print("{{{d}}}\r\n", .{len});
    }

    pub fn literal(self: *Encoder, value: []const u8) !void {
        try self.literalPrefix(value.len);
        try self.bytes.appendSlice(self.allocator, value);
    }

    pub fn crlf(self: *Encoder) !void {
        try self.bytes.appendSlice(self.allocator, "\r\n");
    }

    pub fn writeAll(self: *Encoder, value: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, value);
    }

    pub fn finish(self: *Encoder) ![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }
};
