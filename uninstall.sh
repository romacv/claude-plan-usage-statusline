#!/bin/sh

CLAUDE_DIR="$HOME/.claude"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"

rm -f "$CLAUDE_DIR/statusline.rb"
rm -f "$CLAUDE_DIR/refresh-usage-cache.sh"
rm -f /tmp/claude_usage_cache.json
rm -f /tmp/claude_usage_refresh.lock

ruby - <<'RUBY'
require "json"

settings_path = File.expand_path("~/.claude/settings.json")
exit unless File.exist?(settings_path)

settings = JSON.parse(File.read(settings_path))
settings.delete("statusLine")

if settings["hooks"]
  if settings["hooks"]["Stop"]
    settings["hooks"]["Stop"].reject! do |entry|
      (entry["hooks"] || []).any? { |h| h["command"].to_s.include?("refresh-usage-cache.sh") }
    end
    settings["hooks"].delete("Stop") if settings["hooks"]["Stop"].empty?
  end
  settings.delete("hooks") if settings["hooks"].empty?
end

File.write(settings_path, JSON.pretty_generate(settings))
RUBY

echo "Done. Restart Claude Code to apply."
