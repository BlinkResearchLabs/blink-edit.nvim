---@class BlinkEditLLMConfig
---@field backend string
---@field provider string
---@field url string
---@field model string
---@field temperature number
---@field max_tokens number
---@field stop_tokens string[]
---@field timeout_ms number

---@class BlinkEditBackendOpenAIConfig
---@field health_endpoint string

---@class BlinkEditBackendOllamaConfig
---@field health_endpoint string
---@field num_ctx number|nil
---@field num_gpu number|nil
---@field num_thread number|nil
---@field options table|nil

---@class BlinkEditBackendsConfig
---@field openai BlinkEditBackendOpenAIConfig
---@field ollama BlinkEditBackendOllamaConfig

---@class BlinkEditHistoryConfig
---@field enabled boolean
---@field max_items number
---@field max_tokens number
---@field max_files number
---@field global boolean

---@class BlinkEditContextSelectionConfig
---@field enabled boolean
---@field max_lines number

---@class BlinkEditContextLspConfig
---@field enabled boolean
---@field max_definitions number
---@field max_references number
---@field timeout_ms number
---@field lines_before number
---@field lines_after number

---@class BlinkEditContextSameFileConfig
---@field enabled boolean
---@field max_lines_before number
---@field max_lines_after number

---@class BlinkEditContextConfig
---@field enabled boolean
---@field lines_before number|nil
---@field lines_after number|nil
---@field max_tokens number
---@field selection BlinkEditContextSelectionConfig
---@field lsp BlinkEditContextLspConfig
---@field same_file BlinkEditContextSameFileConfig
---@field history BlinkEditHistoryConfig

---@class BlinkEditInsertKeymapsConfig
---@field accept string|nil
---@field accept_line string|nil
---@field clear string|nil
---@field reject string|nil

---@class BlinkEditNormalKeymapsConfig
---@field accept string|nil
---@field accept_line string|nil

---@class BlinkEditKeymapsConfig
---@field insert BlinkEditInsertKeymapsConfig
---@field normal BlinkEditNormalKeymapsConfig

---@class BlinkEditConfig
---@field llm BlinkEditLLMConfig
---@field backends BlinkEditBackendsConfig
---@field mode string
---@field debounce_ms number
---@field cancel_in_flight boolean
---@field context BlinkEditContextConfig
---@field keymaps BlinkEditKeymapsConfig
---@field highlight table
---@field providers table
---@field enabled_filetypes string[]|nil
---@field disabled_filetypes string[]
---@field use_daemon boolean
---@field daemon_socket string
---@field daemon_auto_start boolean
---@field fallback_to_direct boolean
---@field prefetch BlinkEditPrefetchConfig
---@field normal_mode BlinkEditNormalModeConfig

---@class BlinkEditPrefetchConfig
---@field enabled boolean
---@field strategy string

---@class BlinkEditNormalModeConfig
---@field enabled boolean

local M = {}

local LEGACY_LLM_KEYS = {
  "backend",
  "provider",
  "url",
  "model",
  "temperature",
  "max_tokens",
  "stop_tokens",
  "timeout_ms",
}

local VALID_BACKENDS = {
  openai = true,
  ollama = true,
}

local VALID_PROVIDERS = {
  sweep = true,
  generic = true,
  zeta = true,
}

