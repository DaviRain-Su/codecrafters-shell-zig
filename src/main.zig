const std = @import("std");

// define stdin
var stdin_buffer: [4096]u8 = undefined;
var stdin_readder = std.fs.File.stdin().readerStreaming(&stdin_buffer);
const stdin = &stdin_readder.interface;

// define stdout
var stdout_writer = std.fs.File.stdout().writerStreaming(&.{});
const stdout = &stdout_writer.interface;

pub fn main() !void {
    while (true) {
        const user_input = try prompt("$ ");
        if (std.mem.eql(u8, user_input, "exit")) {
            return std.process.exit(0);
        }
        try stdout.print("{s}: command not found\n", .{user_input});
    }
}

fn prompt(comptime question: []const u8) ![]u8 {
    try stdout.print(question, .{});
    return try stdin.takeDelimiter('\n') orelse "";
}
