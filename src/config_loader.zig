const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const FileLoader = @import("services/file_loader.zig").FileLoader;
const EnvProcessor = @import("services/env_processor.zig").EnvProcessor;
const merge = @import("merge.zig");
const utils = @import("utils.zig");
const layers = @import("layers.zig");

// Zig 0.16+ IO helper
var io_instance: std.Io.Threaded = .init_single_threaded;
fn getIo() std.Io {
    return io_instance.io();
}

/// Get the absolute path of a file relative to a tmpDir (Zig 0.16 compat)
fn tmpDirRealPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8) ![]const u8 {
    // tmpDir is at .zig-cache/tmp/{sub_path} relative to cwd
    const c_realpath = std.c.realpath;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = if (sub_path.len == 0 or std.mem.eql(u8, sub_path, "."))
        std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch return error.InvalidPath
    else
        std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path }) catch return error.InvalidPath;

    // Null-terminate for C
    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(path_z[0..rel.len], rel);
    path_z[rel.len] = 0;

    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = c_realpath(&path_z, &resolved_buf) orelse return error.FileNotFound;
    const len = std.mem.len(resolved);
    return try allocator.dupe(u8, resolved[0..len]);
}

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
    ///
    /// Layers, lowest to highest: `options.defaults`, the config file (local,
    /// else home), environment variables for keys already present, then
    /// `options.overrides`.
    pub fn load(
        self: *ConfigLoader,
        options: types.LoadOptions,
    ) !types.UntypedConfigResult {
        var layered = try self.loadLayers(null, options);
        defer layered.deinit();

        const config = try utils.cloneJsonValue(self.allocator, layered.value);
        errdefer utils.freeJsonValue(self.allocator, config);

        return types.UntypedConfigResult{
            .config = config,
            .source = layered.primary_source,
            .sources = try layered.takeSources(),
            .loaded_at = getCurrentTimestamp(),
            .allocator = self.allocator,
            .parsed_json = null,
            .config_was_modified = layered.env_changed,
        };
    }

    /// The merged layers, in an arena, with where every key came from.
    const Layered = struct {
        arena: std.heap.ArenaAllocator,
        value: std.json.Value,
        provenance: layers.Provenance,
        sources: std.ArrayList(types.SourceInfo),
        primary_source: types.ConfigSource,
        env_changed: bool,
        env_prefix: []const u8,
        allocator: std.mem.Allocator,

        fn deinit(self: *Layered) void {
            for (self.sources.items) |*source| source.deinit(self.allocator);
            self.sources.deinit(self.allocator);
            self.arena.deinit();
        }

        fn takeSources(self: *Layered) ![]types.SourceInfo {
            return self.sources.toOwnedSlice(self.allocator);
        }
    };

    /// Build the layers. With a type, environment variables are derived from its
    /// fields and parsed as their types; without one, only keys already present
    /// are overlaid.
    fn loadLayers(self: *ConfigLoader, comptime T: ?type, options: types.LoadOptions) !Layered {
        var layered: Layered = .{
            .arena = .init(self.allocator),
            .value = .{ .object = .empty },
            .provenance = undefined,
            .sources = .empty,
            .primary_source = .defaults,
            .env_changed = false,
            .env_prefix = options.env_prefix orelse options.name,
            .allocator = self.allocator,
        };
        errdefer layered.deinit();
        const arena = layered.arena.allocator();
        layered.provenance = .init(arena);

        // Determine CWD - allocate if not provided
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = options.cwd orelse blk: {
            const result = std.c.getcwd(&cwd_buf, cwd_buf.len);
            if (result == null) return error.OutOfMemory;
            break :blk std.mem.sliceTo(&cwd_buf, 0);
        };

        // 1. Defaults.
        if (options.defaults) |defaults| {
            layered.value = try utils.cloneJsonValue(arena, defaults);
            try layered.provenance.mark("", layered.value, .{ .source = .defaults });
            try layered.sources.append(self.allocator, .{ .source = .defaults, .path = null, .priority = 0 });
        }

        // 2. The config file: local, else home. Merged over the defaults.
        const local = try self.findLocalFile(options.name, cwd);
        const found: ?struct { path: []const u8, source: types.ConfigSource, priority: u8 } =
            if (local) |path|
                .{ .path = path, .source = .file_local, .priority = 3 }
            else if (try self.findHomeFile(options.name)) |path|
                .{ .path = path, .source = .file_home, .priority = 2 }
            else
                null;
        if (found) |file| {
            defer self.allocator.free(file.path);
            var parsed = try self.file_loader.loadConfigFile(file.path);
            defer parsed.deinit();

            var file_value = parsed.value;
            if (options.nested_key) |nested_key| {
                file_value = extractNestedValue(file_value, nested_key) orelse .{ .object = .empty };
            }
            file_value = try utils.cloneJsonValue(arena, file_value);
            const file_path = try arena.dupe(u8, file.path);

            layered.value = try merge.deepMerge(arena, layered.value, file_value, .{ .strategy = options.merge_strategy });
            try layered.provenance.mark("", file_value, .{ .source = file.source, .detail = file_path });
            layered.primary_source = file.source;
            try layered.sources.append(self.allocator, .{
                .source = file.source,
                .path = try self.allocator.dupe(u8, file.path),
                .priority = file.priority,
            });
        }

        // 3. Environment variables.
        layered.env_changed = if (T) |Config|
            try layers.overlayEnvTyped(Config, arena, &layered.value, layered.env_prefix, &layered.provenance)
        else
            try layers.overlayEnvKeys(arena, &layered.value, layered.env_prefix, "", &layered.provenance);
        if (layered.env_changed) {
            try layered.sources.append(self.allocator, .{ .source = .env_vars, .path = null, .priority = 1 });
        }

        // 4. Explicit overrides.
        if (options.overrides) |overrides| {
            const value = try utils.cloneJsonValue(arena, overrides);
            layered.value = try merge.deepMerge(arena, layered.value, value, .{ .strategy = .replace });
            try layered.provenance.mark("", value, .{ .source = .overrides });
            try layered.sources.append(self.allocator, .{ .source = .overrides, .path = null, .priority = 4 });
        }

        return layered;
    }

    fn findLocalFile(self: *ConfigLoader, name: []const u8, cwd: []const u8) !?[]const u8 {
        return self.file_loader.findConfigFile(name, cwd);
    }

    fn findHomeFile(self: *ConfigLoader, name: []const u8) !?[]const u8 {
        // Get HOME directory (cross-platform: HOME on Unix, USERPROFILE on Windows)
        const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
        const home = utils.getEnvVar(self.allocator, home_var) orelse return null;
        defer self.allocator.free(home);

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const config_dir = try std.fmt.bufPrint(&buf, "{s}/.config", .{home});
        return self.file_loader.findConfigFile(name, config_dir);
    }
};

