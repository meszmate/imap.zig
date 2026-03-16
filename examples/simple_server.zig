const std = @import("std");
const imap = @import("imap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = imap.store.MemStore.init(allocator);
    defer store.deinit();
    try store.addUser("user", "password");

    var server = imap.server.Server.init(allocator, &store);
    var stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll("imap.zig listening on 127.0.0.1:1143\n");
    try server.listenAndServe("127.0.0.1:1143");
}
