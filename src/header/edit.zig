//! Transactional, non-structural header edits for the binding-facing API.
//!
//! `apply` clones the source `Header`, applies a borrowed list of operations in declaration order,
//! and returns the staged header only when every operation succeeds. The source is never modified.
//! Device I/O is deliberately outside this module: callers validate the complete staged header,
//! then commit it with the file-handle layer exactly once.
const std = @import("std");
const errors = @import("../errors.zig");
const limits_mod = @import("../limits.zig");
const Limits = limits_mod.Limits;
const Card = @import("card.zig").Card;
const Header = @import("header.zig").Header;
const Name = @import("name.zig").Name;
const keyword_value = @import("value.zig");
const continuation = @import("continue.zig");
const hierarch = @import("hierarch.zig");
const logical_header = @import("logical.zig");

const Allocator = std.mem.Allocator;

/// A borrowed value supplied by an edit. String storage belongs to the caller and only has to
/// remain live for the duration of `apply`; all generated cards contain their own bytes.
pub const Value = union(enum) {
    int: i64,
    float: f64,
    complex_int: [2]i64,
    complex_float: [2]f64,
    logical: bool,
    string: []const u8,
    undefined,

    fn asKeywordValue(self: Value) keyword_value.KeywordValue {
        return switch (self) {
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .complex_int => |v| .{ .complex_int = v },
            .complex_float => |v| .{ .complex_float = v },
            .logical => |v| .{ .logical = v },
            .string => |v| .{ .string = v },
            .undefined => .undefined,
        };
    }
};

/// Comment policy for an upsert. `preserve` retains the first matching logical record's effective
/// comment and means no comment for a newly inserted key. `explicit = null` removes a comment;
/// `explicit = slice` replaces it (an empty slice is equivalent to no comment on serialization).
pub const Comment = union(enum) {
    preserve,
    explicit: ?[]const u8,
};

pub const Upsert = struct {
    name: []const u8,
    value: Value,
    comment: Comment = .preserve,
};

pub const Rename = struct {
    old: []const u8,
    new: []const u8,
};

pub const Commentary = struct {
    /// Must be `COMMENT`, `HISTORY`, or the empty keyword (case-insensitive).
    keyword: []const u8,
    text: []const u8,
};

pub const RawInsert = struct {
    /// Physical card index in the staged header. The run is inserted before the card at `index`;
    /// `index == END` inserts immediately before END. Inserting after END is invalid.
    index: usize,
    cards: []const [80]u8,
};

/// One borrowed staged operation. Every slice is read only during `apply`.
pub const Edit = union(enum) {
    upsert: Upsert,
    /// Delete the first logical record named by the payload; absence is `KeywordNotFound`.
    delete_first: []const u8,
    /// Delete every logical record named by the payload; absence is a successful no-op.
    delete_all: []const u8,
    rename: Rename,
    append_commentary: Commentary,
    /// Append a parsed raw-card run immediately before END.
    append_raw: []const [80]u8,
    /// Insert a parsed raw-card run at a physical staged-header index.
    insert_raw: RawInsert,
    /// Insert this many all-space reserved cards immediately before END.
    reserve_blanks: usize,
};

pub const ApplyError = errors.HeaderError || errors.HeaderEditError || errors.ValueError || errors.LimitError || Allocator.Error;

/// Apply `edits` sequentially to an allocator-owned clone of `source`.
///
/// On success the caller owns the returned `Header` and must call `deinit(alloc)`. On any failure,
/// all staged storage is discarded and `source` remains byte-for-byte unchanged. The output always
/// has exactly one final END card, even when the input was missing END or contained duplicates.
pub fn apply(alloc: Allocator, source: *const Header, edits: []const Edit) ApplyError!Header {
    return applyInternal(alloc, source, edits, Limits{}, null);
}

/// Variant used by descriptor-based ABIs that need to report which sequential operation failed.
/// `failed_index` is set to `edits.len` until an operation returns an error.
pub fn applyWithFailure(alloc: Allocator, source: *const Header, edits: []const Edit, failed_index: *usize) ApplyError!Header {
    failed_index.* = edits.len;
    return applyInternal(alloc, source, edits, Limits{}, failed_index);
}

/// Limits-aware descriptor-ABI entry point. Resource ceilings are checked before cloning or
/// growing a card array, and the same limits are used by the one logical parse needed for a
/// layout-changing rename. The default wrappers above preserve the original API.
pub fn applyWithFailureAndLimits(
    alloc: Allocator,
    source: *const Header,
    edits: []const Edit,
    limits: Limits,
    failed_index: *usize,
) ApplyError!Header {
    failed_index.* = edits.len;
    return applyInternal(alloc, source, edits, limits, failed_index);
}

fn applyInternal(alloc: Allocator, source: *const Header, edits: []const Edit, limits: Limits, failed_index: ?*usize) ApplyError!Header {
    var staged = try cloneNormalized(alloc, source, limits);
    errdefer staged.deinit(alloc);

    for (edits, 0..) |edit, i| applyOne(alloc, &staged, edit, limits) catch |err| {
        if (failed_index) |out| out.* = i;
        return err;
    };

    // No operation may introduce END, and cloneNormalized established this invariant. Keep this
    // defensive normalization local so future operation kinds cannot accidentally weaken it.
    try normalizeEndInPlace(alloc, &staged);
    return staged;
}

