//! Store helper utilities for common IMAP store operations.
//! Provides pattern matching, number set resolution, and data conversion.

const std = @import("std");
const imap = @import("../root.zig");

/// Match a mailbox name against an IMAP LIST pattern.
/// '*' matches everything including hierarchy delimiters.
/// '%' matches everything except hierarchy delimiters.
pub fn matchPattern(name: []const u8, pattern: []const u8) bool {
    return matchPatternDelim(name, pattern, '/');
}

pub fn matchPatternDelim(name: []const u8, pattern: []const u8, delimiter: u8) bool {
    return matchRec(name, pattern, delimiter);
}

fn matchRec(name: []const u8, pattern: []const u8, delimiter: u8) bool {
    if (pattern.len == 0) return name.len == 0;

    return switch (pattern[0]) {
        '*' => blk: {
            var i: usize = 0;
            while (i <= name.len) : (i += 1) {
                if (matchRec(name[i..], pattern[1..], delimiter)) break :blk true;
            }
            break :blk false;
        },
        '%' => blk: {
            var i: usize = 0;
            while (i <= name.len and (i == name.len or name[i] != delimiter)) : (i += 1) {
                if (matchRec(name[i..], pattern[1..], delimiter)) break :blk true;
            }
            break :blk false;
        },
        else => {
            if (name.len == 0) return false;
            return std.ascii.toUpper(name[0]) == std.ascii.toUpper(pattern[0]) and matchRec(name[1..], pattern[1..], delimiter);
        },
    };
}

/// Check if a mailbox has children in the given list of names.
pub fn hasChildren(name: []const u8, all_names: []const []const u8, delimiter: u8) bool {
    const prefix_len = name.len + 1; // name + delimiter
    for (all_names) |candidate| {
        if (candidate.len > name.len and
            std.mem.startsWith(u8, candidate, name) and
            candidate[name.len] == delimiter)
        {
            _ = prefix_len;
            return true;
        }
    }
    return false;
}

/// Normalize INBOX name (case-insensitive).
pub fn normalizeInbox(name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "INBOX")) return "INBOX";
    return name;
}

/// Resolve a sequence set string to UIDs using a UID map.
pub fn resolveSeqSetToUidsAlloc(allocator: std.mem.Allocator, seq_set_str: []const u8, uid_map: []const u32) ![]u32 {
    var set = try imap.NumSet.parse(allocator, .seq, seq_set_str);
    defer set.deinit();
    var uids: std.ArrayList(u32) = .empty;
    errdefer uids.deinit(allocator);
    for (uid_map, 0..) |uid, index| {
        const seq: u32 = @intCast(index + 1);
        if (set.contains(seq)) try uids.append(allocator, uid);
    }
    return uids.toOwnedSlice(allocator);
}

/// Resolve a UID set string to UIDs, filtering against available UIDs.
pub fn resolveUidSetAlloc(allocator: std.mem.Allocator, uid_set_str: []const u8, available_uids: []const u32) ![]u32 {
    var set = try imap.NumSet.parse(allocator, .uid, uid_set_str);
    defer set.deinit();
    var uids: std.ArrayList(u32) = .empty;
    errdefer uids.deinit(allocator);
    for (available_uids) |uid| {
        if (set.contains(uid)) try uids.append(allocator, uid);
    }
    return uids.toOwnedSlice(allocator);
}

/// Join a slice of flags into a space-separated string.
pub fn joinFlagsAlloc(allocator: std.mem.Allocator, flags: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (flags, 0..) |flag, index| {
        if (index != 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, flag);
    }
    return out.toOwnedSlice(allocator);
}

/// Split a space-separated flags string into individual flags.
pub fn splitFlagsAlloc(allocator: std.mem.Allocator, flags_str: []const u8) ![][]u8 {
    if (flags_str.len == 0) return allocator.alloc([]u8, 0);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    var it = std.mem.tokenizeAny(u8, flags_str, " ");
    while (it.next()) |flag| {
        try out.append(allocator, try allocator.dupe(u8, flag));
    }
    return out.toOwnedSlice(allocator);
}
