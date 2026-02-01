--- Context Manager for blink-edit
--- Collects raw context data in a neutral format for providers
---
--- This module is provider-agnostic. It collects all available context
--- based on provider requirements and returns data in a neutral format.
--- Providers are responsible for formatting the data into their specific
--- prompt structure.

local M = {}

local config = require("blink-edit.config")
local state = require("blink-edit.core.state")
local utils = require("blink-edit.utils")
local log = require("blink-edit.log")

-- =============================================================================
-- Silent LSP Request Helper
-- =============================================================================

--- Perform LSP request without triggering progress notifications
--- (Suppresses fidget.nvim, lualine LSP status, etc.)
---@param bufnr number
---@param method string
---@param params table
---@param timeout_ms number
---@return table|nil results
local function silent_lsp_request(bufnr, method, params, timeout_ms)
  -- Save current progress handler
  local old_progress_handler = vim.lsp.handlers["$/progress"]

  -- Temporarily suppress progress notifications
  vim.lsp.handlers["$/progress"] = function() end

  -- Make the request
  local results = vim.lsp.buf_request_sync(bufnr, method, params, timeout_ms)

  -- Restore the original handler
  vim.lsp.handlers["$/progress"] = old_progress_handler

  return results
end

local function get_attached_clients(bufnr)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients({ bufnr = bufnr })
  end

  local clients = vim.lsp.get_active_clients()
  if not clients then
    return {}
  end

  local attached = {}
  for _, client in ipairs(clients) do
    if client.attached_buffers and client.attached_buffers[bufnr] then
      table.insert(attached, client)
    end
  end
  return attached
end

local function client_supports_method(client, method)
  if client.supports_method then
    return client.supports_method(method)
  end

  local caps = client.server_capabilities or {}
  if method == "textDocument/references" then
    return caps.referencesProvider ~= nil and caps.referencesProvider ~= false
  end
  if method == "textDocument/definition" then
    return caps.definitionProvider ~= nil and caps.definitionProvider ~= false
  end

  return false
end

local function buffer_supports_method(bufnr, method)
  local clients = get_attached_clients(bufnr)
  for _, client in ipairs(clients) do
    if client_supports_method(client, method) then
      return true
    end
  end
  return false
end

-- =============================================================================
-- Data Structure Definitions
-- =============================================================================

---@class BlinkEditWindowData
---@field lines string[] Lines in the window
---@field start_line number 1-indexed start line
---@field end_line number 1-indexed end line

---@class BlinkEditDiagnostic
---@field line number 1-indexed line number
---@field col number 0-indexed column
---@field severity string "error" | "warning" | "info" | "hint"
---@field message string Diagnostic message
---@field source string|nil Source (e.g., "pyright", "eslint")

---@class BlinkEditLspLocation
---@field filepath string File containing the location
---@field start_line number 1-indexed start line
---@field end_line number 1-indexed end line
---@field lines string[] Content lines

---@class BlinkEditContextData
---@field filepath string Relative file path
---@field filetype string Vim filetype
---@field baseline_window BlinkEditWindowData State at InsertEnter
---@field current_window BlinkEditWindowData Current state
---@field cursor { line: number, col: number } Cursor position (1-indexed line, 0-indexed col)
---@field full_file_lines string[] All lines in buffer
---@field history BlinkEditHistoryEntry[] Recent edit history (already trimmed)
---@field diagnostics BlinkEditDiagnostic[] LSP diagnostics
---@field selection BlinkEditSelection|nil Visual selection (if any)
---@field lsp_definitions BlinkEditLspLocation[] Go-to-definition results
---@field lsp_references BlinkEditLspLocation[] Find-references results

---@class BlinkEditContextLimits
---@field max_history_tokens number Token budget for history
---@field max_context_tokens number Token budget for other context
---@field max_history_entries number Max number of history entries
---@field max_files number Max files in history

---@class BlinkEditProviderRequirements
---@field needs_history boolean Include edit history
---@field needs_diagnostics boolean Include LSP diagnostics
---@field needs_full_file boolean Include full file content
---@field needs_lsp_definitions boolean Include go-to-definition results
---@field needs_lsp_references boolean Include find-references results
---@field needs_selection boolean Include visual selection
---@field local_context_lines number|nil Lines before/after editable region (Zeta)

-- =============================================================================
-- Constants
-- =============================================================================

local SEVERITY_MAP = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warning",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

-- =============================================================================
-- Helper Functions
-- =============================================================================

--- Get filepath for a buffer
---@param bufnr number
---@return string
local function get_filepath(bufnr)
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  return utils.normalize_filepath(filepath)
end

--- Estimate token count for a history entry
---@param entry BlinkEditHistoryEntry
---@return number
local function estimate_history_entry_tokens(entry)
  if not entry then
    return 0
  end
  local chars = 0
  chars = chars + #(entry.filepath or "")
  chars = chars + #(entry.original or "")
  chars = chars + #(entry.updated or "")
  chars = chars + 32 -- overhead for formatting
  return math.ceil(chars / utils.CHARS_PER_TOKEN)
