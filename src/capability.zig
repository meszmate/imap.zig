const std = @import("std");

pub const Cap = []const u8;

pub const caps = struct {
    pub const imap4rev1 = "IMAP4rev1";
    pub const imap4rev2 = "IMAP4rev2";
    pub const auth_plain = "AUTH=PLAIN";
    pub const auth_login = "AUTH=LOGIN";
    pub const auth_scram_sha_1 = "AUTH=SCRAM-SHA-1";
    pub const auth_scram_sha_256 = "AUTH=SCRAM-SHA-256";
    pub const auth_scram_sha_1_plus = "AUTH=SCRAM-SHA-1-PLUS";
    pub const auth_scram_sha_256_plus = "AUTH=SCRAM-SHA-256-PLUS";
    pub const auth_cram_md5 = "AUTH=CRAM-MD5";
    pub const auth_xoauth2 = "AUTH=XOAUTH2";
    pub const auth_oauthbearer = "AUTH=OAUTHBEARER";
    pub const auth_external = "AUTH=EXTERNAL";
    pub const auth_anonymous = "AUTH=ANONYMOUS";
    pub const saslir = "SASL-IR";
    pub const idle = "IDLE";
    pub const namespace = "NAMESPACE";
    pub const id = "ID";
    pub const children = "CHILDREN";
    pub const starttls = "STARTTLS";
    pub const login_disabled = "LOGINDISABLED";
    pub const login_referrals = "LOGIN-REFERRALS";
    pub const mailbox_referrals = "MAILBOX-REFERRALS";
    pub const multiappend = "MULTIAPPEND";
    pub const binary = "BINARY";
    pub const unselect = "UNSELECT";
    pub const acl = "ACL";
    pub const annotate_experimental_1 = "ANNOTATE-EXPERIMENT-1";
    pub const uidplus = "UIDPLUS";
    pub const catenate = "CATENATE";
    pub const esearch = "ESEARCH";
    pub const compress_deflate = "COMPRESS=DEFLATE";
    pub const enable = "ENABLE";
    pub const context_search = "CONTEXT=SEARCH";
    pub const context_sort = "CONTEXT=SORT";
    pub const searchres = "SEARCHRES";
    pub const language = "LANGUAGE";
    pub const i18nlevel_1 = "I18NLEVEL=1";
    pub const i18nlevel_2 = "I18NLEVEL=2";
    pub const sort = "SORT";
    pub const thread = "THREAD";
    pub const thread_references = "THREAD=REFERENCES";
    pub const thread_orderedsubject = "THREAD=ORDEREDSUBJECT";
    pub const list_extended = "LIST-EXTENDED";
    pub const convert = "CONVERT";
    pub const metadata = "METADATA";
    pub const metadata_server = "METADATA-SERVER";
    pub const notify = "NOTIFY";
    pub const filters = "FILTERS";
    pub const list_status = "LIST-STATUS";
    pub const list_myrights = "LIST-MYRIGHTS";
    pub const list_metadata = "LIST-METADATA";
    pub const special_use = "SPECIAL-USE";
    pub const create_special_use = "CREATE-SPECIAL-USE";
    pub const move = "MOVE";
    pub const search_fuzzy = "SEARCH=FUZZY";
    pub const utf8_accept = "UTF8=ACCEPT";
    pub const utf8_only = "UTF8=ONLY";
    pub const condstore = "CONDSTORE";
    pub const qresync = "QRESYNC";
    pub const literal_plus = "LITERAL+";
    pub const literal_minus = "LITERAL-";
    pub const appendlimit = "APPENDLIMIT";
    pub const quota = "QUOTA";
    pub const quota_res_storage = "QUOTA=RES-STORAGE";
    pub const quota_res_message = "QUOTA=RES-MESSAGE";
    pub const quota_res_mailbox = "QUOTA=RES-MAILBOX";
    pub const quota_res_annotation_storage = "QUOTA=RES-ANNOTATION-STORAGE";
    pub const quotaset = "QUOTASET";
    pub const status_size = "STATUS=SIZE";
    pub const object_id = "OBJECTID";
    pub const replace = "REPLACE";
    pub const save_date = "SAVEDATE";
    pub const preview = "PREVIEW";
    pub const partial = "PARTIAL";
    pub const inprogress = "INPROGRESS";
    pub const uidonly = "UIDONLY";
    pub const jmapaccess = "JMAPACCESS";
    pub const message_limit = "MESSAGELIMIT";
    pub const save_limit = "SAVELIMIT";
    pub const multisearch = "MULTISEARCH";
    pub const sort_display = "SORT=DISPLAY";
    pub const within = "WITHIN";
    pub const unauthenticate = "UNAUTHENTICATE";
    pub const urlauth = "URLAUTH";
    pub const urlauth_binary = "URLAUTH=BINARY";
    pub const url_partial = "URL-PARTIAL";
    pub const rights = "RIGHTS=";
    pub const imapsieve = "IMAPSIEVE=";
    pub const esort = "ESORT";
    pub const convert_context_sort = "CONTEXT=SORT";
    pub const uidbatches = "UIDBATCHES";
};

pub const CapabilitySet = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) CapabilitySet {
        return .{
            .allocator = allocator,
            .values = .empty,
        };
    }

    pub fn deinit(self: *CapabilitySet) void {
        for (self.values.items) |value| {
            self.allocator.free(value);
        }
        self.values.deinit(self.allocator);
    }

    pub fn add(self: *CapabilitySet, value: []const u8) !void {
        if (self.has(value)) return;
        try self.values.append(self.allocator, try self.allocator.dupe(u8, value));
    }

    pub fn addMany(self: *CapabilitySet, values: []const []const u8) !void {
        for (values) |value| {
            try self.add(value);
        }
    }

    pub fn has(self: *const CapabilitySet, value: []const u8) bool {
        for (self.values.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, value)) return true;
        }
        return false;
    }

    pub fn remove(self: *CapabilitySet, value: []const u8) bool {
        for (self.values.items, 0..) |existing, index| {
            if (std.ascii.eqlIgnoreCase(existing, value)) {
                self.allocator.free(existing);
                _ = self.values.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn slice(self: *const CapabilitySet) []const []const u8 {
        return self.values.items;
    }
};
