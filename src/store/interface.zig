const std = @import("std");
const memstore = @import("memstore.zig");
const fsstore = @import("fsstore.zig");

pub const MailboxInfo = struct {
    flags: []const []const u8 = &.{},
    permanent_flags: []const []const u8 = &.{},
    num_messages: u32 = 0,
    num_recent: u32 = 0,
    uid_next: u32 = 1,
    uid_validity: u32 = 0,
    first_unseen: ?u32 = null,
    read_only: bool = false,
};

pub const MessageData = struct {
    uid: u32 = 0,
    flags: [][]u8 = &.{},
    internal_date_unix: u64 = 0,
    size: u64 = 0,
    body: []u8 = &.{},
};

pub const CopyResult = struct {
    uid_validity: u32 = 0,
    source_uids: []u32 = &.{},
    dest_uids: []u32 = &.{},
};

/// Simplified search parameters for the store interface.
pub const SearchParams = struct {
    all: bool = true,
    seen: ?bool = null,
    answered: ?bool = null,
    flagged: ?bool = null,
    deleted: ?bool = null,
    draft: ?bool = null,
    subject: ?[]const u8 = null,
    body: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    since_unix: ?u64 = null,
    before_unix: ?u64 = null,
    larger: ?u64 = null,
    smaller: ?u64 = null,
};

/// Store flag action constants (match imap StoreAction).
pub const FLAG_ACTION_SET: u8 = 0;
pub const FLAG_ACTION_ADD: u8 = 1;
pub const FLAG_ACTION_REMOVE: u8 = 2;

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const BackendVTable,

    pub fn fromMemStore(store: *memstore.MemStore) Backend {
        return .{
            .ctx = store,
            .vtable = &mem_backend_vtable,
        };
    }

    pub fn fromFsStore(store: *fsstore.FsStore) Backend {
        return .{
            .ctx = store,
            .vtable = &fs_backend_vtable,
        };
    }

    pub fn addUser(self: Backend, username: []const u8, password: []const u8) !void {
        const add_user = self.vtable.add_user orelse return error.UnsupportedOperation;
        return add_user(self.ctx, username, password);
    }

    pub fn authenticate(self: Backend, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !User {
        return self.vtable.authenticate(self.ctx, allocator, username, password);
    }

    pub fn authenticateExternal(self: Backend, allocator: std.mem.Allocator, username: []const u8) !User {
        const authenticate_external = self.vtable.authenticate_external orelse return error.UnsupportedOperation;
        return authenticate_external(self.ctx, allocator, username);
    }
};

pub const User = struct {
    ctx: *anyopaque,
    vtable: *const UserVTable,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *User) void {
        self.vtable.deinit(self.ctx, self.allocator);
        self.* = undefined;
    }

    pub fn username(self: *const User) []const u8 {
        return self.vtable.username(self.ctx);
    }

    pub fn listMailboxesAlloc(self: *User) ![][]u8 {
        return self.vtable.list_mailboxes(self.ctx, self.allocator);
    }

    pub fn createMailbox(self: *User, name: []const u8) !void {
        const create_mailbox = self.vtable.create_mailbox orelse return error.UnsupportedOperation;
        return create_mailbox(self.ctx, self.allocator, name);
    }

    pub fn deleteMailbox(self: *User, name: []const u8) !void {
        const delete_mailbox = self.vtable.delete_mailbox orelse return error.UnsupportedOperation;
        return delete_mailbox(self.ctx, self.allocator, name);
    }

    pub fn renameMailbox(self: *User, old_name: []const u8, new_name: []const u8) !void {
        const rename_mailbox = self.vtable.rename_mailbox orelse return error.UnsupportedOperation;
        return rename_mailbox(self.ctx, self.allocator, old_name, new_name);
    }

    pub fn appendMessage(self: *User, mailbox: []const u8, message: []const u8) !void {
        const append_message = self.vtable.append_message orelse return error.UnsupportedOperation;
        return append_message(self.ctx, self.allocator, mailbox, message);
    }

    pub fn openMailbox(self: *User, name: []const u8) !Mailbox {
        const open_mailbox = self.vtable.open_mailbox orelse return error.UnsupportedOperation;
        return open_mailbox(self.ctx, self.allocator, name);
    }

    pub fn subscribeMailbox(self: *User, name: []const u8) !void {
        const sub_fn = self.vtable.subscribe_mailbox orelse return error.UnsupportedOperation;
        return sub_fn(self.ctx, self.allocator, name);
    }

    pub fn unsubscribeMailbox(self: *User, name: []const u8) !void {
        const unsub_fn = self.vtable.unsubscribe_mailbox orelse return error.UnsupportedOperation;
        return unsub_fn(self.ctx, self.allocator, name);
    }

    pub fn getMailboxStatus(self: *User, name: []const u8) !MailboxInfo {
        const status_fn = self.vtable.get_mailbox_status orelse return error.UnsupportedOperation;
        return status_fn(self.ctx, self.allocator, name);
    }
};

