//! PDF Stream Decompression
//!
//! PDF supports multiple compression filters. In practice:
//! - FlateDecode (zlib/deflate): ~90% of streams
//! - DCTDecode (JPEG): images only
//! - ASCII85Decode: legacy, rare
//! - ASCIIHexDecode: legacy, rare
//! - LZWDecode: legacy, some old PDFs
//! - CCITTFaxDecode: fax images
//!
//! We optimize heavily for FlateDecode since it's the hot path.

const std = @import("std");
const Object = @import("parser.zig").Object;

pub const DecompressError = error{
    UnsupportedFilter,
    InvalidFilterParams,
    DecompressFailed,
    OutputTooLarge,
    InvalidPredictor,
};

/// Maximum decompressed size of one stream (prevent DoS)
pub const MAX_DECOMPRESSED_SIZE: usize = 256 * 1024 * 1024; // 256 MB

/// Decompress a PDF stream based on its /Filter entry
pub fn decompressStream(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter: ?Object,
    params: ?Object,
) ![]u8 {
    return decompressStreamLimited(allocator, data, filter, params, std.math.maxInt(usize));
}

/// Like decompressStream, but fails with OutputTooLarge once the result
/// would exceed `max_out` bytes. Filter output is also capped at
/// MAX_DECOMPRESSED_SIZE per stage. FlateDecode stops at the limit instead
/// of decompressing the whole stream first.
pub fn decompressStreamLimited(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter: ?Object,
    params: ?Object,
    max_out: usize,
) ![]u8 {
    const limit = @min(max_out, MAX_DECOMPRESSED_SIZE);
    // Declared here, not inside the switch, so the slice below outlives it.
    var names: [16][]const u8 = undefined;
    const filters: []const []const u8 = switch (filter orelse Object{ .array = &.{} }) {
        .name => |n| blk: {
            names[0] = n;
            break :blk names[0..1];
        },
        .array => |arr| blk: {
            var count: usize = 0;
            for (arr) |item| {
                if (item == .name and count < 16) {
                    names[count] = item.name;
                    count += 1;
                }
            }
            break :blk names[0..count];
        },
        else => names[0..0],
    };
    // No usable filter: the stream is returned as is, still within max_out.
    if (filters.len == 0) {
        if (data.len > max_out) return DecompressError.OutputTooLarge;
        return try allocator.dupe(u8, data);
    }

    var current = data;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);

    for (filters, 0..) |f, i| {
        const param = if (params) |p| switch (p) {
            .dict => p,
            .array => |arr| if (i < arr.len) arr[i] else null,
            else => null,
        } else null;

        const result = try applyFilter(allocator, current, f, param, limit);
        if (result.len > limit) {
            allocator.free(result);
            return DecompressError.OutputTooLarge;
        }

        if (owned) |o| allocator.free(o);
        owned = result;
        current = result;
    }

    const final = owned orelse try allocator.dupe(u8, data);
    owned = null; // Prevent double-free
    return final;
}

fn applyFilter(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter_name: []const u8,
    params: ?Object,
    max_out: usize,
) ![]u8 {
    if (std.mem.eql(u8, filter_name, "FlateDecode") or
        std.mem.eql(u8, filter_name, "Fl"))
    {
        return decodeFlateDecode(allocator, data, params, max_out);
    }

    if (std.mem.eql(u8, filter_name, "ASCII85Decode") or
        std.mem.eql(u8, filter_name, "A85"))
    {
        return decodeASCII85(allocator, data, max_out);
    }

    if (std.mem.eql(u8, filter_name, "ASCIIHexDecode") or
        std.mem.eql(u8, filter_name, "AHx"))
    {
        return decodeASCIIHex(allocator, data, max_out);
    }

    if (std.mem.eql(u8, filter_name, "LZWDecode") or
        std.mem.eql(u8, filter_name, "LZW"))
    {
        return decodeLZW(allocator, data, params, max_out);
    }

    if (std.mem.eql(u8, filter_name, "RunLengthDecode") or
        std.mem.eql(u8, filter_name, "RL"))
    {
        return decodeRunLength(allocator, data, max_out);
    }

    // DCTDecode (JPEG) and CCITTFaxDecode are for images - pass through for now
    if (std.mem.eql(u8, filter_name, "DCTDecode") or
        std.mem.eql(u8, filter_name, "DCT") or
        std.mem.eql(u8, filter_name, "CCITTFaxDecode") or
        std.mem.eql(u8, filter_name, "CCF") or
        std.mem.eql(u8, filter_name, "JBIG2Decode") or
        std.mem.eql(u8, filter_name, "JPXDecode"))
    {
        // These are image formats - return as-is for image extraction
        if (data.len > max_out) return DecompressError.OutputTooLarge;
        return try allocator.dupe(u8, data);
    }

    return DecompressError.UnsupportedFilter;
}

