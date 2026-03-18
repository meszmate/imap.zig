const std = @import("std");
const imap = @import("imap");

/// Simple IMAP proxy that accepts client connections and forwards
/// commands to an upstream IMAP server. Demonstrates using both
/// the client and server wire-level APIs together.
///
/// Usage: proxy <upstream_host> <upstream_port> [listen_port]
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: proxy <upstream_host> <upstream_port> [listen_port]\n", .{});
        std.process.exit(1);
    }

    const upstream_host = args[1];
    const upstream_port = try std.fmt.parseInt(u16, args[2], 10);
    const listen_port: u16 = if (args.len > 3) try std.fmt.parseInt(u16, args[3], 10) else 1143;

    var stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("IMAP proxy listening on port {d}, forwarding to {s}:{d}\n", .{ listen_port, upstream_host, upstream_port });

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, listen_port);
    var server = try address.listen(.{});
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ allocator, conn, upstream_host, upstream_port });
        thread.detach();
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    downstream_conn: std.net.Server.Connection,
    upstream_host: []const u8,
    upstream_port: u16,
) void {
    defer downstream_conn.stream.close();

    proxySession(allocator, downstream_conn, upstream_host, upstream_port) catch |err| {
        std.debug.print("proxy session error: {}\n", .{err});
    };
}

fn proxySession(
    allocator: std.mem.Allocator,
    downstream_conn: std.net.Server.Connection,
    upstream_host: []const u8,
    upstream_port: u16,
) !void {
    // Connect to upstream server
    var upstream_stream = try std.net.tcpConnectToHost(allocator, upstream_host, upstream_port);
    defer upstream_stream.close();

    // Create transports wrapping the raw streams
    var downstream_stream = downstream_conn.stream;
    const upstream_transport = imap.wire.Transport.fromNetStream(&upstream_stream);
    const downstream_transport = imap.wire.Transport.fromNetStream(&downstream_stream);

    // Create line readers for both directions
    var upstream_reader = imap.wire.LineReader.init(allocator, upstream_transport);
    var downstream_reader = imap.wire.LineReader.init(allocator, downstream_transport);

    // Read upstream greeting and forward to client
    const greeting = try upstream_reader.readLineAlloc();
    defer allocator.free(greeting);

    try downstream_transport.writeAll(greeting);
    try downstream_transport.writeAll("\r\n");

    // Simple line-by-line proxy loop
    while (true) {
        // Read command from client
        const line = downstream_reader.readLineAlloc() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        defer allocator.free(line);

        // Forward command to upstream (re-add CRLF since LineReader strips it)
        try upstream_transport.writeAll(line);
        try upstream_transport.writeAll("\r\n");

        // Read response(s) from upstream and forward to client.
        // Keep reading until we see a tagged response matching the command tag.
        while (true) {
            const resp = upstream_reader.readLineAlloc() catch |err| switch (err) {
                error.EndOfStream => return,
                else => return err,
            };
            defer allocator.free(resp);

            try downstream_transport.writeAll(resp);
            try downstream_transport.writeAll("\r\n");

            // A tagged response means the command is complete
            if (isTaggedResponse(line, resp)) break;
        }
    }
}

/// Check whether a response line is the tagged completion for a given command.
/// IMAP commands start with a tag (e.g. "A001 LOGIN ...") and the server
/// replies with "* ..." for untagged data, then "A001 OK ..." as the final
/// tagged response.
fn isTaggedResponse(command_line: []const u8, response: []const u8) bool {
    // Extract tag from command (first space-delimited token)
    const tag_end = std.mem.indexOfScalar(u8, command_line, ' ') orelse return false;
    const tag = command_line[0..tag_end];

    // Check if the response starts with the same tag followed by a space
    if (response.len <= tag.len) return false;
    if (!std.mem.startsWith(u8, response, tag)) return false;
    return response[tag.len] == ' ';
}