/// Get current timestamp in seconds (Zig 0.16+ compatible, cross-platform)
fn getCurrentTimestamp() i64 {
    if (comptime @import("builtin").os.tag == .windows) {
        const FILETIME = extern struct { dwLowDateTime: u32, dwHighDateTime: u32 };
        const GetSystemTimeAsFileTime = @extern(*const fn (*FILETIME) callconv(.winapi) void, .{ .name = "GetSystemTimeAsFileTime" });
        var ft: FILETIME = undefined;
        GetSystemTimeAsFileTime(&ft);
        const ticks: u64 = @as(u64, ft.dwHighDateTime) << 32 | ft.dwLowDateTime;
        const unix_ticks: i64 = @as(i64, @bitCast(ticks)) - 116444736000000000;
        return @divFloor(unix_ticks, 10000000);
    }
    var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec);
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
///
/// Layers, lowest to highest: `T`'s own field defaults, `options.defaults`, the
/// config file, environment variables (`PREFIX_FIELD`, `PREFIX_PARENT_FIELD`,
/// derived from `T` and parsed as each field's type), then `options.overrides`.
/// A wrong type, an unknown key or a missing required key fails with
/// `error.ConfigSchemaViolation` / `error.ConfigValidationFailed`, and
/// `options.diagnostic` names the key and the source that set it.
pub fn loadConfig(
    comptime T: type,
    allocator: std.mem.Allocator,
    options: types.LoadOptions,
) !types.ConfigResult(T) {
    var loader = try ConfigLoader.init(allocator);
    var layered = try loader.loadLayers(T, options);
    defer layered.deinit();

    try layers.check(T, layered.arena.allocator(), layered.value, &layered.provenance, options.diagnostic, layered.env_prefix);

    var parsed = std.json.parseFromValue(T, allocator, layered.value, .{
        .allocate = .alloc_always,
    }) catch |err| {
        // `check` mirrors what std.json accepts; this is for shapes it leaves
        // to std.json (unions and the like).
        if (options.diagnostic) |d| d.* = layers.Diagnostic.fromError(err);
        return errors.ZigConfigError.ConfigSchemaViolation;
    };
    errdefer parsed.deinit();

    return types.ConfigResult(T){
        .value = parsed.value,
        .source = layered.primary_source,
        .sources = try layered.takeSources(),
        .loaded_at = getCurrentTimestamp(),
        .allocator = allocator,
        .parsed_data = parsed,
    };
}

