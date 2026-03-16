const std = @import("std");
const Transport = @import("transport.zig").Transport;

pub const LineReader = struct {
    allocator: std.mem.Allocator,
    transport: Transport,

    pub fn init(allocator: std.mem.Allocator, transport: Transport) LineReader {
        return .{
            .allocator = allocator,
            .transport = transport,
        };
    }

    pub fn readLineAlloc(self: *LineReader) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.allocator);

        var one: [1]u8 = undefined;
        while (true) {
            const count = try self.transport.read(&one);
            if (count == 0) return error.EndOfStream;
            if (one[0] == '\n') break;
            if (one[0] != '\r') try bytes.append(self.allocator, one[0]);
        }

        return bytes.toOwnedSlice(self.allocator);
    }

    pub fn readExactAlloc(self: *LineReader, len: usize) ![]u8 {
        const bytes = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(bytes);

        var offset: usize = 0;
        while (offset < len) {
            const count = try self.transport.read(bytes[offset..]);
            if (count == 0) return error.EndOfStream;
            offset += count;
        }
        return bytes;
    }

    pub fn readCrlf(self: *LineReader) !void {
        var buffer: [2]u8 = undefined;
        var offset: usize = 0;
        while (offset < 2) {
            const count = try self.transport.read(buffer[offset..]);
            if (count == 0) return error.EndOfStream;
            offset += count;
        }
        if (!std.mem.eql(u8, &buffer, "\r\n")) return error.InvalidLineEnding;
    }
};

pub fn writeQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '\\', '"' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn writeStringOrLiteral(writer: anytype, value: []const u8) !void {
    if (needsLiteral(value)) {
        try writer.print("{{{d}}}\r\n", .{value.len});
        try writer.writeAll(value);
    } else {
        try writeQuoted(writer, value);
    }
}

fn needsLiteral(value: []const u8) bool {
    for (value) |byte| {
        if (byte == '\r' or byte == '\n') return true;
    }
    return false;
}
