const std = @import("std");
const imap = @import("imap");

test "extension registry registers and resolves builtins" {
    var registry = imap.extension.Registry.init(std.testing.allocator);
    defer registry.deinit();

    try imap.extension.Builtins.registerCore(&registry);
    try std.testing.expect(registry.len() >= 45);
    try std.testing.expect(registry.get("IDLE") != null);
    try std.testing.expect(registry.get("ACL") != null);
    try std.testing.expect(registry.get("QRESYNC") != null);
    try std.testing.expect(registry.get("SORT=DISPLAY") != null);
    try std.testing.expect(registry.get("URLAUTH") != null);

    const resolved = try registry.resolveAlloc(std.testing.allocator);
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(resolved.len >= 45);

    const qresync_index = indexOfExtension(resolved, "QRESYNC").?;
    const condstore_index = indexOfExtension(resolved, "CONDSTORE").?;
    try std.testing.expect(condstore_index < qresync_index);

    const esort_index = indexOfExtension(resolved, "ESORT").?;
    const esearch_index = indexOfExtension(resolved, "ESEARCH").?;
    const sort_index = indexOfExtension(resolved, "SORT").?;
    try std.testing.expect(esearch_index < esort_index);
    try std.testing.expect(sort_index < esort_index);

    const sort_display_index = indexOfExtension(resolved, "SORT=DISPLAY").?;
    try std.testing.expect(sort_index < sort_display_index);
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

test "extension registry detects circular dependencies" {
    var registry = imap.extension.Registry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "A",
        .capabilities = &.{},
        .dependencies = &.{"B"},
    });
    try registry.register(.{
        .name = "B",
        .capabilities = &.{},
        .dependencies = &.{"A"},
    });

    try std.testing.expectError(error.CircularDependency, registry.resolveAlloc(std.testing.allocator));
}

fn indexOfExtension(items: []const imap.extension.Extension, name: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.name, name)) return index;
    }
    return null;
}
