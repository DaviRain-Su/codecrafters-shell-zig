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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    while (true) {
        _ = arena.reset(.retain_capacity);

        const command_line = try prompt("$ ");
        if (command_line.len == 0) continue;

        var args = std.mem.tokenizeScalar(u8, command_line, ' ');
        // get the first argument
        const cmd_str = args.next() orelse continue;

        // Check for builtins first
        if (std.meta.stringToEnum(Commands, cmd_str)) |cmd| {
            switch (cmd) {
                .type => try handleType(allocator, &args),
                .echo => try handleEcho(command_line, args.index + 1),
                .pwd => try handlePwd(),
                .cd => try handleCd(command_line, args.index + 1),
                .exit => try handleExit(),
            }
        } else {
            // Treat as external command
            try runExternalCmd(allocator, cmd_str, command_line, args);
        }
    }
}

fn prompt(comptime question: []const u8) ![]u8 {
    try stdout.print(question, .{});
    return try stdin.takeDelimiter('\n') orelse "";
}

fn handlePwd() !void {
    var out_buffer: [1024]u8 = [_]u8{0} ** 1024;
    const cwd = try std.process.getCwd(&out_buffer);
    try stdout.print("{s}\n", .{cwd});
}

fn handleCd(command_line: []const u8, start_index: usize) !void {
    if (start_index < command_line.len) {
        const dir = command_line[start_index..];
        if (std.mem.eql(u8, dir, "~")) {
            const home = std.posix.getenv("HOME") orelse return;
            try std.process.changeCurDir(home);
        } else {
            std.process.changeCurDir(dir) catch {
                try stdout.print("cd: {s}: No such file or directory\n", .{dir});
            };
        }
    } else {
        try std.process.changeCurDir("/");
    }
}

fn handleEcho(command_line: []const u8, start_index: usize) !void {
    // echo prints the rest of the line as-is (simplified behavior)
    if (start_index < command_line.len) {
        try stdout.print("{s}\n", .{command_line[start_index..]});
    } else {
        try stdout.print("\n", .{});
    }
}

fn handleExit() !void {
    std.process.exit(0);
}

// 处理剩余的参数
fn handleType(allocator: std.mem.Allocator, args: *std.mem.TokenIterator(u8, .scalar)) !void {
    const target_cmd = args.next() orelse return;

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
    cmd_str: []const u8,
    command_line: []const u8,
    args_iter: std.mem.TokenIterator(u8, .scalar),
) !void {
    // 1. Check if executable exists in PATH
    const exec_path = try findInPath(allocator, cmd_str);
    if (exec_path == null) {
        try stdout.print("{s}: command not found\n", .{command_line});
        return;
    }
    const dir_path_z = try allocator.dupeZ(u8, exec_path.?);

    // 2. Prepare argv
    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, 10);
    defer argv_list.deinit(allocator);
    // argv[0] is the command itself
    try argv_list.append(allocator, try allocator.dupeZ(u8, cmd_str));

    // Re-create iterator copy to traverse remaining args
    var args = args_iter;
    while (args.next()) |arg| {
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
