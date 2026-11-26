//! Windows console handles, virtual-terminal mode, and final paths.
//! Imported only when the target OS is Windows. macOS and Linux never compile it.
//!
//! Raw mode turns on `ENABLE_VIRTUAL_TERMINAL_INPUT` and
//! `ENABLE_VIRTUAL_TERMINAL_PROCESSING`, so the existing ANSI renderer and
//! byte parser talk to the console the same way they talk to a POSIX terminal.
//! Windows Console Host and Windows Terminal both honor those modes.

const std = @import("std");

const windows = std.os.windows;

const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

const FILE_TYPE_CHAR: DWORD = 0x0002;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
const ENABLE_WRAP_AT_EOL_OUTPUT: DWORD = 0x0002;

const WAIT_OBJECT_0: DWORD = 0;
const WAIT_TIMEOUT: DWORD = 0x00000102;
const WAIT_FAILED: DWORD = 0xffffffff;

const VOLUME_NAME_DOS: DWORD = 0;

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: HANDLE,
    lpConsoleScreenBufferInfo: *ConsoleScreenBufferInfo,
) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetFinalPathNameByHandleW(
    hFile: HANDLE,
    lpszFilePath: [*]u16,
    cchFilePath: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) DWORD;

const Coord = extern struct {
    x: i16,
    y: i16,
};

const SmallRect = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

const ConsoleScreenBufferInfo = extern struct {
    size: Coord,
    cursor_position: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
};

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Poll = struct {
    readable: bool = false,
    hung_up: bool = false,
    has_error: bool = false,
};

pub const InputMode = struct {
    input: DWORD,
    output: DWORD,
    output_valid: bool,
};

fn standard(which: DWORD) ?HANDLE {
    return GetStdHandle(which);
}

pub fn stdinHandle() ?HANDLE {
    return standard(STD_INPUT_HANDLE);
}

pub fn stdoutHandle() ?HANDLE {
    return standard(STD_OUTPUT_HANDLE);
}

pub fn stderrHandle() ?HANDLE {
    return standard(STD_ERROR_HANDLE);
}

pub fn isConsole(handle: ?HANDLE) bool {
    const file = handle orelse return false;
    if (GetFileType(file) != FILE_TYPE_CHAR) return false;
    var mode: DWORD = 0;
    return succeeded(GetConsoleMode(file, &mode));
}

pub fn readStdin(buffer: []u8) error{ InputOutput, Unexpected }!usize {
    const file = stdinHandle() orelse return error.InputOutput;
    if (buffer.len == 0) return 0;
    var read_len: DWORD = 0;
    const want: DWORD = std.math.cast(DWORD, buffer.len) orelse std.math.maxInt(DWORD);
    if (!succeeded(ReadFile(file, buffer.ptr, want, &read_len, null))) return error.InputOutput;
    return read_len;
}

pub fn pollStdin(timeout_ms: i32) error{Unexpected}!Poll {
    const file = stdinHandle() orelse return .{ .hung_up = true };
    const timeout: DWORD = if (timeout_ms < 0) 0xffffffff else @intCast(timeout_ms);
    return switch (WaitForSingleObject(file, timeout)) {
        WAIT_OBJECT_0 => .{ .readable = true },
        WAIT_TIMEOUT => .{},
        WAIT_FAILED => .{ .has_error = true },
        else => .{ .has_error = true },
    };
}

pub fn captureInputMode() error{NotATerminal}!InputMode {
    const input = stdinHandle() orelse return error.NotATerminal;
    var input_mode: DWORD = 0;
    if (!succeeded(GetConsoleMode(input, &input_mode))) return error.NotATerminal;
    var output_mode: DWORD = 0;
    const output_valid = if (stdoutHandle()) |output| succeeded(GetConsoleMode(output, &output_mode)) else false;
    return .{
        .input = input_mode,
        .output = output_mode,
        .output_valid = output_valid,
    };
}

pub fn enableRaw(saved: InputMode) error{NotATerminal}!void {
    const input = stdinHandle() orelse return error.NotATerminal;
    if (!succeeded(SetConsoleMode(input, ENABLE_VIRTUAL_TERMINAL_INPUT))) return error.NotATerminal;
    if (saved.output_valid) {
        if (stdoutHandle()) |output| {
            const mode = ENABLE_PROCESSED_OUTPUT | ENABLE_WRAP_AT_EOL_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
            if (!succeeded(SetConsoleMode(output, mode))) return error.NotATerminal;
        }
    }
}

pub fn restore(saved: InputMode) void {
    if (stdinHandle()) |input| {
        _ = SetConsoleMode(input, saved.input);
    }
    if (saved.output_valid) {
        if (stdoutHandle()) |output| {
            _ = SetConsoleMode(output, saved.output);
        }
    }
}

pub fn windowSize() error{UnableToReadTerminalSize}!Size {
    const output = stdoutHandle() orelse return error.UnableToReadTerminalSize;
    var info: ConsoleScreenBufferInfo = undefined;
    if (!succeeded(GetConsoleScreenBufferInfo(output, &info))) return error.UnableToReadTerminalSize;
    const cols = info.window.right - info.window.left + 1;
    const rows = info.window.bottom - info.window.top + 1;
    if (cols <= 0 or rows <= 0) return error.UnableToReadTerminalSize;
    return .{
        .cols = @intCast(cols),
        .rows = @intCast(rows),
    };
}

/// Caller owns the returned UTF-8 path. `\\?\` and `\\?\UNC\` prefixes are stripped.
pub fn finalPathAlloc(alloc: std.mem.Allocator, handle: HANDLE) ![]u8 {
    var wide: [32768]u16 = undefined;
    const len = GetFinalPathNameByHandleW(handle, &wide, wide.len, VOLUME_NAME_DOS);
    if (len == 0 or len >= wide.len) return error.HandlePathUnavailable;
    const prefixed = wide[0..len];
    const bare = stripDosPrefix(prefixed);
    const utf8_len = std.unicode.calcWtf8Len(bare);
    const out = try alloc.alloc(u8, utf8_len);
    errdefer alloc.free(out);
    const written = std.unicode.wtf16LeToWtf8(out, bare);
    if (written != out.len) return error.HandlePathUnavailable;
    return out;
}

fn succeeded(value: windows.BOOL) bool {
    return @backingInt(value) != 0;
}

fn stripDosPrefix(path: []const u16) []const u16 {
    const unc = std.unicode.wtf8ToWtf16LeStringLiteral("\\\\?\\UNC\\");
    if (std.mem.startsWith(u16, path, unc)) {
        // `\\?\UNC\server\share` -> `\\server\share`. The two leading backslashes
        // replace the prefix's own separator, so keep one separator from the prefix.
        return path[unc.len - 1 ..];
    }
    const dos = std.unicode.wtf8ToWtf16LeStringLiteral("\\\\?\\");
    if (std.mem.startsWith(u16, path, dos)) return path[dos.len..];
    return path;
}
