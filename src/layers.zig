//! Layering support for `loadConfig`: where each value came from, the
//! environment overlay, and type checking that names the key and its source.
//!
//! Precedence, lowest to highest: defaults, file, environment, overrides.

const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const utils = @import("utils.zig");
const EnvProcessor = @import("services/env_processor.zig").EnvProcessor;

const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// A struct field, read the same way on Zig 0.16 (`fields`) and 0.17
/// (`field_names` / `field_types` / `field_attrs`).
const Field = struct { name: [:0]const u8, type: type, has_default: bool };

fn structFields(comptime T: type) []const Field {
    comptime {
        const info = @typeInfo(T).@"struct";
        if (@hasField(@TypeOf(info), "field_names")) {
            var out: [info.field_names.len]Field = undefined;
            for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FieldType, attrs, i| {
                out[i] = .{ .name = name, .type = FieldType, .has_default = attrs.default_value_ptr != null };
            }
            const final = out;
            return &final;
        } else {
            var out: [info.fields.len]Field = undefined;
            for (info.fields, 0..) |f, i| {
                out[i] = .{ .name = f.name, .type = f.type, .has_default = f.default_value_ptr != null };
            }
            const final = out;
            return &final;
        }
    }
}

/// Where a value came from.
pub const Origin = struct {
    source: types.ConfigSource,
    /// File path or environment variable name; empty for defaults and overrides.
    detail: []const u8 = "",
};

/// Dotted key path (`scan.max_size`, `paths[2]`) to the layer that last set it.
pub const Provenance = struct {
    map: std.StringHashMapUnmanaged(Origin) = .empty,
    arena: Allocator,

    pub fn init(arena: Allocator) Provenance {
        return .{ .arena = arena };
    }

    /// Record `origin` for `path` and every key below it in `value`.
    pub fn mark(self: *Provenance, path: []const u8, value: Value, origin: Origin) !void {
        try self.map.put(self.arena, try self.arena.dupe(u8, path), origin);
        if (value != .object) return;
        var it = value.object.iterator();
        while (it.next()) |entry| {
            const child = try joinKey(self.arena, path, entry.key_ptr.*);
            try self.mark(child, entry.value_ptr.*, origin);
        }
    }

    /// The origin of `path`, or of its nearest recorded ancestor.
    pub fn lookup(self: *const Provenance, path: []const u8) ?Origin {
        var p = path;
        while (true) {
            if (self.map.get(p)) |origin| return origin;
            if (p.len == 0) return null;
            p = parentKey(p);
        }
    }
};

fn joinKey(arena: Allocator, parent: []const u8, key: []const u8) ![]const u8 {
    if (parent.len == 0) return arena.dupe(u8, key);
    return std.fmt.allocPrint(arena, "{s}.{s}", .{ parent, key });
}

fn parentKey(path: []const u8) []const u8 {
    if (path.len > 0 and path[path.len - 1] == ']') {
        if (std.mem.lastIndexOfScalar(u8, path, '[')) |i| return path[0..i];
    }
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "";
    return path[0..dot];
}

/// Set `value` at `path` (dotted keys) inside the object `root`, creating
/// intermediate objects and replacing non-objects in the way.
fn setPath(arena: Allocator, root: *Value, keys: []const []const u8, value: Value) !void {
    var current = root;
    for (keys, 0..) |key, i| {
        if (current.* != .object) current.* = .{ .object = .empty };
        if (i == keys.len - 1) {
            try current.object.put(arena, key, value);
            return;
        }
        const entry = try current.object.getOrPut(arena, key);
        if (!entry.found_existing or entry.value_ptr.* != .object) {
            entry.value_ptr.* = .{ .object = .empty };
        }
        current = entry.value_ptr;
    }
}

fn envName(arena: Allocator, prefix: []const u8, keys: []const []const u8) ![]const u8 {
    var processor = EnvProcessor.init(arena);
    return processor.generateEnvName(prefix, keys);
}

/// Overlay environment variables for every field of `T` (recursing into
/// struct fields): `PREFIX_FIELD`, `PREFIX_PARENT_FIELD`, ... Values are parsed
/// as the field's type; a value that does not parse is kept as a string so
/// the type check reports it with the variable's name.
pub fn overlayEnvTyped(
    comptime T: type,
    arena: Allocator,
    root: *Value,
    prefix: []const u8,
    provenance: *Provenance,
) !bool {
    var keys: std.ArrayList([]const u8) = .empty;
    return overlayStruct(T, arena, root, prefix, &keys, provenance);
}

