const std = @import("std");
const imap = @import("../root.zig");

pub const Message = struct {
    uid: imap.UID,
    internal_date_unix: u64,
    body: []u8,
    flags: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        for (self.flags.items) |flag| allocator.free(flag);
        self.flags.deinit(allocator);
        allocator.free(self.body);
    }

    pub fn hasFlag(self: *const Message, flag: []const u8) bool {
        for (self.flags.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, flag)) return true;
        }
        return false;
    }

    pub fn addFlag(self: *Message, allocator: std.mem.Allocator, flag: []const u8) !void {
        if (self.hasFlag(flag)) return;
        try self.flags.append(allocator, try allocator.dupe(u8, flag));
    }

    pub fn removeFlag(self: *Message, allocator: std.mem.Allocator, flag: []const u8) bool {
        for (self.flags.items, 0..) |existing, index| {
            if (std.ascii.eqlIgnoreCase(existing, flag)) {
                allocator.free(existing);
                _ = self.flags.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn replaceFlags(self: *Message, allocator: std.mem.Allocator, flags: []const []const u8) !void {
        for (self.flags.items) |flag| allocator.free(flag);
        self.flags.clearRetainingCapacity();
        for (flags) |flag| {
            try self.flags.append(allocator, try allocator.dupe(u8, flag));
        }
    }
};

pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    subscribed: bool = false,
    uid_validity: u32,
    next_uid: imap.UID = 1,
    messages: std.ArrayList(Message) = .empty,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, uid_validity: u32) !*Mailbox {
        const mailbox = try allocator.create(Mailbox);
        mailbox.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .uid_validity = uid_validity,
        };
        return mailbox;
    }

    pub fn deinit(self: *Mailbox) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn appendMessage(self: *Mailbox, bytes: []const u8, flags: []const []const u8, internal_date_unix: ?u64) !imap.UID {
        var message = Message{
            .uid = self.next_uid,
            .internal_date_unix = internal_date_unix orelse @as(u64, @intCast(@divTrunc(std.time.milliTimestamp(), 1000))),
            .body = try self.allocator.dupe(u8, bytes),
        };
        for (flags) |flag| {
            try message.addFlag(self.allocator, flag);
        }
        try self.messages.append(self.allocator, message);
        self.next_uid += 1;
        return message.uid;
    }

    pub fn firstUnseenSeq(self: *const Mailbox) ?u32 {
        for (self.messages.items, 0..) |message, index| {
            if (!message.hasFlag(imap.flags.seen)) return @as(u32, @intCast(index + 1));
        }
        return null;
    }

    pub fn countRecent(self: *const Mailbox) u32 {
        var count: u32 = 0;
        for (self.messages.items) |message| {
            if (message.hasFlag(imap.flags.recent)) count += 1;
        }
        return count;
    }

    pub fn standardFlags(_: *const Mailbox) []const []const u8 {
        return &.{
            imap.flags.seen,
            imap.flags.answered,
            imap.flags.flagged,
            imap.flags.deleted,
            imap.flags.draft,
        };
    }
};

pub const User = struct {
    allocator: std.mem.Allocator,
    username: []u8,
    password: []u8,
    mailboxes: std.StringHashMap(*Mailbox),

    pub fn init(allocator: std.mem.Allocator, username: []const u8, password: []const u8, uid_seed: *u32) !*User {
        const user = try allocator.create(User);
        user.* = .{
            .allocator = allocator,
            .username = try allocator.dupe(u8, username),
            .password = try allocator.dupe(u8, password),
            .mailboxes = std.StringHashMap(*Mailbox).init(allocator),
        };
        try user.createMailbox("INBOX", uid_seed);
        return user;
    }

    pub fn deinit(self: *User) void {
        var it = self.mailboxes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.mailboxes.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        self.allocator.destroy(self);
    }

    pub fn createMailbox(self: *User, name: []const u8, uid_seed: *u32) !void {
        if (self.mailboxes.contains(name)) return error.MailboxAlreadyExists;
        const mailbox = try Mailbox.init(self.allocator, name, uid_seed.*);
        uid_seed.* += 1;
        try self.mailboxes.put(mailbox.name, mailbox);
    }

    pub fn deleteMailbox(self: *User, name: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(name, "INBOX")) return error.CannotDeleteInbox;
        const mailbox = self.mailboxes.fetchRemove(name) orelse return error.NoSuchMailbox;
        mailbox.value.deinit();
    }

    pub fn renameMailbox(self: *User, old_name: []const u8, new_name: []const u8) !void {
        if (self.mailboxes.contains(new_name)) return error.MailboxAlreadyExists;
        const mailbox = self.mailboxes.fetchRemove(old_name) orelse return error.NoSuchMailbox;
        self.allocator.free(mailbox.value.name);
        mailbox.value.name = try self.allocator.dupe(u8, new_name);
        try self.mailboxes.put(mailbox.value.name, mailbox.value);
    }

    pub fn getMailbox(self: *User, name: []const u8) ?*Mailbox {
        return self.mailboxes.get(name);
    }
};

pub const MemStore = struct {
    allocator: std.mem.Allocator,
    users: std.StringHashMap(*User),
    next_uid_validity: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) MemStore {
        return .{
            .allocator = allocator,
            .users = std.StringHashMap(*User).init(allocator),
        };
    }

    pub fn deinit(self: *MemStore) void {
        var it = self.users.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.users.deinit();
    }

    pub fn addUser(self: *MemStore, username: []const u8, password: []const u8) !void {
        if (self.users.contains(username)) {
            const user = self.users.get(username).?;
            self.allocator.free(user.password);
            user.password = try self.allocator.dupe(u8, password);
            return;
        }
        const user = try User.init(self.allocator, username, password, &self.next_uid_validity);
        try self.users.put(user.username, user);
    }

    pub fn authenticate(self: *MemStore, username: []const u8, password: []const u8) !*User {
        const user = self.users.get(username) orelse return error.InvalidCredentials;
        if (!std.mem.eql(u8, user.password, password)) return error.InvalidCredentials;
        return user;
    }

    pub fn authenticateExternal(self: *MemStore, username: []const u8) !*User {
        return self.users.get(username) orelse error.InvalidCredentials;
    }
};

pub fn matchesPattern(name: []const u8, pattern: []const u8) bool {
    return matchPatternRec(name, pattern);
}

fn matchPatternRec(name: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;

    return switch (pattern[0]) {
        '*' => blk: {
            var i: usize = 0;
            while (i <= name.len) : (i += 1) {
                if (matchPatternRec(name[i..], pattern[1..])) break :blk true;
            }
            break :blk false;
        },
        '%' => blk: {
            var i: usize = 0;
            while (i <= name.len and (i == name.len or name[i] != '/')) : (i += 1) {
                if (matchPatternRec(name[i..], pattern[1..])) break :blk true;
            }
            break :blk false;
        },
        else => {
            if (name.len == 0) return false;
            return std.ascii.toUpper(name[0]) == std.ascii.toUpper(pattern[0]) and matchPatternRec(name[1..], pattern[1..]);
        },
    };
}
