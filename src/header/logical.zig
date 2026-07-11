//! Lossless logical projection of physical FITS header cards for language bindings.
//!
//! This is intentionally more permissive than `value.parseValue`: a malformed/unsupported token
//! is retained as `.raw_token`, and an integer outside i64 is retained as `.integer_text`. Long
//! strings are folded while still escaped, then unescaped once, which accepts Astropy files that
//! split a doubled-quote pair across a CONTINUE boundary.
const std = @import("std");
const errors = @import("../errors.zig");
const limits_mod = @import("../limits.zig");
const Limits = limits_mod.Limits;
const Card = @import("card.zig").Card;
const hierarch = @import("hierarch.zig");

const Allocator = std.mem.Allocator;

pub const EntryKind = enum { value, commentary, blank, other };

pub const Value = union(enum) {
    none,
    undefined,
    logical: bool,
    int64: i64,
    integer_text: []const u8,
    float64: f64,
    string: []const u8,
    raw_token: []const u8,
};

pub const Entry = struct {
    kind: EntryKind,
    value: Value = .none,
    keyword: []const u8,
    commentary_text: []const u8 = "",
    comment: ?[]const u8 = null,
    physical_first: usize,
    physical_count: usize = 1,
    hierarch: bool = false,
    continued: bool = false,
    malformed: bool = false,
};

const Ref = struct {
    off: usize = 0,
    len: usize = 0,
    present: bool = false,
};

const TempValue = union(enum) {
    none,
    undefined,
    logical: bool,
    int64: i64,
    integer_text: Ref,
    float64: f64,
    string: Ref,
    raw_token: Ref,
};

const TempEntry = struct {
    kind: EntryKind,
    value: TempValue = .none,
    keyword: Ref,
    commentary_text: Ref = .{},
    comment: Ref = .{},
    physical_first: usize,
    physical_count: usize = 1,
    hierarch: bool = false,
    continued: bool = false,
    malformed: bool = false,
};

pub const Snapshot = struct {
    entries: []Entry,
    arena: []u8,
    physical_count: usize,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.entries);
        alloc.free(self.arena);
        self.* = .{ .entries = &.{}, .arena = &.{}, .physical_count = 0 };
    }

    pub fn build(alloc: Allocator, cards: []const Card, limits: Limits) (errors.HeaderError || errors.LimitError || Allocator.Error)!Snapshot {
        // The retained arena is a projection of 80-byte physical cards: for each logical record,
        // keyword + decoded value/commentary + comment cannot exceed the bytes consumed by its
        // physical run. Reserve that tight upper bound rather than the old 3x over-allocation;
        // this is especially material in wasm where query/fill snapshots live in linear memory.
        const cap64 = try limits_mod.mul(@intCast(cards.len), 80);
        const temp_bytes = try limits_mod.mul(@intCast(cards.len), @sizeOf(TempEntry));
        const entry_bytes = try limits_mod.mul(@intCast(cards.len), @sizeOf(Entry));
        if (cap64 > limits.max_open_alloc or temp_bytes > limits.max_open_alloc or entry_bytes > limits.max_open_alloc)
            return error.LimitExceeded;
        const arena_cap = std.math.cast(usize, cap64) orelse return error.LimitExceeded;

        var arena: std.ArrayList(u8) = .empty;
        defer arena.deinit(alloc);
        try arena.ensureTotalCapacityPrecise(alloc, arena_cap);
        var temp: std.ArrayList(TempEntry) = .empty;
        defer temp.deinit(alloc);
        try temp.ensureTotalCapacityPrecise(alloc, cards.len);

        var i: usize = 0;
        while (i < cards.len) {
            const card = &cards[i];
            if (card.kind == .end) break;
            const is_hierarch = hierarch.isHierarch(card) and hierarch.valueField(card) != null;
            if (card.kind == .value or is_hierarch) {
                const built = try parseValued(alloc, &arena, cards, i, is_hierarch, limits.max_string_value, limits.max_open_alloc);
                try temp.append(alloc, built.entry);
                i += built.consumed;
                continue;
            }

            const keyword = try put(alloc, &arena, card.name.text(), limits.max_open_alloc);
            const text = try put(alloc, &arena, trimEndSpaces(card.raw[8..]), limits.max_open_alloc);
            try temp.append(alloc, .{
                // `Card.Kind.commentary` is also the catch-all for a named record without `= `.
                // Only the FITS commentary names (COMMENT/HISTORY/blank) get the narrower ABI kind.
                .kind = if (card.kind == .blank)
                    .blank
                else if (card.kind == .commentary and card.name.isCommentary())
                    .commentary
                else
                    .other,
                .keyword = keyword,
                .commentary_text = text,
                .physical_first = i,
            });
            i += 1;
        }

        const owned_arena = try arena.toOwnedSlice(alloc);
        errdefer alloc.free(owned_arena);
        const entries = try alloc.alloc(Entry, temp.items.len);
        errdefer alloc.free(entries);
        for (temp.items, entries) |t, *out| out.* = materialize(t, owned_arena);
        return .{ .entries = entries, .arena = owned_arena, .physical_count = cards.len };
    }
};

