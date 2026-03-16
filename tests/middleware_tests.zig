const std = @import("std");
const imap = @import("imap");

fn recordHandler(context: *imap.middleware.Context) !void {
    try context.addNote("handled");
}

fn failingHandler(_: *imap.middleware.Context) !void {
    return error.Boom;
}

test "middleware chain logs and counts invocations" {
    var sink = imap.middleware.LogSink.init(std.testing.allocator);
    defer sink.deinit();

    var metrics = imap.middleware.Metrics.init(std.testing.allocator);
    defer metrics.deinit();

    var context = imap.middleware.Context.init(std.testing.allocator, "A001", "SELECT");
    defer context.deinit();

    const middlewares = [_]imap.middleware.Middleware{
        imap.middleware.logging(&sink),
        imap.middleware.metrics(&metrics),
    };
    const chain = imap.middleware.Chain{
        .middlewares = &middlewares,
        .handler = recordHandler,
    };

    try chain.run(&context);

    try std.testing.expectEqual(@as(usize, 1), sink.entries.items.len);
    try std.testing.expectEqualStrings("A001", sink.entries.items[0].tag);
    try std.testing.expectEqual(@as(usize, 1), metrics.total_runs);
    try std.testing.expectEqual(@as(usize, 1), metrics.per_command.get("SELECT").?);
    try std.testing.expectEqual(@as(usize, 1), context.notes.items.len);
}

test "middleware rate limiter rejects excess requests" {
    var limiter = imap.middleware.RateLimiter.init(1);
    var context = imap.middleware.Context.init(std.testing.allocator, "A001", "NOOP");
    defer context.deinit();

    const middlewares = [_]imap.middleware.Middleware{
        imap.middleware.rateLimit(&limiter),
    };
    const chain = imap.middleware.Chain{
        .middlewares = &middlewares,
        .handler = recordHandler,
    };

    try chain.run(&context);
    try std.testing.expectError(error.RateLimited, chain.run(&context));
}

test "middleware recovery captures handler errors" {
    var context = imap.middleware.Context.init(std.testing.allocator, "A001", "FETCH");
    defer context.deinit();

    const middlewares = [_]imap.middleware.Middleware{
        imap.middleware.recovery(),
    };
    const chain = imap.middleware.Chain{
        .middlewares = &middlewares,
        .handler = failingHandler,
    };

    try chain.run(&context);
    try std.testing.expectEqualStrings("Boom", context.recovered_error.?);
    try std.testing.expectEqual(@as(usize, 1), context.notes.items.len);
}

test "middleware timeout rejects expired command" {
    var timeout_state = imap.middleware.Timeout{ .deadline_ms = std.time.milliTimestamp() - 1 };
    var context = imap.middleware.Context.init(std.testing.allocator, "A001", "LOGIN");
    defer context.deinit();

    const middlewares = [_]imap.middleware.Middleware{
        imap.middleware.timeout(&timeout_state),
    };
    const chain = imap.middleware.Chain{
        .middlewares = &middlewares,
        .handler = recordHandler,
    };

    try std.testing.expectError(error.TimeoutExceeded, chain.run(&context));
}
