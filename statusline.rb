#!/usr/bin/env ruby
# frozen_string_literal: true

# Claude Code Status Line
#
# Displays model, usage, git, and workspace info in Claude Code's status bar.
# Usage data is fetched from Anthropic's OAuth API and cached locally.
#
# Usage:
#   echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Sonnet 4.6"},"context_window":{"remaining_percentage":80}}' | ruby ~/.claude/statusline.rb
#
# Installation (settings.json):
#   "statusLine": {
#     "type": "command",
#     "command": "ruby ~/.claude/statusline.rb",
#     "padding": 0
#   }

require 'json'
require 'net/http'
require 'uri'
require 'time'

class ClaudeStatusLine
  CACHE_FILE = '/tmp/claude_usage_cache.json'
  CACHE_TTL = 300
  KEYCHAIN_SERVICE = 'Claude Code-credentials'

  COLORS = {
    directory: "\033[38;5;110m",
    model: "\033[38;5;133m",
    tokens: "\033[38;5;66m",
    messages: "\033[38;5;107m",
    time: "\033[38;5;178m",
    worktree: "\033[38;5;180m",
    git_clean: "\033[38;5;96m",
    git_dirty: "\033[38;5;167m",
    gray: "\033[90m",
    reset: "\033[0m"
  }.freeze

  def initialize
    @input_data = JSON.parse($stdin.read)
    @current_dir = @input_data.dig('workspace', 'current_dir') || @input_data['cwd']
    @model_name = @input_data.dig('model', 'display_name')
    @dir_name = File.basename(@current_dir) if @current_dir
    @colors = COLORS
    @ctx_remaining = @input_data.dig('context_window', 'remaining_percentage') || 100
  end

  def generate
    sep = "#{@colors[:gray]}\u{00B7}#{@colors[:reset]}"
    usage = calculate_usage
    git = git_data

    line1_parts = [
      colorize("\u{25C6} #{@model_name}", :model),
      colorize("\u{25A4} #{usage[:context]}", :tokens),
      "#{colorize("\u{25AE} #{usage[:session]}", :messages)} #{colorize("\u{29D6} #{usage[:reset_time]}", :time)}",
      colorize("\u{25AE} #{usage[:weekly]}", :messages)
    ]
    line1 = line1_parts.join(" #{sep} ")

    line2_parts = [
      colorize("~ #{@current_dir}", :directory),
      (colorize("\u{2442} #{git[:worktree]}", :worktree) if git[:worktree]),
      colorize("\u{2325} #{git[:branch]}#{git[:indicators]}", git[:color])
    ].compact
    line2 = line2_parts.join(" #{sep} ")

    "#{line1}\n#{line2}"
  end

  private

  def colorize(text, color)
    return '' unless text
    "#{@colors[color]}#{text}#{@colors[:reset]}"
  end

  def git_data
    default = { worktree: nil, branch: '', indicators: '', color: :git_clean }
    return default unless @current_dir && File.exist?(File.join(@current_dir, '.git'))

    Dir.chdir(@current_dir) do
      branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
      return default if branch.empty?

      git_dir = `git rev-parse --git-dir 2>/dev/null`.strip
      common_dir = `git rev-parse --git-common-dir 2>/dev/null`.strip
      worktree = if git_dir != common_dir
        File.basename(`git rev-parse --show-toplevel 2>/dev/null`.strip)
      else
        nil
      end

      indicators = build_git_indicators
      color = indicators.empty? ? :git_clean : :git_dirty

      { worktree: worktree, branch: branch, indicators: indicators, color: color }
    end
  rescue
    default
  end

  def build_git_indicators
    status = `git status --porcelain 2>/dev/null`.strip
    branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
    ahead_behind = `git rev-list --left-right --count origin/#{branch}...#{branch} 2>/dev/null`.strip

    parts = []
    parts << '?' if status.match?(/^\?\?/)
    staged_count = status.lines.count { |l| l.match?(/^[AM]/) }
    parts << "\u{2219}#{staged_count}" if staged_count > 0
    modified_count = status.lines.count { |l| l.match?(/^.[MD]/) }
    parts << "!#{modified_count}" if modified_count > 0

    if ahead_behind.match(/^(\d+)\s+(\d+)$/)
      behind, ahead = ahead_behind.split.map(&:to_i)
      parts << "\u{2191}#{ahead}" if ahead > 0
      parts << "\u{2193}#{behind}" if behind > 0
    end

    parts.empty? ? '' : ' ' + parts.join(' ')
  end

  def fetch_oauth_token
    json_str = `security find-generic-password -s "#{KEYCHAIN_SERVICE}" -w 2>/dev/null`.strip
    return nil if json_str.empty?

    data = JSON.parse(json_str)
    data.dig('claudeAiOauth', 'accessToken')
  rescue StandardError
    nil
  end

  def fetch_api_usage(token)
    uri = URI('https://api.anthropic.com/api/oauth/usage')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{token}"
    request['anthropic-beta'] = 'oauth-2025-04-20'

    response = http.request(request)
    return { 'rate_limited' => true } if response.code == '429'
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue StandardError
    nil
  end

  def read_cached_usage
    return nil unless File.exist?(CACHE_FILE)
    return nil if (Time.now - File.mtime(CACHE_FILE)) > CACHE_TTL

    JSON.parse(File.read(CACHE_FILE))
  rescue StandardError
    nil
  end

  def write_cache(data)
    File.write(CACHE_FILE, JSON.generate(data))
  rescue StandardError
    nil
  end

  def calculate_usage
    cached = read_cached_usage
    if cached
      return default_usage if cached['rate_limited']
      return parse_api_data(cached)
    end

    token = fetch_oauth_token
    if token
      api_data = fetch_api_usage(token)
      if api_data
        write_cache(api_data)
        return default_usage if api_data['rate_limited']
        return parse_api_data(api_data)
      end
    end

    default_usage
  end

  def parse_api_data(data)
    standard = data['five_hour'] || data['standardRateLimit'] || data['standard'] || {}
    weekly = data['seven_day'] || data['weeklyRateLimit'] || data['weekly'] || {}

    session_util = (standard['utilizationPercentage'] || standard['utilization_percentage'] || standard['utilization'] || 0).to_f
    weekly_util = (weekly['utilizationPercentage'] || weekly['utilization_percentage'] || weekly['utilization'] || 0).to_f
    resets_at_str = standard['resetsAt'] || standard['resets_at']

    session_remaining = [100 - session_util.round, 0].max
    weekly_remaining = [100 - weekly_util.round, 0].max

    {
      context: "Ctx: #{@ctx_remaining.round}%",
      session: "5h: #{session_remaining}%",
      reset_time: format_reset_time(resets_at_str),
      weekly: "1w: #{weekly_remaining}%"
    }
  rescue StandardError
    default_usage
  end

  def format_reset_time(resets_at_str)
    return "-" unless resets_at_str

    resets_at = Time.parse(resets_at_str)
    seconds_until_reset = [(resets_at - Time.now).to_i, 0].max
    hours = seconds_until_reset / 3600
    minutes = (seconds_until_reset % 3600) / 60
    "#{hours}h#{minutes}m"
  rescue StandardError
    "-"
  end

  def default_usage
    {
      context: "Ctx: #{@ctx_remaining.round}%",
      session: "5h: ?",
      reset_time: "-",
      weekly: "1w: ?"
    }
  end
end

# Execute
puts ClaudeStatusLine.new.generate
