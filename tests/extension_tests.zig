const std = @import("std");
const imap = @import("imap");

test "extension registry registers and resolves builtins" {
    var registry = imap.extension.Registry.init(std.testing.allocator);
    defer registry.deinit();

    try imap.extension.Builtins.registerCore(&registry);
    try std.testing.expect(registry.len() >= 8);
    try std.testing.expect(registry.get("IDLE") != null);

    const resolved = try registry.resolveAlloc(std.testing.allocator);
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(resolved.len >= 8);
}

test "extension registry detects missing dependencies" {
    var registry = imap.extension.Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "BROKEN",
        .capabilities = &.{imap.caps.qresync},
        .dependencies = &.{"CONDSTORE"},
    });
    try std.testing.expectError(error.MissingDependency, registry.resolveAlloc(std.testing.allocator));
}
