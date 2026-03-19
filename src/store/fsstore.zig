const std = @import("std");
const imap = @import("../root.zig");

pub const FsStore = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !FsStore {
        var cwd = std.fs.cwd();
        try cwd.makePath(root_path);
        const users_path = try std.fs.path.join(allocator, &.{ root_path, "users" });
        defer allocator.free(users_path);
        try cwd.makePath(users_path);
        return .{
            .allocator = allocator,
            .root_path = try allocator.dupe(u8, root_path),
        };
    }

    pub fn deinit(self: *FsStore) void {
        self.allocator.free(self.root_path);
    }

    pub fn addUser(self: *FsStore, username: []const u8, password: []const u8) !void {
        const user_dir = try self.userDirAlloc(username);
        defer self.allocator.free(user_dir);
        try std.fs.cwd().makePath(user_dir);
        const password_path = try std.fs.path.join(self.allocator, &.{ user_dir, "password.txt" });
        defer self.allocator.free(password_path);
        try writeFileLocal(password_path, password);

        const mailboxes_dir = try std.fs.path.join(self.allocator, &.{ user_dir, "mailboxes" });
        defer self.allocator.free(mailboxes_dir);
        try std.fs.cwd().makePath(mailboxes_dir);
        try self.createMailbox(username, "INBOX");
    }

    pub fn authenticate(self: *FsStore, username: []const u8, password: []const u8) !FsUser {
        const password_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", username, "password.txt" });
        defer self.allocator.free(password_path);
        const actual = try std.fs.cwd().readFileAlloc(self.allocator, password_path, 1024 * 16);
        defer self.allocator.free(actual);
        if (!std.mem.eql(u8, std.mem.trimRight(u8, actual, "\r\n"), password)) return error.InvalidCredentials;
        return .{
            .allocator = self.allocator,
            .root_path = self.root_path,
            .username = try self.allocator.dupe(u8, username),
        };
    }

    pub fn createMailbox(self: *FsStore, username: []const u8, mailbox: []const u8) !void {
        const mailbox_path = try self.mailboxPathAlloc(username, mailbox);
        defer self.allocator.free(mailbox_path);
        if (std.fs.cwd().openFile(mailbox_path, .{})) |file| {
            file.close();
            return error.MailboxAlreadyExists;
        } else |_| {}
        try writeFileLocal(mailbox_path, "");
    }

    pub fn deleteMailbox(self: *FsStore, username: []const u8, mailbox: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(mailbox, "INBOX")) return error.CannotDeleteInbox;
        const mailbox_path = try self.mailboxPathAlloc(username, mailbox);
        defer self.allocator.free(mailbox_path);
        std.fs.cwd().deleteFile(mailbox_path) catch |err| switch (err) {
            error.FileNotFound => return error.NoSuchMailbox,
            else => return err,
        };
    }

    pub fn renameMailbox(self: *FsStore, username: []const u8, old_mailbox: []const u8, new_mailbox: []const u8) !void {
        const old_path = try self.mailboxPathAlloc(username, old_mailbox);
        defer self.allocator.free(old_path);
        const new_path = try self.mailboxPathAlloc(username, new_mailbox);
        defer self.allocator.free(new_path);
        if (self.mailboxExists(username, new_mailbox)) return error.MailboxAlreadyExists;
        std.fs.cwd().rename(old_path, new_path) catch |err| switch (err) {
            error.FileNotFound => return error.NoSuchMailbox,
            else => return err,
        };
    }

    pub fn mailboxExists(self: *FsStore, username: []const u8, mailbox: []const u8) bool {
        const mailbox_path = self.mailboxPathAlloc(username, mailbox) catch return false;
        defer self.allocator.free(mailbox_path);
        if (std.fs.cwd().openFile(mailbox_path, .{})) |file| {
            file.close();
            return true;
        } else |_| {
            return false;
        }
    }

    fn userDirAlloc(self: *FsStore, username: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{ self.root_path, "users", username });
    }

    fn mailboxPathAlloc(self: *FsStore, username: []const u8, mailbox: []const u8) ![]u8 {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.mbox", .{sanitized});
        defer self.allocator.free(file_name);
        return std.fs.path.join(self.allocator, &.{ self.root_path, "users", username, "mailboxes", file_name });
    }
};