pub const Mailbox = struct {
    ctx: *anyopaque,
    vtable: *const MailboxVTable,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Mailbox) void {
        self.vtable.deinit(self.ctx, self.allocator);
        self.* = undefined;
    }

    pub fn name(self: *const Mailbox) []const u8 {
        return self.vtable.name(self.ctx);
    }

    pub fn appendMessage(self: *Mailbox, message: []const u8) !void {
        return self.vtable.append_message(self.ctx, self.allocator, message);
    }

    pub fn info(self: *Mailbox) !MailboxInfo {
        const info_fn = self.vtable.info orelse return error.UnsupportedOperation;
        return info_fn(self.ctx, self.allocator);
    }

    pub fn getMessages(self: *Mailbox, uids: []const u32) ![]MessageData {
        const get_fn = self.vtable.get_messages orelse return error.UnsupportedOperation;
        return get_fn(self.ctx, self.allocator, uids);
    }

    pub fn setFlags(self: *Mailbox, uids: []const u32, action: u8, flags: []const []const u8) !void {
        const set_fn = self.vtable.set_flags orelse return error.UnsupportedOperation;
        return set_fn(self.ctx, self.allocator, uids, action, flags);
    }

    pub fn copyMessages(self: *Mailbox, uids: []const u32, dest_name: []const u8) !CopyResult {
        const copy_fn = self.vtable.copy_messages orelse return error.UnsupportedOperation;
        return copy_fn(self.ctx, self.allocator, uids, dest_name);
    }

    pub fn expungeMessages(self: *Mailbox, uid_set: ?[]const u32) ![]u32 {
        const expunge_fn = self.vtable.expunge orelse return error.UnsupportedOperation;
        return expunge_fn(self.ctx, self.allocator, uid_set);
    }

    pub fn searchMessages(self: *Mailbox, criteria: *const SearchParams) ![]u32 {
        const search_fn = self.vtable.search_messages orelse return error.UnsupportedOperation;
        return search_fn(self.ctx, self.allocator, criteria);
    }

    pub fn listUids(self: *Mailbox) ![]u32 {
        const list_fn = self.vtable.list_uids orelse return error.UnsupportedOperation;
        return list_fn(self.ctx, self.allocator);
    }

    pub fn moveMessages(self: *Mailbox, uids: []const u32, dest_name: []const u8) !CopyResult {
        const move_fn = self.vtable.move_messages orelse return error.UnsupportedOperation;
        return move_fn(self.ctx, self.allocator, uids, dest_name);
    }

    pub fn freeMessageData(self: *Mailbox, data: []MessageData) void {
        for (data) |*msg| {
            for (msg.flags) |flag| self.allocator.free(flag);
            if (msg.flags.len > 0) self.allocator.free(msg.flags);
            if (msg.body.len > 0) self.allocator.free(msg.body);
        }
        self.allocator.free(data);
    }
};

const BackendVTable = struct {
    authenticate: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, username: []const u8, password: []const u8) anyerror!User,
    authenticate_external: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, username: []const u8) anyerror!User = null,
    add_user: ?*const fn (ctx: *anyopaque, username: []const u8, password: []const u8) anyerror!void = null,
};

const UserVTable = struct {
    deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    username: *const fn (ctx: *anyopaque) []const u8,
    list_mailboxes: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![][]u8,
    create_mailbox: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void = null,
    delete_mailbox: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void = null,
    rename_mailbox: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, old_name: []const u8, new_name: []const u8) anyerror!void = null,
    append_message: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, mailbox: []const u8, message: []const u8) anyerror!void = null,
    open_mailbox: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!Mailbox = null,
    subscribe_mailbox: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void = null,
    unsubscribe_mailbox: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void = null,
    get_mailbox_status: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!MailboxInfo = null,
};

