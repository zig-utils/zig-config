const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const utils = @import("../utils.zig");

// Zig 0.16+ IO helper
var io_instance: std.Io.Threaded = .init_single_threaded;
fn getIo() std.Io {
    return io_instance.io();
}

/// Check if a file exists using cross-platform Io.Dir
fn fileExists(path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(getIo(), path, .{ .mode = .read_only }) catch return false;
    file.close(getIo());
    return true;
}

/// Strip single-line (//) and multi-line (/* */) comments from JSON content
fn stripJsonComments(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    try result.ensureTotalCapacity(allocator, content.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var in_string = false;
    var escape_next = false;

    while (i < content.len) : (i += 1) {
        const c = content[i];

        // Handle string literals (comments inside strings should not be stripped)
        if (c == '"' and !escape_next) {
            in_string = !in_string;
            try result.append(allocator, c);
            continue;
        }

        if (in_string) {
            try result.append(allocator, c);
            escape_next = (c == '\\' and !escape_next);
            continue;
        }

        escape_next = false;

        // Check for single-line comment
        if (c == '/' and i + 1 < content.len and content[i + 1] == '/') {
            // Skip until end of line
            i += 2;
            while (i < content.len and content[i] != '\n') : (i += 1) {}
            if (i < content.len) try result.append(allocator, '\n'); // Preserve newline
            continue;
        }

        // Check for multi-line comment
        if (c == '/' and i + 1 < content.len and content[i + 1] == '*') {
            // Skip until we find */
            i += 2;
            while (i + 1 < content.len) : (i += 1) {
                if (content[i] == '*' and content[i + 1] == '/') {
                    i += 1; // Skip the '/'
                    break;
                }
            }
            continue;
        }

        try result.append(allocator, c);
    }

    return result.toOwnedSlice(allocator);
}

/// File loader service for discovering and loading configuration files
pub const FileLoader = struct {
    allocator: std.mem.Allocator,

    const EXTENSIONS = [_][]const u8{ ".json", ".jsonc", ".zig", ".ts" };
    /// Also search for {name}.config.{ext} (bunfig convention)
    const CONFIG_EXTENSIONS = [_][]const u8{ ".config.json", ".config.jsonc", ".config.zig", ".config.ts" };
    const PROJECT_PATHS = [_][]const u8{ "", "config", ".config" };
    const COMMON_NAMES = [_][]const u8{ "package", "pantry" };

    pub fn init(allocator: std.mem.Allocator) FileLoader {
        return FileLoader{
            .allocator = allocator,
        };
    }

    /// Find config file in multiple locations with extension priority
    pub fn findConfigFile(
        self: *FileLoader,
        name: []const u8,
        cwd: []const u8,
    ) !?[]const u8 {
        // Search in project directories with the provided name
        // Try both {name}.{ext} and {name}.config.{ext} (bunfig convention)
        const all_extensions = EXTENSIONS ++ CONFIG_EXTENSIONS;
        for (PROJECT_PATHS) |dir| {
            for (all_extensions) |ext| {
                const path = if (dir.len == 0)
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ cwd, name, ext })
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}{s}", .{ cwd, dir, name, ext });
                defer self.allocator.free(path);

                if (fileExists(path)) {
                    return try self.allocator.dupe(u8, path);
                }
            }
        }

        // Also try common package file names (package.json, pantry.json, etc.)
        for (COMMON_NAMES) |common_name| {
            for (EXTENSIONS) |ext| {
                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ cwd, common_name, ext });
                defer self.allocator.free(path);

                if (fileExists(path)) {
                    return try self.allocator.dupe(u8, path);
                }
            }
        }

        // Search in home directory (cross-platform)
        const home_var = if (@import("builtin").os.tag == .windows) "USERPROFILE" else "HOME";
        const home = utils.getEnvVar(self.allocator, home_var) orelse return null;
        defer self.allocator.free(home);

        for (all_extensions) |ext| {
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/.config/{s}{s}",
                .{ home, name, ext },
            );
            defer self.allocator.free(path);

            if (fileExists(path)) {
                return try self.allocator.dupe(u8, path);
            }
        }

        return null;
    }

    /// Load and parse config file
    /// Returns a Parsed struct that owns the memory - caller must call deinit()
    pub fn loadConfigFile(
        self: *FileLoader,
        path: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        // Route TypeScript files through bun evaluation
        if (std.mem.endsWith(u8, path, ".ts")) {
            return self.loadTypeScriptConfig(path);
        }

        // Use cross-platform Io.Dir for file access
        const file = std.Io.Dir.cwd().openFile(getIo(), path, .{ .mode = .read_only }) catch |err| {
            return switch (err) {
                error.FileNotFound => errors.ZigConfigError.ConfigFileNotFound,
                error.AccessDenied => errors.ZigConfigError.ConfigFilePermissionDenied,
                else => errors.ZigConfigError.ConfigFileInvalid,
            };
        };
        defer file.close(getIo());

        // Read file content using Io.File (cross-platform)
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const bufs = [_][]u8{&buf};
            const n = file.readStreaming(getIo(), &bufs) catch {
                return errors.ZigConfigError.ConfigFileInvalid;
            };
            if (n == 0) break;
            content.appendSlice(self.allocator, buf[0..n]) catch {
                return errors.ZigConfigError.ConfigFileInvalid;
            };
        }

        const owned_content = content.toOwnedSlice(self.allocator) catch {
            return errors.ZigConfigError.ConfigFileInvalid;
        };
        defer self.allocator.free(owned_content);

        // Strip comments if this is a JSONC file
        const is_jsonc = std.mem.endsWith(u8, path, ".jsonc");
        const json_content = if (is_jsonc)
            try stripJsonComments(self.allocator, owned_content)
        else
            owned_content;
        defer if (is_jsonc) self.allocator.free(json_content);

        // Parse JSON/JSONC (with comments support)
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json_content,
            .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        ) catch {
            return errors.ZigConfigError.ConfigFileSyntaxError;
        };

        return parsed;
    }

    /// Load a TypeScript config file by shelling out to bun.
    /// Uses std.process.run for cross-platform subprocess execution.
    /// Falls back to ConfigFileInvalid if bun is not available or fails.
    fn loadTypeScriptConfig(
        self: *FileLoader,
        path: []const u8,
    ) !std.json.Parsed(std.json.Value) {
        // Build the eval script that imports the TS config and dumps JSON
        const script = std.fmt.allocPrint(
            self.allocator,
            "const c = await import('{s}'); console.log(JSON.stringify(c.default ?? c))",
            .{path},
        ) catch return errors.ZigConfigError.ConfigFileInvalid;
        defer self.allocator.free(script);

        // Use cross-platform std.process.run to execute bun
        const result = std.process.run(self.allocator, getIo(), .{
            .argv = &.{ "bun", "-e", script },
        }) catch {
            return errors.ZigConfigError.ConfigFileInvalid;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term != .exited or result.term.exited != 0) {
            return errors.ZigConfigError.ConfigFileInvalid;
        }

        if (result.stdout.len == 0) return errors.ZigConfigError.ConfigFileInvalid;

        // Parse the JSON output
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            result.stdout,
            .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            },
        ) catch {
            return errors.ZigConfigError.ConfigFileSyntaxError;
        };

        return parsed;
    }

    /// Get file modification time for cache invalidation
    pub fn getModTime(self: *FileLoader, path: []const u8) !i64 {
        _ = self;
        // Open file using cross-platform Io.Dir and use File.stat
        const file = std.Io.Dir.cwd().openFile(getIo(), path, .{ .mode = .read_only }) catch return error.FileNotFound;
        defer file.close(getIo());
        const stat = try file.stat(getIo());
        // mtime is in nanoseconds, convert to seconds
        return @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
    }
};

