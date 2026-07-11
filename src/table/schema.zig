//! Compile-time binary-table schemas and programmatic table construction.
//!
//! A schema keeps the FITS `TFORMn` spellings explicit—the only unambiguous description of
//! logical, bit, character, complex, and variable-length columns—but validates those spellings
//! during compilation. It also derives `TFIELDS`, `NAXIS1`, and every byte offset once, so a
//! caller cannot accidentally publish a header whose declared row geometry disagrees with its
//! columns. On-disk tables remain runtime data and are still validated by `BinTable.of`.
const std = @import("std");
const Fits = @import("../fits.zig").Fits;
const FitsError = @import("../fits.zig").FitsError;
const Hdu = @import("../hdu.zig").Hdu;
const Header = @import("../header/header.zig").Header;
const common = @import("common.zig");
const binary = @import("binary.zig");

const Allocator = std.mem.Allocator;
const BinTform = common.BinTform;
const BinaryType = common.BinaryType;

/// One column in a compile-time `BinarySchema`.
///
/// `tform` deliberately uses the standard FITS spelling (`1J`, `8A`, `1PE(1024)`, …): a Zig
/// type alone cannot distinguish, for example, two `f32` values from one complex value. The
/// remaining fields map directly to optional per-column header keywords.
pub const BinaryColumnSpec = struct {
    /// Standard binary-table format (`TFORMn`), such as `1J`, `8A`, or `1PE(1024)`.
    tform: []const u8,
    /// Optional column name (`TTYPEn`). Effective names must be unique, ignoring ASCII case
    /// and trailing blanks.
    name: ?[]const u8 = null,
    /// Optional physical unit (`TUNITn`).
    unit: ?[]const u8 = null,
    /// Optional non-zero linear scale (`TSCALn`); not valid for A/L/X values.
    tscal: ?f64 = null,
    /// Optional linear zero point (`TZEROn`); not valid for A/L/X values.
    tzero: ?f64 = null,
    /// Optional raw integer null value (`TNULLn`), valid only for B/I/J/K storage, including
    /// P/Q columns whose heap element type is one of those integers.
    tnull: ?i64 = null,
    /// Multidimensional shape written as `TDIMn`. For fixed-width columns its product must not
    /// exceed the TFORM repeat; for P/Q columns it describes the heap value and must not exceed
    /// the declared `emax` when one is present.
    tdim: ?[]const u64 = null,
    /// Optional standard display format (`TDISPn`).
    tdisp: ?[]const u8 = null,
};

/// Runtime properties of a table appended from a compile-time schema.
pub const BinaryTableOpts = struct {
    /// Initial `NAXIS2` row count. New cells are zero-filled by `Fits.appendHdu`.
    rows: u64 = 0,
    /// Initial `PCOUNT` heap reservation, useful for P/Q variable-length columns.
    heap_bytes: u64 = 0,
    /// Optional `EXTNAME` value.
    extname: ?[]const u8 = null,
};

/// Errors produced when appending a schema and opening its typed `BinTable` view.
pub const AppendError = FitsError || binary.OpenError;