// ============================================================================
// FLATEDECODE - THE HOT PATH
// ============================================================================

fn decodeFlateDecode(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
    max_out: usize,
) ![]u8 {
    return decodeFlateDecodeWithLimit(allocator, data, params, @min(max_out, MAX_DECOMPRESSED_SIZE));
}

fn decodeFlateDecodeWithLimit(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
    max_size: usize,
) ![]u8 {
    // Use Zig's built-in zlib/flate decompressor
    var input: std.Io.Reader = .fixed(data);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .zlib, &decompress_buffer);

    // Pull bounded chunks so a compression bomb cannot allocate beyond the cap.
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = decomp.reader.readSliceShort(&chunk) catch return DecompressError.DecompressFailed;
        if (output.items.len > max_size or n > max_size - output.items.len) return DecompressError.OutputTooLarge;
        const new_len = output.items.len + n;
        // Grow geometrically (an exact reserve per chunk copied the whole
        // buffer every 64 KiB), but never past the limit.
        if (new_len > output.capacity) {
            try output.ensureTotalCapacityPrecise(allocator, @min(max_size, @max(new_len, output.capacity * 2)));
        }
        output.appendSliceAssumeCapacity(chunk[0..n]);
        if (n < chunk.len) break;
    }

    // Apply predictor if specified
    if (params) |p| {
        if (p == .dict) {
            const predictor = if (p.dict.get("Predictor")) |pred| switch (pred) {
                .integer => |value| std.math.cast(i32, value) orelse return DecompressError.InvalidFilterParams,
                else => 1,
            } else 1;

            if (predictor > 1) {
                const columns = if (p.dict.get("Columns")) |c| switch (c) {
                    .integer => |value| std.math.cast(u32, value) orelse return DecompressError.InvalidFilterParams,
                    else => 1,
                } else 1;

                const colors = if (p.dict.get("Colors")) |c| switch (c) {
                    .integer => |value| std.math.cast(u32, value) orelse return DecompressError.InvalidFilterParams,
                    else => 1,
                } else 1;

                const bits = if (p.dict.get("BitsPerComponent")) |b| switch (b) {
                    .integer => |value| std.math.cast(u32, value) orelse return DecompressError.InvalidFilterParams,
                    else => 8,
                } else 8;

                // applyPredictor returns a new buffer; free the decoded one.
                defer output.deinit(allocator);
                return try applyPredictor(
                    allocator,
                    output.items,
                    predictor,
                    columns,
                    colors,
                    bits,
                );
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Apply PNG predictor to decoded data
fn applyPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    predictor: i32,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    if (predictor == 1) {
        // No prediction
        return try allocator.dupe(u8, data);
    }

    if (predictor == 2) {
        // TIFF Predictor 2
        return applyTiffPredictor(allocator, data, columns, colors, bits);
    }

    if (predictor >= 10 and predictor <= 15) {
        // PNG predictors
        return applyPngPredictor(allocator, data, columns, colors, bits);
    }

    return DecompressError.InvalidPredictor;
}

fn applyTiffPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    if (columns == 0 or colors == 0 or bits != 8) return DecompressError.InvalidFilterParams;
    const bytes_per_row = std.math.mul(usize, columns, colors) catch return DecompressError.InvalidFilterParams;
    if (bytes_per_row == 0) return DecompressError.InvalidFilterParams;
    const num_rows = data.len / bytes_per_row;

    var output = try allocator.alloc(u8, data.len);
    errdefer allocator.free(output);

    var row: usize = 0;
    while (row < num_rows) : (row += 1) {
        const row_start = row * bytes_per_row;
        const row_data = data[row_start..][0..bytes_per_row];
        const out_row = output[row_start..][0..bytes_per_row];

        // First pixel unchanged
        var col: usize = 0;
        while (col < colors) : (col += 1) {
            out_row[col] = row_data[col];
        }

        // Subsequent pixels: add to previous
        while (col < bytes_per_row) : (col += 1) {
            out_row[col] = row_data[col] +% out_row[col - colors];
        }
    }

    return output;
}

fn applyPngPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    if (columns == 0 or colors == 0 or
        !(bits == 1 or bits == 2 or bits == 4 or bits == 8 or bits == 16))
    {
        return DecompressError.InvalidFilterParams;
    }
    const pixel_bits = std.math.mul(usize, colors, bits) catch return DecompressError.InvalidFilterParams;
    const row_bits = std.math.mul(usize, columns, pixel_bits) catch return DecompressError.InvalidFilterParams;
    const rounded_pixel_bits = std.math.add(usize, pixel_bits, 7) catch return DecompressError.InvalidFilterParams;
    const rounded_row_bits = std.math.add(usize, row_bits, 7) catch return DecompressError.InvalidFilterParams;
    const row_bytes = rounded_row_bits / 8;
    const src_row_bytes = std.math.add(usize, row_bytes, 1) catch return DecompressError.InvalidFilterParams;
    const bytes_per_pixel = rounded_pixel_bits / 8;
    if (bytes_per_pixel == 0 or row_bytes == 0) return DecompressError.InvalidFilterParams;

    const num_rows = data.len / src_row_bytes;
    const out_len = std.math.mul(usize, num_rows, row_bytes) catch return DecompressError.InvalidFilterParams;

    var output = try allocator.alloc(u8, out_len);
    errdefer allocator.free(output);

    var prev_row: ?[]const u8 = null;

    var row: usize = 0;
    while (row < num_rows) : (row += 1) {
        const src_start = row * src_row_bytes;
        if (src_start >= data.len) break;

        const filter_type = data[src_start];
        const src_row = data[src_start + 1 ..][0..row_bytes];
        const out_row = output[row * row_bytes ..][0..row_bytes];

        switch (filter_type) {
            0 => {
                // None
                @memcpy(out_row, src_row);
            },
            1 => {
                // Sub
                for (out_row, 0..) |*b, i| {
                    const left: u8 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    b.* = src_row[i] +% left;
                }
            },
            2 => {
                // Up
                for (out_row, 0..) |*b, i| {
                    const up: u8 = if (prev_row) |pr| pr[i] else 0;
                    b.* = src_row[i] +% up;
                }
            },
            3 => {
                // Average
                for (out_row, 0..) |*b, i| {
                    const left: u16 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    const up: u16 = if (prev_row) |pr| pr[i] else 0;
                    b.* = src_row[i] +% @as(u8, @truncate((left + up) / 2));
                }
            },
            4 => {
                // Paeth
                for (out_row, 0..) |*b, i| {
                    const left: i16 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    const up: i16 = if (prev_row) |pr| pr[i] else 0;
                    const up_left: i16 = if (prev_row != null and i >= bytes_per_pixel)
                        prev_row.?[i - bytes_per_pixel]
                    else
                        0;

                    b.* = src_row[i] +% paeth(left, up, up_left);
                }
            },
            else => {
                // Unknown filter - copy as-is
                @memcpy(out_row, src_row);
            },
        }

        prev_row = out_row;
    }

    return output;
}

fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if (pa <= pb and pa <= pc) {
        return @truncate(@as(u16, @bitCast(a)));
    } else if (pb <= pc) {
        return @truncate(@as(u16, @bitCast(b)));
    } else {
        return @truncate(@as(u16, @bitCast(c)));
    }
}

// ============================================================================
// ASCII85DECODE
// ============================================================================

fn decodeASCII85(allocator: std.mem.Allocator, data: []const u8, max_out: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // u64 so a group above 2^32-1 ("uuuuu") is detected instead of
    // overflowing; such a group is invalid ASCII85.
    var tuple: u64 = 0;
    var count: u8 = 0;
    var i: usize = 0;

    while (i < data.len) : (i += 1) {
        const c = data[i];

        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

        // End of data marker
        if (c == '~') {
            if (i + 1 < data.len and data[i + 1] == '>') break;
            continue;
        }

        // 'z' represents 4 zero bytes
        if (c == 'z') {
            if (count != 0) return DecompressError.DecompressFailed;
            if (output.items.len + 4 > max_out) return DecompressError.OutputTooLarge;
            try output.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 });
            continue;
        }

        // Regular ASCII85 character
        if (c < '!' or c > 'u') continue;

        tuple = tuple * 85 + (c - '!');
        count += 1;

        if (count == 5) {
            if (tuple > std.math.maxInt(u32)) return DecompressError.DecompressFailed;
            if (output.items.len + 4 > max_out) return DecompressError.OutputTooLarge;
            try output.append(allocator, @truncate(tuple >> 24));
            try output.append(allocator, @truncate(tuple >> 16));
            try output.append(allocator, @truncate(tuple >> 8));
            try output.append(allocator, @truncate(tuple));
            tuple = 0;
            count = 0;
        }
    }

    // Handle remaining bytes
    if (count > 0) {
        var j: u8 = count;
        while (j < 5) : (j += 1) {
            tuple = tuple * 85 + 84;
        }
        if (tuple > std.math.maxInt(u32)) return DecompressError.DecompressFailed;

        if (output.items.len + (count - 1) > max_out) return DecompressError.OutputTooLarge;
        if (count >= 2) try output.append(allocator, @truncate(tuple >> 24));
        if (count >= 3) try output.append(allocator, @truncate(tuple >> 16));
        if (count >= 4) try output.append(allocator, @truncate(tuple >> 8));
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// ASCIIHEXDECODE
// ============================================================================

fn decodeASCIIHex(allocator: std.mem.Allocator, data: []const u8, max_out: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var high: ?u4 = null;

    for (data) |c| {
        // End marker
        if (c == '>') break;

        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

        const nibble: ?u4 = if (c >= '0' and c <= '9')
            @truncate(c - '0')
        else if (c >= 'A' and c <= 'F')
            @truncate(c - 'A' + 10)
        else if (c >= 'a' and c <= 'f')
            @truncate(c - 'a' + 10)
        else
            null;

        if (nibble) |n| {
            if (high) |h| {
                if (output.items.len >= max_out) return DecompressError.OutputTooLarge;
                try output.append(allocator, (@as(u8, h) << 4) | n);
                high = null;
            } else {
                high = n;
            }
        }
    }

    // Trailing nibble is padded with 0
    if (high) |h| {
        if (output.items.len >= max_out) return DecompressError.OutputTooLarge;
        try output.append(allocator, @as(u8, h) << 4);
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// LZWDECODE
// ============================================================================

fn decodeLZW(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
    max_out: usize,
) ![]u8 {
    // /EarlyChange (default 1): widen codes one entry before the table needs it.
    const early: u16 = if (params) |p| switch (p) {
        .dict => |d| if (d.get("EarlyChange")) |e| switch (e) {
            .integer => |v| if (v == 0) 0 else 1,
            else => 1,
        } else 1,
        else => 1,
    } else 1;
    return decodeLZWEarly(allocator, data, early, max_out);
}

fn decodeLZWEarly(
    allocator: std.mem.Allocator,
    data: []const u8,
    early: u16,
    max_out: usize,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // Dictionary as prefix links: entry = entry[prefix] ++ suffix. No per-entry
    // allocation; an entry is written out by walking its prefix chain backwards.
    const max_codes = 4096;
    var prefix: [max_codes]u16 = undefined;
    var suffix: [max_codes]u8 = undefined;
    var first: [max_codes]u8 = undefined;
    var lens: [max_codes]u16 = undefined;
    for (0..256) |i| {
        prefix[i] = 0;
        suffix[i] = @truncate(i);
        first[i] = @truncate(i);
        lens[i] = 1;
    }
    var size: u16 = 258; // 256 = clear, 257 = end of data

    var bit_pos: usize = 0;
    var code_size: u4 = 9;
    var prev_code: ?u16 = null;

    while (true) {
        // Read next code
        const code = readBits(data, bit_pos, code_size) orelse break;
        bit_pos += code_size;

        // Clear table
        if (code == 256) {
            size = 258;
            code_size = 9;
            prev_code = null;
            continue;
        }

        // End of data
        if (code == 257) break;

        if (code < size) {
            try emitLzw(allocator, &output, code, &prefix, &suffix, &lens);
            if (prev_code) |pc| {
                if (pc < size and size < max_codes) {
                    prefix[size] = pc;
                    suffix[size] = first[code];
                    first[size] = first[pc];
                    lens[size] = lens[pc] + 1;
                    size += 1;
                }
            }
        } else if (prev_code) |pc| {
            // Code not yet in the table: it is prev ++ prev[0].
            if (pc < size) {
                try emitLzw(allocator, &output, pc, &prefix, &suffix, &lens);
                try output.append(allocator, first[pc]);
                if (size < max_codes) {
                    prefix[size] = pc;
                    suffix[size] = first[pc];
                    first[size] = first[pc];
                    lens[size] = lens[pc] + 1;
                    size += 1;
                }
            }
        }
        if (output.items.len > max_out) return DecompressError.OutputTooLarge;

        prev_code = code;

        // Increase code size when needed
        if (size + early >= (@as(u16, 1) << code_size) and code_size < 12) {
            code_size += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

/// Append dictionary entry `code` by walking its prefix chain backwards.
fn emitLzw(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    code: u16,
    prefix: *const [4096]u16,
    suffix: *const [4096]u8,
    lens: *const [4096]u16,
) !void {
    const len = lens[code];
    const start = output.items.len;
    try output.resize(allocator, start + len);
    var c = code;
    var pos = start + len;
    while (pos > start) {
        pos -= 1;
        output.items[pos] = suffix[c];
        c = prefix[c];
    }
}

fn readBits(data: []const u8, bit_pos: usize, count: u4) ?u16 {
    // MSB-first code of `count` bits starting at bit_pos; null past the end.
    if (bit_pos + count > data.len * 8) return null;
    const byte_pos = bit_pos / 8;
    const bit_offset: u5 = @truncate(bit_pos % 8);

    // Up to 3 bytes cover any 12-bit code at any bit offset; missing bytes read as 0.
    const b0: u24 = data[byte_pos];
    const b1: u24 = if (byte_pos + 1 < data.len) data[byte_pos + 1] else 0;
    const b2: u24 = if (byte_pos + 2 < data.len) data[byte_pos + 2] else 0;

    const combined: u24 = (b0 << 16) | (b1 << 8) | b2;
    const shift: u5 = 24 - @as(u5, count) - bit_offset;
    // Mask off the bits of the previous code that share the first byte.
    const mask: u24 = (@as(u24, 1) << count) - 1;
    return @truncate((combined >> shift) & mask);
}

// ============================================================================
// RUNLENGTHDECODE
// ============================================================================

fn decodeRunLength(allocator: std.mem.Allocator, data: []const u8, max_out: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        const length = data[i];
        i += 1;

        if (length == 128) {
            // End of data
            break;
        } else if (length < 128) {
            // Copy next length+1 bytes literally
            const copy_len = @as(usize, length) + 1;
            if (i + copy_len > data.len) break;
            if (copy_len > max_out -| output.items.len) return DecompressError.OutputTooLarge;
            try output.appendSlice(allocator, data[i..][0..copy_len]);
            i += copy_len;
        } else {
            // Repeat next byte (257-length) times
            const repeat_count = 257 - @as(usize, length);
            if (i >= data.len) break;
            if (repeat_count > max_out -| output.items.len) return DecompressError.OutputTooLarge;
            const byte = data[i];
            i += 1;
            try output.appendNTimes(allocator, byte, repeat_count);
        }
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "decodeASCIIHex" {
    const allocator = std.testing.allocator;

    const input = "48656C6C6F>";
    const result = try decodeASCIIHex(allocator, input, MAX_DECOMPRESSED_SIZE);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeASCIIHex with whitespace" {
    const allocator = std.testing.allocator;

    const input = "48 65 6C\n6C 6F>";
    const result = try decodeASCIIHex(allocator, input, MAX_DECOMPRESSED_SIZE);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeASCII85" {
    const allocator = std.testing.allocator;

    // "Hello world" in ASCII85
    const input = "87cURD]j7BEbo7~>";
    const result = try decodeASCII85(allocator, input, MAX_DECOMPRESSED_SIZE);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello world", result);
}

test "decodeRunLength" {
    const allocator = std.testing.allocator;

    // [2, 'A', 'B', 'C'] = copy 3 bytes
    // [254, 'X'] = repeat 'X' 3 times
    // [128] = end
    const input = [_]u8{ 2, 'A', 'B', 'C', 254, 'X', 128 };
    const result = try decodeRunLength(allocator, &input, MAX_DECOMPRESSED_SIZE);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("ABCXXX", result);
}

test "predictors reject unsafe dimensions and unsupported TIFF bit depths" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidFilterParams, applyTiffPredictor(allocator, "abc", 0, 1, 8));
    try std.testing.expectError(error.InvalidFilterParams, applyTiffPredictor(allocator, "abc", 1, 0, 8));
    try std.testing.expectError(error.InvalidFilterParams, applyTiffPredictor(allocator, "abc", 1, 1, 4));
    try std.testing.expectError(error.InvalidFilterParams, applyPngPredictor(allocator, "abc", 0, 1, 8));
    try std.testing.expectError(error.InvalidFilterParams, applyPngPredictor(allocator, "abc", 1, 1, 3));
}

test "FlateDecode enforces output limit while streaming" {
    const compressed = [_]u8{
        0x78, 0x9c, 0xed, 0xc1, 0x31, 0x01, 0x00, 0x00, 0x00, 0xc2, 0xa0, 0x6c, 0xeb, 0x5f, 0xca, 0x1a,
        0x1e, 0x40, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xaf,
        0x06, 0xe2, 0x0c, 0x34, 0x6e,
    };
    try std.testing.expectError(
        error.OutputTooLarge,
        decodeFlateDecodeWithLimit(std.testing.allocator, &compressed, null, 1_000),
    );
}
test "flate stops at the output limit without buffering the whole stream" {
    const PeakAllocator = @import("testpdf.zig").PeakAllocator;
    const bomb = @embedFile("testdata/zeros_1mib.zlib"); // 1 MiB of zeros
    const flate: Object = .{ .name = "FlateDecode" };

    var peak = PeakAllocator{ .child = std.testing.allocator };
    const a = peak.allocator();
    try std.testing.expectError(
        DecompressError.OutputTooLarge,
        decompressStreamLimited(a, bomb, flate, null, 64 * 1024),
    );
    try std.testing.expectEqual(@as(usize, 0), peak.live);
    try std.testing.expect(peak.peak < 512 * 1024);

    const out = try decompressStreamLimited(a, bomb, flate, null, 2 * 1024 * 1024);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), out.len);
    try std.testing.expect(peak.peak < 3 * 1024 * 1024);

    // The limit is inclusive: exactly max_out bytes fit, one fewer does not.
    const exact = try decompressStreamLimited(a, bomb, flate, null, 1024 * 1024);
    defer a.free(exact);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), exact.len);
    try std.testing.expectError(
        DecompressError.OutputTooLarge,
        decompressStreamLimited(a, bomb, flate, null, 1024 * 1024 - 1),
    );
}

test "limited passthrough rejects raw streams over the limit" {
    try std.testing.expectError(
        DecompressError.OutputTooLarge,
        decompressStreamLimited(std.testing.allocator, "0123456789", null, null, 4),
    );
    const ok = try decompressStream(std.testing.allocator, "0123456789", null, null);
    defer std.testing.allocator.free(ok);
    try std.testing.expectEqualStrings("0123456789", ok);
}

test "fuzz: limited decompression stays within its limit and never leaks" {
    // std.testing.Smith arrived in Zig 0.16. The callback lives inside the
    // guarded branch so older toolchains never analyze its signature.
    if (comptime @hasDecl(std.testing, "Smith")) {
        const Fuzz = struct {
            fn one(_: void, smith: *std.testing.Smith) !void {
                const filters = [_][]const u8{
                    "FlateDecode", "ASCIIHexDecode", "ASCII85Decode", "LZWDecode", "RunLengthDecode",
                };
                var buf: [4096]u8 = undefined;
                const filter: Object = .{ .name = filters[smith.value(u8) % filters.len] };
                const limit = smith.valueRangeAtMost(u32, 0, 1 << 20);
                const data = buf[0..smith.slice(&buf)];

                // std.testing.allocator fails the test on any leak, including on error paths.
                const a = std.testing.allocator;
                const out = decompressStreamLimited(a, data, filter, null, limit) catch return;
                defer a.free(out);
                try std.testing.expect(out.len <= limit);
            }
        };
        try std.testing.fuzz({}, Fuzz.one, .{
            .corpus = &.{@embedFile("testdata/zeros_1mib.zlib")},
        });
    } else return error.SkipZigTest;
}

test "ASCII85 rejects groups above 2^32-1 instead of overflowing" {
    const a = std.testing.allocator;
    const a85: Object = .{ .name = "ASCII85Decode" };
    try std.testing.expectError(DecompressError.DecompressFailed, decompressStream(a, "uuuuu~>", a85, null));
    try std.testing.expectError(DecompressError.DecompressFailed, decompressStream(a, "uu~>", a85, null));
    // s8W-! is the largest valid group: 0xFFFFFFFF.
    const ok = try decompressStream(a, "s8W-!~>", a85, null);
    defer a.free(ok);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF }, ok);
}

