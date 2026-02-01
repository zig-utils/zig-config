const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const FileLoader = @import("services/file_loader.zig").FileLoader;
const EnvProcessor = @import("services/env_processor.zig").EnvProcessor;
const merge = @import("merge.zig");
const utils = @import("utils.zig");

/// Configuration loader orchestrator
pub const ConfigLoader = struct {
    file_loader: FileLoader,
    env_processor: EnvProcessor,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ConfigLoader {
        return ConfigLoader{
            .file_loader = FileLoader.init(allocator),
            .env_processor = EnvProcessor.init(allocator),
            .allocator = allocator,
        };
    }

    /// Load configuration with multi-source fallback (untyped)
    pub fn load(
        self: *ConfigLoader,
        options: types.LoadOptions,
    ) !types.UntypedConfigResult {
        var sources = try std.ArrayList(types.SourceInfo).initCapacity(self.allocator, 4);
        defer sources.deinit(self.allocator);

        // Determine CWD - allocate if not provided
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_from_fs = if (options.cwd == null) blk: {
            const path = blk2: {
                const result = std.c.getcwd(&cwd_buf, cwd_buf.len);
                if (result == null) return error.OutOfMemory;
                break :blk2 std.mem.sliceTo(&cwd_buf, 0);
            };
            break :blk try self.allocator.dupe(u8, path);
        } else null;
        defer if (cwd_from_fs) |path| self.allocator.free(path);

        const cwd = options.cwd orelse cwd_from_fs.?;

        var final_config: ?std.json.Value = null;
        var parsed_json: ?std.json.Parsed(std.json.Value) = null;
        var primary_source: types.ConfigSource = .defaults;

        // Try loading from local file
        if (try self.loadFromFile(options.name, cwd)) |parsed| {
            final_config = parsed.value;
            parsed_json = parsed;
            primary_source = .file_local;
            try sources.append(self.allocator, types.SourceInfo{
                .source = .file_local,
                .path = null,
                .priority = 3,
            });
        }

        // Try loading from home directory
        if (final_config == null) {
            if (try self.loadFromHome(options.name)) |parsed| {
                final_config = parsed.value;
                parsed_json = parsed;
                primary_source = .file_home;
                try sources.append(self.allocator, types.SourceInfo{
                    .source = .file_home,
                    .path = null,
                    .priority = 2,
                });
            }
        }

        // Apply defaults if no file found
        if (final_config == null and options.defaults != null) {
            final_config = try utils.cloneJsonValue(self.allocator, options.defaults.?);
            primary_source = .defaults;
            try sources.append(self.allocator, types.SourceInfo{
                .source = .defaults,
                .path = null,
                .priority = 0,
            });
        }

        // If still no config, create empty object
        if (final_config == null) {
            final_config = .{ .object = std.json.ObjectMap.init(self.allocator) };
        }

        // Extract nested key if specified
        var nested_cloned: ?std.json.Value = null;
        if (options.nested_key) |nested_key| {
            if (extractNestedValue(final_config.?, nested_key)) |nested_value| {
                // Clone the nested value since the original will be freed
                nested_cloned = try utils.cloneJsonValue(self.allocator, nested_value);
                final_config = nested_cloned;
            } else {
                // Nested key not found, use empty object
                final_config = .{ .object = std.json.ObjectMap.init(self.allocator) };
            }
        }

        // Apply environment variables
        const env_prefix = options.env_prefix orelse options.name;
        const with_env = try self.env_processor.applyEnvVars(final_config.?, env_prefix);

        // Check if env vars made changes
        const config_was_modified = try self.configsAreDifferent(final_config.?, with_env);
        if (config_was_modified) {
            try sources.append(self.allocator, types.SourceInfo{
                .source = .env_vars,
                .path = null,
                .priority = 1,
            });
        }

        // Free the original config if it was from defaults or empty object
        // (arena-allocated configs from parsed_json will be freed separately)
        if (parsed_json == null) {
            utils.freeJsonValue(self.allocator, final_config.?);
        }

        // Free the cloned nested value if we created one
        if (nested_cloned) |cloned| {
            utils.freeJsonValue(self.allocator, cloned);
        }

        return types.UntypedConfigResult{
            .config = with_env,
            .source = primary_source,
            .sources = try sources.toOwnedSlice(self.allocator),
            .loaded_at = getCurrentTimestamp(),
            .allocator = self.allocator,
            .parsed_json = parsed_json,
            .config_was_modified = config_was_modified,
        };
    }

    fn loadFromFile(self: *ConfigLoader, name: []const u8, cwd: []const u8) !?std.json.Parsed(std.json.Value) {
        const path = try self.file_loader.findConfigFile(name, cwd) orelse return null;
        defer self.allocator.free(path);

        return try self.file_loader.loadConfigFile(path);
    }

    fn loadFromHome(self: *ConfigLoader, name: []const u8) !?std.json.Parsed(std.json.Value) {
        // Get HOME directory (cross-platform: HOME on Unix, USERPROFILE on Windows)
        const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
        const home = utils.getEnvVar(self.allocator, home_var) orelse return null;
        defer self.allocator.free(home);

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_dir = try std.fmt.bufPrint(&buf, "{s}/.config", .{home});

        const path = try self.file_loader.findConfigFile(name, config_dir) orelse return null;
        defer self.allocator.free(path);

        return try self.file_loader.loadConfigFile(path);
    }

    fn configsAreDifferent(self: *ConfigLoader, a: std.json.Value, b: std.json.Value) !bool {
        _ = self;
        // Use deep equality comparison from utils
        return !utils.jsonValuesEqual(a, b);
    }
};

