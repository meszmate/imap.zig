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

test "server conn parses uid commands and writes tagged responses" {
    var transport = ScriptTransport.init(
        std.testing.allocator,
        "A001 UID FETCH 1:* (FLAGS UID)\r\n",
    );
    defer transport.deinit();

    var conn = imap.server.Conn.init(std.testing.allocator, transport.transport());
    try conn.writeGreeting("IMAP4rev1 UIDPLUS");

    var command = (try conn.readCommandAlloc()).?;
    defer command.deinit();

    try std.testing.expectEqualStrings("A001", command.tag);
    try std.testing.expectEqualStrings("FETCH", command.name);
    try std.testing.expect(command.uid_mode);
    try std.testing.expectEqual(@as(usize, 2), command.args.len);

    try conn.writeTagged(command.tag, .ok, "READ-WRITE", "done");
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "* OK [CAPABILITY IMAP4rev1 UIDPLUS] imap.zig ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.output.items, "A001 OK [READ-WRITE] done") != null);
}

test "server session tracks selection state" {
    var session = imap.server.SessionState{};
    try std.testing.expect(!session.canExecute("FETCH"));
    session.state = .authenticated;
    try std.testing.expect(session.canExecute("LIST"));
    session.select("INBOX", false);
    try std.testing.expect(session.canExecute("FETCH"));
    try std.testing.expectEqualStrings("INBOX", session.selected_mailbox.?);
    session.unselect();
    try std.testing.expectEqual(imap.ConnState.authenticated, session.state);
    session.logout();
    try std.testing.expectEqual(imap.ConnState.logout, session.state);
}