/// Build a compile-time-validated binary-table schema.
///
/// The returned type exposes `field_count`, `row_bytes`, and `column_offsets` as compile-time
/// constants. `appendHdu` writes a conforming `BINTABLE` extension; `append` additionally opens
/// and returns a `BinTable` view, which the caller must later `deinit`. FITS requires a primary
/// HDU before any table extension, so append an image-like primary first.
pub fn BinarySchema(comptime columns: []const BinaryColumnSpec) type {
    const geometry = comptime geometry: {
        // Parsing and cross-checking hundreds of descriptors is intentional work, not runaway
        // evaluation. The FITS ceiling below bounds it at 999 columns.
        @setEvalBranchQuota(20_000_000);
        break :geometry validateAndMeasure(columns);
    };

    return struct {
        /// Original compile-time column descriptors.
        pub const column_specs = columns;
        /// Number of fields written to `TFIELDS`.
        pub const field_count: u16 = @intCast(columns.len);
        /// Derived row width written to `NAXIS1`.
        pub const row_bytes: u64 = geometry.row_bytes;
        /// Derived 0-based byte offset of each column within a row.
        pub const column_offsets = geometry.offsets;

        /// Append this schema as a `BINTABLE` HDU and return the stable HDU pointer owned by
        /// `fits`. The file must already contain its primary HDU.
        pub fn appendHdu(fits: *Fits, opts: BinaryTableOpts) FitsError!*Hdu {
            if (opts.heap_bytes > fits.limits.max_heap_bytes) return error.LimitExceeded;
            const header = try buildHeader(fits.alloc, opts);
            // appendHdu consumes `header` on both success and failure.
            return fits.appendHdu(header);
        }

        /// Append this schema and open a parsed `BinTable` view over it. The returned view owns
        /// its column metadata; call `table.deinit(allocator)` when finished.
        pub fn append(fits: *Fits, opts: BinaryTableOpts) AppendError!binary.BinTable {
            const hdu = try appendHdu(fits, opts);
            return binary.BinTable.of(fits, hdu);
        }

        fn buildHeader(alloc: Allocator, opts: BinaryTableOpts) FitsError!Header {
            var header = Header.initEmpty();
            errdefer header.deinit(alloc);

            const rows = std.math.cast(i64, opts.rows) orelse return error.LimitExceeded;
            const heap_bytes = std.math.cast(i64, opts.heap_bytes) orelse return error.LimitExceeded;

            try header.appendValue(alloc, "XTENSION", .{ .string = "BINTABLE" }, "binary table extension");
            try header.appendValue(alloc, "BITPIX", .{ .int = 8 }, null);
            try header.appendValue(alloc, "NAXIS", .{ .int = 2 }, null);
            try header.appendValue(alloc, "NAXIS1", .{ .int = @intCast(row_bytes) }, null);
            try header.appendValue(alloc, "NAXIS2", .{ .int = rows }, null);
            try header.appendValue(alloc, "PCOUNT", .{ .int = heap_bytes }, null);
            try header.appendValue(alloc, "GCOUNT", .{ .int = 1 }, null);
            try header.appendValue(alloc, "TFIELDS", .{ .int = field_count }, null);

            var keyword_buf: [16]u8 = undefined;
            var tdim_buf: [68]u8 = undefined;
            for (columns, 0..) |column, i| {
                const n = i + 1;
                try header.appendValue(alloc, keyword(&keyword_buf, "TFORM", n), .{ .string = column.tform }, null);
                if (column.name) |name| try header.appendValue(alloc, keyword(&keyword_buf, "TTYPE", n), .{ .string = name }, null);
                if (column.unit) |unit| try header.appendValue(alloc, keyword(&keyword_buf, "TUNIT", n), .{ .string = unit }, null);
                if (column.tscal) |scale| try header.appendValue(alloc, keyword(&keyword_buf, "TSCAL", n), .{ .float = scale }, null);
                if (column.tzero) |zero| try header.appendValue(alloc, keyword(&keyword_buf, "TZERO", n), .{ .float = zero }, null);
                if (column.tnull) |null_value| try header.appendValue(alloc, keyword(&keyword_buf, "TNULL", n), .{ .int = null_value }, null);
                if (column.tdim) |dims| try header.appendValue(alloc, keyword(&keyword_buf, "TDIM", n), .{ .string = formatTdim(&tdim_buf, dims) }, null);
                if (column.tdisp) |display| try header.appendValue(alloc, keyword(&keyword_buf, "TDISP", n), .{ .string = display }, null);
            }
            if (opts.extname) |name| try header.appendValue(alloc, "EXTNAME", .{ .string = name }, null);
            try header.ensureEnd(alloc);
            return header;
        }
    };
}

