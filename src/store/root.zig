pub const memstore = @import("memstore.zig");
pub const fsstore = @import("fsstore.zig");

pub const MemStore = memstore.MemStore;
pub const User = memstore.User;
pub const Mailbox = memstore.Mailbox;
pub const Message = memstore.Message;
pub const FsStore = fsstore.FsStore;
pub const FsUser = fsstore.FsUser;