---@type BlinkEditConfig
local defaults = {
  ---------------------------------------------------------
  -- LLM Configuration
  ---------------------------------------------------------
  llm = {
    backend = "openai", -- "openai" | "ollama"
    provider = "sweep", -- "sweep" | "generic" | custom
    url = "http://localhost:8000", -- LLM server URL
    model = "sweep-next-edit-1.5b", -- Model name
    temperature = 0.0, -- Deterministic output
    max_tokens = 512, -- Max response length
    stop_tokens = { "<|file_sep|>", "</s>", "<|endoftext|>" },
    timeout_ms = 5000, -- Request timeout
  },

  ---------------------------------------------------------
  -- Provider (Prompt/Response Handling)
  ---------------------------------------------------------
  providers = {
    sweep = {
      window_size = 21,
      strict_line_count = false,
    },
    generic = {
      prompt_template = nil,
    },
    zeta = {
      use_instruction_prompt = true,
      context_lines_before = 5,
      context_lines_after = 5,
    },
  },

  ---------------------------------------------------------
  -- Backend Options
  ---------------------------------------------------------
  backends = {
    openai = {
      health_endpoint = "/health",
    },
    ollama = {
      health_endpoint = "/api/tags",
      num_ctx = nil,
      num_gpu = nil,
      num_thread = nil,
      options = {},
    },
  },

  ---------------------------------------------------------
  -- Mode
  ---------------------------------------------------------
  mode = "next-edit", -- "next-edit" | "completion"
  -- "next-edit": Full Sweep-style prediction (requires Sweep model)
  -- "completion": Simple line completion (works with any model)

  ---------------------------------------------------------
  -- Timing
  ---------------------------------------------------------
  debounce_ms = 100, -- Delay before sending request
  cancel_in_flight = true, -- Cancel TCP when new request queued (faster iteration)

  ---------------------------------------------------------
  -- Context Window
  ---------------------------------------------------------
  -- Mode defaults:
  --   "next-edit": { lines_before = 10, lines_after = 10 }  (21 lines for Sweep)
  --   "completion": { lines_before = 50, lines_after = 20 } (more context)
  context = {
    enabled = true, -- Global switch for extra context blocks
    lines_before = nil, -- nil = use mode default
    lines_after = nil, -- nil = use mode default
    max_tokens = 512, -- Token budget for context
    selection = {
      enabled = true,
      max_lines = 10, -- Max lines from selection to include
    },
    lsp = {
      enabled = true,
      max_definitions = 2,
      max_references = 2,
      timeout_ms = 100,
      lines_before = 10,
      lines_after = 10,
    },
    same_file = {
      enabled = true,
      max_lines_before = 20, -- Max same-file lines above window
      max_lines_after = 20, -- Max same-file lines below window (used by Zeta)
    },
    history = {
      enabled = false, -- Disabled for testing (was causing noisy predictions)
      max_items = 5, -- Number of recent diffs (global across all buffers)
      max_tokens = 512, -- Token budget for history
      max_files = 2, -- Max number of files to keep in history
      global = true, -- Share history across all buffers
    },
  },

  ---------------------------------------------------------
  -- Keymaps
  ---------------------------------------------------------
  keymaps = {
    insert = {
      accept = "<Tab>",        -- Accept next hunk
      accept_line = "<C-j>",   -- Accept first line of multi-line hunk
      clear = "<C-]>",         -- Dismiss ghost text (stay in insert mode)
      reject = "<Esc>",        -- Reject and exit insert mode
    },
    normal = {
      accept = "<Tab>",        -- Accept next hunk (only when normal_mode.enabled)
      accept_line = "<C-j>",   -- Accept first line (only when normal_mode.enabled)
      -- clear and reject not mapped in normal mode to avoid conflicts
    },
  },
  -- Keys only trigger when prediction is visible
  -- Falls through to default behavior otherwise

  ---------------------------------------------------------
  -- UI / Highlights
  ---------------------------------------------------------
  highlight = {
    addition = { bg = "#394f2f" }, -- Added text background
    deletion = { bg = "#4f2f2f" }, -- Deleted text background
    preview = { fg = "#80899c", italic = true }, -- Ghost text
    jump = { fg = "#5c6370", bg = "#2d3343", bold = true }, -- Jump indicator (⇥ TAB)
  },

  ui = {
    progress = true, -- Show "thinking..." indicator when in-flight
    suppress_lsp_floats = true, -- Hide LSP float dialogs while predictions are visible
  },

  ---------------------------------------------------------
  -- Prefetch (Speculative)
  ---------------------------------------------------------
  prefetch = {
    enabled = false, -- May use extra tokens
    strategy = "n-1", -- Trigger prefetch when one hunk remains
  },

  ---------------------------------------------------------
  -- Normal Mode Completions
  ---------------------------------------------------------
  normal_mode = {
    enabled = false,
  },

  ---------------------------------------------------------
  -- Filetypes
  ---------------------------------------------------------
  enabled_filetypes = nil, -- nil = all filetypes
  disabled_filetypes = { -- Skip these
    -- UI plugins
    "TelescopePrompt",
    "neo-tree",
    "NvimTree",
    "oil",
    "lazy",
    "mason",

    -- Special buffers
    "help",
    "qf",
    "quickfix",
    "terminal",
    "toggleterm",

    -- Git
    "fugitive",
    "gitcommit",
    "gitrebase",

    -- Other
    "dashboard",
    "alpha",
    "startify",
  },

  ---------------------------------------------------------
  -- Transport (Phase 5: Daemon)
  ---------------------------------------------------------
  use_daemon = false, -- Use Rust daemon when available
  daemon_socket = "/tmp/blink-edit.sock",
  daemon_auto_start = true, -- Start daemon if not running
  fallback_to_direct = true, -- Fall back to HTTP if daemon fails
}

