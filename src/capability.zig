const std = @import("std");

pub const Cap = []const u8;

pub const caps = struct {
    pub const imap4rev1 = "IMAP4rev1";
    pub const imap4rev2 = "IMAP4rev2";
    pub const auth_plain = "AUTH=PLAIN";
    pub const auth_login = "AUTH=LOGIN";
    pub const auth_cram_md5 = "AUTH=CRAM-MD5";
    pub const auth_xoauth2 = "AUTH=XOAUTH2";
    pub const auth_oauthbearer = "AUTH=OAUTHBEARER";
    pub const auth_external = "AUTH=EXTERNAL";
    pub const auth_anonymous = "AUTH=ANONYMOUS";
    pub const saslir = "SASL-IR";
    pub const idle = "IDLE";
    pub const namespace = "NAMESPACE";
    pub const id = "ID";
    pub const children = "CHILDREN";
    pub const starttls = "STARTTLS";
    pub const login_disabled = "LOGINDISABLED";
    pub const multiappend = "MULTIAPPEND";
    pub const binary = "BINARY";
    pub const unselect = "UNSELECT";
    pub const acl = "ACL";
    pub const uidplus = "UIDPLUS";
    pub const esearch = "ESEARCH";
    pub const enable = "ENABLE";
    pub const searchres = "SEARCHRES";
    pub const sort = "SORT";
    pub const thread_references = "THREAD=REFERENCES";
    pub const list_extended = "LIST-EXTENDED";
    pub const metadata = "METADATA";
    pub const notify = "NOTIFY";
    pub const list_status = "LIST-STATUS";
    pub const special_use = "SPECIAL-USE";
    pub const move = "MOVE";
    pub const utf8_accept = "UTF8=ACCEPT";
    pub const condstore = "CONDSTORE";
    pub const qresync = "QRESYNC";
    pub const literal_plus = "LITERAL+";
    pub const literal_minus = "LITERAL-";
    pub const appendlimit = "APPENDLIMIT";
    pub const quota = "QUOTA";
    pub const status_size = "STATUS=SIZE";
    pub const object_id = "OBJECTID";
    pub const replace = "REPLACE";
    pub const save_date = "SAVEDATE";
    pub const preview = "PREVIEW";
    pub const partial = "PARTIAL";
    pub const uidonly = "UIDONLY";
    pub const list_metadata = "LIST-METADATA";
    pub const message_limit = "MESSAGELIMIT";
};

pub const CapabilitySet = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) CapabilitySet {
        return .{
            .allocator = allocator,
            .values = .empty,
        };
    }

    pub fn deinit(self: *CapabilitySet) void {
        for (self.values.items) |value| {
            self.allocator.free(value);
        }
        self.values.deinit(self.allocator);
    }

    pub fn add(self: *CapabilitySet, value: []const u8) !void {
        if (self.has(value)) return;
        try self.values.append(self.allocator, try self.allocator.dupe(u8, value));
    }

    pub fn addMany(self: *CapabilitySet, values: []const []const u8) !void {
        for (values) |value| {
            try self.add(value);
        }
    }

    pub fn has(self: *const CapabilitySet, value: []const u8) bool {
        for (self.values.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, value)) return true;
        }
        return false;
    }

    pub fn remove(self: *CapabilitySet, value: []const u8) bool {
        for (self.values.items, 0..) |existing, index| {
            if (std.ascii.eqlIgnoreCase(existing, value)) {
                self.allocator.free(existing);
                _ = self.values.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn slice(self: *const CapabilitySet) []const []const u8 {
        return self.values.items;
    }
};
