const imap = @import("../root.zig");

pub const Extension = struct {
    name: []const u8,
    capabilities: []const imap.Cap = &.{},
    dependencies: []const []const u8 = &.{},
};

pub const BaseExtension = Extension;
