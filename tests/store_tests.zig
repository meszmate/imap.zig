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
