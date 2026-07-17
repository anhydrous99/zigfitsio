//! The `HIERARCH` long/hierarchical keyword convention (FR-HDR-9, §9.3; FITS Registry).
//!
//! A `HIERARCH` card carries a hierarchical, possibly long keyword name after the literal
//! `HIERARCH` token, separated from its value by `=`:
//!
//!     HIERARCH ESO DET CHIP1 NAME = 'CCD1' / detector name
//!
//! Because bytes 9–10 are not the `= ` value indicator, the card layer classifies a `HIERARCH`
//! card as **commentary** (preserved verbatim). This module interprets those cards: it extracts
//! the hierarchical name and the value, builds new `HIERARCH` cards, and looks one up by either
//! the spaced token form (`ESO DET CHIP1 NAME`) or the full `HIERARCH …` spelling.
const std = @import("std");
const errors = @import("../errors.zig");
const HeaderError = errors.HeaderError;
const Card = @import("card.zig").Card;
const value = @import("value.zig");

const Allocator = std.mem.Allocator;

/// Whether `card` uses the HIERARCH convention. A fixed-format value card whose literal keyword
/// is `HIERARCH` is not a convention card.
pub fn isHierarch(card: *const Card) bool {
    return card.name.eqlText("HIERARCH") and card.kind != .value;
}

/// Whether a public keyword spelling requires the HIERARCH convention rather than the fixed
/// eight-byte keyword field.
pub fn requiresConvention(name: []const u8) bool {
    const n = std.mem.trim(u8, name, " ");
    return (n.len >= 9 and std.ascii.eqlIgnoreCase(n[0..9], "HIERARCH ")) or
        n.len > 8 or std.mem.indexOfScalar(u8, n, ' ') != null;
}

/// The hierarchical keyword name of a `HIERARCH` card — the text between `HIERARCH` and the
/// first `=`, with runs of spaces collapsed to single spaces, written into `out`. Returns the
/// slice of `out` used, or `null` if `card` is not a well-formed `HIERARCH` card. `out` should
/// be at least 70 bytes.
pub fn keyword(card: *const Card, out: []u8) ?[]const u8 {
    if (!isHierarch(card)) return null;
    const rest = card.raw[8..]; // bytes 9–80
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const name_part = std.mem.trim(u8, rest[0..eq], " ");
    if (name_part.len == 0) return null;
    // Collapse internal whitespace runs to single spaces.
    var n: usize = 0;
    var prev_space = false;
    for (name_part) |c| {
        const is_space = c == ' ';
        if (is_space) {
            if (prev_space) continue;
            prev_space = true;
        } else prev_space = false;
        if (n >= out.len) return null;
        out[n] = c;
        n += 1;
    }
    return out[0..n];
}

/// The raw value field of a `HIERARCH` card — everything after the first `=` (the value plus any
/// `/ comment`), analogous to `Card.valueField()` for a fixed-format card. `null` if `card` is not
/// a well-formed `HIERARCH` card (no `=`). `value.parseValue`/`value.parseComment` accept the slice
/// unchanged, so header getters can route HIERARCH cards through it instead of the fixed columns
/// 11–80 (which for a HIERARCH card fall inside the keyword, not the value).
pub fn valueField(card: *const Card) ?[]const u8 {
    if (!isHierarch(card)) return null;
    const rest = card.raw[8..];
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    return rest[eq + 1 ..];
}

/// Parse the value of a `HIERARCH` card (everything after the first `=`). Allocates a string
/// payload via `alloc`. `null` if `card` is not a well-formed `HIERARCH` card.
pub fn parseValue(alloc: Allocator, card: *const Card) (HeaderError || errors.ValueError || Allocator.Error)!?value.KeywordValue {
    if (!isHierarch(card)) return null;
    const rest = card.raw[8..];
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    return try value.parseValue(alloc, rest[eq + 1 ..]);
}

