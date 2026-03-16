const std = @import("std");

pub const ReadFn = *const fn (ctx: *anyopaque, buffer: []u8) anyerror!usize;
pub const WriteFn = *const fn (ctx: *anyopaque, buffer: []const u8) anyerror!usize;
pub const CloseFn = *const fn (ctx: *anyopaque) anyerror!void;

pub const Transport = struct {
    ctx: *anyopaque,
    read_fn: ReadFn,
    write_fn: WriteFn,
    close_fn: ?CloseFn = null,

    pub fn read(self: *const Transport, buffer: []u8) !usize {
        return self.read_fn(self.ctx, buffer);
    }

    pub fn write(self: *const Transport, buffer: []const u8) !usize {
        return self.write_fn(self.ctx, buffer);
    }

    pub fn writeAll(self: *const Transport, buffer: []const u8) !void {
        var offset: usize = 0;
        while (offset < buffer.len) {
            const written = try self.write(buffer[offset..]);
            if (written == 0) return error.WriteZero;
            offset += written;
        }
    }

    pub fn close(self: *const Transport) !void {
        if (self.close_fn) |close_fn| try close_fn(self.ctx);
    }

    pub fn print(self: *const Transport, comptime fmt: []const u8, args: anytype) !void {
        var stack_buffer: [4096]u8 = undefined;
        const rendered = try std.fmt.bufPrint(&stack_buffer, fmt, args);
        try self.writeAll(rendered);
    }

    pub fn fromNetStream(stream: *std.net.Stream) Transport {
        return .{
            .ctx = stream,
            .read_fn = netRead,
            .write_fn = netWrite,
            .close_fn = netClose,
        };
    }
};

fn netRead(ctx: *anyopaque, buffer: []u8) !usize {
    const stream: *std.net.Stream = @ptrCast(@alignCast(ctx));
    return stream.read(buffer);
}

fn netWrite(ctx: *anyopaque, buffer: []const u8) !usize {
    const stream: *std.net.Stream = @ptrCast(@alignCast(ctx));
    return stream.write(buffer);
}

fn netClose(ctx: *anyopaque) !void {
    const stream: *std.net.Stream = @ptrCast(@alignCast(ctx));
    stream.close();
}
