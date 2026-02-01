--- Render module for blink-edit
--- Displays predictions using virtual text (ghost text style)
--- Applies predictions by replacing the entire window

local M = {}

local state = require("blink-edit.core.state")
local diff = require("blink-edit.core.diff")
local utils = require("blink-edit.utils")
local log = require("blink-edit.log")

-- Namespace for extmarks
local ns = vim.api.nvim_create_namespace("blink-edit")

---@type table<number, number[]> Buffer -> list of extmark IDs
local extmarks = {}

local visibility = { on_show = nil, on_clear = nil }

function M.set_visibility_listeners(listeners)
  if type(listeners) == "table" then
    visibility.on_show = listeners.on_show
    visibility.on_clear = listeners.on_clear
  else
    visibility.on_show = nil
    visibility.on_clear = nil
  end
end

--- Format a key string for display
---@param key string
---@return string
local function format_key_for_display(key)
  if key == "<Tab>" then
    return "Tab"
  elseif key:match("^<C%-") then
    -- <C-x> -> Ctrl+X
    return key:gsub("^<C%-(.-)>$", "Ctrl+%1")
  elseif key:match("^<M%-") then
    -- <M-x> -> Alt+X
    return key:gsub("^<M%-(.-)>$", "Alt+%1")
  elseif key:match("^<S%-") then
    -- <S-x> -> Shift+X
    return key:gsub("^<S%-(.-)>$", "Shift+%1")
  elseif key:match("^<.-") then
    -- <key> -> key
    return key:gsub("^<(.-)>$", "%1")
  end
  return key
end

--- Get the jump indicator text based on configured accept key and current mode
---@return string
local function get_jump_text()
  local cfg = require("blink-edit.config").get()
  local mode = vim.api.nvim_get_mode().mode

  -- Determine which key to show based on current mode
  local key
  if mode == "n" and cfg.keymaps and cfg.keymaps.normal and cfg.keymaps.normal.accept then
    key = cfg.keymaps.normal.accept
  elseif cfg.keymaps and cfg.keymaps.insert and cfg.keymaps.insert.accept then
    key = cfg.keymaps.insert.accept
  else
    key = "<Tab>"
  end

  local display_key = format_key_for_display(key)
  return " -> " .. display_key .. " "
end

-- =============================================================================
-- Display Functions (one per hunk type)
-- =============================================================================