/// Build one `HIERARCH` card for hierarchical name `name` (spaced tokens) with value `v` and an
/// optional comment. A leading `HIERARCH ` spelling is accepted and stripped, so it is never
/// doubled on output. `error.CardOverflow` if the complete card does not fit in 80 bytes;
/// `error.BadValueSyntax` for a non-finite real (`value.requireFinite`). For a string/comment that
/// needs the long-string convention, use `split`.
pub fn build(name: []const u8, v: value.KeywordValue, comment: ?[]const u8) HeaderError!Card {
    try value.requireFinite(v);
    const tokens = normalizedName(name);
    const cmt = nonEmptyComment(comment);
    var raw: [80]u8 = [_]u8{' '} ** 80;
    var w = std.Io.Writer.fixed(&raw);
    w.writeAll("HIERARCH ") catch return error.CardOverflow;
    w.writeAll(tokens) catch return error.CardOverflow;
    w.writeAll(" = ") catch return error.CardOverflow;
    formatFree(&w, v) catch return error.CardOverflow;
    if (cmt) |c| {
        w.writeAll(" / ") catch return error.CardOverflow;
        w.writeAll(c) catch return error.CardOverflow;
    }
    // Validate printable ASCII via the normal card parser (kind will be .commentary).
    return Card.parse(&raw);
}

/// Build the complete physical-card run for a `HIERARCH` value.
///
/// A value that fits is returned as one ordinary `HIERARCH` card. Long strings use the registered
/// `CONTINUE` convention: the base card has the variable capacity left by the hierarchical name,
/// later fragments use the standard `CONTINUE  ` prefix, and a comment is placed on the final data
/// fragment when it fits or on a dedicated `CONTINUE  '' / comment` card otherwise. String quotes
/// are escaped before chunking and a cut never splits a `''` pair. Non-string values never
/// continue: the value must fit in full, while an overflowing comment is truncated at column 80,
/// matching the binding behavior.
///
/// `name` may be either `ESO DET CHIP` or `HIERARCH ESO DET CHIP` (case-insensitive prefix). The
/// returned card slice is allocator-owned; free the slice, not individual cards.
pub fn split(alloc: Allocator, name: []const u8, v: value.KeywordValue, comment: ?[]const u8) (HeaderError || Allocator.Error)![]Card {
    try value.requireFinite(v);
    const tokens = normalizedName(name);
    const cmt = nonEmptyComment(comment);

    var list: std.ArrayList(Card) = .empty;
    errdefer list.deinit(alloc);

    if (v != .string) {
        try list.append(alloc, try buildNonStringTruncatingComment(tokens, v, cmt));
        return list.toOwnedSlice(alloc);
    }

    const str = v.string;
    const esc_len = value.escapedLen(str);
    const prefix_len = hierarchPrefixLen(tokens);
    const comment_cost: usize = if (cmt) |c| 3 + c.len else 0;

    // Compact HIERARCH strings have no eight-character minimum padding. If the complete rendered
    // card fits, retain the ordinary one-card spelling byte-for-byte.
    if (prefix_len <= 80 and esc_len <= 80 - prefix_len and
        2 + esc_len <= 80 - prefix_len and comment_cost <= 80 - prefix_len - 2 - esc_len)
    {
        try list.append(alloc, try build(tokens, v, cmt));
        return list.toOwnedSlice(alloc);
    }

    // Empty data cannot be continued meaningfully. Preserve the complete `''` value and truncate
    // only an overflowing comment; an overlong name/value prefix still fails loudly.
    if (esc_len == 0) {
        try list.append(alloc, try buildEmptyStringTruncatingComment(tokens, cmt));
        return list.toOwnedSlice(alloc);
    }

    const esc = try alloc.alloc(u8, esc_len);
    defer alloc.free(esc);
    value.escapeQuotes(str, esc);

    var pos: usize = 0;
    var first = true;
    var comment_done = cmt == null;
    while (pos < esc.len) {
        const head_len = if (first) prefix_len else CONTINUE_PREFIX.len;
        if (head_len + 2 > 80) return error.CardOverflow; // no room even for the two quotes
        const cap = 80 - head_len - 2; // text columns between quotes, including a possible `&`
        const remaining = esc.len - pos;
        const terminal_cap = if (comment_cost <= cap) cap - comment_cost else 0;
        const terminal = comment_cost <= cap and remaining <= terminal_cap;

        var take: usize = undefined;
        if (terminal) {
            take = remaining;
        } else {
            if (cap <= 1) return error.CardOverflow; // a continued card needs data plus `&`
            take = pairSafeTake(esc[pos..], @min(cap - 1, remaining));
            if (take == 0) return error.CardOverflow;
        }

        const chunk = esc[pos .. pos + take];
        pos += take;
        try list.append(alloc, try buildStringRunCard(tokens, first, chunk, !terminal, if (terminal) cmt else null));
        first = false;
        if (terminal) {
            comment_done = true;
            break;
        }
    }

    // The last data fragment was deliberately marked as continued because its comment did not fit.
    if (!comment_done) try list.append(alloc, try buildDedicatedComment(cmt.?));
    return list.toOwnedSlice(alloc);
}

