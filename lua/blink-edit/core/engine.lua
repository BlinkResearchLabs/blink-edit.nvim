--- Engine module for blink-edit
--- Implements valve architecture for prediction lifecycle

local M = {}

local config = require("blink-edit.config")
local state = require("blink-edit.core.state")
local context_manager = require("blink-edit.core.context_manager")
local diff = require("blink-edit.core.diff")
local render = require("blink-edit.core.render")
local backend = require("blink-edit.backends")
local transport = require("blink-edit.transport")
local utils = require("blink-edit.utils")
local log = require("blink-edit.log")
local ui = require("blink-edit.ui")

local uv = vim.uv or vim.loop

local MAX_INVALID_RETRIES = 1

---@class DebounceTimer
---@field timer userdata|nil
---@field bufnr number

---@type table<number, DebounceTimer>
local debounce_timers = {}

-- Provider cache
local provider_cache = {}

local merge_completion

-- =============================================================================
-- Provider Management
-- =============================================================================

--- Get or create provider instance
---@return BlinkEditProvider
local function get_provider()
  local cfg = config.get()
  local name = cfg.llm.provider or "sweep"
  local provider_config = {}

  if cfg.providers and cfg.providers[name] then
    provider_config = cfg.providers[name]
  end

  -- Check cache
  local cached = provider_cache[name]
  if cached and cached.config == provider_config then
    return cached.provider
  end

  -- Create new provider
  local ok, module = pcall(require, "blink-edit.providers." .. name)
  if not ok then
    -- Fallback to generic
    module = require("blink-edit.providers.generic")
    name = "generic"
  end

  local provider
  if type(module.new) == "function" then
    provider = module.new({
      name = name,
      config = provider_config,
      global_config = cfg,
    })
  else
    provider = module
    provider.name = provider.name or name
    provider.config = provider_config
    provider.global_config = cfg
  end

  -- Cache it
  provider_cache[name] = { provider = provider, config = provider_config }

  return provider
end

-- =============================================================================
-- Debounce Management
-- =============================================================================

--- Cancel debounce timer for a buffer
---@param bufnr number
local function cancel_debounce(bufnr)
  local dt = debounce_timers[bufnr]
  if dt and dt.timer and not dt.timer:is_closing() then
    dt.timer:stop()
    dt.timer:close()
  end
  debounce_timers[bufnr] = nil
end

local function cancel_prefetch(bufnr)
  local prefetch = state.get_prefetch(bufnr)
  if prefetch and prefetch.request_id then
    transport.cancel(prefetch.request_id)
  end
  state.clear_prefetch(bufnr)
end

-- =============================================================================
-- Hunk Helpers
-- =============================================================================

