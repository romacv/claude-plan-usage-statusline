# Claude Code Plan Usage Statusline

A Ruby status line script for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays model, usage limits, git state, and workspace context -- all in your terminal's status bar.

## Screenshot

```
◆ Opus 4.6 · ▤ Ctx: 72% · ▮ 5h: 85% 3h42m · ▮ 1w: 91%
~ /Users/you/project · ⌥ main · ⎋ feature/auth ∙2 !1 ↑1
```

## Features

- **OAuth API usage** -- fetches 5-hour and weekly rate limit data from Anthropic's API
- **Local caching** -- avoids repeated API calls with configurable TTL (default: 60s)
- **macOS Keychain integration** -- reads OAuth tokens securely, no hardcoded credentials
- **Git indicators** -- branch, worktree, staged/modified counts, ahead/behind tracking
- **Color schemes** -- `minimal`, `colors`, and `background` display modes
- **Info modes** -- `none`, `emoji`, or `text` label styles
- **Context window** -- shows remaining context percentage from Claude Code's input

## Requirements

- Ruby (system Ruby on macOS works fine)
- macOS (uses `security` CLI for Keychain access)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with OAuth authentication

## Installation

### Automatic

```bash
curl -fsSL https://raw.githubusercontent.com/romacv/claude-plan-usage-statusline/main/install.sh | sh
```

### Manual

1. Copy `statusline.rb` to `~/.claude/statusline.rb`

2. Add to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "CLAUDE_STATUS_DISPLAY_MODE=minimal ruby ~/.claude/statusline.rb",
    "padding": 0
  }
}
```

## Configuration

All configuration is done via environment variables in the `command` string:

| Variable | Default | Description |
|---|---|---|
| `CLAUDE_STATUS_DISPLAY_MODE` | `colors` | Color scheme: `minimal`, `colors`, or `background` |
| `CLAUDE_STATUS_INFO_MODE` | `none` | Label style: `none`, `emoji`, or `text` |
| `CLAUDE_STATUS_CACHE_FILE` | `/tmp/claude_usage_cache.json` | Path to the usage cache file |
| `CLAUDE_STATUS_CACHE_TTL` | `60` | Cache lifetime in seconds |
| `CLAUDE_STATUS_KEYCHAIN_SERVICE` | `Claude Code-credentials` | macOS Keychain service name for OAuth token |

Example with multiple settings:

```json
{
  "statusLine": {
    "type": "command",
    "command": "CLAUDE_STATUS_DISPLAY_MODE=colors CLAUDE_STATUS_INFO_MODE=emoji CLAUDE_STATUS_CACHE_TTL=120 ruby ~/.claude/statusline.rb",
    "padding": 0
  }
}
```

## How It Works

1. **Token retrieval** -- reads the OAuth access token from macOS Keychain via `security find-generic-password`
2. **API call** -- fetches usage data from `https://api.anthropic.com/api/oauth/usage` with the OAuth token
3. **Caching** -- writes API response to a local JSON file; subsequent calls within TTL skip the API
4. **Git data** -- runs `git status`, `git rev-parse`, and `git rev-list` to gather branch/worktree info
5. **Formatting** -- combines model name, context window, usage percentages, reset timer, and git state into a two-line status bar

## License

MIT
