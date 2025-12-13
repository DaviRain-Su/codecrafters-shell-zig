const std = @import("std");

// define stdin
var stdin_buffer: [4096]u8 = undefined;
var stdin_readder = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_readder.interface;

// define stdout
var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

const Commands = enum {
    echo,
    exit,
    notfound,
};

pub fn main() !void {
    while (true) {
        const command = try prompt("$ ");
        if (command.len == 0) {
            continue;
        } else {
            var args = std.mem.tokenizeScalar(u8, command, ' ');
            const translated_command = std.meta.stringToEnum(Commands, args.next().?) orelse Commands.notfound;
            switch (translated_command) {
                Commands.echo => try stdout.print("{s}\n", .{command[args.index + 1 ..]}),
                Commands.exit => return std.process.exit(0),
                Commands.notfound => try stdout.print("{s}: command not found\n", .{ .command = command }),
            }
        }
    }
}

fn prompt(comptime question: []const u8) ![]u8 {
    try stdout.print(question, .{});
    return try stdin.takeDelimiter('\n') orelse "";
}
