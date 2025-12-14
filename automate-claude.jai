// Automate Claude Code - Run multiple claude commands sequentially
//
// Usage: automate-claude [options] "cmd1","cmd2","cmd3"
// Example: automate-claude "refactor the utils module"
// Example: automate-claude "/implement feature","write tests","fix lint errors"
// Example: automate-claude --live --headless "step1","step2","step3"
// Example: automate-claude --count 3 "task1","task2"  # runs all commands 3 times
//
// This program:
// - Runs claude in print mode (-p) for non-interactive output
// - Accepts comma-separated list of commands to run sequentially
// - Saves output of each run to a file (claude_runs/run_N.txt)
// - Records timing for each run
// - Stops on failure (non-zero exit or timeout)
// - Writes summary on completion
//
// Build: jai automate-claude.jai
// Run:   ./automate-claude "fix lint errors","run tests"

#import "Basic";
#import "Process";
#import "File";
#import "String";
#import "POSIX";
#import "Hash_Table";
#import,dir "modules/jason";

// Get current timestamp as a formatted string [HH:MM:SS]
get_timestamp :: () -> string {
    now := current_time_consensus();
    cal := to_calendar(now, .LOCAL);
    return sprint("[%:%:%]",
        formatInt(cal.hour, minimum_digits=2),
        formatInt(cal.minute, minimum_digits=2),
        formatInt(cal.second, minimum_digits=2));
}

// Flush stdout/stderr for immediate output
flush_stdout :: () {
    libc :: #library,system "libc";
    stdout : *void #elsewhere libc;
    fflush :: (stream: *void) -> s32 #foreign libc;
    fflush(stdout);
}

flush_stderr :: () {
    libc :: #library,system "libc";
    stderr : *void #elsewhere libc;
    fflush :: (stream: *void) -> s32 #foreign libc;
    fflush(stderr);
}

// Flush all output and wait for PTY to drain
// This prevents buffered output from being sent to parent shell and executed
flush_and_wait :: (wait_ms: s32 = 100) {
    flush_stdout();
    flush_stderr();
    sleep_milliseconds(wait_ms);
}

// Escape single quotes in a string for safe shell usage
// Replaces ' with '\'' (end quote, escaped quote, start quote)
escape_single_quotes :: (str: string) -> string {
    // Count single quotes to allocate the right size
    quote_count := 0;
    for i: 0..str.count-1 {
        if str[i] == #char "'" {
            quote_count += 1;
        }
    }

    // If no quotes, return copy
    if quote_count == 0 return copy_string(str);

    // Allocate space for original + 3 extra chars per quote ('\'' becomes 4 chars total)
    result: String_Builder;

    for i: 0..str.count-1 {
        c := str[i];
        if c == #char "'" {
            // Replace ' with '\''
            append(*result, "'\\''");
        } else {
            append(*result, c);
        }
    }

    return builder_to_string(*result);
}

// Extract text content from a Claude stream-json line
// Returns the text if found, empty string otherwise
// Stream JSON format produces lines like:
// {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}
extract_text_from_stream_json :: (line: string) -> string, bool {
    success, json := json_parse_string(line);
    if !success return "", false;
    defer json_free(json);

    if json.type != .OBJECT return "", false;

    // Check if this is a stream_event with text_delta
    type_found, type_val := table_find(json.object, "type");
    if !type_found || type_val.type != .STRING return "", false;
    if type_val.str != "stream_event" return "", false;

    // Get the event object
    event_found, event_val := table_find(json.object, "event");
    if !event_found || event_val.type != .OBJECT return "", false;

    // Check event type is content_block_delta
    event_type_found, event_type_val := table_find(event_val.object, "type");
    if !event_type_found || event_type_val.type != .STRING return "", false;
    if event_type_val.str != "content_block_delta" return "", false;

    // Get the delta object
    delta_found, delta_val := table_find(event_val.object, "delta");
    if !delta_found || delta_val.type != .OBJECT return "", false;

    // Check delta type is text_delta
    delta_type_found, delta_type_val := table_find(delta_val.object, "type");
    if !delta_type_found || delta_type_val.type != .STRING return "", false;
    if delta_type_val.str != "text_delta" return "", false;

    // Extract the text
    text_found, text_val := table_find(delta_val.object, "text");
    if !text_found || text_val.type != .STRING return "", false;

    return copy_string(text_val.str), true;
}

// Extract final result text from stream-json result message
// {"type":"result","subtype":"success",...,"result":"the text here",...}
extract_result_from_stream_json :: (line: string) -> string, bool {
    success, json := json_parse_string(line);
    if !success return "", false;
    defer json_free(json);

    if json.type != .OBJECT return "", false;

    // Check if this is a result message
    type_found, type_val := table_find(json.object, "type");
    if !type_found || type_val.type != .STRING return "", false;
    if type_val.str != "result" return "", false;

    // Get the result text
    result_found, result_val := table_find(json.object, "result");
    if !result_found || result_val.type != .STRING return "", false;

    return copy_string(result_val.str), true;
}

// Clean terminal output by removing binary/garbled data and bash warnings
// The script command captures raw terminal output which can include control characters,
// binary data, and stderr warnings mixed with stdout
clean_terminal_output :: (input: string) -> string {
    builder: String_Builder;

    lines := split(input, "\n");
    first_line := true;

    for line: lines {
        // Skip bash heredoc warnings that get mixed into output
        if contains(line, "here-document") && contains(line, "delimited by end-of-file") continue;
        if contains(line, "wanted") && contains(line, "CLAUDE_INPUT_EOF") continue;

        // Skip lines that are mostly non-printable (binary/garbled data)
        printable_count := 0;
        high_byte_count := 0;  // Count bytes >= 128 (non-ASCII)
        total_count := 0;
        for i: 0..line.count-1 {
            c := line[i];
            total_count += 1;
            // Count printable ASCII
            if (c >= 32 && c < 127) || c == #char "\t" || c == #char "\r" {
                printable_count += 1;
            }
            // Count high bytes that are likely part of binary/garbled data
            if cast,no_check(u8)c >= 128 {
                high_byte_count += 1;
            }
        }

        // Skip lines where less than 50% is printable (likely binary)
        if total_count > 0 && printable_count * 100 / total_count < 50 continue;

        // Skip lines with more than 10% high bytes (likely contains garbled/binary data)
        if total_count > 0 && high_byte_count * 100 / total_count > 10 continue;

        // Add newline between lines
        if !first_line {
            append(*builder, "\n");
        }
        first_line = false;

        // Copy the line, filtering out non-printable and high-byte characters
        // Also skip ANSI escape sequences (ESC [ ... m)
        i := 0;
        while i < line.count {
            c := line[i];
            // Check for ANSI escape sequence: ESC (0x1B) followed by '['
            if c == 0x1B && i + 1 < line.count && line[i + 1] == #char "[" {
                // Skip until we find a letter (command terminator)
                i += 2;
                while i < line.count {
                    tc := line[i];
                    i += 1;
                    if (tc >= #char "A" && tc <= #char "Z") || (tc >= #char "a" && tc <= #char "z") {
                        break;
                    }
                }
                continue;
            }
            // Only keep printable ASCII and tab
            if (c >= 32 && c < 127) || c == #char "\t" {
                append(*builder, c);
            }
            i += 1;
        }
    }

    return builder_to_string(*builder);
}

