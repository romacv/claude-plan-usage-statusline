# Claude Code Plan Usage Statusline

Status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays model, usage limits, git state, and workspace context in your terminal's status bar.

## Screenshot

![Screenshot](screenshot.svg)

**Real rate limit data.** Other tools count tokens locally from transcript files. This script reads server-side `five_hour` and `seven_day` utilization from Anthropic's OAuth API -- the actual numbers the rate limiter tracks.

**No permission prompts.** It's a plain CLI script, not a sandboxed app. Keychain is read by delegating to `/usr/bin/security` -- an Apple-signed system binary that already has Keychain access. The script itself never touches the Security APIs, so macOS has no reason to prompt. Outbound network from CLI doesn't trigger the firewall dialog either.

## Features

- **Model** -- current model name (long-context suffix compacted, e.g. `(1M context)` becomes `·1M`)
- **Effort** -- current effort level (when set via `/effort`)
- **Context window** -- remaining % from Claude Code's input, color-graded
- **5h usage** -- session headroom with countdown to reset, color-graded (amber at 35% left, red at 15% left); shows `?` when usage data is unavailable instead of a misleading 100%
- **1w usage** -- weekly headroom with reset date, color-graded
- **Loop status** -- shows an active recurring loop and its goal when a session loop-state file is present (see [Loop Status](#loop-status))
- **Git** -- branch, worktree (when in a git worktree), staged/modified counts, ahead/behind
- **Live refresh** -- cache updated automatically after each agent response via Claude Code `Stop` hook, with 30-second debounce

## Loop Status

The status bar shows whether a recurring loop is active for the current session and its goal:

- `⟳loop:15m goal:…` -- an active loop, interval and goal (goal truncated to fit)
- `⟳loop:off` -- no active loop

The segment reads a per-session state file at `~/.claude/loops/<session_id>.json`, keyed by the `session_id` Claude Code passes to the status line. Write it when a loop starts, remove it when the loop stops:

```json
{"active": true, "interval": "15m", "goal": "your goal here", "job_id": "abc123"}
```

Keying by session id means each session shows only its own loop, and a leftover file from a closed session is inert -- its id never recurs. When no matching file is present, the segment shows `⟳loop:off`.

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

1. Reads OAuth token from macOS Keychain via `security find-generic-password`
2. Calls `https://api.anthropic.com/api/oauth/usage` with the token
3. Caches the response locally; skips the API call if cache is fresh
4. Collects git state via `git status` / `git rev-parse` / `git rev-list`
5. Outputs a two-line status bar with model, context, usage, reset timer, git info, and loop status
6. A `Stop` hook runs `refresh-usage-cache.sh` asynchronously after each agent response, keeping the cache fresh without blocking Claude Code. Debounced to at most one API call per 30 seconds.

## Menu Bar

For a native menu bar experience, check out [Usage Battery for Claude Code](https://apps.apple.com/us/app/usage-battery-for-cluade-code/id6757597561?mt=12) on the Mac App Store.

<img width="993" height="613" alt="Screenshot 2026-04-02 at 12 04 40" src="https://github.com/user-attachments/assets/339bfd04-c186-4477-a488-650f50ef3c8b" />

## License

MIT
