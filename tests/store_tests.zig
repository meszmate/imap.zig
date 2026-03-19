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

test "store interface mailbox operations" {
    var store = imap.store.memstore.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    var backend = imap.store.Backend.fromMemStore(&store);
    var user = try backend.authenticate(std.testing.allocator, "user", "pass");
    defer user.deinit();

    var mailbox = try user.openMailbox("INBOX");
    defer mailbox.deinit();

    // Append a message
    try mailbox.appendMessage("Subject: Test\r\n\r\nHello");

    // Get info
    const mb_info = try mailbox.info();
    try std.testing.expectEqual(@as(u32, 1), mb_info.num_messages);
    try std.testing.expectEqual(@as(u32, 1), mb_info.uid_validity);

    // List UIDs
    const uids = try mailbox.listUids();
    defer std.testing.allocator.free(uids);
    try std.testing.expectEqual(@as(usize, 1), uids.len);

    // Get messages
    const msgs = try mailbox.getMessages(uids);
    defer mailbox.freeMessageData(msgs);
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expect(std.mem.indexOf(u8, msgs[0].body, "Hello") != null);

    // Set flags
    try mailbox.setFlags(uids, imap.store.interface.FLAG_ACTION_ADD, &.{"\\Seen"});

    // Search
    const search_params = imap.store.SearchParams{ .seen = true };
    const results = try mailbox.searchMessages(&search_params);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);

    // Expunge (no deleted messages, should return empty)
    const expunged = try mailbox.expungeMessages(null);
    defer std.testing.allocator.free(expunged);
    try std.testing.expectEqual(@as(usize, 0), expunged.len);
}

test "store interface subscribe and status" {
    var store = imap.store.memstore.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    var backend = imap.store.Backend.fromMemStore(&store);
    var user = try backend.authenticate(std.testing.allocator, "user", "pass");
    defer user.deinit();

    try user.subscribeMailbox("INBOX");
    try user.unsubscribeMailbox("INBOX");

    const status = try user.getMailboxStatus("INBOX");
    try std.testing.expectEqual(@as(u32, 0), status.num_messages);
}

test "protocol adapter basic operations" {
    var store = imap.store.memstore.MemStore.init(std.testing.allocator);
    defer store.deinit();
    try store.addUser("user", "pass");

    const mem_user = store.users.get("user").?;
    const inbox = mem_user.getMailbox("INBOX").?;
    _ = try inbox.appendMessage("Subject: Test\r\n\r\nBody", &.{}, null);

    const backend = imap.store.Backend.fromMemStore(&store);
    var adapter = imap.store.ProtocolAdapter.init(std.testing.allocator, backend);
    defer adapter.deinit();

    try adapter.login("user", "pass");
    const info = try adapter.selectMailbox("INBOX");
    try std.testing.expectEqual(@as(u32, 1), info.num_messages);

    // Test seq-to-uid mapping
    try std.testing.expect(adapter.seqToUid(1) != null);
    try std.testing.expect(adapter.seqToUid(2) == null);
}

test "create options and store options" {
    const create_opts = imap.CreateOptions{};
    try std.testing.expect(create_opts.special_use == null);

    const store_opts = imap.StoreOptions{};
    try std.testing.expect(store_opts.unchanged_since == null);

    const ns = imap.NamespaceData{};
    try std.testing.expectEqual(@as(usize, 0), ns.personal.len);
}