pub const DecodeOptions = struct {
    /// Source name used in schema diagnostics.
    path: []const u8 = "",
    env_prefix: []const u8,
    environ: ?*const std.process.Environ.Map = null,
    diagnostic: ?*layers.Diagnostic = null,
    /// Collect dotted paths of unknown keys (or subtrees) instead of failing.
    ignored_keys: ?*std.ArrayList([]const u8) = null,
};

/// Decode caller-supplied JSON and overlay typed values from a caller-supplied
/// environment. Returned data and ignored key paths live in the caller's arena.
pub fn decodeJson(
    comptime T: type,
    arena: std.mem.Allocator,
    json: []const u8,
    options: DecodeOptions,
) !T {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{ .allocate = .alloc_always });
    var provenance: layers.Provenance = .init(arena);
    try provenance.mark("", .null, .{ .source = .file_local, .detail = options.path });
    if (value == .object) if (options.environ) |env| {
        _ = try layers.overlayEnvTypedFromMap(T, arena, &value, options.env_prefix, env, &provenance);
    };
    try layers.checkWithIgnored(T, arena, value, &provenance, options.diagnostic, options.env_prefix, options.ignored_keys);
    return std.json.parseFromValueLeaky(T, arena, value, .{ .ignore_unknown_fields = options.ignored_keys != null });
}

test "decode explicit JSON with typed environment and ignored paths" {
    const Config = struct {
        server: struct { count: u32 = 1, name: []const u8 = "" } = .{},
        cap: u64 = 0,
    };
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("APP_SERVER_COUNT", "4");
    try env.put("APP_CAP", "18446744073709551615");
    var ignored: std.ArrayList([]const u8) = .empty;
    var diagnostic: layers.Diagnostic = .{};
    const options: DecodeOptions = .{
        .path = "settings.json",
        .env_prefix = "APP",
        .environ = &env,
        .diagnostic = &diagnostic,
        .ignored_keys = &ignored,
    };
    const value = try decodeJson(Config, arena,
        \\{"server":{"count":2,"name":"test","obsolete":true},"unused":{"nested":1}}
    , options);
    try std.testing.expectEqual(4, value.server.count);
    try std.testing.expectEqualStrings("test", value.server.name);
    try std.testing.expectEqual(std.math.maxInt(u64), value.cap);
    try std.testing.expectEqual(2, ignored.items.len);
    try std.testing.expectEqualStrings("unused", ignored.items[0]);
    try std.testing.expectEqualStrings("server.obsolete", ignored.items[1]);
    try std.testing.expectError(error.ConfigSchemaViolation, decodeJson(Config, arena, "[]", options));
    try std.testing.expectEqualStrings("settings.json", diagnostic.origin());
    try std.testing.expectError(error.ConfigSchemaViolation, decodeJson(Config, arena,
        \\{"cap":18446744073709551616.0}
    , .{ .env_prefix = "APP" }));
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

    const cwd = try tmpDirRealPath(allocator, &tmp, ".");
    defer allocator.free(cwd);

    // Create defaults
    var defaults_obj: std.json.ObjectMap = .empty;
    defer defaults_obj.deinit(allocator);
    try defaults_obj.put(allocator, "key", .{ .string = "value" });
    try defaults_obj.put(allocator, "port", .{ .integer = 3000 });

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

    const file = try tmp.dir.createFile(getIo(), "test.json", .{});
    defer file.close(getIo());
    try file.writePositionalAll(getIo(), "{\"loaded\": true, \"count\": 42}", 0);

    const cwd = try tmpDirRealPath(allocator, &tmp, ".");
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
    const file = try tmp.dir.createFile(getIo(), "package.json", .{});
    defer file.close(getIo());
    try file.writePositionalAll(getIo(),
        \\{
        \\  "name": "my-project",
        \\  "version": "1.0.0",
        \\  "den": {
        \\    "verbose": true,
        \\    "port": 3000
        \\  }
        \\}
    , 0);

    const cwd = try tmpDirRealPath(allocator, &tmp, ".");
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

    const file = try tmp.dir.createFile(getIo(), "config.json", .{});
    defer file.close(getIo());
    try file.writePositionalAll(getIo(),
        \\{
        \\  "tooling": {
        \\    "shell": {
        \\      "shell": "zsh",
        \\      "timeout": 60
        \\    }
        \\  }
        \\}
    , 0);

    const cwd = try tmpDirRealPath(allocator, &tmp, ".");
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
    const allocator = std.testing.allocator;
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "foo", .{ .integer = 1 });

    const value = extractNestedValue(.{ .object = obj }, "bar");
    try std.testing.expect(value == null);
}

