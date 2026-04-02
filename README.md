# Claude Code Plan Usage Statusline

Status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays model, usage limits, git state, and workspace context in your terminal's status bar.

## Screenshot

![Screenshot](screenshot.svg)

**Real rate limit data.** Other tools count tokens locally from transcript files. This script reads server-side `five_hour` and `seven_day` utilization from Anthropic's OAuth API -- the actual numbers the rate limiter tracks.

**No permission prompts.** It's a plain CLI script, not a sandboxed app. Keychain is read by delegating to `/usr/bin/security` -- an Apple-signed system binary that already has Keychain access. The script itself never touches the Security APIs, so macOS has no reason to prompt. Outbound network from CLI doesn't trigger the firewall dialog either.

## Features

- **Model** -- current model name
- **Context window** -- remaining % from Claude Code's input
- **5h usage** -- session utilization with countdown to reset
- **1w usage** -- weekly utilization with reset date
- **Git** -- branch, worktree (when in a git worktree), staged/modified counts, ahead/behind
- **Live refresh** -- cache updated automatically after each agent response via Claude Code `Stop` hook, with 30-second debounce

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

## How It Works

1. Reads OAuth token from macOS Keychain via `security find-generic-password`
2. Calls `https://api.anthropic.com/api/oauth/usage` with the token
3. Caches the response locally; skips the API call if cache is fresh
4. Collects git state via `git status` / `git rev-parse` / `git rev-list`
5. Outputs a two-line status bar with model, context, usage, reset timer, and git info
6. A `Stop` hook runs `refresh-usage-cache.sh` asynchronously after each agent response, keeping the cache fresh without blocking Claude Code. Debounced to at most one API call per 30 seconds.

## Menu Bar

For a native menu bar experience, check out [Usage Battery for Claude Code](https://apps.apple.com/us/app/usage-battery-for-cluade-code/id6757597561?mt=12) on the Mac App Store.

<img width="993" height="613" alt="Screenshot 2026-04-02 at 12 04 40" src="https://github.com/user-attachments/assets/339bfd04-c186-4477-a488-650f50ef3c8b" />
## License

MIT
