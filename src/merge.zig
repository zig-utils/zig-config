const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const utils = @import("utils.zig");

const MergeError = std.mem.Allocator.Error || errors.ZigConfigError;

/// Deep merge two JSON values
pub fn deepMerge(
    allocator: std.mem.Allocator,
    target: std.json.Value,
    source: std.json.Value,
    options: types.MergeOptions,
) MergeError!std.json.Value {
    var visited = std.AutoHashMap(usize, void).init(allocator);
    defer visited.deinit();

    return try deepMergeImpl(allocator, target, source, options, &visited);
}

fn deepMergeImpl(
    allocator: std.mem.Allocator,
    target: std.json.Value,
    source: std.json.Value,
    options: types.MergeOptions,
    visited: *std.AutoHashMap(usize, void),
) MergeError!std.json.Value {
    // If types differ, source wins
    const target_tag = std.meta.activeTag(target);
    const source_tag = std.meta.activeTag(source);

    if (target_tag != source_tag) {
        return try utils.cloneJsonValue(allocator, source);
    }

    switch (source) {
        .object => |source_obj| {
            const target_obj = target.object;

            // Circular reference check
            const addr = @intFromPtr(&target_obj);
            if (visited.get(addr)) |_| {
                return errors.ZigConfigError.CircularReferenceDetected;
            }
            try visited.put(addr, {});
            defer _ = visited.remove(addr);

            // Merge objects
            var result = std.json.ObjectMap.init(allocator);

            // Add all target keys
            var target_iter = target_obj.iterator();
            while (target_iter.next()) |entry| {
                try result.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try utils.cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }

            // Merge/add source keys
            var source_iter = source_obj.iterator();
            while (source_iter.next()) |entry| {
                if (result.getPtr(entry.key_ptr.*)) |target_value_ptr| {
                    // Save the old value
                    const old_value = target_value_ptr.*;

                    // Recursive merge
                    const merged = try deepMergeImpl(
                        allocator,
                        old_value,
                        entry.value_ptr.*,
                        options,
                        visited,
                    );

                    // Replace with merged value
                    target_value_ptr.* = merged;

                    // Free the old value after replacement
                    utils.freeJsonValue(allocator, old_value);
                } else {
                    // Add new key
                    try result.put(
                        try allocator.dupe(u8, entry.key_ptr.*),
                        try utils.cloneJsonValue(allocator, entry.value_ptr.*),
                    );
                }
            }

            return .{ .object = result };
        },

        .array => |source_arr| {
            const target_arr = target.array.items;
            const merged_items = try mergeArrays(
                allocator,
                target_arr,
                source_arr.items,
                options.strategy,
            );
            return .{ .array = std.json.Array.fromOwnedSlice(allocator, merged_items) };
        },

        else => {
            // Primitives: source wins
            return try utils.cloneJsonValue(allocator, source);
        },
    }
}

fn mergeArrays(
    allocator: std.mem.Allocator,
    target: []std.json.Value,
    source: []std.json.Value,
    strategy: types.MergeStrategy,
) ![]std.json.Value {
    return switch (strategy) {
        .replace => try cloneArray(allocator, source),
        .concat => try concatArrays(allocator, target, source),
        .smart => try smartMergeArrays(allocator, target, source),
    };
}

fn cloneArray(allocator: std.mem.Allocator, arr: []std.json.Value) ![]std.json.Value {
    var result = std.ArrayList(std.json.Value){};
    try result.ensureTotalCapacity(allocator, arr.len);
    for (arr) |item| {
        try result.append(allocator, try utils.cloneJsonValue(allocator, item));
    }
    return try result.toOwnedSlice(allocator);
}

