const types = @import("../types.zig");
const state_machine = @import("../state/machine.zig");

pub const SessionState = struct {
    state: types.ConnState = .not_authenticated,
    selected_mailbox: ?[]const u8 = null,
    read_only: bool = false,

    pub fn canExecute(self: *const SessionState, command: []const u8) bool {
        const allowed = state_machine.commandAllowedStates(command);
        for (allowed) |candidate| {
            if (candidate == self.state) return true;
        }
        return false;
    }

    pub fn select(self: *SessionState, mailbox: []const u8, read_only: bool) void {
        self.state = .selected;
        self.selected_mailbox = mailbox;
        self.read_only = read_only;
    }

    pub fn unselect(self: *SessionState) void {
        if (self.state == .selected) self.state = .authenticated;
        self.selected_mailbox = null;
        self.read_only = false;
    }

    pub fn logout(self: *SessionState) void {
        self.state = .logout;
        self.selected_mailbox = null;
        self.read_only = false;
    }
};
