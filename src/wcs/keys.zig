//! World Coordinate System keyword set: parse and serialize (FR-WCS-1, §18.1;
//! FITS 4.0 §8.1–8.2, Tables 21–22).
//!
//! `Wcs.fromHeader` reads the WCS keywords for a given alternate description (`a` = `' '` for
//! the primary, `'A'`–`'Z'` for alternates): `WCSAXES`, `CTYPEi`, `CRPIXi`, `CRVALi`,
//! `CDELTi`, `CUNITi`, the **mutually exclusive** `CDi_j` / `PCi_j` matrices, `PVi_m`,
//! `PSi_m`, `LONPOLE`/`LATPOLE`, `RADESYS`, `EQUINOX`. The legacy `CROTAi` is read but
//! deprecated and is never written together with `PCi_j`/`PVi_m`/`PSi_m`. `writeTo` emits the
//! set back into a header. The pixel↔world transforms themselves are WCS-2 (`celestial.zig`).
const std = @import("std");
const WcsError = @import("../errors.zig").WcsError;
const Header = @import("../header/header.zig").Header;

const Allocator = std.mem.Allocator;

/// A `PVi_m` numeric projection-parameter term.
pub const PvTerm = struct { axis: u16, m: u16, value: f64 };
/// A `PSi_m` string projection-parameter term (allocator-owned `value`).
pub const PsTerm = struct { axis: u16, m: u16, value: []u8 };

/// The linear transform: either a `PCi_j` matrix (with per-axis `CDELTi`) or a `CDi_j`
/// matrix (which folds in the scale), or none (implicit identity `PC`).
pub const Transform = union(enum) {
    none,
    pc: [][]f64,
    cd: [][]f64,
};