--- Show an insertion hunk as virt_lines below the anchor line
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param extmark_list number[] List to append extmark IDs to
local function show_insertion(bufnr, hunk, window_start, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Anchor line: after line start_old in the window
  -- For insertion at start_old=0, anchor at line 0 (first line)
  local anchor_line = window_start + hunk.start_old - 1 -- 1-indexed buffer line
  local anchor_line_0 = anchor_line - 1 -- 0-indexed for API

  -- Clamp to buffer bounds
  if anchor_line_0 < 0 then
    anchor_line_0 = 0
  end
  if anchor_line_0 >= line_count then
    anchor_line_0 = line_count - 1
  end

  -- Build virt_lines
  local virt_lines = {}
  for _, line in ipairs(hunk.new_lines) do
    table.insert(virt_lines, { { line, "BlinkEditPreview" } })
  end

  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line_0, 0, {
    virt_lines = virt_lines,
    virt_lines_above = false, -- Show below anchor line
  })
  table.insert(extmark_list, mark_id)

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2(string.format("Insertion: %d lines after buffer line %d", #hunk.new_lines, anchor_line))
  end
end

--- Show a deletion hunk with [delete] markers at end of each line
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param extmark_list number[] List to append extmark IDs to
local function show_deletion(bufnr, hunk, window_start, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for i = 1, hunk.count_old do
    local lnum = window_start + hunk.start_old + i - 2 -- 0-indexed
    if lnum >= 0 and lnum < line_count then
      local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
        virt_text = { { " [delete]", "BlinkEditDeletion" } },
        virt_text_pos = "eol",
      })
      table.insert(extmark_list, mark_id)
    end
  end

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2(
      string.format("Deletion: %d lines starting at buffer line %d", hunk.count_old, window_start + hunk.start_old - 1)
    )
  end
end

--- Show a modification hunk with inline ghost text for each changed line
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param extmark_list number[] List to append extmark IDs to
local function show_modification(bufnr, hunk, window_start, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  if not hunk.line_changes then
    return
  end

  for _, lc in ipairs(hunk.line_changes) do
    local lnum = window_start + hunk.start_old + lc.index - 2 -- 0-indexed
    if lnum >= 0 and lnum < line_count then
      local change = lc.change

      -- Get current line length to ensure col is valid
      local ok, line_data = pcall(vim.api.nvim_buf_get_lines, bufnr, lnum, lnum + 1, false)
      local current_line = (ok and line_data[1]) or ""
      local col = math.min(change.col, #current_line)

      local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, col, {
        virt_text = { { change.text, "BlinkEditPreview" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
      table.insert(extmark_list, mark_id)

      if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
        log.debug2(string.format("Modification: %s at line %d col %d: %q", change.type, lnum + 1, col, change.text))
      end
    end
  end
end

--- Show a replacement hunk with [replace] markers and virt_lines for new content
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number 1-indexed
---@param extmark_list number[] List to append extmark IDs to
local function show_replacement(bufnr, hunk, window_start, extmark_list)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- Mark old lines with [replace]
  for i = 1, hunk.count_old do
    local lnum = window_start + hunk.start_old + i - 2 -- 0-indexed
    if lnum >= 0 and lnum < line_count then
      local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
        virt_text = { { " [replace]", "BlinkEditDeletion" } },
        virt_text_pos = "eol",
      })
      table.insert(extmark_list, mark_id)
    end
  end

  -- Show new content as virt_lines after last old line
  if hunk.count_new > 0 then
    -- Anchor at the last line being replaced
    local anchor_line_0 = window_start + hunk.start_old + hunk.count_old - 2 -- 0-indexed
    if anchor_line_0 < 0 then
      anchor_line_0 = 0
    end
    if anchor_line_0 >= line_count then
      anchor_line_0 = line_count - 1
    end

    local virt_lines = {}
    for _, line in ipairs(hunk.new_lines) do
      table.insert(virt_lines, { { line, "BlinkEditPreview" } })
    end

    local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line_0, 0, {
      virt_lines = virt_lines,
      virt_lines_above = false,
    })
    table.insert(extmark_list, mark_id)
  end

  if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
    log.debug2(
      string.format(
        "Replacement: %d old lines -> %d new lines at buffer line %d",
        hunk.count_old,
        hunk.count_new,
        window_start + hunk.start_old - 1
      )
    )
  end
end

--- Get a stable anchor line for jump indicators
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number
---@return number|nil line_0
local function get_jump_anchor_line(bufnr, hunk, window_start)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count <= 0 then
    return nil
  end

  local anchor_line = window_start + hunk.start_old - 1
  local anchor_line_0 = anchor_line - 1

  if anchor_line_0 < 0 then
    anchor_line_0 = 0
  end
  if anchor_line_0 >= line_count then
    anchor_line_0 = line_count - 1
  end

  return anchor_line_0
end

--- Show a jump indicator for the next hunk (rendered as a virtual line below the target)
---@param bufnr number
---@param hunk DiffHunk
---@param window_start number
---@param extmark_list number[]
local function show_jump_indicator(bufnr, hunk, window_start, extmark_list)
  local anchor_line_0 = get_jump_anchor_line(bufnr, hunk, window_start)
  if anchor_line_0 == nil then
    return
  end

  local jump_text = get_jump_text()

  -- Render as a virtual line below the target hunk
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_line_0, 0, {
    virt_lines = { { { jump_text, "BlinkEditJump" } } },
    virt_lines_above = false, -- Show below the anchor line
  })
  table.insert(extmark_list, mark_id)
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Clear all extmarks for a buffer
---@param bufnr number
function M.clear(bufnr)
  -- Clear all extmarks in our namespace
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  extmarks[bufnr] = nil

  -- Clear prediction state
  state.clear_prediction(bufnr)

  if visibility.on_clear then
    visibility.on_clear(bufnr)
  end
end

--- Check if there's a visible prediction
---@param bufnr number
---@return boolean
function M.has_visible(bufnr)
  local marks = extmarks[bufnr]
  return marks ~= nil and #marks > 0
end

--- Show prediction as ghost text
--- Uses vim.diff() to properly identify insertions, deletions, and modifications
--- Only shows changes at or below cursor position (next-edit semantics)
---@param bufnr number
---@param prediction BlinkEditPrediction
function M.show(bufnr, prediction)
  -- Clear existing extmarks first
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  extmarks[bufnr] = {}

  if not prediction then
    return
  end

  local snapshot = prediction.snapshot_lines
  local predicted = prediction.predicted_lines
  local window_start = prediction.window_start
  local cursor = prediction.cursor

  if not snapshot or not predicted then
    return
  end

  if prediction.accept_queue and #prediction.accept_queue > 0 then
    local delta = prediction.accept_queue_delta or 0
    local shown_count = 0
    local summary = { insertions = 0, deletions = 0, replacements = 0 }
    local first_hunk = nil

    local current = nil
    local groups = {}

    local function flush_group()
      if not current then
        return
      end
      table.insert(groups, current)
      current = nil
    end

    for _, entry in ipairs(prediction.accept_queue) do
      local kind = entry.kind
      local anchor = entry.anchor_line + delta
      if anchor < 1 then
        anchor = 1
      end
      if not current then
        current = { kind = kind, anchor_line = anchor, lines = {} }
      else
        local can_merge = false
        if kind == current.kind then
          if kind == "insertion" then
            can_merge = anchor == current.anchor_line
          else
            can_merge = anchor == current.anchor_line + #current.lines
          end
        end
        if not can_merge then
          flush_group()
          current = { kind = kind, anchor_line = anchor, lines = {} }
        end
      end
      table.insert(current.lines, entry.text or "")
    end
    flush_group()

    for _, group in ipairs(groups) do
      local hunk
      if group.kind == "insertion" then
        local start_old = group.anchor_line - 1
        hunk = {
          type = "insertion",
          start_old = start_old,
          count_old = 0,
          start_new = start_old + 1,
          count_new = #group.lines,
          old_lines = {},
          new_lines = group.lines,
        }
        summary.insertions = summary.insertions + 1
        show_insertion(bufnr, hunk, window_start, extmarks[bufnr])
      elseif group.kind == "deletion" then
        hunk = {
          type = "deletion",
          start_old = group.anchor_line,
          count_old = #group.lines,
          start_new = group.anchor_line,
          count_new = 0,
          old_lines = {},
          new_lines = {},
        }
        summary.deletions = summary.deletions + 1
        show_deletion(bufnr, hunk, window_start, extmarks[bufnr])
      elseif group.kind == "replacement" then
        hunk = {
          type = "replacement",
          start_old = group.anchor_line,
          count_old = #group.lines,
          start_new = group.anchor_line,
          count_new = #group.lines,
          old_lines = {},
          new_lines = group.lines,
        }
        summary.replacements = summary.replacements + 1
        show_replacement(bufnr, hunk, window_start, extmarks[bufnr])
      end

      if hunk then
        shown_count = shown_count + 1
        if not first_hunk then
          first_hunk = hunk
        end
      end
    end

    if first_hunk then
      show_jump_indicator(bufnr, first_hunk, window_start, extmarks[bufnr])
    end

    if visibility.on_show and extmarks[bufnr] and #extmarks[bufnr] > 0 then
      visibility.on_show(bufnr)
    end

    if vim.g.blink_edit_debug then
      log.debug(
        string.format(
          "Showing ghost text: %d hunks shown, 0 skipped (ins=%d, del=%d, mod=%d, repl=%d)",
          shown_count,
          summary.insertions,
          summary.deletions,
          0,
          summary.replacements
        )
      )
    end
    return
  end

  -- Calculate cursor offset in window (1-indexed)
  local cursor_offset = 1
  if cursor then
    cursor_offset = cursor[1] - window_start + 1
    cursor_offset = math.max(1, cursor_offset) -- Clamp to valid range
  end

  -- Compute diff using the new diff module
  local diff_result = diff.compute(snapshot, predicted)

  if not diff_result.has_changes then
    if vim.g.blink_edit_debug then
      log.debug("No changes between snapshot and predicted")
    end
    return
  end

  -- Process each hunk, but only if at or below cursor (next-edit semantics)
  local shown_count = 0
  local skipped_count = 0
  local first_hunk = nil

  for _, hunk in ipairs(diff_result.hunks) do
    -- Only show hunks at or below cursor position
    local anchor = hunk.start_old
    if hunk.type == "insertion" then
      anchor = hunk.start_old + 1
    end
    if anchor >= cursor_offset then
      shown_count = shown_count + 1
      if not first_hunk then
        first_hunk = hunk
      end
      if hunk.type == "insertion" then
        show_insertion(bufnr, hunk, window_start, extmarks[bufnr])
      elseif hunk.type == "deletion" then
        show_deletion(bufnr, hunk, window_start, extmarks[bufnr])
      elseif hunk.type == "modification" then
        show_modification(bufnr, hunk, window_start, extmarks[bufnr])
      elseif hunk.type == "replacement" then
        show_replacement(bufnr, hunk, window_start, extmarks[bufnr])
      end
    else
      skipped_count = skipped_count + 1
      if vim.g.blink_edit_debug and vim.g.blink_edit_debug >= 2 then
        log.debug2(
          string.format(
            "Skipping hunk above cursor: %s at line %d (cursor at %d)",
            hunk.type,
            anchor,
            cursor_offset
          )
        )
      end
    end
  end

  if not first_hunk and prediction.allow_fallback and diff_result.has_changes and #diff_result.hunks > 0 then
    local fallback = diff_result.hunks[1]
    if vim.g.blink_edit_debug then
      log.debug("Render fallback: showing first hunk above cursor")
    end
    if fallback.type == "insertion" then
      show_insertion(bufnr, fallback, window_start, extmarks[bufnr])
    elseif fallback.type == "deletion" then
      show_deletion(bufnr, fallback, window_start, extmarks[bufnr])
    elseif fallback.type == "modification" then
      show_modification(bufnr, fallback, window_start, extmarks[bufnr])
    elseif fallback.type == "replacement" then
      show_replacement(bufnr, fallback, window_start, extmarks[bufnr])
    end
    first_hunk = fallback
  end

  if first_hunk then
    show_jump_indicator(bufnr, first_hunk, window_start, extmarks[bufnr])
  end

  if visibility.on_show and extmarks[bufnr] and #extmarks[bufnr] > 0 then
    visibility.on_show(bufnr)
  end

  if vim.g.blink_edit_debug then
    local summary = diff.summarize(diff_result)
    log.debug(
      string.format(
        "Showing ghost text: %d hunks shown, %d skipped (ins=%d, del=%d, mod=%d, repl=%d)",
        shown_count,
        skipped_count,
        summary.insertions,
        summary.deletions,
        summary.modifications,
        summary.replacements
      )
    )
  end
end

local function build_merged_result(prediction)
  local window_start = prediction.window_start
  local snapshot = prediction.snapshot_lines
  local predicted = prediction.predicted_lines
  local cursor = prediction.cursor

  if not snapshot or not predicted then
    return nil, nil, nil
  end

  local cursor_offset = 1
  if cursor then
    cursor_offset = cursor[1] - window_start + 1
    cursor_offset = math.max(1, cursor_offset)
  end

  local diff_result = diff.compute(snapshot, predicted)
  local line_offset = 0

  for _, hunk in ipairs(diff_result.hunks) do
    if hunk.start_old < cursor_offset then
      line_offset = line_offset + (hunk.count_new - hunk.count_old)
    end
  end

  local merged = {}

  for i = 1, cursor_offset - 1 do
    table.insert(merged, snapshot[i])
  end

  local pred_start = cursor_offset + line_offset
  if pred_start < 1 then
    pred_start = 1
  end

  for i = pred_start, #predicted do
    table.insert(merged, predicted[i])
  end

  return merged, cursor_offset, line_offset
end

--- Apply a prediction to the buffer (uses supplied prediction)
---@param bufnr number
---@param prediction BlinkEditPrediction
---@return boolean success, string[]|nil merged_lines
local function apply_prediction(bufnr, prediction)
  if not prediction then
    return false, nil
  end

  local window_start = prediction.window_start
  local snapshot = prediction.snapshot_lines
  local predicted = prediction.predicted_lines

  if not snapshot or not predicted then
    return false, nil
  end

  -- Race condition check: verify buffer content still matches snapshot
  local ok, current = pcall(vim.api.nvim_buf_get_lines, bufnr, window_start - 1, window_start - 1 + #snapshot, false)

  if not ok then
    if vim.g.blink_edit_debug then
      log.debug("Failed to read buffer for prediction apply", vim.log.levels.WARN)
    end
    M.clear(bufnr)
    return false, nil
  end

  if not utils.lines_equal(current, snapshot) then
    -- Buffer changed since prediction was made, discard
    if vim.g.blink_edit_debug then
      log.debug("Buffer changed since prediction, discarding stale prediction")
    end
    M.clear(bufnr)
    return false, nil
  end
  local merged, cursor_offset, line_offset = build_merged_result(prediction)
  if not merged then
    return false, nil
  end

  -- Apply merged result
  vim.api.nvim_buf_set_lines(
    bufnr,
    window_start - 1, -- 0-indexed start
    window_start - 1 + #snapshot, -- end (exclusive)
    false,
    merged
  )

  if vim.g.blink_edit_debug then
    log.debug(
      string.format(
        "Applied prediction: cursor_offset=%d, line_offset=%d, merged=%d lines",
        cursor_offset,
        line_offset,
        #merged
      )
    )
  end

  -- Clear the visual indicators (but don't clear prediction state yet - engine needs it)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  extmarks[bufnr] = nil

  return true, merged
end

--- Apply the current prediction to the buffer
--- Only applies changes at or below cursor position (next-edit semantics)
--- Keeps snapshot content above cursor, uses predicted content at/below cursor
---@param bufnr number
---@return boolean success, string[]|nil merged_lines
function M.apply(bufnr)
  local prediction = state.get_prediction(bufnr)
  return apply_prediction(bufnr, prediction)
end

--- Apply a supplied prediction (used for partial hunks)
---@param bufnr number
---@param prediction BlinkEditPrediction
---@return boolean success, string[]|nil merged_lines
function M.apply_with_prediction(bufnr, prediction)
  return apply_prediction(bufnr, prediction)
end

--- Get namespace ID (for testing/debugging)
---@return number
function M.get_namespace()
  return ns
end

--- Get extmark IDs for a buffer (for testing/debugging)
---@param bufnr number
---@return number[]
function M.get_extmarks(bufnr)
  return extmarks[bufnr] or {}
end

return M
