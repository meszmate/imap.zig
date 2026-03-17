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

    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* OK [CAPABILITY IMAP4rev1 UIDPLUS MOVE NAMESPACE ID UNSELECT IDLE ENABLE AUTH=PLAIN AUTH=LOGIN AUTH=EXTERNAL SORT THREAD=REFERENCES THREAD=ORDEREDSUBJECT ACL QUOTA METADATA STARTTLS COMPRESS=DEFLATE UNAUTHENTICATE REPLACE]") != null);
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

test "server authenticate plain succeeds" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    const plain = try imap.auth.plain.initialResponseAlloc(std.testing.allocator, "", "user", "pass");
    defer std.testing.allocator.free(plain);
    const script = try std.fmt.allocPrint(
        std.testing.allocator,
        "A001 AUTHENTICATE PLAIN\r\n{s}\r\nA002 LOGOUT\r\n",
        .{plain},
    );
    defer std.testing.allocator.free(script);

    var transport = ScriptTransport.init(std.testing.allocator, script);
    defer transport.deinit();

    var server = imap.server.Server.init(std.testing.allocator, &store);
    try server.serveTransport(transport.transport());

    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A001 OK AUTHENTICATE completed") != null);
}

test "server sort thread acl quota metadata" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    const user = try store.authenticate("user", "pass");
    const inbox = user.getMailbox("INBOX").?;
    _ = try inbox.appendMessage("Subject: Zebra\r\nMessage-ID: <z1>\r\n\r\nBody", &.{}, 5);
    _ = try inbox.appendMessage("Subject: alpha\r\nMessage-ID: <a1>\r\nIn-Reply-To: <z1>\r\n\r\nBody", &.{}, 10);

    var transport = ScriptTransport.init(
        std.testing.allocator,
        "A001 LOGIN \"user\" \"pass\"\r\n" ++
            "A002 SELECT \"INBOX\"\r\n" ++
            "A003 SORT (SUBJECT) UTF-8 ALL\r\n" ++
            "A004 THREAD REFERENCES UTF-8 ALL\r\n" ++
            "A005 SETACL \"INBOX\" friend lr\r\n" ++
            "A006 GETACL \"INBOX\"\r\n" ++
            "A007 MYRIGHTS \"INBOX\"\r\n" ++
            "A008 SETQUOTA \"\" (STORAGE 2048 MESSAGE 25)\r\n" ++
            "A009 GETQUOTA \"\"\r\n" ++
            "A010 GETQUOTAROOT \"INBOX\"\r\n" ++
            "A011 SETMETADATA \"INBOX\" (/private/comment \"test\")\r\n" ++
            "A012 GETMETADATA \"INBOX\" (/private/comment)\r\n" ++
            "A013 LOGOUT\r\n",
    );
    defer transport.deinit();

    var server = imap.server.Server.init(std.testing.allocator, &store);
    try server.serveTransport(transport.transport());

    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* SORT 2 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* THREAD (1 (2))") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* ACL INBOX user lrswipdkxtea friend lr") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* MYRIGHTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* QUOTA \"\" (STORAGE") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "MESSAGE 2 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* QUOTAROOT") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* METADATA INBOX (\"/private/comment\" \"test\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A012 OK GETMETADATA completed") != null);
}

test "server starttls compress unauthenticate" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    var transport = ScriptTransport.init(
        std.testing.allocator,
        "A001 STARTTLS\r\n" ++
            "A002 LOGIN \"user\" \"pass\"\r\n" ++
            "A003 COMPRESS DEFLATE\r\n" ++
            "A004 UNAUTHENTICATE\r\n" ++
            "A005 LOGIN \"user\" \"pass\"\r\n" ++
            "A006 LOGOUT\r\n",
    );
    defer transport.deinit();

    var server = imap.server.Server.init(std.testing.allocator, &store);
    try server.serveTransport(transport.transport());

    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A001 OK Begin TLS negotiation now") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A003 OK COMPRESS completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A004 OK UNAUTHENTICATE completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A005 OK LOGIN completed") != null);
}

test "server search with larger smaller and header" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    const user = try store.authenticate("user", "pass");
    const inbox = user.getMailbox("INBOX").?;
    _ = try inbox.appendMessage("Subject: tiny\r\n\r\nhi", &.{}, 0);
    _ = try inbox.appendMessage("Subject: big\r\n\r\n" ++ "X" ** 200, &.{}, 0);

    var transport = ScriptTransport.init(
        std.testing.allocator,
        "A001 LOGIN \"user\" \"pass\"\r\n" ++
            "A002 SELECT \"INBOX\"\r\n" ++
            "A003 SEARCH LARGER 100\r\n" ++
            "A004 SEARCH SMALLER 50\r\n" ++
            "A005 LOGOUT\r\n",
    );
    defer transport.deinit();

    var server = imap.server.Server.init(std.testing.allocator, &store);
    try server.serveTransport(transport.transport());

    // Message 2 is > 100 bytes
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* SEARCH 2") != null);
    // Message 1 is < 50 bytes
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* SEARCH 1\r\n") != null);
}
