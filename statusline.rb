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
  LABEL_MAX = 28
  USAGE_GUARD_DIR = File.join(Dir.home, '.claude', 'usage-guard')
  TRANSCRIPT_CACHE_DIR = File.join(Dir.home, '.claude', 'cache')
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
    directory: "\e[38;5;32m",
    model: "\e[38;5;91m",
    tokens: "\e[38;5;30m",
    ctx_warn: "\e[38;5;172m",
    ctx_alert: "\e[38;5;160m",
    plan: "\e[38;5;31m",
    messages: "\e[38;5;64m",
    time: "\e[38;5;136m",
    worktree: "\e[38;5;137m",
    git_clean: "\e[38;5;60m",
    git_dirty: "\e[38;5;131m",
    loop: "\e[38;5;35m",
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
    @transcript_path = @input_data['transcript_path']
  end

  def generate
    sep = "#{@colors[:gray]}|#{@colors[:reset]}"
    usage = calculate_usage
    git = git_data
    model_segment = colorize("\u{25C6}#{@model_name}", :model)
    model_segment += colorize("\u{2726}#{@effort_level}", :plan) if @effort_level

    line1_parts = [
      pause_segment,
      model_segment,
      context_segment(usage[:context]),
      usage_segment(usage[:session], usage[:session_pct], usage[:reset_time], usage[:stale]),
      usage_segment(usage[:weekly], usage[:weekly_pct], usage[:weekly_reset_time], usage[:stale])
    ].compact
    line1 = line1_parts.join(" #{sep} ")

    line2_parts = [
      colorize(short_path, :directory),
      (colorize("\u{2442}#{git[:worktree]}", :worktree) if git[:worktree]),
      colorize("\u{2325}#{git[:branch]}#{git[:indicators]}", git[:color])
    ].compact
    line2 = line2_parts.join(" #{sep} ")

    line3_parts = [goal_segment, loop_segment].compact
    lines = [line1, line2]
    lines << line3_parts.join(" #{sep} ") unless line3_parts.empty?
    crons = cron_segment
    lines << crons if crons
    lines.join("\n")
  end

  private

  def colorize(text, color)
    return '' unless text
    "#{@colors[color]}#{text}#{@colors[:reset]}"
  end

  # Strip C0 control bytes (incl. ESC 0x1b) and DEL from any file-sourced string
  # before it reaches the terminal, so a crafted marker/loop file can't inject
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

  # Derived state (crons + loop) parsed out of this session's own transcript
  # — see the transcript scanning section below. `loop_data` prefers an
  # explicit ScheduleWakeup-driven loop; absent that, a live cron implies an
  # interval loop pacing itself, using the newest cron's schedule/label.
  def dated_cron?(cron)
    fields = sanitize(cron).split(/\s+/)
    return false unless fields.length == 5

    fields[2] != '*' || fields[3] != '*'
  rescue StandardError
    false
  end

  def loops_data
    state = transcript_state
    loops = []
    active = state['loop']
    loops << active if active.is_a?(Hash) && active['active']

    crons = state['crons']
    live = crons.is_a?(Hash) ? crons.values.select { |c| c.is_a?(Hash) && !c['oneShot'] && !cron_stale?(c) } : []
    # A job pinned to one day and month fires once whatever its `recurring`
    # flag says, so it never stands in for a loop.
    live = live.reject { |c| dated_cron?(c['cron']) }
    tagged = live.select { |c| c['loop'] }

    # Nothing tagged and no wakeup: an interval loop still paces this session,
    # so read it off the newest recurring cron the way we always have.
    tagged = [live.last].compact if tagged.empty? && loops.empty?

    tagged.each do |c|
      loops << {
        'active' => true,
        'interval' => human_cron_interval(c['cron']),
        'goal' => c['label'],
        '_source_cron_id' => c['id']
      }
    end
    loops
  rescue StandardError
    []
  end

  # The cron id backing the loop when it was derived from the fallback path
  # (no ScheduleWakeup in the transcript) — used by cron_segment to suppress
  # that cron from its own listing so it isn't shown twice. nil when the
  # loop came from ScheduleWakeup or there is no loop.
  def loop_backing_cron_ids
    ids = loops_data.map { |l| l['_source_cron_id'] }.compact
    ids
  rescue StandardError
    []
  end

  # The session's own /goal, first three words of the condition.
  def goal_segment
    g = transcript_state['goal']
    return nil unless g.is_a?(Hash)

    text = word_label(four_word_label(g['condition']))
    return nil if text.empty?

    colorize("\u{25CE}goal:#{text}", :messages)
  rescue StandardError
    nil
  end

  def loop_segment
    loops = loops_data
    return nil if loops.empty?

    entries = loops.map do |l|
      [l['interval'].to_s, word_label(l['goal'])].reject(&:empty?).join(' ')
    end.reject(&:empty?)
    return nil if entries.empty?

    # Count what is actually drawn, not what was collected — an entry that
    # rendered empty must not push the label to the plural.
    name = entries.size > 1 ? 'loops' : 'loop'
    colorize("\u{27F3}#{name}:#{entries.join(" \u{00B7} ")}", :loop)
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
    text = "\u{23F8}paused"
    text += " to #{clock}" if clock
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

  def crons_data
    crons = transcript_state['crons']
    return nil unless crons.is_a?(Hash) && !crons.empty?

    crons.values
  rescue StandardError
    nil
  end

  # --- Transcript-derived state -------------------------------------------
  #
  # `cron_segment`/`loop_segment` used to read registry files nothing ever
  # wrote. Instead we scan this session's own transcript (the `.jsonl` at
  # `transcript_path`) for CronCreate/CronDelete/ScheduleWakeup tool calls
  # and derive the same shapes those renderers already expect. Subagent
  # activity (`isSidechain: true`) is skipped throughout.
  #
  # Rescanning a multi-megabyte transcript on every render would be wasteful,
  # so the byte offset already scanned plus the derived state are cached per
  # session at TRANSCRIPT_CACHE_DIR/statusline-session-<sid>.json. A shrunk
  # or rotated transcript (cache size > current size) forces a full rescan.
  # Deleting the cache file forces one too, which is how a job created before
  # a scanning change (a /loop cron predating the loop tag) gets classified
  # correctly without being recreated.

  def transcript_state
    @transcript_state ||= compute_transcript_state
  end

  def default_transcript_state
    { 'crons' => {}, 'loop' => nil, 'pending' => {}, 'goal' => nil }
  end

  def compute_transcript_state
    return default_transcript_state unless @transcript_path && File.exist?(@transcript_path)

    file_size = File.size(@transcript_path)
    cache_path = transcript_cache_path
    cached = cache_path && read_transcript_cache(cache_path)

    if cached && cached['size'].is_a?(Integer) && cached['state'].is_a?(Hash) && file_size >= cached['size']
      offset = cached['offset'].is_a?(Integer) ? cached['offset'] : 0
      state = cached['state']
    else
      offset = 0
      state = default_transcript_state
    end

    new_offset = scan_transcript(@transcript_path, offset, state)
    if cache_path
      write_transcript_cache_atomic(cache_path, { 'offset' => new_offset, 'size' => file_size, 'state' => state })
    end
    state
  rescue StandardError
    default_transcript_state
  end

  def transcript_cache_path
    return nil unless @session_id

    sid = @session_id.to_s.gsub(/[^A-Za-z0-9_-]/, '')
    return nil if sid.empty?

    File.join(TRANSCRIPT_CACHE_DIR, "statusline-session-#{sid}.json")
  end

  def read_transcript_cache(path)
    return nil unless File.exist?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end

  def ensure_transcript_cache_dir(dir)
    return if Dir.exist?(dir)

    Dir.mkdir(dir)
  rescue StandardError
    nil
  end

  # Atomic write, same pattern as write_cache_atomic: temp file in the same
  # directory + File.rename, so a concurrently-rendering session never
  # observes a torn/partial cache file.
  def write_transcript_cache_atomic(path, data)
    dir = File.dirname(path)
    ensure_transcript_cache_dir(dir)
    tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.#{rand(1_000_000)}.tmp")
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, path)
  rescue StandardError
    nil
  end

  # Reads only the new bytes past `offset`, parses whichever lines are fully
  # written (a trailing partial line is left for the next render), and
  # mutates `state` in place. Returns the new offset to persist.
  def scan_transcript(path, offset, state)
    content = File.open(path, 'rb') do |f|
      f.seek(offset)
      f.read
    end
    return offset if content.nil? || content.empty?

    last_newline = content.rindex("\n")
    return offset if last_newline.nil?

    usable = content[0..last_newline]
    pending = state['pending'] ||= {}
    crons = state['crons'] ||= {}

    usable.each_line { |line| process_transcript_line(line, pending, crons, state) }

    offset + usable.bytesize
  rescue StandardError
    offset
  end

  def process_transcript_line(line, pending, crons, state)
    line = line.strip
    return if line.empty?

    d = JSON.parse(line)
    return unless d.is_a?(Hash)
    return if d['isSidechain']

    # A /goal writes a `goal_status` attachment: sentinel/met:false when the
    # goal is set or still open, met:true once it is satisfied and cleared.
    att = d['attachment']
    if att.is_a?(Hash) && att['type'] == 'goal_status'
      if att['met']
        state['goal'] = nil
      else
        prev = state['goal']
        set_at = (prev.is_a?(Hash) && prev['condition'] == att['condition'] && prev['set_at']) || d['timestamp']
        state['goal'] = { 'condition' => att['condition'].to_s, 'set_at' => set_at }
      end
    end

    # `/loop <interval> <prompt>` schedules an ordinary cron with no trace of
    # its origin in the CronCreate call, so the command message itself is what
    # marks the next created job as a loop.
    raw = d.dig('message', 'content')
    if raw.is_a?(String) && raw.include?('<command-name>/loop</command-name>')
      state['loop_cmd'] = true
    end

    content = raw
    return unless content.is_a?(Array)

    content.each do |block|
      next unless block.is_a?(Hash)

      case block['type']
      when 'tool_use'
        process_tool_use(block, pending, crons, state)
      when 'tool_result'
        process_tool_result(block, pending, crons, d['timestamp'], state)
      end
    end
  rescue StandardError
    nil
  end

  def process_tool_use(block, pending, crons, state)
    case block['name']
    when 'CronCreate'
      pending[block['id']] = block['input'] if block['id'] && block['input'].is_a?(Hash)
    when 'CronDelete'
      del_id = block.dig('input', 'id') || block['id']
      crons.delete(del_id) if del_id
    when 'ScheduleWakeup'
      input = block['input'].is_a?(Hash) ? block['input'] : {}
      if input['stop']
        state['loop'] = nil
      else
        # The loop's own task (the /loop prompt) names it better than the
        # wakeup's pacing `reason`, which only explains the delay.
        task = input['prompt'].to_s.sub(%r{\A/loop\s+}, '')
        task = input['reason'] if task.strip.empty?
        state['loop'] = {
          'active' => true,
          'interval' => format_interval(input['delaySeconds']),
          'goal' => four_word_label(task)
        }
      end
    end
  rescue StandardError
    nil
  end

  # Anchored on Claude Code's own confirmation phrasing rather than a bare
  # "(job|task) <hex>" — a transcript can contain a tool_result that merely
  # *quotes* another session's cron output (e.g. a Bash result echoing
  # `USE CronCreate id=… input={"cron"=>...}`), and a loose pattern would
  # harvest ids that were never this session's. Claude Code words the two
  # cron kinds differently: "Scheduled recurring job <id> (...)" and
  # "Scheduled one-shot task <id> (...)".
  CRON_CONFIRMATION = /\bScheduled (recurring job|one-shot task) ([0-9a-f]{6,})\b/

  def process_tool_result(block, pending, crons, timestamp, state = {})
    tid = block['tool_use_id']
    return unless tid

    input = pending.delete(tid)
    return unless input

    text = extract_result_text(block)
    m = text.to_s.match(CRON_CONFIRMATION)
    return unless m

    kind, job_id = m[1], m[2]
    one_shot = input.key?('recurring') ? (input['recurring'] == false) : (kind == 'one-shot task')

    entry = {
      'id' => job_id,
      'cron' => input['cron'],
      'label' => four_word_label(input['prompt']),
      'oneShot' => one_shot,
      'loop' => !one_shot && state['loop_cmd'] == true
    }
    state['loop_cmd'] = false
    entry['next'] = one_shot_next(input['cron'], timestamp) if one_shot

    crons[job_id] = entry
  rescue StandardError
    nil
  end

  # A fired one-shot is auto-deleted by Claude Code with no trace left in the
  # transcript, so cron_stale? can only expire it if we pin its one and only
  # fire time ourselves. The cron expression for a one-shot fully determines
  # that moment (minute hour day-of-month month, day-of-week is "*"), so we
  # compute it once at creation and store it as `next`. Any non-integer
  # field (or an invalid calendar date, e.g. day-of-month/month combo that
  # doesn't exist) leaves `next` absent — the entry then just persists,
  # matching a recurring cron, rather than guessing and risking a wrong
  # expiry. The year is chosen so the result is the next such moment at or
  # after `reference_iso` (the creation time), so a job scheduled for a
  # month earlier in the calendar than the reference rolls to next year
  # instead of resolving into the past.
  def one_shot_next(cron, reference_iso)
    fields = cron.to_s.split(/\s+/)
    return nil unless fields.length == 5

    minute, hour, dom, month, = fields
    return nil unless [minute, hour, dom, month].all? { |f| f.match?(/\A\d+\z/) }

    ref = reference_iso ? Time.parse(reference_iso) : Time.now
    ref = ref.localtime

    candidate = Time.new(ref.year, month.to_i, dom.to_i, hour.to_i, minute.to_i, 0, ref.utc_offset)
    candidate = Time.new(ref.year + 1, month.to_i, dom.to_i, hour.to_i, minute.to_i, 0, ref.utc_offset) if candidate < ref
    candidate.iso8601
  rescue StandardError
    nil
  end

  def extract_result_text(block)
    content = block['content']
    case content
    when String
      content
    when Array
      content.map { |c| c.is_a?(Hash) ? c['text'] : nil }.compact.join(' ')
    end
  rescue StandardError
    nil
  end

  # First two words of a cron prompt or ScheduleWakeup reason, used as the
  # label/goal. CRON_LABEL_MAX/LOOP_GOAL_MAX truncation downstream is only a
  # backstop for a pathological single long word.
  def two_word_label(text)
    text.to_s.gsub(/\s+/, ' ').strip.split(' ').first(2).join(' ')
  end

  # Four words, and an ellipsis when there were more — a label that stops
  # mid-sentence with no mark reads as the whole thing.
  def four_word_label(text)
    words = text.to_s.gsub(/\s+/, ' ').strip.split(' ')
    label = words.first(4).join(' ')
    words.length > 4 ? "#{label}\u{2026}" : label
  end

  # Line-3 labels read as words, never as a chopped one: take whole words up to
  # LABEL_MAX characters and mark the cut with an ellipsis only when something
  # was actually dropped.
  def word_label(text, limit = LABEL_MAX)
    words = sanitize(text).gsub(/\s+/, ' ').strip.split(' ')
    return '' if words.empty?

    out = words.shift
    while (w = words.first) && (out.length + 1 + w.length) <= limit
      out = "#{out} #{words.shift}"
    end
    out = out[0, limit] if out.length > limit
    return out if words.empty? || out.end_with?("\u{2026}")

    "#{out}\u{2026}"
  end

  def format_interval(delay_seconds)
    seconds = delay_seconds.to_i
    return "#{seconds}s" if seconds <= 0
    return "#{seconds}s" if seconds < 60

    # Round to whole minutes: a 2300s wakeup reads as 38m, not 2300s.
    "#{(seconds / 60.0).round}m"
  end

  def cron_stale?(entry)
    # A date-pinned job fires at one moment and Claude Code deletes it without
    # a trace, so once that moment is past the entry is a ghost — whatever its
    # `recurring` flag claimed. Never roll it into next year: that would keep a
    # job that already fired on the line for another twelve months.
    dated = dated_time(entry['cron'])
    return true if dated && dated < Time.now
    return false unless entry['oneShot'] && entry['next']

    Time.parse(entry['next']) < Time.now
  rescue StandardError
    false
  end

  def dated_time(cron)
    return nil unless dated_cron?(cron)

    minute, hour, dom, month, = sanitize(cron).split(/\s+/)
    return nil unless [minute, hour, dom, month].all? { |f| f.match?(/\A\d+\z/) }

    now = Time.now.localtime
    Time.new(now.year, month.to_i, dom.to_i, hour.to_i, minute.to_i, 0, now.utc_offset)
  rescue StandardError
    nil
  end

  def cron_sort_key(entry)
    return next_recurring_time(entry['cron'])&.to_f || Float::INFINITY unless entry['next']

    Time.parse(entry['next']).to_f
  rescue StandardError
    Float::INFINITY
  end

  def cron_next_clock(next_str)
    format_local_clock(Time.parse(next_str).localtime)
  rescue StandardError
    nil
  end

  # Wall-clock of a recurring cron's next fire, so the badge reads "@17:37"
  # instead of the cron's own shorthand ":37" — the same thing a one-shot
  # already shows via `next`. Covers the three shapes /loop produces; anything
  # else falls back to short_cron.
  def next_recurring_clock(cron)
    t = next_recurring_time(cron)
    t && format_local_clock(t)
  end

  def next_recurring_time(cron)
    fields = sanitize(cron).split(/\s+/)
    return nil unless fields.length == 5

    minute, hour, dom, month, dow = fields
    return nil unless dom == '*' && month == '*' && dow == '*'

    now = Time.now.localtime
    if (m = minute.match(/\A\*\/(\d+)\z/)) && hour == '*'
      step = m[1].to_i
      return nil unless step.positive?

      nxt = ((now.min / step) + 1) * step
      t = Time.new(now.year, now.month, now.day, now.hour, 0, 0, now.utc_offset) + nxt * 60
    elsif minute.match?(/\A\d{1,2}\z/) && hour == '*'
      t = Time.new(now.year, now.month, now.day, now.hour, minute.to_i, 0, now.utc_offset)
      t += 3600 if t <= now
    elsif minute.match?(/\A\d{1,2}\z/) && hour.match?(/\A\d{1,2}\z/)
      t = Time.new(now.year, now.month, now.day, hour.to_i, minute.to_i, 0, now.utc_offset)
      t += 86_400 if t <= now
    else
      return nil
    end

    t
  rescue StandardError
    nil
  end

  def short_cron(cron)
    cron = sanitize(cron)
    m = cron.match(/\A\*\/(\d+) \* \* \* \*\z/)
    return "*/#{m[1]}m" if m

    m = cron.match(/\A(\d{1,2}) \* \* \* \*\z/)
    return ":#{m[1]}" if m

    cron
  end

  # Human period for a cron expression, used only when that cron IS the loop
  # (the fallback-derivation path). Unlike short_cron (which renders the
  # cron's own short form, e.g. "*/15m" or ":43"), this reads as an interval.
  def human_cron_interval(cron)
    sanitized = sanitize(cron)

    m = sanitized.match(/\A\*\/(\d+) \* \* \* \*\z/)
    return "#{m[1]}m" if m

    return '1h' if sanitized.match?(/\A\d{1,2} \* \* \* \*\z/)
    return '1d' if sanitized.match?(/\A\d{1,2} \d{1,2} \* \* \*\z/)

    m = sanitized.match(%r{\A\d{1,2} \*/(\d{1,2}) \* \* \*\z})
    return "#{m[1]}h" if m

    m = sanitized.match(%r{\A\d{1,2} \d{1,2} \*/(\d{1,2}) \* \*\z})
    return "#{m[1]}d" if m

    # A dated one-off (minute hour day month *) has no period at all: show the
    # clock it fires at rather than leaking the raw five-field expression.
    m = sanitized.match(/\A(\d{1,2}) (\d{1,2}) \d{1,2} \d{1,2} \*\z/)
    return format('%02d:%02d', m[2].to_i, m[1].to_i) if m

    short_cron(sanitized)
  rescue StandardError
    short_cron(cron)
  end

  # What kind of job it is, so a clock alone never has to carry the meaning:
  # "once" for a one-shot, otherwise how often it repeats.
  # A job pinned to a day and month fires at one moment, whether or not it was
  # flagged recurring — show that moment rather than the raw expression.
  def dated_clock(cron)
    return nil unless dated_cron?(cron)

    t = dated_time(cron)
    t && format_local_clock(t)
  rescue StandardError
    nil
  end

  def cron_cadence(entry)
    return 'once' if entry['oneShot'] || dated_cron?(entry['cron'])

    human_cron_interval(entry['cron'])
  end

  # "resume" alone says nothing about what comes back. The stand-down's own
  # checkpoint records the work that was parked, so name that instead.
  def resume_label
    goal = checkpoint_goal
    goal.empty? ? 'resume the paused work' : "resume #{word_label(four_word_label(goal))}"
  end

  def checkpoint_goal
    return '' unless @session_id

    sid = @session_id.to_s.gsub(/[^A-Za-z0-9_-]/, '')
    return '' if sid.empty?

    path = File.join(USAGE_GUARD_DIR, "resume-#{sid}.json")
    return '' unless File.exist?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) ? sanitize(data['goal']).strip : ''
  rescue StandardError
    ''
  end

  def cron_entry_text(entry)
    label = resume_cron?(entry) ? resume_label : word_label(entry['label'])
    label = 'cron' if label.empty?
    clock = (entry['next'] && cron_next_clock(entry['next'])) ||
            next_recurring_clock(entry['cron']) ||
            dated_clock(entry['cron']) || short_cron(entry['cron'])
    "#{clock} (#{cron_cadence(entry)}) #{label}".strip
  end

  # The stand-down's own resume cron is already spelled out by the pause badge
  # ("⏸5h→21:11"); listing it again as "@21:12 Invoke the" says nothing new.
  # Match it by fire time rather than by id, which the marker doesn't carry.
  def resume_cron?(entry)
    marker = standdown_data
    return false unless marker

    wake = marker['wake_at_epoch'].to_i
    return false unless wake.positive? && entry['next']

    (Time.parse(entry['next']).to_i - wake).abs <= 600
  rescue StandardError
    false
  end

  def cron_segment
    data = crons_data
    return nil unless data

    backing_ids = loop_backing_cron_ids
    active = data.select { |e| e.is_a?(Hash) }
                 .reject { |e| cron_stale?(e) }
                 .reject { |e| backing_ids.include?(e['id']) }
                 .sort_by { |e| cron_sort_key(e) }
    return nil if active.empty?

    entries = active.map { |e| cron_entry_text(e) }
    name = entries.size > 1 ? 'crons' : 'cron'
    colorize("\u{25F7}#{name}:#{entries.join(" \u{00B7} ")}", :time)
  rescue StandardError
    nil
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