fn concatArrays(
    allocator: std.mem.Allocator,
    target: []std.json.Value,
    source: []std.json.Value,
) ![]std.json.Value {
    var result = std.ArrayList(std.json.Value){};
    try result.ensureTotalCapacity(allocator, target.len + source.len);

    // Add all target items
    for (target) |item| {
        try result.append(allocator, try utils.cloneJsonValue(allocator, item));
    }

    // Add source items (deduplicate if same value)
    for (source) |item| {
        var found = false;
        for (result.items) |existing| {
            if (try valuesEqual(existing, item)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try result.append(allocator, try utils.cloneJsonValue(allocator, item));
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn smartMergeArrays(
    allocator: std.mem.Allocator,
    target: []std.json.Value,
    source: []std.json.Value,
) ![]std.json.Value {
    // Check if both are object arrays
    if (!isObjectArray(target) or !isObjectArray(source)) {
        return try concatArrays(allocator, target, source);
    }

    // Find merge key
    const merge_key = findMergeKey(target[0].object) orelse {
        return try concatArrays(allocator, target, source);
    };

    var result = std.ArrayList(std.json.Value){};
    try result.ensureTotalCapacity(allocator, target.len + source.len);
    var seen = std.StringHashMap(usize).init(allocator);
    defer seen.deinit();

    // Add all target items
    for (target, 0..) |item, i| {
        const key_value = item.object.get(merge_key).?.string;
        try seen.put(key_value, i);
        try result.append(allocator, try utils.cloneJsonValue(allocator, item));
    }

    // Merge or add source items
    for (source) |source_item| {
        const key_value = source_item.object.get(merge_key).?.string;

        if (seen.get(key_value)) |target_idx| {
            // Merge with existing
            var visited = std.AutoHashMap(usize, void).init(allocator);
            defer visited.deinit();

            // Save the old value
            const old_value = result.items[target_idx];

            const merged = try deepMergeImpl(
                allocator,
                old_value,
                source_item,
                .{ .strategy = .smart },
                &visited,
            );

            // Replace with merged value
            result.items[target_idx] = merged;

            // Free the old value after replacement
            utils.freeJsonValue(allocator, old_value);
        } else {
            // Add new item
            try seen.put(key_value, result.items.len);
            try result.append(allocator, try utils.cloneJsonValue(allocator, source_item));
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn isObjectArray(arr: []std.json.Value) bool {
    if (arr.len == 0) return false;
    for (arr) |item| {
        if (item != .object) return false;
    }
    return true;
}

fn findMergeKey(obj: std.json.ObjectMap) ?[]const u8 {
    const merge_keys = [_][]const u8{ "id", "name", "key", "path", "type" };
    for (merge_keys) |key| {
        if (obj.get(key)) |value| {
            if (value == .string) {
                return key;
            }
        }
    }
    return null;
}

fn valuesEqual(a: std.json.Value, b: std.json.Value) !bool {
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
        .array => false, // Arrays not compared for dedup
        .object => false, // Objects not compared for dedup
    };
}

test "deepMerge merges simple objects" {
    const allocator = std.testing.allocator;

    var target_obj = std.json.ObjectMap.init(allocator);
    defer target_obj.deinit();
    try target_obj.put("a", .{ .integer = 1 });
    try target_obj.put("b", .{ .integer = 2 });

    var source_obj = std.json.ObjectMap.init(allocator);
    defer source_obj.deinit();
    try source_obj.put("b", .{ .integer = 3 });
    try source_obj.put("c", .{ .integer = 4 });

    const target = std.json.Value{ .object = target_obj };
    const source = std.json.Value{ .object = source_obj };

    const result = try deepMerge(allocator, target, source, .{});
    defer {
        // Use freeJsonValue to properly free all nested allocations
        utils.freeJsonValue(allocator, result);
    }

    try std.testing.expectEqual(@as(i64, 1), result.object.get("a").?.integer);
    try std.testing.expectEqual(@as(i64, 3), result.object.get("b").?.integer);
    try std.testing.expectEqual(@as(i64, 4), result.object.get("c").?.integer);
}

test "deepMerge replace strategy replaces arrays" {
    const allocator = std.testing.allocator;

    const target_items = try allocator.alloc(std.json.Value, 2);
    target_items[0] = .{ .integer = 1 };
    target_items[1] = .{ .integer = 2 };
    const target = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, target_items) };
    defer target.array.deinit();

    const source_items = try allocator.alloc(std.json.Value, 2);
    source_items[0] = .{ .integer = 3 };
    source_items[1] = .{ .integer = 4 };
    const source = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, source_items) };
    defer source.array.deinit();

    const result = try deepMerge(allocator, target, source, .{ .strategy = .replace });
    defer allocator.free(result.array.items);

    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);
    try std.testing.expectEqual(@as(i64, 3), result.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 4), result.array.items[1].integer);
}

test "deepMerge handles nested objects correctly" {
    const allocator = std.testing.allocator;

    // Create nested target object
    var target_inner = std.json.ObjectMap.init(allocator);
    defer target_inner.deinit();
    try target_inner.put("value", .{ .integer = 1 });

    var target_obj = std.json.ObjectMap.init(allocator);
    defer target_obj.deinit();
    try target_obj.put("inner", .{ .object = target_inner });

    const target = std.json.Value{ .object = target_obj };

    // Create nested source object
    var source_inner = std.json.ObjectMap.init(allocator);
    defer source_inner.deinit();
    try source_inner.put("value", .{ .integer = 2 });

    var source_obj = std.json.ObjectMap.init(allocator);
    defer source_obj.deinit();
    try source_obj.put("inner", .{ .object = source_inner });

    const source = std.json.Value{ .object = source_obj };

    // Merge should handle nested objects properly
    const result = try deepMerge(allocator, target, source, .{});
    defer {
        // Use freeJsonValue to properly free all nested allocations
        utils.freeJsonValue(allocator, result);
    }

    const inner_result = result.object.get("inner").?.object;
    try std.testing.expectEqual(@as(i64, 2), inner_result.get("value").?.integer);
}