test "LZW decodes the PDF reference example" {
    // PDF 1.7 reference, section 3.3.3: codes 256 45 258 258 65 259 66 257.
    const encoded = [_]u8{ 0x80, 0x0B, 0x60, 0x50, 0x22, 0x0C, 0x0C, 0x85, 0x01 };
    const out = try decompressStream(std.testing.allocator, &encoded, .{ .name = "LZWDecode" }, null);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("-----A---B", out);
}

/// String-table LZW reference with the same code-width and table rules as
/// decodeLZW, for differential testing.
fn referenceLZW(a: std.mem.Allocator, data: []const u8, early: usize) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var table: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const reset = struct {
        fn f(t: *std.ArrayList([]const u8), al: std.mem.Allocator) !void {
            t.clearRetainingCapacity();
            for (0..256) |i| {
                const e = try al.alloc(u8, 1);
                e[0] = @truncate(i);
                try t.append(al, e);
            }
            try t.append(al, "");
            try t.append(al, "");
        }
    }.f;
    try reset(&table, ar);
    var bit_pos: usize = 0;
    var code_size: u4 = 9;
    var prev: ?u16 = null;
    while (readBits(data, bit_pos, code_size)) |code| {
        bit_pos += code_size;
        if (code == 256) {
            try reset(&table, ar);
            code_size = 9;
            prev = null;
            continue;
        }
        if (code == 257) break;
        if (code < table.items.len) {
            const e = table.items[code];
            try out.appendSlice(a, e);
            if (prev) |pc| if (pc < table.items.len and table.items.len < 4096) {
                const n = try std.mem.concat(ar, u8, &.{ table.items[pc], e[0..1] });
                try table.append(ar, n);
            };
        } else if (prev) |pc| {
            if (pc < table.items.len) {
                const p = table.items[pc];
                const n = try std.mem.concat(ar, u8, &.{ p, p[0..1] });
                try out.appendSlice(a, n);
                if (table.items.len < 4096) try table.append(ar, n);
            }
        }
        prev = code;
        if (table.items.len + early >= (@as(usize, 1) << code_size) and code_size < 12) code_size += 1;
    }
    return out.toOwnedSlice(a);
}