/// A parsed WCS keyword set for one alternate description.
pub const Wcs = struct {
    alt: u8 = ' ',
    axes: u16 = 0,
    ctype: [][]u8 = &.{},
    cunit: [][]u8 = &.{},
    crpix: []f64 = &.{},
    crval: []f64 = &.{},
    cdelt: []f64 = &.{},
    crota: []f64 = &.{}, // legacy, read-only
    transform: Transform = .none,
    pv: []PvTerm = &.{},
    ps: []PsTerm = &.{},
    lonpole: ?f64 = null,
    latpole: ?f64 = null,
    equinox: ?f64 = null,
    radesys: ?[]u8 = null,

    /// Read the WCS keyword set for alternate `alt` (`' '` for the primary). `WCSAXES`
    /// defaults to `NAXIS`. Returns `error.BadWcs` if both `CDi_j` and `PCi_j` are present.
    pub fn fromHeader(a: Allocator, h: *const Header, alt: u8) (WcsError || std.mem.Allocator.Error)!Wcs {
        var self: Wcs = .{ .alt = alt };
        errdefer self.deinit(a);

        const naxes = blk: {
            if (getValueAlt(h, u16, "WCSAXES", alt)) |n| break :blk n;
            break :blk h.getValue(u16, "NAXIS") catch 0;
        };
        self.axes = naxes;
        const n: usize = naxes;

        self.ctype = try a.alloc([]u8, n);
        @memset(self.ctype, &.{});
        self.cunit = try a.alloc([]u8, n);
        @memset(self.cunit, &.{});
        self.crpix = try a.alloc(f64, n);
        self.crval = try a.alloc(f64, n);
        self.cdelt = try a.alloc(f64, n);
        self.crota = try a.alloc(f64, n);

        var buf: [8]u8 = undefined;
        for (0..n) |i| {
            const idx = i + 1;
            self.ctype[i] = try getStringAlt(a, h, "CTYPE", idx, alt) orelse try a.dupe(u8, "");
            self.cunit[i] = try getStringAlt(a, h, "CUNIT", idx, alt) orelse try a.dupe(u8, "");
            self.crpix[i] = getIndexedAlt(h, "CRPIX", idx, alt) orelse 0;
            self.crval[i] = getIndexedAlt(h, "CRVAL", idx, alt) orelse 0;
            self.cdelt[i] = getIndexedAlt(h, "CDELT", idx, alt) orelse 1;
            self.crota[i] = getIndexedAlt(h, "CROTA", idx, alt) orelse 0;
            _ = &buf;
        }

        // Detect CD vs PC (mutually exclusive).
        const has_cd = anyMatrix(h, "CD", n, alt);
        const has_pc = anyMatrix(h, "PC", n, alt);
        if (has_cd and has_pc) return error.BadWcs;
        if (has_cd) {
            self.transform = .{ .cd = try readMatrix(a, h, "CD", n, alt, 0) }; // CD default 0
        } else if (has_pc) {
            self.transform = .{ .pc = try readMatrix(a, h, "PC", n, alt, null) }; // PC default identity
        } else {
            self.transform = .none;
        }

        self.pv = try readPv(a, h, n, alt);
        self.ps = try readPs(a, h, n, alt);
        self.lonpole = getValueAlt(h, f64, "LONPOLE", alt);
        self.latpole = getValueAlt(h, f64, "LATPOLE", alt);
        self.equinox = getValueAlt(h, f64, "EQUINOX", alt);
        if (try getStringAltName(a, h, "RADESYS", alt)) |r| self.radesys = r;
        return self;
    }

    /// Serialize the keyword set into `h`. `CROTAi` is **not** written when a `PC`/`PV`/`PS`
    /// representation is present (FR-WCS-1). Mandatory-keyword ordering is the HDU's concern;
    /// this appends the WCS cards.
    pub fn writeTo(self: *const Wcs, a: Allocator, h: *Header) (WcsError || @import("../errors.zig").HeaderError || std.mem.Allocator.Error)!void {
        var buf: [8]u8 = undefined;
        try h.appendValue(a, nameAlt(&buf, "WCSAXES", self.alt), .{ .int = self.axes }, null);
        for (0..self.axes) |i| {
            const idx = i + 1;
            if (self.ctype[i].len > 0) try h.appendValue(a, indexedName(&buf, "CTYPE", idx, self.alt), .{ .string = self.ctype[i] }, null);
            try h.appendValue(a, indexedName(&buf, "CRPIX", idx, self.alt), .{ .float = self.crpix[i] }, null);
            try h.appendValue(a, indexedName(&buf, "CRVAL", idx, self.alt), .{ .float = self.crval[i] }, null);
            try h.appendValue(a, indexedName(&buf, "CDELT", idx, self.alt), .{ .float = self.cdelt[i] }, null);
            if (self.cunit[i].len > 0) try h.appendValue(a, indexedName(&buf, "CUNIT", idx, self.alt), .{ .string = self.cunit[i] }, null);
        }
        switch (self.transform) {
            .none => {},
            .pc => |m| try writeMatrix(a, h, "PC", m, self.alt),
            .cd => |m| try writeMatrix(a, h, "CD", m, self.alt),
        }
        for (self.pv) |t| {
            try h.appendValue(a, matrixName(&buf, "PV", t.axis, t.m, self.alt), .{ .float = t.value }, null);
        }
        for (self.ps) |t| {
            try h.appendValue(a, matrixName(&buf, "PS", t.axis, t.m, self.alt), .{ .string = t.value }, null);
        }
        if (self.lonpole) |v| try h.appendValue(a, nameAlt(&buf, "LONPOLE", self.alt), .{ .float = v }, null);
        if (self.latpole) |v| try h.appendValue(a, nameAlt(&buf, "LATPOLE", self.alt), .{ .float = v }, null);
        if (self.equinox) |v| try h.appendValue(a, nameAlt(&buf, "EQUINOX", self.alt), .{ .float = v }, null);
        if (self.radesys) |r| try h.appendValue(a, nameAlt(&buf, "RADESYS", self.alt), .{ .string = r }, null);
        // CROTAi is deprecated and intentionally not written when PC/PV/PS exist; since we
        // always serialize via PC/CD, CROTAi is never emitted here (FR-WCS-1).
    }

    pub fn deinit(self: *Wcs, a: Allocator) void {
        for (self.ctype) |s| a.free(s);
        a.free(self.ctype);
        for (self.cunit) |s| a.free(s);
        a.free(self.cunit);
        a.free(self.crpix);
        a.free(self.crval);
        a.free(self.cdelt);
        a.free(self.crota);
        switch (self.transform) {
            .none => {},
            .pc, .cd => |m| {
                for (m) |row| a.free(row);
                a.free(m);
            },
        }
        a.free(self.pv);
        for (self.ps) |t| a.free(t.value);
        a.free(self.ps);
        if (self.radesys) |r| a.free(r);
    }
};

// ── name builders ──────────────────────────────────────────────────────────────────────

fn altSuffix(alt: u8) []const u8 {
    return if (alt == ' ' or alt == 0) "" else &[_]u8{alt};
}

fn nameAlt(buf: *[8]u8, comptime base: []const u8, alt: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ base, altSuffix(alt) }) catch unreachable;
}

fn indexedName(buf: *[8]u8, comptime base: []const u8, idx: usize, alt: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}{s}", .{ base, idx, altSuffix(alt) }) catch unreachable;
}

