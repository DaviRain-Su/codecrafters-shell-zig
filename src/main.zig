const std = @import("std");

// Global stdin/stdout for convenience within this simple shell
var stdin_buffer: [4096]u8 = undefined;
var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_reader.interface;

var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

const Commands = enum {
    type,
    echo,
    exit,
    pwd,
    cd,
};

const ParsedCommand = struct {
    args: []const []const u8,
    output_file_path: ?OutputFilePath,
};

const OutputFilePath = union(enum) {
    stdout: SelfStdout,
    stderr: SelfStderr,
};

const SelfStdout = struct {
    stdout: []const u8,
    append: bool = false,
};

const SelfStderr = struct {
    stderr: []const u8,
    append: bool = false,
};

fn parseCommand(allocator: std.mem.Allocator, args: []const []const u8) !ParsedCommand {
    var clean_args = try std.ArrayList([]const u8).initCapacity(allocator, args.len);
    var output_file_path: ?OutputFilePath = null;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "1>")) {
            if (i + 1 < args.len) {
                output_file_path = OutputFilePath{ .stdout = SelfStdout{ .stdout = args[i + 1] } };
                i += 2; // Skip operator and filename
                continue;
            }
        } else if (std.mem.eql(u8, arg, "2>") or std.mem.eql(u8, arg, "2>>")) {
            if (i + 1 < args.len) {
                output_file_path = OutputFilePath{ .stderr = SelfStderr{ .stderr = args[i + 1], .append = std.mem.eql(u8, arg, "2>>") } };
                i += 2; // Skip operator and filename
                continue;
            }
        } else if (std.mem.eql(u8, arg, ">>") or std.mem.eql(u8, arg, "1>>")) {
            if (i + 1 < args.len) {
                output_file_path = OutputFilePath{ .stdout = SelfStdout{ .stdout = args[i + 1], .append = std.mem.eql(u8, arg, "1>>") } };
                i += 2; // Skip operator and filename
                continue;
            }
        }

        try clean_args.append(allocator, arg);

        i += 1;
    }

    return ParsedCommand{
        .args = try clean_args.toOwnedSlice(allocator),
        .output_file_path = output_file_path,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    while (true) {
        _ = arena.reset(.retain_capacity);

        const command_line = try prompt("$ ");
        if (command_line.len == 0) continue;

        const args = try parseArgs(allocator, command_line);
        if (args.len == 0) continue;

        const parsed_cmd = try parseCommand(allocator, args);
        const cmd_str = parsed_cmd.args[0];

        // Check for builtins first
        if (std.meta.stringToEnum(Commands, cmd_str)) |cmd| {
            switch (cmd) {
                .type => try handleType(allocator, parsed_cmd.args),
                .echo => try handleEcho(parsed_cmd.args[1..], parsed_cmd.output_file_path),
                .pwd => try handlePwd(),
                .cd => try handleCd(parsed_cmd.args),
                .exit => try handleExit(parsed_cmd.args),
            }
        } else {
            // Treat as external command
            try runExternalCmd(allocator, parsed_cmd.args, parsed_cmd.output_file_path);
        }
    }
}

fn prompt(comptime question: []const u8) ![]u8 {
    try stdout.print(question, .{});
    return try stdin.takeDelimiter('\n') orelse "";
}

