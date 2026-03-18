const std = @import("std");
const imap = @import("../root.zig");
const memstore = @import("memstore.zig");

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
