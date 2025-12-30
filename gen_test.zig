const std = @import("std");
const testpdf = @import("src/testpdf.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const pdf_data = try testpdf.generateMinimalPdf(allocator, "Hello from zpdf!");
    defer allocator.free(pdf_data);

    const file = try std.fs.cwd().createFile("test.pdf", .{});
    defer file.close();
    try file.writeAll(pdf_data);

    std.debug.print("Generated test.pdf ({} bytes)\n", .{pdf_data.len});
}