/// One valued logical record parsed at a physical-card index. Unlike `Snapshot.build`, this owns
/// only the arena for the requested record and visits only that card plus its CONTINUE run. All
/// slices in `entry` point into `arena` and remain valid until `deinit`.
pub const ParsedAt = struct {
    entry: Entry,
    arena: []u8,

    pub fn deinit(self: *ParsedAt, alloc: Allocator) void {
        alloc.free(self.arena);
        self.* = undefined;
    }
};

/// Parse the valued record beginning at `first`. Returns `null` for END, commentary, blank, and
/// orphaned CONTINUE cards. This is the run-local counterpart to `Snapshot.build`: it deliberately
/// does not inspect unrelated cards before or after the requested logical record.
pub fn parseAt(alloc: Allocator, cards: []const Card, first: usize, limits: Limits) (errors.HeaderError || errors.LimitError || Allocator.Error)!?ParsedAt {
    if (first >= cards.len) return null;
    const card = &cards[first];
    const is_hierarch = hierarch.isHierarch(card) and hierarch.valueField(card) != null;
    if (card.kind != .value and !is_hierarch) return null;

    var arena: std.ArrayList(u8) = .empty;
    defer arena.deinit(alloc);
    const max_string = @min(@as(u64, limits.max_string_value), limits.max_open_alloc);
    const built = try parseValued(alloc, &arena, cards, first, is_hierarch, @intCast(max_string), limits.max_open_alloc);
    if (arena.items.len > limits.max_open_alloc) return error.LimitExceeded;
    const owned_arena = try arena.toOwnedSlice(alloc);
    return .{
        .entry = materialize(built.entry, owned_arena),
        .arena = owned_arena,
    };
}

fn put(alloc: Allocator, arena: *std.ArrayList(u8), bytes: []const u8, max_arena: u64) (errors.LimitError || Allocator.Error)!Ref {
    const off = arena.items.len;
    // Snapshot.build reserves its maximum up front; parseAt grows the same representation only as
    // the requested logical record needs it. Either way, all final slices share one owned arena.
    const needed = std.math.add(usize, off, bytes.len) catch return error.LimitExceeded;
    if (needed > max_arena) return error.LimitExceeded;
    if (needed > arena.capacity) try arena.ensureTotalCapacityPrecise(alloc, needed);
    arena.appendSliceAssumeCapacity(bytes);
    return .{ .off = off, .len = bytes.len, .present = true };
}

fn sliceOf(arena: []const u8, ref: Ref) []const u8 {
    return arena[ref.off .. ref.off + ref.len];
}

fn optionalSlice(arena: []const u8, ref: Ref) ?[]const u8 {
    return if (ref.present) sliceOf(arena, ref) else null;
}

fn materialize(t: TempEntry, arena: []const u8) Entry {
    return .{
        .kind = t.kind,
        .value = switch (t.value) {
            .none => .none,
            .undefined => .undefined,
            .logical => |v| .{ .logical = v },
            .int64 => |v| .{ .int64 = v },
            .integer_text => |r| .{ .integer_text = sliceOf(arena, r) },
            .float64 => |v| .{ .float64 = v },
            .string => |r| .{ .string = sliceOf(arena, r) },
            .raw_token => |r| .{ .raw_token = sliceOf(arena, r) },
        },
        .keyword = sliceOf(arena, t.keyword),
        .commentary_text = sliceOf(arena, t.commentary_text),
        .comment = optionalSlice(arena, t.comment),
        .physical_first = t.physical_first,
        .physical_count = t.physical_count,
        .hierarch = t.hierarch,
        .continued = t.continued,
        .malformed = t.malformed,
    };
}

