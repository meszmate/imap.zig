const std = @import("std");
const imap = @import("imap");

const ScriptTransport = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    position: usize = 0,
    output: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator, input: []const u8) ScriptTransport {
        return .{
            .allocator = allocator,
            .input = input,
        };
    }

    fn deinit(self: *ScriptTransport) void {
        self.output.deinit(self.allocator);
    }

    fn transport(self: *ScriptTransport) imap.wire.Transport {
        return .{
            .ctx = self,
            .read_fn = read,
            .write_fn = write,
        };
    }

    fn read(ctx: *anyopaque, buffer: []u8) !usize {
        const self: *ScriptTransport = @ptrCast(@alignCast(ctx));
        if (self.position >= self.input.len) return 0;
        const remaining = self.input.len - self.position;
        const len = @min(buffer.len, remaining);
        @memcpy(buffer[0..len], self.input[self.position .. self.position + len]);
        self.position += len;
        return len;
    }

    fn write(ctx: *anyopaque, buffer: []const u8) !usize {
        const self: *ScriptTransport = @ptrCast(@alignCast(ctx));
        try self.output.appendSlice(self.allocator, buffer);
        return buffer.len;
    }
};

test "server login select search and logout" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    const user = try store.authenticate("user", "pass");
    const inbox = user.getMailbox("INBOX").?;
    _ = try inbox.appendMessage(
        "Subject: Hello\r\nFrom: test@example.com\r\n\r\nbody",
        &.{},
        0,
    );

    var transport = ScriptTransport.init(
        std.testing.allocator,
        "A001 LOGIN \"user\" \"pass\"\r\n" ++
            "A002 SELECT \"INBOX\"\r\n" ++
            "A003 SEARCH ALL\r\n" ++
            "A004 LOGOUT\r\n",
    );
    defer transport.deinit();

    var server = imap.server.Server.init(std.testing.allocator, &store);
    try server.serveTransport(transport.transport());

    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* OK [CAPABILITY IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE]") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A001 OK LOGIN completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* 1 EXISTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* SEARCH 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* BYE logging out") != null);
}

test "server append consumes literal and returns APPENDUID" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    var transport = ScriptTransport.init(
        std.testing.allocator,
        "A001 LOGIN \"user\" \"pass\"\r\n" ++
            "A002 APPEND \"INBOX\" {5}\r\nhello\r\n" ++
            "A003 LOGOUT\r\n",
    );
    defer transport.deinit();

    var server = imap.server.Server.init(std.testing.allocator, &store);
    try server.serveTransport(transport.transport());

    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "+ Ready for literal data") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A002 OK [APPENDUID 1 1] APPEND completed") != null);
}

test "server lsub and idle are supported" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    const user = try store.authenticate("user", "pass");
    const inbox = user.getMailbox("INBOX").?;
    inbox.subscribed = true;

    var transport = ScriptTransport.init(
        std.testing.allocator,
        "A001 LOGIN \"user\" \"pass\"\r\n" ++
            "A002 LSUB \"\" \"*\"\r\n" ++
            "A003 SELECT \"INBOX\"\r\n" ++
            "A004 IDLE\r\n" ++
            "DONE\r\n" ++
            "A005 LOGOUT\r\n",
    );
    defer transport.deinit();

    var server = imap.server.Server.init(std.testing.allocator, &store);
    try server.serveTransport(transport.transport());

    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* LSUB (\\Subscribed) \"/\" \"INBOX\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "+ idling") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A004 OK IDLE completed") != null);
}
