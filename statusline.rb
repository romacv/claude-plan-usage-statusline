#!/usr/bin/env ruby
# frozen_string_literal: true

# Claude Code Status Line
#
# Displays model, usage, git, and workspace info in Claude Code's status bar.
# Usage is read primarily from the `rate_limits` block Claude Code pipes into
# this script on stdin (see usage_from_rate_limits) — no token, keychain
# read, or network call needed. That reading is also written through to the
# local cache file so usage-guard/guard.sh sees fresh data on every render.
#
# When stdin carries no `rate_limits` (older Claude Code builds, or the
# script run standalone), usage falls back to Anthropic's OAuth API, cached
# locally. A 429 response records a shared backoff (/tmp/claude_usage_backoff)
# that this script and refresh-usage-cache.sh both honor, so neither re-pins
# the rate-limit budget. Data older than CACHE_TTL but within
# STALE_DISPLAY_MAX is still shown, marked with a `~` prefix and gray color,
# instead of being silently discarded.
#
# OAuth token resolution order (first non-empty wins), see fetch_oauth_token:
#   1. $CLAUDE_CODE_OAUTH_TOKEN env var
#   2. Token file: $CLAUDE_USAGE_TOKEN_FILE, default
#      $HOME/.agents/keys/claude-oauth-token (set via `claude setup-token`)
#   3. macOS keychain item "Claude Code-credentials" ->
#      claudeAiOauth.accessToken (may not exist on newer Claude Code builds)
# If none yield a token, the fetch is skipped and stale/default usage is shown.
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
  BACKOFF_FILE = '/tmp/claude_usage_backoff'
  STALE_DISPLAY_MAX = 21_600
  USAGE_GUARD_DIR = File.join(Dir.home, '.claude', 'usage-guard')
  # Hide a stand-down badge whose wake time is this many seconds past — the
  # resume cron may re-schedule ~5 min on a not-yet-reset window without
  # touching the marker, so keep the badge honest through the normal resume
  # path but never let a stale/orphaned marker freeze it. The reaper that
  # actually deletes the file lives in usage-guard's stop-hook.sh.
  STANDDOWN_STALE_GRACE = 300
  KEYCHAIN_SERVICE = 'Claude Code-credentials'
  DEFAULT_TOKEN_FILE = File.join(Dir.home, '.agents', 'keys', 'claude-oauth-token')
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
    @rate_limits = @input_data['rate_limits']
  end

  def generate
    sep = "#{@colors[:gray]}|#{@colors[:reset]}"
    usage = calculate_usage
    git = git_data
    model_segment = colorize("\u{25C6}#{@model_name}", :model)
    model_segment += colorize("\u{2726}#{@effort_level}", :plan) if @effort_level

    line1_parts = [
      model_segment,
      context_segment(usage[:context]),
      usage_segment(usage[:session], usage[:session_pct], usage[:reset_time], usage[:stale]),
      usage_segment(usage[:weekly], usage[:weekly_pct], usage[:weekly_reset_time], usage[:stale])
    ].compact
    line1 = line1_parts.join(" #{sep} ")

    line2_parts = [
      colorize(short_path, :directory),
      (colorize("\u{2442}#{git[:worktree]}", :worktree) if git[:worktree]),
      colorize("\u{2325}#{git[:branch]}#{git[:indicators]}", git[:color]),
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

  # Strip C0 control bytes (incl. ESC 0x1b) and DEL from any file-sourced string
  # before it reaches the terminal, so a crafted marker file can't inject
  # its own escape sequences. Apply to the DATA, never to colorized output.
  def sanitize(text)
    text.to_s.gsub(/[\u0000-\u001f\u007f]/, '')
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

  def standdown_data
    return nil unless @session_id

    sid = @session_id.to_s.gsub(/[^A-Za-z0-9_-]/, '')
    return nil if sid.empty?

    path = File.join(USAGE_GUARD_DIR, "standdown-#{sid}.json")
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path))
    return nil unless data.is_a?(Hash) && data['breach']

    # Self-expire: once the wake time is safely past, the window has reset —
    # hide the badge even if no lead response or RESUME has cleared the marker
    # yet (an idle stood-down session never responds again). Pure read: the
    # file is deleted by stop-hook.sh's reaper, not here. `wake > 0` guard is
    # essential — nil.to_i == 0, so a marker missing wake_at_epoch must keep
    # rendering (show badge, no clock) rather than read as "always past".
    wake = data['wake_at_epoch'].to_i
    return nil if wake.positive? && Time.now.to_i > wake + STANDDOWN_STALE_GRACE

    data
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
    by = sanitize(by).strip
    return by unless by.empty?

    window = sanitize(data['window']).strip
    window = '5h' if window.empty?
    "#{window} limit"
  end

  def format_wake_clock(epoch)
    return nil unless epoch

    format_local_clock(Time.at(epoch.to_i).localtime)
  end

  def format_local_clock(t)
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

  # Resolution order: env var -> token file -> keychain. Each source is
  # rescue-safe on its own so a bad/unreadable source falls through to the
  # next one instead of raising.
  def fetch_oauth_token
    token = env_oauth_token
    return token if token

    token = token_file_oauth_token
    return token if token

    keychain_oauth_token
  end

  def env_oauth_token
    token = ENV['CLAUDE_CODE_OAUTH_TOKEN']
    token = token.to_s.strip
    token.empty? ? nil : token
  rescue StandardError
    nil
  end

  def token_file_oauth_token
    path = ENV['CLAUDE_USAGE_TOKEN_FILE']
    path = DEFAULT_TOKEN_FILE if path.nil? || path.empty?
    return nil unless File.readable?(path)

    token = File.read(path).strip
    token.empty? ? nil : token
  rescue StandardError
    nil
  end

  def keychain_oauth_token
    read_keychain.dig('claudeAiOauth', 'accessToken')
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
    return { 'rate_limited' => true, 'retry_after' => response['retry-after'].to_i } if response.code == '429'
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue StandardError
    nil
  end

  def record_backoff(retry_after)
    seconds = retry_after.to_i > 0 ? retry_after.to_i : 3600
    File.write(BACKOFF_FILE, (Time.now.to_i + seconds).to_s)
  rescue StandardError
    nil
  end

  def backoff_active?
    return false unless File.exist?(BACKOFF_FILE)

    until_at = File.read(BACKOFF_FILE).strip
    until_at.match?(/\A\d+\z/) && until_at.to_i > Time.now.to_i
  rescue StandardError
    false
  end

  def clear_backoff
    File.delete(BACKOFF_FILE) if File.exist?(BACKOFF_FILE)
  rescue StandardError
    nil
  end

  # Reads and parses the cache file with no age filter, returning the data
  # alongside its age in seconds. Freshness decisions live in calculate_usage.
  def read_cached_usage
    return [nil, nil] unless File.exist?(CACHE_FILE)

    age = (Time.now - File.mtime(CACHE_FILE)).to_i
    data = JSON.parse(File.read(CACHE_FILE))
    data.is_a?(Hash) ? [data, age] : [nil, nil]
  rescue StandardError
    [nil, nil]
  end

  def write_cache(data)
    File.write(CACHE_FILE, JSON.generate(data))
  rescue StandardError
    nil
  end

  # Atomic write: temp file in the same directory + File.rename, so a
  # concurrently-rendering session never observes a torn/partial cache file.
  def write_cache_atomic(data)
    dir = File.dirname(CACHE_FILE)
    tmp = File.join(dir, ".#{File.basename(CACHE_FILE)}.#{Process.pid}.#{rand(1_000_000)}.tmp")
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, CACHE_FILE)
  rescue StandardError
    nil
  end

  def usable_rate_window?(window)
    window.is_a?(Hash) && !window['used_percentage'].nil?
  end

  # `resets_at` in the stdin payload is a Unix epoch integer (unlike the API
  # payload's ISO-8601 string) — convert once here so every downstream
  # consumer (display formatters, cache write) works from a real Time.
  def epoch_to_iso(epoch)
    return nil unless epoch

    Time.at(epoch.to_i).iso8601
  rescue StandardError
    nil
  end

  # Writes the stdin reading through to CACHE_FILE in the same shape
  # guard.sh already parses from the API (`utilization` + ISO string), so
  # guard.sh keeps working unmodified and gets fresh data on every render.
  # A window stdin didn't provide is omitted rather than written as null.
  def write_stdin_cache(five_hour, seven_day)
    payload = { 'source' => 'statusline_stdin' }
    if usable_rate_window?(five_hour)
      payload['five_hour'] = { 'utilization' => five_hour['used_percentage'], 'resets_at' => epoch_to_iso(five_hour['resets_at']) }
    end
    if usable_rate_window?(seven_day)
      payload['seven_day'] = { 'utilization' => seven_day['used_percentage'], 'resets_at' => epoch_to_iso(seven_day['resets_at']) }
    end
    write_cache_atomic(payload)
  rescue StandardError
    nil
  end

  # Primary usage source: the `rate_limits` block Claude Code pipes into
  # this script on stdin. No cache read, no backoff check, no token lookup,
  # no HTTP — and never marked stale, since it is live data straight from
  # the caller. Returns nil (falling through to the API-backed path below)
  # when stdin carried no usable rate_limits, e.g. older Claude Code builds.
  def usage_from_rate_limits
    return nil unless @rate_limits.is_a?(Hash)

    five_hour = @rate_limits['five_hour']
    seven_day = @rate_limits['seven_day']
    return nil unless usable_rate_window?(five_hour) || usable_rate_window?(seven_day)

    write_stdin_cache(five_hour, seven_day)

    session_remaining = usable_rate_window?(five_hour) ? [100 - five_hour['used_percentage'].to_f.round, 0].max : nil
    weekly_remaining = usable_rate_window?(seven_day) ? [100 - seven_day['used_percentage'].to_f.round, 0].max : nil

    {
      context: "Ctx:#{@ctx_remaining.round}%",
      session: "5h:#{session_remaining || '?'}%",
      session_pct: session_remaining,
      reset_time: format_reset_time(usable_rate_window?(five_hour) ? epoch_to_iso(five_hour['resets_at']) : nil),
      weekly: "1w:#{weekly_remaining || '?'}%",
      weekly_pct: weekly_remaining,
      weekly_reset_time: format_weekly_reset_time(usable_rate_window?(seven_day) ? epoch_to_iso(seven_day['resets_at']) : nil)
    }
  rescue StandardError
    nil
  end

  def calculate_usage
    stdin_usage = usage_from_rate_limits
    return stdin_usage if stdin_usage

    data, age = read_cached_usage

    if data && !data['rate_limited'] && age && age <= CACHE_TTL
      return parse_api_data(data)
    end

    if !backoff_active?
      token = fetch_oauth_token
      if token
        api_data = fetch_api_usage(token)
        if api_data && api_data['rate_limited']
          record_backoff(api_data['retry_after'])
        elsif api_data
          write_cache(api_data)
          clear_backoff
          return parse_api_data(api_data)
        end
      end
    end

    if data && !data['rate_limited'] && age && age <= STALE_DISPLAY_MAX
      return parse_api_data(data).merge(stale: true)
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

  def usage_segment(text, remaining, reset, stale = false)
    label = stale ? "~#{text}" : text
    if reset.nil? || reset == '-'
      colorize("\u{25AE}#{label.sub(/:.*/, ':?')}", :gray)
    else
      color = stale ? :gray : usage_color(remaining)
      "#{colorize("\u{25AE}#{label}", color)} #{colorize("\u{29D6}#{reset}", :time)}"
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