test "deepMerge concat strategy deduplicates arrays" {
    const allocator = std.testing.allocator;

    const target_items = try allocator.alloc(std.json.Value, 2);
    target_items[0] = .{ .integer = 1 };
    target_items[1] = .{ .integer = 2 };
    const target = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, target_items) };
    defer target.array.deinit();

    const source_items = try allocator.alloc(std.json.Value, 3);
    source_items[0] = .{ .integer = 2 }; // Duplicate
    source_items[1] = .{ .integer = 3 };
    source_items[2] = .{ .integer = 4 };
    const source = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, source_items) };
    defer source.array.deinit();

    const result = try deepMerge(allocator, target, source, .{ .strategy = .concat });
    defer {
        for (result.array.items) |item| {
            if (item == .string) allocator.free(item.string);
        }
        allocator.free(result.array.items);
    }

    // Should have 4 items: 1, 2, 3, 4 (2 is deduplicated)
    try std.testing.expectEqual(@as(usize, 4), result.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), result.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), result.array.items[1].integer);
    try std.testing.expectEqual(@as(i64, 3), result.array.items[2].integer);
    try std.testing.expectEqual(@as(i64, 4), result.array.items[3].integer);
}

test "smartMerge handles empty arrays" {
    const allocator = std.testing.allocator;

    const target_items = try allocator.alloc(std.json.Value, 0);
    const target = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, target_items) };
    defer target.array.deinit();

    const source_items = try allocator.alloc(std.json.Value, 1);
    source_items[0] = .{ .integer = 1 };
    const source = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, source_items) };
    defer source.array.deinit();

    const result = try deepMerge(allocator, target, source, .{ .strategy = .smart });
    defer allocator.free(result.array.items);

    try std.testing.expectEqual(@as(usize, 1), result.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), result.array.items[0].integer);
}

test "smartMerge merges object arrays by id" {
    const allocator = std.testing.allocator;

    // Create target array with one object
    var target_obj1 = std.json.ObjectMap.init(allocator);
    defer target_obj1.deinit();
    try target_obj1.put("id", .{ .string = "1" });
    try target_obj1.put("value", .{ .integer = 100 });

    const target_items = try allocator.alloc(std.json.Value, 1);
    target_items[0] = .{ .object = target_obj1 };
    const target = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, target_items) };
    defer target.array.deinit();

    // Create source array with overlapping and new object
    var source_obj1 = std.json.ObjectMap.init(allocator);
    defer source_obj1.deinit();
    try source_obj1.put("id", .{ .string = "1" });
    try source_obj1.put("value", .{ .integer = 200 }); // Override

    var source_obj2 = std.json.ObjectMap.init(allocator);
    defer source_obj2.deinit();
    try source_obj2.put("id", .{ .string = "2" });
    try source_obj2.put("value", .{ .integer = 300 });

    const source_items = try allocator.alloc(std.json.Value, 2);
    source_items[0] = .{ .object = source_obj1 };
    source_items[1] = .{ .object = source_obj2 };
    const source = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, source_items) };
    defer source.array.deinit();

    const result = try deepMerge(allocator, target, source, .{ .strategy = .smart });
    defer {
        // Use freeJsonValue to properly free all nested allocations
        utils.freeJsonValue(allocator, result);
    }

    // Should have 2 items: merged first object and new second object
    try std.testing.expectEqual(@as(usize, 2), result.array.items.len);

    const first = result.array.items[0].object;
    try std.testing.expectEqualStrings("1", first.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 200), first.get("value").?.integer); // Merged value

    const second = result.array.items[1].object;
    try std.testing.expectEqualStrings("2", second.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 300), second.get("value").?.integer);
}

test "smartMerge falls back to concat for non-object arrays" {
    const allocator = std.testing.allocator;

    const target_items = try allocator.alloc(std.json.Value, 2);
    target_items[0] = .{ .integer = 1 };
    target_items[1] = .{ .integer = 2 };
    const target = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, target_items) };
    defer target.array.deinit();

    const source_items = try allocator.alloc(std.json.Value, 2);
    source_items[0] = .{ .integer = 3 };
    source_items[1] = .{ .integer = 4 };
    const source = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, source_items) };
    defer source.array.deinit();

    const result = try deepMerge(allocator, target, source, .{ .strategy = .smart });
    defer allocator.free(result.array.items);

    // Should concatenate like concat strategy
    try std.testing.expectEqual(@as(usize, 4), result.array.items.len);
}
