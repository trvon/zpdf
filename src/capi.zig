const std = @import("std");
const zpdf = @import("root.zig");

pub const ZpdfDocument = opaque {};

var c_allocator: std.mem.Allocator = std.heap.page_allocator;

export fn zpdf_open(path_ptr: [*:0]const u8) ?*ZpdfDocument {
    const path = std.mem.span(path_ptr);
    const doc = zpdf.Document.open(c_allocator, path) catch return null;
    return @ptrCast(doc);
}

export fn zpdf_open_memory(data: [*]const u8, len: usize) ?*ZpdfDocument {
    const slice = data[0..len];
    const doc = zpdf.Document.openFromMemory(c_allocator, slice, zpdf.ErrorConfig.default()) catch return null;
    return @ptrCast(doc);
}

export fn zpdf_close(handle: ?*ZpdfDocument) void {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        doc.close();
    }
}

export fn zpdf_page_count(handle: ?*ZpdfDocument) c_int {
    if (handle) |h| {
        const doc: *const zpdf.Document = @ptrCast(@alignCast(h));
        return @intCast(doc.pageCount());
    }
    return -1;
}

export fn zpdf_extract_page(handle: ?*ZpdfDocument, page_num: c_int, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0) return null;

        var buffer: std.ArrayList(u8) = .empty;
        doc.extractText(@intCast(page_num), buffer.writer(c_allocator)) catch return null;

        const slice = buffer.toOwnedSlice(c_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

export fn zpdf_extract_all(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));

        var buffer: std.ArrayList(u8) = .empty;
        doc.extractAllText(buffer.writer(c_allocator)) catch return null;

        const slice = buffer.toOwnedSlice(c_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

export fn zpdf_extract_all_parallel(handle: ?*ZpdfDocument, out_len: *usize) ?[*]u8 {
    if (handle) |h| {
        const doc: *zpdf.Document = @ptrCast(@alignCast(h));
        const result = doc.extractAllTextParallel(c_allocator) catch return null;
        out_len.* = result.len;
        return result.ptr;
    }
    return null;
}

export fn zpdf_free_buffer(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| {
        c_allocator.free(p[0..len]);
    }
}

export fn zpdf_get_page_info(handle: ?*ZpdfDocument, page_num: c_int, width: *f64, height: *f64, rotation: *c_int) c_int {
    if (handle) |h| {
        const doc: *const zpdf.Document = @ptrCast(@alignCast(h));
        if (page_num < 0 or @as(usize, @intCast(page_num)) >= doc.pages.items.len) return -1;

        const page = doc.pages.items[@intCast(page_num)];
        width.* = page.media_box[2] - page.media_box[0];
        height.* = page.media_box[3] - page.media_box[1];
        rotation.* = page.rotation;
        return 0;
    }
    return -1;
}