fn applyOne(alloc: Allocator, staged: *Header, edit: Edit, limits: Limits) ApplyError!void {
    switch (edit) {
        .upsert => |op| try applyUpsert(alloc, staged, op, limits),
        .delete_first => |name| try deleteFirst(staged, name),
        .delete_all => |name| try deleteAll(staged, name),
        .rename => |op| try applyRename(alloc, staged, op, limits),
        .append_commentary => |op| try appendCommentary(alloc, staged, op, limits),
        .append_raw => |raws| try insertRawRun(alloc, staged, endIndex(staged), raws, limits),
        .insert_raw => |op| try insertRawRun(alloc, staged, op.index, op.cards, limits),
        .reserve_blanks => |n| {
            const new_count = std.math.add(usize, staged.cards.items.len, n) catch return error.LimitExceeded;
            try ensureCardCount(new_count, limits);
            try staged.cards.ensureTotalCapacityPrecise(alloc, new_count);
            try staged.reserveSpace(alloc, n);
        },
    }
}

fn cloneNormalized(alloc: Allocator, source: *const Header, limits: Limits) (errors.LimitError || Allocator.Error)!Header {
    var out = Header.initEmpty();
    errdefer out.deinit(alloc);
    out.inherit = source.inherit;
    var count: usize = 1; // one normalized final END
    for (source.cards.items) |card| if (card.kind != .end) {
        count = std.math.add(usize, count, 1) catch return error.LimitExceeded;
    };
    try ensureCardCount(count, limits);
    try out.cards.ensureTotalCapacityPrecise(alloc, count);
    for (source.cards.items) |card| {
        if (card.kind != .end) out.cards.appendAssumeCapacity(card);
    }
    out.cards.appendAssumeCapacity(endCard());
    return out;
}