// Helper to run a Claude command via script with proper shell and flushing
// Returns: result, stdout, stderr, timed_out
run_claude_via_script :: (command: string, headless_mode: bool, skip_perms: bool, timeout_ms: int) -> Process_Result, string, string, bool {
    // Use a here-document approach to safely pass arbitrary text to Claude
    // This avoids all quoting issues with special characters

    // Build the claude command using bash here-document syntax
    use_skip_perms := skip_perms || headless_mode;

    claude_flags := ifx use_skip_perms then "--dangerously-skip-permissions -p" else "-p";

    // Use a here-document to pass the command safely
    // Generate a unique delimiter that doesn't appear in the command text
    // This prevents issues when checking output that contains the delimiter
    base_delimiter := "CLAUDE_INPUT_EOF";
    delimiter := base_delimiter;
    suffix := 0;
    while contains(command, delimiter) {
        suffix += 1;
        delimiter = sprint("%_%", base_delimiter, suffix);
    }
    defer if suffix > 0 then free(delimiter);

    // Ensure command ends with newline for heredoc - bash requires the delimiter
    // to be on its own line, so if content doesn't end with \n, the delimiter
    // won't be recognized and we get "here-document delimited by end-of-file"
    command_with_newline := command;
    allocated_newline := false;
    if command.count > 0 && command[command.count - 1] != #char "\n" {
        command_with_newline = sprint("%\n", command);
        allocated_newline = true;
    }
    defer if allocated_newline then free(command_with_newline);

    script_cmd: string;
    if headless_mode {
        script_cmd = sprint(#string HEREDOC
env IS_SANDBOX=1 claude % << '%'
%
%
HEREDOC, claude_flags, delimiter, command_with_newline, delimiter);
    } else {
        script_cmd = sprint(#string HEREDOC
claude % << '%'
%
%
HEREDOC, claude_flags, delimiter, command_with_newline, delimiter);
    }
    defer free(script_cmd);

    // Run with SHELL=/bin/bash to avoid zsh interpretation issues
    result, out_str, err_str, timed_out := run_command(
        "env", "SHELL=/bin/bash", "script", "-q", "-c",
        script_cmd,
        "/dev/null",
        capture_and_return_output = true,
        timeout_ms = timeout_ms
    );

    // Immediately flush to prevent buffered output from being sent to parent shell
    flush_and_wait(50);

    return result, out_str, err_str, timed_out;
}

BASE_OUTPUT_DIR :: "claude_runs";
DEFAULT_TIMEOUT_MINUTES :: 60;

// Generate a timestamp string for output folder naming (YYYY-MM-DD_HH-MM-SS)
get_output_folder_timestamp :: () -> string {
    now := current_time_consensus();
    cal := to_calendar(now, .LOCAL);
    return sprint("%-%-%_%-%-%",
        formatInt(cal.year, minimum_digits=4),
        formatInt(cal.month_starting_at_0 + 1, minimum_digits=2),
        formatInt(cal.day_of_month_starting_at_0 + 1, minimum_digits=2),
        formatInt(cal.hour, minimum_digits=2),
        formatInt(cal.minute, minimum_digits=2),
        formatInt(cal.second, minimum_digits=2));
}

// Rate limit detection and handling
// Detects messages like: "5-hour limit reached · resets 1pm (Australia/Brisbane)"
// Returns: reset_time_string (e.g. "1pm"), timezone (e.g. "Australia/Brisbane"), found
parse_rate_limit_message :: (text: string) -> string, string, bool {
    // Look for patterns like "limit reached" and "resets Xpm/am"
    // The format is: "X-hour limit reached · resets TIME (TIMEZONE)"

    // First check if this looks like a rate limit message
    if !contains(text, "limit reached") return "", "", false;
    if !contains(text, "resets") return "", "", false;

    // Find the reset time - look for "resets " followed by time
    reset_pos := find_index_from_left(text, "resets ");
    if reset_pos == -1 return "", "", false;

    // Skip past "resets "
    time_start := reset_pos + 7;  // length of "resets "
    if time_start >= text.count return "", "", false;

    // Parse the time (e.g. "1pm", "12am", "3:30pm")
    time_end := time_start;
    while time_end < text.count {
        c := text[time_end];
        // Time can contain digits, ':', 'a', 'p', 'm'
        if (c >= #char "0" && c <= #char "9") || c == #char ":" || c == #char "a" || c == #char "p" || c == #char "m" {
            time_end += 1;
        } else {
            break;
        }
    }

    if time_end == time_start return "", "", false;

    reset_time: string;
    reset_time.data = text.data + time_start;
    reset_time.count = time_end - time_start;

    // Now look for timezone in parentheses
    paren_start := find_index_from_left(text, "(", time_end);
    if paren_start == -1 return copy_string(reset_time), "", true;

    paren_end := find_index_from_left(text, ")", paren_start);
    if paren_end == -1 return copy_string(reset_time), "", true;

    timezone: string;
    timezone.data = text.data + paren_start + 1;
    timezone.count = paren_end - paren_start - 1;

    return copy_string(reset_time), copy_string(timezone), true;
}

// Parse a time string like "1pm", "12:30am" into hours and minutes (24-hour format)
// Returns: hours (0-23), minutes (0-59), success
parse_time_string :: (time_str: string) -> int, int, bool {
    if time_str.count == 0 return 0, 0, false;

    hours := 0;
    minutes := 0;
    is_pm := false;
    is_am := false;

    // Parse the time string character by character
    i := 0;

    // Parse hours
    while i < time_str.count {
        c := time_str[i];
        if c >= #char "0" && c <= #char "9" {
            hours = hours * 10 + cast(int)(c - #char "0");
            i += 1;
        } else {
            break;
        }
    }

    // Check for colon (minutes follow)
    if i < time_str.count && time_str[i] == #char ":" {
        i += 1;
        // Parse minutes
        while i < time_str.count {
            c := time_str[i];
            if c >= #char "0" && c <= #char "9" {
                minutes = minutes * 10 + cast(int)(c - #char "0");
                i += 1;
            } else {
                break;
            }
        }
    }

    // Check for am/pm
    remaining: string;
    remaining.data = time_str.data + i;
    remaining.count = time_str.count - i;

    if contains(remaining, "pm") || contains(remaining, "PM") {
        is_pm = true;
    } else if contains(remaining, "am") || contains(remaining, "AM") {
        is_am = true;
    }

    // Convert to 24-hour format
    if is_pm && hours != 12 {
        hours += 12;
    } else if is_am && hours == 12 {
        hours = 0;
    }

    // Validate
    if hours < 0 || hours > 23 return 0, 0, false;
    if minutes < 0 || minutes > 59 return 0, 0, false;

    return hours, minutes, true;
}

