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
        try writeFile(password_path, password);

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
        try writeFile(mailbox_path, "");
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
};

fn writeFile(path: []const u8, bytes: []const u8) !void {
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
