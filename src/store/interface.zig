const std = @import("std");
const memstore = @import("memstore.zig");
const fsstore = @import("fsstore.zig");

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
};

const MailboxVTable = struct {
    deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    name: *const fn (ctx: *anyopaque) []const u8,
    append_message: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, message: []const u8) anyerror!void,
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