// Calculate seconds until a given time (in hours:minutes, 24-hour format)
// If the time has already passed today, assumes it's tomorrow
// Returns seconds to wait
calculate_seconds_until :: (target_hours: int, target_minutes: int) -> int {
    // Get current time
    now := current_time_consensus();
    cal := to_calendar(now, .LOCAL);

    current_hours := cal.hour;
    current_minutes := cal.minute;
    current_seconds := cal.second;

    // Calculate target time in seconds from midnight
    target_seconds_from_midnight := target_hours * 3600 + target_minutes * 60;
    current_seconds_from_midnight := current_hours * 3600 + current_minutes * 60 + current_seconds;

    seconds_to_wait := target_seconds_from_midnight - current_seconds_from_midnight;

    // If target time has passed, wait until tomorrow
    if seconds_to_wait <= 0 {
        seconds_to_wait += 24 * 3600;  // Add a day
    }

    // Add a small buffer (2 minutes) to ensure the limit has actually reset
    seconds_to_wait += 120;

    return seconds_to_wait;
}

// Format seconds into a human-readable string (e.g. "2h 30m 15s")
format_duration :: (seconds: int) -> string {
    hours := seconds / 3600;
    remaining := seconds % 3600;
    mins := remaining / 60;
    secs := remaining % 60;

    if hours > 0 {
        return sprint("%h %m %s", hours, mins, secs);
    } else if mins > 0 {
        return sprint("%m %s", mins, secs);
    } else {
        return sprint("%s", secs);
    }
}

// Sleep until rate limit resets, printing countdown every 5 minutes
// Returns true if we slept successfully, false if something went wrong
wait_for_rate_limit_reset :: (reset_time_str: string, timezone_str: string) -> bool {
    hours, minutes, time_ok := parse_time_string(reset_time_str);
    if !time_ok {
        print("% ERROR: Could not parse reset time '%'\n", get_timestamp(), reset_time_str);
        return false;
    }

    seconds_to_wait := calculate_seconds_until(hours, minutes);

    print("% === RATE LIMIT REACHED ===\n", get_timestamp());
    print("% Reset time: % (%)\n", get_timestamp(), reset_time_str, ifx timezone_str.count > 0 then timezone_str else "local time");
    print("% Waiting % before retrying...\n", get_timestamp(), format_duration(seconds_to_wait));
    print("% Will print status every 5 minutes.\n", get_timestamp());
    print("% ==========================\n\n", get_timestamp());
    flush_stdout();

    FIVE_MINUTES :: 5 * 60;  // 300 seconds

    while seconds_to_wait > 0 {
        // Sleep for up to 5 minutes at a time
        sleep_duration := min(seconds_to_wait, FIVE_MINUTES);
        sleep_milliseconds(cast(s32)(sleep_duration * 1000));
        seconds_to_wait -= sleep_duration;

        if seconds_to_wait > 0 {
            // Print status update
            print("% Rate limit wait: % remaining until work continues\n",
                  get_timestamp(), format_duration(seconds_to_wait));
            flush_stdout();
        }
    }

    print("% === RATE LIMIT WAIT COMPLETE ===\n", get_timestamp());
    print("% Resuming work...\n", get_timestamp());
    print("% ================================\n\n", get_timestamp());
    flush_stdout();

    return true;
}

// Check if output contains a rate limit message
// Returns: is_rate_limited, reset_time, timezone
check_for_rate_limit :: (output: string) -> bool, string, string {
    // Check the output for rate limit patterns
    reset_time, timezone, found := parse_rate_limit_message(output);
    return found, reset_time, timezone;
}

print_usage :: (program_name: string) {
    print("Usage: % [options] \"cmd1\",\"cmd2\",\"cmd3\"\n", program_name);
    print("Example: % \"refactor the utils module\"\n", program_name);
    print("Example: % \"/implement feature\",\"write tests\",\"fix lint\"\n", program_name);
    print("Example: % --timeout 60 \"fix all lint errors\"\n", program_name);
    print("Example: % --live \"step1\",\"step2\"\n", program_name);
    print("Example: % --headless \"task1\",\"task2\"  # full automation, works as root\n", program_name);
    print("\nOptions:\n");
    print("  --timeout <minutes>  Timeout per run in minutes (default: %)\n", DEFAULT_TIMEOUT_MINUTES);
    print("  --live               Stream output in real-time (enables tail -f on log files)\n");
    print("  --skip-perms         Add --dangerously-skip-permissions flag (doesn't work as root)\n");
    print("  --headless           Full automation mode: sets IS_SANDBOX=1 + skip-permissions (works as root)\n");
    print("  --count <n>          Repeat all commands n times (default: 1)\n");
    print("\nCommands are comma-separated. Each command runs claude in print mode (-p).\n");
    print("Output is saved to %/<timestamp>/run_N.txt\n", BASE_OUTPUT_DIR);
}

// Result of a live run
LiveRunResult :: struct {
    exit_code: s32;
    failed_to_launch: bool;
    timeout_reached: bool;
    stdout_output: string;
    stderr_output: string;
}