fn normalizeEndInPlace(alloc: Allocator, header: *Header) Allocator.Error!void {
    var i: usize = 0;
    while (i < header.cards.items.len) {
        if (header.cards.items[i].kind == .end) {
            _ = header.cards.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    try header.cards.append(alloc, endCard());
}

fn endCard() Card {
    var raw: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(raw[0..3], "END");
    return Card.parse(&raw) catch unreachable;
}

fn endIndex(header: *const Header) usize {
    for (header.cards.items, 0..) |*card, i| if (card.kind == .end) return i;
    return header.cards.items.len;
}

fn cardCeiling(limits: Limits) errors.LimitError!usize {
    const by_blocks = try limits_mod.mul(limits.max_header_blocks, 36);
    const by_alloc = limits.max_open_alloc / @sizeOf(Card);
    return std.math.cast(usize, @min(by_blocks, by_alloc)) orelse error.LimitExceeded;
}

fn ensureCardCount(count: usize, limits: Limits) errors.LimitError!void {
    if (count > try cardCeiling(limits)) return error.LimitExceeded;
}

fn ensureValueLimits(v: Value, limits: Limits) errors.LimitError!void {
    switch (v) {
        .string => |s| if (s.len > limits.max_string_value) return error.LimitExceeded,
        else => {},
    }
}

fn checkedEscapedLen(s: []const u8) errors.LimitError!usize {
    var len = s.len;
    for (s) |c| if (c == '\'') {
        len = std.math.add(usize, len, 1) catch return error.LimitExceeded;
    };
    return len;
}

fn publicName(name: []const u8) []const u8 {
    var n = std.mem.trim(u8, name, " ");
    if (n.len >= 9 and std.ascii.eqlIgnoreCase(n[0..9], "HIERARCH ")) {
        n = std.mem.trimStart(u8, n[9..], " ");
    }
    return n;
}

/// Binding-level structural policy: these cards describe the HDU/data layout and cannot be changed
/// through a user-header transaction. Table/compression reconstruction applies its own additional
/// filtering before it constructs edits.
pub fn isStructural(name: []const u8) bool {
    const n = publicName(name);
    const exact = [_][]const u8{
        "SIMPLE",  "BITPIX",   "NAXIS",    "EXTEND",   "PCOUNT",   "GCOUNT",
        "GROUPS",  "XTENSION", "END",      "BSCALE",   "BZERO",    "TFIELDS",
        "THEAP",   "ZIMAGE",   "ZSIMPLE",  "ZEXTEND",  "ZBITPIX",  "ZNAXIS",
        "ZPCOUNT", "ZGCOUNT",  "ZCMPTYPE", "ZMASKCMP", "ZQUANTIZ", "ZDITHER0",
        "ZBLANK",  "ZHECKSUM", "ZDATASUM", "ZTHEAP",   "ZTABLE",   "ZTILELEN",
    };
    for (exact) |kw| if (std.ascii.eqlIgnoreCase(n, kw)) return true;
    // NAXIS historically rejects every prefixed spelling, not only a numeric suffix. The other
    // families are indexed physical-layout descriptors and require at least one decimal digit.
    if (std.ascii.startsWithIgnoreCase(n, "NAXIS")) return true;
    const indexed = [_][]const u8{ "TFORM", "TBCOL", "ZNAXIS", "ZTILE", "ZNAME", "ZVAL", "ZFORM", "ZCTYP" };
    for (indexed) |prefix| if (hasNumericSuffix(n, prefix)) return true;
    return false;
}

fn hasNumericSuffix(name: []const u8, prefix: []const u8) bool {
    if (name.len <= prefix.len or !std.ascii.startsWithIgnoreCase(name, prefix)) return false;
    for (name[prefix.len..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn rejectStructural(name: []const u8) errors.HeaderEditError!void {
    if (isStructural(name)) return error.StructuralKeyword;
}

fn isCommentaryName(name: []const u8) bool {
    const n = std.mem.trim(u8, name, " ");
    return n.len == 0 or std.ascii.eqlIgnoreCase(n, "COMMENT") or std.ascii.eqlIgnoreCase(n, "HISTORY");
}

fn isHierarchName(name: []const u8) bool {
    const n = std.mem.trim(u8, name, " ");
    return (n.len >= 9 and std.ascii.eqlIgnoreCase(n[0..9], "HIERARCH ")) or
        n.len > 8 or std.mem.indexOfScalar(u8, n, ' ') != null;
}

const Run = struct {
    first: usize,
    count: usize,
    hierarch: bool,
};

fn fieldStartsString(field: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, field, " ");
    return trimmed.len > 0 and trimmed[0] == '\'';
}

fn baseValueField(card: *const Card) ?[]const u8 {
    if (hierarch.isHierarch(card)) return hierarch.valueField(card);
    return if (card.kind == .value) card.valueField() else null;
}

/// Return the logical run beginning at `first` without parsing or allocating. A CONTINUE card is
/// folded only when the preceding string has an `&` sentinel and the fragment itself begins with
/// a string. This mirrors the permissive snapshot scanner, including Astropy's split `''` pair.
fn physicalRunAt(cards: []const Card, first: usize) Run {
    const card = &cards[first];
    const is_hierarch = hierarch.isHierarch(card) and hierarch.valueField(card) != null;
    var run: Run = .{ .first = first, .count = 1, .hierarch = is_hierarch };
    const first_field = baseValueField(card) orelse return run;
    if (!continuation.endsWithSentinel(first_field)) return run;

    var next = first + 1;
    while (next < cards.len and cards[next].kind == .continuation) {
        const field = cards[next].raw[8..];
        if (!fieldStartsString(field)) break;
        run.count += 1;
        next += 1;
        if (!continuation.endsWithSentinel(field)) break;
    }
    return run;
}

fn runMatches(cards: []const Card, run: Run, name: []const u8) bool {
    const card = &cards[run.first];
    return if (run.hierarch)
        hierarch.matchName(card, publicName(name))
    else
        card.name.eqlText(publicName(name));
}

// Snapshot lookup remains a test oracle for the physical scanner; edit operations do not call it.
fn findSnapshotEntry(snapshot: *const logical_header.Snapshot, name: []const u8) ?*const logical_header.Entry {
    const query = publicName(name);
    for (snapshot.entries) |*entry| {
        if (!entry.hierarch and std.ascii.eqlIgnoreCase(entry.keyword, query)) return entry;
        if (entry.hierarch) {
            var ia = std.mem.tokenizeScalar(u8, entry.keyword, ' ');
            var ib = std.mem.tokenizeScalar(u8, query, ' ');
            var equal = true;
            while (true) {
                const a = ia.next();
                const b = ib.next();
                if (a == null or b == null) {
                    equal = a == null and b == null;
                    break;
                }
                if (!std.ascii.eqlIgnoreCase(a.?, b.?)) {
                    equal = false;
                    break;
                }
            }
            if (equal) return entry;
        }
    }
    return null;
}

fn findRun(header: *const Header, name: []const u8) ?Run {
    var i: usize = 0;
    while (i < header.cards.items.len) {
        if (header.cards.items[i].kind == .end) return null;
        const run = physicalRunAt(header.cards.items, i);
        if (runMatches(header.cards.items, run, name)) return run;
        i += run.count;
    }
    return null;
}

fn removeRun(header: *Header, run: Run) void {
    header.cards.replaceRangeAssumeCapacity(run.first, run.count, &.{});
}

fn fieldComment(field: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < field.len and field[i] == ' ') i += 1;
    if (i == field.len or field[i] != '\'') return keyword_value.parseComment(field);
    i += 1;
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
        if (rest.len == 0) return null;
        if (rest[0] == '/') {
            const comment = std.mem.trim(u8, rest[1..], " ");
            return if (comment.len == 0) null else comment;
        }
        // A quote followed by content can be one half of a doubled quote split across cards.
        i += 1;
    }
    return null;
}

fn effectiveComment(cards: []const Card, run: Run) ?[]const u8 {
    var out = if (baseValueField(&cards[run.first])) |field| fieldComment(field) else null;
    var i: usize = 1;
    while (i < run.count) : (i += 1) {
        if (fieldComment(cards[run.first + i].raw[8..])) |comment| out = comment;
    }
    return out;
}

fn deleteFirst(header: *Header, name: []const u8) ApplyError!void {
    try rejectStructural(name);
    const run = findRun(header, name) orelse return error.KeywordNotFound;
    removeRun(header, run);
}

fn deleteAll(header: *Header, name: []const u8) ApplyError!void {
    try rejectStructural(name);
    // Compact all non-matching logical runs in one pass. This avoids both the snapshot allocation
    // and the quadratic tail shifting caused by repeated orderedRemove calls.
    const old_len = header.cards.items.len;
    var read: usize = 0;
    var write: usize = 0;
    while (read < old_len) {
        const run = physicalRunAt(header.cards.items[0..old_len], read);
        if (!runMatches(header.cards.items[0..old_len], run, name)) {
            if (write != read) @memmove(header.cards.items[write .. write + run.count], header.cards.items[read .. read + run.count]);
            write += run.count;
        }
        read += run.count;
    }
    header.cards.items.len = write;
}

fn applyUpsert(alloc: Allocator, header: *Header, op: Upsert, limits: Limits) ApplyError!void {
    try rejectStructural(op.name);
    if (isCommentaryName(op.name)) return error.InvalidHeaderOperation;
    try ensureValueLimits(op.value, limits);

    const old = findRun(header, op.name);
    const comment: ?[]const u8 = switch (op.comment) {
        .preserve => if (old) |run| effectiveComment(header.cards.items, run) else null,
        .explicit => |c| c,
    };
    try preflightValueRun(header, if (old) |run| run.count else 0, op.name, op.value, comment, limits);
    const cards = try buildValueRun(alloc, op.name, op.value, comment);
    defer alloc.free(cards);

    if (old) |run| {
        try replaceRun(alloc, header, run.first, run.count, cards, limits);
    } else {
        try insertUsingReservedBlanks(alloc, header, cards, limits);
    }
}

fn generatedCardUpperBound(name: []const u8, edit_value: Value, comment: ?[]const u8, limits: Limits) errors.LimitError!usize {
    if (edit_value != .string) return 1;
    const str = edit_value.string;
    const escaped = try checkedEscapedLen(str);
    if (escaped > limits.max_open_alloc) return error.LimitExceeded;

    const comment_len = if (comment) |c| c.len else 0;
    const comment_cost = if (comment != null)
        std.math.add(usize, comment_len, 3) catch return error.LimitExceeded
    else
        0;
    if (!isHierarchName(name)) {
        const padded = std.math.add(usize, escaped, if (str.len < keyword_value.MIN_STRING_CHARS) keyword_value.MIN_STRING_CHARS - str.len else 0) catch
            return error.LimitExceeded;
        if (comment_cost <= 68 and padded <= 68 - comment_cost) return 1;
    } else {
        const tokens = publicName(name);
        const prefix = std.math.add(usize, 12, tokens.len) catch return error.LimitExceeded;
        // HIERARCH ignores an explicitly empty comment.
        const hcost = if (comment_len == 0) 0 else comment_cost;
        if (prefix <= 78 and escaped <= 78 - prefix and hcost <= 80 - prefix - 2 - escaped) return 1;
        if (escaped == 0) return 1;
    }

    // A pair-safe CONTINUE data card carries at least 66 escaped bytes after the possibly narrow
    // HIERARCH base card. Two extra cards conservatively cover that base and a dedicated comment.
    const chunks = std.math.divCeil(usize, escaped, 66) catch unreachable;
    return std.math.add(usize, chunks, 2) catch return error.LimitExceeded;
}

fn contiguousBlankCount(header: *const Header) usize {
    const first = firstBlankBeforeEnd(header) orelse return 0;
    const end = endIndex(header);
    var n: usize = 0;
    while (first + n < end and header.cards.items[first + n].kind == .blank) : (n += 1) {}
    return n;
}

fn preflightValueRun(
    header: *const Header,
    replaced_count: usize,
    name: []const u8,
    edit_value: Value,
    comment: ?[]const u8,
    limits: Limits,
) errors.LimitError!void {
    const upper = try generatedCardUpperBound(name, edit_value, comment, limits);
    try ensureCardCount(upper, limits); // serializer's temporary []Card allocation
    const consumed_blanks = if (replaced_count == 0) @min(upper, contiguousBlankCount(header)) else 0;
    const removed = std.math.add(usize, replaced_count, consumed_blanks) catch return error.LimitExceeded;
    const base = header.cards.items.len - removed;
    const projected = std.math.add(usize, base, upper) catch return error.LimitExceeded;
    try ensureCardCount(projected, limits);
}

fn buildValueRun(alloc: Allocator, name: []const u8, edit_value: Value, comment: ?[]const u8) ApplyError![]Card {
    const v = edit_value.asKeywordValue();
    if (isHierarchName(name)) return hierarch.split(alloc, name, v, comment);
    if (v == .string) return continuation.split(alloc, name, v.string, comment);
    const one = try alloc.alloc(Card, 1);
    errdefer alloc.free(one);
    one[0] = try Card.buildValue(name, v, comment);
    return one;
}

fn firstBlankBeforeEnd(header: *const Header) ?usize {
    for (header.cards.items, 0..) |*card, i| {
        if (card.kind == .end) return null;
        if (card.kind == .blank) return i;
    }
    return null;
}

fn replaceRun(
    alloc: Allocator,
    header: *Header,
    first: usize,
    old_count: usize,
    cards: []const Card,
    limits: Limits,
) (errors.LimitError || Allocator.Error)!void {
    const base = header.cards.items.len - old_count;
    const new_count = std.math.add(usize, base, cards.len) catch return error.LimitExceeded;
    try ensureCardCount(new_count, limits);
    if (new_count > header.cards.capacity) try header.cards.ensureTotalCapacityPrecise(alloc, new_count);
    header.cards.replaceRangeAssumeCapacity(first, old_count, cards);
}

fn insertUsingReservedBlanks(alloc: Allocator, header: *Header, cards: []const Card, limits: Limits) (errors.LimitError || Allocator.Error)!void {
    if (cards.len == 0) return;
    const first = firstBlankBeforeEnd(header) orelse {
        try replaceRun(alloc, header, endIndex(header), 0, cards, limits);
        return;
    };
    var blanks: usize = 0;
    const end = endIndex(header);
    while (blanks < cards.len and first + blanks < end and header.cards.items[first + blanks].kind == .blank) : (blanks += 1) {}
    try replaceRun(alloc, header, first, blanks, cards, limits);
}

fn applyRename(alloc: Allocator, header: *Header, op: Rename, limits: Limits) ApplyError!void {
    try rejectStructural(op.old);
    try rejectStructural(op.new);
    if (isCommentaryName(op.old) or isCommentaryName(op.new)) return error.InvalidHeaderOperation;

    const run = findRun(header, op.old) orelse return error.KeywordNotFound;

    // Fixed-name to fixed-name retains the exact value/comment bytes and continuation fragments,
    // so it needs neither allocation nor a logical value parse.
    if (!run.hierarch and !isHierarchName(op.new)) {
        const new_name = try Name.parseStrict(op.new);
        var raw = header.cards.items[run.first].raw;
        @memcpy(raw[0..8], &new_name.bytes);
        header.cards.items[run.first] = try Card.parse(&raw);
        return;
    }

    // A transition involving HIERARCH changes the base card's available width. Parse only the
    // matched physical run, under the caller's limits, to obtain a typed value for reconstruction.
    var snapshot = try logical_header.Snapshot.build(alloc, header.cards.items[run.first .. run.first + run.count], limits);
    defer snapshot.deinit(alloc);
    const entry = if (snapshot.entries.len > 0) &snapshot.entries[0] else return error.InvalidHeaderOperation;

    const edit_value: Value = switch (entry.value) {
        .undefined => .undefined,
        .logical => |v| .{ .logical = v },
        .int64 => |v| .{ .int = v },
        .float64 => |v| .{ .float = v },
        .string => |v| .{ .string = v },
        // Opaque and wider-than-i64 tokens have no safe typed reserializer. A same-width standard
        // rename took the byte-preserving branch above; changing their layout fails atomically.
        .none, .integer_text, .raw_token => return error.InvalidHeaderOperation,
    };
    try ensureValueLimits(edit_value, limits);
    try preflightValueRun(header, run.count, op.new, edit_value, entry.comment, limits);
    const cards = try buildValueRun(alloc, op.new, edit_value, entry.comment);
    defer alloc.free(cards);
    try replaceRun(alloc, header, run.first, run.count, cards, limits);
}

fn appendCommentary(alloc: Allocator, header: *Header, op: Commentary, limits: Limits) ApplyError!void {
    if (!isCommentaryName(op.keyword)) return error.InvalidHeaderOperation;
    const trimmed = std.mem.trim(u8, op.keyword, " ");
    const keyword = if (trimmed.len == 0) "" else if (std.ascii.eqlIgnoreCase(trimmed, "COMMENT")) "COMMENT" else "HISTORY";

    const count = if (op.text.len == 0) 1 else std.math.divCeil(usize, op.text.len, 72) catch unreachable;
    const new_count = std.math.add(usize, header.cards.items.len, count) catch return error.LimitExceeded;
    try ensureCardCount(new_count, limits);
    if (new_count > header.cards.capacity) try header.cards.ensureTotalCapacityPrecise(alloc, new_count);
    const slots = header.cards.addManyAtAssumeCapacity(endIndex(header), count);
    if (op.text.len == 0) {
        slots[0] = try buildCommentaryCard(keyword, "");
    } else {
        var pos: usize = 0;
        for (slots) |*slot| {
            const n = @min(@as(usize, 72), op.text.len - pos);
            slot.* = try buildCommentaryCard(keyword, op.text[pos .. pos + n]);
            pos += n;
        }
    }
}

fn buildCommentaryCard(keyword: []const u8, text: []const u8) errors.HeaderError!Card {
    if (keyword.len > 8 or text.len > 72) return error.CardOverflow;
    var raw: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(raw[0..keyword.len], keyword);
    @memcpy(raw[8 .. 8 + text.len], text);
    return Card.parse(&raw);
}

fn validateRawCard(card: *const Card) errors.HeaderEditError!void {
    if (card.kind == .end) return error.InvalidHeaderOperation;
    if (hierarch.isHierarch(card)) {
        var buf: [70]u8 = undefined;
        if (hierarch.keyword(card, &buf)) |name| try rejectStructural(name);
    } else {
        try rejectStructural(card.name.text());
    }
}

fn insertRawRun(alloc: Allocator, header: *Header, index: usize, raws: []const [80]u8, limits: Limits) ApplyError!void {
    const end = endIndex(header);
    if (index > end) return error.InvalidHeaderOperation;
    try ensureCardCount(raws.len, limits); // bounds the temporary parsed-card allocation
    const new_count = std.math.add(usize, header.cards.items.len, raws.len) catch return error.LimitExceeded;
    try ensureCardCount(new_count, limits);
    const parsed = try alloc.alloc(Card, raws.len);
    defer alloc.free(parsed);
    for (raws, 0..) |*raw, i| {
        parsed[i] = try Card.parse(raw);
        try validateRawCard(&parsed[i]);
    }
    try replaceRun(alloc, header, index, 0, parsed, limits);
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

fn raw80(text: []const u8) [80]u8 {
    std.debug.assert(text.len <= 80);
    var raw: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(raw[0..text.len], text);
    return raw;
}

fn headerOf(alloc: Allocator, texts: []const []const u8) !Header {
    var header = Header.initEmpty();
    errdefer header.deinit(alloc);
    for (texts) |text| {
        const raw = raw80(text);
        try header.appendRaw(alloc, &raw);
    }
    try header.ensureEnd(alloc);
    return header;
}

fn countNamed(header: *const Header, name: []const u8) usize {
    var n: usize = 0;
    for (header.cards.items) |*card| {
        if (hierarch.isHierarch(card)) {
            if (hierarch.matchName(card, name)) n += 1;
        } else if (card.name.eqlText(name)) {
            n += 1;
        }
    }
    return n;
}

fn expectOneFinalEnd(header: *const Header) !void {
    var count: usize = 0;
    for (header.cards.items, 0..) |card, i| {
        if (card.kind == .end) {
            count += 1;
            try testing.expectEqual(header.cards.items.len - 1, i);
        }
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "apply clones the source and runs mixed upserts sequentially" {
    var source = try headerOf(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
        "OBS     =                    1 / keep me",
    });
    defer source.deinit(testing.allocator);

    const long = "long value with a quote ' and ampersand &;" ** 4;
    const edits = [_]Edit{
        .{ .upsert = .{ .name = "OBS", .value = .{ .int = 2 } } }, // preserve comment
        .{ .upsert = .{ .name = "LSTR", .value = .{ .string = long }, .comment = .{ .explicit = "standard" } } },
        .{ .upsert = .{ .name = "ESO LONG KEY", .value = .{ .string = long }, .comment = .{ .explicit = "hierarch" } } },
        .{ .delete_first = "OBS" },
        .{ .upsert = .{ .name = "OBS", .value = .{ .int = 3 }, .comment = .{ .explicit = "final" } } },
    };
    var staged = try apply(testing.allocator, &source, &edits);
    defer staged.deinit(testing.allocator);

    // The source is untouched; operations see the output of every preceding operation.
    try testing.expectEqual(@as(i64, 1), try source.getValue(i64, "OBS"));
    try testing.expectEqual(@as(i64, 3), try staged.getValue(i64, "OBS"));
    try testing.expectEqualStrings("final", staged.comment("OBS").?);
    const standard = try staged.getLongString(testing.allocator, "LSTR");
    defer testing.allocator.free(standard);
    try testing.expectEqualStrings(long, standard);
    var snap = try logical_header.Snapshot.build(testing.allocator, staged.cards.items, .{});
    defer snap.deinit(testing.allocator);
    try testing.expect(findSnapshotEntry(&snap, "ESO LONG KEY").?.physical_count > 1);
    try expectOneFinalEnd(&staged);
}

test "delete_first is strict and delete_all removes duplicate logical runs" {
    var source = try headerOf(testing.allocator, &.{
        "DUP     =                    1",
        "DUP     =                    2",
        "COMMENT first",
        "COMMENT second",
    });
    defer source.deinit(testing.allocator);

    var staged = try apply(testing.allocator, &source, &.{
        .{ .delete_first = "dup" },
        .{ .delete_all = "COMMENT" },
        .{ .delete_all = "ABSENT" }, // deliberately a no-op
    });
    defer staged.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 2), try staged.getValue(i64, "DUP"));
    try testing.expectEqual(@as(usize, 1), countNamed(&staged, "DUP"));
    try testing.expectEqual(@as(usize, 0), countNamed(&staged, "COMMENT"));

    try testing.expectError(error.KeywordNotFound, apply(testing.allocator, &source, &.{.{ .delete_first = "ABSENT" }}));
}

test "rename preserves a standard long-string run and its comment" {
    var source = try headerOf(testing.allocator, &.{});
    defer source.deinit(testing.allocator);
    const cards = try continuation.split(testing.allocator, "OLD", "z" ** 150, "note");
    defer testing.allocator.free(cards);
    try source.cards.insertSlice(testing.allocator, 0, cards);

    var staged = try apply(testing.allocator, &source, &.{.{ .rename = .{ .old = "OLD", .new = "NEW" } }});
    defer staged.deinit(testing.allocator);
    try testing.expect(!staged.has("OLD"));
    const got = try staged.getLongString(testing.allocator, "NEW");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("z" ** 150, got);
    var snap = try logical_header.Snapshot.build(testing.allocator, staged.cards.items, .{});
    defer snap.deinit(testing.allocator);
    try testing.expectEqualStrings("note", findSnapshotEntry(&snap, "NEW").?.comment.?);
}

test "rename rebuilds transitions to and from HIERARCH without orphaning continuations" {
    var source = try headerOf(testing.allocator, &.{});
    defer source.deinit(testing.allocator);
    const original = "a quoted ' HIERARCH value &;" ** 6;
    const cards = try hierarch.split(testing.allocator, "ESO OLD LONG KEY", .{ .string = original }, "provenance");
    defer testing.allocator.free(cards);
    try source.cards.insertSlice(testing.allocator, 0, cards);

    var staged = try apply(testing.allocator, &source, &.{
        .{ .rename = .{ .old = "HIERARCH ESO OLD LONG KEY", .new = "MIDKEY" } },
        .{ .rename = .{ .old = "MIDKEY", .new = "HIERARCH ESO NEW LONG KEY" } },
    });
    defer staged.deinit(testing.allocator);
    var snap = try logical_header.Snapshot.build(testing.allocator, staged.cards.items, .{});
    defer snap.deinit(testing.allocator);
    try testing.expect(findSnapshotEntry(&snap, "ESO OLD LONG KEY") == null);
    try testing.expect(findSnapshotEntry(&snap, "MIDKEY") == null);
    const renamed = findSnapshotEntry(&snap, "ESO NEW LONG KEY").?;
    try testing.expect(renamed.hierarch and renamed.continued);
    try testing.expectEqualStrings(original, renamed.value.string);
    try testing.expectEqualStrings("provenance", renamed.comment.?);
    // The source run remains intact because the whole edit list operated on a clone.
    try testing.expect(source.has("ESO OLD LONG KEY"));
}

test "snapshot spans make Astropy split-quote runs replace and delete atomically" {
    var source = try headerOf(testing.allocator, &.{
        "LSTR    = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'&'",
        "CONTINUE  ''bbbb' / final comment",
        "AFTER   =                    9",
    });
    defer source.deinit(testing.allocator);
    var initial = try logical_header.Snapshot.build(testing.allocator, source.cards.items, .{});
    defer initial.deinit(testing.allocator);
    const old = findSnapshotEntry(&initial, "LSTR").?;
    try testing.expectEqual(@as(usize, 2), old.physical_count);
    try testing.expect(std.mem.endsWith(u8, old.value.string, "'bbbb"));

    var replaced = try apply(testing.allocator, &source, &.{.{ .upsert = .{
        .name = "LSTR",
        .value = .{ .string = "short" },
    } }});
    defer replaced.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), countNamed(&replaced, "CONTINUE"));
    const short = try replaced.getString(testing.allocator, "LSTR");
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("short", short);
    var replaced_snap = try logical_header.Snapshot.build(testing.allocator, replaced.cards.items, .{});
    defer replaced_snap.deinit(testing.allocator);
    try testing.expectEqualStrings("final comment", findSnapshotEntry(&replaced_snap, "LSTR").?.comment.?);

    var deleted = try apply(testing.allocator, &source, &.{.{ .delete_first = "LSTR" }});
    defer deleted.deinit(testing.allocator);
    try testing.expect(!deleted.has("LSTR"));
    try testing.expectEqual(@as(usize, 0), countNamed(&deleted, "CONTINUE"));
    try testing.expectEqual(@as(i64, 9), try deleted.getValue(i64, "AFTER"));
}

