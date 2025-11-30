# Automate Claude Code

A command-line tool for running multiple Claude Code commands sequentially with automatic retry, rate limit handling, and output verification.

## Overview

`automate-claude` wraps the Claude CLI tool to enable automated, unattended execution of multiple commands. It handles common automation challenges like:

- **Sequential command execution** - Run multiple Claude commands one after another
- **Output verification** - Uses Claude to verify each command completed successfully
- **Automatic retry** - If a command fails, automatically attempts recovery
- **Rate limit handling** - Detects rate limits and waits for reset before continuing
- **Live streaming** - Real-time output streaming with JSON parsing
- **Detailed logging** - Saves all output to timestamped log files

## Installation

### Pre-built Binary

Pre-built static binaries are available on the [releases page](https://github.com/neichler-digital/automate-claude/releases). Currently only tested on Ubuntu.

```bash
./automate-claude --help
```

### Building from Source

Requires the [Jai programming language](https://jai.community/) compiler.

The provided binary was compiled with **Jai version beta 0.2.018** (built on 11 October 2025).

```bash
jai automate-claude.jai
```

This produces the `automate-claude` executable.

### Building with Docker (static executable)

```bash
mkdir -p output

# Build the image
docker build -t automate-claude-builder .

# Run the build (mount Jai compiler and get output)
docker run -v /path/to/jai:/jai -v $(pwd)/output:/output automate-claude-builder
```

## Basic Usage

```bash
# Run a single command
./automate-claude "refactor the utils module"

# Run multiple comma-separated commands
./automate-claude "fix lint errors","run tests","update documentation"

# Use slash commands
./automate-claude "/implement feature","write tests","fix lint"
```

Commands are executed sequentially. If any command fails, execution stops.

## Command-Line Options

| Option | Short | Description | Default |
|--------|-------|-------------|---------|
| `--timeout <minutes>` | `-t` | Timeout per command in minutes | 60 |
| `--live` | `-l` | Stream output in real-time | Off |
| `--skip-perms` | `-s` | Add `--dangerously-skip-permissions` flag | Off |
| `--headless` | `-H` | Full automation mode (sets `IS_SANDBOX=1` + skip-perms) | Off |
| `--count <n>` | `-c` | Repeat all commands n times | 1 |

## Configuration Options Explained

### Timeout (`--timeout`)

Sets the maximum time (in minutes) each command is allowed to run before being killed.

```bash
# Allow up to 2 hours per command for long-running tasks
./automate-claude --timeout 120 "refactor entire codebase"

# Quick timeout for simple commands
./automate-claude --timeout 5 "fix typo in README"
```

Note: At the moment, if any command is killed via timeout the entire program will exit.

### Live Mode (`--live`)

Enables real-time output streaming. When enabled:
- Output is displayed immediately as Claude generates it
- Uses Claude's `--output-format stream-json` for proper streaming
- Output is simultaneously written to log files
- Useful for monitoring long-running tasks

```bash
./automate-claude --live "implement new feature"
```

Without `--live`, output is captured silently and only displayed in the final log files.

### Skip Permissions (`--skip-perms`)

Adds the `--dangerously-skip-permissions` flag to Claude commands. This allows Claude to:
- Execute commands without confirmation prompts
- Write files without asking
- Run potentially destructive operations

**Warning:** Only use this in controlled environments where you trust the commands being executed.

```bash
./automate-claude --skip-perms "format all code files"
```

**Note:** This flag does not work when running as root. Use `--headless` instead.

### Headless Mode (`--headless`)

Full automation mode designed for unattended execution, particularly in Docker containers or CI/CD pipelines or in WSL. When enabled:
- Sets `IS_SANDBOX=1` environment variable
- Automatically enables `--dangerously-skip-permissions`
- Works correctly when running as root

```bash
# Run in a Docker container
./automate-claude --headless "run all tests","fix any failures"

# In a CI/CD pipeline
./automate-claude --headless --timeout 30 "lint code","run tests"
```

### Count (`--count`)

Repeats all commands multiple times. Useful for iterative tasks or ensuring consistency.

```bash
# Run the same workflow 3 times
./automate-claude --count 3 "check for issues","fix issues"

# This runs: check -> fix -> check -> fix -> check -> fix
```

The total number of runs is `number_of_commands * count`.

## Output Directory Structure

All output is saved to `claude_runs/<timestamp>/`:

```
claude_runs/
  2024-01-15_14-30-45/
    run_1.txt          # Output from first command
    run_1_check.txt    # AI verification log for first command
    run_2.txt          # Output from second command
    run_2_check.txt    # AI verification log
    run_2_retry.txt    # Retry output (if retry was needed)
    summary.txt        # Final summary of all runs
```

## How It Works

### Execution Flow

1. **Parse commands** - Split comma-separated command string
2. **Create output directory** - Timestamped folder under `claude_runs/`
3. **For each command:**
   - Run Claude with the command
   - Save output to log file
   - Use Claude to verify success/failure
   - If failed: attempt automatic retry
   - If retry fails: stop execution
4. **Write summary** - Record total time and success status

### AI Verification

After each command, the tool runs a separate Claude instance to analyze the output and determine if the command succeeded. This catches cases where:
- Claude encounters errors but exits with code 0
- Work was partially completed
- Unexpected issues occurred

The verification prompt looks for:
- Error messages and exceptions
- Completion indicators
- Build errors or warnings

### Automatic Retry

If AI verification fails, the tool attempts automatic recovery:

1. Creates a recovery prompt asking Claude to continue from where it left off
2. Points Claude to the previous run's log file for context
3. Runs the recovery command
4. Verifies the retry output

### Rate Limit Handling

The tool detects rate limit messages in the format:
```
5-hour limit reached · resets 1pm (Australia/Brisbane)
```

When detected:
- Calculates wait time until reset
- Prints countdown status every 5 minutes
- Automatically resumes execution after the wait
- Adds a 2-minute buffer after reset time

## Examples

### Basic Automation

```bash
# Single task
./automate-claude "fix all TypeScript errors"

# Multi-step workflow
./automate-claude "analyze codebase","create implementation plan","implement changes"
```

### CI/CD Integration

```bash
# Run in headless mode with timeout
./automate-claude --headless --timeout 30 \
  "run linter","fix lint errors","run tests"
```

### Long-Running Tasks with Monitoring

```bash
# Stream output while running complex refactoring
./automate-claude --live --timeout 120 \
  "refactor authentication module","update all tests","verify no regressions"
```

### Iterative Improvement

```bash
# Keep improving until no more issues (run 5 iterations)
./automate-claude --count 5 --live \
  "find code quality issues","fix one issue"
```

### Docker Usage

```bash
# In Dockerfile or docker run
docker run -v $(pwd):/workspace myimage \
  ./automate-claude --headless "run tests"
```

## Exit Codes

- `0` - All commands completed successfully
- Non-zero - A command failed, timed out, or verification failed

## Troubleshooting

### "Could not launch claude command"
Ensure `claude` is installed and in your PATH:
```bash
which claude
claude --version
```

### Command times out
Increase the timeout:
```bash
./automate-claude --timeout 120 "long running task"
```

### Permission denied errors
Use `--headless` when running as root, or `--skip-perms` otherwise:
```bash
./automate-claude --headless "task requiring permissions"
```

### Rate limit messages
The tool automatically handles rate limits. You can also:
- Use a different API key
- Check your usage limits

## Requirements

- Claude CLI (`claude`) installed and configured
- Jai compiler (for building from source)
- Linux/POSIX environment (uses `script` command for PTY)

## License

See LICENSE file for details.