const CONTINUE_PREFIX = "CONTINUE  ";

// Trim the public spelling and accept one optional `HIERARCH ` prefix without doubling it.
fn normalizedName(name: []const u8) []const u8 {
    var tokens = std.mem.trim(u8, name, " ");
    if (tokens.len >= 9 and std.ascii.eqlIgnoreCase(tokens[0..9], "HIERARCH ")) {
        tokens = std.mem.trimStart(u8, tokens[9..], " ");
    }
    return tokens;
}

fn nonEmptyComment(comment: ?[]const u8) ?[]const u8 {
    const c = comment orelse return null;
    return if (c.len == 0) null else c;
}

fn hierarchPrefixLen(tokens: []const u8) usize {
    // `HIERARCH ` + tokens + ` = `; a real slice cannot approach usize overflow in practice.
    return "HIERARCH ".len + tokens.len + " = ".len;
}

fn writeHierarchPrefix(w: *std.Io.Writer, tokens: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("HIERARCH ");
    try w.writeAll(tokens);
    try w.writeAll(" = ");
}

fn appendTruncated(raw: *[80]u8, pos: *usize, text: []const u8) void {
    if (pos.* >= raw.len) return;
    const n = @min(text.len, raw.len - pos.*);
    @memcpy(raw[pos.* .. pos.* + n], text[0..n]);
    pos.* += n;
}

// Non-string HIERARCH values are never continued. Render the value separately so a long comment
// may be clipped without ever clipping or partially writing the value itself.
fn buildNonStringTruncatingComment(tokens: []const u8, v: value.KeywordValue, comment: ?[]const u8) HeaderError!Card {
    var literal_buf: [160]u8 = undefined;
    var literal_writer = std.Io.Writer.fixed(&literal_buf);
    formatFree(&literal_writer, v) catch return error.CardOverflow;
    const literal = literal_writer.buffered();

    const prefix_len = hierarchPrefixLen(tokens);
    if (prefix_len > 80 or literal.len > 80 - prefix_len) return error.CardOverflow;

    var raw: [80]u8 = [_]u8{' '} ** 80;
    var w = std.Io.Writer.fixed(&raw);
    writeHierarchPrefix(&w, tokens) catch return error.CardOverflow;
    w.writeAll(literal) catch return error.CardOverflow;
    var pos = w.buffered().len;
    if (comment) |c| {
        appendTruncated(&raw, &pos, " / ");
        appendTruncated(&raw, &pos, c);
    }
    return Card.parse(&raw);
}

fn buildEmptyStringTruncatingComment(tokens: []const u8, comment: ?[]const u8) HeaderError!Card {
    const prefix_len = hierarchPrefixLen(tokens);
    if (prefix_len > 78) return error.CardOverflow; // preserve both quotes or reject

    var raw: [80]u8 = [_]u8{' '} ** 80;
    var w = std.Io.Writer.fixed(&raw);
    writeHierarchPrefix(&w, tokens) catch return error.CardOverflow;
    w.writeAll("''") catch return error.CardOverflow;
    var pos = w.buffered().len;
    if (comment) |c| {
        appendTruncated(&raw, &pos, " / ");
        appendTruncated(&raw, &pos, c);
    }
    return Card.parse(&raw);
}

fn buildStringRunCard(tokens: []const u8, first: bool, escaped_chunk: []const u8, continues: bool, comment: ?[]const u8) HeaderError!Card {
    var raw: [80]u8 = [_]u8{' '} ** 80;
    var w = std.Io.Writer.fixed(&raw);
    if (first) {
        writeHierarchPrefix(&w, tokens) catch return error.CardOverflow;
    } else {
        w.writeAll(CONTINUE_PREFIX) catch return error.CardOverflow;
    }
    w.writeByte('\'') catch return error.CardOverflow;
    w.writeAll(escaped_chunk) catch return error.CardOverflow;
    if (continues) w.writeByte('&') catch return error.CardOverflow;
    w.writeByte('\'') catch return error.CardOverflow;
    if (comment) |c| {
        w.writeAll(" / ") catch return error.CardOverflow;
        w.writeAll(c) catch return error.CardOverflow;
    }
    return Card.parse(&raw);
}

fn buildDedicatedComment(comment: []const u8) HeaderError!Card {
    var raw: [80]u8 = [_]u8{' '} ** 80;
    var pos: usize = 0;
    appendTruncated(&raw, &pos, "CONTINUE  '' / ");
    appendTruncated(&raw, &pos, comment);
    return Card.parse(&raw);
}