fn keyword(buf: []u8, comptime prefix: []const u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "{d}", .{n}) catch unreachable;
}

fn formatTdim(buf: *[68]u8, dims: []const u64) []const u8 {
    var pos: usize = 0;
    buf[pos] = '(';
    pos += 1;
    for (dims, 0..) |dim, i| {
        if (i != 0) {
            buf[pos] = ',';
            pos += 1;
        }
        const rendered = std.fmt.bufPrint(buf[pos..], "{d}", .{dim}) catch unreachable;
        pos += rendered.len;
    }
    buf[pos] = ')';
    return buf[0 .. pos + 1];
}

fn validateAndMeasure(comptime columns: []const BinaryColumnSpec) struct {
    row_bytes: u64,
    offsets: [columns.len]u64,
} {
    if (columns.len > 999) @compileError("BinarySchema: FITS permits at most 999 columns");

    var offsets: [columns.len]u64 = undefined;
    var name_hashes: [columns.len]u64 = undefined;
    var row_bytes: u64 = 0;
    for (columns, 0..) |column, i| {
        name_hashes[i] = 0;
        const one_based = i + 1;
        const tform = BinTform.parse(column.tform) catch {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} has invalid TFORM", .{one_based}));
        };
        validateFormatSpelling(column.tform, one_based, "TFORM");
        if (tform.type.isVla() and tform.vla_elem == null) {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} VLA TFORM requires an element type", .{one_based}));
        }
        if (!stringFitsCard(column.tform)) {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TFORM does not fit in one card", .{one_based}));
        }
        validateOptionalString(column.name, one_based, "name");
        validateOptionalString(column.unit, one_based, "unit");
        validateOptionalString(column.tdisp, one_based, "TDISP");
        if (column.name) |name| {
            if (std.mem.trimEnd(u8, name, " ").len == 0) {
                @compileError(std.fmt.comptimePrint("BinarySchema: column {d} name must not be blank", .{one_based}));
            }
        }
        if (column.tdisp) |display| {
            validateFormatSpelling(display, one_based, "TDISP");
            const parsed = common.Tdisp.parse(display) catch {
                @compileError(std.fmt.comptimePrint("BinarySchema: column {d} has invalid TDISP", .{one_based}));
            };
            if (!isStandardTdispCode(parsed)) {
                @compileError(std.fmt.comptimePrint("BinarySchema: column {d} has unsupported TDISP code", .{one_based}));
            }
            if (!validTdispSyntax(display, parsed)) {
                @compileError(std.fmt.comptimePrint("BinarySchema: column {d} has invalid TDISP", .{one_based}));
            }
            if (!tdispCompatible(tform, parsed)) {
                @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDISP is incompatible with its TFORM", .{one_based}));
            }
        }
        if (column.tscal) |scale| if (!std.math.isFinite(scale) or scale == 0) {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TSCAL must be finite and non-zero", .{one_based}));
        };
        if (column.tzero) |zero| if (!std.math.isFinite(zero)) {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TZERO must be finite", .{one_based}));
        };
        if (column.tscal != null or column.tzero != null) validateScaling(one_based, tform);
        if (column.tnull) |null_value| validateNull(one_based, tform, null_value);
        if (column.tdim) |dims| validateTdim(one_based, tform, dims);

        offsets[i] = row_bytes;
        const width = tform.fieldBytes() catch {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} byte width overflows", .{one_based}));
        };
        row_bytes = std.math.add(u64, row_bytes, width) catch {
            @compileError("BinarySchema: derived row width overflows u64");
        };

        if (column.name) |name| {
            const effective_name = std.mem.trimEnd(u8, name, " ");
            const hash = effectiveNameHash(effective_name);
            name_hashes[i] = hash;
            for (columns[0..i], 0..) |earlier, j| {
                if (name_hashes[j] == hash and earlier.name != null) {
                    const other = earlier.name.?;
                    const effective_other = std.mem.trimEnd(u8, other, " ");
                    if (std.ascii.eqlIgnoreCase(effective_name, effective_other)) {
                        @compileError(std.fmt.comptimePrint(
                            "BinarySchema: columns {d} and {d} have duplicate names",
                            .{ j + 1, one_based },
                        ));
                    }
                }
            }
        }
    }
    if (row_bytes > std.math.maxInt(i64)) {
        @compileError("BinarySchema: derived row width does not fit the FITS integer field");
    }
    return .{ .row_bytes = row_bytes, .offsets = offsets };
}

