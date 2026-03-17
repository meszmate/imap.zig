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
    acl: std.StringHashMap([]u8),
    metadata: std.StringHashMap(?[]u8),

    pub fn init(allocator: std.mem.Allocator, name: []const u8, uid_validity: u32) !*Mailbox {
        const mailbox = try allocator.create(Mailbox);
        mailbox.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .uid_validity = uid_validity,
            .acl = std.StringHashMap([]u8).init(allocator),
            .metadata = std.StringHashMap(?[]u8).init(allocator),
        };
        return mailbox;
    }

    pub fn deinit(self: *Mailbox) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        var acl_it = self.acl.iterator();
        while (acl_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.acl.deinit();
        var metadata_it = self.metadata.iterator();
        while (metadata_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |value| self.allocator.free(value);
        }
        self.metadata.deinit();
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

    pub fn setAcl(self: *Mailbox, identifier: []const u8, rights: []const u8) !void {
        const entry = try self.acl.getOrPut(identifier);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, identifier);
        } else {
            self.allocator.free(entry.value_ptr.*);
        }
        entry.value_ptr.* = try self.allocator.dupe(u8, rights);
    }

    pub fn deleteAcl(self: *Mailbox, identifier: []const u8) bool {
        const removed = self.acl.fetchRemove(identifier) orelse return false;
        self.allocator.free(removed.key);
        self.allocator.free(removed.value);
        return true;
    }

    pub fn getRights(self: *const Mailbox, owner_username: []const u8, identifier: []const u8) []const u8 {
        if (std.mem.eql(u8, owner_username, identifier)) return "lrswipdkxtea";
        return self.acl.get(identifier) orelse "";
    }

    pub fn setMetadata(self: *Mailbox, entry_name: []const u8, value: ?[]const u8) !void {
        const entry = try self.metadata.getOrPut(entry_name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, entry_name);
        } else if (entry.value_ptr.*) |existing| {
            self.allocator.free(existing);
        }
        entry.value_ptr.* = if (value) |present| try self.allocator.dupe(u8, present) else null;
    }

    pub fn removeMetadata(self: *Mailbox, entry_name: []const u8) bool {
        const removed = self.metadata.fetchRemove(entry_name) orelse return false;
        self.allocator.free(removed.key);
        if (removed.value) |value| self.allocator.free(value);
        return true;
    }
};

pub const User = struct {
    allocator: std.mem.Allocator,
    username: []u8,
    password: []u8,
    mailboxes: std.StringHashMap(*Mailbox),
    quota_root: []u8,
    quota_storage_limit: u64 = 1_048_576,
    quota_message_limit: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, username: []const u8, password: []const u8, uid_seed: *u32) !*User {
        const user = try allocator.create(User);
        user.* = .{
            .allocator = allocator,
            .username = try allocator.dupe(u8, username),
            .password = try allocator.dupe(u8, password),
            .mailboxes = std.StringHashMap(*Mailbox).init(allocator),
            .quota_root = try allocator.dupe(u8, ""),
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
        self.allocator.free(self.quota_root);
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

    pub fn quotaStorageUsage(self: *const User) u64 {
        var total: u64 = 0;
        var it = self.mailboxes.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*.messages.items) |message| total += message.body.len;
        }
        return total;
    }

    pub fn quotaMessageUsage(self: *const User) u64 {
        var total: u64 = 0;
        var it = self.mailboxes.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.*.messages.items.len;
        }
        return total;
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