fn overlayStruct(
    comptime T: type,
    arena: Allocator,
    root: *Value,
    prefix: []const u8,
    keys: *std.ArrayList([]const u8),
    provenance: *Provenance,
) !bool {
    var changed = false;
    inline for (comptime structFields(T)) |field| {
        const name = field.name;
        const FieldType = field.type;
        try keys.append(arena, name);
        defer _ = keys.pop();

        const env = try envName(arena, prefix, keys.items);
        if (utils.getEnvVar(arena, env)) |raw| {
            const value = try parseEnvAs(FieldType, arena, raw);
            try setPath(arena, root, keys.items, value);
            const path = try std.mem.join(arena, ".", keys.items);
            try provenance.mark(path, value, .{ .source = .env_vars, .detail = env });
            changed = true;
        } else if (comptime structChild(FieldType)) |Child| {
            if (try overlayStruct(Child, arena, root, prefix, keys, provenance)) changed = true;
        }
    }
    return changed;
}

/// The struct type a field nests, if it is a struct (or optional struct) that
/// maps to a JSON object.
fn structChild(comptime T: type) ?type {
    const U = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (U == Value) return null;
    return if (@typeInfo(U) == .@"struct") U else null;
}

fn parseEnvAs(comptime T: type, arena: Allocator, raw: []const u8) !Value {
    if (T == Value) {
        var processor = EnvProcessor.init(arena);
        return processor.parseEnvValue(raw);
    }
    const string: Value = .{ .string = raw };
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (std.mem.eql(u8, raw, "null")) return .null;
            return parseEnvAs(o.child, arena, raw);
        },
        .bool => {
            const yes = [_][]const u8{ "true", "1", "yes", "on" };
            const no = [_][]const u8{ "false", "0", "no", "off" };
            for (yes) |w| if (std.ascii.eqlIgnoreCase(raw, w)) return .{ .bool = true };
            for (no) |w| if (std.ascii.eqlIgnoreCase(raw, w)) return .{ .bool = false };
            return string;
        },
        .int => return if (std.fmt.parseInt(i64, raw, 10)) |n| .{ .integer = n } else |_| string,
        .float => return if (std.fmt.parseFloat(f64, raw)) |f| .{ .float = f } else |_| string,
        .@"enum" => return string,
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return string;
            if (ptr.size == .slice) return parseEnvList(ptr.child, arena, raw);
            return string;
        },
        .array => |arr| return parseEnvList(arr.child, arena, raw),
        .@"struct" => {
            if (raw.len > 0 and raw[0] == '{') return parseJson(arena, raw) orelse string;
            return string;
        },
        else => return string,
    }
}

/// `[...]` as JSON, otherwise comma-separated items parsed as `Elem`.
fn parseEnvList(comptime Elem: type, arena: Allocator, raw: []const u8) !Value {
    if (raw.len > 0 and raw[0] == '[') {
        if (parseJson(arena, raw)) |v| return v;
        return .{ .string = raw };
    }
    var items: std.json.Array = .init(arena);
    if (std.mem.trim(u8, raw, " \t").len == 0) return .{ .array = items };
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |item| {
        try items.append(try parseEnvAs(Elem, arena, std.mem.trim(u8, item, " \t")));
    }
    return .{ .array = items };
}

fn parseJson(arena: Allocator, raw: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch null;
}

/// Overlay environment variables for keys already in `root` (untyped loading,
/// where there is no type to say which keys exist).
pub fn overlayEnvKeys(
    arena: Allocator,
    root: *Value,
    prefix: []const u8,
    path: []const u8,
    provenance: *Provenance,
) !bool {
    if (root.* != .object) return false;
    var changed = false;
    var processor = EnvProcessor.init(arena);
    var it = root.object.iterator();
    while (it.next()) |entry| {
        const env = try processor.generateEnvName(prefix, &.{entry.key_ptr.*});
        const child_path = try joinKey(arena, path, entry.key_ptr.*);
        if (utils.getEnvVar(arena, env)) |raw| {
            entry.value_ptr.* = try processor.parseEnvValue(raw);
            try provenance.mark(child_path, entry.value_ptr.*, .{ .source = .env_vars, .detail = env });
            changed = true;
        } else if (entry.value_ptr.* == .object) {
            if (try overlayEnvKeys(arena, entry.value_ptr, env, child_path, provenance)) changed = true;
        }
    }
    return changed;
}