fn effectiveNameHash(comptime name: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (name) |c| {
        hash ^= std.ascii.toLower(c);
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn validateFormatSpelling(comptime text: []const u8, comptime column: usize, comptime label: []const u8) void {
    for (text) |c| {
        if (c >= 'a' and c <= 'z') {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} {s} codes must be uppercase", .{ column, label }));
        }
        if (c == ' ') {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} {s} must not contain spaces", .{ column, label }));
        }
    }
}

fn isStandardTdispCode(comptime display: common.Tdisp) bool {
    const code = display.codeText();
    if (code.len == 2) return std.mem.eql(u8, code, "EN") or std.mem.eql(u8, code, "ES");
    return std.mem.indexOfScalar(u8, "ALIBOZFEGD", code[0]) != null;
}

fn validTdispSyntax(comptime text: []const u8, comptime display: common.Tdisp) bool {
    if (display.width == 0) return false;
    const trimmed = std.mem.trim(u8, text, " ");
    const tail = trimmed[display.code_len..];
    const has_decimal = std.mem.indexOfScalar(u8, tail, '.') != null;
    const has_exponent = std.mem.indexOfScalar(u8, tail, 'E') != null;
    const code = display.codeText();

    if (code.len == 1 and (code[0] == 'A' or code[0] == 'L')) {
        return !has_decimal and !has_exponent;
    }
    if (code.len == 1 and std.mem.indexOfScalar(u8, "IBOZ", code[0]) != null) {
        return !has_exponent and (!has_decimal or display.min_digits <= display.width);
    }

    // Every real format requires `.d`; only E/D/G permit an explicit exponent width.
    if (!has_decimal) return false;
    if (has_exponent and display.exp_digits == 0) return false;
    if (code.len == 2 or code[0] == 'F') return !has_exponent;
    return true;
}

fn effectiveType(comptime tform: BinTform) BinaryType {
    return if (tform.type.isVla()) tform.vla_elem.? else tform.type;
}

fn tdispCompatible(comptime tform: BinTform, comptime display: common.Tdisp) bool {
    const code = display.codeText();
    // FITS 4.0 §7.3.4 expressly permits G for every type (equivalent to A/L/I as needed).
    if (code.len == 1 and code[0] == 'G') return true;
    const ty = effectiveType(tform);
    return switch (ty) {
        .char => code.len == 1 and code[0] == 'A',
        .logical => code.len == 1 and code[0] == 'L',
        .bit, .byte, .int16, .int32, .int64 => code.len == 2 or
            std.mem.indexOfScalar(u8, "IBOZFED", code[0]) != null,
        .float32, .float64, .complex32, .complex64 => code.len == 2 or
            std.mem.indexOfScalar(u8, "FED", code[0]) != null,
        .vla32, .vla64 => unreachable,
    };
}

fn validateScaling(comptime column: usize, comptime tform: BinTform) void {
    switch (effectiveType(tform)) {
        .char, .logical, .bit => @compileError(std.fmt.comptimePrint(
            "BinarySchema: column {d} TSCAL/TZERO are invalid for its TFORM",
            .{column},
        )),
        else => {},
    }
}