fn parseArgs(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var args = try std.ArrayList([]const u8).initCapacity(allocator, 10);

    var current_arg: ?std.ArrayList(u8) = null;
    var state: enum { Normal, InSingleQuote, InDoubleQuote, BackslashEscaping, BackSlashEscapingInDoubleQuote } = .Normal;

    for (line) |c| {
        switch (state) {
            .Normal => switch (c) {
                ' ' => {
                    if (current_arg) |*arg| {
                        try args.append(allocator, try arg.toOwnedSlice(allocator));
                        current_arg = null;
                    }
                },
                '\'' => {
                    if (current_arg == null) {
                        current_arg = try std.ArrayList(u8).initCapacity(allocator, 16);
                    }
                    state = .InSingleQuote;
                },
                '"' => {
                    if (current_arg == null) {
                        current_arg = try std.ArrayList(u8).initCapacity(allocator, 16);
                    }
                    state = .InDoubleQuote;
                },
                '\\' => {
                    if (current_arg == null) {
                        current_arg = try std.ArrayList(u8).initCapacity(allocator, 16);
                    }
                    state = .BackslashEscaping;
                },
                else => {
                    if (current_arg == null) {
                        current_arg = try std.ArrayList(u8).initCapacity(allocator, 16);
                    }
                    try current_arg.?.append(allocator, c);
                },
            },
            .InSingleQuote => switch (c) {
                '\'' => {
                    state = .Normal;
                },
                else => {
                    try current_arg.?.append(allocator, c);
                },
            },
            .BackSlashEscapingInDoubleQuote => switch (c) {
                '"' => {
                    try current_arg.?.append(allocator, c);
                    state = .InDoubleQuote;
                },
                '\\' => {
                    try current_arg.?.append(allocator, '\\');
                    state = .InDoubleQuote;
                },
                '\'' => {
                    try current_arg.?.append(allocator, '\\');
                    try current_arg.?.append(allocator, '\'');
                    state = .InDoubleQuote;
                },
                else => {
                    try current_arg.?.append(allocator, '\\');
                    try current_arg.?.append(allocator, c);
                    state = .InDoubleQuote;
                },
            },
            .InDoubleQuote => switch (c) {
                '"' => {
                    state = .Normal;
                },
                '\\' => {
                    state = .BackSlashEscapingInDoubleQuote;
                },
                else => {
                    try current_arg.?.append(allocator, c);
                },
            },
            .BackslashEscaping => {
                // In this state, we just append the character literally and go back to Normal
                try current_arg.?.append(allocator, c);
                state = .Normal;
            },
        }
    }

    if (current_arg) |*arg| {
        try args.append(allocator, try arg.toOwnedSlice(allocator));
    }

    return args.toOwnedSlice(allocator);
}

fn handlePwd() !void {
    var out_buffer: [1024]u8 = [_]u8{0} ** 1024;
    const cwd = try std.process.getCwd(&out_buffer);
    try stdout.print("{s}\n", .{cwd});
}

fn handleCd(args: []const []const u8) !void {
    var dir: []const u8 = "~";
    if (args.len > 1) {
        dir = args[1];
    }

    if (std.mem.eql(u8, dir, "~")) {
        const home = std.posix.getenv("HOME") orelse return;
        try std.process.changeCurDir(home);
    } else {
        std.process.changeCurDir(dir) catch {
            try stdout.print("cd: {s}: No such file or directory\n", .{dir});
        };
    }
}

fn handleEcho(args: []const []const u8, output_file_path: ?OutputFilePath) !void {
    var stdout_file: ?std.fs.File = null;

    if (output_file_path) |filename| {
        switch (filename) {
            .stdout => |path| {
                if (path.append) {
                    // TIPS: Use .truncate = false to append to the file
                    stdout_file = try std.fs.cwd().createFile(path.stdout, .{ .truncate = false });
                    // get size to seekTo End
                    const size = try stdout_file.?.getEndPos();
                    try stdout_file.?.seekTo(size);
                } else {
                    stdout_file = try std.fs.cwd().createFile(path.stdout, .{});
                }
            },
            .stderr => |path| {
                if (path.append) {
                    // TIPS: Use .truncate = false to append to the file
                    stdout_file = try std.fs.cwd().createFile(path.stderr, .{ .truncate = false });
                    // get size to seekTo End
                    const size = try stdout_file.?.getEndPos();
                    try stdout_file.?.seekTo(size);
                } else {
                    const f = try std.fs.cwd().createFile(path.stderr, .{});
                    f.close();
                }
            },
        }
    }
    defer if (stdout_file) |f| f.close();

    if (stdout_file) |file| {
        // Create a streaming writer for the file
        var writer_impl = file.writerStreaming(&.{});
        var writer = &writer_impl.interface;
        for (args, 0..) |arg, i| {
            try writer.print("{s}", .{arg});
            if (i < args.len - 1) {
                try writer.print(" ", .{});
            }
        }
        try writer.print("\n", .{});
    } else {
        for (args, 0..) |arg, i| {
            try stdout.print("{s}", .{arg});
            if (i < args.len - 1) {
                try stdout.print(" ", .{});
            }
        }
        try stdout.print("\n", .{});
    }
}