// Largest cut <= `want` that does not split one of the `''` pairs in fully escaped text.
fn pairSafeTake(escaped: []const u8, want: usize) usize {
    var i: usize = 0;
    while (i < want) {
        if (escaped[i] == '\'') {
            if (i + 1 == want) return want - 1;
            i += 2;
        } else {
            i += 1;
        }
    }
    return want;
}

// Free-format (compact) value writer for HIERARCH cards (the fixed-format 20-column padding
// of mandatory keywords does not apply to the long-keyword convention).
fn formatFree(w: *std.Io.Writer, v: value.KeywordValue) std.Io.Writer.Error!void {
    switch (v) {
        .int => |n| try w.print("{d}", .{n}),
        .float => |f| {
            var tmp: [64]u8 = undefined;
            try writeBindingReal(w, value.formatReal(&tmp, f));
        },
        .logical => |b| try w.writeAll(if (b) "T" else "F"),
        .complex_int => |c| try w.print("({d}, {d})", .{ c[0], c[1] }),
        .complex_float => |c| {
            var rb: [64]u8 = undefined;
            var ib: [64]u8 = undefined;
            try w.print("({s}, {s})", .{ value.formatReal(&rb, c[0]), value.formatReal(&ib, c[1]) });
        },
        .string => |s| {
            try w.writeByte('\'');
            for (s) |ch| {
                if (ch == '\'') try w.writeAll("''") else try w.writeByte(ch);
            }
            try w.writeByte('\'');
        },
        .undefined => {},
    }
}

// Keep the historical binding spelling for one-digit negative exponents (`E-07`, not `E-7`) while
// centralizing it in Zig. Both language bindings previously carried their own HIERARCH formatter;
// this is the only compatibility tweak beyond the core's canonical uppercase-exponent renderer.
fn writeBindingReal(w: *std.Io.Writer, rendered: []const u8) std.Io.Writer.Error!void {
    const e = std.mem.indexOfScalar(u8, rendered, 'E') orelse return w.writeAll(rendered);
    const exp = rendered[e + 1 ..];
    if (exp.len != 2 or exp[0] != '-') return w.writeAll(rendered);
    try w.writeAll(rendered[0 .. rendered.len - 1]);
    try w.writeByte('0');
    try w.writeByte(rendered[rendered.len - 1]);
}

/// Case-insensitive comparison of a `HIERARCH` card's name to `query`. `query` may be the
/// spaced token form (`ESO DET CHIP1 NAME`) or the full form (`HIERARCH ESO DET CHIP1 NAME`).
pub fn matchName(card: *const Card, query: []const u8) bool {
    var buf: [70]u8 = undefined;
    const kw = keyword(card, &buf) orelse return false;
    var q = std.mem.trim(u8, query, " ");
    if (std.ascii.startsWithIgnoreCase(q, "HIERARCH ")) q = std.mem.trim(u8, q[9..], " ");
    return tokensEqualIgnoreCase(kw, q);
}

// Compare two space-separated token strings ignoring case and collapsing whitespace.
fn tokensEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeScalar(u8, a, ' ');
    var ib = std.mem.tokenizeScalar(u8, b, ' ');
    while (true) {
        const ta = ia.next();
        const tb = ib.next();
        if (ta == null and tb == null) return true;
        if (ta == null or tb == null) return false;
        if (!std.ascii.eqlIgnoreCase(ta.?, tb.?)) return false;
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;

fn card80(s: []const u8) Card {
    var b: [80]u8 = [_]u8{' '} ** 80;
    @memcpy(b[0..s.len], s);
    return Card.parse(&b) catch unreachable;
}

// Reassemble a run produced by `split`. Every fragment must parse independently: that property
// catches a cut through a doubled-quote pair in addition to checking the final logical value.
fn reassembleSplit(alloc: Allocator, cards: []const Card) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (cards, 0..) |*c, i| {
        const field = if (i == 0) valueField(c) orelse return error.BadValueSyntax else c.valueField();
        const parsed = try value.parseValue(alloc, field);
        defer parsed.deinit(alloc);
        const fragment = switch (parsed) {
            .string => |s| s,
            else => return error.BadValueSyntax,
        };
        const has_next = i + 1 < cards.len and cards[i + 1].kind == .continuation;
        if (has_next and fragment.len > 0 and fragment[fragment.len - 1] == '&') {
            try out.appendSlice(alloc, fragment[0 .. fragment.len - 1]);
        } else {
            try out.appendSlice(alloc, fragment);
        }
    }
    return out.toOwnedSlice(alloc);
}