// Run a command with streaming JSON output parsing
// This uses claude's --output-format stream-json to get real-time output
// We wrap with 'script' to provide a PTY since claude requires one
run_command_streaming :: (log_file: *File, timeout_ms: int, command: string, headless_mode: bool) -> LiveRunResult {
    result: LiveRunResult;

    text_builder: String_Builder;  // Accumulates extracted text
    line_builder: String_Builder;  // Accumulates partial lines

    process: Process;

    // Build the claude command string for script to execute
    // Use stream-json format for real-time streaming with partial messages
    claude_cmd: string;
    if headless_mode {
        claude_cmd = sprint("env IS_SANDBOX=1 claude --dangerously-skip-permissions -p --verbose --output-format stream-json --include-partial-messages '%'", command);
    } else {
        claude_cmd = sprint("claude --dangerously-skip-permissions -p --verbose --output-format stream-json --include-partial-messages '%'", command);
    }

    // Use script to provide a PTY wrapper (claude requires TTY)
    // -q = quiet, -f = flush after write, -c = command
    // Force bash to avoid zsh's aggressive interpretation of special characters
    // Launch the process with output capture
    launched := create_process(*process, "env", "SHELL=/bin/bash", "script", "-qf", "-c", claude_cmd, "/dev/null", capture_and_return_output = true);
    if !launched {
        result.failed_to_launch = true;
        return result;
    }

    start_time := current_time_monotonic();

    // Buffers for reading stdout and stderr
    output_buffer: [4096] u8;
    error_buffer: [4096] u8;

    // Poll and read output until process completes
    while true {
        // Check timeout
        elapsed := to_milliseconds(current_time_monotonic() - start_time);
        if elapsed >= timeout_ms {
            kill_process(*process);
            result.timeout_reached = true;
            break;
        }

        // Calculate remaining timeout for this poll
        remaining_ms := timeout_ms - cast(int)elapsed;
        poll_timeout := min(remaining_ms, 100);  // Poll every 100ms max

        // Read available output from both pipes
        read_success, output_bytes, error_bytes := read_from_process(*process, output_buffer, error_buffer, poll_timeout);

        if output_bytes > 0 {
            chunk: string;
            chunk.data = output_buffer.data;
            chunk.count = output_bytes;

            // Process each complete line in the chunk
            // JSON stream format has one JSON object per line
            remaining := chunk;
            while remaining.count > 0 {
                newline_pos := find_index_from_left(remaining, #char "\n");
                if newline_pos == -1 {
                    // No complete line yet, buffer for later
                    append(*line_builder, remaining);
                    break;
                }

                // Extract the line (including any buffered content)
                line_part: string;
                line_part.data = remaining.data;
                line_part.count = newline_pos;

                full_line: string;
                if builder_string_length(*line_builder) > 0 {
                    append(*line_builder, line_part);
                    full_line = builder_to_string(*line_builder);
                    reset(*line_builder);
                } else {
                    full_line = copy_string(line_part);
                }

                // Try to extract text from this JSON line
                text, found := extract_text_from_stream_json(full_line);
                if found && text.count > 0 {
                    // Write extracted text to console and log file
                    write_string(text);
                    flush_stdout();
                    file_write(log_file, text);
                    file_flush(<<log_file);
                    append(*text_builder, text);
                    free(text);
                } else {
                    // Try to extract final result
                    result_text, result_found := extract_result_from_stream_json(full_line);
                    if result_found {
                        // Don't print result (already streamed), but store it
                        free(result_text);
                    }
                }

                free(full_line);

                // Move past the newline
                remaining.data += newline_pos + 1;
                remaining.count -= newline_pos + 1;
            }
        }

        if error_bytes > 0 {
            chunk: string;
            chunk.data = error_buffer.data;
            chunk.count = error_bytes;
            // Write stderr to console and log
            write_string(chunk, to_standard_error = true);
            flush_stderr();
            file_write(log_file, "[stderr] ");
            file_write(log_file, chunk);
            file_flush(<<log_file);
        }

        if !read_success {
            break;
        }

        // Check if both pipes have reached EOF (process finished outputting)
        if process.output.eof && process.error.eof {
            break;
        }
    }

    // Get the process exit status (blocking wait since output is done)
    if !result.timeout_reached {
        proc_success, proc_result := get_process_result(*process, -1);
        if proc_success {
            if proc_result.type == .EXITED {
                result.exit_code = proc_result.exit_code;
            } else if proc_result.type == .SIGNALED {
                result.exit_code = -1;
            }
        }
    }

    deinit(*process);

    result.stdout_output = builder_to_string(*text_builder);
    result.stderr_output = "";

    return result;
}

// Run a command with streaming output to both console and file
run_command_live :: (log_file: *File, timeout_ms: int, args: .. string) -> LiveRunResult {
    result: LiveRunResult;

    stdout_builder: String_Builder;
    stderr_builder: String_Builder;

    process: Process;

    // Launch the process with output capture
    launched := create_process(*process, ..args, capture_and_return_output = true);
    if !launched {
        result.failed_to_launch = true;
        return result;
    }

    start_time := current_time_monotonic();

    // Buffers for reading stdout and stderr
    output_buffer: [4096] u8;
    error_buffer: [4096] u8;

    // Poll and read output until process completes
    // The loop exits when both stdout and stderr reach EOF (process closed its output)
    while true {
        // Check timeout
        elapsed := to_milliseconds(current_time_monotonic() - start_time);
        if elapsed >= timeout_ms {
            kill_process(*process);
            result.timeout_reached = true;
            break;
        }

        // Calculate remaining timeout for this poll
        remaining_ms := timeout_ms - cast(int)elapsed;
        poll_timeout := min(remaining_ms, 100);  // Poll every 100ms max

        // Read available output from both pipes
        // read_from_process uses poll() internally and sets eof flags when pipes close
        read_success, output_bytes, error_bytes := read_from_process(*process, output_buffer, error_buffer, poll_timeout);

        if output_bytes > 0 {
            chunk: string;
            chunk.data = output_buffer.data;
            chunk.count = output_bytes;
            // Write to console and flush immediately
            write_string(chunk);
            flush_stdout();
            // Write to log file and flush for tail -f
            file_write(log_file, chunk);
            file_flush(<<log_file);
            // Accumulate for final output
            append(*stdout_builder, chunk);
        }

        if error_bytes > 0 {
            chunk: string;
            chunk.data = error_buffer.data;
            chunk.count = error_bytes;
            // Write to console (stderr) and flush
            write_string(chunk, to_standard_error = true);
            flush_stderr();
            // Write to log file and flush
            file_write(log_file, "[stderr] ");
            file_write(log_file, chunk);
            file_flush(<<log_file);
            // Accumulate for final output
            append(*stderr_builder, chunk);
        }

        if !read_success {
            break;
        }

        // Check if both pipes have reached EOF (process finished outputting)
        if process.output.eof && process.error.eof {
            break;
        }
    }

    // Get the process exit status (blocking wait since output is done)
    if !result.timeout_reached {
        proc_success, proc_result := get_process_result(*process, -1);
        if proc_success {
            if proc_result.type == .EXITED {
                result.exit_code = proc_result.exit_code;
            } else if proc_result.type == .SIGNALED {
                result.exit_code = -1;
            }
        }
    }

    deinit(*process);

    result.stdout_output = builder_to_string(*stdout_builder);
    result.stderr_output = builder_to_string(*stderr_builder);

    return result;
}

// Result of a check operation
CheckResult :: struct {
    success: bool;           // Whether the original command succeeded according to Claude
    check_failed: bool;      // Whether the check itself failed to run
    reasoning: string;       // Claude's explanation
}

// Use Claude to analyze output and determine if the command succeeded
// Also saves the check conversation to a log file for debugging
check_output_with_claude :: (command: string, output: string, headless_mode: bool, timeout_ms: int, run_number: int, output_dir: string) -> CheckResult {
    result: CheckResult;

    // Clean and truncate output before sending to Claude
    // This removes binary/garbled data that can confuse the check process
    cleaned_output := clean_terminal_output(output);
    defer free(cleaned_output);

    MAX_OUTPUT_LENGTH :: 50000;
    truncated_output := cleaned_output;
    if cleaned_output.count > MAX_OUTPUT_LENGTH {
        truncated_output.count = MAX_OUTPUT_LENGTH;
    }

    // Build the check prompt
    check_prompt := sprint(#string PROMPT
Analyze the following output from running the command: "%"

Output:
---
%
---

You are being asked to check if the command/work item (designed to be run
iterativley) completed SUCCESSFULLY or FAILED.

IMPORTANT: Respond with EXACTLY one of these two formats:
SUCCESS: <brief explanation of why it succeeded>
FAILURE: <brief explanation of why it failed>

Look for:
- Error messages, exceptions, or stack traces (indicate failure) to connect to claude or network
- Exit codes or status messages from claude
- Completion messages like "done", "completed", "finished"
- If work items intended for completion this iteration of the command e.g updating progress tracker
- Build errors or warnings that indicate problems

Note: we are mainly looking for if the work item was completed, and if we should continue
with the next work iteration, or if we need to have a command run that will finish up
any unfinished work from the previous iteration. It is fine
if additional tasks or todos were created that are intended to be handled in another
iteration

Be strict: if there are errors, exceptions, or clear failure indicators, report FAILURE.
PROMPT, command, truncated_output);

    defer free(check_prompt);

    // Run Claude to check the output
    proc_result, out_str, err_str, timed_out := run_claude_via_script(check_prompt, headless_mode, true, timeout_ms);

    defer free(out_str);
    defer free(err_str);

    // Log the check conversation for debugging
    check_log_filename := sprint("%/run_%_check.txt", output_dir, run_number);
    check_log_content := sprint(
        #string LOG
=== Check Conversation for Run % ===
Original Command: %
Timeout: %

--- Check Prompt ---
%

--- Check Response (stdout) ---
%

--- Check Response (stderr) ---
%

--- Check Result ---
Exit Code: %
Timed Out: %
Failed to Launch: %
=== END CHECK LOG ===
LOG,
        run_number,
        command,
        ifx timed_out then "YES" else "NO",
        check_prompt,
        out_str,
        err_str,
        proc_result.exit_code,
        ifx timed_out then "YES" else "NO",
        ifx proc_result.type == .FAILED_TO_LAUNCH then "YES" else "NO"
    );
    write_entire_file(check_log_filename, check_log_content);
    free(check_log_filename);
    free(check_log_content);

    if proc_result.type == .FAILED_TO_LAUNCH || timed_out || proc_result.exit_code != 0 {
        result.check_failed = true;
        result.reasoning = "Check command failed to execute";
        flush_and_wait();
        return result;
    }

    // Parse the response to determine success/failure
    // First, clean the output to handle binary/garbled data from script command
    response := clean_terminal_output(trim(out_str));
    result.reasoning = copy_string(response);

    // Look for SUCCESS: or FAILURE: at the start of a line
    if contains(response, "SUCCESS:") || contains(response, "SUCCESS\n") {
        // Check if there's also a failure mentioned (Claude might analyze both)
        // Prefer explicit SUCCESS: at start
        lines := split(response, "\n");
        for line: lines {
            trimmed := trim(line);
            if begins_with(trimmed, "SUCCESS:") || trimmed == "SUCCESS" {
                result.success = true;
                flush_and_wait();
                return result;
            }
            if begins_with(trimmed, "FAILURE:") || trimmed == "FAILURE" {
                result.success = false;
                flush_and_wait();
                return result;
            }
        }
        // If we found SUCCESS somewhere but no clear FAILURE, assume success
        result.success = true;
    } else if contains(response, "FAILURE:") || contains(response, "FAILURE\n") || contains(response, "FAILED") {
        result.success = false;
    } else {
        // Couldn't parse response clearly - be conservative and fail
        result.success = false;
        result.reasoning = sprint("Could not parse check response: %", response);
    }

    flush_and_wait();
    return result;
}

main :: () {
    args := get_command_line_arguments();
    defer array_free(args);

    if args.count < 2 {
        print_usage(args[0]);
        return;
    }

    // Parse optional flags and positional arguments
    timeout_minutes := DEFAULT_TIMEOUT_MINUTES;
    live_mode := false;
    skip_perms := false;
    headless_mode := false;
    repeat_count := 1;
    arg_index := 1;

    // Check for flags
    while arg_index < args.count {
        if args[arg_index] == "--timeout" || args[arg_index] == "-t" {
            if arg_index + 1 >= args.count {
                print("Error: --timeout requires a value\n");
                return;
            }
            timeout_val, timeout_ok := parse_positive_int(args[arg_index + 1]);
            if !timeout_ok {
                print("Error: Invalid timeout '%'. Must be a positive integer (minutes).\n", args[arg_index + 1]);
                return;
            }
            timeout_minutes = timeout_val;
            arg_index += 2;
        } else if args[arg_index] == "--live" || args[arg_index] == "-l" {
            live_mode = true;
            arg_index += 1;
        } else if args[arg_index] == "--skip-perms" || args[arg_index] == "-s" {
            skip_perms = true;
            arg_index += 1;
        } else if args[arg_index] == "--headless" || args[arg_index] == "-H" {
            headless_mode = true;
            arg_index += 1;
        } else if args[arg_index] == "--count" || args[arg_index] == "-c" {
            if arg_index + 1 >= args.count {
                print("Error: --count requires a value\n");
                return;
            }
            count_val, count_ok := parse_positive_int(args[arg_index + 1]);
            if !count_ok {
                print("Error: Invalid count '%'. Must be a positive integer.\n", args[arg_index + 1]);
                return;
            }
            repeat_count = count_val;
            arg_index += 2;
        } else if args[arg_index].count > 0 && args[arg_index][0] == #char "-" {
            // Unrecognized flag
            print("Error: Unknown option '%'\n", args[arg_index]);
            print("Valid options: --timeout, --live, --skip-perms, --headless, --count\n");
            return;
        } else {
            break;  // No more flags, rest are positional args
        }
    }

    // Need at least one command after flags
    if args.count - arg_index < 1 {
        print_usage(args[0]);
        return;
    }

    // Build the full command string from remaining arguments (join with spaces)
    commands_str := args[arg_index];
    for i: arg_index+1..args.count-1 {
        commands_str = sprint("% %", commands_str, args[i]);
    }

    // Parse comma-separated commands
    commands: [..] string;
    remaining := commands_str;
    while remaining.count > 0 {
        // Find next comma (but handle quoted strings)
        found_comma := false;
        comma_pos := 0;
        in_quotes := false;
        for i: 0..remaining.count-1 {
            c := remaining[i];
            if c == #char "\"" {
                in_quotes = !in_quotes;
            } else if c == #char "," && !in_quotes {
                comma_pos = i;
                found_comma = true;
                break;
            }
        }

        cmd: string;
        if found_comma {
            cmd.data = remaining.data;
            cmd.count = comma_pos;
            remaining.data += comma_pos + 1;
            remaining.count -= comma_pos + 1;
        } else {
            cmd = remaining;
            remaining.count = 0;
        }

        // Trim whitespace and quotes from cmd
        cmd = trim(cmd);
        if cmd.count >= 2 && cmd[0] == #char "\"" && cmd[cmd.count-1] == #char "\"" {
            cmd.data += 1;
            cmd.count -= 2;
        }

        if cmd.count > 0 {
            array_add(*commands, copy_string(cmd));
        }
    }

    if commands.count == 0 {
        print("Error: No commands provided.\n");
        print_usage(args[0]);
        return;
    }

    count := commands.count;

    // Convert timeout to milliseconds
    timeout_ms := timeout_minutes * 60 * 1000;

    // Create output directory with timestamp subfolder
    run_timestamp := get_output_folder_timestamp();
    output_dir := sprint("%/%", BASE_OUTPUT_DIR, run_timestamp);

    print("% === Claude Code Automation ===\n", get_timestamp());
    print("% Commands: % total\n", get_timestamp(), count);
    for cmd, i: commands {
        print("%   [%] %\n", get_timestamp(), i + 1, cmd);
    }
    print("% Repeat count: %\n", get_timestamp(), repeat_count);
    print("% Total runs: % (% commands x % iterations)\n", get_timestamp(), count * repeat_count, count, repeat_count);
    print("% Timeout: % minutes per run\n", get_timestamp(), timeout_minutes);
    print("% Live mode: %\n", get_timestamp(), ifx live_mode then "YES (streaming output)" else "NO");
    print("% Skip permissions: %\n", get_timestamp(), ifx skip_perms then "YES" else "NO");
    print("% Headless mode: %\n", get_timestamp(), ifx headless_mode then "YES (IS_SANDBOX=1 + skip-perms)" else "NO");
    print("% Output directory: %/\n", get_timestamp(), output_dir);
    print("% ==============================\n\n", get_timestamp());

    // Create output directories if they don't exist
    make_directory_if_it_does_not_exist(BASE_OUTPUT_DIR);
    make_directory_if_it_does_not_exist(output_dir);

    completed_runs := 0;
    total_time_seconds: float64 = 0;
    total_runs := count * repeat_count;
    global_run := 0;  // Global run counter across all iterations

    for iteration: 1..repeat_count {
        if repeat_count > 1 {
            print("% === Iteration %/% ===\n", get_timestamp(), iteration, repeat_count);
        }

        for run: 1..count {
            global_run += 1;
            command := commands[run - 1];
            print("% [Run %/% (iter %/%)] Starting: %\n", get_timestamp(), global_run, total_runs, iteration, repeat_count, command);

            output_filename := sprint("%/run_%.txt", output_dir, global_run);

            // Record start time
            start_time := current_time_monotonic();

            // Variables to hold results
            exit_code: s32 = 0;
            failed_to_launch := false;
            timeout_reached := false;
            output_string: string;
            error_string: string;

            if live_mode {
                // Live mode: stream output to console and file using JSON streaming
                log_file, ok := file_open(output_filename, for_writing = true);
                if !ok {
                    print("% [Run %/%] ERROR: Failed to open log file: %\n", get_timestamp(), global_run, total_runs, output_filename);
                    return;
                }

                // Write header to log file
                header := sprint("=== Claude Run % of % (LIVE STREAMING) ===\nCommand: %\n=========================\n\n", global_run, total_runs, command);
                file_write(*log_file, header);
                free(header);

                print("% --- Live streaming output (also writing to %) ---\n", get_timestamp(), output_filename);

                // Use the new streaming function that parses JSON stream format
                live_result := run_command_streaming(
                    *log_file,
                    timeout_ms,
                    command,
                    headless_mode || skip_perms
                );

                exit_code = live_result.exit_code;
                failed_to_launch = live_result.failed_to_launch;
                timeout_reached = live_result.timeout_reached;
                output_string = live_result.stdout_output;
                error_string = live_result.stderr_output;

                // Write footer to log file
                end_time := current_time_monotonic();
                elapsed := to_float64_seconds(end_time - start_time);
                footer := sprint("\n=== END RUN % (% seconds, exit: %) ===\n", global_run, elapsed, exit_code);
                file_write(*log_file, footer);
                free(footer);

                file_close(*log_file);
                print("% --- End live output ---\n", get_timestamp());
            } else {
                // Normal mode: capture output and write at end
                result, out_str, err_str, timed_out := run_claude_via_script(command, headless_mode, skip_perms, timeout_ms);

                exit_code = result.exit_code;
                failed_to_launch = (result.type == .FAILED_TO_LAUNCH);
                timeout_reached = timed_out;
                output_string = out_str;
                error_string = err_str;
            }

            // Calculate elapsed time
            end_time := current_time_monotonic();
            elapsed_seconds := to_float64_seconds(end_time - start_time);

            // Write output to file (for non-live mode, or update for live mode summary)
            if !live_mode {
                output_content := sprint(
                    #string CONTENT
=== Claude Run % of % ===
Command: %
Exit Code: %
Timeout: %
Duration: % seconds
=========================

--- STDOUT ---
%

--- STDERR ---
%

=== END RUN % (% seconds) ===
CONTENT,
                    global_run, total_runs,
                    command,
                    exit_code,
                    ifx timeout_reached then "YES" else "NO",
                    elapsed_seconds,
                    output_string,
                    error_string,
                    global_run, elapsed_seconds
                );

                write_success := write_entire_file(output_filename, output_content);

                if !write_success {
                    print("% [Run %/%] ERROR: Failed to write output file: %\n", get_timestamp(), global_run, total_runs, output_filename);
                } else {
                    print("% [Run %/%] Output saved to: %\n", get_timestamp(), global_run, total_runs, output_filename);
                }

                free(output_content);
            } else {
                print("% [Run %/%] Output saved to: %\n", get_timestamp(), global_run, total_runs, output_filename);
            }

            free(output_filename);

            // Check for failure conditions
            if failed_to_launch {
                print("% !!! FAILURE !!!\n", get_timestamp());
                print("% Run % FAILED: Could not launch claude command.\n", get_timestamp(), global_run);
                print("% Make sure 'claude' is installed and in your PATH.\n", get_timestamp());
                print("% Completed runs: %\n", get_timestamp(), completed_runs);
                print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                flush_and_wait();
                return;
            }

            if timeout_reached {
                print("% !!! FAILURE !!!\n", get_timestamp());
                print("% Run % FAILED: Command timed out after % minutes.\n", get_timestamp(), global_run, timeout_minutes);
                print("% Completed runs: %\n", get_timestamp(), completed_runs);
                print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                flush_and_wait();
                return;
            }

            if exit_code != 0 {
                print("% !!! FAILURE !!!\n", get_timestamp());
                print("% Run % FAILED: Exit code %\n", get_timestamp(), global_run, exit_code);
                print("% Check %/run_%.txt for details.\n", get_timestamp(), output_dir, global_run);
                print("% Completed runs: %\n", get_timestamp(), completed_runs);
                print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                flush_and_wait();
                return;
            }

            // Use Claude to verify the output succeeded
            {
                print("% [Run %/%] Checking output with Claude...\n", get_timestamp(), global_run, total_runs);

                check_result := check_output_with_claude(command, output_string, headless_mode, timeout_ms, global_run, output_dir);

                if check_result.check_failed {
                    // Check if this is a rate limit issue - look in the reasoning (which contains the raw output)
                    is_rate_limited, reset_time, timezone := check_for_rate_limit(check_result.reasoning);

                    if is_rate_limited {
                        // Wait for rate limit to reset and then retry the current run
                        waited := wait_for_rate_limit_reset(reset_time, timezone);
                        free(reset_time);
                        if timezone.count > 0 free(timezone);

                        if waited {
                            // Retry this run from the beginning by decrementing loop counter
                            // We use continue with run-=1 pattern, but since for loop increments,
                            // we need to handle this differently - we'll re-run the same command
                            print("% [Run %/%] Retrying after rate limit wait...\n", get_timestamp(), global_run, total_runs);
                            free(check_result.reasoning);

                            // Re-run the same command by jumping back (using goto equivalent - continue with adjustment)
                            // Since Jai doesn't have goto, we'll need to restructure - for now, just continue
                            // which will move to the next iteration. Instead, let's use a different approach:
                            // We'll make the outer loop a while loop with manual increment control.
                            // For now, we'll just retry inline here.

                            // Re-execute the check after waiting
                            print("% [Run %/%] Re-checking output with Claude after rate limit...\n", get_timestamp(), global_run, total_runs);
                            check_result = check_output_with_claude(command, output_string, headless_mode, timeout_ms, global_run, output_dir);

                            // If still failing, fall through to the error handling below
                            if !check_result.check_failed {
                                // Check succeeded after rate limit wait - continue with result
                                if check_result.success {
                                    print("% [Run %/%] AI verification: SUCCESS (after rate limit wait)\n", get_timestamp(), global_run, total_runs);
                                    print("% [Run %/%] Check log saved to: %/run_%_check.txt\n", get_timestamp(), global_run, total_runs, output_dir, global_run);
                                    free(check_result.reasoning);
                                    // Continue to success path
                                    completed_runs += 1;
                                    total_time_seconds += elapsed_seconds;
                                    print("% [Run %/%] Completed in % seconds (exit code: %)\n\n", get_timestamp(), global_run, total_runs, elapsed_seconds, exit_code);
                                    continue;  // Move to next run
                                }
                                // If !success, fall through to retry logic below
                            }
                        }
                    }

                    // If we get here, either not rate limited or rate limit handling failed
                    if check_result.check_failed {
                        print("% !!! CHECK FAILED !!!\n", get_timestamp());
                        print("% Run % check could not be performed: %\n", get_timestamp(), global_run, check_result.reasoning);
                        print("% Stopping execution as we cannot verify success.\n", get_timestamp());
                        print("% Completed runs: %\n", get_timestamp(), completed_runs);
                        print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                        flush_and_wait();
                        return;
                    }
                }

                if !check_result.success {
                    print("% !!! AI VERIFICATION FAILED !!!\n", get_timestamp());
                    print("% Run % did NOT complete successfully according to Claude.\n", get_timestamp(), global_run);
                    print("% Reason: %\n", get_timestamp(), check_result.reasoning);
                    print("% Check %/run_%.txt for details.\n", get_timestamp(), output_dir, global_run);

                    // Attempt automatic recovery by running a retry command
                    print("% [Run %/%] Attempting automatic recovery...\n", get_timestamp(), global_run, total_runs);

                    // Build recovery command that tells Claude to continue the incomplete work
                    // Note: We don't include the original command string to avoid quoting issues
                    recovery_command := sprint("The previous command did not complete successfully. Read %/run_%.txt to see what was attempted and what may have been completed already. Continue the work from where it left off and complete any remaining tasks.", output_dir, global_run);
                    defer free(recovery_command);

                    retry_output_filename := sprint("%/run_%_retry.txt", output_dir, global_run);
                    retry_start_time := current_time_monotonic();

                    // Variables for retry run
                    retry_exit_code: s32 = 0;
                    retry_failed_to_launch := false;
                    retry_timeout_reached := false;
                    retry_output_string: string;
                    retry_error_string: string;

                    if live_mode {
                        // Live mode retry with streaming
                        retry_log_file, retry_ok := file_open(retry_output_filename, for_writing = true);
                        if !retry_ok {
                            print("% [Run %/%] ERROR: Failed to open retry log file: %\n", get_timestamp(), global_run, total_runs, retry_output_filename);
                            print("% Stopping execution.\n", get_timestamp());
                            print("% Completed runs: %\n", get_timestamp(), completed_runs);
                            print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                            flush_and_wait();
                            return;
                        }

                        retry_header := sprint("=== Claude Run % of % (RETRY - LIVE STREAMING) ===\nOriginal Command: %\nRecovery Command: %\n=========================\n\n", global_run, total_runs, command, recovery_command);
                        file_write(*retry_log_file, retry_header);
                        free(retry_header);

                        print("% --- Live streaming retry output (also writing to %) ---\n", get_timestamp(), retry_output_filename);

                        retry_live_result := run_command_streaming(
                            *retry_log_file,
                            timeout_ms,
                            recovery_command,
                            headless_mode || skip_perms
                        );

                        retry_exit_code = retry_live_result.exit_code;
                        retry_failed_to_launch = retry_live_result.failed_to_launch;
                        retry_timeout_reached = retry_live_result.timeout_reached;
                        retry_output_string = retry_live_result.stdout_output;
                        retry_error_string = retry_live_result.stderr_output;

                        retry_end_time := current_time_monotonic();
                        retry_elapsed := to_float64_seconds(retry_end_time - retry_start_time);
                        retry_footer := sprint("\n=== END RETRY RUN % (% seconds, exit: %) ===\n", global_run, retry_elapsed, retry_exit_code);
                        file_write(*retry_log_file, retry_footer);
                        free(retry_footer);

                        file_close(*retry_log_file);
                        print("% --- End retry output ---\n", get_timestamp());
                    } else {
                        // Normal mode retry
                        retry_result, retry_out_str, retry_err_str, retry_timed_out := run_claude_via_script(recovery_command, headless_mode, skip_perms, timeout_ms);

                        retry_exit_code = retry_result.exit_code;
                        retry_failed_to_launch = (retry_result.type == .FAILED_TO_LAUNCH);
                        retry_timeout_reached = retry_timed_out;
                        retry_output_string = retry_out_str;
                        retry_error_string = retry_err_str;
                    }

                    retry_end_time := current_time_monotonic();
                    retry_elapsed_seconds := to_float64_seconds(retry_end_time - retry_start_time);

                    // Write retry output if not in live mode
                    if !live_mode {
                        retry_output_content := sprint(
                            #string CONTENT
=== Claude Run % of % (RETRY) ===
Original Command: %
Recovery Command: %
Exit Code: %
Timeout: %
Duration: % seconds
=========================

--- STDOUT ---
%

--- STDERR ---
%

=== END RETRY RUN % (% seconds) ===
CONTENT,
                            global_run, total_runs,
                            command,
                            recovery_command,
                            retry_exit_code,
                            ifx retry_timeout_reached then "YES" else "NO",
                            retry_elapsed_seconds,
                            retry_output_string,
                            retry_error_string,
                            global_run, retry_elapsed_seconds
                        );

                        write_entire_file(retry_output_filename, retry_output_content);
                        free(retry_output_content);
                    }

                    print("% [Run %/%] Retry output saved to: %\n", get_timestamp(), global_run, total_runs, retry_output_filename);
                    free(retry_output_filename);

                    // Check retry results
                    if retry_failed_to_launch {
                        print("% !!! RETRY FAILED !!!\n", get_timestamp());
                        print("% Run % retry FAILED: Could not launch claude command.\n", get_timestamp(), global_run);
                        print("% Completed runs: %\n", get_timestamp(), completed_runs);
                        print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                        flush_and_wait();
                        return;
                    }

                    if retry_timeout_reached {
                        print("% !!! RETRY FAILED !!!\n", get_timestamp());
                        print("% Run % retry FAILED: Command timed out after % minutes.\n", get_timestamp(), global_run, timeout_minutes);
                        print("% Completed runs: %\n", get_timestamp(), completed_runs);
                        print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                        flush_and_wait();
                        return;
                    }

                    if retry_exit_code != 0 {
                        print("% !!! RETRY FAILED !!!\n", get_timestamp());
                        print("% Run % retry FAILED: Exit code %\n", get_timestamp(), global_run, retry_exit_code);
                        print("% Completed runs: %\n", get_timestamp(), completed_runs);
                        print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                    flush_and_wait();
                    return;
                }

                    // Check the retry output with Claude
                    print("% [Run %/%] Checking retry output with Claude...\n", get_timestamp(), global_run, total_runs);
                    retry_check_result := check_output_with_claude(recovery_command, retry_output_string, headless_mode, timeout_ms, global_run, output_dir);

                    if retry_check_result.check_failed {
                        // Check if this is a rate limit issue
                        retry_is_rate_limited, retry_reset_time, retry_timezone := check_for_rate_limit(retry_check_result.reasoning);

                        if retry_is_rate_limited {
                            waited := wait_for_rate_limit_reset(retry_reset_time, retry_timezone);
                            free(retry_reset_time);
                            if retry_timezone.count > 0 free(retry_timezone);

                            if waited {
                                print("% [Run %/%] Re-checking retry output after rate limit...\n", get_timestamp(), global_run, total_runs);
                                free(retry_check_result.reasoning);
                                retry_check_result = check_output_with_claude(recovery_command, retry_output_string, headless_mode, timeout_ms, global_run, output_dir);

                                if !retry_check_result.check_failed {
                                    if retry_check_result.success {
                                        print("% [Run %/%] Retry verification: SUCCESS (after rate limit wait)\n", get_timestamp(), global_run, total_runs);
                                        print("% [Run %/%] Work completed after retry!\n", get_timestamp(), global_run, total_runs);
                                        free(retry_check_result.reasoning);
                                        total_time_seconds += retry_elapsed_seconds;
                                        // Skip to success path - need to break out of retry logic
                                        // Set a flag or use different flow
                                        completed_runs += 1;
                                        total_time_seconds += elapsed_seconds;
                                        print("% [Run %/%] Completed in % seconds (exit code: %)\n\n", get_timestamp(), global_run, total_runs, elapsed_seconds, exit_code);
                                        continue;  // Move to next run
                                    }
                                    // Fall through to retry verification failed
                                }
                            }
                        }

                        if retry_check_result.check_failed {
                            print("% !!! RETRY CHECK FAILED !!!\n", get_timestamp());
                            print("% Run % retry check could not be performed: %\n", get_timestamp(), global_run, retry_check_result.reasoning);
                            print("% Stopping execution.\n", get_timestamp());
                            print("% Completed runs: %\n", get_timestamp(), completed_runs);
                            print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                            flush_and_wait();
                            return;
                        }
                    }

                    if !retry_check_result.success {
                        // Check if the failure reason contains rate limit info
                        fail_is_rate_limited, fail_reset_time, fail_timezone := check_for_rate_limit(retry_check_result.reasoning);

                        if fail_is_rate_limited {
                            waited := wait_for_rate_limit_reset(fail_reset_time, fail_timezone);
                            free(fail_reset_time);
                            if fail_timezone.count > 0 free(fail_timezone);

                            if waited {
                                print("% [Run %/%] Re-checking retry output after rate limit...\n", get_timestamp(), global_run, total_runs);
                                free(retry_check_result.reasoning);
                                retry_check_result = check_output_with_claude(recovery_command, retry_output_string, headless_mode, timeout_ms, global_run, output_dir);

                                if !retry_check_result.check_failed && retry_check_result.success {
                                    print("% [Run %/%] Retry verification: SUCCESS (after rate limit wait)\n", get_timestamp(), global_run, total_runs);
                                    print("% [Run %/%] Work completed after retry!\n", get_timestamp(), global_run, total_runs);
                                    free(retry_check_result.reasoning);
                                    total_time_seconds += retry_elapsed_seconds;
                                    completed_runs += 1;
                                    total_time_seconds += elapsed_seconds;
                                    print("% [Run %/%] Completed in % seconds (exit code: %)\n\n", get_timestamp(), global_run, total_runs, elapsed_seconds, exit_code);
                                    continue;  // Move to next run
                                }
                            }
                        }

                        print("% !!! RETRY VERIFICATION FAILED !!!\n", get_timestamp());
                        print("% Run % retry did NOT complete successfully according to Claude.\n", get_timestamp(), global_run);
                        print("% Reason: %\n", get_timestamp(), retry_check_result.reasoning);
                        print("% Stopping execution after failed retry.\n", get_timestamp());
                        print("% Completed runs: %\n", get_timestamp(), completed_runs);
                        print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
                        flush_and_wait();
                        return;
                    }

                    print("% [Run %/%] Retry verification: SUCCESS\n", get_timestamp(), global_run, total_runs);
                    print("% [Run %/%] Work completed after retry!\n", get_timestamp(), global_run, total_runs);
                    free(retry_check_result.reasoning);

                    // Update total time to include retry time
                    total_time_seconds += retry_elapsed_seconds;
                }

                print("% [Run %/%] AI verification: SUCCESS\n", get_timestamp(), global_run, total_runs);
                print("% [Run %/%] Check log saved to: %/run_%_check.txt\n", get_timestamp(), global_run, total_runs, output_dir, global_run);
                free(check_result.reasoning);
            }

            // Success - update counters
            completed_runs += 1;
            total_time_seconds += elapsed_seconds;

            print("% [Run %/%] Completed in % seconds (exit code: %)\n\n",
                  get_timestamp(), global_run, total_runs, elapsed_seconds, exit_code);
        }  // end inner for run
    }  // end outer for iteration

    // All runs completed successfully
    print("% === ALL RUNS COMPLETED ===\n", get_timestamp());
    print("% Total runs: %\n", get_timestamp(), completed_runs);
    print("% Total time: % seconds\n", get_timestamp(), total_time_seconds);
    print("% Average time per run: % seconds\n", get_timestamp(), total_time_seconds / cast(float64) completed_runs);
    print("% ===========================\n", get_timestamp());

    // Write summary file
    // Build commands list for summary
    commands_summary: String_Builder;
    for cmd, i: commands {
        append(*commands_summary, sprint("  [%] %\n", i + 1, cmd));
    }

    summary := sprint(
        #string SUMMARY
Claude Automation Summary
=========================
Commands:
%Repeat count: %
Total runs: % (% commands x % iterations)
Total time: % seconds
Average time per run: % seconds
Status: SUCCESS
SUMMARY,
        builder_to_string(*commands_summary),
        repeat_count,
        completed_runs, count, repeat_count,
        total_time_seconds,
        total_time_seconds / cast(float64) completed_runs
    );

    write_entire_file(sprint("%/summary.txt", output_dir), summary);
    print("% Summary written to %/summary.txt\n", get_timestamp(), output_dir);

    // Ensure all output is flushed before exiting to prevent buffered text
    // from being sent to the parent shell and executed as commands
    flush_and_wait();
}

// Parse a positive integer from a string
// Returns (value, success)
parse_positive_int :: (str: string) -> int, bool {
    if str.count == 0 return 0, false;

    result := 0;
    for i: 0..str.count-1 {
        c := str[i];
        if c < #char "0" || c > #char "9" {
            return 0, false;
        }
        digit := cast(int)(c - #char "0");
        result = result * 10 + digit;
    }

    if result <= 0 return 0, false;
    return result, true;
}