test "physical scanner folds split-quote CONTINUE runs without allocating" {
    var header = try headerOf(testing.allocator, &.{
        "LSTR    = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'&'",
        "CONTINUE  ''bbbb' / final comment",
        "KEEP    =                    9",
    });
    defer header.deinit(testing.allocator);

    const run = findRun(&header, "lstr").?;
    try testing.expectEqual(@as(usize, 0), run.first);
    try testing.expectEqual(@as(usize, 2), run.count);
    try testing.expect(!run.hierarch);
    try testing.expectEqualStrings("final comment", effectiveComment(header.cards.items, run).?);

    // A fixed-name rename and deletion need no allocator: only layout-changing HIERARCH renames
    // invoke the matched-run logical parser.
    var no_memory: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&no_memory);
    try applyRename(fba.allocator(), &header, .{ .old = "LSTR", .new = "RENAMED" }, Limits{});
    try testing.expectEqual(@as(usize, 2), findRun(&header, "RENAMED").?.count);
    try deleteFirst(&header, "RENAMED");
    try testing.expectEqual(@as(i64, 9), try header.getValue(i64, "KEEP"));
    try testing.expect(findRun(&header, "CONTINUE") == null);
}

test "limits-aware apply bounds clone growth serializers and failed index" {
    var source = try headerOf(testing.allocator, &.{"A       =                    1"});
    defer source.deinit(testing.allocator);

    var failed: usize = undefined;
    const three_cards: Limits = .{
        .max_header_blocks = 1,
        .max_open_alloc = 3 * @sizeOf(Card),
    };
    try testing.expectError(
        error.LimitExceeded,
        applyWithFailureAndLimits(testing.allocator, &source, &.{.{ .reserve_blanks = 2 }}, three_cards, &failed),
    );
    try testing.expectEqual(@as(usize, 0), failed);
    try testing.expectEqual(@as(usize, 2), source.count());

    // A one-card value fits exactly, while a generated long-string run is rejected by its
    // conservative card upper bound before the serializer allocates its []Card result.
    var short = try applyWithFailureAndLimits(testing.allocator, &source, &.{.{ .upsert = .{
        .name = "B",
        .value = .{ .string = "ok" },
    } }}, three_cards, &failed);
    defer short.deinit(testing.allocator);
    const short_value = try short.getString(testing.allocator, "B");
    defer testing.allocator.free(short_value);
    try testing.expectEqualStrings("ok", short_value);
    try testing.expectError(
        error.LimitExceeded,
        applyWithFailureAndLimits(testing.allocator, &source, &.{.{ .upsert = .{
            .name = "LONG",
            .value = .{ .string = "x" ** 200 },
        } }}, three_cards, &failed),
    );
    try testing.expectEqual(@as(usize, 0), failed);

    const short_strings: Limits = .{ .max_string_value = 3 };
    try testing.expectError(
        error.LimitExceeded,
        applyWithFailureAndLimits(testing.allocator, &source, &.{.{ .upsert = .{
            .name = "B",
            .value = .{ .string = "four" },
        } }}, short_strings, &failed),
    );
    try testing.expectEqual(@as(usize, 0), failed);
}