test "LZW matches the string-table reference on random code streams" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x12a7);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (0..5_000) |_| {
        const n = r.uintLessThan(usize, buf.len);
        r.bytes(buf[0..n]);
        const early: u16 = r.uintAtMost(u16, 1);
        const want = try referenceLZW(a, buf[0..n], early);
        defer a.free(want);
        const got = decodeLZWEarly(a, buf[0..n], early, MAX_DECOMPRESSED_SIZE) catch |err| {
            std.debug.print("decodeLZW failed with {t} on {d} bytes\n", .{ err, n });
            return err;
        };
        defer a.free(got);
        try std.testing.expectEqualSlices(u8, want, got);
    }
}

/// Minimal LZW encoder (MSB-first, clear code first, EOD last) with the
/// same /EarlyChange width rule as the decoder, for round-trip tests.
fn encodeLZW(a: std.mem.Allocator, input: []const u8, early: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var acc: u32 = 0;
    var nbits: u5 = 0;
    var width: u4 = 9;
    var dict: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer dict.deinit(a);
    var next: u16 = 258;
    const emit = struct {
        fn f(o: *std.ArrayList(u8), al: std.mem.Allocator, ac: *u32, nb: *u5, code: u16, w: u4) !void {
            ac.* = (ac.* << w) | code;
            nb.* += w;
            while (nb.* >= 8) {
                nb.* -= 8;
                try o.append(al, @truncate(ac.* >> nb.*));
            }
            ac.* &= (@as(u32, 1) << nb.*) - 1;
        }
    }.f;
    try emit(&out, a, &acc, &nbits, 256, width);
    if (input.len > 0) {
        var cur: u16 = input[0];
        for (input[1..]) |b| {
            const key = (@as(u32, cur) << 8) | b;
            if (dict.get(key)) |code| {
                cur = code;
                continue;
            }
            // Width the decoder uses for this code: it lags one entry behind.
            while (width < 12 and next - 1 + early >= (@as(u16, 1) << width)) width += 1;
            try emit(&out, a, &acc, &nbits, cur, width);
            if (next < 4096) {
                try dict.put(a, key, next);
                next += 1;
            }
            cur = b;
        }
        while (width < 12 and next - 1 + early >= (@as(u16, 1) << width)) width += 1;
        try emit(&out, a, &acc, &nbits, cur, width);
        if (next < 4096) next += 1;
    }
    while (width < 12 and next - 1 + early >= (@as(u16, 1) << width)) width += 1;
    try emit(&out, a, &acc, &nbits, 257, width);
    if (nbits > 0) try out.append(a, @truncate(acc << (8 - @as(u5, nbits))));
    return out.toOwnedSlice(a);
}

