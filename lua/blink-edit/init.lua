---@class BlinkEdit
---@field config BlinkEditConfig
---@field state table|nil
---@field engine table|nil
local M = {}

local config = require("blink-edit.config")
local transport = require("blink-edit.transport")
local commands = require("blink-edit.commands")
local engine = require("blink-edit.core.engine")
local render = require("blink-edit.core.render")
local state = require("blink-edit.core.state")
local utils = require("blink-edit.utils")
local log = require("blink-edit.log")

local uv = vim.uv or vim.loop

---@type boolean
local initialized = false
local normal_mode_timer = nil
local esc_wrappers = {}
local lsp_wrapped = false
local original_hover = nil
local original_signature = nil
local original_diag_open_float = nil

--- Setup blink-edit with user configuration
---@param user_config? table
function M.setup(user_config)
  if initialized then
    log.warn("Already initialized, call reset() first")
    return
  end

  -- Initialize configuration
  config.setup(user_config)
  local cfg = config.get()

  if cfg.context and cfg.context.enabled == false then
    state.clear_history()
    state.clear_selection()
  end

  -- Setup highlights
  M._setup_highlights()

  -- Setup keymaps
  M._setup_keymaps()

  -- Setup visibility listeners
  M._setup_visibility_listeners()

  -- Setup LSP float suppression (optional)
  M._setup_lsp_suppression()

  -- Setup autocmds
  M._setup_autocmds()

  initialized = true

  -- Log successful initialization (debug only)
  if vim.g.blink_edit_debug then
    log.debug(
      string.format(
        "Initialized: mode=%s, backend=%s, provider=%s, url=%s",
        cfg.mode,
        cfg.llm.backend,
        cfg.llm.provider,
        cfg.llm.url
      ),
      vim.log.levels.INFO
    )
  end

  -- Setup commands
  commands.setup({
    enable = M.enable,
    disable = M.disable,
    toggle = M.toggle,
    status = M.status,
    health = M.health_check,
  })
end

--- Setup highlight groups
function M._setup_highlights()
  local cfg = config.get()

  vim.api.nvim_set_hl(0, "BlinkEditAddition", cfg.highlight.addition)
  vim.api.nvim_set_hl(0, "BlinkEditDeletion", cfg.highlight.deletion)
  vim.api.nvim_set_hl(0, "BlinkEditPreview", cfg.highlight.preview)
  vim.api.nvim_set_hl(0, "BlinkEditJump", cfg.highlight.jump)
end

--- Check if any completion plugin menu is visible
---@return boolean
function M._completion_menu_visible()
  if package.loaded["blink.cmp"] then
    local ok, blink_cmp = pcall(require, "blink.cmp")
    if ok and blink_cmp.is_visible and blink_cmp.is_visible() then
      return true
    end
  end

  if package.loaded["cmp"] then
    local ok, cmp = pcall(require, "cmp")
    if ok and cmp.visible() then
      return true
    end
  end

  return false
end

