# Claude Code Plan Usage Statusline

Status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays model, usage limits, git state, and workspace context in your terminal's status bar.

## Screenshot

![Screenshot](screenshot.svg)

**Real rate limit data.** Other tools count tokens locally from transcript files. This script reads server-side `five_hour` and `seven_day` utilization -- the actual numbers the rate limiter tracks. Claude Code 2.1.241+ pipes that data straight into the status line command's stdin, so no token, keychain read, or network call is needed. Older Claude Code builds, or the script run standalone, fall back to Anthropic's OAuth API.

**No permission prompts.** It's a plain CLI script, not a sandboxed app. On the primary stdin path there's nothing to prompt for -- no keychain access, no network call. On the API fallback, keychain is read by delegating to `/usr/bin/security` -- an Apple-signed system binary that already has Keychain access. The script itself never touches the Security APIs, so macOS has no reason to prompt. Outbound network from CLI doesn't trigger the firewall dialog either.

## Features

- **Model** -- current model name (long-context suffix compacted, e.g. `(1M context)` becomes `·1M`)
- **Effort** -- current effort level appended to the model segment (when set via `/effort`)
- **Context window** -- remaining % from Claude Code's input, color-graded
- **5h usage** -- session headroom with countdown to reset, color-graded (amber at 35% left, red at 15% left); shows `?` when usage data is unavailable instead of a misleading 100%
- **1w usage** -- weekly headroom with reset date, color-graded
- **Goal** -- the session's active `/goal`, when one is set (see [Goal](#goal))
- **Loop status** -- every loop pacing this session and what it works on, derived from its own transcript (see [Loop Status](#loop-status))
- **Cron display** -- this session's other scheduled jobs, with next fire time and cadence (see [Cron Display](#cron-display))
- **Git** -- branch, worktree (when in a git worktree), staged/modified counts, ahead/behind
- **Live refresh** -- the primary stdin reading writes through to the cache on every render; the API fallback is also refreshed automatically after each agent response via Claude Code `Stop` hook, with 900-second debounce

## Layout

Up to four lines, each dropped entirely when it has nothing to say:

1. pause badge (only while paused), model, effort, context, 5h and 1w usage
2. path, worktree, branch
3. goal, loops
4. crons

Every label on lines 3 and 4 is cut on whole words, never mid-word, and ends in `…` only when something was actually dropped.

## Goal

- `◎goal:ship the release` -- the session's active `/goal`, first four words of its condition

Claude Code records a goal as a `goal_status` attachment in the transcript; the segment shows the open condition and disappears once the goal is met or cleared.

## Loop Status

The status bar shows every loop pacing this session and the task each one runs:

- `⟳loop:20m Poll the Slack` -- one loop: its interval and the first words of its task
- `⟳loops:20m Poll the Slack · 1h check my tasks` -- several loops, separated by ` · `

Nothing is shown when no loop is active. Two kinds count as loops: a self-paced `ScheduleWakeup` (interval from `delaySeconds`, task from its `prompt`), and a cron created by `/loop` -- the `/loop` command message in the transcript marks the job it schedules, so an interval loop is not mistaken for an ordinary cron. Absent both, a lone recurring cron is still read as the loop pacing the session.

There is no registry file and nothing to write; see [How loop and cron are derived](#how-loop-and-cron-are-derived).

## Cron Display

Claude Code session crons (scheduled via its `CronCreate` tool) are in-memory only -- the CLI has no API for a status line to query them. This status line instead recovers them from the transcript:

- `◷cron:17:13 (1h) check my tasks` -- when it next fires, how often it repeats, and its label
- The cadence in parentheses is `15m`, `1h`, `1d` or `once` for a one-shot; `◷crons:` with ` · ` between entries when there is more than one
- Jobs already promoted to the loop segment are not repeated here, and usage-guard's resume job is labelled `resume` rather than by its protocol prompt

### How loop and cron are derived

Only this session's own tool calls count -- any transcript line marked `isSidechain: true` (subagent activity) is skipped. A `CronCreate` tool call is matched to its result by `tool_use_id`; the job id is pulled from the result text, and an entry is recorded with that id, the `cron` expression, and a label made from the first few words of the `prompt`. A later `CronDelete` naming that id removes the entry. A `ScheduleWakeup` tool call records an active loop with its `delaySeconds` (as an interval) and its `prompt` (as the task); one with `stop: true` clears it. A `/loop` command message marks the next `CronCreate` as a loop rather than a plain cron.

Scanning the whole transcript on every render would be wasteful, so the byte offset already scanned and the derived state are cached per session under `~/.claude/cache/`. A shrunk or rotated transcript forces a full rescan, and so does deleting the cache file -- which is how a job scheduled before a change in how the transcript is read gets classified correctly without being recreated. Any failure to read, parse, or cache -- missing file, corrupt JSON, anything -- degrades to no segment rather than a crash or stale wrong answer.

## Standdown

When the companion [usage-guard](https://github.com/romacv/claude-usage-guard) has paused the session (headroom below its threshold, waiting for the limit to reset), the status bar adds a pause segment:

- `⏸paused to 20:01` -- the local clock time work will resume (date added when it's not today)

It leads the first line, ahead of the model. The segment reads usage-guard's session-scoped marker at `~/.claude/usage-guard/standdown-<session_id>.json` and only appears while a breach is active -- if usage-guard isn't installed, the file is absent and nothing shows. It shares the usage cache this status line already maintains, so no extra API calls.

## Requirements

- Ruby (system Ruby on macOS works fine)
- macOS with Claude Code authenticated (`claude` run at least once)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/romacv/claude-plan-usage-statusline/main/install.sh | sh
```

Or manually: copy `statusline.rb` to `~/.claude/statusline.rb` and add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "ruby ~/.claude/statusline.rb",
    "padding": 0
  }
}
```

## AI Agent Configuration Files

Settings and configurations for AI agents are stored in the following paths. Since these files are located inside hidden dotfile directories, you must always look deep inside them (and navigate via aliases/symlinks if needed) to manage and configure the agents:

| AI Agent | Settings File Path |
| :--- | :--- |
| **Claude Code** | `~/.claude/settings.json` |
| **Google Antigravity (`agy`)** | `~/.gemini/antigravity-cli/settings.json` |



## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/romacv/claude-plan-usage-statusline/main/uninstall.sh | sh
```

Removes `statusline.rb`, `refresh-usage-cache.sh`, cache files, and the `statusLine` + `Stop` hook entries from `settings.json`.

## How It Works

1. Reads `rate_limits` from Claude Code's stdin payload when present, and writes that reading through to the local cache; otherwise resolves an OAuth token (env var, token file, then macOS Keychain via `security find-generic-password`) and calls `https://api.anthropic.com/api/oauth/usage`
2. On the API path, caches the response locally; skips the call if the cache is fresh, and shows greyed stale data with a `~` prefix rather than discarding it once the cache outgrows the freshness window but is still under 6 hours old
3. A shared Retry-After backoff, written on a 429 by either this script or `refresh-usage-cache.sh`, is honored before any API call
4. Collects git state via `git status` / `git rev-parse` / `git rev-list`
5. Outputs the status bar -- model, context, usage, reset timer, git info, goal, loops and crons
6. A `Stop` hook runs `refresh-usage-cache.sh` asynchronously after each agent response, keeping the API-fallback cache fresh without blocking Claude Code. Debounced to at most one API call per 900 seconds.

## Menu Bar

For a native menu bar experience, check out [Usage Battery for Claude Code](https://apps.apple.com/us/app/usage-battery-for-cluade-code/id6757597561?mt=12) on the Mac App Store.

<img width="993" height="613" alt="Screenshot 2026-04-02 at 12 04 40" src="https://github.com/user-attachments/assets/339bfd04-c186-4477-a488-650f50ef3c8b" />

## License

MIT
