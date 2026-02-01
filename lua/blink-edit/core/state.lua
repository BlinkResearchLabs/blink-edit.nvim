--- State management for blink-edit
--- Implements valve architecture with global history and per-buffer baseline

local M = {}

local config = require("blink-edit.config")
local utils = require("blink-edit.utils")
local log = require("blink-edit.log")

---@class BlinkEditBaseline
---@field lines string[] Lines in the context window
---@field window_start number 1-indexed start line
---@field window_end number 1-indexed end line
---@field cursor { [1]: number, [2]: number } Cursor position when captured
---@field timestamp number

---@class BlinkEditSnapshot
---@field lines string[] Lines in the context window
---@field window_start number 1-indexed start line
---@field window_end number 1-indexed end line
---@field cursor { [1]: number, [2]: number } Cursor position when captured
---@field timestamp number
---@field force_request boolean|nil

---@class BlinkEditPrediction
---@field predicted_lines string[] Full predicted window content from LLM
---@field snapshot_lines string[] Buffer content when request was sent
---@field window_start number 1-indexed start line of context window
---@field window_end number 1-indexed end line of context window
---@field response_text string Raw LLM response
---@field created_at number
---@field cursor_after { [1]: number, [2]: number }|nil Cursor position after applying (completion)
---@field cursor { [1]: number, [2]: number } Cursor position when prediction was made
---@field allow_fallback boolean|nil
---@field accept_queue { kind: string, anchor_line: number, text: string|nil }[]|nil
---@field accept_queue_delta number|nil

---@class BlinkEditPrefetch
---@field request_id number|nil
---@field snapshot BlinkEditSnapshot|nil
---@field prediction BlinkEditPrediction|nil
---@field created_at number|nil
---@field in_flight boolean|nil

---@class BlinkEditHistoryEntry
---@field filepath string
---@field original string Context window before edit
---@field updated string Context window after edit
---@field start_line number|nil
---@field end_line number|nil
---@field start_line_old number|nil
---@field end_line_old number|nil
---@field start_line_new number|nil
---@field end_line_new number|nil
---@field timestamp number

---@class BlinkEditSelection
---@field filepath string
---@field start_line number
---@field end_line number
---@field lines string[]
---@field timestamp number

---@class BlinkEditValve
---@field stack BlinkEditSnapshot|nil Latest pending snapshot (cap at 1)
---@field in_flight { request_id: number|nil, timestamp: number|nil }

---@class BlinkEditBufferState
---@field baseline BlinkEditBaseline|nil Captured on InsertEnter
---@field valve BlinkEditValve
---@field prediction BlinkEditPrediction|nil Current visible prediction
---@field history BlinkEditHistoryEntry[]
---@field selection BlinkEditSelection|nil
---@field history_files string[]|nil
---@field suppress_next_trigger boolean|nil
---@field invalid_response { fingerprint: string, count: number }|nil
---@field prefetch BlinkEditPrefetch|nil

---@type table<number, BlinkEditBufferState>
local buffers = {}

---@type BlinkEditHistoryEntry[]
local global_history = {}

---@type string[]
local global_history_files = {}

---@type BlinkEditSelection|nil
local global_selection = nil

-- =============================================================================
-- Helper Functions
-- =============================================================================

--- Calculate context window bounds around cursor
---@param cursor_line number 1-indexed cursor line
---@param total_lines number Total lines in buffer
---@return number, number start_line, end_line (1-indexed)
local function get_window_bounds(cursor_line, total_lines)
  local ctx = config.get_context_lines()
  local lines_before = ctx.lines_before
  local lines_after = ctx.lines_after

  local start_line = math.max(1, cursor_line - lines_before)
  local end_line = math.min(total_lines, cursor_line + lines_after)

  -- Adjust if we hit boundaries
  if start_line == 1 then
    end_line = math.min(total_lines, 1 + lines_before + lines_after)
  elseif end_line == total_lines then
    start_line = math.max(1, total_lines - lines_before - lines_after)
  end

  return start_line, end_line
end

