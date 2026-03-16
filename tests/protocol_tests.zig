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

test "literal marker parsing" {
    // Standard synchronizing literal
    const info1 = imap.wire.parseLiteralMarker("{100}");
    try std.testing.expect(info1 != null);
    try std.testing.expectEqual(@as(usize, 100), info1.?.size);
    try std.testing.expect(info1.?.synchronizing);
    try std.testing.expect(!info1.?.binary);

    // Literal+ (non-synchronizing)
    const info2 = imap.wire.parseLiteralMarker("{42+}");
    try std.testing.expect(info2 != null);
    try std.testing.expectEqual(@as(usize, 42), info2.?.size);
    try std.testing.expect(!info2.?.synchronizing);

    // Literal- (non-synchronizing)
    const info3 = imap.wire.parseLiteralMarker("{7-}");
    try std.testing.expect(info3 != null);
    try std.testing.expectEqual(@as(usize, 7), info3.?.size);
    try std.testing.expect(!info3.?.synchronizing);

    // Binary literal
    const info4 = imap.wire.parseLiteralMarker("~{200}");
    try std.testing.expect(info4 != null);
    try std.testing.expectEqual(@as(usize, 200), info4.?.size);
    try std.testing.expect(info4.?.binary);

    // Invalid
    try std.testing.expect(imap.wire.parseLiteralMarker("hello") == null);
    try std.testing.expect(imap.wire.parseLiteralMarker("{}") == null);
}