const MailboxVTable = struct {
    deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    name: *const fn (ctx: *anyopaque) []const u8,
    append_message: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, message: []const u8) anyerror!void,
    info: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!MailboxInfo = null,
    get_messages: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, uids: []const u32) anyerror![]MessageData = null,
    set_flags: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, uids: []const u32, action: u8, flags: []const []const u8) anyerror!void = null,
    copy_messages: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, uids: []const u32, dest_name: []const u8) anyerror!CopyResult = null,
    expunge: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, uid_set: ?[]const u32) anyerror![]u32 = null,
    search_messages: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, criteria: *const SearchParams) anyerror![]u32 = null,
    list_uids: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u32 = null,
    move_messages: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator, uids: []const u32, dest_name: []const u8) anyerror!CopyResult = null,
};

const MemUserAdapter = struct {
    user: *memstore.User,
    uid_seed: *u32,
};

const MemMailboxAdapter = struct {
    mailbox: *memstore.Mailbox,
};

const FsUserAdapter = struct {
    store: *fsstore.FsStore,
    user: fsstore.FsUser,
};

const FsMailboxAdapter = struct {
    store: *fsstore.FsStore,
    username: []u8,
    mailbox_name: []u8,
};

const mem_backend_vtable = BackendVTable{
    .authenticate = memAuthenticate,
    .authenticate_external = memAuthenticateExternal,
    .add_user = memAddUser,
};

const fs_backend_vtable = BackendVTable{
    .authenticate = fsAuthenticate,
    .add_user = fsAddUser,
};

const mem_user_vtable = UserVTable{
    .deinit = memUserDeinit,
    .username = memUserUsername,
    .list_mailboxes = memListMailboxes,
    .create_mailbox = memCreateMailbox,
    .delete_mailbox = memDeleteMailbox,
    .rename_mailbox = memRenameMailbox,
    .append_message = memAppendMessage,
    .open_mailbox = memOpenMailbox,
    .subscribe_mailbox = memSubscribeMailbox,
    .unsubscribe_mailbox = memUnsubscribeMailbox,
    .get_mailbox_status = memGetMailboxStatus,
};

const fs_user_vtable = UserVTable{
    .deinit = fsUserDeinit,
    .username = fsUserUsername,
    .list_mailboxes = fsListMailboxes,
    .create_mailbox = fsCreateMailbox,
    .delete_mailbox = fsDeleteMailbox,
    .rename_mailbox = fsRenameMailbox,
    .append_message = fsAppendMessage,
    .open_mailbox = fsOpenMailbox,
};

const mem_mailbox_vtable = MailboxVTable{
    .deinit = memMailboxDeinit,
    .name = memMailboxName,
    .append_message = memMailboxAppendMessage,
    .info = memMailboxInfo,
    .get_messages = memMailboxGetMessages,
    .set_flags = memMailboxSetFlags,
    .expunge = memMailboxExpunge,
    .search_messages = memMailboxSearch,
    .list_uids = memMailboxListUids,
};

const fs_mailbox_vtable = MailboxVTable{
    .deinit = fsMailboxDeinit,
    .name = fsMailboxName,
    .append_message = fsMailboxAppendMessage,
};

fn memAddUser(ctx: *anyopaque, username: []const u8, password: []const u8) !void {
    const store: *memstore.MemStore = @ptrCast(@alignCast(ctx));
    return store.addUser(username, password);
}

fn memAuthenticate(ctx: *anyopaque, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !User {
    const store: *memstore.MemStore = @ptrCast(@alignCast(ctx));
    const adapter = try allocator.create(MemUserAdapter);
    errdefer allocator.destroy(adapter);
    adapter.* = .{
        .user = try store.authenticate(username, password),
        .uid_seed = &store.next_uid_validity,
    };
    return .{
        .ctx = adapter,
        .vtable = &mem_user_vtable,
        .allocator = allocator,
    };
}

fn memAuthenticateExternal(ctx: *anyopaque, allocator: std.mem.Allocator, username: []const u8) !User {
    const store: *memstore.MemStore = @ptrCast(@alignCast(ctx));
    const adapter = try allocator.create(MemUserAdapter);
    errdefer allocator.destroy(adapter);
    adapter.* = .{
        .user = try store.authenticateExternal(username),
        .uid_seed = &store.next_uid_validity,
    };
    return .{
        .ctx = adapter,
        .vtable = &mem_user_vtable,
        .allocator = allocator,
    };
}

fn memUserDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    allocator.destroy(adapter);
}