end

-- =============================================================================
-- History Management
-- =============================================================================

--- Trim history entries to fit within limits
---@param entries BlinkEditHistoryEntry[]
---@param max_tokens number
---@param max_entries number
---@return BlinkEditHistoryEntry[]
function M.trim_history(entries, max_tokens, max_entries)
  if not entries or #entries == 0 then
    return {}
  end

  -- First apply max_entries limit (keep most recent)
  local limited = entries
  if max_entries > 0 and #entries > max_entries then
    limited = {}
    local start_idx = #entries - max_entries + 1
    for i = start_idx, #entries do
      table.insert(limited, entries[i])
    end
  end

  -- Then apply token limit (keep most recent within budget)
  if max_tokens <= 0 then
    return limited
  end

  local result = {}
  local total_tokens = 0

  -- Iterate from newest to oldest
  for i = #limited, 1, -1 do
    local entry = limited[i]
    local entry_tokens = estimate_history_entry_tokens(entry)

    if total_tokens + entry_tokens <= max_tokens then
      table.insert(result, 1, entry) -- Prepend to maintain order
      total_tokens = total_tokens + entry_tokens
    else
      break -- Stop when we exceed budget
    end
  end

  return result
end

-- =============================================================================
-- Diagnostics Collection
-- =============================================================================

--- Collect LSP diagnostics for a buffer
---@param bufnr number
---@param window_start number|nil Optional: only include diagnostics within window
---@param window_end number|nil Optional: only include diagnostics within window
---@return BlinkEditDiagnostic[]
function M.collect_diagnostics(bufnr, window_start, window_end)
  local diagnostics = vim.diagnostic.get(bufnr)
  if not diagnostics or #diagnostics == 0 then
    return {}
  end

  local result = {}
  for _, diag in ipairs(diagnostics) do
    local line = diag.lnum + 1 -- Convert to 1-indexed

    -- Filter by window if specified
    if window_start and window_end then
      if line < window_start or line > window_end then
        goto continue
      end
    end

    table.insert(result, {
      line = line,
      col = diag.col or 0,
      severity = SEVERITY_MAP[diag.severity] or "info",
      message = diag.message or "",
      source = diag.source,
    })

    ::continue::
  end

  -- Sort by line number
  table.sort(result, function(a, b)
    return a.line < b.line
  end)

  return result
end

-- =============================================================================
-- LSP Location Collection
-- =============================================================================

--- Get lines for a URI with context
---@param uri string
---@param anchor_line number 1-indexed line to center on
---@param lines_before number
---@param lines_after number
---@return string[]|nil lines
---@return string|nil filepath
local function get_lines_for_uri(uri, anchor_line, lines_before, lines_after)
  local bufnr = vim.uri_to_bufnr(uri)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, nil
  end

  -- Load buffer if not loaded
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    pcall(vim.fn.bufload, bufnr)
  end

  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, nil
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, anchor_line - lines_before)
  local end_line = math.min(line_count, anchor_line + lines_after)

  if start_line > end_line then
    return nil, nil
  end

  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, start_line - 1, end_line, false)
  if not ok then
    return nil, nil
  end
  local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))

  return lines, filepath
end

--- Extract URI and range from LSP location result
---@param location table
---@return string|nil uri
---@return table|nil range
local function location_to_uri_range(location)
  if not location then
    return nil, nil
  end

  -- Standard location
  if location.uri and location.range then
    return location.uri, location.range
  end

  -- LocationLink
  if location.targetUri and location.targetRange then
    return location.targetUri, location.targetRange
  end

  return nil, nil
end

