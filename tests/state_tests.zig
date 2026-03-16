const std = @import("std");
const imap = @import("imap");

fn beforeHook(from: imap.ConnState, to: imap.ConnState) !void {
    if (from == .not_authenticated and to == .authenticated) return;
}

test "state machine supports RFC-style transitions" {
    var machine = try imap.state.Machine.init(std.testing.allocator, .not_authenticated);
    defer machine.deinit();

    try std.testing.expect(machine.canTransitionFromCurrent(.authenticated));
    try std.testing.expect(!machine.canTransitionFromCurrent(.selected));

    try machine.transition(.authenticated);
    try std.testing.expectEqual(imap.ConnState.authenticated, machine.current());

    try machine.transition(.selected);
    try std.testing.expectEqual(imap.ConnState.selected, machine.current());

    try std.testing.expectError(error.InvalidTransition, machine.transition(.not_authenticated));
}

test "state machine hooks and allowed command states work" {
    var machine = try imap.state.Machine.init(std.testing.allocator, .not_authenticated);
    defer machine.deinit();
    try machine.onBefore(beforeHook);

    try machine.requireState(&.{.not_authenticated});
    try std.testing.expectEqual(@as(usize, 1), imap.state.commandAllowedStates("LOGIN").len);
}