/// Why a value was rejected, naming the key and the layer that set it.
pub const Diagnostic = struct {
    source: ?types.ConfigSource = null,
    key_buf: [256]u8 = undefined,
    key_len: usize = 0,
    origin_buf: [512]u8 = undefined,
    origin_len: usize = 0,
    message_buf: [1024]u8 = undefined,
    message_len: usize = 0,

    /// Dotted key path, e.g. `scan.max_size` or `paths[2]`; empty for the root.
    pub fn key(self: *const Diagnostic) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    /// File path or environment variable name that set the value, if any.
    pub fn origin(self: *const Diagnostic) []const u8 {
        return self.origin_buf[0..self.origin_len];
    }

    /// The whole report, e.g. `scan.max_size: expected integer, found string "big"
    /// (from environment variable ZAVD_SCAN_MAX_SIZE)`.
    pub fn message(self: *const Diagnostic) []const u8 {
        return self.message_buf[0..self.message_len];
    }

    /// A report for a failure that has no key to point at.
    pub fn fromError(err: anyerror) Diagnostic {
        var d: Diagnostic = .{};
        d.set("", null, "cannot read the configuration: {s}", .{@errorName(err)});
        return d;
    }

    fn set(self: *Diagnostic, path: []const u8, found: ?Origin, comptime fmt: []const u8, args: anytype) void {
        self.key_len = copyTruncated(&self.key_buf, path);
        self.source = if (found) |o| o.source else null;
        self.origin_len = copyTruncated(&self.origin_buf, if (found) |o| o.detail else "");

        var w: std.Io.Writer = .fixed(&self.message_buf);
        w.print("{s}: ", .{if (path.len == 0) "(root)" else path}) catch {};
        w.print(fmt, args) catch {};
        if (found) |o| switch (o.source) {
            .env_vars => w.print(" (from environment variable {s})", .{o.detail}) catch {},
            .file_local, .file_home, .typescript, .package_json => w.print(" (from file {s})", .{o.detail}) catch {},
            .defaults => w.writeAll(" (from defaults)") catch {},
            .overrides => w.writeAll(" (from overrides)") catch {},
        };
        self.message_len = w.end;
    }
};

fn copyTruncated(dest: []u8, src: []const u8) usize {
    const n = @min(dest.len, src.len);
    @memcpy(dest[0..n], src[0..n]);
    return n;
}

pub const CheckError = error{ ConfigSchemaViolation, ConfigValidationFailed } || Allocator.Error;

/// Check that `value` can become a `T`, the way `std.json.parseFromValue`
/// with default options will read it. On failure `diagnostic` (when given)
/// names the key, what was expected and found, and where the value came from.
pub fn check(
    comptime T: type,
    arena: Allocator,
    value: Value,
    provenance: *const Provenance,
    diagnostic: ?*Diagnostic,
    env_prefix: []const u8,
) CheckError!void {
    var ctx: CheckContext = .{
        .arena = arena,
        .provenance = provenance,
        .diagnostic = diagnostic,
        .env_prefix = env_prefix,
    };
    return ctx.checkValue(T, value, "");
}

