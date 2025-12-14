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
                .echo => try handleEcho(allocator, command_line[args.index + 1 ..]),
                .pwd => try handlePwd(),
                .cd => try handleCd(command_line[args.index + 1 ..]),
                .exit => try handleExit(),
            }
        } else {
            // Treat as external command
            try runExternalCmd(allocator, cmd_str, command_line[args.index + 1 ..]);
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

fn handleCd(input: []const u8) !void {
    const dir = input;
    if (std.mem.eql(u8, dir, "~")) {
        const home = std.posix.getenv("HOME") orelse return;
        try std.process.changeCurDir(home);
    } else {
        std.process.changeCurDir(dir) catch {
            try stdout.print("cd: {s}: No such file or directory\n", .{dir});
        };
    }
}

fn handleEcho(allocator: std.mem.Allocator, command_line: []const u8) !void {
    // echo prints the rest of the line as-is (simplified behavior)
    const result = try tokenize(allocator, command_line);
    try stdout.print("{s}\n", .{result});
    allocator.free(result);
}
// 定义解析器的状态
const ParserState = enum {
    Normal, // 普通模式：压缩空格，识别引号
    InQuote, // 引用模式：保留原样，寻找结束引号
};

fn tokenize(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer result.deinit(allocator);

    // 初始状态
    var state = ParserState.Normal;
    var pending_space = false; // 用于标记“是否欠一个空格”

    for (input) |c| {
        switch (state) {
            // === 状态 1: 普通模式 ===
            .Normal => switch (c) {
                // 1. 遇到单引号：切换到引用模式
                '\'' => {
                    // 【修复点】：在进入引号前，如果之前欠了一个空格，必须先补上！
                    // 比如: echo 'a' 'b' -> 中间的空格会在这里被补上
                    if (pending_space) {
                        try result.append(allocator, ' ');
                        pending_space = false;
                    }
                    state = .InQuote;
                },
                // 2. 遇到空格：标记需要空格，但不立即写入（实现压缩）
                ' ' => {
                    // 只有当结果不为空时才需要处理空格（忽略开头的空格）
                    if (result.items.len > 0) {
                        pending_space = true;
                    }
                },
                // 3. 其他字符：写入
                else => {
                    // 如果之前欠了一个空格，现在补上
                    if (pending_space) {
                        try result.append(allocator, ' ');
                        pending_space = false;
                    }
                    try result.append(allocator, c);
                },
            },

            // === 状态 2: 引用模式 (单引号内) ===
            .InQuote => switch (c) {
                // 1. 遇到单引号：结束引用，切回普通模式
                '\'' => {
                    state = .Normal;
                },
                // 2. 其他任何字符（包括空格）：原样写入
                else => {
                    try result.append(allocator, c);
                },
            },
        }
    }

    return result.toOwnedSlice(allocator);
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
    input: []const u8,
) !void {
    // 1. Check if executable exists in PATH
    const exec_path = try findInPath(allocator, cmd_str);
    if (exec_path == null) {
        try stdout.print("{s}: command not found\n", .{cmd_str});
        return;
    }
    const dir_path_z = try allocator.dupeZ(u8, exec_path.?);

    // 2. Prepare argv
    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, 10);
    defer argv_list.deinit(allocator);
    // argv[0] is the command itself
    try argv_list.append(allocator, try allocator.dupeZ(u8, cmd_str));

    // Re-create iterator copy to traverse remaining args
    //var args = args_iter;
    //while (args.next()) |arg| {
    const arg_z = try tokenize(allocator, input);
    try argv_list.append(allocator, try allocator.dupeZ(u8, arg_z));
    //}
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

fn findInPath(allocator: std.mem.Allocator, file_name: []const u8) !?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;
    var dirs = std.mem.splitScalar(u8, path_env, ':');

    while (dirs.next()) |dir| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, file_name });
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