const StringField = struct {
    escaped: []const u8,
    comment: ?[]const u8,
    is_string: bool,
    malformed: bool = false,
};

fn stringField(field: []const u8) StringField {
    var i: usize = 0;
    while (i < field.len and field[i] == ' ') i += 1;
    if (i == field.len or field[i] != '\'') return .{ .escaped = "", .comment = null, .is_string = false };
    i += 1;
    const start = i;
    while (i < field.len) {
        if (field[i] != '\'') {
            i += 1;
            continue;
        }
        if (i + 1 < field.len and field[i + 1] == '\'') {
            i += 2;
            continue;
        }
        const rest = std.mem.trimStart(u8, field[i + 1 ..], " ");
        if (rest.len == 0 or rest[0] == '/') {
            const comment = if (rest.len > 0) nonEmpty(std.mem.trim(u8, rest[1..], " ")) else null;
            return .{ .escaped = field[start..i], .comment = comment, .is_string = true };
        }
        // Astropy may put one half of a `''` escape at the end of this fragment. A quote followed
        // by content rather than blanks/comment is content, not the closing delimiter.
        i += 1;
    }
    return .{ .escaped = field[start..], .comment = null, .is_string = true, .malformed = true };
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

// Incrementally decodes the concatenated escaped fragments. Keeping a pending quote preserves an
// Astropy `''` pair split across two cards; keeping pending spaces out of `out` implements FITS
// trailing-blank trimming without allowing an arbitrarily long blank suffix to consume memory.
const StringDecoder = struct {
    out: std.ArrayList(u8) = .empty,
    pending_spaces: usize = 0,
    pending_quote: bool = false,
    max_len: usize,

    fn deinit(self: *StringDecoder, alloc: Allocator) void {
        self.out.deinit(alloc);
    }

    fn feed(self: *StringDecoder, alloc: Allocator, escaped: []const u8) (errors.LimitError || Allocator.Error)!void {
        for (escaped) |c| {
            if (self.pending_quote) {
                self.pending_quote = false;
                if (c == '\'') {
                    try self.emit(alloc, '\'');
                    continue;
                }
                // A lone quote is retained verbatim, matching `unescape`'s permissive behavior.
                try self.emit(alloc, '\'');
            }
            if (c == '\'') {
                self.pending_quote = true;
            } else {
                try self.emit(alloc, c);
            }
        }
    }

    fn finish(self: *StringDecoder, alloc: Allocator) (errors.LimitError || Allocator.Error)!void {
        if (self.pending_quote) {
            self.pending_quote = false;
            try self.emit(alloc, '\'');
        }
        // pending_spaces intentionally remain unmaterialized: FITS strings ignore trailing blanks.
    }

    fn emit(self: *StringDecoder, alloc: Allocator, c: u8) (errors.LimitError || Allocator.Error)!void {
        if (c == ' ') {
            self.pending_spaces = std.math.add(usize, self.pending_spaces, 1) catch return error.LimitExceeded;
            return;
        }
        const with_spaces = std.math.add(usize, self.out.items.len, self.pending_spaces) catch return error.LimitExceeded;
        const needed = std.math.add(usize, with_spaces, 1) catch return error.LimitExceeded;
        if (needed > self.max_len) return error.LimitExceeded;
        if (needed > self.out.capacity) {
            const doubled = std.math.mul(usize, self.out.capacity, 2) catch self.max_len;
            const target = @min(self.max_len, @max(needed, @max(@as(usize, 64), doubled)));
            try self.out.ensureTotalCapacityPrecise(alloc, target);
        }
        self.out.appendNTimesAssumeCapacity(' ', self.pending_spaces);
        self.pending_spaces = 0;
        self.out.appendAssumeCapacity(c);
    }
};

fn parseValued(alloc: Allocator, arena: *std.ArrayList(u8), cards: []const Card, first: usize, is_hierarch: bool, max_string: u32, max_arena: u64) !struct { entry: TempEntry, consumed: usize } {
    const base = &cards[first];
    const keyword_bytes = if (is_hierarch) hierarchName(base) else base.name.text();
    const keyword = try put(alloc, arena, keyword_bytes, max_arena);
    const field = if (is_hierarch) hierarch.valueField(base).? else base.valueField();
    const sf = stringField(field);

    if (sf.is_string) {
        var decoded: StringDecoder = .{ .max_len = max_string };
        defer decoded.deinit(alloc);
        var comment = sf.comment;
        var malformed = sf.malformed;
        var consumed: usize = 1;
        const starts_run = sf.escaped.len > 0 and sf.escaped[sf.escaped.len - 1] == '&' and
            first + 1 < cards.len and cards[first + 1].kind == .continuation;
        if (starts_run) {
            try decoded.feed(alloc, sf.escaped[0 .. sf.escaped.len - 1]);
            var j = first + 1;
            while (j < cards.len and cards[j].kind == .continuation) : (j += 1) {
                const frag = stringField(cards[j].raw[8..]);
                if (!frag.is_string) {
                    malformed = true;
                    break;
                }
                consumed += 1;
                malformed = malformed or frag.malformed;
                if (frag.comment) |c| comment = c;
                const more = frag.escaped.len > 0 and frag.escaped[frag.escaped.len - 1] == '&' and
                    j + 1 < cards.len and cards[j + 1].kind == .continuation;
                if (more) {
                    try decoded.feed(alloc, frag.escaped[0 .. frag.escaped.len - 1]);
                } else {
                    try decoded.feed(alloc, frag.escaped);
                    break;
                }
            }
        } else {
            try decoded.feed(alloc, sf.escaped);
        }
        try decoded.finish(alloc);
        const value_ref = try put(alloc, arena, decoded.out.items, max_arena);
        return .{ .entry = .{
            .kind = .value,
            .value = .{ .string = value_ref },
            .keyword = keyword,
            .comment = if (comment) |c| try put(alloc, arena, c, max_arena) else .{},
            .physical_first = first,
            .physical_count = consumed,
            .hierarch = is_hierarch,
            .continued = starts_run,
            .malformed = malformed,
        }, .consumed = consumed };
    }

    const parsed = try parseToken(alloc, arena, field, max_arena);
    return .{ .entry = .{
        .kind = .value,
        .value = parsed.value,
        .keyword = keyword,
        .comment = parsed.comment,
        .physical_first = first,
        .hierarch = is_hierarch,
        .malformed = parsed.malformed,
    }, .consumed = 1 };
}

fn hierarchName(card: *const Card) []const u8 {
    const rest = card.raw[8..];
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return "";
    return std.mem.trim(u8, rest[0..eq], " ");
}

fn parseToken(alloc: Allocator, arena: *std.ArrayList(u8), field: []const u8, max_arena: u64) !struct { value: TempValue, comment: Ref, malformed: bool } {
    const slash = std.mem.indexOfScalar(u8, field, '/');
    const token = std.mem.trim(u8, if (slash) |s| field[0..s] else field, " ");
    const comment: Ref = if (slash) |s| blk: {
        const c = std.mem.trim(u8, field[s + 1 ..], " ");
        break :blk if (c.len == 0) .{} else try put(alloc, arena, c, max_arena);
    } else .{};
    if (token.len == 0) return .{ .value = .undefined, .comment = comment, .malformed = false };
    if (std.mem.eql(u8, token, "T")) return .{ .value = .{ .logical = true }, .comment = comment, .malformed = false };
    if (std.mem.eql(u8, token, "F")) return .{ .value = .{ .logical = false }, .comment = comment, .malformed = false };
    if (isIntegerToken(token)) {
        const n = std.fmt.parseInt(i64, token, 10) catch {
            return .{ .value = .{ .integer_text = try put(alloc, arena, token, max_arena) }, .comment = comment, .malformed = false };
        };
        return .{ .value = .{ .int64 = n }, .comment = comment, .malformed = false };
    }
    if (isRealToken(token)) {
        var buf: [96]u8 = undefined;
        if (token.len <= buf.len) {
            @memcpy(buf[0..token.len], token);
            for (buf[0..token.len]) |*c| if (c.* == 'D' or c.* == 'd') {
                c.* = 'E';
            };
            const n = std.fmt.parseFloat(f64, buf[0..token.len]) catch null;
            if (n) |f| if (std.math.isFinite(f)) return .{ .value = .{ .float64 = f }, .comment = comment, .malformed = false };
        }
    }
    return .{ .value = .{ .raw_token = try put(alloc, arena, token, max_arena) }, .comment = comment, .malformed = true };
}

fn isIntegerToken(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = if (s[0] == '+' or s[0] == '-') 1 else 0;
    if (i == s.len) return false;
    while (i < s.len) : (i += 1) if (!std.ascii.isDigit(s[i])) return false;
    return true;
}

fn isRealToken(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (i < s.len and (s[i] == 'E' or s[i] == 'e' or s[i] == 'D' or s[i] == 'd')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == exp_start) return false;
    }
    return i == s.len and (std.mem.indexOfScalar(u8, s, '.') != null or
        std.mem.indexOfScalar(u8, s, 'E') != null or
        std.mem.indexOfScalar(u8, s, 'e') != null or
        std.mem.indexOfScalar(u8, s, 'D') != null or
        std.mem.indexOfScalar(u8, s, 'd') != null);
}