test "append_commentary wraps at 72 bytes and accepts COMMENT HISTORY and blank" {
    var source = try headerOf(testing.allocator, &.{});
    defer source.deinit(testing.allocator);
    const text = "0123456789" ** 10;
    var staged = try apply(testing.allocator, &source, &.{
        .{ .append_commentary = .{ .keyword = "comment", .text = text } },
        .{ .append_commentary = .{ .keyword = "HISTORY", .text = "" } },
        .{ .append_commentary = .{ .keyword = "", .text = "separator" } },
    });
    defer staged.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), countNamed(&staged, "COMMENT"));
    try testing.expectEqual(@as(usize, 1), countNamed(&staged, "HISTORY"));
    try testing.expectEqual(@as(usize, 1), countNamed(&staged, ""));
    var snap = try logical_header.Snapshot.build(testing.allocator, staged.cards.items, .{});
    defer snap.deinit(testing.allocator);
    const first_comment = findSnapshotEntry(&snap, "COMMENT").?;
    try testing.expectEqual(@as(usize, 72), std.mem.trimEnd(u8, staged.cards.items[first_comment.physical_first].commentaryText(), " ").len);
    try expectOneFinalEnd(&staged);

    try testing.expectError(
        error.InvalidHeaderOperation,
        apply(testing.allocator, &source, &.{.{ .append_commentary = .{ .keyword = "OBJECT", .text = "bad" } }}),
    );
}