/// Get the absolute path of a file relative to a tmpDir (Zig 0.16 compat)
fn tmpDirRealPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, sub_path: []const u8) ![]const u8 {
    const c_realpath = std.c.realpath;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel = if (sub_path.len == 0 or std.mem.eql(u8, sub_path, "."))
        std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch return error.InvalidPath
    else
        std.fmt.bufPrint(&rel_buf, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, sub_path }) catch return error.InvalidPath;

    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(path_z[0..rel.len], rel);
    path_z[rel.len] = 0;

    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = c_realpath(&path_z, &resolved_buf) orelse return error.FileNotFound;
    const len = std.mem.len(resolved);
    return try allocator.dupe(u8, resolved[0..len]);
}

test "FileLoader.findConfigFile finds in project root" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(getIo(), "test.json", .{});
    defer file.close(getIo());
    try file.writePositionalAll(getIo(), "{}", 0);

    const cwd = try tmpDirRealPath(allocator, &tmp, ".");
    defer allocator.free(cwd);

    var loader = FileLoader.init(allocator);
    const found = try loader.findConfigFile("test", cwd);
    defer if (found) |path| allocator.free(path);

    try std.testing.expect(found != null);
    try std.testing.expect(std.mem.endsWith(u8, found.?, "test.json"));
}

test "FileLoader.findConfigFile returns null when not found" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try tmpDirRealPath(allocator, &tmp, ".");
    defer allocator.free(cwd);

    var loader = FileLoader.init(allocator);
    const found = try loader.findConfigFile("nonexistent", cwd);

    try std.testing.expect(found == null);
}

test "FileLoader.loadConfigFile parses JSON" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(getIo(), "test.json", .{});
    defer file.close(getIo());
    try file.writePositionalAll(getIo(), "{\"key\": \"value\"}", 0);

    const path = try tmpDirRealPath(allocator, &tmp, "test.json");
    defer allocator.free(path);

    var loader = FileLoader.init(allocator);
    var parsed = try loader.loadConfigFile(path);
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("key") != null);
}