fn matrixName(buf: *[8]u8, comptime base: []const u8, i: usize, j: usize, alt: u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}_{d}{s}", .{ base, i, j, altSuffix(alt) }) catch unreachable;
}

// ── readers ────────────────────────────────────────────────────────────────────────────

fn getValueAlt(h: *const Header, comptime T: type, comptime base: []const u8, alt: u8) ?T {
    var buf: [8]u8 = undefined;
    return h.getValue(T, nameAlt(&buf, base, alt)) catch null;
}

fn getIndexedAlt(h: *const Header, comptime base: []const u8, idx: usize, alt: u8) ?f64 {
    var buf: [8]u8 = undefined;
    return h.getValue(f64, indexedName(&buf, base, idx, alt)) catch null;
}

fn getStringAlt(a: Allocator, h: *const Header, comptime base: []const u8, idx: usize, alt: u8) std.mem.Allocator.Error!?[]u8 {
    var buf: [8]u8 = undefined;
    const name = indexedName(&buf, base, idx, alt);
    const s = h.getString(a, name) catch return null;
    return s;
}

fn getStringAltName(a: Allocator, h: *const Header, comptime base: []const u8, alt: u8) std.mem.Allocator.Error!?[]u8 {
    var buf: [8]u8 = undefined;
    const name = nameAlt(&buf, base, alt);
    const s = h.getString(a, name) catch return null;
    return s;
}

fn anyMatrix(h: *const Header, comptime base: []const u8, n: usize, alt: u8) bool {
    var buf: [8]u8 = undefined;
    for (1..n + 1) |i| {
        for (1..n + 1) |j| {
            if (h.has(matrixName(&buf, base, i, j, alt))) return true;
        }
    }
    return false;
}

fn readMatrix(a: Allocator, h: *const Header, comptime base: []const u8, n: usize, alt: u8, default_off_diag: ?f64) std.mem.Allocator.Error![][]f64 {
    var buf: [8]u8 = undefined;
    const m = try a.alloc([]f64, n);
    var made: usize = 0;
    errdefer {
        for (m[0..made]) |row| a.free(row);
        a.free(m);
    }
    for (0..n) |i| {
        m[i] = try a.alloc(f64, n);
        made += 1;
        for (0..n) |j| {
            const name = matrixName(&buf, base, i + 1, j + 1, alt);
            if (h.getValue(f64, name) catch null) |v| {
                m[i][j] = v;
            } else {
                // Default: PC is identity (1 on diagonal, 0 off); CD is 0 everywhere.
                m[i][j] = if (default_off_diag) |d| d else (if (i == j) @as(f64, 1) else 0);
            }
        }
    }
    return m;
}

fn readPv(a: Allocator, h: *const Header, n: usize, alt: u8) std.mem.Allocator.Error![]PvTerm {
    var list: std.ArrayList(PvTerm) = .empty;
    errdefer list.deinit(a);
    var buf: [8]u8 = undefined;
    for (1..n + 1) |i| {
        for (0..100) |m| {
            const name = matrixName(&buf, "PV", i, m, alt);
            if (h.getValue(f64, name) catch null) |v| {
                try list.append(a, .{ .axis = @intCast(i), .m = @intCast(m), .value = v });
            }
        }
    }
    return list.toOwnedSlice(a);
}

fn readPs(a: Allocator, h: *const Header, n: usize, alt: u8) std.mem.Allocator.Error![]PsTerm {
    var list: std.ArrayList(PsTerm) = .empty;
    errdefer {
        for (list.items) |t| a.free(t.value);
        list.deinit(a);
    }
    var buf: [8]u8 = undefined;
    for (1..n + 1) |i| {
        for (0..100) |m| {
            const name = matrixName(&buf, "PS", i, m, alt);
            const s = h.getString(a, name) catch continue;
            try list.append(a, .{ .axis = @intCast(i), .m = @intCast(m), .value = s });
        }
    }
    return list.toOwnedSlice(a);
}