---@param snapshot BlinkEditSnapshot
---@return string
local function fingerprint_snapshot(snapshot)
  local first = snapshot.lines and snapshot.lines[1] or ""
  local last = snapshot.lines and snapshot.lines[#snapshot.lines] or ""
  return table.concat({
    tostring(snapshot.window_start or 0),
    tostring(snapshot.window_end or 0),
    tostring(snapshot.cursor and snapshot.cursor[1] or 0),
    tostring(snapshot.cursor and snapshot.cursor[2] or 0),
    tostring(snapshot.lines and #snapshot.lines or 0),
    first,
    last,
  }, "|")
end

---@param lines string[]
---@param target string
---@return number|nil
local function find_line_index(lines, target)
  if not target or target == "" then
    return nil
  end
  for i, line in ipairs(lines or {}) do
    if line == target then
      return i
    end
  end
  return nil
end

--- Count leading empty/whitespace lines
---@param lines string[]
---@return number
local function count_leading_blank(lines)
  local count = 0
  for _, line in ipairs(lines or {}) do
    if line:match("%S") then
      break
    end
    count = count + 1
  end
  return count
end

--- Get first non-empty line
---@param lines string[]
---@return string|nil, number|nil
local function get_first_non_empty(lines)
  for i, line in ipairs(lines or {}) do
    if line:match("%S") then
      return line, i
    end
  end
  return nil, nil
end

--- Count trailing empty/whitespace lines
---@param lines string[]
---@return number
local function count_trailing_blank(lines)
  local count = 0
  for i = #(lines or {}), 1, -1 do
    if lines[i]:match("%S") then
      break
    end
    count = count + 1
  end
  return count
end

--- Get first N consecutive non-empty lines
---@param lines string[]
---@param count number
---@return string[]|nil anchor_lines, number|nil start_index (1-indexed)
local function get_first_consecutive_non_empty(lines, count)
  if not lines or #lines < count then
    return nil, nil
  end

  for i = 1, #lines - count + 1 do
    local all_non_empty = true
    for j = 0, count - 1 do
      if not lines[i + j]:match("%S") then
        all_non_empty = false
        break
      end
    end
    if all_non_empty then
      local result = {}
      for j = 0, count - 1 do
        table.insert(result, lines[i + j])
      end
      return result, i
    end
  end

  return nil, nil
end

--- Find where needle (consecutive lines) appears in haystack
---@param haystack string[]
---@param needle string[]
---@return number|nil match_index (1-indexed)
local function find_consecutive_match(haystack, needle)
  if not haystack or not needle or #needle == 0 then
    return nil
  end
  if #haystack < #needle then
    return nil
  end

  for i = 1, #haystack - #needle + 1 do
    local match = true
    for j = 1, #needle do
      if haystack[i + j - 1] ~= needle[j] then
        match = false
        break
      end
    end
    if match then
      return i
    end
  end

  return nil
end

--- Extract a slice of lines (1-indexed, inclusive)
---@param lines string[]
---@param start_idx number
---@param end_idx number|nil (nil = to end)
---@return string[]
local function slice_lines(lines, start_idx, end_idx)
  local result = {}
  end_idx = end_idx or #lines
  for i = start_idx, math.min(end_idx, #lines) do
    table.insert(result, lines[i])
  end
  return result
end

--- Attempt to realign a shifted/partial prediction with the snapshot
--- Handles: excess leading blanks, excess trailing blanks, suffix-only responses
---@param snapshot_lines string[]
---@param predicted_lines string[]
---@return string[]|nil realigned_lines
local function try_realign_prediction(snapshot_lines, predicted_lines)
  if not snapshot_lines or not predicted_lines or #predicted_lines == 0 then
    return nil
  end

  -- Work with a copy
  local result = {}
  for _, line in ipairs(predicted_lines) do
    table.insert(result, line)
  end

  local changed = false

  -- Step 1: Strip excess leading blanks
  local snapshot_leading = count_leading_blank(snapshot_lines)
  local predicted_leading = count_leading_blank(result)
  if predicted_leading > snapshot_leading then
    local excess = predicted_leading - snapshot_leading
    result = slice_lines(result, excess + 1, nil)
    changed = true
    if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
      log.debug2(string.format("Realign: stripped %d leading blanks", excess))
    end
  end

  -- Step 2: Strip excess trailing blanks
  local snapshot_trailing = count_trailing_blank(snapshot_lines)
  local predicted_trailing = count_trailing_blank(result)
  if predicted_trailing > snapshot_trailing then
    local excess = predicted_trailing - snapshot_trailing
    result = slice_lines(result, 1, #result - excess)
    changed = true
    if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
      log.debug2(string.format("Realign: stripped %d trailing blanks", excess))
    end
  end

  -- Step 3: If still shorter than snapshot, try anchor alignment
  if #result < #snapshot_lines then
    local anchor, anchor_idx = get_first_consecutive_non_empty(result, 2)
    if anchor then
      local match_idx = find_consecutive_match(snapshot_lines, anchor)
      if match_idx and match_idx > 1 then
        -- Prepend snapshot prefix
        local prefix = slice_lines(snapshot_lines, 1, match_idx - 1)
        local new_result = {}
        for _, line in ipairs(prefix) do
          table.insert(new_result, line)
        end
        for _, line in ipairs(result) do
          table.insert(new_result, line)
        end
        result = new_result
        changed = true
        if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
          log.debug2(string.format("Realign: prepended %d lines (anchor at snapshot line %d)", #prefix, match_idx))
        end
      end
    end
  end

  if not changed then
    if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
      log.debug2("Realign: no adjustment needed")
    end
  end

  return result
end

---@param snapshot_lines string[]
---@param predicted_lines string[]
---@return boolean invalid, string|nil reason
local function is_invalid_prediction(snapshot_lines, predicted_lines)
  if not snapshot_lines or not predicted_lines then
    return false, nil
  end

  local snapshot_len = #snapshot_lines
  local predicted_len = #predicted_lines

  -- Check if prediction is all empty/whitespace
  local first_non_empty, first_idx = get_first_non_empty(predicted_lines)
  if not first_non_empty then
    return true, "all_empty"
  end

  -- Check leading blank mismatch
  local snapshot_leading = count_leading_blank(snapshot_lines)
  local predicted_leading = count_leading_blank(predicted_lines)
  if predicted_leading > snapshot_leading + 1 then
    return true, "leading_blank_mismatch"
  end

  -- Use first non-empty line as anchor instead of first line
  if snapshot_len > 10 and first_non_empty then
    local anchor = find_line_index(snapshot_lines, first_non_empty)
    if anchor and anchor > math.floor(snapshot_len / 4) then
      return true, "anchor_too_far"
    end
  end

  return false, nil
end

--- Check if two line arrays differ only in trailing empty/whitespace lines
---@param snapshot_lines string[]
---@param predicted_lines string[]
---@return boolean
local function is_only_trailing_whitespace_change(snapshot_lines, predicted_lines)
  if not snapshot_lines or not predicted_lines then
    return false
  end

  -- Strip trailing empty/whitespace lines from both
  local function strip_trailing(lines)
    local result = {}
    local last_non_empty = 0
    for i, line in ipairs(lines) do
      if line:match("%S") then
        last_non_empty = i
      end
    end
    for i = 1, last_non_empty do
      result[i] = lines[i]
    end
    return result
  end

  local stripped_snapshot = strip_trailing(snapshot_lines)
  local stripped_predicted = strip_trailing(predicted_lines)

  if #stripped_snapshot ~= #stripped_predicted then
    return false
  end

  for i = 1, #stripped_snapshot do
    if stripped_snapshot[i] ~= stripped_predicted[i] then
      return false
    end
  end

  -- If we get here, the non-trailing content is identical
  -- so the only changes are trailing whitespace
  return true
end

---@param window_start number
---@param cursor { [1]: number, [2]: number }|nil
---@return number
local function get_cursor_offset(window_start, cursor)
  local cursor_offset = 1
  if cursor then
    cursor_offset = cursor[1] - window_start + 1
    cursor_offset = math.max(1, cursor_offset)
  end
  return cursor_offset
end

---@param hunks DiffHunk[]
---@param cursor_offset number
---@return DiffHunk|nil
local function find_next_hunk(hunks, cursor_offset)
  for _, hunk in ipairs(hunks or {}) do
    local anchor = hunk.start_old
    if hunk.type == "insertion" then
      anchor = hunk.start_old + 1
    end
    if anchor >= cursor_offset then
      return hunk
    end
  end
  return nil
end

---@param lines string[]
---@param hunk DiffHunk
---@return string[]
local function apply_hunk_lines(lines, hunk)
  local result = {}

  local before_end
  if hunk.count_old == 0 then
    before_end = hunk.start_old
  else
    before_end = hunk.start_old - 1
  end
  before_end = math.max(before_end, 0)

  for i = 1, math.min(before_end, #lines) do
    table.insert(result, lines[i])
  end

  for _, line in ipairs(hunk.new_lines or {}) do
    table.insert(result, line)
  end

  local after_start
  if hunk.count_old == 0 then
    after_start = hunk.start_old + 1
  else
    after_start = hunk.start_old + hunk.count_old
  end
  after_start = math.max(after_start, 1)

  for i = after_start, #lines do
    table.insert(result, lines[i])
  end

  return result
end

--- Get a stable anchor line for hunk visibility/queue
---@param hunk DiffHunk
---@return number
local function get_hunk_anchor_line(hunk)
  if hunk.type == "insertion" then
    return hunk.start_old + 1
  end
  return hunk.start_old
end

--- Build a visible-only accept queue from the current prediction
---@param prediction BlinkEditPrediction
---@return { kind: string, anchor_line: number, text: string|nil }[]|nil
local function build_accept_queue(prediction)
  local snapshot = prediction.snapshot_lines
  local predicted = prediction.predicted_lines
  if not snapshot or not predicted then
    return nil
  end

  local cursor_offset = get_cursor_offset(prediction.window_start, prediction.cursor)
  local diff_result = diff.compute(snapshot, predicted)
  if not diff_result.has_changes or #diff_result.hunks == 0 then
    return nil
  end

  local queue = {}

  for _, hunk in ipairs(diff_result.hunks) do
    local anchor = get_hunk_anchor_line(hunk)
    if anchor < cursor_offset then
      goto continue
    end

    if hunk.type == "insertion" then
      local insert_anchor = hunk.start_old + 1
      for _, line in ipairs(hunk.new_lines or {}) do
        table.insert(queue, { kind = "insertion", anchor_line = insert_anchor, text = line })
      end
    elseif hunk.type == "deletion" then
      for i = 1, hunk.count_old do
        table.insert(queue, { kind = "deletion", anchor_line = hunk.start_old + i - 1 })
      end
    elseif hunk.type == "modification" then
      for i = 1, hunk.count_old do
        local old_line = (hunk.old_lines and hunk.old_lines[i]) or ""
        local new_line = (hunk.new_lines and hunk.new_lines[i]) or ""
        if old_line ~= new_line then
          table.insert(queue, { kind = "replacement", anchor_line = hunk.start_old + i - 1, text = new_line })
        end
      end
    elseif hunk.type == "replacement" then
      local min_lines = math.min(hunk.count_old, hunk.count_new)
      for i = 1, min_lines do
        local old_line = (hunk.old_lines and hunk.old_lines[i]) or ""
        local new_line = (hunk.new_lines and hunk.new_lines[i]) or ""
        if old_line ~= new_line then
          table.insert(queue, { kind = "replacement", anchor_line = hunk.start_old + i - 1, text = new_line })
        end
      end

      if hunk.count_new > hunk.count_old then
        local insert_anchor = hunk.start_old + min_lines
        for i = min_lines + 1, hunk.count_new do
          local new_line = (hunk.new_lines and hunk.new_lines[i]) or ""
          table.insert(queue, { kind = "insertion", anchor_line = insert_anchor, text = new_line })
        end
      elseif hunk.count_old > hunk.count_new then
        for i = min_lines + 1, hunk.count_old do
          table.insert(queue, { kind = "deletion", anchor_line = hunk.start_old + i - 1 })
        end
      end
    end

    ::continue::
  end

  if #queue == 0 then
    return nil
  end

  return queue
end

--- Apply a single queue entry and update snapshot
---@param bufnr number
---@param prediction BlinkEditPrediction
---@param entry { kind: string, anchor_line: number, text: string|nil }
---@param delta number
---@return boolean success, number new_delta, number applied_line, string|nil applied_text
local function apply_queue_entry(bufnr, prediction, entry, delta)
  local snapshot = prediction.snapshot_lines
  if not snapshot then
    return false, delta, 0, nil
  end

  local effective_line = entry.anchor_line + delta
  if effective_line < 1 then
    effective_line = 1
  end

  if entry.kind == "insertion" then
    if effective_line > #snapshot + 1 then
      effective_line = #snapshot + 1
    end
    local text = entry.text or ""
    local buf_line = prediction.window_start + effective_line - 1
    vim.api.nvim_buf_set_lines(bufnr, buf_line - 1, buf_line - 1, false, { text })
    table.insert(snapshot, effective_line, text)
    return true, delta + 1, effective_line, text
  elseif entry.kind == "deletion" then
    if effective_line > #snapshot then
      return false, delta, effective_line, nil
    end
    local buf_line = prediction.window_start + effective_line - 1
    vim.api.nvim_buf_set_lines(bufnr, buf_line - 1, buf_line, false, {})
    table.remove(snapshot, effective_line)
    return true, delta - 1, effective_line, nil
  elseif entry.kind == "replacement" then
    if effective_line > #snapshot then
      return false, delta, effective_line, nil
    end
    local text = entry.text or ""
    local buf_line = prediction.window_start + effective_line - 1
    vim.api.nvim_buf_set_lines(bufnr, buf_line - 1, buf_line, false, { text })
    snapshot[effective_line] = text
    return true, delta, effective_line, text
  end

  return false, delta, effective_line, nil
end

---@param hunk DiffHunk
---@param window_start number
---@param lines string[]
---@return number, number
local function compute_hunk_end_cursor(hunk, window_start, lines)
  local end_line
  local end_col

  if hunk.count_new == 0 or hunk.type == "deletion" then
    end_line = window_start + hunk.start_new - 1
    end_col = 0
  else
    local hunk_end = hunk.start_new + hunk.count_new - 1
    hunk_end = math.max(1, math.min(hunk_end, #lines))
    end_line = window_start + hunk_end - 1
    end_col = #(lines[hunk_end] or "")
  end

  return end_line, end_col
end

-- =============================================================================
-- Request Lifecycle
-- =============================================================================

--- Start a new prediction request (called when valve opens)
---@param bufnr number
---@param snapshot BlinkEditSnapshot
local function start_request(bufnr, snapshot)
  local cfg = config.get()

  -- Get baseline (captured on InsertEnter)
  local baseline = state.get_baseline(bufnr)
  if not baseline then
    -- No baseline - capture one now as fallback
    state.capture_baseline(bufnr)
    baseline = state.get_baseline(bufnr)
    if not baseline then
      if vim.g.blink_edit_debug then
        log.debug("No baseline available, skipping request", vim.log.levels.WARN)
      end
      return
    end
  end

  local force_request = snapshot.force_request == true

  if vim.g.blink_edit_debug then
    log.debug(
      string.format(
        "start_request: force=%s window=%d-%d",
        tostring(force_request),
        snapshot.window_start or -1,
        snapshot.window_end or -1
      )
    )
  end

  -- Skip if nothing changed from baseline (no edit to predict)
  if not force_request and utils.lines_equal(baseline.lines, snapshot.lines) then
    if vim.g.blink_edit_debug then
      log.debug("Skipping request: no changes from baseline")
    end
    return
  end

  -- Get provider
  local provider = get_provider()

  -- Get provider requirements
  local requirements = provider:get_requirements()

  -- Build context limits from config
  local limits = {
    max_history_tokens = cfg.context.history.max_tokens or 512,
    max_context_tokens = cfg.context.max_tokens or 512,
    max_history_entries = cfg.context.history.max_items or 5,
    max_files = cfg.context.history.max_files or 2,
  }

  -- Collect context based on requirements
  local context_data = context_manager.collect(bufnr, baseline, snapshot, requirements, limits)

  -- Build prompt (provider handles all formatting)
  local prompt, metadata, build_err = provider:build_prompt(context_data, limits)

  if not prompt or not metadata then
    if vim.g.blink_edit_debug then
      log.debug("Failed to build prompt: " .. (build_err or "unknown"))
    end
    return
  end

  if vim.g.blink_edit_debug then
    log.debug(
      string.format(
        "Starting request, window=%d-%d, history=%d",
        metadata.window_start,
        metadata.window_end,
        #context_data.history
      )
    )
  end

  -- Log full prompt at debug level 2
  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2("=== PROMPT ===\n" .. prompt .. "\n=== END PROMPT ===")
  end

  -- Get stop tokens from provider
  local stop_tokens = provider:get_stop_tokens()

  -- Send request and track it
  local request_id = backend.complete({
    prompt = prompt,
    model = cfg.llm.model,
    max_tokens = cfg.llm.max_tokens,
    temperature = cfg.llm.temperature,
    stop = stop_tokens,
  }, function(err, result)
    -- Schedule callback to run in main loop
    vim.schedule(function()
      on_response(bufnr, err, result, metadata, snapshot, provider)
    end)
  end)

  -- Track in_flight state
  state.set_in_flight(bufnr, request_id)

  -- Show progress indicator
  ui.show_progress()
end

local function on_prefetch_response(bufnr, err, result, metadata, snapshot, provider, request_id)
  local prefetch = state.get_prefetch(bufnr)
  if not prefetch or prefetch.request_id ~= request_id then
    return
  end

  prefetch.in_flight = false

  if err or not result or not result.text then
    state.clear_prefetch(bufnr)
    return
  end

  local cfg = config.get()

  local predicted_lines, parse_err = provider:parse_response(result.text, snapshot.lines)
  if not predicted_lines then
    if vim.g.blink_edit_debug then
      log.debug("Prefetch invalid response: " .. (parse_err or "unknown"))
    end
    state.clear_prefetch(bufnr)
    return
  end

  -- Try to realign shifted/partial responses
  local realigned = try_realign_prediction(snapshot.lines, predicted_lines)
  if realigned then
    predicted_lines = realigned
  end

  local cursor_after = nil
  if cfg.mode == "completion" then
    local merged, after, merge_err = merge_completion(snapshot, predicted_lines)
    if not merged then
      if vim.g.blink_edit_debug then
        log.debug("Prefetch invalid completion: " .. (merge_err or "unknown"))
      end
      state.clear_prefetch(bufnr)
      return
    end
    predicted_lines = merged
    cursor_after = after
  end

  if cfg.mode ~= "completion" then
    local invalid = is_invalid_prediction(snapshot.lines, predicted_lines)
    if invalid then
      state.clear_prefetch(bufnr)
      return
    end
  end

  local has_changes = false
  if #predicted_lines ~= #snapshot.lines then
    has_changes = true
  else
    for i = 1, #predicted_lines do
      if predicted_lines[i] ~= snapshot.lines[i] then
        has_changes = true
        break
      end
    end
  end

  if not has_changes then
    state.clear_prefetch(bufnr)
    return
  end

  -- Discard if only trailing whitespace changed
  if is_only_trailing_whitespace_change(snapshot.lines, predicted_lines) then
    state.clear_prefetch(bufnr)
    return
  end

  prefetch.prediction = {
    predicted_lines = predicted_lines,
    snapshot_lines = snapshot.lines,
    window_start = metadata.window_start,
    window_end = metadata.window_end,
    response_text = result.text,
    created_at = uv.now(),
    cursor_after = cursor_after,
    cursor = snapshot.cursor,
  }

  state.set_prefetch(bufnr, prefetch)
end

local function start_prefetch_request(bufnr, snapshot)
  local cfg = config.get()
  if not cfg.prefetch or not cfg.prefetch.enabled then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if state.is_in_flight(bufnr) then
    return
  end

  local existing = state.get_prefetch(bufnr)
  if existing and existing.in_flight then
    return
  end

  local baseline = state.get_baseline(bufnr)
  if not baseline then
    state.capture_baseline(bufnr)
    baseline = state.get_baseline(bufnr)
    if not baseline then
      return
    end
  end

  local provider = get_provider()
  local requirements = provider:get_requirements()

  local limits = {
    max_history_tokens = cfg.context.history.max_tokens,
    max_context_tokens = cfg.context.max_tokens,
    max_history_entries = cfg.context.history.max_items,
    max_files = cfg.context.history.max_files,
  }

  local context_data = context_manager.collect(bufnr, baseline, snapshot, requirements, limits)
  local prompt, metadata, build_err = provider:build_prompt(context_data, limits)
  if not prompt or not metadata then
    if vim.g.blink_edit_debug then
      log.debug("Prefetch failed to build prompt: " .. (build_err or "unknown"))
    end
    return
  end

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2("=== PREFETCH PROMPT ===\n" .. prompt .. "\n=== END PREFETCH PROMPT ===")
  end

  local stop_tokens = provider:get_stop_tokens()
  local request_id = backend.complete({
    prompt = prompt,
    model = cfg.llm.model,
    max_tokens = cfg.llm.max_tokens,
    temperature = cfg.llm.temperature,
    stop = stop_tokens,
  }, function(err, result)
    vim.schedule(function()
      on_prefetch_response(bufnr, err, result, metadata, snapshot, provider, request_id)
    end)
  end)

  state.set_prefetch(bufnr, {
    request_id = request_id,
    snapshot = snapshot,
    created_at = uv.now(),
    in_flight = true,
  })
end

--- Handle response from LLM
---@param bufnr number
---@param err string|table|nil
---@param result table|nil
---@param metadata table
---@param snapshot BlinkEditSnapshot
---@param provider BlinkEditProvider
function on_response(bufnr, err, result, metadata, snapshot, provider)
  -- Clear in_flight state
  state.clear_in_flight(bufnr)

  -- Hide progress indicator
  ui.hide_progress()

  local cfg = config.get()

  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if there's a pending snapshot in the stack
  if state.has_pending_snapshot(bufnr) then
    -- Discard this response - we have fresher data
    if vim.g.blink_edit_debug then
      log.debug("Discarding stale response, processing stack")
    end

    local pending = state.pop_from_stack(bufnr)
    if pending then
      start_request(bufnr, pending)
    end
    return
  end

  -- Handle error
  if err then
    if type(err) == "table" then
      local err_type = err.type
      local err_message = err.message or "Unknown error"

      if err_type == "connection" or err_type == "curl_error" then
        log.error("Cannot connect to LLM server. Is it running?")
      elseif err_type == "timeout" then
        log.error("Request timed out")
      elseif err_type == "server" then
        log.error("Server error: " .. err_message)
      else
        log.debug("Request failed: " .. err_message, vim.log.levels.WARN)
      end
    else
      log.debug("Request failed: " .. tostring(err), vim.log.levels.WARN)
    end
    return
  end

  -- Handle empty response
  if not result or not result.text then
    if vim.g.blink_edit_debug then
      log.debug("Empty response", vim.log.levels.WARN)
    end
    return
  end

  -- Log full response at debug level 2
  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2("=== RESPONSE ===\n" .. result.text .. "\n=== END RESPONSE ===")
  end

  -- Parse response using provider
  local predicted_lines, parse_err = provider:parse_response(result.text, snapshot.lines)
  if not predicted_lines then
    if vim.g.blink_edit_debug then
      log.debug("Invalid response: " .. (parse_err or "unknown"))
    end
    return
  end

  -- Try to realign shifted/partial responses
  local realigned = try_realign_prediction(snapshot.lines, predicted_lines)
  if realigned then
    predicted_lines = realigned
  end

  local cursor_after = nil
  if cfg.mode == "completion" then
    local merged, after, merge_err = merge_completion(snapshot, predicted_lines)
    if not merged then
      if vim.g.blink_edit_debug then
        log.debug("Invalid completion: " .. (merge_err or "unknown"))
      end
      return
    end
    predicted_lines = merged
    cursor_after = after
  end

  local allow_fallback = false
  if cfg.mode ~= "completion" then
    local invalid, reason = is_invalid_prediction(snapshot.lines, predicted_lines)
    if invalid then
      local fingerprint = fingerprint_snapshot(snapshot)
      local count = state.bump_invalid_response(bufnr, fingerprint)
      if vim.g.blink_edit_debug then
        log.debug(string.format("Invalid prediction (%s), retry=%d", tostring(reason), count))
      end
      if count <= MAX_INVALID_RETRIES then
        M.trigger_force(bufnr)
        return
      end
      allow_fallback = true
    else
      state.clear_invalid_response(bufnr)
    end
  end

  -- Check if prediction is same as current (no changes)
  local has_changes = false
  if #predicted_lines ~= #snapshot.lines then
    has_changes = true
  else
    for i = 1, #predicted_lines do
      if predicted_lines[i] ~= snapshot.lines[i] then
        has_changes = true
        break
      end
    end
  end

  if not has_changes then
    if vim.g.blink_edit_debug then
      log.debug("No changes detected in prediction")
    end
    return
  end

  -- Discard if only trailing whitespace changed
  if is_only_trailing_whitespace_change(snapshot.lines, predicted_lines) then
    if vim.g.blink_edit_debug then
      log.debug("Discarding prediction: only trailing whitespace changes")
    end
    return
  end

  cancel_prefetch(bufnr)

  -- Store prediction with snapshot and predicted lines
  local prediction = {
    predicted_lines = predicted_lines,
    snapshot_lines = snapshot.lines,
    window_start = metadata.window_start,
    window_end = metadata.window_end,
    response_text = result.text,
    created_at = uv.now(),
    cursor_after = cursor_after,
    cursor = snapshot.cursor, -- Cursor position when prediction was made
    allow_fallback = allow_fallback,
  }
  if allow_fallback then
    state.clear_invalid_response(bufnr)
  end
  state.set_prediction(bufnr, prediction)

  -- Render ghost text
  ui.close_lsp_floats()
  render.show(bufnr, prediction)

  if vim.g.blink_edit_debug then
    log.debug(
      string.format("Showing prediction: %d snapshot lines -> %d predicted lines", #snapshot.lines, #predicted_lines)
    )
  end
end

--- Merge completion into snapshot (for completion mode)
---@param snapshot BlinkEditSnapshot
---@param completion_lines string[]
---@return string[]|nil merged
---@return table|nil cursor_after
---@return string|nil error
merge_completion = function(snapshot, completion_lines)
  if not completion_lines or #completion_lines == 0 then
    return nil, nil, "empty completion"
  end

  local cursor_line = snapshot.cursor[1]
  local cursor_col = snapshot.cursor[2]
  local window_start = snapshot.window_start

  local cursor_index = cursor_line - window_start + 1
  if cursor_index < 1 or cursor_index > #snapshot.lines then
    return nil, nil, "cursor outside window"
  end

  local current_line = snapshot.lines[cursor_index] or ""
  local prefix = current_line:sub(1, cursor_col)
  local suffix = current_line:sub(cursor_col + 1)

  local merged = {}
  for i = 1, cursor_index - 1 do
    table.insert(merged, snapshot.lines[i])
  end

  if #completion_lines == 1 then
    table.insert(merged, prefix .. completion_lines[1] .. suffix)
  else
    table.insert(merged, prefix .. completion_lines[1])
    for i = 2, #completion_lines - 1 do
      table.insert(merged, completion_lines[i])
    end
    table.insert(merged, (completion_lines[#completion_lines] or "") .. suffix)
  end

  for i = cursor_index + 1, #snapshot.lines do
    table.insert(merged, snapshot.lines[i])
  end

  local cursor_after_line = cursor_line + #completion_lines - 1
  local cursor_after_col
  if #completion_lines == 1 then
    cursor_after_col = #prefix + #completion_lines[1]
  else
    cursor_after_col = #(completion_lines[#completion_lines] or "")
  end

  return merged, { cursor_after_line, cursor_after_col }, nil
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Trigger a prediction (debounced) - called on TextChangedI
---@param bufnr number
function M.trigger(bufnr)
  local cfg = config.get()

  cancel_prefetch(bufnr)

  -- Cancel existing debounce timer
  cancel_debounce(bufnr)

  -- Check if buffer is valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if plugin is enabled
  if vim.g.blink_edit_enabled == false then
    return
  end

  -- Check filetype
  local ft = vim.bo[bufnr].filetype
  if not config.is_filetype_enabled(ft) then
    return
  end

  -- Create new debounce timer
  local timer = uv.new_timer()
  debounce_timers[bufnr] = {
    timer = timer,
    bufnr = bufnr,
  }

  -- Start debounce timer
  timer:start(cfg.debounce_ms, 0, function()
    -- Timer fired - close it
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    debounce_timers[bufnr] = nil

    -- Run valve logic in main loop
    vim.schedule(function()
      M._on_debounce_fired(bufnr)
    end)
  end)
end

--- Called when debounce timer fires
---@param bufnr number
---@param opts? { force_request?: boolean }
function M._on_debounce_fired(bufnr, opts)
  local cfg = config.get()
  local force_request = opts and opts.force_request

  -- Check if buffer is still valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- 1. Clear existing ghost text
  render.clear(bufnr)

  -- 2. Capture snapshot (current state)
  local snapshot = state.capture_snapshot(bufnr)
  if snapshot and force_request then
    snapshot.force_request = true
  end

  if vim.g.blink_edit_debug then
    local line_count = snapshot and snapshot.lines and #snapshot.lines or 0
    log.debug(string.format("Debounce fired (force=%s, snapshot_lines=%d)", tostring(force_request), line_count))
  end

  -- 3. Push to stack (replaces any existing)
  state.push_to_stack(bufnr, snapshot)

  -- 4. Check valve state
  if state.is_in_flight(bufnr) then
    if cfg.cancel_in_flight then
      -- Cancel the in-flight request and start new one immediately
      local request_id = state.get_in_flight_request_id(bufnr)
      if request_id then
        transport.cancel(request_id)
      end
      state.clear_in_flight(bufnr)

      if vim.g.blink_edit_debug then
        log.debug("Cancelled in-flight request, starting new")
      end

      -- Pop from stack and start request
      local pending = state.pop_from_stack(bufnr)
      if pending then
        start_request(bufnr, pending)
      end
    else
      -- Valve closed - wait for current request to complete
      if vim.g.blink_edit_debug then
        log.debug("Valve closed, pushed to stack")
      end
    end
  else
    -- Valve open - start request immediately
    local pending = state.pop_from_stack(bufnr)
    if pending then
      start_request(bufnr, pending)
    end
  end
end

--- Trigger a prediction immediately (bypass debounce)
---@param bufnr number
function M.trigger_now(bufnr)
  -- Cancel any existing debounce
  cancel_debounce(bufnr)

  -- Check if buffer is valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if plugin is enabled
  if vim.g.blink_edit_enabled == false then
    return
  end

  -- Directly fire the debounce logic
  M._on_debounce_fired(bufnr)
end

--- Trigger a prediction immediately (force request)
---@param bufnr number
function M.trigger_force(bufnr)
  -- Cancel any existing debounce
  cancel_debounce(bufnr)

  cancel_prefetch(bufnr)

  -- Check if buffer is valid
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Check if plugin is enabled
  if vim.g.blink_edit_enabled == false then
    return
  end

  if vim.g.blink_edit_debug then
    log.debug(
      string.format(
        "Force trigger requested (in_flight=%s, pending=%s)",
        tostring(state.is_in_flight(bufnr)),
        tostring(state.has_pending_snapshot(bufnr))
      )
    )
  end

  -- Directly fire the debounce logic (force request)
  M._on_debounce_fired(bufnr, { force_request = true })
end

--- Cancel pending request for a buffer
---@param bufnr number
function M.cancel(bufnr)
  -- Cancel debounce timer
  cancel_debounce(bufnr)

  cancel_prefetch(bufnr)

  -- Cancel in-flight request
  local request_id = state.get_in_flight_request_id(bufnr)
  if request_id then
    transport.cancel(request_id)
    state.clear_in_flight(bufnr)
    ui.hide_progress()
  end

  -- Clear ghost text and prediction
  render.clear(bufnr)
end

--- Cancel any prefetch request for a buffer
---@param bufnr number
function M.cancel_prefetch(bufnr)
  cancel_prefetch(bufnr)
end

--- Accept the current prediction
---@param bufnr number
---@return boolean success
function M.accept(bufnr)
  local prediction = state.get_prediction(bufnr)
  if not prediction then
    return false
  end

  if prediction.accept_queue and #prediction.accept_queue > 0 then
    local queue = prediction.accept_queue
    local delta = prediction.accept_queue_delta or 0
    local last_line = nil
    local last_text = nil
    local last_kind = nil
    local snapshot_before = vim.deepcopy(prediction.snapshot_lines or {})

    for _, entry in ipairs(queue) do
      state.set_suppress_trigger(bufnr, true)
      local success
      success, delta, last_line, last_text = apply_queue_entry(bufnr, prediction, entry, delta)
      if not success then
        return false
      end
      last_kind = entry.kind
    end

    prediction.accept_queue = nil
    prediction.accept_queue_delta = nil
    prediction.predicted_lines = prediction.snapshot_lines
    state.set_prediction(bufnr, prediction)
    cancel_debounce(bufnr)

    if last_line then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local cursor_line = prediction.window_start + last_line - 1
      cursor_line = math.max(1, math.min(cursor_line, line_count))
      local cursor_col = 0
      if last_kind == "deletion" then
        local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, cursor_line - 1, cursor_line, false)
        local line_content = (ok and line_data[1]) or ""
        local prev_col = prediction.cursor and prediction.cursor[2] or 0
        cursor_col = math.min(prev_col, #line_content)
      else
        cursor_col = #(last_text or "")
      end
      vim.api.nvim_win_set_cursor(0, { cursor_line, cursor_col })
      prediction.cursor = { cursor_line, cursor_col }
    end

    local cfg = config.get()
    if cfg.context.enabled and cfg.context.history.enabled and cfg.llm.provider ~= "zeta" then
      local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))
      local step_diff = diff.compute(snapshot_before, prediction.snapshot_lines or {})
      for _, hunk in ipairs(step_diff.hunks) do
        local original_text = table.concat(hunk.old_lines or {}, "\n")
        local updated_text = table.concat(hunk.new_lines or {}, "\n")

        local start_old = hunk.count_old > 0 and (prediction.window_start + hunk.start_old - 1) or nil
        local end_old = hunk.count_old > 0 and (prediction.window_start + hunk.start_old + hunk.count_old - 2) or nil
        local start_new = hunk.count_new > 0 and (prediction.window_start + hunk.start_new - 1) or nil
        local end_new = hunk.count_new > 0 and (prediction.window_start + hunk.start_new + hunk.count_new - 2) or nil

        local start_line = start_new or start_old
        local end_line = end_new or end_old

        state.add_to_history(bufnr, filepath, original_text, updated_text, {
          start_line = start_line,
          end_line = end_line,
          start_line_old = start_old,
          end_line_old = end_old,
          start_line_new = start_new,
          end_line_new = end_new,
        })
      end
    end

    if vim.g.blink_edit_debug then
      log.debug("Accept: applied queued lines")
    end

    render.clear(bufnr)
    state.clear_selection(bufnr)
    state.update_baseline(bufnr)

    local prefetch = state.get_prefetch(bufnr)
    if prefetch and prefetch.prediction and prefetch.snapshot then
      local snapshot_match =
        prefetch.snapshot.window_start == prediction.window_start
        and prefetch.snapshot.window_end == prediction.window_end
        and utils.lines_equal(prefetch.snapshot.lines, prediction.snapshot_lines)
      if snapshot_match then
        state.set_prediction(bufnr, prefetch.prediction)
        state.clear_prefetch(bufnr)
        render.show(bufnr, prefetch.prediction)
        return true
      end
    end

    cancel_prefetch(bufnr)
    M.trigger_force(bufnr)
    return true
  end

  local snapshot_lines = prediction.snapshot_lines
  local predicted_lines = prediction.predicted_lines
  local window_start = prediction.window_start

  if not snapshot_lines or not predicted_lines then
    return false
  end

  local cursor_offset = get_cursor_offset(window_start, prediction.cursor)
  local diff_result = diff.compute(snapshot_lines, predicted_lines)

  if not diff_result.has_changes or #diff_result.hunks == 0 then
    if vim.g.blink_edit_debug then
      log.debug("Accept: no diff hunks, nothing to apply")
    end
    render.clear(bufnr)
    state.clear_selection(bufnr)
    cancel_debounce(bufnr)
    return false
  end

  local next_hunk = find_next_hunk(diff_result.hunks, cursor_offset)
  if not next_hunk then
    if prediction.allow_fallback and diff_result.hunks[1] then
      if vim.g.blink_edit_debug then
        log.debug("Accept fallback: applying first hunk above cursor")
      end
      next_hunk = diff_result.hunks[1]
    else
      if vim.g.blink_edit_debug then
        log.debug("Accept: no hunk at/below cursor, forcing request")
      end
      render.clear(bufnr)
      state.clear_selection(bufnr)
      cancel_debounce(bufnr)
      M.trigger_force(bufnr)
      state.update_baseline(bufnr)
      return false
    end
  end

  -- Apply only the next hunk
  state.set_suppress_trigger(bufnr, true)
  local partial_predicted = apply_hunk_lines(snapshot_lines, next_hunk)
  local partial_prediction = {
    predicted_lines = partial_predicted,
    snapshot_lines = snapshot_lines,
    window_start = prediction.window_start,
    window_end = prediction.window_end,
    response_text = prediction.response_text,
    created_at = prediction.created_at,
    cursor = prediction.cursor,
  }

  local success, merged_lines = render.apply_with_prediction(bufnr, partial_prediction)
  if not success then
    if vim.g.blink_edit_debug then
      log.debug("Accept: partial apply failed")
    end
    state.set_suppress_trigger(bufnr, false)
    return false
  end

  local cfg = config.get()
  if cfg.context.enabled and cfg.context.history.enabled and cfg.llm.provider ~= "zeta" then
    -- Add per-hunk history from applied content
    local cursor_offset_history = cursor_offset
    local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))

    local step_diff = diff.compute(snapshot_lines, merged_lines or partial_predicted)
    for _, hunk in ipairs(step_diff.hunks) do
      if hunk.start_old >= cursor_offset_history then
        local original_text = table.concat(hunk.old_lines or {}, "\n")
        local updated_text = table.concat(hunk.new_lines or {}, "\n")

        local start_old = hunk.count_old > 0 and (window_start + hunk.start_old - 1) or nil
        local end_old = hunk.count_old > 0 and (window_start + hunk.start_old + hunk.count_old - 2) or nil
        local start_new = hunk.count_new > 0 and (window_start + hunk.start_new - 1) or nil
        local end_new = hunk.count_new > 0 and (window_start + hunk.start_new + hunk.count_new - 2) or nil

        local start_line = start_new or start_old
        local end_line = end_new or end_old

        state.add_to_history(bufnr, filepath, original_text, updated_text, {
          start_line = start_line,
          end_line = end_line,
          start_line_old = start_old,
          end_line_old = end_old,
          start_line_new = start_new,
          end_line_new = end_new,
        })
      end
    end
  end

  -- Update prediction state for the remaining hunks
  prediction.snapshot_lines = merged_lines or partial_predicted

  local end_line, end_col = compute_hunk_end_cursor(next_hunk, window_start, partial_predicted)

  -- Ensure line is valid
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if end_line > line_count then
    end_line = line_count
  end
  if end_line < 1 then
    end_line = 1
  end

  -- Get line content to ensure col is valid
  local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, end_line - 1, end_line, false)
  local line_content = (ok and line_data[1]) or ""
  if end_col > #line_content then
    end_col = #line_content
  end
  if end_col < 0 then
    end_col = 0
  end

  vim.api.nvim_win_set_cursor(0, { end_line, end_col })
  prediction.cursor = { end_line, end_col }
  state.set_prediction(bufnr, prediction)

  -- Cancel any pending debounce to prevent stale request from TextChangedI
  cancel_debounce(bufnr)

  -- Check if more hunks remain at/below cursor
  local remaining = diff.compute(prediction.snapshot_lines, prediction.predicted_lines)
  local remaining_hunk = nil
  local remaining_hunks = {}
  if remaining.has_changes and #remaining.hunks > 0 then
    local new_cursor_offset = get_cursor_offset(window_start, prediction.cursor)
    for _, hunk in ipairs(remaining.hunks) do
      if hunk.start_old >= new_cursor_offset then
        table.insert(remaining_hunks, hunk)
      end
    end
    remaining_hunk = remaining_hunks[1]
  end

  if cfg.prefetch and cfg.prefetch.enabled and cfg.prefetch.strategy == "n-1" then
    if #remaining_hunks == 1 then
      local target_hunk = remaining_hunks[1]
      local end_line, end_col = compute_hunk_end_cursor(target_hunk, window_start, prediction.predicted_lines)
      local prefetch_snapshot = {
        lines = prediction.predicted_lines,
        window_start = prediction.window_start,
        window_end = prediction.window_end,
        cursor = { end_line, end_col },
        timestamp = uv.now(),
        force_request = true,
      }
      start_prefetch_request(bufnr, prefetch_snapshot)
    end
  end

  if remaining_hunk then
    if vim.g.blink_edit_debug then
      log.debug("Accept: remaining hunks, re-rendering")
    end
    render.show(bufnr, prediction)
  else
    if vim.g.blink_edit_debug then
      log.debug("Accept: last hunk applied, forcing request")
    end
    render.clear(bufnr)
    state.clear_selection(bufnr)
    state.update_baseline(bufnr)

    local prefetch = state.get_prefetch(bufnr)
    if prefetch and prefetch.prediction and prefetch.snapshot then
      local snapshot_match =
        prefetch.snapshot.window_start == prediction.window_start
        and prefetch.snapshot.window_end == prediction.window_end
        and utils.lines_equal(prefetch.snapshot.lines, prediction.snapshot_lines)
      if snapshot_match then
        state.set_prediction(bufnr, prefetch.prediction)
        state.clear_prefetch(bufnr)
        render.show(bufnr, prefetch.prediction)
        return true
      end
    end

    cancel_prefetch(bufnr)
    M.trigger_force(bufnr)
  end

  if vim.g.blink_edit_debug then
    log.debug(string.format("Accepted hunk, history=%d", state.get_history_count(bufnr)))
  end

  return true
end

--- Accept only the first line of the current hunk
--- For multi-line hunks: accepts first line, keeps rest visible
--- For single-line hunks: same as accept()
--- For deletion hunks: accepts full deletion (can't partially delete)
---@param bufnr number
---@return boolean success
function M.accept_line(bufnr)
  local prediction = state.get_prediction(bufnr)
  if not prediction then
    return false
  end
  local function finalize_prediction()
    if vim.g.blink_edit_debug then
      log.debug("Accept line: last line applied")
    end

    render.clear(bufnr)
    state.clear_selection(bufnr)
    state.update_baseline(bufnr)

    local prefetch = state.get_prefetch(bufnr)
    if prefetch and prefetch.prediction and prefetch.snapshot then
      local snapshot_match =
        prefetch.snapshot.window_start == prediction.window_start
        and prefetch.snapshot.window_end == prediction.window_end
        and utils.lines_equal(prefetch.snapshot.lines, prediction.snapshot_lines)
      if snapshot_match then
        state.set_prediction(bufnr, prefetch.prediction)
        state.clear_prefetch(bufnr)
        render.show(bufnr, prefetch.prediction)
        return true
      end
    end

    cancel_prefetch(bufnr)
    M.trigger_force(bufnr)
    return true
  end

  if not prediction.accept_queue then
    local queue = build_accept_queue(prediction)
    if not queue or #queue == 0 then
      return M.accept(bufnr)
    end
    prediction.accept_queue = queue
    prediction.accept_queue_delta = 0
    state.set_prediction(bufnr, prediction)
  end

  local entry = table.remove(prediction.accept_queue, 1)
  if not entry then
    prediction.accept_queue = nil
    prediction.accept_queue_delta = nil
    return finalize_prediction()
  end

  state.set_suppress_trigger(bufnr, true)
  local success, new_delta, applied_line, applied_text =
    apply_queue_entry(bufnr, prediction, entry, prediction.accept_queue_delta or 0)
  if not success then
    return false
  end

  prediction.accept_queue_delta = new_delta

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local cursor_line = prediction.window_start + applied_line - 1
  cursor_line = math.max(1, math.min(cursor_line, line_count))
  local cursor_col = 0
  if entry.kind == "deletion" then
    local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, cursor_line - 1, cursor_line, false)
    local line_content = (ok and line_data[1]) or ""
    local prev_col = prediction.cursor and prediction.cursor[2] or 0
    cursor_col = math.min(prev_col, #line_content)
  else
    cursor_col = #(applied_text or "")
  end

  vim.api.nvim_win_set_cursor(0, { cursor_line, cursor_col })
  prediction.cursor = { cursor_line, cursor_col }
  state.set_prediction(bufnr, prediction)
  cancel_debounce(bufnr)

  if #prediction.accept_queue == 0 then
    prediction.accept_queue = nil
    prediction.accept_queue_delta = nil
    return finalize_prediction()
  end

  render.show(bufnr, prediction)
  return true
end

--- Clear prediction without leaving insert mode (soft dismiss)
--- Unlike reject(), this doesn't cancel in-flight requests
---@param bufnr number
function M.clear(bufnr)
  cancel_debounce(bufnr)
  render.clear(bufnr)

  if vim.g.blink_edit_debug then
    log.debug("Prediction cleared (soft dismiss)")
  end
end

--- Reject the current prediction
---@param bufnr number
function M.reject(bufnr)
  -- Cancel debounce and in-flight
  cancel_debounce(bufnr)

  cancel_prefetch(bufnr)

  local request_id = state.get_in_flight_request_id(bufnr)
  if request_id then
    transport.cancel(request_id)
    state.clear_in_flight(bufnr)
  end

  -- Clear ghost text
  render.clear(bufnr)

  if vim.g.blink_edit_debug then
    log.debug("Prediction rejected")
  end
end

--- Check if there's an active prediction
---@param bufnr number
---@return boolean
function M.has_prediction(bufnr)
  return render.has_visible(bufnr)
end

--- Called when cursor moves - check if we should clear prediction
---@param bufnr number
function M.on_cursor_moved(bufnr)
  local prediction = state.get_prediction(bufnr)
  if not prediction then
    return
  end

  -- Get current cursor position
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]

  -- Check if cursor is still within the prediction window
  local start_line = prediction.window_start
  local end_line = prediction.window_start + math.max(#prediction.snapshot_lines, #prediction.predicted_lines) - 1

  -- Allow some tolerance (2 lines above/below)
  if cursor_line < start_line - 2 or cursor_line > end_line + 2 then
    -- Cursor moved away from prediction area - clear it
    M.reject(bufnr)
  end
end

--- Called on InsertEnter - capture baseline
---@param bufnr number
function M.on_insert_enter(bufnr)
  -- Capture baseline (state before user's edits in this insert session)
  state.capture_baseline(bufnr)

  -- If there's a pending snapshot in the stack from a previous session,
  -- we could start a request here, but typically the stack should be empty
  if state.has_pending_snapshot(bufnr) and not state.is_in_flight(bufnr) then
    local pending = state.pop_from_stack(bufnr)
    if pending then
      start_request(bufnr, pending)
    end
  end
end

--- Called on InsertLeave - cleanup
---@param bufnr number
function M.on_insert_leave(bufnr)
  -- Cancel in-flight request
  local request_id = state.get_in_flight_request_id(bufnr)
  if request_id then
    transport.cancel(request_id)
    state.clear_in_flight(bufnr)
  end

  cancel_prefetch(bufnr)

  -- Clear ghost text
  render.clear(bufnr)
end

--- Cleanup engine state (called on reset)
function M.cleanup()
  -- Cancel all debounce timers
  for bufnr, _ in pairs(debounce_timers) do
    cancel_debounce(bufnr)
  end
  debounce_timers = {}

  -- Clear provider cache
  provider_cache = {}

  -- Clear all state
  state.clear_all()
end

return M
