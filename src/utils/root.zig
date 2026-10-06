const std = @import("std");
const ascii = @import("std").ascii;

const PatternOptions = struct {
    case_sensitive: bool = true,
};

/// Searches for the first occurrence of `needle` in `haystack`.
///
/// Returns:
/// - The starting index of the first match if found.
/// - `null` if `needle` is empty, longer than `haystack`, or no match is found.
///
/// Case sensitivity is controlled by `opts.case_sensitive`.
pub fn findPattern(haystack: []const u8, needle: []const u8, opts: PatternOptions) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;

    var i: usize = 0;

    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        var j: usize = 0;

        while (j < needle.len) : (j += 1) {
            const h = if (opts.case_sensitive) haystack[i + j] else ascii.toLower(haystack[i + j]);
            const n = if (opts.case_sensitive) needle[j] else ascii.toLower(needle[j]);

            if (h != n) {
                match = false;
                break;
            }
        }

        if (match) return i;
    }

    return null;
}

test "findPattern found pattern at the end" {
    const haystack = "hello world";
    const needle = "world";
    const expected = 6;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern found pattern at the beginning" {
    const haystack = "USB Audio";
    const needle = "USB";
    const expected = 0;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern found pattern in the middle" {
    const haystack = "hello world is a nice place";
    const needle = "world";
    const expected = 6;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern did not find a pattern" {
    const haystack = "hello world";
    const needle = "something";
    const expected = null;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}
test "findPattern with empty haystack" {
    const haystack = "";
    const needle = "test";
    const expected: ?usize = null;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern with empty needle" {
    const haystack = "hello world";
    const needle = "";
    const expected: ?usize = null;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern with equal length strings" {
    const haystack = "test";
    const needle = "test";
    const expected: ?usize = 0;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern with pattern longer than haystack" {
    const haystack = "short";
    const needle = "longer string";
    const expected: ?usize = null;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern with overlapping characters" {
    const haystack = "aaaaa";
    const needle = "aa";
    const expected: ?usize = 0; // Should find first occurrence
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern with special characters" {
    const haystack = "hello\n\tworld";
    const needle = "\n\t";
    const expected: ?usize = 5;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern with single character" {
    const haystack = "hello world";
    const needle = "o";
    const expected: ?usize = 4; // First 'o' in "hello"
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern with unicode characters" {
    const haystack = "Hello 世界!";
    const needle = "世界";
    const expected: ?usize = 6;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern case sensitive" {
    const haystack = "Hello World";
    const needle = "world"; // lowercase, should not match "World"
    const expected: ?usize = null;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}

test "findPattern case insensitive" {
    const haystack = "Hello World";
    const needle = "world";
    const expected: ?usize = 6;
    const result = findPattern(haystack, needle, .{ .case_sensitive = false });
    try std.testing.expectEqual(result, expected);
}

test "findPattern with pattern at start" {
    const haystack = "prefix rest of string";
    const needle = "prefix";
    const expected: ?usize = 0;
    const result = findPattern(haystack, needle, .{});
    try std.testing.expectEqual(result, expected);
}