--- Setup keymaps for accepting/rejecting predictions
function M._setup_keymaps()
  local cfg = config.get()
  local km = cfg.keymaps or {}
  local insert_km = km.insert or {}
  local normal_km = km.normal or {}
  local normal_mode_enabled = cfg.normal_mode and cfg.normal_mode.enabled

  -- ==========================================================================
  -- Insert Mode Keymaps
  -- ==========================================================================

  -- Accept prediction (default: Tab)
  if insert_km.accept then
    vim.keymap.set("i", insert_km.accept, function()
      -- Priority 1: Accept our prediction
      if M.has_prediction() then
        vim.schedule(function()
          M.accept()
        end)
        return ""
      end

      -- Priority 2: Let completion plugins handle the key
      if M._completion_menu_visible() then
        return insert_km.accept
      end

      -- Default: pass through
      return insert_km.accept
    end, { expr = true, noremap = true, desc = "Accept blink-edit prediction" })
  end

  -- Accept first line of hunk (default: C-j)
  if insert_km.accept_line then
    vim.keymap.set("i", insert_km.accept_line, function()
      if M.has_prediction() then
        vim.schedule(function()
          M.accept_line()
        end)
        return ""
      end
      return insert_km.accept_line
    end, { expr = true, noremap = true, desc = "Accept first line of blink-edit prediction" })
  end

  -- Clear prediction without leaving insert mode (default: C-])
  if insert_km.clear then
    vim.keymap.set("i", insert_km.clear, function()
      if M.has_prediction() then
        vim.schedule(function()
          M.clear()
        end)
        return ""
      end
      return insert_km.clear
    end, { expr = true, noremap = true, desc = "Clear blink-edit prediction" })
  end

  -- Reject prediction (default: Esc)
  if insert_km.reject then
    vim.keymap.set("i", insert_km.reject, function()
      if M.has_prediction() then
        vim.schedule(function()
          M.reject()
        end)
        return "" -- Consume the key
      end
      -- Fall through to default behavior
      return insert_km.reject
    end, { expr = true, noremap = true, desc = "Reject blink-edit prediction" })
  end

  -- ==========================================================================
  -- Normal Mode Keymaps (only when normal_mode.enabled)
  -- ==========================================================================

  if normal_mode_enabled then
    -- Accept prediction in normal mode
    if normal_km.accept then
      vim.keymap.set("n", normal_km.accept, function()
        if M.has_prediction() then
          vim.schedule(function()
            M.accept()
          end)
          return ""
        end
        return normal_km.accept
      end, { expr = true, noremap = true, desc = "Accept blink-edit prediction (normal)" })
    end

    -- Accept first line of hunk in normal mode
    if normal_km.accept_line then
      vim.keymap.set("n", normal_km.accept_line, function()
        if M.has_prediction() then
          vim.schedule(function()
            M.accept_line()
          end)
          return ""
        end
        return normal_km.accept_line
      end, { expr = true, noremap = true, desc = "Accept first line of blink-edit prediction (normal)" })
    end
  end
end

local function get_buf_esc_map(bufnr)
  if vim.keymap and vim.keymap.get then
    local maps = vim.keymap.get("n", "<Esc>", { buffer = bufnr })
    if maps and #maps > 0 then
      return maps[1]
    end
    return nil
  end

  local ok, maps = pcall(vim.api.nvim_buf_get_keymap, bufnr, "n")
  if not ok or not maps then
    return nil
  end

  for _, map in ipairs(maps) do
    if map.lhs == "<Esc>" then
      return {
        lhs = map.lhs,
        rhs = map.rhs,
        expr = map.expr == 1 or map.expr == true,
        noremap = map.noremap == 1 or map.noremap == true,
        silent = map.silent == 1 or map.silent == true,
        nowait = map.nowait == 1 or map.nowait == true,
      }
    end
  end

  return nil
end

local function restore_buf_esc_map(bufnr, map)
  if not map then
    return
  end

  local rhs = map.callback or map.rhs
  if not rhs then
    return
  end

  local opts = {
    buffer = bufnr,
    expr = map.expr == true,
    noremap = map.noremap == true,
    silent = map.silent == true,
    nowait = map.nowait == true,
  }

  if map.script ~= nil then
    opts.script = map.script
  end
  if map.desc then
    opts.desc = map.desc
  end
  if map.replace_keycodes ~= nil then
    opts.replace_keycodes = map.replace_keycodes
  end

  vim.keymap.set("n", "<Esc>", rhs, opts)
end

local function remove_esc_wrapper(bufnr)
  local entry = esc_wrappers[bufnr]
  if not entry then
    return
  end

  pcall(vim.keymap.del, "n", "<Esc>", { buffer = bufnr })
  if entry.original then
    restore_buf_esc_map(bufnr, entry.original)
  end
  esc_wrappers[bufnr] = nil
end

local function remove_all_esc_wrappers()
  for bufnr, _ in pairs(esc_wrappers) do
    remove_esc_wrapper(bufnr)
  end
end

local function install_esc_wrapper(bufnr)
  local cfg = config.get()
  if not (cfg.normal_mode and cfg.normal_mode.enabled) then
    return
  end

  if esc_wrappers[bufnr] then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local original = get_buf_esc_map(bufnr)
  esc_wrappers[bufnr] = { original = original }

  vim.keymap.set("n", "<Esc>", function()
    if M.has_prediction() then
      M.reject()
    end

    remove_esc_wrapper(bufnr)

    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "m", false)
    return ""
  end, { expr = true, noremap = true, silent = true, buffer = bufnr, desc = "Clear blink-edit prediction" })
