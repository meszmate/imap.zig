const std = @import("std");
const imap = @import("../root.zig");

pub const TransitionHook = *const fn (from: imap.ConnState, to: imap.ConnState) anyerror!void;

pub const Machine = struct {
    allocator: std.mem.Allocator,
    state: imap.ConnState,
    transitions: std.AutoHashMap(imap.ConnState, std.ArrayList(imap.ConnState)),
    before_hooks: std.ArrayList(TransitionHook) = .empty,
    after_hooks: std.ArrayList(TransitionHook) = .empty,

    pub fn init(allocator: std.mem.Allocator, initial: imap.ConnState) !Machine {
        var machine = Machine{
            .allocator = allocator,
            .state = initial,
            .transitions = std.AutoHashMap(imap.ConnState, std.ArrayList(imap.ConnState)).init(allocator),
        };
        errdefer machine.deinit();
        try machine.setDefaultTransitions();
        return machine;
    }

    pub fn deinit(self: *Machine) void {
        var it = self.transitions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.transitions.deinit();
        self.before_hooks.deinit(self.allocator);
        self.after_hooks.deinit(self.allocator);
    }

    pub fn current(self: *const Machine) imap.ConnState {
        return self.state;
    }

    pub fn transition(self: *Machine, target: imap.ConnState) !void {
        if (!self.canTransition(self.state, target)) return error.InvalidTransition;
        const from = self.state;
        for (self.before_hooks.items) |hook| try hook(from, target);
        self.state = target;
        for (self.after_hooks.items) |hook| try hook(from, target);
    }

    pub fn requireState(self: *const Machine, allowed: []const imap.ConnState) !void {
        for (allowed) |state| {
            if (self.state == state) return;
        }
        return error.CommandNotAllowedInState;
    }

    pub fn onBefore(self: *Machine, hook: TransitionHook) !void {
        try self.before_hooks.append(self.allocator, hook);
    }

    pub fn onAfter(self: *Machine, hook: TransitionHook) !void {
        try self.after_hooks.append(self.allocator, hook);
    }

    pub fn setTransitions(self: *Machine, transitions: []const TransitionSpec) !void {
        var it = self.transitions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.transitions.clearRetainingCapacity();

        for (transitions) |spec| {
            var list = std.ArrayList(imap.ConnState).empty;
            errdefer list.deinit(self.allocator);
            try list.appendSlice(self.allocator, spec.allowed);
            try self.transitions.put(spec.from, list);
        }
    }

    pub fn addTransition(self: *Machine, from: imap.ConnState, to: imap.ConnState) !void {
        const entry = try self.transitions.getOrPut(from);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        for (entry.value_ptr.items) |existing| {
            if (existing == to) return;
        }
        try entry.value_ptr.append(self.allocator, to);
    }

    pub fn canTransitionFromCurrent(self: *const Machine, target: imap.ConnState) bool {
        return self.canTransition(self.state, target);
    }

    fn canTransition(self: *const Machine, from: imap.ConnState, to: imap.ConnState) bool {
        const allowed = self.transitions.get(from) orelse return false;
        for (allowed.items) |state| {
            if (state == to) return true;
        }
        return false;
    }

    fn setDefaultTransitions(self: *Machine) !void {
        try self.setTransitions(&defaultTransitions());
    }
};

pub const TransitionSpec = struct {
    from: imap.ConnState,
    allowed: []const imap.ConnState,
};

pub fn defaultTransitions() [3]TransitionSpec {
    return .{
        .{
            .from = .not_authenticated,
            .allowed = &.{ .authenticated, .logout },
        },
        .{
            .from = .authenticated,
            .allowed = &.{ .selected, .logout, .not_authenticated },
        },
        .{
            .from = .selected,
            .allowed = &.{ .authenticated, .selected, .logout },
        },
    };
}

pub fn commandAllowedStates(command: []const u8) []const imap.ConnState {
    if (eqAny(command, &.{ "CAPABILITY", "NOOP", "LOGOUT" })) {
        return &.{ .not_authenticated, .authenticated, .selected };
    }
    if (eqAny(command, &.{ "STARTTLS", "AUTHENTICATE", "LOGIN" })) {
        return &.{.not_authenticated};
    }
    if (eqAny(command, &.{ "ENABLE", "SELECT", "EXAMINE", "CREATE", "DELETE", "RENAME", "SUBSCRIBE", "UNSUBSCRIBE", "LIST", "LSUB", "NAMESPACE", "STATUS", "APPEND", "IDLE", "ID", "GETACL", "SETACL", "DELETEACL", "LISTRIGHTS", "MYRIGHTS", "GETQUOTA", "SETQUOTA", "GETQUOTAROOT", "GETMETADATA", "SETMETADATA", "COMPRESS", "UNAUTHENTICATE" })) {
        return &.{ .authenticated, .selected };
    }
    if (eqAny(command, &.{ "CLOSE", "UNSELECT", "EXPUNGE", "SEARCH", "FETCH", "STORE", "COPY", "MOVE", "SORT", "THREAD", "REPLACE", "UID" })) {
        return &.{.selected};
    }
    return &.{};
}

fn eqAny(value: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(value, candidate)) return true;
    }
    return false;
}