test "extractNestedValue handles single key" {
    const allocator = std.testing.allocator;
    var inner: std.json.ObjectMap = .empty;
    defer inner.deinit(allocator);
    try inner.put(allocator, "value", .{ .integer = 42 });

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "den", .{ .object = inner });

    const result = extractNestedValue(.{ .object = obj }, "den");
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .object);
}

// ---- layering tests -----------------------------------------------------

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const ZavdConfig = struct {
    name: []const u8 = "zavd",
    db: struct {
        path: []const u8 = "/var/lib/zavd/sigs.db",
        reload_seconds: u32 = 300,
    } = .{},
    scan: struct {
        max_size: u64 = 1024,
        exclude: []const []const u8 = &.{},
        mode: enum { fast, thorough } = .fast,
    } = .{},
};

/// A tmp dir holding `zavd.json` with `content`, and its absolute path.
const ConfigDir = struct {
    tmp: std.testing.TmpDir,
    cwd: []const u8,
    file: []const u8,

    fn init(content: ?[]const u8) !ConfigDir {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        if (content) |c| {
            const f = try tmp.dir.createFile(getIo(), "zavd.json", .{});
            defer f.close(getIo());
            try f.writePositionalAll(getIo(), c, 0);
        }
        const cwd = try tmpDirRealPath(allocator, &tmp, ".");
        errdefer allocator.free(cwd);
        return .{ .tmp = tmp, .cwd = cwd, .file = try std.fmt.allocPrint(allocator, "{s}/zavd.json", .{cwd}) };
    }

    fn deinit(self: *ConfigDir) void {
        std.testing.allocator.free(self.cwd);
        std.testing.allocator.free(self.file);
        self.tmp.cleanup();
    }
};

fn setEnv(comptime name: [:0]const u8, value: [:0]const u8) void {
    _ = setenv(name, value, 1);
}

fn clearEnv(comptime name: [:0]const u8) void {
    _ = unsetenv(name);
}

fn parseJsonLeaky(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "precedence 1: struct defaults, then LoadOptions.defaults" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var dir: ConfigDir = try .init(null);
    defer dir.deinit();

    var result = try loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = dir.cwd,
        .env_prefix = "ZT1",
        .defaults = try parseJsonLeaky(arena_state.allocator(), "{\"db\": {\"reload_seconds\": 60}}"),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.ConfigSource.defaults, result.source);
    try std.testing.expectEqual(@as(u32, 60), result.value.db.reload_seconds);
    try std.testing.expectEqualStrings("/var/lib/zavd/sigs.db", result.value.db.path);
}

