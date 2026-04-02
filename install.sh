#!/bin/sh
set -e

BASE_URL="https://raw.githubusercontent.com/romacv/claude-plan-usage-statusline/main"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

mkdir -p "$CLAUDE_DIR"

curl -fsSL "$BASE_URL/statusline.rb" -o "$CLAUDE_DIR/statusline.rb"
curl -fsSL "$BASE_URL/refresh-usage-cache.sh" -o "$CLAUDE_DIR/refresh-usage-cache.sh"
chmod +x "$CLAUDE_DIR/refresh-usage-cache.sh"

ruby - <<'RUBY'
require "json"

settings_path = File.expand_path("~/.claude/settings.json")
settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}

settings["statusLine"] = {
  "type"    => "command",
  "command" => "ruby ~/.claude/statusline.rb",
  "padding" => 0
}

settings["hooks"] ||= {}
settings["hooks"]["Stop"] = [
  {
    "matcher" => "",
    "hooks" => [
      {
        "type"          => "command",
        "command"       => "bash $HOME/.claude/refresh-usage-cache.sh",
        "async"         => true,
        "timeout"       => 15000,
        "statusMessage" => ""
      }
    ]
  }
]

File.write(settings_path, JSON.pretty_generate(settings))
RUBY

echo "Done. Restart Claude Code to apply."