-- Mode-based context defaults
local MODE_CONTEXT_DEFAULTS = {
  ["next-edit"] = {
    lines_before = 10, -- Sweep uses 21-line window
    lines_after = 10,
  },
  ["completion"] = {
    lines_before = 50, -- More context for general LLMs
    lines_after = 20,
  },
}

---@type BlinkEditConfig|nil
local current_config = nil

--- Deep merge two tables
---@param t1 table
---@param t2 table
---@return table
local function deep_merge(t1, t2)
  local result = vim.deepcopy(t1)
  for k, v in pairs(t2) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

---@param user_config table
local function validate_user_config(user_config)
  for _, key in ipairs(LEGACY_LLM_KEYS) do
    if user_config[key] ~= nil then
      error(string.format("[blink-edit] Deprecated config key '%s'. Use llm.%s instead.", key, key))
    end
  end
end

---@param cfg BlinkEditConfig
local function validate_config(cfg)
  if type(cfg.llm) ~= "table" then
    error("[blink-edit] Missing llm configuration table")
  end

  if not VALID_BACKENDS[cfg.llm.backend] then
    error(
      string.format("[blink-edit] Invalid llm.backend '%s'. Must be one of: openai, ollama", tostring(cfg.llm.backend))
    )
  end

  local provider = cfg.llm.provider
  if not provider or (not VALID_PROVIDERS[provider] and not (cfg.providers and cfg.providers[provider])) then
    error(
      string.format(
        "[blink-edit] Invalid llm.provider '%s'. Must be one of: sweep, generic, zeta, or a custom provider",
        tostring(provider)
      )
    )
  end

  if provider == "zeta" and cfg.mode == "completion" then
    error("[blink-edit] Zeta provider only supports mode = 'next-edit'")
  end

  if type(cfg.llm.stop_tokens) ~= "table" then
    error("[blink-edit] llm.stop_tokens must be a list of strings")
  end

  if cfg.llm.temperature < 0 then
    error("[blink-edit] llm.temperature must be >= 0")
  end
  if cfg.llm.max_tokens < 0 then
    error("[blink-edit] llm.max_tokens must be >= 0")
  end
  if cfg.llm.timeout_ms <= 0 then
    error("[blink-edit] llm.timeout_ms must be > 0")
  end

  if cfg.context.max_tokens < 0 then
    error("[blink-edit] context.max_tokens must be >= 0")
  end

  if type(cfg.context.enabled) ~= "boolean" then
    error("[blink-edit] context.enabled must be a boolean")
  end

  -- Selection validation
  if type(cfg.context.selection) ~= "table" then
    error("[blink-edit] context.selection must be a table")
  end
  if type(cfg.context.selection.enabled) ~= "boolean" then
    error("[blink-edit] context.selection.enabled must be a boolean")
  end
  if cfg.context.selection.max_lines < 0 then
    error("[blink-edit] context.selection.max_lines must be >= 0")
  end

  -- LSP validation
  local lsp_cfg = cfg.context.lsp
  if type(lsp_cfg) ~= "table" then
    error("[blink-edit] context.lsp must be a table")
  end
  if type(lsp_cfg.enabled) ~= "boolean" then
    error("[blink-edit] context.lsp.enabled must be a boolean")
  end
  if lsp_cfg.max_definitions < 0 then
    error("[blink-edit] context.lsp.max_definitions must be >= 0")
  end
  if lsp_cfg.max_references < 0 then
    error("[blink-edit] context.lsp.max_references must be >= 0")
  end
  if lsp_cfg.timeout_ms <= 0 then
    error("[blink-edit] context.lsp.timeout_ms must be > 0")
  end
  if lsp_cfg.lines_before < 0 then
    error("[blink-edit] context.lsp.lines_before must be >= 0")
  end
  if lsp_cfg.lines_after < 0 then
    error("[blink-edit] context.lsp.lines_after must be >= 0")
  end

  -- Same-file validation
  if type(cfg.context.same_file) ~= "table" then
    error("[blink-edit] context.same_file must be a table")
  end
  if type(cfg.context.same_file.enabled) ~= "boolean" then
    error("[blink-edit] context.same_file.enabled must be a boolean")
  end
  if type(cfg.context.same_file.max_lines_before) ~= "number" then
    error("[blink-edit] context.same_file.max_lines_before must be a number")
  end
  if cfg.context.same_file.max_lines_before < 0 then
    error("[blink-edit] context.same_file.max_lines_before must be >= 0")
  end
  if type(cfg.context.same_file.max_lines_after) ~= "number" then
    error("[blink-edit] context.same_file.max_lines_after must be a number")
  end
  if cfg.context.same_file.max_lines_after < 0 then
    error("[blink-edit] context.same_file.max_lines_after must be >= 0")
  end

  -- History validation
  local history = cfg.context.history
  if type(history) ~= "table" then
    error("[blink-edit] context.history must be a table")
  end
  if history.max_items < 0 then
    error("[blink-edit] context.history.max_items must be >= 0")
  end
  if history.max_tokens < 0 then
    error("[blink-edit] context.history.max_tokens must be >= 0")
  end
  if history.max_files < 0 then
    error("[blink-edit] context.history.max_files must be >= 0")
  end

  -- UI validation
  if cfg.ui then
    if cfg.ui.suppress_lsp_floats ~= nil and type(cfg.ui.suppress_lsp_floats) ~= "boolean" then
      error("[blink-edit] ui.suppress_lsp_floats must be a boolean")
    end
  end

  -- Prefetch validation
  if cfg.prefetch then
    if type(cfg.prefetch.enabled) ~= "boolean" then
      error("[blink-edit] prefetch.enabled must be a boolean")
    end
    if cfg.prefetch.strategy ~= nil and type(cfg.prefetch.strategy) ~= "string" then
      error("[blink-edit] prefetch.strategy must be a string")
    end
  end

  -- Normal mode validation
  if cfg.normal_mode then
    if type(cfg.normal_mode.enabled) ~= "boolean" then
      error("[blink-edit] normal_mode.enabled must be a boolean")
    end
  end

  local ollama_cfg = cfg.backends.ollama
  if ollama_cfg.options and type(ollama_cfg.options) ~= "table" then
    error("[blink-edit] backends.ollama.options must be a table")
  end
  if ollama_cfg.num_ctx and ollama_cfg.num_ctx < 0 then
    error("[blink-edit] backends.ollama.num_ctx must be >= 0")
  end
  if ollama_cfg.num_gpu and ollama_cfg.num_gpu < 0 then
    error("[blink-edit] backends.ollama.num_gpu must be >= 0")
  end
  if ollama_cfg.num_thread and ollama_cfg.num_thread < 0 then
    error("[blink-edit] backends.ollama.num_thread must be >= 0")
  end