fn memUserUsername(ctx: *anyopaque) []const u8 {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.user.username;
}

fn memListMailboxes(ctx: *anyopaque, allocator: std.mem.Allocator) ![][]u8 {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    var it = adapter.user.mailboxes.iterator();
    while (it.next()) |entry| {
        try list.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
    }
    return list.toOwnedSlice(allocator);
}

fn memCreateMailbox(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !void {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.user.createMailbox(name, adapter.uid_seed);
}

fn memDeleteMailbox(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !void {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.user.deleteMailbox(name);
}

fn memRenameMailbox(ctx: *anyopaque, _: std.mem.Allocator, old_name: []const u8, new_name: []const u8) !void {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.user.renameMailbox(old_name, new_name);
}

fn memAppendMessage(ctx: *anyopaque, _: std.mem.Allocator, mailbox_name: []const u8, message: []const u8) !void {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    const mailbox = adapter.user.getMailbox(mailbox_name) orelse return error.NoSuchMailbox;
    _ = try mailbox.appendMessage(message, &.{}, null);
}

fn memOpenMailbox(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !Mailbox {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    const mailbox = adapter.user.getMailbox(name) orelse return error.NoSuchMailbox;
    const mailbox_adapter = try allocator.create(MemMailboxAdapter);
    errdefer allocator.destroy(mailbox_adapter);
    mailbox_adapter.* = .{ .mailbox = mailbox };
    return .{
        .ctx = mailbox_adapter,
        .vtable = &mem_mailbox_vtable,
        .allocator = allocator,
    };
}

fn memMailboxDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const adapter: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    allocator.destroy(adapter);
}

fn memMailboxName(ctx: *anyopaque) []const u8 {
    const adapter: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    return adapter.mailbox.name;
}

fn memMailboxAppendMessage(ctx: *anyopaque, _: std.mem.Allocator, message: []const u8) !void {
    const adapter: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    _ = try adapter.mailbox.appendMessage(message, &.{}, null);
}

fn memMailboxInfo(ctx: *anyopaque, _: std.mem.Allocator) !MailboxInfo {
    const a: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    const mb = a.mailbox;
    return .{
        .flags = mb.standardFlags(),
        .permanent_flags = mb.standardFlags(),
        .num_messages = @intCast(mb.messages.items.len),
        .num_recent = mb.countRecent(),
        .uid_next = mb.next_uid,
        .uid_validity = mb.uid_validity,
        .first_unseen = mb.firstUnseenSeq(),
    };
}

fn memMailboxGetMessages(ctx: *anyopaque, allocator: std.mem.Allocator, uids: []const u32) ![]MessageData {
    const a: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    const mb = a.mailbox;
    var out: std.ArrayList(MessageData) = .empty;
    errdefer {
        for (out.items) |*msg| {
            for (msg.flags) |flag| allocator.free(flag);
            if (msg.flags.len > 0) allocator.free(msg.flags);
            if (msg.body.len > 0) allocator.free(msg.body);
        }
        out.deinit(allocator);
    }
    for (uids) |uid| {
        for (mb.messages.items) |message| {
            if (message.uid == uid) {
                var flag_copies = try allocator.alloc([]u8, message.flags.items.len);
                var populated: usize = 0;
                errdefer {
                    for (flag_copies[0..populated]) |f| allocator.free(f);
                    allocator.free(flag_copies);
                }
                for (message.flags.items, 0..) |flag, fi| {
                    flag_copies[fi] = try allocator.dupe(u8, flag);
                    populated += 1;
                }
                try out.append(allocator, .{
                    .uid = message.uid,
                    .flags = flag_copies,
                    .internal_date_unix = message.internal_date_unix,
                    .size = message.body.len,
                    .body = try allocator.dupe(u8, message.body),
                });
                break;
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

fn memMailboxSetFlags(ctx: *anyopaque, _: std.mem.Allocator, uids: []const u32, action: u8, flags: []const []const u8) !void {
    const a: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    const mb = a.mailbox;
    for (mb.messages.items) |*message| {
        var found = false;
        for (uids) |uid| {
            if (message.uid == uid) {
                found = true;
                break;
            }
        }
        if (!found) continue;
        switch (action) {
            FLAG_ACTION_SET => try message.replaceFlags(mb.allocator, flags),
            FLAG_ACTION_ADD => {
                for (flags) |flag| try message.addFlag(mb.allocator, flag);
            },
            FLAG_ACTION_REMOVE => {
                for (flags) |flag| _ = message.removeFlag(mb.allocator, flag);
            },
            else => {},
        }
    }
}

fn memMailboxCopyMessages(ctx: *anyopaque, allocator: std.mem.Allocator, uids: []const u32, dest_name: []const u8) !CopyResult {
    const a: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    _ = a;
    _ = allocator;
    _ = uids;
    _ = dest_name;
    return error.UnsupportedOperation;
}

fn memMailboxExpunge(ctx: *anyopaque, allocator: std.mem.Allocator, uid_set: ?[]const u32) ![]u32 {
    const a: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    const mb = a.mailbox;
    var expunged: std.ArrayList(u32) = .empty;
    errdefer expunged.deinit(allocator);
    var index: usize = 0;
    while (index < mb.messages.items.len) {
        const msg = &mb.messages.items[index];
        if (!msg.hasFlag("\\Deleted")) {
            index += 1;
            continue;
        }
        if (uid_set) |uids| {
            var in_set = false;
            for (uids) |uid| {
                if (msg.uid == uid) {
                    in_set = true;
                    break;
                }
            }
            if (!in_set) {
                index += 1;
                continue;
            }
        }
        try expunged.append(allocator, @intCast(index + 1));
        msg.deinit(mb.allocator);
        _ = mb.messages.orderedRemove(index);
    }
    return expunged.toOwnedSlice(allocator);
}

fn memMailboxSearch(ctx: *anyopaque, allocator: std.mem.Allocator, criteria: *const SearchParams) ![]u32 {
    const a: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    const mb = a.mailbox;
    var results: std.ArrayList(u32) = .empty;
    errdefer results.deinit(allocator);
    for (mb.messages.items) |message| {
        if (matchesSearchParams(message, criteria)) {
            try results.append(allocator, message.uid);
        }
    }
    return results.toOwnedSlice(allocator);
}

fn memMailboxListUids(ctx: *anyopaque, allocator: std.mem.Allocator) ![]u32 {
    const a: *MemMailboxAdapter = @ptrCast(@alignCast(ctx));
    const mb = a.mailbox;
    var uids = try allocator.alloc(u32, mb.messages.items.len);
    for (mb.messages.items, 0..) |message, index| {
        uids[index] = message.uid;
    }
    return uids;
}

fn matchesSearchParams(message: memstore.Message, criteria: *const SearchParams) bool {
    if (criteria.seen) |seen| {
        if (seen != message.hasFlag("\\Seen")) return false;
    }
    if (criteria.answered) |answered| {
        if (answered != message.hasFlag("\\Answered")) return false;
    }
    if (criteria.flagged) |flagged| {
        if (flagged != message.hasFlag("\\Flagged")) return false;
    }
    if (criteria.deleted) |deleted| {
        if (deleted != message.hasFlag("\\Deleted")) return false;
    }
    if (criteria.draft) |draft| {
        if (draft != message.hasFlag("\\Draft")) return false;
    }
    if (criteria.subject) |subject| {
        if (std.mem.indexOf(u8, message.body, subject) == null) return false;
    }
    if (criteria.body) |body_text| {
        if (std.mem.indexOf(u8, message.body, body_text) == null) return false;
    }
    if (criteria.from) |from| {
        if (std.mem.indexOf(u8, message.body, from) == null) return false;
    }
    if (criteria.to) |to| {
        if (std.mem.indexOf(u8, message.body, to) == null) return false;
    }
    if (criteria.since_unix) |since| {
        if (message.internal_date_unix < since) return false;
    }
    if (criteria.before_unix) |before| {
        if (message.internal_date_unix >= before) return false;
    }
    if (criteria.larger) |larger| {
        if (message.body.len <= larger) return false;
    }
    if (criteria.smaller) |smaller| {
        if (message.body.len >= smaller) return false;
    }
    return true;
}

fn memSubscribeMailbox(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !void {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    const mailbox = adapter.user.getMailbox(name) orelse return error.NoSuchMailbox;
    mailbox.subscribed = true;
}

fn memUnsubscribeMailbox(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !void {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    const mailbox = adapter.user.getMailbox(name) orelse return error.NoSuchMailbox;
    mailbox.subscribed = false;
}

fn memGetMailboxStatus(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !MailboxInfo {
    const adapter: *MemUserAdapter = @ptrCast(@alignCast(ctx));
    const mailbox = adapter.user.getMailbox(name) orelse return error.NoSuchMailbox;
    return .{
        .flags = mailbox.standardFlags(),
        .permanent_flags = mailbox.standardFlags(),
        .num_messages = @intCast(mailbox.messages.items.len),
        .num_recent = mailbox.countRecent(),
        .uid_next = mailbox.next_uid,
        .uid_validity = mailbox.uid_validity,
        .first_unseen = mailbox.firstUnseenSeq(),
    };
}

fn fsAddUser(ctx: *anyopaque, username: []const u8, password: []const u8) !void {
    const store: *fsstore.FsStore = @ptrCast(@alignCast(ctx));
    return store.addUser(username, password);
}

fn fsAuthenticate(ctx: *anyopaque, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !User {
    const store: *fsstore.FsStore = @ptrCast(@alignCast(ctx));
    const adapter = try allocator.create(FsUserAdapter);
    errdefer allocator.destroy(adapter);
    adapter.* = .{
        .store = store,
        .user = try store.authenticate(username, password),
    };
    return .{
        .ctx = adapter,
        .vtable = &fs_user_vtable,
        .allocator = allocator,
    };
}

fn fsUserDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    adapter.user.deinit();
    allocator.destroy(adapter);
}

fn fsUserUsername(ctx: *anyopaque) []const u8 {
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.user.username;
}

fn fsListMailboxes(ctx: *anyopaque, allocator: std.mem.Allocator) ![][]u8 {
    _ = allocator;
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.user.listMailboxesAlloc();
}

fn fsCreateMailbox(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !void {
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.store.createMailbox(adapter.user.username, name);
}

fn fsDeleteMailbox(ctx: *anyopaque, _: std.mem.Allocator, name: []const u8) !void {
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.store.deleteMailbox(adapter.user.username, name);
}

fn fsRenameMailbox(ctx: *anyopaque, _: std.mem.Allocator, old_name: []const u8, new_name: []const u8) !void {
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.store.renameMailbox(adapter.user.username, old_name, new_name);
}

fn fsAppendMessage(ctx: *anyopaque, _: std.mem.Allocator, mailbox: []const u8, message: []const u8) !void {
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    return adapter.user.appendMessage(mailbox, message);
}

fn fsOpenMailbox(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) !Mailbox {
    const adapter: *FsUserAdapter = @ptrCast(@alignCast(ctx));
    if (!adapter.store.mailboxExists(adapter.user.username, name)) return error.NoSuchMailbox;

    const mailbox_adapter = try allocator.create(FsMailboxAdapter);
    errdefer allocator.destroy(mailbox_adapter);
    mailbox_adapter.* = .{
        .store = adapter.store,
        .username = try allocator.dupe(u8, adapter.user.username),
        .mailbox_name = try allocator.dupe(u8, name),
    };
    return .{
        .ctx = mailbox_adapter,
        .vtable = &fs_mailbox_vtable,
        .allocator = allocator,
    };
}

fn fsMailboxDeinit(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const adapter: *FsMailboxAdapter = @ptrCast(@alignCast(ctx));
    allocator.free(adapter.username);
    allocator.free(adapter.mailbox_name);
    allocator.destroy(adapter);
}

fn fsMailboxName(ctx: *anyopaque) []const u8 {
    const adapter: *FsMailboxAdapter = @ptrCast(@alignCast(ctx));
    return adapter.mailbox_name;
}

fn fsMailboxAppendMessage(ctx: *anyopaque, allocator: std.mem.Allocator, message: []const u8) !void {
    _ = allocator;
    const adapter: *FsMailboxAdapter = @ptrCast(@alignCast(ctx));
    var user = fsstore.FsUser{
        .allocator = adapter.store.allocator,
        .root_path = adapter.store.root_path,
        .username = adapter.username,
    };
    return user.appendMessage(adapter.mailbox_name, message);
}
