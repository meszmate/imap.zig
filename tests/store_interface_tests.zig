const std = @import("std");
const imap = @import("imap");

test "store backend wraps memstore operations" {
    var store = imap.store.MemStore.init(std.testing.allocator);
    defer store.deinit();

    const backend = imap.store.Backend.fromMemStore(&store);
    try backend.addUser("user", "pass");

    var user = try backend.authenticate(std.testing.allocator, "user", "pass");
    defer user.deinit();

    try std.testing.expectEqualStrings("user", user.username());
    try user.createMailbox("Archive");
    try user.appendMessage("Archive", "hello from memstore");

    var mailbox = try user.openMailbox("Archive");
    defer mailbox.deinit();
    try std.testing.expectEqualStrings("Archive", mailbox.name());
    try mailbox.appendMessage("second message");

    const boxes = try user.listMailboxesAlloc();
    defer {
        for (boxes) |box| std.testing.allocator.free(box);
        std.testing.allocator.free(boxes);
    }
    try std.testing.expect(boxes.len >= 2);
}

test "store backend wraps fsstore operations" {
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/imap_backend_fs_{d}", .{@as(i64, std.time.milliTimestamp())});
    defer std.testing.allocator.free(path);

    var store = try imap.store.FsStore.init(std.testing.allocator, path);
    defer store.deinit();

    const backend = imap.store.Backend.fromFsStore(&store);
    try backend.addUser("user", "pass");

    var user = try backend.authenticate(std.testing.allocator, "user", "pass");
    defer user.deinit();

    try user.createMailbox("Archive");
    try user.renameMailbox("Archive", "Saved");
    try user.appendMessage("Saved", "hello from fsstore");

    var mailbox = try user.openMailbox("Saved");
    defer mailbox.deinit();
    try std.testing.expectEqualStrings("Saved", mailbox.name());
    try mailbox.appendMessage("second fs message");

    const boxes = try user.listMailboxesAlloc();
    defer {
        for (boxes) |box| std.testing.allocator.free(box);
        std.testing.allocator.free(boxes);
    }

    var found_saved = false;
    for (boxes) |box| {
        if (std.mem.eql(u8, box, "Saved")) found_saved = true;
    }
    try std.testing.expect(found_saved);
}
