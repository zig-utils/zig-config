const std = @import("std");

/// Cross-platform environment variable retrieval
/// Returns null if the environment variable is not set
/// The returned string is owned by the environment and should not be freed
pub fn getEnvVar(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    // Use C getenv since std.process.getEnvVarOwned was removed
    var key_buf: [4096:0]u8 = undefined;
    if (key.len >= key_buf.len) return null;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    const value = std.c.getenv(&key_buf) orelse return null;
    const slice = std.mem.sliceTo(value, 0);
    return allocator.dupe(u8, slice) catch null;
}

/// Deep clone a JSON value with all nested structures
pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null, .bool, .integer, .float, .number_string => value,
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            const items = try allocator.alloc(std.json.Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                items[i] = try cloneJsonValue(allocator, item);
            }
            return .{ .array = std.json.Array.fromOwnedSlice(allocator, items) };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try new_obj.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            return .{ .object = new_obj };
        },
    };
}

/// Recursively free a JSON value and all its children
pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            // Recursively free all array items
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            allocator.free(arr.items);
        },
        .object => |obj| {
            // Recursively free all object entries
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            // Free the ObjectMap itself
            var mutable_obj = obj;
            mutable_obj.deinit();
        },
        else => {
            // Primitives (null, bool, integer, float, number_string) don't need freeing
        },
    }
}

/// Deep equality comparison for JSON values
pub fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    const a_tag = std.meta.activeTag(a);
    const b_tag = std.meta.activeTag(b);

    if (a_tag != b_tag) return false;

    return switch (a) {
        .null => true,
        .bool => |val| val == b.bool,
        .integer => |val| val == b.integer,
        .float => |val| val == b.float,
        .number_string => |val| std.mem.eql(u8, val, b.number_string),
        .string => |val| std.mem.eql(u8, val, b.string),
        .array => |arr| {
            const b_arr = b.array.items;
            if (arr.items.len != b_arr.len) return false;
            for (arr.items, b_arr) |a_item, b_item| {
                if (!jsonValuesEqual(a_item, b_item)) return false;
            }
            return true;
        },
        .object => |obj| {
            const b_obj = b.object;
            if (obj.count() != b_obj.count()) return false;

            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const b_value = b_obj.get(entry.key_ptr.*) orelse return false;
                if (!jsonValuesEqual(entry.value_ptr.*, b_value)) return false;
            }
            return true;
        },
    };
}

test "cloneJsonValue clones primitives" {
    const allocator = std.testing.allocator;

    const null_val = try cloneJsonValue(allocator, .null);
    try std.testing.expect(null_val == .null);

    const bool_val = try cloneJsonValue(allocator, .{ .bool = true });
    try std.testing.expectEqual(true, bool_val.bool);

    const int_val = try cloneJsonValue(allocator, .{ .integer = 42 });
    try std.testing.expectEqual(@as(i64, 42), int_val.integer);
}

test "cloneJsonValue clones strings" {
    const allocator = std.testing.allocator;

    const str_val = try cloneJsonValue(allocator, .{ .string = "test" });
    defer allocator.free(str_val.string);

    try std.testing.expectEqualStrings("test", str_val.string);
}

test "cloneJsonValue clones objects" {
    const allocator = std.testing.allocator;

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("key", .{ .integer = 123 });

    const cloned = try cloneJsonValue(allocator, .{ .object = obj });
    defer {
        var iter = cloned.object.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        var mutable_obj = cloned.object;
        mutable_obj.deinit();
    }

    try std.testing.expectEqual(@as(i64, 123), cloned.object.get("key").?.integer);
}

test "jsonValuesEqual compares primitives" {
    try std.testing.expect(jsonValuesEqual(.null, .null));
    try std.testing.expect(jsonValuesEqual(.{ .bool = true }, .{ .bool = true }));
    try std.testing.expect(!jsonValuesEqual(.{ .bool = true }, .{ .bool = false }));
    try std.testing.expect(jsonValuesEqual(.{ .integer = 42 }, .{ .integer = 42 }));
    try std.testing.expect(!jsonValuesEqual(.{ .integer = 42 }, .{ .integer = 43 }));
}

test "jsonValuesEqual compares strings" {
    try std.testing.expect(jsonValuesEqual(.{ .string = "test" }, .{ .string = "test" }));
    try std.testing.expect(!jsonValuesEqual(.{ .string = "test" }, .{ .string = "other" }));
}

test "jsonValuesEqual compares objects" {
    const allocator = std.testing.allocator;

    var obj1 = std.json.ObjectMap.init(allocator);
    defer obj1.deinit();
    try obj1.put("key", .{ .integer = 123 });

    var obj2 = std.json.ObjectMap.init(allocator);
    defer obj2.deinit();
    try obj2.put("key", .{ .integer = 123 });

    var obj3 = std.json.ObjectMap.init(allocator);
    defer obj3.deinit();
    try obj3.put("key", .{ .integer = 456 });

    try std.testing.expect(jsonValuesEqual(.{ .object = obj1 }, .{ .object = obj2 }));
    try std.testing.expect(!jsonValuesEqual(.{ .object = obj1 }, .{ .object = obj3 }));
}