fn validateOptionalString(comptime text: ?[]const u8, comptime column: usize, comptime label: []const u8) void {
    if (text) |s| {
        if (s.len == 0) {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} {s} must not be empty", .{ column, label }));
        }
        for (s) |c| {
            if (!std.ascii.isPrint(c)) {
                @compileError(std.fmt.comptimePrint("BinarySchema: column {d} {s} must contain printable ASCII", .{ column, label }));
            }
        }
        if (!stringFitsCard(s)) {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} {s} does not fit in one card", .{ column, label }));
        }
    }
}

fn stringFitsCard(comptime text: []const u8) bool {
    var escaped_len: usize = text.len;
    for (text) |c| {
        if (c == '\'') escaped_len += 1;
    }
    return @as(usize, 2) + @max(@as(usize, 8), escaped_len) <= @as(usize, 70);
}

fn validateNull(comptime column: usize, comptime tform: BinTform, comptime value: i64) void {
    const ty = effectiveType(tform);
    const valid = switch (ty) {
        .byte => value >= 0 and value <= std.math.maxInt(u8),
        .int16 => value >= std.math.minInt(i16) and value <= std.math.maxInt(i16),
        .int32 => value >= std.math.minInt(i32) and value <= std.math.maxInt(i32),
        .int64 => true,
        else => false,
    };
    if (!valid) {
        @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TNULL is invalid for its TFORM", .{column}));
    }
}

fn validateTdim(comptime column: usize, comptime tform: BinTform, comptime dims: []const u64) void {
    if (dims.len == 0) {
        @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDIM must have at least one axis", .{column}));
    }
    if (tform.type.isVla() and tform.repeat == 0) {
        @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDIM is invalid for an empty VLA field", .{column}));
    }
    var product: u64 = 1;
    var rendered_len: usize = 2; // parentheses
    for (dims, 0..) |dim, i| {
        if (dim == 0) {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDIM axes must be positive", .{column}));
        }
        product = std.math.mul(u64, product, dim) catch {
            @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDIM product overflows", .{column}));
        };
        rendered_len += std.fmt.count("{d}", .{dim});
        if (i != 0) rendered_len += 1;
    }
    if (tform.type.isVla()) {
        if (tform.emax) |emax| {
            if (product > emax) {
                @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDIM exceeds its VLA TFORM emax", .{column}));
            }
        }
    } else if (product > tform.repeat) {
        @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDIM exceeds its TFORM repeat", .{column}));
    }
    if (rendered_len > 68) {
        @compileError(std.fmt.comptimePrint("BinarySchema: column {d} TDIM does not fit in one card", .{column}));
    }
}

const testing = std.testing;
const MemoryDevice = @import("../io/memory.zig").MemoryDevice;

test "schema derives binary row geometry at compile time" {
    const Events = BinarySchema(&.{
        .{ .tform = "1J", .name = "COUNT" },
        .{ .tform = "2E", .name = "COORD" },
        .{ .tform = "8A", .name = "LABEL" },
    });
    try testing.expectEqual(@as(u16, 3), Events.field_count);
    try testing.expectEqual(@as(u64, 20), Events.row_bytes);
    try testing.expectEqualSlices(u64, &.{ 0, 4, 12 }, &Events.column_offsets);
}

test "large schemas stay within the intentional comptime evaluation budget" {
    const columns = comptime columns: {
        @setEvalBranchQuota(20_000_000);
        const prefix = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
        var result: [999]BinaryColumnSpec = undefined;
        for (&result, 0..) |*column, i| {
            column.* = .{ .tform = "1B", .name = std.fmt.comptimePrint(prefix ++ "{d}", .{i}) };
        }
        break :columns result;
    };
    const Wide = BinarySchema(&columns);
    try testing.expectEqual(@as(u16, 999), Wide.field_count);
    try testing.expectEqual(@as(u64, 999), Wide.row_bytes);
}

