const std = @import("std");
const types = @import("../types.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    tag: []const u8,
    command: []const u8,
    state: types.ConnState = .not_authenticated,
    notes: std.ArrayList([]u8) = .empty,
    recovered_error: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, tag: []const u8, command: []const u8) Context {
        return .{
            .allocator = allocator,
            .tag = tag,
            .command = command,
        };
    }

    pub fn deinit(self: *Context) void {
        for (self.notes.items) |note| self.allocator.free(note);
        self.notes.deinit(self.allocator);
        if (self.recovered_error) |message| self.allocator.free(message);
        self.* = undefined;
    }

    pub fn addNote(self: *Context, note: []const u8) !void {
        try self.notes.append(self.allocator, try self.allocator.dupe(u8, note));
    }
};

pub const Handler = *const fn (context: *Context) anyerror!void;

pub const Middleware = struct {
    name: []const u8,
    ctx: *anyopaque,
    apply_fn: *const fn (ctx: *anyopaque, chain: *const Chain, index: usize, context: *Context) anyerror!void,

    pub fn apply(self: Middleware, chain: *const Chain, index: usize, context: *Context) !void {
        return self.apply_fn(self.ctx, chain, index, context);
    }
};

pub const Chain = struct {
    middlewares: []const Middleware,
    handler: Handler,

    pub fn run(self: *const Chain, context: *Context) !void {
        return self.runFrom(0, context);
    }

    pub fn runFrom(self: *const Chain, index: usize, context: *Context) !void {
        if (index >= self.middlewares.len) return self.handler(context);
        return self.middlewares[index].apply(self, index + 1, context);
    }
};

pub const LogEntry = struct {
    tag: []u8,
    command: []u8,

    fn deinit(self: *LogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
        allocator.free(self.command);
        self.* = undefined;
    }
};

pub const LogSink = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(LogEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) LogSink {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LogSink) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }
};

pub const Metrics = struct {
    allocator: std.mem.Allocator,
    total_runs: usize = 0,
    per_command: std.StringHashMap(usize),

    pub fn init(allocator: std.mem.Allocator) Metrics {
        return .{
            .allocator = allocator,
            .per_command = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Metrics) void {
        var it = self.per_command.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.per_command.deinit();
    }
};

pub const RateLimiter = struct {
    remaining: usize,

    pub fn init(limit: usize) RateLimiter {
        return .{ .remaining = limit };
    }
};

pub const Timeout = struct {
    deadline_ms: i64,

    pub fn initRelative(milliseconds: i64) Timeout {
        return .{
            .deadline_ms = std.time.milliTimestamp() + milliseconds,
        };
    }
};

pub fn logging(sink: *LogSink) Middleware {
    return .{
        .name = "logging",
        .ctx = sink,
        .apply_fn = applyLogging,
    };
}

pub fn metrics(metrics_state: *Metrics) Middleware {
    return .{
        .name = "metrics",
        .ctx = metrics_state,
        .apply_fn = applyMetrics,
    };
}

pub fn rateLimit(limiter: *RateLimiter) Middleware {
    return .{
        .name = "rate-limit",
        .ctx = limiter,
        .apply_fn = applyRateLimit,
    };
}

pub fn recovery() Middleware {
    return .{
        .name = "recovery",
        .ctx = undefined,
        .apply_fn = applyRecovery,
    };
}

pub fn timeout(timeout_state: *Timeout) Middleware {
    return .{
        .name = "timeout",
        .ctx = timeout_state,
        .apply_fn = applyTimeout,
    };
}

fn applyLogging(ctx: *anyopaque, chain: *const Chain, index: usize, context: *Context) !void {
    const sink: *LogSink = @ptrCast(@alignCast(ctx));
    try sink.entries.append(sink.allocator, .{
        .tag = try sink.allocator.dupe(u8, context.tag),
        .command = try sink.allocator.dupe(u8, context.command),
    });
    try chain.runFrom(index, context);
}

fn applyMetrics(ctx: *anyopaque, chain: *const Chain, index: usize, context: *Context) !void {
    const metrics_state: *Metrics = @ptrCast(@alignCast(ctx));
    metrics_state.total_runs += 1;
    const entry = try metrics_state.per_command.getOrPut(context.command);
    if (!entry.found_existing) {
        entry.key_ptr.* = try metrics_state.allocator.dupe(u8, context.command);
        entry.value_ptr.* = 0;
    }
    entry.value_ptr.* += 1;
    try chain.runFrom(index, context);
}

fn applyRateLimit(ctx: *anyopaque, chain: *const Chain, index: usize, context: *Context) !void {
    const limiter: *RateLimiter = @ptrCast(@alignCast(ctx));
    if (limiter.remaining == 0) return error.RateLimited;
    limiter.remaining -= 1;
    try chain.runFrom(index, context);
}

fn applyRecovery(_: *anyopaque, chain: *const Chain, index: usize, context: *Context) !void {
    chain.runFrom(index, context) catch |err| {
        if (context.recovered_error) |message| context.allocator.free(message);
        context.recovered_error = try context.allocator.dupe(u8, @errorName(err));
        try context.addNote("recovered");
    };
}

fn applyTimeout(ctx: *anyopaque, chain: *const Chain, index: usize, context: *Context) !void {
    const timeout_state: *Timeout = @ptrCast(@alignCast(ctx));
    if (std.time.milliTimestamp() > timeout_state.deadline_ms) return error.TimeoutExceeded;
    try chain.runFrom(index, context);
    if (std.time.milliTimestamp() > timeout_state.deadline_ms) return error.TimeoutExceeded;
}
