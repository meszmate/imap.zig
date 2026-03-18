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
    pub const acl = ext("ACL", &.{imap.caps.acl}, &.{});
    pub const appendlimit = ext("APPENDLIMIT", &.{imap.caps.appendlimit}, &.{});
    pub const binary = ext("BINARY", &.{imap.caps.binary}, &.{});
    pub const catenate = ext("CATENATE", &.{imap.caps.catenate}, &.{});
    pub const children = ext("CHILDREN", &.{imap.caps.children}, &.{});
    pub const compress = ext("COMPRESS", &.{imap.caps.compress_deflate}, &.{});
    pub const condstore = ext("CONDSTORE", &.{imap.caps.condstore}, &.{});
    pub const contextsearch = ext("CONTEXTSEARCH", &.{imap.caps.context_search}, &.{});
    pub const convert = ext("CONVERT", &.{imap.caps.convert}, &.{});
    pub const enable = ext("ENABLE", &.{imap.caps.enable}, &.{});
    pub const esearch = ext("ESEARCH", &.{imap.caps.esearch}, &.{});
    pub const esort = ext("ESORT", &.{imap.caps.esort}, &.{ "ESEARCH", "SORT" });
    pub const filters = ext("FILTERS", &.{imap.caps.filters}, &.{});
    pub const id = ext("ID", &.{imap.caps.id}, &.{});
    pub const idle = ext("IDLE", &.{imap.caps.idle}, &.{});
    pub const inprogress = ext("INPROGRESS", &.{imap.caps.inprogress}, &.{});
    pub const jmapaccess = ext("JMAPACCESS", &.{imap.caps.jmapaccess}, &.{});
    pub const language = ext("LANGUAGE", &.{imap.caps.language}, &.{});
    pub const list_extended = ext("LIST-EXTENDED", &.{imap.caps.list_extended}, &.{});
    pub const list_metadata = ext("LIST-METADATA", &.{imap.caps.list_metadata}, &.{"LIST-EXTENDED"});
    pub const list_myrights = ext("LIST-MYRIGHTS", &.{imap.caps.list_myrights}, &.{"LIST-EXTENDED"});
    pub const list_status = ext("LIST-STATUS", &.{imap.caps.list_status}, &.{"LIST-EXTENDED"});
    pub const literal_plus = ext("LITERAL+", &.{imap.caps.literal_plus}, &.{});
    pub const messagelimit = ext("MESSAGELIMIT", &.{imap.caps.message_limit}, &.{});
    pub const metadata = ext("METADATA", &.{ imap.caps.metadata, imap.caps.metadata_server }, &.{});
    pub const move = ext("MOVE", &.{imap.caps.move}, &.{});
    pub const multiappend = ext("MULTIAPPEND", &.{imap.caps.multiappend}, &.{});
    pub const multisearch = ext("MULTISEARCH", &.{imap.caps.multisearch}, &.{});
    pub const namespace = ext("NAMESPACE", &.{imap.caps.namespace}, &.{});
    pub const notify = ext("NOTIFY", &.{imap.caps.notify}, &.{});
    pub const object_id = ext("OBJECTID", &.{imap.caps.object_id}, &.{});
    pub const partial = ext("PARTIAL", &.{imap.caps.partial}, &.{});
    pub const preview = ext("PREVIEW", &.{imap.caps.preview}, &.{});
    pub const qresync = ext("QRESYNC", &.{imap.caps.qresync}, &.{"CONDSTORE"});
    pub const quota = ext(
        "QUOTA",
        &.{
            imap.caps.quota,
            imap.caps.quotaset,
            imap.caps.quota_res_storage,
            imap.caps.quota_res_message,
            imap.caps.quota_res_mailbox,
            imap.caps.quota_res_annotation_storage,
        },
        &.{},
    );
    pub const replace = ext("REPLACE", &.{imap.caps.replace}, &.{});
    pub const saslir = ext("SASL-IR", &.{imap.caps.saslir}, &.{});
    pub const savedate = ext("SAVEDATE", &.{imap.caps.save_date}, &.{});
    pub const search_fuzzy = ext("SEARCH=FUZZY", &.{imap.caps.search_fuzzy}, &.{});
    pub const searchres = ext("SEARCHRES", &.{imap.caps.searchres}, &.{});
    pub const sort = ext("SORT", &.{imap.caps.sort}, &.{});
    pub const sort_display = ext("SORT=DISPLAY", &.{imap.caps.sort_display}, &.{"SORT"});
    pub const special_use = ext("SPECIAL-USE", &.{ imap.caps.special_use, imap.caps.create_special_use }, &.{});
    pub const status_size = ext("STATUS=SIZE", &.{imap.caps.status_size}, &.{});
    pub const thread = ext("THREAD", &.{ imap.caps.thread, imap.caps.thread_references, imap.caps.thread_orderedsubject }, &.{});
    pub const uidonly = ext("UIDONLY", &.{imap.caps.uidonly}, &.{});
    pub const uidplus = ext("UIDPLUS", &.{imap.caps.uidplus}, &.{});
    pub const unauthenticate = ext("UNAUTHENTICATE", &.{imap.caps.unauthenticate}, &.{});
    pub const unselect = ext("UNSELECT", &.{imap.caps.unselect}, &.{});
    pub const urlauth = ext("URLAUTH", &.{ imap.caps.urlauth, imap.caps.urlauth_binary }, &.{});
    pub const utf8_accept = ext("UTF8=ACCEPT", &.{imap.caps.utf8_accept}, &.{});
    pub const within = ext("WITHIN", &.{imap.caps.within}, &.{});

    pub fn registerCore(registry: *Registry) !void {
        try registry.register(acl);
        try registry.register(appendlimit);
        try registry.register(binary);
        try registry.register(catenate);
        try registry.register(children);
        try registry.register(compress);
        try registry.register(condstore);
        try registry.register(contextsearch);
        try registry.register(convert);
        try registry.register(enable);
        try registry.register(esearch);
        try registry.register(filters);
        try registry.register(idle);
        try registry.register(namespace);
        try registry.register(id);
        try registry.register(inprogress);
        try registry.register(jmapaccess);
        try registry.register(language);
        try registry.register(list_extended);
        try registry.register(list_metadata);
        try registry.register(list_myrights);
        try registry.register(list_status);
        try registry.register(literal_plus);
        try registry.register(messagelimit);
        try registry.register(metadata);
        try registry.register(move);
        try registry.register(multiappend);
        try registry.register(multisearch);
        try registry.register(notify);
        try registry.register(object_id);
        try registry.register(partial);
        try registry.register(preview);
        try registry.register(quota);
        try registry.register(replace);
        try registry.register(saslir);
        try registry.register(savedate);
        try registry.register(search_fuzzy);
        try registry.register(searchres);
        try registry.register(sort);
        try registry.register(special_use);
        try registry.register(status_size);
        try registry.register(thread);
        try registry.register(uidonly);
        try registry.register(uidplus);
        try registry.register(unauthenticate);
        try registry.register(unselect);
        try registry.register(qresync);
        try registry.register(esort);
        try registry.register(sort_display);
        try registry.register(urlauth);
        try registry.register(utf8_accept);
        try registry.register(within);
    }
};

fn ext(name: []const u8, capabilities: []const imap.Cap, dependencies: []const []const u8) ext_mod.Extension {
    return .{
        .name = name,
        .capabilities = capabilities,
        .dependencies = dependencies,
    };
}
