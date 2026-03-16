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
