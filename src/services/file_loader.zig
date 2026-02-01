const std = @import("std");
const types = @import("../types.zig");
const errors = @import("../errors.zig");
const utils = @import("../utils.zig");

// Zig 0.16+ IO helper
var io_instance: std.Io.Threaded = .init_single_threaded;
fn getIo() std.Io {
    return io_instance.io();
}

/// Check if a file exists using openat
fn fileExists(path: []const u8) bool {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return false;
    std.posix.close(fd);
    return true;
}

/// Strip single-line (//) and multi-line (/* */) comments from JSON content
fn stripJsonComments(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len);
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

    const EXTENSIONS = [_][]const u8{ ".json", ".jsonc", ".zig" };
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
        for (PROJECT_PATHS) |dir| {
            for (EXTENSIONS) |ext| {
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

        for (EXTENSIONS) |ext| {
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
        // Use posix.openat since Io.Dir doesn't have openFileAbsolute in Zig 0.16
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch |err| {
            return switch (err) {
                error.FileNotFound => errors.ZigConfigError.ConfigFileNotFound,
                error.AccessDenied => errors.ZigConfigError.ConfigFilePermissionDenied,
                else => errors.ZigConfigError.ConfigFileInvalid,
            };
        };
        defer std.posix.close(fd);

        // Read file content using loop (Zig 0.16+ compatible)
        var content = std.ArrayList(u8).empty;
        defer content.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = std.posix.read(fd, &buf) catch |err| {
                return switch (err) {
                    error.AccessDenied => errors.ZigConfigError.ConfigFilePermissionDenied,
                    else => errors.ZigConfigError.ConfigFileInvalid,
                };
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

    /// Get file modification time for cache invalidation
    pub fn getModTime(self: *FileLoader, path: []const u8) !i64 {
        _ = self;
        // Use posix stat since Io.Dir doesn't have openFileAbsolute
        const stat = try std.posix.stat(path);
        // Return mtime in seconds
        return @as(i64, stat.mtime.sec);
    }
};

test "FileLoader.findConfigFile finds in project root" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("test.json", .{});
    defer file.close(getIo());
    try file.writeAll("{}");

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
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

    const cwd = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var loader = FileLoader.init(allocator);
    const found = try loader.findConfigFile("nonexistent", cwd);

    try std.testing.expect(found == null);
}

test "FileLoader.loadConfigFile parses JSON" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("test.json", .{});
    defer file.close(getIo());
    try file.writeAll("{\"key\": \"value\"}");

    const path = try tmp.dir.realpathAlloc(allocator, "test.json");
    defer allocator.free(path);

    var loader = FileLoader.init(allocator);
    var parsed = try loader.loadConfigFile(path);
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("key") != null);
}
