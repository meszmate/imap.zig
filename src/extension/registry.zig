const std = @import("std");
const ext_mod = @import("extension.zig");
const imap = @import("../root.zig");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    extensions: std.StringArrayHashMap(ext_mod.Extension),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .extensions = std.StringArrayHashMap(ext_mod.Extension).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.extensions.deinit();
    }

    pub fn register(self: *Registry, extension: ext_mod.Extension) !void {
        if (self.extensions.contains(extension.name)) return error.ExtensionAlreadyRegistered;
        try self.extensions.put(extension.name, extension);
    }

    pub fn get(self: *const Registry, name: []const u8) ?ext_mod.Extension {
        return self.extensions.get(name);
    }

    pub fn remove(self: *Registry, name: []const u8) bool {
        return self.extensions.swapRemove(name);
    }

    pub fn len(self: *const Registry) usize {
        return self.extensions.count();
    }

    pub fn namesAlloc(self: *const Registry, allocator: std.mem.Allocator) ![][]const u8 {
        var out = try allocator.alloc([]const u8, self.extensions.count());
        for (self.extensions.keys(), 0..) |name, index| out[index] = name;
        return out;
    }

    pub fn allAlloc(self: *const Registry, allocator: std.mem.Allocator) ![]ext_mod.Extension {
        var out = try allocator.alloc(ext_mod.Extension, self.extensions.count());
        for (self.extensions.values(), 0..) |value, index| out[index] = value;
        return out;
    }

    pub fn resolveAlloc(self: *const Registry, allocator: std.mem.Allocator) ![]ext_mod.Extension {
        for (self.extensions.values()) |extension| {
            for (extension.dependencies) |dep| {
                if (!self.extensions.contains(dep)) return error.MissingDependency;
            }
        }

        var indegree = std.StringHashMap(usize).init(allocator);
        defer indegree.deinit();
        for (self.extensions.keys(), self.extensions.values()) |name, extension| {
            try indegree.put(name, extension.dependencies.len);
        }

        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(allocator);
        for (self.extensions.keys()) |name| {
            if (indegree.get(name).? == 0) try queue.append(allocator, name);
        }

        var sorted: std.ArrayList(ext_mod.Extension) = .empty;
        defer sorted.deinit(allocator);
        var index: usize = 0;
        while (index < queue.items.len) : (index += 1) {
            const name = queue.items[index];
            const extension = self.extensions.get(name).?;
            try sorted.append(allocator, extension);

            for (self.extensions.keys(), self.extensions.values()) |other_name, other_ext| {
                for (other_ext.dependencies) |dep| {
                    if (!std.mem.eql(u8, dep, name)) continue;
                    const current = indegree.get(other_name).?;
                    try indegree.put(other_name, current - 1);
                    if (current - 1 == 0) try queue.append(allocator, other_name);
                }
            }
        }

        if (sorted.items.len != self.extensions.count()) return error.CircularDependency;
        return sorted.toOwnedSlice(allocator);
    }
};

pub const Builtins = struct {
    pub const idle = ext("IDLE", &.{imap.caps.idle}, &.{});
    pub const namespace = ext("NAMESPACE", &.{imap.caps.namespace}, &.{});
    pub const id = ext("ID", &.{imap.caps.id}, &.{});
    pub const enable = ext("ENABLE", &.{imap.caps.enable}, &.{});
    pub const list_extended = ext("LIST-EXTENDED", &.{imap.caps.list_extended}, &.{});
    pub const move = ext("MOVE", &.{imap.caps.move}, &.{});
    pub const uidplus = ext("UIDPLUS", &.{imap.caps.uidplus}, &.{});
    pub const unselect = ext("UNSELECT", &.{imap.caps.unselect}, &.{});
    pub const list_status = ext("LIST-STATUS", &.{imap.caps.list_status}, &.{"LIST-EXTENDED"});
    pub const list_metadata = ext("LIST-METADATA", &.{imap.caps.list_metadata}, &.{"LIST-EXTENDED"});
    pub const searchres = ext("SEARCHRES", &.{imap.caps.searchres}, &.{});
    pub const condstore = ext("CONDSTORE", &.{imap.caps.condstore}, &.{});
    pub const qresync = ext("QRESYNC", &.{imap.caps.qresync}, &.{ "CONDSTORE" });
    pub const preview = ext("PREVIEW", &.{imap.caps.preview}, &.{});
    pub const partial = ext("PARTIAL", &.{imap.caps.partial}, &.{});
    pub const object_id = ext("OBJECTID", &.{imap.caps.object_id}, &.{});
    pub const savedate = ext("SAVEDATE", &.{imap.caps.save_date}, &.{});

    pub fn registerCore(registry: *Registry) !void {
        try registry.register(idle);
        try registry.register(namespace);
        try registry.register(id);
        try registry.register(enable);
        try registry.register(list_extended);
        try registry.register(move);
        try registry.register(uidplus);
        try registry.register(unselect);
        try registry.register(list_status);
        try registry.register(list_metadata);
        try registry.register(searchres);
        try registry.register(condstore);
        try registry.register(qresync);
        try registry.register(preview);
        try registry.register(partial);
        try registry.register(object_id);
        try registry.register(savedate);
    }
};

fn ext(name: []const u8, capabilities: []const imap.Cap, dependencies: []const []const u8) ext_mod.Extension {
    return .{
        .name = name,
        .capabilities = capabilities,
        .dependencies = dependencies,
    };
}
