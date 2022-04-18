const std = @import("std");
const sqlite = @import("sqlite");
const manage_main = @import("main.zig");
const libpcre = @import("libpcre");
const Context = manage_main.Context;

const log = std.log.scoped(.atags);

const VERSION = "0.0.1";
const HELPTEXT =
    \\ atags: manage your tags
    \\
    \\ usage:
    \\ 	atags action [arguments...]
    \\
    \\ options:
    \\ 	-h				prints this help and exits
    \\ 	-V				prints version and exits
    \\ 	--no-confirm			do not ask for confirmation on remove
    \\ 					commands.
    \\
    \\ examples:
    \\ 	atags create tag
    \\ 	atags create --core lkdjfalskjg tag
    \\ 	atags search tag
    \\ 	atags remove --tag tag
    \\ 	atags remove --core dslkjfsldkjf
;

const ActionConfig = union(enum) {
    Create: CreateAction.Config,
    Remove: RemoveAction.Config,
    Search: SearchAction.Config,
};

const CreateAction = struct {
    pub const Config = struct {
        tag_core: ?[]const u8 = null,
        tag_alias: ?[]const u8 = null,
        tag: ?[]const u8 = null,
    };

    pub fn processArgs(args_it: *std.process.ArgIterator, given_args: *Args) !ActionConfig {
        _ = given_args;
        var config = Config{};

        const ArgState = enum { None, NeedTagCore, NeedTagAlias };
        var state: ArgState = .None;
        while (args_it.next()) |arg| {
            if (state == .NeedTagCore) {
                config.tag_core = arg;
                state = .None;
            } else if (state == .NeedTagAlias) {
                config.tag_alias = arg;
                state = .None;
            } else if (std.mem.eql(u8, arg, "--core")) {
                state = .NeedTagCore;
            } else if (std.mem.eql(u8, arg, "--alias")) {
                state = .NeedTagAlias;
            } else {
                config.tag = arg;
            }

            if (config.tag_core != null and config.tag_alias != null) {
                log.err("only one of --core or --alias may be provided", .{});
                return error.OnlyOneAliasOrCore;
            }
        }
        return ActionConfig{ .Create = config };
    }

    ctx: *Context,
    config: Config,

    const Self = @This();

    pub fn init(ctx: *Context, config: Config) !Self {
        return Self{ .ctx = ctx, .config = config };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn run(self: *Self) !void {
        _ = self;

        var stdout = std.io.getStdOut().writer();

        var raw_core_hash_buffer: [32]u8 = undefined;
        var maybe_core: ?Context.Hash = null;

        if (self.config.tag_core) |tag_core_hex_string| {
            maybe_core = try consumeCoreHash(self.ctx, &raw_core_hash_buffer, tag_core_hex_string);
        } else if (self.config.tag_alias) |tag_core_hex_string| {
            // tag aliasing is a process where you have two separate tags
            // and you want them both to refer to the same core, in a non
            // destructive manner, by relinking files from the tag that's going
            // to become the alias.
            //
            // for purposes of explanation, we'll consider that we have
            // tag A and tag B, and we want B to be an alias of A
            //
            // to do so, we need to
            //  - find all files that are linked to B
            //  - link them to A
            //  - delete tag B
            //  - create tag B, with core set to A

            // TODO transaction over this (savepoints real)

            var tag_to_be_aliased_to = try consumeCoreHash(self.ctx, &raw_core_hash_buffer, tag_core_hex_string);
            var tag_to_be_aliased_from = if (try self.ctx.fetchNamedTag(self.config.tag.?, "en")) |tag_text|
                tag_text
            else
                return error.UnknownTag;

            if (tag_to_be_aliased_from.core.id == tag_to_be_aliased_to.id) {
                log.err(
                    "tag {s} already is pointing to core {s}, making a new alias of an existing alias is a destructive operation",
                    .{ self.config.tag.?, tag_to_be_aliased_to },
                );
                return error.TagAlreadyAliased;
            }

            // find all tags with that single tag (tag_to_be_aliased_from)
            const SqlGiver = @import("./find_main.zig").SqlGiver;

            var wrapped_sql_result = try SqlGiver.giveMeSql(self.ctx.allocator, self.config.tag.?);
            defer wrapped_sql_result.deinit();

            const sql_result = switch (wrapped_sql_result) {
                .Ok => |ok_body| ok_body,
                .Error => |error_body| {
                    log.err("parse error at character {d}: {s}", .{ error_body.character, error_body.error_type });
                    return error.ParseErrorHappened;
                },
            };

            std.debug.assert(sql_result.tags.len == 1);
            std.debug.assert(std.mem.eql(u8, sql_result.tags[0], self.config.tag.?));

            // execute query and bind to tag_to_be_aliased_from
            var stmt = try self.ctx.db.?.prepareDynamic(sql_result.query);
            defer stmt.deinit();
            var args = [1]i64{tag_to_be_aliased_from.core.id};
            var it = try stmt.iterator(i64, args);

            // add tag_to_be_aliased_to to all returned files
            while (try it.next(.{})) |file_hash_id| {
                var file = (try self.ctx.fetchFile(file_hash_id)).?;
                defer file.deinit();
                try file.addTag(tag_to_be_aliased_to);

                try stdout.print("relinked {s}", .{file.local_path});
                try file.printTagsTo(self.ctx.allocator, stdout);
                try stdout.print("\n", .{});
            }

            // delete tag_to_be_aliased_from
            const deleted_tag_names = try tag_to_be_aliased_from.deleteAll(&self.ctx.db.?);
            log.info("deleted {d} tag names", .{deleted_tag_names});

            // and create the proper alias (can only be done after deletion)
            const aliased_tag = try self.ctx.createNamedTag(self.config.tag.?, "en", tag_to_be_aliased_to);
            log.info("full tag info: {}", .{aliased_tag});

            return;
        }

        const tag = try self.ctx.createNamedTag(self.config.tag.?, "en", maybe_core);

        try stdout.print(
            "created tag with core '{s}' name '{s}'\n",
            .{ tag.core, tag },
        );
    }
};

fn consumeCoreHash(ctx: *Context, raw_core_hash_buffer: *[32]u8, tag_core_hex_string: []const u8) !Context.Hash {
    if (tag_core_hex_string.len != 64) {
        log.err("hashes myst be 64 bytes long, got {d}", .{tag_core_hex_string.len});
        return error.InvalidHashLength;
    }
    var raw_core_hash = try std.fmt.hexToBytes(raw_core_hash_buffer, tag_core_hex_string);

    const hash_blob = sqlite.Blob{ .data = raw_core_hash };
    const hash_id = (try ctx.db.?.one(
        i64,
        \\ select hashes.id
        \\ from hashes
        \\ join tag_cores
        \\  on tag_cores.core_hash = hashes.id
        \\ where hashes.hash_data = ?
    ,
        .{},
        .{hash_blob},
    )) orelse {
        return error.UnknownTagCore;
    };

    log.debug("found hash_id for the given core: {d}", .{hash_id});
    return Context.Hash{ .id = hash_id, .hash_data = raw_core_hash_buffer.* };
}

const RemoveAction = struct {
    pub const Config = struct {
        tag_core: ?[]const u8 = null,
        tag: ?[]const u8 = null,
        given_args: *Args,
    };

    pub fn processArgs(args_it: *std.process.ArgIterator, given_args: *Args) !ActionConfig {
        _ = given_args;
        var config = Config{ .given_args = given_args };

        const ArgState = enum { None, NeedTagCore, NeedTag };
        var state: ArgState = .None;
        while (args_it.next()) |arg| {
            if (state == .NeedTagCore) {
                config.tag_core = arg;
                state = .None;
            } else if (state == .NeedTag) {
                config.tag = arg;
                state = .None;
            } else if (std.mem.eql(u8, arg, "--core")) {
                state = .NeedTagCore;
            } else if (std.mem.eql(u8, arg, "--tag")) {
                state = .NeedTag;
            } else {
                return error.InvalidArgument;
            }
        }
        return ActionConfig{ .Remove = config };
    }

    ctx: *Context,
    config: Config,

    const Self = @This();

    pub fn init(ctx: *Context, config: Config) !Self {
        return Self{ .ctx = ctx, .config = config };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn run(self: *Self) !void {
        _ = self;

        var stdout = std.io.getStdOut().writer();
        var stdin = std.io.getStdIn().reader();

        var raw_core_hash_buffer: [32]u8 = undefined;

        var amount: usize = 0;
        var core_hash_id: ?i64 = null;
        try stdout.print("the following tags will be removed:\n", .{});

        if (self.config.tag_core) |tag_core_hex_string| {
            var core = try consumeCoreHash(self.ctx, &raw_core_hash_buffer, tag_core_hex_string);
            core_hash_id = core.id;

            // to delete the core, we need to delete every tag that references this tag core
            //
            // since this is a VERY destructive operation, we print the tag
            // names that are affected by this command, requiring user
            // confirmation to continue.

            var stmt = try self.ctx.db.?.prepare(
                "select tag_text, tag_language from tag_names where core_hash = ?",
            );
            defer stmt.deinit();

            var it = try stmt.iteratorAlloc(
                struct {
                    tag_text: []const u8,
                    tag_language: []const u8,
                },
                self.ctx.allocator,
                .{core.id},
            );

            while (try it.nextAlloc(self.ctx.allocator, .{})) |tag_name| {
                defer {
                    self.ctx.allocator.free(tag_name.tag_text);
                    self.ctx.allocator.free(tag_name.tag_language);
                }
                try stdout.print(" {s}", .{tag_name.tag_text});
                amount += 1;
            }
            try stdout.print("\n", .{});
        } else if (self.config.tag) |tag_text| {
            var maybe_tag = try self.ctx.fetchNamedTag(tag_text, "en");
            if (maybe_tag) |tag| {
                try stdout.print(" {s}", .{tag.kind.Named.text});
                core_hash_id = tag.core.id;
                amount += 1;
            } else {
                return error.NamedTagNotFound;
            }
            try stdout.print("\n", .{});
        } else {
            unreachable;
        }

        {
            const referenced_files = try self.ctx.db.?.one(
                i64,
                "select count(*) from tag_files where core_hash = ?",
                .{},
                .{core_hash_id},
            );
            try stdout.print("{d} files reference this tag.\n", .{referenced_files});
        }

        if (self.config.given_args.ask_confirmation) {
            var outcome: [1]u8 = undefined;
            try stdout.print("do you want to remove {d} tags (y/n)? ", .{amount});
            _ = try stdin.read(&outcome);

            if (!std.mem.eql(u8, &outcome, "y")) return error.NotConfirmed;
        }

        var deleted_count: ?i64 = null;

        if (self.config.tag_core) |tag_core_hex_string| {
            var core = try consumeCoreHash(self.ctx, &raw_core_hash_buffer, tag_core_hex_string);
            // TODO fix deleted_count here
            deleted_count = (try self.ctx.db.?.one(
                i64,
                \\ delete from tag_names
                \\ where core_hash = ?
                \\ returning (
                \\ 	select count(*)
                \\ 	from tag_names
                \\ 	where core_hash = ?
                \\ ) as deleted_count
            ,
                .{},
                .{ core.id, core.id },
            )).?;
            try self.ctx.db.?.exec("delete from tag_cores where core_hash = ?", .{}, .{core.id});
            try self.ctx.db.?.exec("delete from hashes where id = ?", .{}, .{core.id});
        } else if (self.config.tag) |tag_text| {
            deleted_count = (try self.ctx.db.?.one(
                i64,
                \\ delete from tag_names
                \\ where tag_text = ? and tag_language = ?
                \\ returning (
                \\ 	select count(*)
                \\ 	from tag_names
                \\ 	where tag_text = ? and tag_language = ?
                \\ ) as deleted_count
            ,
                .{},
                .{ tag_text, "en", tag_text, "en" },
            )).?;
        }
        try stdout.print("deleted {d} tags\n", .{deleted_count.?});
    }
};

const SearchAction = struct {
    pub const Config = struct {
        query: ?[]const u8 = null,
    };

    pub fn processArgs(args_it: *std.process.ArgIterator, given_args: *Args) !ActionConfig {
        _ = given_args;
        var config = Config{};
        config.query = args_it.next() orelse return error.MissingQuery;
        return ActionConfig{ .Search = config };
    }

    ctx: *Context,
    config: Config,

    const Self = @This();

    pub fn init(ctx: *Context, config: Config) !Self {
        return Self{ .ctx = ctx, .config = config };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn run(self: *Self) !void {
        var stdout = std.io.getStdOut().writer();

        var stmt = try self.ctx.db.?.prepare(
            \\ select distinct core_hash core_hash, hashes.hash_data
            \\ from tag_names
            \\ join hashes
            \\  on hashes.id = tag_names.core_hash
            \\ where tag_text LIKE '%' || ? || '%'
        );
        defer stmt.deinit();

        var tag_names = try stmt.all(
            struct {
                core_hash: i64,
                hash_data: sqlite.Blob,
            },
            self.ctx.allocator,
            .{},
            .{self.config.query.?},
        );

        defer {
            for (tag_names) |tag| {
                self.ctx.allocator.free(tag.hash_data.data);
            }
            self.ctx.allocator.free(tag_names);
        }

        for (tag_names) |tag_name| {
            const fake_hash = Context.HashWithBlob{
                .id = tag_name.core_hash,
                .hash_data = tag_name.hash_data,
            };
            var related_tags = try self.ctx.fetchTagsFromCore(
                self.ctx.allocator,
                fake_hash.toRealHash(),
            );
            defer related_tags.deinit();

            const full_tag_core = related_tags.items[0].core;
            try stdout.print("{s}", .{full_tag_core});
            for (related_tags.items) |tag| {
                try stdout.print(" '{s}'", .{tag});
            }
            try stdout.print("\n", .{});
        }
    }
};

const Args = struct {
    help: bool = false,
    version: bool = false,
    ask_confirmation: bool = true,
    action_config: ?ActionConfig = null,
};

pub fn main() anyerror!void {
    const rc = sqlite.c.sqlite3_config(sqlite.c.SQLITE_CONFIG_LOG, manage_main.sqliteLog, @as(?*anyopaque, null));
    if (rc != sqlite.c.SQLITE_OK) {
        std.log.err("failed to configure: {d} '{s}'", .{
            rc, sqlite.c.sqlite3_errstr(rc),
        });
        return error.ConfigFail;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    var args_it = std.process.args();
    _ = args_it.skip();

    var given_args = Args{};

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h")) {
            given_args.help = true;
        } else if (std.mem.eql(u8, arg, "-V")) {
            given_args.version = true;
        } else if (std.mem.eql(u8, arg, "--no-confirm")) {
            given_args.ask_confirmation = false;
        } else {
            if (std.mem.eql(u8, arg, "search")) {
                given_args.action_config = try SearchAction.processArgs(&args_it, &given_args);
            } else if (std.mem.eql(u8, arg, "create")) {
                given_args.action_config = try CreateAction.processArgs(&args_it, &given_args);
            } else if (std.mem.eql(u8, arg, "remove")) {
                given_args.action_config = try RemoveAction.processArgs(&args_it, &given_args);
            } else {
                log.err("{s} is an invalid action", .{arg});
                return error.InvalidAction;
            }
        }
    }

    if (given_args.help) {
        std.debug.print(HELPTEXT, .{});
        return;
    } else if (given_args.version) {
        std.debug.print("ainclude {s}\n", .{VERSION});
        return;
    }

    if (given_args.action_config == null) {
        std.log.err("action is a required argument", .{});
        return error.MissingAction;
    }
    const action_config = given_args.action_config.?;

    var ctx = Context{
        .home_path = null,
        .args_it = undefined,
        .stdout = undefined,
        .db = null,
        .allocator = allocator,
    };
    defer ctx.deinit();

    try ctx.loadDatabase(.{});

    switch (action_config) {
        .Search => |search_config| {
            var self = try SearchAction.init(&ctx, search_config);
            defer self.deinit();
            try self.run();
        },
        .Create => |create_config| {
            var self = try CreateAction.init(&ctx, create_config);
            defer self.deinit();
            try self.run();
        },
        .Remove => |remove_config| {
            var self = try RemoveAction.init(&ctx, remove_config);
            defer self.deinit();
            try self.run();
        },
    }
}
