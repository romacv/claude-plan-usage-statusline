#!/bin/sh
set -e

STATUSLINE_URL="https://raw.githubusercontent.com/romacv/claude-plan-usage-statusline/main/statusline.rb"
CLAUDE_DIR="$HOME/.claude"
STATUSLINE_PATH="$CLAUDE_DIR/statusline.rb"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"

curl -fsSL "$STATUSLINE_URL" -o "$STATUSLINE_PATH"

ruby - <<'RUBY'
require "json"

settings_path = File.expand_path("~/.claude/settings.json")
settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
settings["statusLine"] = {
  "type"    => "command",
  "command" => "ruby ~/.claude/statusline.rb",
  "padding" => 0
}
File.write(settings_path, JSON.pretty_generate(settings))
RUBY

echo "Done. Restart Claude Code to apply."
