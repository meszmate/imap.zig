const std = @import("std");
const imap = @import("imap");

const TestTransport = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    position: usize = 0,
    output: std.ArrayList(u8) = .empty,

    fn create(allocator: std.mem.Allocator, input: []const u8) !*TestTransport {
        const transport = try allocator.create(TestTransport);
        transport.* = .{
            .allocator = allocator,
            .input = input,
        };
        return transport;
    }

    fn destroy(self: *TestTransport) void {
        self.output.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn asTransport(self: *TestTransport) imap.wire.Transport {
        return .{
            .ctx = self,
            .read_fn = read,
            .write_fn = write,
            .close_fn = close,
        };
    }

    fn read(ctx: *anyopaque, buffer: []u8) !usize {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        if (self.position >= self.input.len) return 0;
        const remaining = self.input.len - self.position;
        const len = @min(buffer.len, remaining);
        @memcpy(buffer[0..len], self.input[self.position .. self.position + len]);
        self.position += len;
        return len;
    }

    fn write(ctx: *anyopaque, buffer: []const u8) !usize {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        try self.output.appendSlice(self.allocator, buffer);
        return buffer.len;
    }

    fn close(ctx: *anyopaque) !void {
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.destroy();
    }
};

const DialState = struct {
    calls: usize = 0,
};

fn fakeDial(allocator: std.mem.Allocator, _: []const u8, _: u16) !imap.client.Client {
    const scripted = try TestTransport.create(
        allocator,
        "* OK hi\r\n",
    );
    return imap.client.Client.init(allocator, scripted.asTransport());
}

test "client pool reuses idle connections" {
    var pool = imap.client.Pool.init(std.testing.allocator, .{
        .host = "127.0.0.1",
        .port = 143,
        .max_idle = 1,
        .dial_fn = fakeDial,
    });
    defer pool.deinit();

    const first = try pool.acquire();
    pool.release(first);
    const second = try pool.acquire();
    defer pool.release(second);

    try std.testing.expect(first == second);
}
