const std = @import("std");
const imap = @import("../root.zig");

pub const UpdateKind = enum {
    exists,
    expunge,
    flags,
};

pub const Update = struct {
    kind: UpdateKind,
    seq_num: u32 = 0,
    num_messages: u32 = 0,
    flags: []const []const u8 = &.{},
};

/// SessionTracker tracks pending updates for a single session/connection.
pub const SessionTracker = struct {
    allocator: std.mem.Allocator,
    mailbox: ?*MailboxTracker = null,
    updates: std.ArrayList(Update) = .empty,

    pub fn init(allocator: std.mem.Allocator) SessionTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SessionTracker) void {
        self.unselectMailbox();
        self.updates.deinit(self.allocator);
    }

    pub fn selectMailbox(self: *SessionTracker, tracker: *MailboxTracker) void {
        self.unselectMailbox();
        self.mailbox = tracker;
        tracker.addSession(self);
    }

    pub fn unselectMailbox(self: *SessionTracker) void {
        if (self.mailbox) |tracker| {
            tracker.removeSession(self);
            self.mailbox = null;
        }
        for (self.updates.items) |update| {
            for (update.flags) |flag| self.allocator.free(flag);
        }
        self.updates.clearRetainingCapacity();
    }

    pub fn queueUpdate(self: *SessionTracker, update: Update) !void {
        try self.updates.append(self.allocator, update);
    }

    pub fn hasPendingUpdates(self: *const SessionTracker) bool {
        return self.updates.items.len > 0;
    }

    /// Flush pending updates through a writer (UpdateWriter).
    /// Returns the number of updates flushed.
    pub fn flush(self: *SessionTracker, transport: anytype, allow_expunge: bool) !u32 {
        var flushed: u32 = 0;
        var index: usize = 0;
        while (index < self.updates.items.len) {
            const update = self.updates.items[index];
            switch (update.kind) {
                .exists => {
                    try transport.print("* {d} EXISTS\r\n", .{update.num_messages});
                    flushed += 1;
                    _ = self.updates.orderedRemove(index);
                },
                .expunge => {
                    if (allow_expunge) {
                        try transport.print("* {d} EXPUNGE\r\n", .{update.seq_num});
                        flushed += 1;
                        _ = self.updates.orderedRemove(index);
                    } else {
                        index += 1;
                    }
                },
                .flags => {
                    try transport.print("* {d} FETCH (FLAGS (", .{update.seq_num});
                    for (update.flags, 0..) |flag, fi| {
                        if (fi != 0) try transport.writeAll(" ");
                        try transport.writeAll(flag);
                    }
                    try transport.writeAll("))\r\n");
                    for (update.flags) |flag| self.allocator.free(flag);
                    flushed += 1;
                    _ = self.updates.orderedRemove(index);
                },
            }
        }
        return flushed;
    }
};

/// MailboxTracker tracks a mailbox across multiple sessions for update notifications.
pub const MailboxTracker = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    num_messages: u32 = 0,
    uid_next: imap.UID = 1,
    uid_validity: u32 = 0,
    sessions: std.ArrayList(*SessionTracker) = .empty,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, uid_validity: u32) !*MailboxTracker {
        const tracker = try allocator.create(MailboxTracker);
        tracker.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .uid_validity = uid_validity,
        };
        return tracker;
    }

    pub fn deinit(self: *MailboxTracker) void {
        self.sessions.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn addSession(self: *MailboxTracker, session: *SessionTracker) void {
        self.sessions.append(self.allocator, session) catch {};
    }

    pub fn removeSession(self: *MailboxTracker, session: *SessionTracker) void {
        for (self.sessions.items, 0..) |s, index| {
            if (s == session) {
                _ = self.sessions.swapRemove(index);
                return;
            }
        }
    }

    pub fn queueNewMessage(self: *MailboxTracker) void {
        self.num_messages += 1;
        for (self.sessions.items) |session| {
            session.queueUpdate(.{ .kind = .exists, .num_messages = self.num_messages }) catch {};
        }
    }

    pub fn queueExpunge(self: *MailboxTracker, seq_num: u32) void {
        if (self.num_messages > 0) self.num_messages -= 1;
        for (self.sessions.items) |session| {
            session.queueUpdate(.{ .kind = .expunge, .seq_num = seq_num }) catch {};
        }
    }

    pub fn queueFlagsUpdate(self: *MailboxTracker, seq_num: u32, flags: []const []const u8) void {
        for (self.sessions.items) |session| {
            const duped = session.allocator.alloc([]const u8, flags.len) catch continue;
            var populated: usize = 0;
            for (flags) |flag| {
                duped[populated] = session.allocator.dupe(u8, flag) catch {
                    for (duped[0..populated]) |d| session.allocator.free(d);
                    session.allocator.free(duped);
                    break;
                };
                populated += 1;
            }
            if (populated == flags.len) {
                session.queueUpdate(.{ .kind = .flags, .seq_num = seq_num, .flags = duped }) catch {
                    for (duped) |d| session.allocator.free(d);
                    session.allocator.free(duped);
                };
            }
        }
    }
};