test "precedence 2: the file is merged over defaults, key by key" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var dir: ConfigDir = try .init("{\"db\": {\"path\": \"/etc/zavd/sigs.db\"}}");
    defer dir.deinit();

    var result = try loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = dir.cwd,
        .env_prefix = "ZT2",
        .defaults = try parseJsonLeaky(arena_state.allocator(), "{\"db\": {\"path\": \"/d\", \"reload_seconds\": 60}}"),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.ConfigSource.file_local, result.source);
    try std.testing.expectEqualStrings("/etc/zavd/sigs.db", result.value.db.path);
    // A sibling only the defaults set survives: the file used to replace them wholesale.
    try std.testing.expectEqual(@as(u32, 60), result.value.db.reload_seconds);
    try std.testing.expectEqualStrings(dir.file, result.sources[1].path.?);
}

test "precedence 3: an environment variable beats the file for a nested field" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var dir: ConfigDir = try .init("{\"name\": \"from-file\", \"scan\": {\"max_size\": 100}}");
    defer dir.deinit();

    setEnv("ZT3_SCAN_MAX_SIZE", "500");
    defer clearEnv("ZT3_SCAN_MAX_SIZE");
    // Keys the file never mentions are reachable too, typed by the field.
    setEnv("ZT3_DB_PATH", "/env/sigs.db");
    defer clearEnv("ZT3_DB_PATH");
    setEnv("ZT3_SCAN_EXCLUDE", "/proc,/sys");
    defer clearEnv("ZT3_SCAN_EXCLUDE");
    // A numeric-looking value for a string field stays a string.
    setEnv("ZT3_NAME", "123");
    defer clearEnv("ZT3_NAME");

    var result = try loadConfig(ZavdConfig, std.testing.allocator, .{ .name = "zavd", .cwd = dir.cwd, .env_prefix = "ZT3" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 500), result.value.scan.max_size);
    try std.testing.expectEqualStrings("/env/sigs.db", result.value.db.path);
    try std.testing.expectEqual(@as(usize, 2), result.value.scan.exclude.len);
    try std.testing.expectEqualStrings("/sys", result.value.scan.exclude[1]);
    try std.testing.expectEqualStrings("123", result.value.name);
    try std.testing.expectEqual(types.ConfigSource.env_vars, result.sources[result.sources.len - 1].source);
}

test "precedence 4: explicit overrides beat the environment" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var dir: ConfigDir = try .init("{\"scan\": {\"max_size\": 100, \"exclude\": [\"/a\", \"/b\"]}}");
    defer dir.deinit();
    setEnv("ZT4_SCAN_MAX_SIZE", "500");
    defer clearEnv("ZT4_SCAN_MAX_SIZE");

    var result = try loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = dir.cwd,
        .env_prefix = "ZT4",
        .overrides = try parseJsonLeaky(arena_state.allocator(), "{\"scan\": {\"max_size\": 7, \"exclude\": [\"/c\"]}}"),
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), result.value.scan.max_size);
    // Overrides replace arrays rather than merging them.
    try std.testing.expectEqual(@as(usize, 1), result.value.scan.exclude.len);
    const order = [_]types.ConfigSource{ .file_local, .env_vars, .overrides };
    for (order, result.sources) |want, got| try std.testing.expectEqual(want, got.source);
}

test "a wrong type in the file names the key and the file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var dir: ConfigDir = try .init("{\"scan\": {\"max_size\": \"big\"}}");
    defer dir.deinit();
    var diag: layers.Diagnostic = .{};
    try std.testing.expectError(error.ConfigSchemaViolation, loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = dir.cwd,
        .env_prefix = "ZT5",
        .diagnostic = &diag,
    }));
    try std.testing.expectEqualStrings("scan.max_size", diag.key());
    try std.testing.expectEqual(types.ConfigSource.file_local, diag.source.?);
    try std.testing.expectEqualStrings(dir.file, diag.origin());
    const want = try std.fmt.allocPrint(std.testing.allocator, "scan.max_size: expected integer from 0 to 18446744073709551615, found string \"big\" (from file {s})", .{dir.file});
    defer std.testing.allocator.free(want);
    try std.testing.expectEqualStrings(want, diag.message());
}