test "parse a HIERARCH card: name and value" {
    const c = card80("HIERARCH ESO DET CHIP1 NAME = 'CCD1' / detector name");
    try testing.expect(isHierarch(&c));
    var buf: [70]u8 = undefined;
    try testing.expectEqualStrings("ESO DET CHIP1 NAME", keyword(&c, &buf).?);
    const v = (try parseValue(testing.allocator, &c)).?;
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("CCD1", v.string);
}

test "HIERARCH numeric value" {
    const c = card80("HIERARCH ESO INS TEMP = 12.5 / Celsius");
    const v = (try parseValue(testing.allocator, &c)).?;
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 12.5), v.float);
}

test "build a HIERARCH card and round-trip it" {
    const c = try build("ESO DET CHIP1 GAIN", .{ .float = 2.1 }, "e-/ADU");
    try testing.expect(isHierarch(&c));
    var buf: [70]u8 = undefined;
    try testing.expectEqualStrings("ESO DET CHIP1 GAIN", keyword(&c, &buf).?);
    const v = (try parseValue(testing.allocator, &c)).?;
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 2.1), v.float);
}

test "split keeps a short value on one card and normalizes an explicit prefix" {
    const cards = try split(testing.allocator, "  hIeRaRcH   ESO DET ID  ", .{ .int = 42 }, null);
    defer testing.allocator.free(cards);
    try testing.expectEqual(@as(usize, 1), cards.len);
    try testing.expect(std.mem.startsWith(u8, cards[0].bytes(), "HIERARCH ESO DET ID = 42"));
    try testing.expect(std.mem.indexOf(u8, cards[0].bytes()[9..], "HIERARCH") == null);
    var name_buf: [70]u8 = undefined;
    try testing.expectEqualStrings("ESO DET ID", keyword(&cards[0], &name_buf).?);
}

test "split writes a long HIERARCH string as a variable-capacity CONTINUE run" {
    const original = ("the quick brown fox " ** 12)[0..239];
    const cards = try split(testing.allocator, "ESO LONG STR", .{ .string = original }, "provenance");
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 3);
    try testing.expect(cards[0].kind == .commentary);
    try testing.expect(std.mem.startsWith(u8, cards[0].bytes(), "HIERARCH ESO LONG STR = '"));
    for (cards[1..]) |c| try testing.expectEqual(Card.Kind.continuation, c.kind);

    const joined = try reassembleSplit(testing.allocator, cards);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings(original, joined);
    const last_comment = value.parseComment(cards[cards.len - 1].valueField()).?;
    try testing.expectEqualStrings("provenance", last_comment);
}

test "split never cuts a doubled-quote pair across HIERARCH or CONTINUE cards" {
    var offset: usize = 0;
    while (offset < 90) : (offset += 1) {
        var original: [150]u8 = [_]u8{'x'} ** 150;
        original[offset] = '\'';
        original[149 - offset] = '&';
        const cards = try split(testing.allocator, "ESO Q W", .{ .string = &original }, null);
        defer testing.allocator.free(cards);
        try testing.expect(cards.len >= 2);

        const joined = try reassembleSplit(testing.allocator, cards);
        defer testing.allocator.free(joined);
        try testing.expectEqualStrings(&original, joined);
    }
}

test "split puts a fitting comment on the final fragment" {
    const original = "x" ** 100;
    const cards = try split(testing.allocator, "ESO LONG STR", .{ .string = original }, "note");
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 2);
    try testing.expectEqualStrings("note", value.parseComment(cards[cards.len - 1].valueField()).?);

    const joined = try reassembleSplit(testing.allocator, cards);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings(original, joined);
}

test "split uses a dedicated empty CONTINUE card when the comment cannot ride the data" {
    const original = "A" ** 180;
    const cards = try split(testing.allocator, "ESO LONG STR", .{ .string = original }, "trailing comment");
    defer testing.allocator.free(cards);
    try testing.expect(cards.len >= 4);
    try testing.expect(std.mem.startsWith(u8, cards[cards.len - 1].bytes(), "CONTINUE  '' / trailing comment"));

    const joined = try reassembleSplit(testing.allocator, cards);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings(original, joined);
}

