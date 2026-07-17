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
  CACHE_TTL = 600
  LOOP_DIR = File.join(Dir.home, '.claude', 'loops')
  LOOP_GOAL_MAX = 22
  STANDDOWN_FILE = File.join(Dir.home, '.claude', 'usage-guard', 'standdown.json')
  KEYCHAIN_SERVICE = 'Claude Code-credentials'
  MIDDLE_TRUNCATE_THRESHOLD = 23
  MIDDLE_TRUNCATE_HEAD = 11
  MIDDLE_TRUNCATE_TAIL = 8
  MIDDLE_TRUNCATE_MARKER = '....'

  COLORS = {
    directory: "\033[38;5;110m",
    model: "\033[38;5;133m",
    tokens: "\033[38;5;66m",
    ctx_warn: "\033[38;5;214m",
    ctx_alert: "\033[38;5;196m",
    plan: "\033[38;5;73m",
    messages: "\033[38;5;107m",
    time: "\033[38;5;178m",
    worktree: "\033[38;5;180m",
    git_clean: "\033[38;5;96m",
    git_dirty: "\033[38;5;167m",
    loop: "\033[38;5;114m",
    gray: "\033[90m",
    reset: "\033[0m"
  }.freeze

  def initialize
    @input_data = JSON.parse($stdin.read)
    @current_dir = @input_data.dig('workspace', 'current_dir') || @input_data['cwd']
    @model_name = @input_data.dig('model', 'display_name')&.sub(/\s*\(1M context\)/, "\u{00B7}1M")
    @dir_name = File.basename(@current_dir) if @current_dir
    @colors = COLORS
    @ctx_remaining = @input_data.dig('context_window', 'remaining_percentage') || 100
    @effort_level = @input_data.dig('effort', 'level')
    @session_id = @input_data['session_id'] || @input_data['sessionId']
  end

  def generate
    sep = "#{@colors[:gray]}|#{@colors[:reset]}"
    usage = calculate_usage
    git = git_data
    effort = @effort_level ? "Eff:#{@effort_level}" : nil

    line1_parts = [
      colorize("\u{25C6}#{@model_name}", :model),
      (colorize("\u{2726}#{effort}", :plan) if effort),
      context_segment(usage[:context]),
      usage_segment(usage[:session], usage[:session_pct], usage[:reset_time]),
      usage_segment(usage[:weekly], usage[:weekly_pct], usage[:weekly_reset_time])
    ].compact
    line1 = line1_parts.join(" #{sep} ")

    line2_parts = [
      colorize(short_path, :directory),
      (colorize("\u{2442}#{git[:worktree]}", :worktree) if git[:worktree]),
      colorize("\u{2325}#{git[:branch]}#{git[:indicators]}", git[:color]),
      loop_segment,
      pause_segment
    ].compact
    line2 = line2_parts.join(" #{sep} ")

    "#{line1}\n#{line2}"
  end

  private

  def colorize(text, color)
    return '' unless text
    "#{@colors[color]}#{text}#{@colors[:reset]}"
  end

  def context_segment(text)
    rem = @ctx_remaining
    if rem <= 20
      "#{colorize("\u{25A4}#{text}", :ctx_alert)}#{colorize(" \u{26A0}COMPACT", :ctx_alert)}"
    elsif rem <= 35
      colorize("\u{25A4}#{text}", :ctx_warn)
    else
      colorize("\u{25A4}#{text}", :tokens)
    end
  end

  def short_path
    return '' unless @current_dir
    middle_truncate(@current_dir.sub(/\A#{Regexp.escape(Dir.home)}(?=\/|\z)/, '~'))
  end

  def loop_data
    return nil unless @session_id
    path = File.join(LOOP_DIR, "#{@session_id}.json")
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) && data['active'] ? data : nil
  rescue StandardError
    nil
  end

  def loop_segment
    data = loop_data
    return colorize("\u{27F3}loop:off", :gray) unless data

    interval = data['interval'].to_s
    goal = data['goal'].to_s.gsub(/\s+/, ' ').strip
    goal = "#{goal[0, LOOP_GOAL_MAX]}\u{2026}" if goal.length > LOOP_GOAL_MAX + 1
    parts = []
    parts << "loop:#{interval}" unless interval.empty?
    parts << "goal:#{goal}" unless goal.empty?
    colorize("\u{27F3}#{parts.join(' ')}", :loop)
  end

  def standdown_data
    return nil unless File.exist?(STANDDOWN_FILE)

    data = JSON.parse(File.read(STANDDOWN_FILE))
    data.is_a?(Hash) && data['breach'] ? data : nil
  rescue StandardError
    nil
  end

  def pause_segment
    data = standdown_data
    return nil unless data

    by = pause_source(data)
    clock = format_wake_clock(data['wake_at_epoch'])
    text = "\u{23F8}paused by #{by}"
    text += ", resume #{clock}" if clock
    colorize(text, :ctx_alert)
  end

  # Generic cause label. Any scheduler may set `by` (string or list) on the
  # marker; usage-guard sets "<window> limit". Falls back to the window field.
  def pause_source(data)
    by = data['by']
    by = by.join(', ') if by.is_a?(Array)
    by = by.to_s.strip
    return by unless by.empty?

    window = data['window'].to_s
    window = '5h' if window.empty?
    "#{window} limit"
  end

  def format_wake_clock(epoch)
    return nil unless epoch

    t = Time.at(epoch.to_i).localtime
    t.strftime('%Y%m%d') == Time.now.strftime('%Y%m%d') ? t.strftime('%H:%M') : t.strftime('%b %-d %H:%M')
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

      { worktree: worktree, branch: middle_truncate(branch), indicators: indicators, color: color }
    end
  rescue
    default
  end

  def middle_truncate(text)
    return text if text.length <= MIDDLE_TRUNCATE_THRESHOLD

    "#{text[0, MIDDLE_TRUNCATE_HEAD]}#{MIDDLE_TRUNCATE_MARKER}#{text[-MIDDLE_TRUNCATE_TAIL, MIDDLE_TRUNCATE_TAIL]}"
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

  def read_keychain
    return @keychain_data if defined?(@keychain_data)
    json_str = `security find-generic-password -s "#{KEYCHAIN_SERVICE}" -w 2>/dev/null`.strip
    @keychain_data = json_str.empty? ? {} : JSON.parse(json_str)
  rescue StandardError
    @keychain_data = {}
  end

  def fetch_oauth_token
    read_keychain.dig('claudeAiOauth', 'accessToken')
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

    data = JSON.parse(File.read(CACHE_FILE))
    data.is_a?(Hash) ? data : nil
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
    weekly_resets_at_str = weekly['resetsAt'] || weekly['resets_at']

    session_remaining = [100 - session_util.round, 0].max
    weekly_remaining = [100 - weekly_util.round, 0].max

    {
      context: "Ctx:#{@ctx_remaining.round}%",
      session: "5h:#{session_remaining}%",
      session_pct: session_remaining,
      reset_time: format_reset_time(resets_at_str),
      weekly: "1w:#{weekly_remaining}%",
      weekly_pct: weekly_remaining,
      weekly_reset_time: format_weekly_reset_time(weekly_resets_at_str)
    }
  rescue StandardError
    default_usage
  end

  def usage_color(remaining)
    return :gray if remaining.nil?
    return :ctx_alert if remaining <= 15
    return :ctx_warn if remaining <= 35

    :messages
  end

  def usage_segment(text, remaining, reset)
    if reset.nil? || reset == '-'
      colorize("\u{25AE}#{text.sub(/:.*/, ':?')}", :gray)
    else
      "#{colorize("\u{25AE}#{text}", usage_color(remaining))} #{colorize("\u{29D6}#{reset}", :time)}"
    end
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

  def format_weekly_reset_time(resets_at_str)
    return "-" unless resets_at_str

    resets_at = Time.parse(resets_at_str).localtime
    resets_at.strftime("%b %-d %H:%M")
  rescue StandardError
    "-"
  end

  def default_usage
    {
      context: "Ctx:#{@ctx_remaining.round}%",
      session: "5h:?",
      session_pct: nil,
      reset_time: "-",
      weekly: "1w:?",
      weekly_pct: nil,
      weekly_reset_time: "-"
    }
  end
end

# Execute
puts ClaudeStatusLine.new.generate