end

--- Setup configuration with user overrides
---@param user_config? table
function M.setup(user_config)
  user_config = user_config or {}
  validate_user_config(user_config)
  current_config = deep_merge(defaults, user_config)
  validate_config(current_config)
end

--- Get current configuration
---@return BlinkEditConfig
function M.get()
  if not current_config then
    M.setup({})
  end
  return current_config
end

--- Get context lines based on mode and user overrides
---@return { lines_before: number, lines_after: number }
function M.get_context_lines()
  local config = M.get()
  local mode_defaults = MODE_CONTEXT_DEFAULTS[config.mode] or MODE_CONTEXT_DEFAULTS["next-edit"]

  return {
    lines_before = config.context.lines_before or mode_defaults.lines_before,
    lines_after = config.context.lines_after or mode_defaults.lines_after,
  }
end

--- Check if a filetype is enabled
---@param filetype string
---@return boolean
function M.is_filetype_enabled(filetype)
  local config = M.get()

  -- Check disabled list first
  if vim.tbl_contains(config.disabled_filetypes, filetype) then
    return false
  end

  -- If enabled list is set, check it
  if config.enabled_filetypes then
    return vim.tbl_contains(config.enabled_filetypes, filetype)
  end

  -- Default: all filetypes enabled
  return true
end

--- Get the defaults (for testing/inspection)
---@return BlinkEditConfig
function M.get_defaults()
  return vim.deepcopy(defaults)
end

--- Reset configuration to defaults
function M.reset()
  current_config = nil
end

return M
