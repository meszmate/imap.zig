const std = @import("std");
const imap = @import("imap");

test "plain auth roundtrip" {
    const encoded = try imap.auth.plain.initialResponseAlloc(std.testing.allocator, "", "user", "pass");
    defer std.testing.allocator.free(encoded);

    const decoded = try imap.auth.plain.decodeResponseAlloc(std.testing.allocator, encoded);
    defer {
        std.testing.allocator.free(decoded.authzid);
        std.testing.allocator.free(decoded.username);
        std.testing.allocator.free(decoded.password);
    }
    try std.testing.expectEqualStrings("user", decoded.username);
    try std.testing.expectEqualStrings("pass", decoded.password);
}

test "login auth encodes prompts" {
    const encoded = try imap.auth.login.encodeAlloc(std.testing.allocator, "user");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("dXNlcg==", encoded);
    try std.testing.expectEqualStrings("VXNlcm5hbWU6", imap.auth.login.usernamePrompt());
}

test "cram md5 produces base64 response" {
    const response = try imap.auth.crammd5.responseAlloc(std.testing.allocator, "tim", "tanstaaftanstaaf", "PDE4OTYuNjk3MTcwOTUyQHBvc3Qub2ZmaWNlLm5ldD4=");
    defer std.testing.allocator.free(response);
    try std.testing.expect(response.len > 10);
}
