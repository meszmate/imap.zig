pub const memstore = @import("memstore.zig");
pub const fsstore = @import("fsstore.zig");
pub const interface = @import("interface.zig");

pub const MemStore = memstore.MemStore;
pub const User = memstore.User;
pub const Mailbox = memstore.Mailbox;
pub const Message = memstore.Message;
pub const FsStore = fsstore.FsStore;
pub const FsUser = fsstore.FsUser;
pub const Backend = interface.Backend;
pub const BackendUser = interface.User;
pub const BackendMailbox = interface.Mailbox;