--- Extract lines within a window
---@param all_lines string[]
---@param start_line number 1-indexed
---@param end_line number 1-indexed
---@return string[]
local function extract_window(all_lines, start_line, end_line)
  local result = {}
  for i = start_line, math.min(end_line, #all_lines) do
    table.insert(result, all_lines[i])
  end
  return result
end

--- Get or create buffer state
---@param bufnr number
---@return BlinkEditBufferState
local function get_or_create(bufnr)
  if not buffers[bufnr] then
    buffers[bufnr] = {
      baseline = nil,
      valve = {
        stack = nil,
        in_flight = {
          request_id = nil,
          timestamp = nil,
        },
      },
      prediction = nil,
      history = {},
      selection = nil,
      history_files = nil,
      suppress_next_trigger = false,
      suppress_next_normal_move = false,
      invalid_response = nil,
      prefetch = nil,
    }
  end
  return buffers[bufnr]
end

--- Rebuild file order list from history (oldest-first)
---@param history BlinkEditHistoryEntry[]
---@return string[]
local function rebuild_file_order(history)
  local seen = {}
  local order = {}
  for _, entry in ipairs(history) do
    if entry.filepath and not seen[entry.filepath] then
      seen[entry.filepath] = true
      table.insert(order, entry.filepath)
    end
  end
  return order
end

--- Enforce max_items and max_files constraints
---@param history BlinkEditHistoryEntry[]
---@param max_items number
---@param max_files number
---@return BlinkEditHistoryEntry[], string[]
local function enforce_history_limits(history, max_items, max_files)
  if max_files == 0 then
    return {}, {}
  end

  while #history > max_items do
    table.remove(history, 1)
  end

  local file_order = rebuild_file_order(history)
  if max_files > 0 then
    while #file_order > max_files do
      local drop_file = table.remove(file_order, 1)
      if drop_file then
        local filtered = {}
        for _, entry in ipairs(history) do
          if entry.filepath ~= drop_file then
            table.insert(filtered, entry)
          end
        end
        history = filtered
      end
      file_order = rebuild_file_order(history)
    end
  end

  return history, file_order
end

-- =============================================================================
-- Baseline Management (captured on InsertEnter)
-- =============================================================================

--- Capture baseline for a buffer (call on InsertEnter)
---@param bufnr number
function M.capture_baseline(bufnr)
  local state = get_or_create(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok then
    return
  end

  local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok_cursor then
    cursor = { 1, 0 }
  end
  local cursor_line = cursor[1]

  local window_start, window_end = get_window_bounds(cursor_line, #lines)
  local window_lines = extract_window(lines, window_start, window_end)

  state.baseline = {
    lines = window_lines,
    window_start = window_start,
    window_end = window_end,
    cursor = cursor,
    timestamp = vim.uv.now(),
  }

  if vim.g.blink_edit_debug then
    log.debug(string.format("Captured baseline, window=%d-%d", window_start, window_end))
  end
end

--- Get baseline for a buffer
---@param bufnr number
---@return BlinkEditBaseline|nil
function M.get_baseline(bufnr)
  local state = buffers[bufnr]
  return state and state.baseline
end

--- Update baseline after accepting a prediction
---@param bufnr number
function M.update_baseline(bufnr)
  M.capture_baseline(bufnr)
end

-- =============================================================================
-- Snapshot Management (captured on debounce trigger)
-- =============================================================================

--- Capture current snapshot for a buffer
---@param bufnr number
---@return BlinkEditSnapshot
function M.capture_snapshot(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok then
    return nil
  end

  local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok_cursor then
    cursor = { 1, 0 }
  end
  local cursor_line = cursor[1]

  local window_start, window_end = get_window_bounds(cursor_line, #lines)
  local window_lines = extract_window(lines, window_start, window_end)

  return {
    lines = window_lines,
    window_start = window_start,
    window_end = window_end,
    cursor = cursor,
    timestamp = vim.uv.now(),
  }
end

-- =============================================================================
-- Valve Management (stack and in_flight tracking)
-- =============================================================================

--- Push a snapshot to the stack (replaces any existing)
---@param bufnr number
---@param snapshot BlinkEditSnapshot
function M.push_to_stack(bufnr, snapshot)
  if not snapshot then
    return
  end
  local state = get_or_create(bufnr)
  state.valve.stack = snapshot

  if vim.g.blink_edit_debug then
    log.debug("Pushed snapshot to stack")
  end
end

--- Pop snapshot from the stack
---@param bufnr number
---@return BlinkEditSnapshot|nil
function M.pop_from_stack(bufnr)
  local state = buffers[bufnr]
  if not state then
    return nil
  end

  local snapshot = state.valve.stack
  state.valve.stack = nil
  return snapshot
end

--- Check if stack has a pending snapshot
---@param bufnr number
---@return boolean
function M.has_pending_snapshot(bufnr)
  local state = buffers[bufnr]
  return state ~= nil and state.valve.stack ~= nil
end

--- Set in_flight state
---@param bufnr number
---@param request_id number|nil
function M.set_in_flight(bufnr, request_id)
  local state = get_or_create(bufnr)
  if request_id then
    state.valve.in_flight = {
      request_id = request_id,
      timestamp = vim.uv.now(),
    }
  else
    state.valve.in_flight = {
      request_id = nil,
      timestamp = nil,
    }
  end
end

--- Check if there's a request in flight
---@param bufnr number
---@return boolean
function M.is_in_flight(bufnr)
  local state = buffers[bufnr]
  return state ~= nil and state.valve.in_flight.request_id ~= nil
end

--- Get the current in_flight request ID
---@param bufnr number
---@return number|nil
function M.get_in_flight_request_id(bufnr)
  local state = buffers[bufnr]
  if state then
    return state.valve.in_flight.request_id
  end
  return nil
end

--- Clear in_flight state
---@param bufnr number
function M.clear_in_flight(bufnr)
  M.set_in_flight(bufnr, nil)
end

-- =============================================================================
-- Prediction Management
-- =============================================================================

--- Set the current prediction
---@param bufnr number
---@param prediction BlinkEditPrediction
function M.set_prediction(bufnr, prediction)
  local state = get_or_create(bufnr)
  state.prediction = prediction
end

--- Get the current prediction
---@param bufnr number
---@return BlinkEditPrediction|nil
function M.get_prediction(bufnr)
  local state = buffers[bufnr]
  return state and state.prediction
end

--- Check if buffer has an active prediction
---@param bufnr number
---@return boolean
function M.has_prediction(bufnr)
  local state = buffers[bufnr]
  return state ~= nil and state.prediction ~= nil
end

--- Clear the current prediction
---@param bufnr number
function M.clear_prediction(bufnr)
  local state = buffers[bufnr]
  if state then
    state.prediction = nil
  end
end

-- =============================================================================
-- Trigger Suppression
-- =============================================================================

--- Suppress the next TextChangedI trigger for a buffer
---@param bufnr number
---@param value boolean
function M.set_suppress_trigger(bufnr, value)
  local state = get_or_create(bufnr)
  state.suppress_next_trigger = value and true or false
end

--- Consume the suppress flag (returns true once)
---@param bufnr number
---@return boolean
function M.consume_suppress_trigger(bufnr)
  local state = buffers[bufnr]
  if state and state.suppress_next_trigger then
    state.suppress_next_trigger = false
    return true
  end
  return false
end

-- =============================================================================
-- Normal-mode Cursor Suppression
-- =============================================================================

--- Suppress the next CursorMoved in normal mode
---@param bufnr number
---@param value boolean
function M.set_suppress_normal_move(bufnr, value)
  local state = get_or_create(bufnr)
  state.suppress_next_normal_move = value and true or false
end

--- Consume the suppress flag (returns true once)
---@param bufnr number
---@return boolean
function M.consume_suppress_normal_move(bufnr)
  local state = buffers[bufnr]
  if state and state.suppress_next_normal_move then
    state.suppress_next_normal_move = false
    return true
  end
  return false
end

-- =============================================================================
-- Invalid Response Tracking
-- =============================================================================

--- Increment invalid response count for a fingerprint
---@param bufnr number
---@param fingerprint string
---@return number count
function M.bump_invalid_response(bufnr, fingerprint)
  local state = get_or_create(bufnr)
  if state.invalid_response and state.invalid_response.fingerprint == fingerprint then
    state.invalid_response.count = state.invalid_response.count + 1
  else
    state.invalid_response = { fingerprint = fingerprint, count = 1 }
  end
  return state.invalid_response.count
end

--- Clear invalid response tracking
---@param bufnr number
function M.clear_invalid_response(bufnr)
  local state = buffers[bufnr]
  if state then
    state.invalid_response = nil
  end
end

-- =============================================================================
-- Prefetch Management
-- =============================================================================

--- Store prefetch state
---@param bufnr number
---@param prefetch BlinkEditPrefetch|nil
function M.set_prefetch(bufnr, prefetch)
  local state = get_or_create(bufnr)
  state.prefetch = prefetch
end

--- Get prefetch state
---@param bufnr number
---@return BlinkEditPrefetch|nil
function M.get_prefetch(bufnr)
  local state = buffers[bufnr]
  return state and state.prefetch
end

--- Clear prefetch state
---@param bufnr number
function M.clear_prefetch(bufnr)
  local state = buffers[bufnr]
  if state then
    state.prefetch = nil
  end
end

-- =============================================================================
-- History Management
-- =============================================================================

--- Add an accepted edit to history
---@param bufnr number
---@param filepath string
---@param original string Original context window text
---@param updated string Updated context window text
---@param meta? table
function M.add_to_history(bufnr, filepath, original, updated, meta)
  local cfg = config.get()
  local history_cfg = cfg.context.history
  if not cfg.context.enabled or not history_cfg.enabled then
    return
  end

  if cfg.llm and cfg.llm.provider == "zeta" then
    return
  end

  filepath = utils.normalize_filepath(filepath)

  meta = meta or {}
  local entry = {
    filepath = filepath,
    original = original,
    updated = updated,
    start_line = meta.start_line,
    end_line = meta.end_line,
    start_line_old = meta.start_line_old,
    end_line_old = meta.end_line_old,
    start_line_new = meta.start_line_new,
    end_line_new = meta.end_line_new,
    timestamp = vim.uv.now(),
  }

  if history_cfg.global then
    table.insert(global_history, entry)

    local trimmed, file_order = enforce_history_limits(global_history, history_cfg.max_items, history_cfg.max_files)
    global_history = trimmed
    global_history_files = file_order
  else
    local state = get_or_create(bufnr)
    table.insert(state.history, entry)
    state.history, state.history_files =
      enforce_history_limits(state.history, history_cfg.max_items, history_cfg.max_files)
  end

  if vim.g.blink_edit_debug then
    local count = history_cfg.global and #global_history or #get_or_create(bufnr).history
    log.debug(string.format("Added to history, total=%d", count))
  end
end

--- Get history entries for a buffer
---@param bufnr number
---@return BlinkEditHistoryEntry[]
function M.get_history(bufnr)
  local cfg = config.get()
  local history_cfg = cfg.context.history
  if not cfg.context.enabled then
    if #global_history > 0 then
      global_history = {}
      global_history_files = {}
    end
    if global_selection then
      global_selection = nil
    end
    for _, state in pairs(buffers) do
      state.history = {}
      state.selection = nil
      state.history_files = nil
    end
    return {}
  end

  if not history_cfg.enabled then
    return {}
  end

  if history_cfg.global then
    return global_history
  end

  local state = buffers[bufnr]
  return state and state.history or {}
end

--- Clear history entries
---@param bufnr? number
function M.clear_history(bufnr)
  if bufnr then
    local state = buffers[bufnr]
    if state then
      state.history = {}
      state.history_files = nil
    end
    return
  end

  global_history = {}
  global_history_files = {}
  for _, state in pairs(buffers) do
    state.history = {}
    state.history_files = nil
  end
end

--- Get history count
---@param bufnr number
---@return number
function M.get_history_count(bufnr)
  local cfg = config.get()
  local history_cfg = cfg.context.history
  if not cfg.context.enabled or not history_cfg.enabled then
    return 0
  end

  if history_cfg.global then
    return #global_history
  end

  local state = buffers[bufnr]
  return state and #state.history or 0
end

-- =============================================================================
-- Selection Management
-- =============================================================================

--- Set the latest visual selection
---@param bufnr number
---@param selection BlinkEditSelection
function M.set_selection(bufnr, selection)
  local cfg = config.get()
  if not cfg.context.enabled or not cfg.context.selection.enabled then
    return
  end

  if cfg.context.history.global then
    global_selection = selection
  else
    local state = get_or_create(bufnr)
    state.selection = selection
  end
end

--- Get the latest visual selection
---@param bufnr number
---@return BlinkEditSelection|nil
function M.get_selection(bufnr)
  local cfg = config.get()
  if not cfg.context.enabled or not cfg.context.selection.enabled then
    return nil
  end

  if cfg.context.history.global then
    return global_selection
  end

  local state = buffers[bufnr]
  return state and state.selection or nil
end

--- Clear selection
---@param bufnr? number
function M.clear_selection(bufnr)
  if bufnr then
    local state = buffers[bufnr]
    if state then
      state.selection = nil
    end
    return
  end

  global_selection = nil
  for _, state in pairs(buffers) do
    state.selection = nil
  end
end

-- =============================================================================
-- Buffer Helpers
-- =============================================================================

--- Get current buffer lines
---@param bufnr number
---@return string[]
function M.get_current_lines(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
  if not ok then
    return {}
  end

  return lines
end

--- Get lines within a range
---@param bufnr number
---@param start_line number 1-indexed start line
---@param end_line number 1-indexed end line (inclusive)
---@return string[]
function M.get_lines_range(bufnr, start_line, end_line)
  -- Convert to 0-indexed for nvim_buf_get_lines
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_line - 1, end_line, false)
  if not ok then
    return {}
  end

  return lines
end

-- =============================================================================
-- Cleanup
-- =============================================================================

--- Clear all state for a buffer
---@param bufnr number
function M.clear(bufnr)
  buffers[bufnr] = nil
end

--- Clear all state (for reset)
function M.clear_all()
  buffers = {}
  global_history = {}
  global_history_files = {}
  global_selection = nil
end

--- Get buffer state (for debugging)
---@param bufnr number
---@return BlinkEditBufferState|nil
function M.get_state(bufnr)
  return buffers[bufnr]
end

--- Get all tracked buffers (for debugging)
---@return number[]
function M.get_tracked_buffers()
  local result = {}
  for bufnr, _ in pairs(buffers) do
    table.insert(result, bufnr)
  end
  return result
end

return M
