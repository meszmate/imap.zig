const std = @import("std");
const imap = @import("../root.zig");
const memstore = @import("memstore.zig");
const interface = @import("interface.zig");

/// SessionAdapter bridges a memstore backend to the IMAP server protocol.
/// It handles sequence-to-UID mapping, body section extraction, and
/// envelope parsing from raw messages.
///
/// This is analogous to Go's store/adapter.go NewSessionFactory.
pub const SessionAdapter = struct {
    allocator: std.mem.Allocator,
    user: *memstore.User,
    selected: ?*memstore.Mailbox = null,
    read_only: bool = false,

    pub fn init(allocator: std.mem.Allocator, user: *memstore.User) SessionAdapter {
        return .{
            .allocator = allocator,
            .user = user,
        };
    }

    pub fn selectMailbox(self: *SessionAdapter, name: []const u8, read_only: bool) !imap.SelectData {
        const mailbox = self.user.getMailbox(name) orelse return error.NoSuchMailbox;
        self.selected = mailbox;
        self.read_only = read_only;
        return .{
            .mailbox = mailbox.name,
            .exists = @intCast(mailbox.messages.items.len),
            .recent = mailbox.countRecent(),
            .unseen = mailbox.firstUnseenSeq(),
            .uid_validity = mailbox.uid_validity,
            .uid_next = mailbox.next_uid,
            .flags = mailbox.standardFlags(),
            .permanent_flags = mailbox.standardFlags(),
            .read_only = read_only,
        };
    }

    pub fn unselectMailbox(self: *SessionAdapter) void {
        self.selected = null;
        self.read_only = false;
    }

    pub fn getSelected(self: *const SessionAdapter) ?*memstore.Mailbox {
        return self.selected;
    }

    /// Convert a sequence number to a UID.
    pub fn seqToUid(self: *const SessionAdapter, seq_num: u32) ?imap.UID {
        const mailbox = self.selected orelse return null;
        if (seq_num == 0 or seq_num > mailbox.messages.items.len) return null;
        return mailbox.messages.items[seq_num - 1].uid;
    }

    /// Convert a UID to a sequence number.
    pub fn uidToSeq(self: *const SessionAdapter, uid: imap.UID) ?u32 {
        const mailbox = self.selected orelse return null;
        for (mailbox.messages.items, 0..) |msg, index| {
            if (msg.uid == uid) return @intCast(index + 1);
        }
        return null;
    }

    /// Get a message by sequence number.
    pub fn getMessageBySeq(self: *const SessionAdapter, seq_num: u32) ?*memstore.Message {
        const mailbox = self.selected orelse return null;
        if (seq_num == 0 or seq_num > mailbox.messages.items.len) return null;
        return &mailbox.messages.items[seq_num - 1];
    }

    /// Get a message by UID.
    pub fn getMessageByUid(self: *const SessionAdapter, uid: imap.UID) ?*memstore.Message {
        const mailbox = self.selected orelse return null;
        for (mailbox.messages.items) |*msg| {
            if (msg.uid == uid) return msg;
        }
        return null;
    }

    /// Extract the header portion of a message body.
    pub fn extractHeaders(body: []const u8) []const u8 {
        const separator = std.mem.indexOf(u8, body, "\r\n\r\n") orelse return body;
        return body[0 .. separator + 2]; // include trailing \r\n
    }

    /// Extract the text portion of a message body (after headers).
    pub fn extractText(body: []const u8) []const u8 {
        const separator = std.mem.indexOf(u8, body, "\r\n\r\n") orelse return "";
        return body[separator + 4 ..];
    }

    /// Extract a specific header value from message body.
    pub fn extractHeader(body: []const u8, header_name: []const u8) []const u8 {
        var it = std.mem.splitSequence(u8, body, "\r\n");
        while (it.next()) |line| {
            if (line.len == 0) break;
            if (line.len > header_name.len + 1 and
                std.ascii.eqlIgnoreCase(line[0..header_name.len], header_name) and
                line[header_name.len] == ':')
            {
                return std.mem.trimLeft(u8, line[header_name.len + 1 ..], " ");
            }
        }
        return "";
    }

    /// Extract specific headers (HEADER.FIELDS filter).
    pub fn extractHeaderFieldsAlloc(allocator: std.mem.Allocator, body: []const u8, fields: []const []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var it = std.mem.splitSequence(u8, body, "\r\n");
        while (it.next()) |line| {
            if (line.len == 0) break;
            for (fields) |field| {
                if (line.len > field.len and
                    std.ascii.eqlIgnoreCase(line[0..field.len], field) and
                    line[field.len] == ':')
                {
                    try out.appendSlice(allocator, line);
                    try out.appendSlice(allocator, "\r\n");
                    break;
                }
            }
        }
        try out.appendSlice(allocator, "\r\n");
        return out.toOwnedSlice(allocator);
    }

    /// Parse an envelope from raw message headers.
    pub fn parseEnvelope(body: []const u8) imap.Envelope {
        return .{
            .date = extractHeader(body, "Date"),
            .subject = extractHeader(body, "Subject"),
            .message_id = extractHeader(body, "Message-ID"),
            .in_reply_to = extractHeader(body, "In-Reply-To"),
            // Note: address fields point into the body slice (no allocation).
            // For full address parsing, use parseAddressListAlloc.
        };
    }

    /// Apply a partial range to body data.
    pub fn applyPartial(data: []const u8, partial: ?imap.SectionPartial) []const u8 {
        const p = partial orelse return data;
        if (p.offset >= data.len) return "";
        const end = @min(p.offset + p.count, data.len);
        return data[p.offset..end];
    }

    /// Get body section data according to a section specification.
    pub fn getBodySectionAlloc(self: *const SessionAdapter, allocator: std.mem.Allocator, msg: *const memstore.Message, section: imap.BodySectionName) ![]u8 {
        _ = self;
        const specifier = section.specifier;

        if (specifier.len == 0) {
            return allocator.dupe(u8, applyPartial(msg.body, section.partial));
        }

        if (std.ascii.eqlIgnoreCase(specifier, "HEADER")) {
            return allocator.dupe(u8, applyPartial(extractHeaders(msg.body), section.partial));
        }

        if (std.ascii.eqlIgnoreCase(specifier, "TEXT")) {
            return allocator.dupe(u8, applyPartial(extractText(msg.body), section.partial));
        }

        if (std.ascii.eqlIgnoreCase(specifier, "HEADER.FIELDS")) {
            return extractHeaderFieldsAlloc(allocator, msg.body, section.fields);
        }

        // Default: return full body
        return allocator.dupe(u8, applyPartial(msg.body, section.partial));
    }
};