pub const FsUser = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    username: []u8,

    pub fn deinit(self: *FsUser) void {
        self.allocator.free(self.username);
    }

    pub fn listMailboxesAlloc(self: *FsUser) ![][]u8 {
        const dir_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes" });
        defer self.allocator.free(dir_path);
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |item| self.allocator.free(item);
            list.deinit(self.allocator);
        }
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            const base = std.fs.path.stem(entry.name);
            try list.append(self.allocator, try desanitizeMailboxAlloc(self.allocator, base));
        }
        return list.toOwnedSlice(self.allocator);
    }

    pub fn appendMessage(self: *FsUser, mailbox: []const u8, message: []const u8) !void {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.mbox", .{sanitized});
        defer self.allocator.free(file_name);
        const path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", file_name });
        defer self.allocator.free(path);
        var file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(message);
        try file.writeAll("\n\n");
    }

    pub fn subscribeMailbox(self: *FsUser, mailbox: []const u8) !void {
        const path = try self.subscriptionPathAlloc(mailbox);
        defer self.allocator.free(path);
        try writeFileLocal(path, "1");
    }

    pub fn unsubscribeMailbox(self: *FsUser, mailbox: []const u8) !void {
        const path = try self.subscriptionPathAlloc(mailbox);
        defer self.allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    }

    pub fn isSubscribed(self: *FsUser, mailbox: []const u8) bool {
        const path = self.subscriptionPathAlloc(mailbox) catch return false;
        defer self.allocator.free(path);
        if (std.fs.cwd().openFile(path, .{})) |file| {
            file.close();
            return true;
        } else |_| return false;
    }

    fn subscriptionPathAlloc(self: *FsUser, mailbox: []const u8) ![]u8 {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const file_name = try std.fmt.allocPrint(self.allocator, "{s}.sub", .{sanitized});
        defer self.allocator.free(file_name);
        return std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", file_name });
    }

    pub fn getMessageCount(self: *FsUser, mailbox: []const u8) !u32 {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}.msgs", .{sanitized});
        defer self.allocator.free(dir_name);
        const dir_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", dir_name });
        defer self.allocator.free(dir_path);
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return 0;
        defer dir.close();
        var count: u32 = 0;
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".eml")) count += 1;
        }
        return count;
    }

    pub fn appendMessageWithUid(self: *FsUser, mailbox: []const u8, message: []const u8, flags: []const []const u8) !u32 {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        // Ensure messages directory exists
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}.msgs", .{sanitized});
        defer self.allocator.free(dir_name);
        const dir_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", dir_name });
        defer self.allocator.free(dir_path);
        try std.fs.cwd().makePath(dir_path);
        // Get next UID (count existing + 1)
        const uid = (try self.getMessageCount(mailbox)) + 1;
        // Write message file
        const msg_name = try std.fmt.allocPrint(self.allocator, "{d}.eml", .{uid});
        defer self.allocator.free(msg_name);
        const msg_path = try std.fs.path.join(self.allocator, &.{ dir_path, msg_name });
        defer self.allocator.free(msg_path);
        try writeFileLocal(msg_path, message);
        // Write flags file
        if (flags.len > 0) {
            const flags_name = try std.fmt.allocPrint(self.allocator, "{d}.flags", .{uid});
            defer self.allocator.free(flags_name);
            const flags_path = try std.fs.path.join(self.allocator, &.{ dir_path, flags_name });
            defer self.allocator.free(flags_path);
            var flag_text: std.ArrayList(u8) = .empty;
            defer flag_text.deinit(self.allocator);
            for (flags, 0..) |flag, i| {
                if (i != 0) try flag_text.append(self.allocator, ' ');
                try flag_text.appendSlice(self.allocator, flag);
            }
            try writeFileLocal(flags_path, flag_text.items);
        }
        return uid;
    }

    pub fn deleteMessage(self: *FsUser, mailbox: []const u8, uid: u32) !void {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}.msgs", .{sanitized});
        defer self.allocator.free(dir_name);
        const dir_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", dir_name });
        defer self.allocator.free(dir_path);
        const msg_name = try std.fmt.allocPrint(self.allocator, "{d}.eml", .{uid});
        defer self.allocator.free(msg_name);
        const msg_path = try std.fs.path.join(self.allocator, &.{ dir_path, msg_name });
        defer self.allocator.free(msg_path);
        std.fs.cwd().deleteFile(msg_path) catch {};
        const flags_name = try std.fmt.allocPrint(self.allocator, "{d}.flags", .{uid});
        defer self.allocator.free(flags_name);
        const flags_path = try std.fs.path.join(self.allocator, &.{ dir_path, flags_name });
        defer self.allocator.free(flags_path);
        std.fs.cwd().deleteFile(flags_path) catch {};
    }

    pub fn readMessageAlloc(self: *FsUser, mailbox: []const u8, uid: u32) ![]u8 {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}.msgs", .{sanitized});
        defer self.allocator.free(dir_name);
        const msg_name = try std.fmt.allocPrint(self.allocator, "{d}.eml", .{uid});
        defer self.allocator.free(msg_name);
        const msg_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", dir_name, msg_name });
        defer self.allocator.free(msg_path);
        return std.fs.cwd().readFileAlloc(self.allocator, msg_path, 1024 * 1024 * 10);
    }

    pub fn readFlagsAlloc(self: *FsUser, mailbox: []const u8, uid: u32) ![]u8 {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}.msgs", .{sanitized});
        defer self.allocator.free(dir_name);
        const flags_name = try std.fmt.allocPrint(self.allocator, "{d}.flags", .{uid});
        defer self.allocator.free(flags_name);
        const flags_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", dir_name, flags_name });
        defer self.allocator.free(flags_path);
        return std.fs.cwd().readFileAlloc(self.allocator, flags_path, 1024 * 64) catch return try self.allocator.dupe(u8, "");
    }

    pub fn writeFlagsAlloc(self: *FsUser, mailbox: []const u8, uid: u32, flags_text: []const u8) !void {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}.msgs", .{sanitized});
        defer self.allocator.free(dir_name);
        const flags_name = try std.fmt.allocPrint(self.allocator, "{d}.flags", .{uid});
        defer self.allocator.free(flags_name);
        const flags_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", dir_name, flags_name });
        defer self.allocator.free(flags_path);
        try writeFileLocal(flags_path, flags_text);
    }

    pub fn listMessageUids(self: *FsUser, mailbox: []const u8) ![]u32 {
        const sanitized = try sanitizeMailboxAlloc(self.allocator, mailbox);
        defer self.allocator.free(sanitized);
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}.msgs", .{sanitized});
        defer self.allocator.free(dir_name);
        const dir_path = try std.fs.path.join(self.allocator, &.{ self.root_path, "users", self.username, "mailboxes", dir_name });
        defer self.allocator.free(dir_path);
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return try self.allocator.alloc(u32, 0);
        defer dir.close();
        var uids: std.ArrayList(u32) = .empty;
        errdefer uids.deinit(self.allocator);
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".eml")) continue;
            const stem = std.fs.path.stem(entry.name);
            const uid = std.fmt.parseInt(u32, stem, 10) catch continue;
            try uids.append(self.allocator, uid);
        }
        // Sort UIDs
        std.mem.sort(u32, uids.items, {}, std.sort.asc(u32));
        return uids.toOwnedSlice(self.allocator);
    }
};

fn writeFileLocal(path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn sanitizeMailboxAlloc(allocator: std.mem.Allocator, mailbox: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (mailbox) |byte| {
        try out.append(allocator, if (byte == '/') '_' else byte);
    }
    return out.toOwnedSlice(allocator);
}

fn desanitizeMailboxAlloc(allocator: std.mem.Allocator, mailbox: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (mailbox) |byte| {
        try out.append(allocator, if (byte == '_') '/' else byte);
    }
    return out.toOwnedSlice(allocator);
}