test "LZW round-trips across code-width changes for both EarlyChange values" {
    const a = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xEC0);
    const r = prng.random();
    var buf: [30_000]u8 = undefined;
    for (0..60) |i| {
        const n = r.uintAtMost(usize, buf.len);
        // Small alphabets build long dictionary chains; full bytes fill the table.
        const alphabet: u8 = if (i % 3 == 0) 4 else if (i % 3 == 1) 26 else 255;
        for (buf[0..n]) |*b| b.* = r.uintAtMost(u8, alphabet);
        for ([_]u16{ 0, 1 }) |early| {
            const enc = try encodeLZW(a, buf[0..n], early);
            defer a.free(enc);
            const dec = try decodeLZWEarly(a, enc, early, MAX_DECOMPRESSED_SIZE);
            defer a.free(dec);
            try std.testing.expectEqualSlices(u8, buf[0..n], dec);
        }
    }
    // /DecodeParms selects the rule; the default is EarlyChange 1.
    var parms_entries = [_]Object.Dict.Entry{.{ .key = "EarlyChange", .value = .{ .integer = 0 } }};
    const parms: Object = .{ .dict = .{ .entries = &parms_entries } };
    for (buf[0..20_000]) |*b| b.* = r.uintAtMost(u8, 26);
    const enc0 = try encodeLZW(a, buf[0..20_000], 0);
    defer a.free(enc0);
    const dec0 = try decompressStream(a, enc0, .{ .name = "LZWDecode" }, parms);
    defer a.free(dec0);
    try std.testing.expectEqualSlices(u8, buf[0..20_000], dec0);
    const enc1 = try encodeLZW(a, buf[0..20_000], 1);
    defer a.free(enc1);
    const dec1 = try decompressStream(a, enc1, .{ .name = "LZWDecode" }, null);
    defer a.free(dec1);
    try std.testing.expectEqualSlices(u8, buf[0..20_000], dec1);
}

test "limited decoders stop at the limit" {
    const a = std.testing.allocator;
    const cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "ASCIIHexDecode", .data = "41424344454647>" },
        .{ .name = "ASCII85Decode", .data = "zzzz~>" },
        .{ .name = "RunLengthDecode", .data = &.{ 0x81, 'x', 0x81, 'y', 0x80 } },
        .{ .name = "DCTDecode", .data = "0123456789" },
    };
    for (cases) |c| {
        try std.testing.expectError(
            DecompressError.OutputTooLarge,
            decompressStreamLimited(a, c.data, .{ .name = c.name }, null, 3),
        );
    }
    // An empty or malformed filter returns the data, but still within the limit.
    try std.testing.expectError(DecompressError.OutputTooLarge, decompressStreamLimited(a, "0123456789", .{ .array = &.{} }, null, 4));
    try std.testing.expectError(DecompressError.OutputTooLarge, decompressStreamLimited(a, "0123456789", .{ .integer = 7 }, null, 4));
}