fn trimEndSpaces(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " ");
}

// ── tests ────────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

fn card80(text: []const u8) Card {
    var raw: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(raw[0..text.len], text);
    return Card.parse(&raw) catch unreachable;
}

test "logical snapshot keeps values, commentary, oversized integers, and raw tokens" {
    const cards = [_]Card{
        card80("COUNT   =                  123 / count"),
        card80("HUGE    = 1234567890123456789012345"),
        card80("ODD     = (1, 2) / complex stays opaque"),
        card80("COMMENT note"),
        card80("END"),
    };
    var snap = try Snapshot.build(testing.allocator, &cards, .{});
    defer snap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), snap.entries.len);
    try testing.expectEqual(@as(i64, 123), snap.entries[0].value.int64);
    try testing.expectEqualStrings("count", snap.entries[0].comment.?);
    try testing.expectEqualStrings("1234567890123456789012345", snap.entries[1].value.integer_text);
    try testing.expectEqualStrings("(1, 2)", snap.entries[2].value.raw_token);
    try testing.expectEqualStrings("note", snap.entries[3].commentary_text);
}

test "logical snapshot folds a quote escape split across standard CONTINUE cards" {
    const cards = [_]Card{
        card80("LONGSTR = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'&'"),
        card80("CONTINUE  ''bbbb' / final"),
        card80("END"),
    };
    var snap = try Snapshot.build(testing.allocator, &cards, .{});
    defer snap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), snap.entries.len);
    try testing.expect(snap.entries[0].continued);
    try testing.expectEqual(@as(usize, 2), snap.entries[0].physical_count);
    try testing.expect(std.mem.endsWith(u8, snap.entries[0].value.string, "'bbbb"));
    try testing.expectEqualStrings("final", snap.entries[0].comment.?);
}