end

--- Setup visibility listeners for ephemeral Esc handling
function M._setup_visibility_listeners()
  local cfg = config.get()

  remove_all_esc_wrappers()

  if not (cfg.normal_mode and cfg.normal_mode.enabled) then
    render.set_visibility_listeners(nil)
    return
  end

  render.set_visibility_listeners({
    on_show = function(bufnr)
      if vim.g.blink_edit_enabled == false then
        return
      end
      install_esc_wrapper(bufnr)
    end,
    on_clear = function(bufnr)
      remove_esc_wrapper(bufnr)
    end,
  })
end

local function cancel_normal_mode_timer()
  if normal_mode_timer and not normal_mode_timer:is_closing() then
    normal_mode_timer:stop()
    normal_mode_timer:close()
  end
  normal_mode_timer = nil
end

local function start_normal_mode_timer(bufnr)
  local cfg = config.get()
  if not cfg.normal_mode or not cfg.normal_mode.enabled then
    return
  end
  cancel_normal_mode_timer()
  local timer = uv.new_timer()
  normal_mode_timer = timer
  timer:start(cfg.debounce_ms, 0, function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    normal_mode_timer = nil
    vim.schedule(function()
      if not cfg.normal_mode or not cfg.normal_mode.enabled then
        return
      end
      if M.has_prediction() then
        return
      end
      engine.trigger_force(bufnr)
    end)
  end)
end

function M._setup_lsp_suppression()
  if lsp_wrapped then
    return
  end
  lsp_wrapped = true

  original_hover = vim.lsp.handlers["textDocument/hover"]
  original_signature = vim.lsp.handlers["textDocument/signatureHelp"]
  original_diag_open_float = vim.diagnostic.open_float

  vim.lsp.handlers["textDocument/hover"] = function(err, result, ctx, handler_config)
    local cfg = config.get()
    if cfg.ui and cfg.ui.suppress_lsp_floats and M.has_prediction() then
      return
    end
    if original_hover then
      return original_hover(err, result, ctx, handler_config)
    end
  end

  vim.lsp.handlers["textDocument/signatureHelp"] = function(err, result, ctx, handler_config)
    local cfg = config.get()
    if cfg.ui and cfg.ui.suppress_lsp_floats and M.has_prediction() then
      return
    end
    if original_signature then
      return original_signature(err, result, ctx, handler_config)
    end
  end

  vim.diagnostic.open_float = function(...)
    local cfg = config.get()
    if cfg.ui and cfg.ui.suppress_lsp_floats and M.has_prediction() then
      return
    end
    if original_diag_open_float then
      return original_diag_open_float(...)
    end
  end
end

--- Setup autocmds for triggering predictions
function M._setup_autocmds()
  local augroup = vim.api.nvim_create_augroup("BlinkEdit", { clear = true })

  -- Capture baseline on InsertEnter
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    callback = function(args)
      cancel_normal_mode_timer()
      engine.on_insert_enter(args.buf)
    end,
    desc = "Capture baseline for blink-edit on insert enter",
  })

  -- Trigger prediction on text change
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = augroup,
    callback = function(args)
      M._on_text_changed(args.buf)
    end,
    desc = "Trigger blink-edit prediction on text change",
  })

  -- Check cursor movement
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group = augroup,
    callback = function(args)
      M._on_cursor_moved(args.buf)
    end,
    desc = "Handle cursor movement for blink-edit",
  })

  -- Cleanup on insert leave
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    callback = function(args)
      cancel_normal_mode_timer()
      engine.on_insert_leave(args.buf)
    end,
    desc = "Cleanup blink-edit on insert leave",
  })

  -- Normal mode idle trigger
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    callback = function(args)
      M._on_cursor_moved_normal(args.buf)
    end,
    desc = "Handle normal-mode idle triggers for blink-edit",
  })

  -- Clear prediction on buffer leave
  vim.api.nvim_create_autocmd("BufLeave", {
    group = augroup,
    callback = function(args)
      cancel_normal_mode_timer()
      engine.cancel(args.buf)
    end,
    desc = "Cancel blink-edit on buffer leave",
  })

  -- Cleanup on buffer delete
  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      remove_esc_wrapper(args.buf)
      state.clear(args.buf)
    end,
    desc = "Cleanup blink-edit state on buffer delete",
  })

  -- Capture visual selection on mode change (Visual -> non-Visual)
  -- Pattern matches: v/V/Ctrl-V (visual modes) changing to any non-visual mode
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = augroup,
    pattern = { "[vV\x16]*:[^vV\x16]*" },
    callback = function(args)
      M._capture_selection(args.buf)
    end,
    desc = "Capture visual selection for blink-edit",
  })

  -- Also capture on yank (y in visual mode) - ensures selection is captured when copying
  vim.api.nvim_create_autocmd("TextYankPost", {
    group = augroup,
    callback = function(args)
      local event = vim.v.event
      if event and event.visual then
        M._capture_selection(args.buf)
      end
    end,
    desc = "Capture yanked selection for blink-edit",
  })