/// ProtocolAdapter bridges a store.Backend to full IMAP server protocol.
/// It manages sequence-to-UID mapping and translates IMAP operations.
pub const ProtocolAdapter = struct {
    allocator: std.mem.Allocator,
    backend: interface.Backend,
    user: ?interface.User = null,
    mailbox: ?interface.Mailbox = null,
    uid_map: std.ArrayList(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator, backend: interface.Backend) ProtocolAdapter {
        return .{
            .allocator = allocator,
            .backend = backend,
        };
    }

    pub fn deinit(self: *ProtocolAdapter) void {
        if (self.mailbox) |*mb| mb.deinit();
        if (self.user) |*u| u.deinit();
        self.uid_map.deinit(self.allocator);
    }

    pub fn login(self: *ProtocolAdapter, username: []const u8, password: []const u8) !void {
        self.user = try self.backend.authenticate(self.allocator, username, password);
    }

    pub fn selectMailbox(self: *ProtocolAdapter, name: []const u8) !interface.MailboxInfo {
        if (self.mailbox) |*mb| mb.deinit();
        self.mailbox = try self.user.?.openMailbox(name);
        try self.rebuildUidMap();
        return self.mailbox.?.info();
    }

    pub fn unselectMailbox(self: *ProtocolAdapter) void {
        if (self.mailbox) |*mb| mb.deinit();
        self.mailbox = null;
        self.uid_map.clearRetainingCapacity();
    }

    /// Rebuild the sequence-to-UID mapping.
    fn rebuildUidMap(self: *ProtocolAdapter) !void {
        self.uid_map.clearRetainingCapacity();
        const uids = try self.mailbox.?.listUids();
        defer self.allocator.free(uids);
        try self.uid_map.appendSlice(self.allocator, uids);
    }

    /// Convert sequence number to UID.
    pub fn seqToUid(self: *const ProtocolAdapter, seq: u32) ?u32 {
        if (seq == 0 or seq > self.uid_map.items.len) return null;
        return self.uid_map.items[seq - 1];
    }

    /// Convert UID to sequence number.
    pub fn uidToSeq(self: *const ProtocolAdapter, uid: u32) ?u32 {
        for (self.uid_map.items, 0..) |u, i| {
            if (u == uid) return @intCast(i + 1);
        }
        return null;
    }

    /// Resolve a set of sequence numbers or UIDs to UIDs.
    pub fn resolveToUidsAlloc(self: *const ProtocolAdapter, nums: []const u32, is_uid: bool) ![]u32 {
        if (is_uid) return self.allocator.dupe(u32, nums);
        var uids: std.ArrayList(u32) = .empty;
        errdefer uids.deinit(self.allocator);
        for (nums) |seq| {
            if (self.seqToUid(seq)) |uid| try uids.append(self.allocator, uid);
        }
        return uids.toOwnedSlice(self.allocator);
    }

    pub fn fetchMessages(self: *ProtocolAdapter, uids: []const u32) ![]interface.MessageData {
        return self.mailbox.?.getMessages(uids);
    }

    pub fn storeFlags(self: *ProtocolAdapter, uids: []const u32, action: u8, flags: []const []const u8) !void {
        return self.mailbox.?.setFlags(uids, action, flags);
    }

    pub fn copyMessages(self: *ProtocolAdapter, uids: []const u32, dest: []const u8) !interface.CopyResult {
        return self.mailbox.?.copyMessages(uids, dest);
    }

    pub fn expunge(self: *ProtocolAdapter, uid_set: ?[]const u32) ![]u32 {
        const result = try self.mailbox.?.expungeMessages(uid_set);
        try self.rebuildUidMap();
        return result;
    }

    pub fn searchMessages(self: *ProtocolAdapter, criteria: *const interface.SearchParams) ![]u32 {
        return self.mailbox.?.searchMessages(criteria);
    }

    pub fn appendMessage(self: *ProtocolAdapter, mailbox_name: []const u8, message: []const u8) !void {
        return self.user.?.appendMessage(mailbox_name, message);
    }

    pub fn createMailbox(self: *ProtocolAdapter, name: []const u8) !void {
        return self.user.?.createMailbox(name);
    }

    pub fn deleteMailbox(self: *ProtocolAdapter, name: []const u8) !void {
        return self.user.?.deleteMailbox(name);
    }

    pub fn renameMailbox(self: *ProtocolAdapter, old_name: []const u8, new_name: []const u8) !void {
        return self.user.?.renameMailbox(old_name, new_name);
    }

    pub fn listMailboxes(self: *ProtocolAdapter) ![][]u8 {
        return self.user.?.listMailboxesAlloc();
    }

    pub fn getMailboxStatus(self: *ProtocolAdapter, name: []const u8) !interface.MailboxInfo {
        return self.user.?.getMailboxStatus(name);
    }

    pub fn subscribeMailbox(self: *ProtocolAdapter, name: []const u8) !void {
        return self.user.?.subscribeMailbox(name);
    }

    pub fn unsubscribeMailbox(self: *ProtocolAdapter, name: []const u8) !void {
        return self.user.?.unsubscribeMailbox(name);
    }
};