test "logical snapshot folds HIERARCH plus CONTINUE" {
    const cards = [_]Card{
        card80("HIERARCH ESO LONG STR = 'alpha&'"),
        card80("CONTINUE  'beta' / provenance"),
        card80("END"),
    };
    var snap = try Snapshot.build(testing.allocator, &cards, .{});
    defer snap.deinit(testing.allocator);
    try testing.expectEqualStrings("ESO LONG STR", snap.entries[0].keyword);
    try testing.expectEqualStrings("alphabeta", snap.entries[0].value.string);
    try testing.expect(snap.entries[0].hierarch);
    try testing.expectEqualStrings("provenance", snap.entries[0].comment.?);
}

test "parseAt enforces string limit before allocating a long escaped run" {
    var cards: [128]Card = undefined;
    cards[0] = card80("LONGSTR = '                                                             &'");
    for (cards[1 .. cards.len - 1]) |*card| {
        card.* = card80("CONTINUE  '                                                             &'");
    }
    cards[cards.len - 1] = card80("CONTINUE  'ab'");

    // The physical run contains several KiB of escaped fragments, but max_string_value is one.
    // A tiny allocator must therefore observe LimitExceeded, never OOM from buffering the run.
    var backing: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const limits: Limits = .{ .max_string_value = 1 };
    try testing.expectError(error.LimitExceeded, parseAt(fixed.allocator(), &cards, 0, limits));
}
