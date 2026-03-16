const std = @import("std");
const imap = @import("imap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const host = if (args.len > 1) args[1] else "127.0.0.1";
    const port = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 1143;
    const username = if (args.len > 3) args[3] else "user";
    const password = if (args.len > 4) args[4] else "password";

    var client = try imap.client.Client.connectTcp(allocator, host, port);
    defer client.deinit();

    _ = try client.capability();
    try client.login(username, password);
    const selected = try client.select("INBOX");

    var stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print(
        "Connected to {s}:{d}. INBOX exists={d} uidvalidity={any}\n",
        .{ host, port, selected.exists, selected.uid_validity },
    );

    try client.logout();
}
