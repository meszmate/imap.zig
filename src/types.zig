const std = @import("std");

pub const ConnState = enum {
    not_authenticated,
    authenticated,
    selected,
    logout,

    pub fn label(self: ConnState) []const u8 {
        return switch (self) {
            .not_authenticated => "not authenticated",
            .authenticated => "authenticated",
            .selected => "selected",
            .logout => "logout",
        };
    }
};

pub const Flag = []const u8;

pub const flags = struct {
    pub const seen = "\\Seen";
    pub const answered = "\\Answered";
    pub const flagged = "\\Flagged";
    pub const deleted = "\\Deleted";
    pub const draft = "\\Draft";
    pub const recent = "\\Recent";
    pub const wildcard = "\\*";
};

pub const MailboxAttr = []const u8;

pub const mailbox_attrs = struct {
    pub const no_inferiors = "\\Noinferiors";
    pub const no_select = "\\Noselect";
    pub const marked = "\\Marked";
    pub const unmarked = "\\Unmarked";
    pub const has_children = "\\HasChildren";
    pub const has_no_children = "\\HasNoChildren";
    pub const non_existent = "\\NonExistent";
    pub const subscribed = "\\Subscribed";
    pub const remote = "\\Remote";
    pub const all = "\\All";
    pub const archive = "\\Archive";
    pub const drafts = "\\Drafts";
    pub const flagged = "\\Flagged";
    pub const junk = "\\Junk";
    pub const sent = "\\Sent";
    pub const trash = "\\Trash";
    pub const important = "\\Important";
    pub const memos = "\\Memos";
    pub const scheduled = "\\Scheduled";
    pub const snoozed = "\\Snoozed";
};

pub const UID = u32;
pub const SeqNum = u32;

pub const Literal = struct {
    bytes: []const u8,
};

pub const SectionPartial = struct {
    offset: u64,
    count: u64,
};

pub const BodySectionName = struct {
    specifier: []const u8 = "",
    part: []const u16 = &.{},
    fields: []const []const u8 = &.{},
    not_fields: bool = false,
    peek: bool = false,
    partial: ?SectionPartial = null,
};

pub const Address = struct {
    name: []const u8 = "",
    mailbox: []const u8 = "",
    host: []const u8 = "",
};

pub const Envelope = struct {
    date: []const u8 = "",
    subject: []const u8 = "",
    from: []const Address = &.{},
    sender: []const Address = &.{},
    reply_to: []const Address = &.{},
    to: []const Address = &.{},
    cc: []const Address = &.{},
    bcc: []const Address = &.{},
    in_reply_to: []const u8 = "",
    message_id: []const u8 = "",
};

pub const BodyStructure = struct {
    kind: []const u8 = "",
    subtype: []const u8 = "",
    params: []const Param = &.{},
    id: []const u8 = "",
    description: []const u8 = "",
    encoding: []const u8 = "",
    size: u32 = 0,
    lines: ?u32 = null,
    children: []const BodyStructure = &.{},
    md5: []const u8 = "",
    disposition: []const u8 = "",
    disposition_params: []const Param = &.{},
    language: []const []const u8 = &.{},
    location: []const u8 = "",

    pub const Param = struct {
        name: []const u8,
        value: []const u8,
    };

    pub fn isMultipart(self: BodyStructure) bool {
        return std.ascii.eqlIgnoreCase(self.kind, "multipart");
    }
};

pub const SelectOptions = struct {
    read_only: bool = false,
};

pub const SelectData = struct {
    mailbox: []const u8 = "",
    exists: u32 = 0,
    recent: u32 = 0,
    unseen: ?u32 = null,
    uid_validity: ?u32 = null,
    uid_next: ?u32 = null,
    flags: []const []const u8 = &.{},
    permanent_flags: []const []const u8 = &.{},
    read_only: bool = false,
};

pub const ListOptions = struct {
    subscribed_only: bool = false,
};

pub const ListData = struct {
    attrs: []const []const u8 = &.{},
    delimiter: ?u8 = '/',
    mailbox: []const u8 = "",
};

pub const StatusOptions = struct {
    messages: bool = true,
    recent: bool = true,
    unseen: bool = true,
    uid_next: bool = true,
    uid_validity: bool = true,
};

pub const StatusData = struct {
    mailbox: []const u8 = "",
    messages: ?u32 = null,
    recent: ?u32 = null,
    unseen: ?u32 = null,
    uid_next: ?u32 = null,
    uid_validity: ?u32 = null,
};

pub const AppendOptions = struct {
    flags: []const []const u8 = &.{},
    internal_date_unix: ?u64 = null,
};

pub const AppendData = struct {
    uid_validity: ?u32 = null,
    uid: ?UID = null,
};

pub const CopyData = struct {
    uid_validity: ?u32 = null,
    source_uids: []const UID = &.{},
    dest_uids: []const UID = &.{},
};

pub const SearchCriteria = struct {
    all: bool = true,
    seen: ?bool = null,
    answered: ?bool = null,
    flagged: ?bool = null,
    deleted: ?bool = null,
    draft: ?bool = null,
    subject: ?[]const u8 = null,
    body: ?[]const u8 = null,
    text: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    uid_set: ?[]const u8 = null,
};

pub const FetchBodySection = struct {
    section: BodySectionName = .{},
};

pub const FetchOptions = struct {
    flags: bool = true,
    uid: bool = true,
    internal_date: bool = false,
    rfc822_size: bool = false,
    envelope: bool = false,
    body_structure: bool = false,
    body_sections: []const FetchBodySection = &.{},
};

pub const FetchMessageData = struct {
    seq: SeqNum = 0,
    uid: ?UID = null,
    flags: []const []const u8 = &.{},
    internal_date: ?[]const u8 = null,
    rfc822_size: ?u64 = null,
    envelope: ?Envelope = null,
    body_structure: ?BodyStructure = null,
    body_sections: []const BodySectionData = &.{},

    pub const BodySectionData = struct {
        label: []const u8,
        bytes: []const u8,
    };
};

pub const StoreAction = enum {
    replace,
    add,
    remove,
};

pub const StoreFlags = struct {
    action: StoreAction = .replace,
    silent: bool = false,
    flags: []const []const u8 = &.{},
};

pub fn formatInternalDateUnix(buffer: []u8, unix_seconds: u64) ![]const u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = unix_seconds };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const month_name = switch (month_day.month) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };
    return std.fmt.bufPrint(
        buffer,
        "{d:0>2}-{s}-{d} {d:0>2}:{d:0>2}:{d:0>2} +0000",
        .{
            @as(u8, month_day.day_index) + 1,
            month_name,
            year_day.year,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}