end

--- Capture visual selection for context
---@param bufnr number
function M._capture_selection(bufnr)
  local cfg = config.get()
  if not cfg.context.enabled or not cfg.context.selection.enabled then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  if start_line == 0 or end_line == 0 then
    return
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local lines = state.get_lines_range(bufnr, start_line, end_line)
  if #lines == 0 then
    return
  end

  local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))

  state.set_selection(bufnr, {
    filepath = filepath,
    start_line = start_line,
    end_line = end_line,
    lines = lines,
    timestamp = vim.uv.now(),
  })

  if vim.g.blink_edit_debug then
    log.debug(string.format("Selection captured: %s lines %d-%d (%d lines)", filepath, start_line, end_line, #lines))
  end
end

--- Called on text change in insert mode
---@param bufnr number
function M._on_text_changed(bufnr)
  -- Check if plugin is enabled
  if vim.g.blink_edit_enabled == false then
    return
  end

  cancel_normal_mode_timer()
  engine.cancel_prefetch(bufnr)

  if state.consume_suppress_trigger(bufnr) then
    return
  end

  -- Skip special buffer types
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then
    return
  end

  -- Skip read-only or unmodifiable buffers
  if vim.bo[bufnr].readonly or not vim.bo[bufnr].modifiable then
    return
  end

  -- Check if filetype is enabled
  local ft = vim.bo[bufnr].filetype
  if not config.is_filetype_enabled(ft) then
    return
  end

  -- Trigger prediction via engine (debounced)
  engine.trigger(bufnr)
end

--- Called on cursor move in insert mode
---@param bufnr number
function M._on_cursor_moved(bufnr)
  engine.on_cursor_moved(bufnr)
end

--- Called on cursor move in normal mode
---@param bufnr number
function M._on_cursor_moved_normal(bufnr)
  local cfg = config.get()
  if not cfg.normal_mode or not cfg.normal_mode.enabled then
    return
  end

  if vim.g.blink_edit_enabled == false then
    return
  end

  engine.cancel_prefetch(bufnr)

  if M.has_prediction() then
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "n" then
    return
  end

  -- Skip special buffer types
  local buftype = vim.bo[bufnr].buftype
  if buftype ~= "" then
    return
  end

  -- Skip read-only or unmodifiable buffers
  if vim.bo[bufnr].readonly or not vim.bo[bufnr].modifiable then
    return
  end

  -- Check if filetype is enabled
  local ft = vim.bo[bufnr].filetype
  if not config.is_filetype_enabled(ft) then
    return
  end

  start_normal_mode_timer(bufnr)
end

--- Check if there's an active prediction
---@return boolean
function M.has_prediction()
  local bufnr = vim.api.nvim_get_current_buf()
  return engine.has_prediction(bufnr)
end

--- Accept the current prediction
function M.accept()
  local bufnr = vim.api.nvim_get_current_buf()
  engine.accept(bufnr)
end

--- Reject the current prediction
function M.reject()
  local bufnr = vim.api.nvim_get_current_buf()
  engine.reject(bufnr)
end

--- Accept first line of current hunk
function M.accept_line()
  local bufnr = vim.api.nvim_get_current_buf()
  engine.accept_line(bufnr)
end

--- Clear prediction without leaving insert mode
function M.clear()
  local bufnr = vim.api.nvim_get_current_buf()
  engine.clear(bufnr)
end

--- Manually trigger a prediction
function M.trigger()
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype

  if not config.is_filetype_enabled(ft) then
    log.debug("Filetype not enabled: " .. ft)
    return
  end

  engine.trigger_now(bufnr)
end

--- Enable blink-edit
function M.enable()
  vim.g.blink_edit_enabled = true
  M._setup_visibility_listeners()
  log.info("Enabled")
end

--- Disable blink-edit
function M.disable()
  vim.g.blink_edit_enabled = false
  cancel_normal_mode_timer()
  render.set_visibility_listeners(nil)
  remove_all_esc_wrappers()
  M.reject()
  log.info("Disabled")
end

--- Toggle blink-edit
function M.toggle()
  if vim.g.blink_edit_enabled == false then
    M.enable()
  else
    M.disable()
  end
end

--- Get current status
---@return table
function M.status()
  local cfg = config.get()
  local bufnr = vim.api.nvim_get_current_buf()
  local buf_state = state.get_state(bufnr)

  return {
    initialized = initialized,
    enabled = vim.g.blink_edit_enabled ~= false,
    mode = cfg.mode,
    backend = cfg.llm.backend,
    provider = cfg.llm.provider,
    url = cfg.llm.url,
    model = cfg.llm.model,
    temperature = cfg.llm.temperature,
    max_tokens = cfg.llm.max_tokens,
    has_prediction = M.has_prediction(),
    tracked_buffers = state.get_tracked_buffers(),
    history_count = state.get_history_count(bufnr),
    has_baseline = buf_state and buf_state.baseline ~= nil,
    is_in_flight = state.is_in_flight(bufnr),
    has_pending_snapshot = state.has_pending_snapshot(bufnr),
  }
end

--- Health check (backend ping)
function M.health_check()
  local cfg = config.get()
  local backend = require("blink-edit.backends")

  backend.health_check(function(available, message)
    local prefix = string.format("%s", cfg.llm.backend)
    if available then
      log.debug(prefix .. " backend healthy: " .. message)
    else
      log.debug(prefix .. " backend unhealthy: " .. message, vim.log.levels.WARN)
    end
  end)
end

--- Reset blink-edit (for testing/reconfiguration)
function M.reset()
  -- Clear autocmds
  pcall(vim.api.nvim_del_augroup_by_name, "BlinkEdit")

  render.set_visibility_listeners(nil)
  remove_all_esc_wrappers()

  -- Cleanup engine
  engine.cleanup()

  -- Reset config
  config.reset()

  -- Close transport connections
  transport.close_all()

  initialized = false

  if vim.g.blink_edit_debug then
    log.debug("Reset complete", vim.log.levels.INFO)
  end
end

--- Check if plugin is initialized (for pre-setup commands)
---@return boolean
function M._is_initialized()
  return initialized
end

--- Health check (for :checkhealth)
function M.health()
  local health = vim.health or require("health")
  local start = health.start or health.report_start
  local ok = health.ok or health.report_ok
  local warn = health.warn or health.report_warn
  local error_fn = health.error or health.report_error

  start("blink-edit")

  -- Check initialization
  if initialized then
    ok("Plugin initialized")
  else
    warn("Plugin not initialized, call setup()")
  end

  -- Check configuration
  local cfg = config.get()
  ok(string.format("Mode: %s", cfg.mode))
  ok(string.format("Backend: %s", cfg.llm.backend))
  ok(string.format("Provider: %s", cfg.llm.provider))
  ok(string.format("URL: %s", cfg.llm.url))
  ok(string.format("Model: %s", cfg.llm.model))

  -- Check curl availability
  if vim.fn.executable("curl") == 1 then
    ok("curl is available")
  else
    error_fn("curl not found (required for HTTPS)")
  end

  -- Check Neovim version
  if vim.fn.has("nvim-0.9") == 1 then
    ok("Neovim 0.9+ detected")
  else
    warn("Neovim 0.9+ recommended for best compatibility")
  end

  -- Check vim.diff availability
  if vim.diff then
    ok("vim.diff() available")
  else
    error_fn("vim.diff() not available (requires Neovim 0.9+)")
  end
end

return M