test "raw runs append and insert in operation order but cannot introduce END or structure" {
    var source = try headerOf(testing.allocator, &.{"BASE    =                    1"});
    defer source.deinit(testing.allocator);
    const appended = [_][80]u8{raw80("TAIL    =                    3")};
    const inserted = [_][80]u8{ raw80("MID1    =                   10"), raw80("MID2    =                   20") };
    var staged = try apply(testing.allocator, &source, &.{
        .{ .append_raw = &appended },
        .{ .insert_raw = .{ .index = 1, .cards = &inserted } },
    });
    defer staged.deinit(testing.allocator);
    try testing.expectEqualStrings("BASE", staged.cards.items[0].name.text());
    try testing.expectEqualStrings("MID1", staged.cards.items[1].name.text());
    try testing.expectEqualStrings("MID2", staged.cards.items[2].name.text());
    try testing.expectEqualStrings("TAIL", staged.cards.items[3].name.text());

    const bad_end = [_][80]u8{raw80("END")};
    try testing.expectError(error.InvalidHeaderOperation, apply(testing.allocator, &source, &.{.{ .append_raw = &bad_end }}));
    const bad_struct = [_][80]u8{raw80("NAXIS1  =                    4")};
    try testing.expectError(error.StructuralKeyword, apply(testing.allocator, &source, &.{.{ .append_raw = &bad_struct }}));
    try testing.expectError(
        error.InvalidHeaderOperation,
        apply(testing.allocator, &source, &.{.{ .insert_raw = .{ .index = 99, .cards = &appended } }}),
    );
}

