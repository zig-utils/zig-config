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
            const path = try std.fs.cwd().realpath(".", &cwd_buf);
            break :blk try self.allocator.dupe(u8, path);
        } else null;
        defer if (cwd_from_fs) |path| self.allocator.free(path);

        const cwd = options.cwd orelse cwd_from_fs.?;

        var final_config: ?std.json.Value = null;
        var primary_source: types.ConfigSource = .defaults;

        // Try loading from local file
        if (try self.loadFromFile(options.name, cwd)) |parsed| {
            // Clone the config so we can free the parsed result immediately
            final_config = try utils.cloneJsonValue(self.allocator, parsed.value);
            // parsed will be freed when it goes out of scope (errdefer would handle errors)
            var mutable_parsed = parsed;
            mutable_parsed.deinit();
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
                // Clone the config so we can free the parsed result immediately
                final_config = try utils.cloneJsonValue(self.allocator, parsed.value);
                var mutable_parsed = parsed;
                mutable_parsed.deinit();
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

        // Apply environment variables
        const env_prefix = options.env_prefix orelse options.name;
        const with_env = try self.env_processor.applyEnvVars(final_config.?, env_prefix);

        // Check if env vars made changes
        if (try self.configsAreDifferent(final_config.?, with_env)) {
            try sources.append(self.allocator, types.SourceInfo{
                .source = .env_vars,
                .path = null,
                .priority = 1,
            });
        }

        return types.UntypedConfigResult{
            .config = with_env,
            .source = primary_source,
            .sources = try sources.toOwnedSlice(self.allocator),
            .loaded_at = std.time.timestamp(),
            .allocator = self.allocator,
            // parsed_json is null - deinit will use manual freeing via freeJsonValue
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
