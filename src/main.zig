const std = @import("std");

// define stdin
var stdin_buffer: [4096]u8 = undefined;
var stdin_readder = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_readder.interface;

// define stdout
var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

const Commands = enum {
    type,
    echo,
    exit,
    notfound,
};

pub fn main() !void {
    // 内存分配器 (建议定义在循环外)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    while (true) {
        // 每次循环清空 Arena 内存池，防止内存泄漏，处理起来非常方便！
        _ = arena.reset(.retain_capacity);

        const command = try prompt("$ ");
        if (command.len == 0) {
            continue;
        } else {
            var args = std.mem.tokenizeScalar(u8, command, ' ');
            // 注意：这里需要处理 args 为空的情况，否则 args.next().? 会 crash
            // 实际使用建议加个 if (args.peek() == null) check
            const cmd_str = args.next() orelse continue;
            const translated_command = std.meta.stringToEnum(Commands, cmd_str) orelse .notfound;
            switch (translated_command) {
                .type => {
                    const cmd = std.meta.stringToEnum(Commands, args.peek().?) orelse .notfound;
                    switch (cmd) {
                        .type, .echo, .exit => try stdout.print("{s} is a shell builtin\n", .{args.peek().?}),
                        .notfound => {
                            const command_name = command[args.index..];
                            var found = false;
                            // 1. 直接获取 PATH 环境变量 (如果不存在，默认为空字符串)
                            // std.posix.getenv 返回 ?[]const u8，如果为 null 则跳过
                            if (std.posix.getenv("PATH")) |path_env| {
                                var dirs = std.mem.splitScalar(u8, path_env, ':');
                                while (dirs.next()) |dir| {
                                    // 2. 拼接路径: dir + "/" + command_name
                                    const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, command_name });
                                    defer allocator.free(dir_path);
                                    // 3: check if file is executable if file is executable return
                                    if (std.posix.access(dir_path, std.posix.X_OK)) |_| {
                                        // 成功：找到了！
                                        try stdout.print("{s} is {s}\n", .{ command_name, dir_path });
                                        found = true;
                                        // 【关键修改】：这里只跳出循环，不要 exit！
                                        break;
                                    } else |_| {
                                        // 失败：当前目录下没有，或者不可执行。
                                        // 关键点：什么都不做，继续下一次循环！
                                        continue;
                                    }
                                }
                            }
                            // 4：如果循环结束了还没找到，打印 not found
                            if (!found) {
                                try stdout.print("{s}: not found\n", .{command_name});
                            }
                        },
                    }
                },
                .echo => try stdout.print("{s}\n", .{command[args.index + 1 ..]}),
                .exit => return std.process.exit(0),
                .notfound => {
                    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, 10);
                    defer argv_list.deinit(allocator);
                    const cmd_z = try allocator.dupeZ(u8, cmd_str);
                    try argv_list.append(allocator, cmd_z);
                    while (args.next()) |arg| {
                        const current_args = try allocator.dupeZ(u8, arg);
                        try argv_list.append(allocator, current_args);
                    }
                    // 1. 确保一定要先 append(null)
                    try argv_list.append(allocator, null);

                    // 2. 定义 execveZ 需要的类型
                    const ArgvType = [*:null]const ?[*:0]const u8;

                    // 3. 强制转换指针类型
                    // 告诉编译器："我发誓这里面是以 null 结尾的"
                    const argv_ptr: ArgvType = @ptrCast(argv_list.items.ptr);

                    var found = false;
                    if (std.posix.getenv("PATH")) |path_env| {
                        var dirs = std.mem.splitScalar(u8, path_env, ':');
                        while (dirs.next()) |dir| {
                            // 2. 拼接路径: dir + "/" + command_name
                            const dir_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, cmd_str });
                            defer allocator.free(dir_path);
                            // 3: check if file is executable if file is executable return
                            if (std.posix.access(dir_path, std.posix.X_OK)) |_| {
                                found = true;
                                // 1. 将 dir_path 转换为以 null 结尾的字符串 (Z代表 Zero-terminated)
                                const dir_path_z = try allocator.dupeZ(u8, dir_path);
                                defer allocator.free(dir_path_z); // 养成释放内存的习惯（虽然 exec 成功后会替换进程内存）

                                // 2. 准备环境变量 (使用当前环境)
                                const env_map = try std.process.getEnvMap(allocator);
                                const envp = try std.process.createNullDelimitedEnvMap(allocator, &env_map); // 这是一个复杂的转换函数

                                // [修复 3] 必须 Fork！
                                const pid = try std.posix.fork();

                                if (pid == 0) {
                                    // === 子进程 ===
                                    // 这里执行 exec，替换子进程
                                    const err = std.posix.execveZ(dir_path_z, argv_ptr, envp);
                                    // 如果到了这里，说明 exec 失败了
                                    std.debug.print("Exec failed: {}\n", .{err});
                                    std.posix.exit(1); // 子进程必须退出
                                } else {
                                    // === 父进程 (Shell) ===
                                    // 等待子进程结束
                                    const wait_result = std.posix.waitpid(pid, 0);
                                    // wait_result 包含子进程的退出状态
                                    _ = wait_result;
                                }

                                // 【关键修改】：这里只跳出循环，不要 exit！
                                break;
                            } else |_| {
                                // 失败：当前目录下没有，或者不可执行。
                                // 关键点：什么都不做，继续下一次循环！
                                continue;
                            }
                        }
                    }

                    if (!found) {
                        try stdout.print("{s}: command not found\n", .{command});
                    }
                },
            }
        }
    }
}

fn prompt(comptime question: []const u8) ![]u8 {
    try stdout.print(question, .{});
    return try stdin.takeDelimiter('\n') orelse "";
}