/// Parse an email address string like "Display Name <user@host>" or "user@host"
/// into an Address struct.
pub fn parseAddress(raw: []const u8) imap.Address {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .{};

    // Try "Display Name <user@host>" format
    if (std.mem.indexOfScalar(u8, trimmed, '<')) |angle_start| {
        const display = std.mem.trim(u8, trimmed[0..angle_start], " \t\"");
        const angle_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse trimmed.len;
        const email = trimmed[angle_start + 1 .. angle_end];
        if (std.mem.indexOfScalar(u8, email, '@')) |at| {
            return .{ .name = display, .mailbox = email[0..at], .host = email[at + 1 ..] };
        }
        return .{ .name = display, .mailbox = email };
    }

    // Try bare "user@host" format
    if (std.mem.indexOfScalar(u8, trimmed, '@')) |at| {
        return .{ .mailbox = trimmed[0..at], .host = trimmed[at + 1 ..] };
    }

    return .{ .mailbox = trimmed };
}

/// Parse a comma-separated list of email addresses.
pub fn parseAddressListAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]imap.Address {
    if (raw.len == 0) return allocator.alloc(imap.Address, 0);
    var addrs: std.ArrayList(imap.Address) = .empty;
    errdefer addrs.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const addr = parseAddress(part);
        if (addr.mailbox.len > 0 or addr.name.len > 0) {
            try addrs.append(allocator, addr);
        }
    }
    return addrs.toOwnedSlice(allocator);
}

/// Extract headers that DON'T match the given field names (HEADER.FIELDS.NOT).
pub fn extractHeaderFieldsNotAlloc(allocator: std.mem.Allocator, body: []const u8, fields: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitSequence(u8, body, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        var excluded = false;
        for (fields) |field| {
            if (std.ascii.eqlIgnoreCase(name, field)) {
                excluded = true;
                break;
            }
        }
        if (!excluded) {
            try out.appendSlice(allocator, line);
            try out.appendSlice(allocator, "\r\n");
        }
    }
    try out.appendSlice(allocator, "\r\n");
    return out.toOwnedSlice(allocator);
}

/// Split message body into header bytes and text bytes.
pub fn headerBytes(body: []const u8) []const u8 {
    return SessionAdapter.extractHeaders(body);
}

pub fn textBytes(body: []const u8) []const u8 {
    return SessionAdapter.extractText(body);
}
