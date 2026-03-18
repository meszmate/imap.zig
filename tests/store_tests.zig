const std = @import("std");
const imap = @import("imap");

test "wire encoder and decoder handle quoted and literal tokens" {
    var encoder = imap.wire.Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.atom("A1");
    try encoder.sp();
    try encoder.quoted("INBOX");
    try encoder.sp();
    try encoder.literal("hello");
    const rendered = try encoder.finish();
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("A1 \"INBOX\" {5}\r\nhello", rendered);

    var decoder = imap.wire.Decoder.init(std.testing.allocator, rendered);
    const t1 = (try decoder.next()).?;
    try std.testing.expectEqual(imap.wire.TokenKind.atom, t1.kind);
    try std.testing.expectEqualStrings("A1", t1.value);
    const t2 = (try decoder.next()).?;
    defer std.testing.allocator.free(t2.value);
    try std.testing.expectEqual(imap.wire.TokenKind.quoted, t2.kind);
    try std.testing.expectEqualStrings("INBOX", t2.value);
    const t3 = (try decoder.next()).?;
    defer std.testing.allocator.free(t3.value);
    try std.testing.expectEqual(imap.wire.TokenKind.literal, t3.kind);
    try std.testing.expectEqualStrings("hello", t3.value);
}

test "fsstore persists users and mailboxes" {
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/imap_fsstore_test_{d}", .{@as(i64, std.time.milliTimestamp())});
    defer std.testing.allocator.free(path);

    var fsstore = try imap.store.FsStore.init(std.testing.allocator, path);
    defer fsstore.deinit();
    try fsstore.addUser("user", "pass");

    var user = try fsstore.authenticate("user", "pass");
    defer user.deinit();
    const boxes = try user.listMailboxesAlloc();
    defer {
        for (boxes) |box| std.testing.allocator.free(box);
        std.testing.allocator.free(boxes);
    }
    try std.testing.expect(boxes.len >= 1);
    try user.appendMessage("INBOX", "hello world");
}

test "pgstore schema contains expected tables" {
    const schema = imap.store.pgstore.PgStore.schemaSql();
    try std.testing.expect(std.mem.indexOf(u8, schema, "CREATE TABLE IF NOT EXISTS imap_users") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "CREATE TABLE IF NOT EXISTS imap_mailboxes") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "CREATE TABLE IF NOT EXISTS imap_messages") != null);
}

const MockExec = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList([]u8) = .empty,

    fn deinit(self: *MockExec) void {
        for (self.commands.items) |cmd| self.allocator.free(cmd);
        self.commands.deinit(self.allocator);
    }
};

fn mockExec(ctx: *anyopaque, allocator: std.mem.Allocator, _: imap.store.pgstore.Options, sql: []const u8) ![]u8 {
    const mock: *MockExec = @ptrCast(@alignCast(ctx));
    try mock.commands.append(mock.allocator, try mock.allocator.dupe(u8, sql));

    if (std.mem.startsWith(u8, sql, "SELECT username FROM imap_users")) {
        return allocator.dupe(u8, "user\n");
    }
    if (std.mem.startsWith(u8, sql, "SELECT name FROM imap_mailboxes")) {
        return allocator.dupe(u8, "Archive\nINBOX\n");
    }
    return allocator.dupe(u8, "");
}

test "pgstore works with mock executor without postgres" {
    var mock = MockExec{
        .allocator = std.testing.allocator,
    };
    defer mock.deinit();

    var pgstore = imap.store.PgStore.initWithExecutor(
        std.testing.allocator,
        .{},
        &mock,
        mockExec,
    );
    defer pgstore.deinit();

    try pgstore.ensureSchema();
    try pgstore.addUser("user", "p'ass");
    try pgstore.createMailbox("user", "INBOX");

    var user = try pgstore.authenticate("user", "p'ass");
    defer user.deinit();
    const boxes = try user.listMailboxesAlloc();
    defer {
        for (boxes) |box| std.testing.allocator.free(box);
        std.testing.allocator.free(boxes);
    }
    try std.testing.expectEqual(@as(usize, 2), boxes.len);
    try user.appendMessage("INBOX", "hello");

    try std.testing.expect(mock.commands.items.len >= 6);
    try std.testing.expect(std.mem.indexOf(u8, mock.commands.items[0], "CREATE TABLE IF NOT EXISTS imap_users") != null);
    try std.testing.expect(std.mem.indexOf(u8, mock.commands.items[1], "INSERT INTO imap_users") != null);
}
