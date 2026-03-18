const std = @import("std");
const imap = @import("../root.zig");
const conn_mod = @import("conn.zig");
const session_mod = @import("session.zig");
const wire = @import("../wire/root.zig");

pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    tag: []const u8,
    name: []const u8,
    args: []const conn_mod.Token,
    uid_mode: bool = false,
    transport: wire.Transport,
    session: *session_mod.SessionState,
    values: std.StringHashMap([]const u8),

    pub fn init(
        allocator: std.mem.Allocator,
        tag: []const u8,
        name: []const u8,
        args: []const conn_mod.Token,
        uid_mode: bool,
        transport: wire.Transport,
        session: *session_mod.SessionState,
    ) CommandContext {
        return .{
            .allocator = allocator,
            .tag = tag,
            .name = name,
            .args = args,
            .uid_mode = uid_mode,
            .transport = transport,
            .session = session,
            .values = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CommandContext) void {
        self.values.deinit();
    }

    pub fn state(self: *const CommandContext) imap.ConnState {
        return self.session.state;
    }

    pub fn setValue(self: *CommandContext, key: []const u8, value: []const u8) !void {
        try self.values.put(key, value);
    }

    pub fn getValue(self: *const CommandContext, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }
};

pub const CommandHandlerFn = *const fn (ctx: *CommandContext) anyerror!void;

/// Dispatcher manages command handler registration and routing.
pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    handlers: std.StringHashMap(CommandHandlerFn),

    pub fn init(allocator: std.mem.Allocator) Dispatcher {
        return .{
            .allocator = allocator,
            .handlers = std.StringHashMap(CommandHandlerFn).init(allocator),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.handlers.deinit();
    }

    /// Register a command handler by name (case-insensitive matching at dispatch time).
    pub fn register(self: *Dispatcher, name: []const u8, handler: CommandHandlerFn) !void {
        try self.handlers.put(name, handler);
    }

    /// Get a registered handler by name.
    pub fn get(self: *const Dispatcher, name: []const u8) ?CommandHandlerFn {
        // Try exact match first
        if (self.handlers.get(name)) |handler| return handler;
        // Try case-insensitive match
        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
        }
        return null;
    }

    /// Get all registered command names.
    pub fn namesAlloc(self: *const Dispatcher, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);
        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            try list.append(allocator, entry.key_ptr.*);
        }
        return list.toOwnedSlice(allocator);
    }

    /// Dispatch a command to its registered handler.
    pub fn dispatch(self: *const Dispatcher, ctx: *CommandContext) !void {
        const handler = self.get(ctx.name) orelse {
            try ctx.transport.print("{s} BAD unknown command\r\n", .{ctx.tag});
            return;
        };
        try handler(ctx);
    }
};
