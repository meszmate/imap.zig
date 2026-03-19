const std = @import("std");
const imap = @import("../root.zig");
const dispatch = @import("dispatch.zig");

/// ServerExtension defines the interface for IMAP server extensions.
/// Extensions can register new command handlers, wrap existing ones,
/// and declare capabilities.
pub const ServerExtension = struct {
    name: []const u8,
    capabilities: []const []const u8 = &.{},

    /// Command handlers provided by this extension.
    /// Maps command name -> handler function.
    handlers: []const CommandEntry = &.{},

    /// Handler wrappers for existing commands.
    wrappers: []const WrapperEntry = &.{},

    pub const CommandEntry = struct {
        name: []const u8,
        handler: dispatch.CommandHandlerFn,
    };

    pub const WrapperEntry = struct {
        name: []const u8,
        wrapper: *const fn (original: dispatch.CommandHandlerFn) dispatch.CommandHandlerFn,
    };
};

/// Manages server extensions, registers their handlers into a Dispatcher,
/// and tracks capabilities.
pub const ExtensionManager = struct {
    allocator: std.mem.Allocator,
    extensions: std.ArrayList(ServerExtension) = .empty,
    extra_capabilities: std.ArrayList([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) ExtensionManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ExtensionManager) void {
        self.extensions.deinit(self.allocator);
        self.extra_capabilities.deinit(self.allocator);
    }

    /// Enable an extension. Registers its command handlers and wrappers
    /// into the provided dispatcher.
    pub fn enable(self: *ExtensionManager, ext: ServerExtension, dispatcher: *dispatch.Dispatcher) !void {
        // Register command handlers
        for (ext.handlers) |entry| {
            try dispatcher.register(entry.name, entry.handler);
        }

        // Apply handler wrappers
        for (ext.wrappers) |wrapper| {
            const original = dispatcher.get(wrapper.name) orelse continue;
            const wrapped = wrapper.wrapper(original);
            try dispatcher.register(wrapper.name, wrapped);
        }

        // Track capabilities
        for (ext.capabilities) |cap| {
            try self.extra_capabilities.append(self.allocator, cap);
        }

        try self.extensions.append(self.allocator, ext);
    }

    /// Get all capabilities provided by enabled extensions.
    pub fn allCapabilities(self: *const ExtensionManager) []const []const u8 {
        return self.extra_capabilities.items;
    }

    /// Build a complete capability string including base capabilities and extensions.
    pub fn buildCapabilityStringAlloc(self: *const ExtensionManager, allocator: std.mem.Allocator, base: []const u8) ![]u8 {
        if (self.extra_capabilities.items.len == 0) return allocator.dupe(u8, base);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, base);
        for (self.extra_capabilities.items) |cap| {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, cap);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Check if an extension with the given name is enabled.
    pub fn isEnabled(self: *const ExtensionManager, name: []const u8) bool {
        for (self.extensions.items) |ext| {
            if (std.mem.eql(u8, ext.name, name)) return true;
        }
        return false;
    }

    /// Get an enabled extension by name.
    pub fn get(self: *const ExtensionManager, name: []const u8) ?ServerExtension {
        for (self.extensions.items) |ext| {
            if (std.mem.eql(u8, ext.name, name)) return ext;
        }
        return null;
    }
};