const CheckContext = struct {
    arena: Allocator,
    provenance: *const Provenance,
    diagnostic: ?*Diagnostic,
    env_prefix: []const u8,

    fn mismatch(self: *CheckContext, path: []const u8, expected: []const u8, value: Value) CheckError {
        if (self.diagnostic) |d| {
            var found_buf: [96]u8 = undefined;
            d.set(path, self.provenance.lookup(path), "expected {s}, found {s}", .{ expected, describe(&found_buf, value) });
        }
        return error.ConfigSchemaViolation;
    }

    fn checkValue(self: *CheckContext, comptime T: type, value: Value, path: []const u8) CheckError!void {
        if (T == Value) return;
        switch (@typeInfo(T)) {
            .optional => |o| {
                if (value == .null) return;
                return self.checkValue(o.child, value, path);
            },
            .bool => if (value != .bool) return self.mismatch(path, "boolean", value),
            .int => {
                const ok = switch (value) {
                    .integer => |n| std.math.cast(T, n) != null,
                    .float => |f| @round(f) == f and
                        f >= @as(f64, @floatFromInt(std.math.minInt(T))) and
                        f <= @as(f64, @floatFromInt(std.math.maxInt(T))),
                    .number_string => |s| if (std.fmt.parseInt(T, s, 10)) |_| true else |_| false,
                    else => false,
                };
                if (!ok) {
                    const expected = comptime std.fmt.comptimePrint("integer from {d} to {d}", .{ std.math.minInt(T), std.math.maxInt(T) });
                    return self.mismatch(path, expected, value);
                }
            },
            .float => switch (value) {
                .float, .integer, .number_string => {},
                else => return self.mismatch(path, "number", value),
            },
            .@"enum" => {
                const ok = switch (value) {
                    .string => |s| std.meta.stringToEnum(T, s) != null,
                    .integer => |n| blk: {
                        inline for (comptime std.meta.tags(T)) |tag| {
                            if (@intFromEnum(tag) == n) break :blk true;
                        }
                        break :blk false;
                    },
                    else => false,
                };
                if (!ok) {
                    const expected = comptime blk: {
                        var list: []const u8 = "one of";
                        for (std.meta.fieldNames(T), 0..) |name, i| list = list ++ (if (i == 0) " " else ", ") ++ "\"" ++ name ++ "\"";
                        break :blk list;
                    };
                    return self.mismatch(path, expected, value);
                }
            },
            .pointer => |ptr| {
                if (ptr.size != .slice) return;
                if (ptr.child == u8) {
                    if (value != .string) return self.mismatch(path, "string", value);
                    return;
                }
                if (value != .array) return self.mismatch(path, "array", value);
                for (value.array.items, 0..) |item, i| {
                    const item_path = try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ path, i });
                    try self.checkValue(ptr.child, item, item_path);
                }
            },
            .array => |arr| {
                if (value != .array) return self.mismatch(path, "array", value);
                if (value.array.items.len != arr.len) {
                    const expected = comptime std.fmt.comptimePrint("array of {d} items", .{arr.len});
                    return self.mismatch(path, expected, value);
                }
                for (value.array.items, 0..) |item, i| {
                    const item_path = try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ path, i });
                    try self.checkValue(arr.child, item, item_path);
                }
            },
            .@"struct" => {
                const fields = comptime structFields(T);
                if (value != .object) return self.mismatch(path, "object", value);
                var it = value.object.iterator();
                outer: while (it.next()) |entry| {
                    inline for (fields) |field| {
                        if (std.mem.eql(u8, entry.key_ptr.*, field.name)) continue :outer;
                    }
                    const child = try joinKey(self.arena, path, entry.key_ptr.*);
                    if (self.diagnostic) |d| d.set(child, self.provenance.lookup(child), "unknown key", .{});
                    return error.ConfigSchemaViolation;
                }
                inline for (fields) |field| {
                    const child = try joinKey(self.arena, path, field.name);
                    if (value.object.get(field.name)) |field_value| {
                        try self.checkValue(field.type, field_value, child);
                    } else if (!field.has_default and @typeInfo(field.type) != .optional) {
                        if (self.diagnostic) |d| {
                            var keys: std.ArrayList([]const u8) = .empty;
                            var parts = std.mem.splitScalar(u8, child, '.');
                            while (parts.next()) |part| try keys.append(self.arena, part);
                            const env = try envName(self.arena, self.env_prefix, keys.items);
                            d.set(child, null, "missing; set it in defaults, the file, {s}, or overrides", .{env});
                        }
                        return error.ConfigValidationFailed;
                    }
                }
            },
            // Unions and other shapes: left to std.json.
            else => {},
        }
    }
};

fn describe(buf: []u8, value: Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => |b| if (b) "boolean true" else "boolean false",
        .integer => |n| std.fmt.bufPrint(buf, "integer {d}", .{n}) catch "integer",
        .float => |f| std.fmt.bufPrint(buf, "number {d}", .{f}) catch "number",
        .number_string => |s| std.fmt.bufPrint(buf, "number {s}", .{s}) catch "number",
        .string => |s| if (s.len <= 48)
            std.fmt.bufPrint(buf, "string \"{s}\"", .{s}) catch "string"
        else
            std.fmt.bufPrint(buf, "string \"{s}...\"", .{s[0..45]}) catch "string",
        .array => "array",
        .object => "object",
    };
}

test "Provenance falls back to the nearest ancestor" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var prov: Provenance = .init(arena_state.allocator());
    try prov.mark("scan", .{ .integer = 1 }, .{ .source = .file_local, .detail = "/etc/a.json" });
    try std.testing.expectEqualStrings("/etc/a.json", prov.lookup("scan.paths[3]").?.detail);
    try std.testing.expect(prov.lookup("other") == null);
}

test "parseEnvAs follows the field type" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("123", (try parseEnvAs([]const u8, a, "123")).string);
    try std.testing.expectEqual(@as(i64, 123), (try parseEnvAs(u32, a, "123")).integer);
    try std.testing.expectEqualStrings("big", (try parseEnvAs(u32, a, "big")).string);
    try std.testing.expectEqual(true, (try parseEnvAs(bool, a, "Yes")).bool);
    const list = try parseEnvAs([]const []const u8, a, "/proc, /sys");
    try std.testing.expectEqual(@as(usize, 2), list.array.items.len);
    try std.testing.expectEqualStrings("/sys", list.array.items[1].string);
    const nums = try parseEnvAs([]const u16, a, "[1,2,3]");
    try std.testing.expectEqual(@as(usize, 3), nums.array.items.len);
    try std.testing.expect((try parseEnvAs(?u8, a, "null")) == .null);
}