test "split preserves an empty string and truncates only its overflowing comment" {
    const cards = try split(testing.allocator, "ESO EMPTY", .{ .string = "" }, "c" ** 100);
    defer testing.allocator.free(cards);
    try testing.expectEqual(@as(usize, 1), cards.len);
    const parsed = (try parseValue(testing.allocator, &cards[0])).?;
    defer parsed.deinit(testing.allocator);
    try testing.expectEqualStrings("", parsed.string);
    const c = value.parseComment(valueField(&cards[0]).?).?;
    try testing.expect(c.len > 0 and c.len < 100);
}

test "split never truncates a non-string value but may truncate its comment" {
    const name = "ESO DET " ++ "LONG NAME " ** 4;
    const cards = try split(testing.allocator, name, .{ .int = 123456 }, "c" ** 60);
    defer testing.allocator.free(cards);
    try testing.expectEqual(@as(usize, 1), cards.len);
    const parsed = (try parseValue(testing.allocator, &cards[0])).?;
    try testing.expectEqual(@as(i64, 123456), parsed.int);
    try testing.expect(value.parseComment(valueField(&cards[0]).?).?.len < 60);

    try testing.expectError(
        error.CardOverflow,
        split(testing.allocator, "ESO " ++ "X" ** 76, .{ .int = 1 }, null),
    );
}

test "split uses uppercase real exponents and rejects non-finite values" {
    const cards = try split(testing.allocator, "HIERARCH ESO DET EXPTIME", .{ .float = 1.5e-7 }, "c" ** 70);
    defer testing.allocator.free(cards);
    try testing.expectEqual(@as(usize, 1), cards.len); // non-string comments truncate; never CONTINUE
    try testing.expect(std.mem.indexOfScalar(u8, cards[0].bytes(), 'E') != null);
    try testing.expect(std.mem.indexOfScalar(u8, cards[0].bytes(), 'e') == null);

    try testing.expectError(
        error.BadValueSyntax,
        split(testing.allocator, "ESO DET BAD", .{ .float = std.math.inf(f64) }, null),
    );
}

test "matchName accepts both spellings, case-insensitive, whitespace-collapsed" {
    const c = card80("HIERARCH ESO  DET CHIP1 NAME = 'x'"); // note double space
    try testing.expect(matchName(&c, "ESO DET CHIP1 NAME"));
    try testing.expect(matchName(&c, "eso det chip1 name"));
    try testing.expect(matchName(&c, "HIERARCH ESO DET CHIP1 NAME"));
    try testing.expect(!matchName(&c, "ESO DET CHIP2 NAME"));
    try testing.expect(!matchName(&c, "ESO DET"));
}

test "build emits an UPPERCASE 'E' exponent for real values (§4.2.4)" {
    const c = try build("ESO INS TEMP", .{ .float = 1.5e2 }, null);
    const raw = c.bytes();
    try testing.expect(std.mem.indexOfScalar(u8, raw, 'E') != null);
    try testing.expect(std.mem.indexOf(u8, raw, "1.5E2") != null);
    // No lowercase 'e' anywhere in the formatted value/name.
    try testing.expect(std.mem.indexOfScalar(u8, raw, 'e') == null);

    const cc = try build("ESO INS GAIN", .{ .complex_float = .{ 1.5e2, -2.5e-3 } }, null);
    try testing.expect(std.mem.indexOf(u8, cc.bytes(), "(1.5E2, -2.5E-3)") != null);
}

test "build rejects non-finite reals (BUGHUNT 25/27)" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expectError(error.BadValueSyntax, build("ESO DET GAIN", .{ .float = nan }, null));
    try testing.expectError(error.BadValueSyntax, build("ESO DET GAIN", .{ .float = inf }, null));
    try testing.expectError(error.BadValueSyntax, build("ESO DET GAIN", .{ .float = -inf }, null));
    try testing.expectError(error.BadValueSyntax, build("ESO DET GAIN", .{ .complex_float = .{ nan, 2.0 } }, null));
    try testing.expectError(error.BadValueSyntax, build("ESO DET GAIN", .{ .complex_float = .{ 2.0, -inf } }, null));
}

test "non-HIERARCH card yields null" {
    const c = card80("BITPIX  =                    8");
    try testing.expect(!isHierarch(&c));
    var buf: [70]u8 = undefined;
    try testing.expect(keyword(&c, &buf) == null);
    try testing.expect((try parseValue(testing.allocator, &c)) == null);

    const fixed = card80("HIERARCH=                    1");
    try testing.expect(!isHierarch(&fixed));
}
