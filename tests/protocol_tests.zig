const std = @import("std");
const imap = @import("imap");

test "numset parse and format" {
    var set = try imap.NumSet.parse(std.testing.allocator, .seq, "1,2:4,6:*");
    defer set.deinit();

    try std.testing.expect(set.contains(3));
    try std.testing.expect(set.dynamic());

    const formatted = try set.toOwnedString(std.testing.allocator);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("1,2:4,6:*", formatted);
}

test "status response parser handles tagged line" {
    var response = try imap.parseStatusLine(std.testing.allocator, "A001 OK [UIDVALIDITY 7] done");
    defer imap.freeStatus(std.testing.allocator, &response);

    try std.testing.expectEqual(imap.StatusKind.ok, response.kind);
    try std.testing.expectEqualStrings("A001", response.tag.?);
    try std.testing.expectEqualStrings("UIDVALIDITY", response.code.?);
    try std.testing.expectEqualStrings("7", response.code_arg.?);
    try std.testing.expectEqualStrings("done", response.text);
}

test "modified utf7 roundtrip" {
    const encoded = try imap.wire.encodeAlloc(std.testing.allocator, "Inbox/日本語");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("Inbox/&ZeVnLIqe-", encoded);

    const decoded = try imap.wire.decodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("Inbox/日本語", decoded);
}
