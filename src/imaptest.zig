const std = @import("std");
const imap = @import("root.zig");
const memstore = @import("store/memstore.zig");
const wire = @import("wire/root.zig");

/// Harness provides an in-process IMAP server and client for integration testing.
/// It uses a pair of connected transports so no real TCP is needed.
pub const Harness = struct {
    allocator: std.mem.Allocator,
    store: memstore.MemStore,
    server_transport: PipeTransport,
    client_transport: PipeTransport,

    pub fn init(allocator: std.mem.Allocator) Harness {
        const pipe = PipePair.init(allocator);
        return .{
            .allocator = allocator,
            .store = memstore.MemStore.init(allocator),
            .server_transport = pipe.server,
            .client_transport = pipe.client,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.server_transport.deinit();
        self.client_transport.deinit();
        self.store.deinit();
    }

    /// Add a user to the test store.
    pub fn addUser(self: *Harness, username: []const u8, password: []const u8) !void {
        try self.store.addUser(username, password);
    }

    /// Get a user from the store.
    pub fn getUser(self: *Harness, username: []const u8) ?*memstore.User {
        return self.store.users.get(username);
    }

    /// Run the server on the server-side transport. Call this before using the client.
    /// In tests, run this then send commands via writeClientLine / readClientLine.
    pub fn runServer(self: *Harness) !void {
        var server = imap.server.Server.init(self.allocator, &self.store);
        try server.serveTransport(self.server_transport.transport());
    }

    /// Write a line to the server (simulating client sending).
    pub fn writeClientLine(self: *Harness, line: []const u8) !void {
        const t = self.client_transport.transport();
        try t.writeAll(line);
    }

    /// Read accumulated server output.
    pub fn serverOutput(self: *Harness) []const u8 {
        return self.server_transport.output.items;
    }
};

/// A pair of connected pipe transports for testing.
const PipePair = struct {
    server: PipeTransport,
    client: PipeTransport,

    fn init(allocator: std.mem.Allocator) PipePair {
        return .{
            .server = PipeTransport.init(allocator),
            .client = PipeTransport.init(allocator),
        };
    }
};

/// PipeTransport is a simple in-memory transport for testing.
pub const PipeTransport = struct {
    allocator: std.mem.Allocator,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    read_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator) PipeTransport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PipeTransport) void {
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
    }

    pub fn feedInput(self: *PipeTransport, data: []const u8) !void {
        try self.input.appendSlice(self.allocator, data);
    }

    pub fn transport(self: *PipeTransport) wire.Transport {
        return .{
            .ctx = @ptrCast(self),
            .read_fn = readFn,
            .write_fn = writeFn,
            .close_fn = closeFn,
        };
    }

    fn readFn(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *PipeTransport = @ptrCast(@alignCast(ctx));
        if (self.read_pos >= self.input.items.len) return 0;
        const available = self.input.items[self.read_pos..];
        const to_read = @min(buffer.len, available.len);
        @memcpy(buffer[0..to_read], available[0..to_read]);
        self.read_pos += to_read;
        return to_read;
    }

    fn writeFn(ctx: *anyopaque, data: []const u8) anyerror!usize {
        const self: *PipeTransport = @ptrCast(@alignCast(ctx));
        self.output.appendSlice(self.allocator, data) catch return error.OutOfMemory;
        return data.len;
    }

    fn closeFn(_: *anyopaque) anyerror!void {}
};

/// MockSession provides a minimal mock session for testing command handlers
/// without a real backend.
pub const MockSession = struct {
    logged_in: bool = false,
    username: ?[]const u8 = null,
    selected_mailbox: ?[]const u8 = null,
    closed: bool = false,

    pub fn login(self: *MockSession, user: []const u8, _: []const u8) !void {
        self.logged_in = true;
        self.username = user;
    }

    pub fn selectMailbox(self: *MockSession, name: []const u8) void {
        self.selected_mailbox = name;
    }

    pub fn close(self: *MockSession) void {
        self.closed = true;
    }
};