/// Get current timestamp in seconds (Zig 0.16+ compatible)
fn getCurrentTimestamp() i64 {
    // Use POSIX clock_gettime for real-time timestamp
    const ts = std.posix.clock_gettime(.REALTIME) catch {
        return 0;
    };
    return ts.sec;
}

/// Extract a nested value from a JSON object using dot notation
/// e.g., "den" extracts {"den": {...}} -> {...}
/// e.g., "tooling.shell" extracts {"tooling": {"shell": {...}}} -> {...}
fn extractNestedValue(value: std.json.Value, path: []const u8) ?std.json.Value {
    if (value != .object) return null;

    var current = value;
    var iter = std.mem.splitScalar(u8, path, '.');

    while (iter.next()) |key| {
        if (current != .object) return null;
        current = current.object.get(key) orelse return null;
    }

    return current;
}

/// Primary typed configuration loading function
pub fn loadConfig(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) !types.ConfigResult(T) {
    // First load as untyped JSON
    var untyped = try loadConfigUntyped(allocator, options);
    errdefer untyped.deinit();

    // Parse into the target type
    var parsed = try std.json.parseFromValue(T, allocator, untyped.config, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    // Transfer ownership of sources to typed result
    const result = types.ConfigResult(T){
        .value = parsed.value,
        .source = untyped.source,
        .sources = untyped.sources,
        .loaded_at = untyped.loaded_at,
        .allocator = untyped.allocator,
        .parsed_data = parsed,
    };

    // Clean up untyped config (but preserve sources)
    untyped.sources = &.{}; // Transfer ownership
    untyped.deinit();

    return result;
}

/// Load untyped configuration (internal use)
pub fn loadConfigUntyped(
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) !types.UntypedConfigResult {
    var loader = try ConfigLoader.init(allocator);
    return try loader.load(options);
}

/// Try loading config, return null on error
pub fn tryLoadConfig(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) ?types.ConfigResult(T) {
    return loadConfig(T, allocator, options) catch null;
}

test "loadConfig returns typed defaults when no file found" {
    const allocator = std.testing.allocator;

    const TestConfig = struct {
        key: []const u8,
        port: u16 = 8080,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    // Create defaults
    var defaults_obj = std.json.ObjectMap.init(allocator);
    defer defaults_obj.deinit();
    try defaults_obj.put("key", .{ .string = "value" });
    try defaults_obj.put("port", .{ .integer = 3000 });

    var result = try loadConfig(TestConfig, allocator, .{
        .name = "nonexistent",
        .cwd = cwd,
        .defaults = .{ .object = defaults_obj },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(types.ConfigSource.defaults, result.source);
    try std.testing.expectEqualStrings("value", result.value.key);
    try std.testing.expectEqual(@as(u16, 3000), result.value.port);
}

test "loadConfig loads typed config from file" {
    const allocator = std.testing.allocator;

    const TestConfig = struct {
        loaded: bool,
        count: ?i32 = null,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("test.json", .{});
    defer file.close();
    try file.writeAll("{\"loaded\": true, \"count\": 42}");

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var result = try loadConfig(TestConfig, allocator, .{
        .name = "test",
        .cwd = cwd,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(types.ConfigSource.file_local, result.source);
    try std.testing.expectEqual(true, result.value.loaded);
    try std.testing.expectEqual(@as(i32, 42), result.value.count.?);
}

test "loadConfig extracts nested key from package.json" {
    const allocator = std.testing.allocator;

    const DenConfig = struct {
        verbose: bool = false,
        port: u16 = 8080,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a package.json with a "den" section
    const file = try tmp.dir.createFile("package.json", .{});
    defer file.close();
    try file.writeAll(
        \\{
        \\  "name": "my-project",
        \\  "version": "1.0.0",
        \\  "den": {
        \\    "verbose": true,
        \\    "port": 3000
        \\  }
        \\}
    );

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var result = try loadConfig(DenConfig, allocator, .{
        .name = "package",
        .cwd = cwd,
        .nested_key = "den",
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(true, result.value.verbose);
    try std.testing.expectEqual(@as(u16, 3000), result.value.port);
}

test "loadConfig extracts deeply nested key" {
    const allocator = std.testing.allocator;

    const ShellConfig = struct {
        shell: []const u8 = "bash",
        timeout: u32 = 30,
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("config.json", .{});
    defer file.close();
    try file.writeAll(
        \\{
        \\  "tooling": {
        \\    "shell": {
        \\      "shell": "zsh",
        \\      "timeout": 60
        \\    }
        \\  }
        \\}
    );

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var result = try loadConfig(ShellConfig, allocator, .{
        .name = "config",
        .cwd = cwd,
        .nested_key = "tooling.shell",
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("zsh", result.value.shell);
    try std.testing.expectEqual(@as(u32, 60), result.value.timeout);
}

test "extractNestedValue returns null for missing key" {
    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("foo", .{ .integer = 1 });

    const value = extractNestedValue(.{ .object = obj }, "bar");
    try std.testing.expect(value == null);
}

test "extractNestedValue handles single key" {
    var inner = std.json.ObjectMap.init(std.testing.allocator);
    defer inner.deinit();
    try inner.put("value", .{ .integer = 42 });

    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try obj.put("den", .{ .object = inner });

    const result = extractNestedValue(.{ .object = obj }, "den");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .object);
}