fn writeMatrix(a: Allocator, h: *Header, comptime base: []const u8, m: [][]f64, alt: u8) (@import("../errors.zig").HeaderError || std.mem.Allocator.Error)!void {
    var buf: [8]u8 = undefined;
    for (m, 0..) |row, i| {
        for (row, 0..) |v, j| {
            try h.appendValue(a, matrixName(&buf, base, i + 1, j + 1, alt), .{ .float = v }, null);
        }
    }
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const block = @import("../io/block.zig");
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

fn headerFrom(a: Allocator, cards: []const []const u8) !struct { h: Header, mem: *MemoryDevice, reader: *block.BlockReader } {
    const mem = try a.create(MemoryDevice);
    var buf: [block.BLOCK]u8 = [_]u8{' '} ** block.BLOCK;
    for (cards, 0..) |c, i| @memcpy(buf[i * 80 ..][0..c.len], c);
    @memcpy(buf[cards.len * 80 ..][0..3], "END");
    mem.* = try MemoryDevice.initBytes(a, &buf);
    const reader = try a.create(block.BlockReader);
    reader.* = try block.BlockReader.init(a, mem.device(), 0);
    const res = try Header.parse(a, reader, 0, 36);
    return .{ .h = res.header, .mem = mem, .reader = reader };
}

test "parse a TAN WCS with PC matrix and PV terms" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
        "CRPIX1  =                256.0",
        "CRPIX2  =                256.0",
        "CRVAL1  =                150.0",
        "CRVAL2  =                  2.5",
        "CDELT1  =               -0.001",
        "CDELT2  =                0.001",
        "PC1_1   =                  1.0",
        "PC1_2   =                  0.0",
        "PC2_1   =                  0.0",
        "PC2_2   =                  1.0",
        "PV2_1   =                  0.0",
        "LONPOLE =                180.0",
        "RADESYS = 'FK5'",
        "EQUINOX =               2000.0",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, ' ');
    defer w.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 2), w.axes);
    try testing.expectEqualStrings("RA---TAN", w.ctype[0]);
    try testing.expectEqualStrings("DEC--TAN", w.ctype[1]);
    try testing.expectEqual(@as(f64, 256.0), w.crpix[0]);
    try testing.expectEqual(@as(f64, -0.001), w.cdelt[0]);
    try testing.expect(w.transform == .pc);
    try testing.expectEqual(@as(f64, 1.0), w.transform.pc[0][0]);
    try testing.expectEqual(@as(usize, 1), w.pv.len);
    try testing.expectEqual(@as(f64, 180.0), w.lonpole.?);
    try testing.expectEqual(@as(f64, 2000.0), w.equinox.?);
    try testing.expectEqualStrings("FK5", w.radesys.?);
}

test "CD and PC together is BadWcs" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CD1_1   =                  1.0",
        "PC1_1   =                  1.0",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    try testing.expectError(error.BadWcs, Wcs.fromHeader(testing.allocator, &p.h, ' '));
}

test "PC defaults to identity, CD defaults to zero" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---TAN'",
        "CTYPE2  = 'DEC--TAN'",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, ' ');
    defer w.deinit(testing.allocator);
    // No PC/CD present ⇒ none (implicit identity); cdelt defaults to 1.
    try testing.expect(w.transform == .none);
    try testing.expectEqual(@as(f64, 1), w.cdelt[0]);
}

test "round-trip: parse, write to a new header, re-parse" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXES =                    2",
        "CTYPE1  = 'RA---SIN'",
        "CTYPE2  = 'DEC--SIN'",
        "CRPIX1  =                100.0",
        "CRPIX2  =                100.0",
        "CRVAL1  =                 10.0",
        "CRVAL2  =                -20.0",
        "CDELT1  =                 0.01",
        "CDELT2  =                 0.01",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, ' ');
    defer w.deinit(testing.allocator);

    var h2 = Header.initEmpty();
    defer h2.deinit(testing.allocator);
    try w.writeTo(testing.allocator, &h2);

    var w2 = try Wcs.fromHeader(testing.allocator, &h2, ' ');
    defer w2.deinit(testing.allocator);
    try testing.expectEqualStrings("RA---SIN", w2.ctype[0]);
    try testing.expectEqual(@as(f64, 100.0), w2.crpix[0]);
    try testing.expectEqual(@as(f64, -20.0), w2.crval[1]);
    try testing.expectEqual(@as(f64, 0.01), w2.cdelt[0]);
}

test "alternate WCS description with a suffix" {
    var p = try headerFrom(testing.allocator, &.{
        "WCSAXESA=                    1",
        "CTYPE1A = 'WAVE'",
        "CRVAL1A =               5000.0",
        "CDELT1A =                  1.5",
    });
    defer {
        p.h.deinit(testing.allocator);
        p.reader.deinit();
        testing.allocator.destroy(p.reader);
        p.mem.deinit();
        testing.allocator.destroy(p.mem);
    }
    var w = try Wcs.fromHeader(testing.allocator, &p.h, 'A');
    defer w.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 1), w.axes);
    try testing.expectEqualStrings("WAVE", w.ctype[0]);
    try testing.expectEqual(@as(f64, 5000.0), w.crval[0]);
}
