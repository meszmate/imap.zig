const std = @import("std");
const client_mod = @import("client.zig");

pub const DialFn = *const fn (allocator: std.mem.Allocator, host: []const u8, port: u16) anyerror!client_mod.Client;

pub const Options = struct {
    host: []const u8,
    port: u16,
    max_idle: usize = 4,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    dial_fn: ?DialFn = null,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    options: Options,
    idle: std.ArrayList(*client_mod.Client) = .empty,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, options: Options) Pool {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.idle.items) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.idle.deinit(self.allocator);
    }

    pub fn acquire(self: *Pool) !*client_mod.Client {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.idle.items.len > 0) {
            return self.idle.pop().?;
        }

        const client_ptr = try self.allocator.create(client_mod.Client);
        errdefer self.allocator.destroy(client_ptr);
        client_ptr.* = try (self.options.dial_fn orelse defaultDial)(self.allocator, self.options.host, self.options.port);
        if (self.options.username) |username| {
            try client_ptr.login(username, self.options.password orelse "");
        }
        return client_ptr;
    }

    pub fn release(self: *Pool, client: *client_mod.Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.idle.items.len >= self.options.max_idle or client.state == .logout) {
            client.deinit();
            self.allocator.destroy(client);
            return;
        }
        self.idle.append(self.allocator, client) catch {
            client.deinit();
            self.allocator.destroy(client);
        };
    }

    fn defaultDial(allocator: std.mem.Allocator, host: []const u8, port: u16) !client_mod.Client {
        return client_mod.Client.connectTcp(allocator, host, port);
    }
};