--- Collect LSP locations (definitions or references)
---@param bufnr number
---@param method string "textDocument/definition" or "textDocument/references"
---@param timeout_ms number
---@param max_items number
---@param lines_before number
---@param lines_after number
---@param current_filepath string Filepath of current buffer (to exclude)
---@param current_window_start number Window start (to exclude overlapping locations)
---@param current_window_end number Window end (to exclude overlapping locations)
---@return BlinkEditLspLocation[]
function M.collect_lsp_locations(
  bufnr,
  method,
  timeout_ms,
  max_items,
  lines_before,
  lines_after,
  current_filepath,
  current_window_start,
  current_window_end
)
  if not buffer_supports_method(bufnr, method) then
    if not state.has_lsp_unsupported_warned(bufnr, method) then
      state.mark_lsp_unsupported_warned(bufnr, method)
      if vim.g.blink_edit_debug then
        log.debug(string.format("LSP does not support %s; skipping for this buffer", method))
      end
    end
    return {}
  end

  local params = vim.lsp.util.make_position_params()
  if method == "textDocument/references" then
    params.context = { includeDeclaration = false }
  end

  -- Use silent wrapper to avoid progress notifications (fidget.nvim, etc.)
  local results = silent_lsp_request(bufnr, method, params, timeout_ms)
  if not results then
    return {}
  end

  local locations = {}
  local seen = {}

  for _, res in pairs(results) do
    local result = res.result
    if result then
      if vim.islist(result) then
        for _, loc in ipairs(result) do
          table.insert(locations, loc)
        end
      else
        table.insert(locations, result)
      end
    end
  end

  local output = {}
  for _, loc in ipairs(locations) do
    if #output >= max_items then
      break
    end

    local uri, range = location_to_uri_range(loc)
    if uri and range then
      local start_line = (range.start.line or 0) + 1
      local end_line = (range["end"].line or 0) + 1
      local key = string.format("%s:%d:%d", uri, start_line, end_line)

      if not seen[key] then
        seen[key] = true

        local lines, filepath = get_lines_for_uri(uri, start_line, lines_before, lines_after)
        if lines and #lines > 0 then
          local snippet_start = math.max(1, start_line - lines_before)
          local snippet_end = start_line + lines_after

          -- Skip if overlaps with current window
          local overlaps = filepath == current_filepath
            and snippet_start <= current_window_end
            and snippet_end >= current_window_start

          if not overlaps then
            table.insert(output, {
              filepath = filepath,
              start_line = snippet_start,
              end_line = snippet_end,
              lines = lines,
            })
          end
        end
      end
    end
  end

  return output
end

-- =============================================================================
-- Main Collection Function
-- =============================================================================

--- Collect all context data based on provider requirements
---@param bufnr number
---@param baseline BlinkEditBaseline
---@param snapshot BlinkEditSnapshot
---@param requirements BlinkEditProviderRequirements
---@param limits BlinkEditContextLimits
---@return BlinkEditContextData
function M.collect(bufnr, baseline, snapshot, requirements, limits)
  local cfg = config.get()
  local filepath = get_filepath(bufnr)
  local filetype = vim.bo[bufnr].filetype or ""

  -- Build baseline window data
  local baseline_window = {
    lines = baseline.lines or {},
    start_line = baseline.window_start,
    end_line = baseline.window_end,
  }

  -- Build current window data
  local current_window = {
    lines = snapshot.lines or {},
    start_line = snapshot.window_start,
    end_line = snapshot.window_end,
  }

  -- Cursor position
  local cursor = {
    line = snapshot.cursor[1],
    col = snapshot.cursor[2],
  }

  -- Full file lines (always available, providers decide if they need it)
  local full_file_lines = state.get_current_lines(bufnr)

  -- History (trimmed based on limits)
  local history = {}
  if requirements.needs_history then
    local raw_history = state.get_history(bufnr)
    history = M.trim_history(raw_history, limits.max_history_tokens, limits.max_history_entries)
  end

  -- Diagnostics
  local diagnostics = {}
  if requirements.needs_diagnostics then
    -- Collect diagnostics within extended window (include local context lines)
    local local_ctx = requirements.local_context_lines or 0
    local diag_start = math.max(1, current_window.start_line - local_ctx)
    local diag_end = current_window.end_line + local_ctx
    diagnostics = M.collect_diagnostics(bufnr, diag_start, diag_end)
  end

  -- Selection (trimmed to max_lines)
  local selection = nil
  if requirements.needs_selection then
    selection = state.get_selection(bufnr)

    -- Trim selection to max_lines
    local max_lines = cfg.context.selection.max_lines
    if selection and max_lines and selection.lines and #selection.lines > max_lines then
      selection = vim.tbl_extend("force", selection, {
        lines = vim.list_slice(selection.lines, 1, max_lines),
        end_line = selection.start_line + max_lines - 1,
      })
    end
  end

  -- LSP definitions
  local lsp_definitions = {}
  if requirements.needs_lsp_definitions then
    local lsp_cfg = cfg.context.lsp
    lsp_definitions = M.collect_lsp_locations(
      bufnr,
      "textDocument/definition",
      lsp_cfg.timeout_ms,
      lsp_cfg.max_definitions,
      lsp_cfg.lines_before,
      lsp_cfg.lines_after,
      filepath,
      current_window.start_line,
      current_window.end_line
    )
  end

  -- LSP references
  local lsp_references = {}
  if requirements.needs_lsp_references then
    local lsp_cfg = cfg.context.lsp
    lsp_references = M.collect_lsp_locations(
      bufnr,
      "textDocument/references",
      lsp_cfg.timeout_ms,
      lsp_cfg.max_references,
      lsp_cfg.lines_before,
      lsp_cfg.lines_after,
      filepath,
      current_window.start_line,
      current_window.end_line
    )
  end

  return {
    filepath = filepath,
    filetype = filetype,
    baseline_window = baseline_window,
    current_window = current_window,
    cursor = cursor,
    full_file_lines = full_file_lines,
    history = history,
    diagnostics = diagnostics,
    selection = selection,
    lsp_definitions = lsp_definitions,
    lsp_references = lsp_references,
  }
end

return M