fn handleExit(args: []const []const u8) !void {
    var code: u8 = 0;
    if (args.len > 1) {
        code = std.fmt.parseInt(u8, args[1], 10) catch 0;
    }
    std.process.exit(code);
}

fn handleType(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return;
    const target_cmd = args[1];

    // Check if it's a builtin
    if (std.meta.stringToEnum(Commands, target_cmd)) |_| {
        try stdout.print("{s} is a shell builtin\n", .{target_cmd});
        return;
    }

    // Check PATH
    if (try findInPath(allocator, target_cmd)) |path| {
        try stdout.print("{s} is {s}\n", .{ target_cmd, path });
    } else {
        try stdout.print("{s}: not found\n", .{target_cmd});
    }
}

fn runExternalCmd(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    redirect_file: ?OutputFilePath,
) !void {
    const cmd_str = argv[0];

    // 1. Check if executable exists in PATH
    const exec_path = try findInPath(allocator, cmd_str);
    if (exec_path == null) {
        try stdout.print("{s}: command not found\n", .{cmd_str});
        return;
    }
    const dir_path_z = try allocator.dupeZ(u8, exec_path.?);

    // 2. Prepare argv
    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, argv.len + 1);
    defer argv_list.deinit(allocator);

    for (argv) |arg| {
        try argv_list.append(allocator, try allocator.dupeZ(u8, arg));
    }
    try argv_list.append(allocator, null);

    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(argv_list.items.ptr);

    // 3. Prepare envp
    const env_map = try std.process.getEnvMap(allocator);
    const envp = try std.process.createNullDelimitedEnvMap(allocator, &env_map);

    // 4. Fork and Exec
    const pid = try std.posix.fork();
    if (pid == 0) {
        // Child process
        if (redirect_file) |file_path| {
            switch (file_path) {
                .stdout => |path| {
                    if (path.append) {
                        const file = try std.fs.cwd().createFile(path.stdout, .{ .truncate = false });
                        // get size to seekTo End
                        const size = try file.getEndPos();
                        try file.seekTo(size);
                        // 使用 dup2 将目标文件的文件描述符复制到 STDOUT_FILENO (1)。
                        _ = try std.posix.dup2(file.handle, std.posix.STDOUT_FILENO);
                        file.close();
                    } else {
                        const file = try std.fs.cwd().createFile(path.stdout, .{});
                        // 使用 dup2 将目标文件的文件描述符复制到 STDOUT_FILENO (1)。
                        _ = try std.posix.dup2(file.handle, std.posix.STDOUT_FILENO);
                        file.close();
                    }
                },
                .stderr => |path| {
                    if (path.append) {
                        // TIPS: Use .truncate = false to append to the file
                        const file = try std.fs.cwd().createFile(path.stderr, .{ .truncate = false });
                        // get size to seekTo End
                        const size = try file.getEndPos();
                        try file.seekTo(size);
                        // 使用 dup2 将目标文件的文件描述符复制到 STDOUT_FILENO (1)。
                        _ = try std.posix.dup2(file.handle, std.posix.STDOUT_FILENO);
                        file.close();
                    } else {
                        const file = try std.fs.cwd().createFile(path.stderr, .{});
                        // 使用 dup2 将目标文件的文件描述符复制到 STDERR_FILENO (2)。
                        _ = try std.posix.dup2(file.handle, std.posix.STDERR_FILENO);
                        file.close();
                    }
                },
            }
        }

        const err = std.posix.execveZ(dir_path_z, argv_ptr, envp);
        std.debug.print("Exec failed: {}\n", .{err});
        std.posix.exit(1);
    } else {
        // Parent process
        _ = std.posix.waitpid(pid, 0);
    }
}

fn findInPath(allocator: std.mem.Allocator, command_name: []const u8) !?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;
    var dirs = std.mem.splitScalar(u8, path_env, ':');

    while (dirs.next()) |dir| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, command_name });
        // We don't defer free(full_path) here because if found, we return it (transfer ownership to arena)
        // If not found, it will be freed when arena resets at the end of the loop, which is fine.

        if (std.posix.access(full_path, std.posix.X_OK)) |_| {
            return full_path;
        } else |_| {
            // Not found or not executable, continue
        }
    }
    return null;
}