test "zero-repeat VLA fields contribute no row bytes" {
    const WithEmpty = BinarySchema(&.{
        .{ .tform = "0PJ", .name = "EMPTY" },
        .{ .tform = "1J", .name = "VALUE" },
    });
    try testing.expectEqual(@as(u64, 4), WithEmpty.row_bytes);
    try testing.expectEqualSlices(u64, &.{ 0, 0 }, &WithEmpty.column_offsets);
}

test "integer TDISP accepts an explicit zero minimum digit count" {
    const Counts = BinarySchema(&.{.{ .tform = "1J", .name = "COUNT", .tdisp = "I2.0" }});
    try testing.expectEqual(@as(u64, 4), Counts.row_bytes);
}

test "schema appends a table with optional metadata and typed access" {
    const Events = BinarySchema(&.{
        .{ .tform = "1J", .name = "COUNT", .unit = "ct", .tnull = -1 },
        .{ .tform = "4E", .name = "COORD", .tscal = 2, .tzero = 100, .tdim = &.{ 2, 2 }, .tdisp = "F8.2" },
    });

    var memory = MemoryDevice.init(testing.allocator);
    defer memory.deinit();
    var fits = try Fits.create(testing.allocator, memory.device(), .{});
    defer fits.deinit();
    _ = try fits.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });

    var table = try Events.append(&fits, .{ .rows = 2, .heap_bytes = 16, .extname = "EVENTS" });
    defer table.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 20), table.naxis1);
    try testing.expectEqual(@as(u64, 2), table.rowCount());
    const extname = try table.hdu.header.getString(testing.allocator, "EXTNAME");
    defer testing.allocator.free(extname);
    try testing.expectEqualStrings("EVENTS", extname);
    const unit = try table.hdu.header.getString(testing.allocator, "TUNIT1");
    defer testing.allocator.free(unit);
    try testing.expectEqualStrings("ct", unit);
    try testing.expectEqual(@as(u64, 16), table.hdu.pcount);
    try testing.expectEqual(@as(?i64, -1), table.columns[0].tnull);
    try testing.expectEqual(@as(f64, 2), table.columns[1].scal);
    try testing.expectEqual(@as(f64, 100), table.columns[1].zero);
    try testing.expectEqualSlices(u64, &.{ 2, 2 }, table.columns[1].tdim.?);
    const display = try table.hdu.header.getString(testing.allocator, "TDISP2");
    defer testing.allocator.free(display);
    try testing.expectEqualStrings("F8.2", display);

    const counts = [_]i32{ 10, 20 };
    try table.writeColumn(i32, .{ .name = "COUNT" }, 0, &counts, .{});
    var out: [2]i32 = undefined;
    try table.readColumn(i32, .{ .name = "COUNT" }, 0, &out, .{});
    try testing.expectEqualSlices(i32, &counts, &out);
}

test "schema append requires a primary HDU" {
    const Empty = BinarySchema(&.{});
    var memory = MemoryDevice.init(testing.allocator);
    defer memory.deinit();
    var fits = try Fits.create(testing.allocator, memory.device(), .{});
    defer fits.deinit();
    try testing.expectError(error.MissingRequiredKeyword, Empty.appendHdu(&fits, .{}));
}

test "schema append enforces the configured heap limit without mutation" {
    const Events = BinarySchema(&.{.{ .tform = "1PJ", .name = "VALUES" }});
    var memory = MemoryDevice.init(testing.allocator);
    defer memory.deinit();
    var fits = try Fits.create(testing.allocator, memory.device(), .{ .limits = .{ .max_heap_bytes = 15 } });
    defer fits.deinit();
    _ = try fits.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const size_before = try fits.dev.getSize();

    try testing.expectError(error.LimitExceeded, Events.appendHdu(&fits, .{ .heap_bytes = 16 }));
    try testing.expectEqual(@as(usize, 1), try fits.hduCount());
    try testing.expectEqual(size_before, try fits.dev.getSize());
}
