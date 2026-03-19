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

test "client capability and select parsing" {
    var scripted = ScriptTransport.init(
        std.testing.allocator,
        "* OK [CAPABILITY IMAP4rev1 UIDPLUS] hi\r\n" ++
            "* CAPABILITY IMAP4rev1 UIDPLUS MOVE\r\n" ++
            "A0001 OK CAPABILITY completed\r\n" ++
            "* FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft)\r\n" ++
            "* 3 EXISTS\r\n" ++
            "* 0 RECENT\r\n" ++
            "* OK [UIDVALIDITY 9] valid\r\n" ++
            "* OK [UIDNEXT 12] next\r\n" ++
            "* OK [UNSEEN 2] unseen\r\n" ++
            "A0002 OK [READ-WRITE] SELECT completed\r\n",
    );
    defer scripted.deinit();

    var client = try imap.client.Client.init(std.testing.allocator, scripted.transport());
    defer client.deinit();

    const caps = try client.capability();
    try std.testing.expect(caps.len >= 3);
    try std.testing.expect(client.capabilities.has("MOVE"));

    const select = try client.select("INBOX");
    try std.testing.expectEqual(@as(u32, 3), select.exists);
    try std.testing.expectEqual(@as(u32, 0), select.recent);
    try std.testing.expectEqual(@as(?u32, 9), select.uid_validity);
    try std.testing.expectEqual(@as(?u32, 12), select.uid_next);
    try std.testing.expectEqual(@as(?u32, 2), select.unseen);

    try std.testing.expectEqualStrings(
        "A0001 CAPABILITY\r\nA0002 SELECT \"INBOX\"\r\n",
        scripted.output.items,
    );
}

test "client append sends literal payload" {
    var scripted = ScriptTransport.init(
        std.testing.allocator,
        "* OK hi\r\n" ++
            "+ Ready for literal data\r\n" ++
            "A0001 OK [APPENDUID 4 9] APPEND completed\r\n",
    );
    defer scripted.deinit();

    var client = try imap.client.Client.init(std.testing.allocator, scripted.transport());
    defer client.deinit();

    const append = try client.append("INBOX", "hello");
    try std.testing.expectEqual(@as(?u32, 4), append.uid_validity);
    try std.testing.expectEqual(@as(?imap.UID, 9), append.uid);

    try std.testing.expectEqualStrings(
        "A0001 APPEND \"INBOX\" {5}\r\nhello\r\n",
        scripted.output.items,
    );
}

test "client idleOnce reads continuation and sends DONE" {
    var scripted = ScriptTransport.init(
        std.testing.allocator,
        "* OK [CAPABILITY IMAP4rev1 IDLE] hi\r\n" ++
            "+ idling\r\n" ++
            "* 3 EXISTS\r\n" ++
            "A0001 OK IDLE completed\r\n",
    );
    defer scripted.deinit();

    var client = try imap.client.Client.init(std.testing.allocator, scripted.transport());
    defer client.deinit();

    const lines = try client.idleOnce();
    defer client.freeLines(lines);

    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expectEqualStrings("* 3 EXISTS", lines[0]);
    try std.testing.expectEqualStrings("A0001 IDLE\r\nDONE\r\n", scripted.output.items);
}

test "client authenticatePlain sends challenge response" {
    var scripted = ScriptTransport.init(
        std.testing.allocator,
        "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] hi\r\n" ++
            "+ \r\n" ++
            "A0001 OK AUTHENTICATE completed\r\n",
    );
    defer scripted.deinit();

    var client = try imap.client.Client.init(std.testing.allocator, scripted.transport());
    defer client.deinit();

    try client.authenticatePlain("user", "pass");
    try std.testing.expect(std.mem.startsWith(u8, scripted.output.items, "A0001 AUTHENTICATE PLAIN\r\n"));
}

test "client authenticateCramMd5 answers server challenge" {
    var scripted = ScriptTransport.init(
        std.testing.allocator,
        "* OK [CAPABILITY IMAP4rev1 AUTH=CRAM-MD5] hi\r\n" ++
            "+ PDE4OTYuNjk3MTcwOTUyQHBvc3Qub2ZmaWNlLm5ldD4=\r\n" ++
            "A0001 OK AUTHENTICATE completed\r\n",
    );
    defer scripted.deinit();

    var client = try imap.client.Client.init(std.testing.allocator, scripted.transport());
    defer client.deinit();

    try client.authenticateCramMd5("tim", "tanstaaftanstaaf");
    try std.testing.expect(std.mem.startsWith(u8, scripted.output.items, "A0001 AUTHENTICATE CRAM-MD5\r\n"));
}

test "client options and mailbox state" {
    const opts = imap.client.Options.defaultOptions();
    try std.testing.expectEqual(@as(u64, 0), opts.read_timeout_ms);
    try std.testing.expectEqual(false, opts.debug_log);

    var state = imap.client.MailboxState{};
    state.updateFromLine("* 5 EXISTS", null);
    try std.testing.expectEqual(@as(u32, 5), state.num_messages);
    state.updateFromLine("* 2 RECENT", null);
    try std.testing.expectEqual(@as(u32, 2), state.num_recent);
    state.updateFromLine("* 3 EXPUNGE", null);
    try std.testing.expectEqual(@as(u32, 4), state.num_messages);
    state.reset();
    try std.testing.expectEqual(@as(u32, 0), state.num_messages);
}

test "encoder literal plus and binary" {
    var encoder = imap.wire.Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.literalNonSync("hello");
    const rendered = try encoder.finish();
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("{5+}\r\nhello", rendered);

    var encoder2 = imap.wire.Encoder.init(std.testing.allocator);
    defer encoder2.deinit();
    try encoder2.binaryLiteral("data");
    const rendered2 = try encoder2.finish();
    defer std.testing.allocator.free(rendered2);
    try std.testing.expectEqualStrings("~{4}\r\ndata", rendered2);

    var encoder3 = imap.wire.Encoder.init(std.testing.allocator);
    defer encoder3.deinit();
    try encoder3.literalMinus("test");
    const rendered3 = try encoder3.finish();
    defer std.testing.allocator.free(rendered3);
    try std.testing.expectEqualStrings("{4-}\r\ntest", rendered3);
}

test "client authenticateXOAuth2 sends bearer response" {
    var scripted = ScriptTransport.init(
        std.testing.allocator,
        "* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2] hi\r\n" ++
            "+ \r\n" ++
            "A0001 OK AUTHENTICATE completed\r\n",
    );
    defer scripted.deinit();

    var client = try imap.client.Client.init(std.testing.allocator, scripted.transport());
    defer client.deinit();

    try client.authenticateXOAuth2("user", "token");
    try std.testing.expect(std.mem.startsWith(u8, scripted.output.items, "A0001 AUTHENTICATE XOAUTH2\r\n"));
}