test "reserved blanks are consumed by a later upsert and END is normalized" {
    var source = Header.initEmpty();
    defer source.deinit(testing.allocator);
    try source.appendValue(testing.allocator, "A", .{ .int = 1 }, null);
    try source.ensureEnd(testing.allocator);
    try source.appendValue(testing.allocator, "AFTEREND", .{ .int = 9 }, null); // intentionally hostile shape
    try source.ensureEnd(testing.allocator); // END, AFTEREND, END

    var staged = try apply(testing.allocator, &source, &.{
        .{ .reserve_blanks = 3 },
        .{ .upsert = .{ .name = "B", .value = .{ .int = 2 } } },
    });
    defer staged.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 2), try staged.getValue(i64, "B"));
    var blanks: usize = 0;
    for (staged.cards.items) |card| if (card.kind == .blank) {
        blanks += 1;
    };
    try testing.expectEqual(@as(usize, 2), blanks);
    try expectOneFinalEnd(&staged);
}

test "any later failure discards prior staged edits and structural keywords are rejected" {
    var source = try headerOf(testing.allocator, &.{
        "SIMPLE  =                    T",
        "BITPIX  =                    8",
        "NAXIS   =                    0",
    });
    defer source.deinit(testing.allocator);
    const edits = [_]Edit{
        .{ .upsert = .{ .name = "USER", .value = .{ .int = 7 } } },
        .{ .delete_first = "BITPIX" },
    };
    try testing.expectError(error.StructuralKeyword, apply(testing.allocator, &source, &edits));
    try testing.expect(!source.has("USER"));
    try testing.expectEqual(@as(i64, 8), try source.getValue(i64, "BITPIX"));

    try testing.expectError(
        error.StructuralKeyword,
        apply(testing.allocator, &source, &.{.{ .rename = .{ .old = "USER", .new = "NAXISFOO" } }}),
    );
    inline for (.{
        "GROUPS", "TFIELDS",  "THEAP",  "TFORM1",   "TBCOL2", "ZBITPIX", "ZNAXIS3",
        "ZTILE1", "ZCMPTYPE", "ZTABLE", "ZTILELEN", "ZFORM1", "ZCTYP2",
    }) |name| {
        try testing.expect(isStructural(name));
        try testing.expectError(
            error.StructuralKeyword,
            apply(testing.allocator, &source, &.{.{ .upsert = .{ .name = name, .value = .{ .int = 1 } } }}),
        );
    }
    try testing.expectError(
        error.BadValueSyntax,
        apply(testing.allocator, &source, &.{.{ .upsert = .{ .name = "BAD", .value = .{ .float = std.math.inf(f64) } } }}),
    );
}

test "explicit null removes a comment while preserve retains it" {
    var source = try headerOf(testing.allocator, &.{"A       =                    1 / original"});
    defer source.deinit(testing.allocator);
    var preserved = try apply(testing.allocator, &source, &.{.{ .upsert = .{ .name = "A", .value = .{ .int = 2 } } }});
    defer preserved.deinit(testing.allocator);
    try testing.expectEqualStrings("original", preserved.comment("A").?);

    var cleared = try apply(testing.allocator, &preserved, &.{.{ .upsert = .{
        .name = "A",
        .value = .{ .int = 3 },
        .comment = .{ .explicit = null },
    } }});
    defer cleared.deinit(testing.allocator);
    try testing.expect(cleared.comment("A") == null);
}