test "a wrong type from the environment names the key and the variable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var dir: ConfigDir = try .init("{\"scan\": {\"max_size\": 100}}");
    defer dir.deinit();
    setEnv("ZT6_SCAN_MODE", "paranoid");
    defer clearEnv("ZT6_SCAN_MODE");
    var diag: layers.Diagnostic = .{};
    try std.testing.expectError(error.ConfigSchemaViolation, loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = dir.cwd,
        .env_prefix = "ZT6",
        .diagnostic = &diag,
    }));
    try std.testing.expectEqualStrings("scan.mode", diag.key());
    try std.testing.expectEqual(types.ConfigSource.env_vars, diag.source.?);
    try std.testing.expectEqualStrings("ZT6_SCAN_MODE", diag.origin());
    try std.testing.expectEqualStrings(
        "scan.mode: expected one of \"fast\", \"thorough\", found string \"paranoid\" (from environment variable ZT6_SCAN_MODE)",
        diag.message(),
    );
}

test "wrong types from defaults and overrides, unknown keys and missing keys are reported" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir: ConfigDir = try .init("{\"scna\": {}}");
    defer dir.deinit();
    var empty_dir: ConfigDir = try .init(null);
    defer empty_dir.deinit();
    var diag: layers.Diagnostic = .{};

    try std.testing.expectError(error.ConfigSchemaViolation, loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = empty_dir.cwd,
        .env_prefix = "ZT7",
        .defaults = try parseJsonLeaky(arena, "{\"db\": {\"reload_seconds\": -1}}"),
        .diagnostic = &diag,
    }));
    try std.testing.expectEqualStrings("db.reload_seconds", diag.key());
    try std.testing.expectEqual(types.ConfigSource.defaults, diag.source.?);

    try std.testing.expectError(error.ConfigSchemaViolation, loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = empty_dir.cwd,
        .env_prefix = "ZT7",
        .overrides = try parseJsonLeaky(arena, "{\"scan\": {\"exclude\": [\"/a\", 3]}}"),
        .diagnostic = &diag,
    }));
    try std.testing.expectEqualStrings("scan.exclude[1]", diag.key());
    try std.testing.expectEqual(types.ConfigSource.overrides, diag.source.?);

    try std.testing.expectError(error.ConfigSchemaViolation, loadConfig(ZavdConfig, std.testing.allocator, .{
        .name = "zavd",
        .cwd = dir.cwd,
        .env_prefix = "ZT7",
        .diagnostic = &diag,
    }));
    try std.testing.expectEqualStrings("scna", diag.key());
    const unknown = try std.fmt.allocPrint(std.testing.allocator, "scna: unknown key (from file {s})", .{dir.file});
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqualStrings(unknown, diag.message());

    const Required = struct { token: []const u8 };
    try std.testing.expectError(error.ConfigValidationFailed, loadConfig(Required, std.testing.allocator, .{
        .name = "zavd",
        .cwd = empty_dir.cwd,
        .env_prefix = "ZT7",
        .diagnostic = &diag,
    }));
    try std.testing.expectEqualStrings(
        "token: missing; set it in defaults, the file, ZT7_TOKEN, or overrides",
        diag.message(),
    );
}

test "untyped loading merges the file over defaults too" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var dir: ConfigDir = try .init("{\"a\": 1}");
    defer dir.deinit();
    setEnv("ZT8_A", "2");
    defer clearEnv("ZT8_A");

    var result = try loadConfigUntyped(std.testing.allocator, .{
        .name = "zavd",
        .cwd = dir.cwd,
        .env_prefix = "ZT8",
        .defaults = try parseJsonLeaky(arena_state.allocator(), "{\"a\": 0, \"b\": true}"),
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 2), result.config.object.get("a").?.integer);
    try std.testing.expectEqual(true, result.config.object.get("b").?.bool);
    try std.testing.expect(result.config_was_modified);
}
