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
    highest_mod_seq: ?u64 = null,
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
    size: bool = false,
    highest_mod_seq: bool = false,
};

pub const StatusData = struct {
    mailbox: []const u8 = "",
    messages: ?u32 = null,
    recent: ?u32 = null,
    unseen: ?u32 = null,
    uid_next: ?u32 = null,
    uid_validity: ?u32 = null,
    size: ?u64 = null,
    highest_mod_seq: ?u64 = null,
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
    since: ?u64 = null,
    before: ?u64 = null,
    sent_since: ?u64 = null,
    sent_before: ?u64 = null,
    on: ?u64 = null,
    sent_on: ?u64 = null,
    larger: ?u64 = null,
    smaller: ?u64 = null,
    header: ?[2][]const u8 = null,
    or_criteria: ?[2]*const SearchCriteria = null,
    not_criteria: ?*const SearchCriteria = null,
    younger: ?u32 = null,
    older: ?u32 = null,
    keyword: ?[]const u8 = null,
    unkeyword: ?[]const u8 = null,
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
    mod_seq: bool = false,
    preview: bool = false,
    save_date: bool = false,
    email_id: bool = false,
    thread_id: bool = false,
    changed_since: ?u64 = null,
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
    mod_seq: ?u64 = null,
    preview: ?[]const u8 = null,
    save_date: ?[]const u8 = null,
    email_id: ?[]const u8 = null,
    thread_id: ?[]const u8 = null,

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

// --- SORT ---
pub const SortKey = enum {
    arrival,
    cc,
    date,
    from,
    size,
    subject,
    to,
    display_from,
    display_to,

    pub fn label(self: SortKey) []const u8 {
        return switch (self) {
            .arrival => "ARRIVAL",
            .cc => "CC",
            .date => "DATE",
            .from => "FROM",
            .size => "SIZE",
            .subject => "SUBJECT",
            .to => "TO",
            .display_from => "DISPLAYFROM",
            .display_to => "DISPLAYTO",
        };
    }
};

pub const SortCriterion = struct {
    key: SortKey = .date,
    reverse: bool = false,
};

pub const SortOptions = struct {
    sort_criteria: []const SortCriterion = &.{},
    charset: []const u8 = "UTF-8",
    search_criteria: []const u8 = "ALL",
};

pub const SortData = struct {
    ids: []const u32 = &.{},
};

// --- THREAD ---
pub const ThreadAlgorithm = enum {
    orderedsubject,
    references,

    pub fn label(self: ThreadAlgorithm) []const u8 {
        return switch (self) {
            .orderedsubject => "ORDEREDSUBJECT",
            .references => "REFERENCES",
        };
    }
};

pub const Thread = struct {
    id: u32 = 0,
    children: []const Thread = &.{},
};

pub const ThreadData = struct {
    threads: []const Thread = &.{},
};

// --- ACL ---
pub const AclRight = u8;

pub const acl_rights = struct {
    pub const lookup: AclRight = 'l';
    pub const read: AclRight = 'r';
    pub const seen: AclRight = 's';
    pub const write: AclRight = 'w';
    pub const insert: AclRight = 'i';
    pub const post: AclRight = 'p';
    pub const create_mailbox: AclRight = 'k';
    pub const delete_mailbox: AclRight = 'x';
    pub const delete_message: AclRight = 't';
    pub const expunge: AclRight = 'e';
    pub const admin: AclRight = 'a';
};

pub const AclData = struct {
    mailbox: []const u8 = "",
    entries: []const AclEntry = &.{},
};

pub const AclEntry = struct {
    identifier: []const u8 = "",
    rights: []const u8 = "",
};

pub const AclListRightsData = struct {
    mailbox: []const u8 = "",
    identifier: []const u8 = "",
    required: []const u8 = "",
    optional: []const []const u8 = &.{},
};

pub const AclMyRightsData = struct {
    mailbox: []const u8 = "",
    rights: []const u8 = "",
};

// --- QUOTA ---
pub const QuotaResource = enum {
    storage,
    message,
    mailbox,
    annotation_storage,

    pub fn label(self: QuotaResource) []const u8 {
        return switch (self) {
            .storage => "STORAGE",
            .message => "MESSAGE",
            .mailbox => "MAILBOX",
            .annotation_storage => "ANNOTATION-STORAGE",
        };
    }
};

pub const QuotaResourceData = struct {
    resource: QuotaResource = .storage,
    usage: u64 = 0,
    limit: u64 = 0,
};

pub const QuotaData = struct {
    root: []const u8 = "",
    resources: []const QuotaResourceData = &.{},
};

pub const QuotaRootData = struct {
    mailbox: []const u8 = "",
    roots: []const []const u8 = &.{},
};

// --- METADATA ---
pub const MetadataEntry = struct {
    name: []const u8 = "",
    value: ?[]const u8 = null,
};

pub const MetadataOptions = struct {
    max_size: ?u64 = null,
    depth: ?[]const u8 = null,
};

pub const MetadataData = struct {
    mailbox: []const u8 = "",
    entries: []const MetadataEntry = &.{},
};

// --- Extended SEARCH ---
pub const SearchReturnOptions = struct {
    min: bool = false,
    max: bool = false,
    all: bool = false,
    count: bool = false,
    save: bool = false,
};

pub const ESearchData = struct {
    uid: bool = false,
    min: ?u32 = null,
    max: ?u32 = null,
    all: ?[]const u8 = null,
    count: ?u32 = null,
    mod_seq: ?u64 = null,
};

// --- Extended FETCH fields ---
pub const ExtendedFetchOptions = struct {
    mod_seq: bool = false,
    preview: bool = false,
    save_date: bool = false,
    email_id: bool = false,
    thread_id: bool = false,
    binary_sections: []const BodySectionName = &.{},
    binary_size_sections: []const BodySectionName = &.{},
    changed_since: ?u64 = null,
};

// --- Extended SELECT ---
pub const SelectQResyncParam = struct {
    uid_validity: u32 = 0,
    mod_seq: u64 = 0,
    known_uids: ?[]const u8 = null,
    seq_match: ?[]const u8 = null,
};

// --- REPLACE ---
pub const ReplaceOptions = struct {
    flags: []const []const u8 = &.{},
    internal_date_unix: ?u64 = null,
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
