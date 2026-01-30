```
██████╗ ██╗     ██╗███╗   ██╗██╗  ██╗    ███████╗██████╗ ██╗████████╗
██╔══██╗██║     ██║████╗  ██║██║ ██╔╝    ██╔════╝██╔══██╗██║╚══██╔══╝
██████╔╝██║     ██║██╔██╗ ██║█████╔╝     █████╗  ██║  ██║██║   ██║
██╔══██╗██║     ██║██║╚██╗██║██╔═██╗     ██╔══╝  ██║  ██║██║   ██║
██████╔╝███████╗██║██║ ╚████║██║  ██╗    ███████╗██████╔╝██║   ██║
╚═════╝ ╚══════╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝    ╚══════╝╚═════╝ ╚═╝   ╚═╝
```

<div align="center">

# blink-edit.nvim

**Pure-Lua Neovim plugin for Cursor-style next-edit predictions using local LLMs.**

[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-blueviolet.svg?style=flat-square&logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1-blue.svg?style=flat-square&logo=lua&logoColor=white)](http://www.lua.org)
[![License](https://img.shields.io/badge/License-MIT-success.svg?style=flat-square)](LICENSE)

*⚠️ **Alpha** — Expect breaking changes and rapid iteration ⚠️*

<img src="assets/BlinkEdit.gif" alt="blink-edit demo">

</div>

---

## ⚡ What This Is

**blink-edit.nvim** predicts your next edit and renders it as ghost text. It sends context-aware prompts to a local LLM and shows predictions inline.

- **Fast:** Written entirely in Lua.
- **Private:** Bring your own local model (OpenAI-compatible or Ollama).
- **Simple:** Accept with `<Tab>`, reject with `<Esc>`.

---

## ✨ Features

- 👻 **Ghost Text** — Next-edit predictions rendered inline
- 🎮 **Intuitive Controls** — Accept/reject with standard insert-mode keymaps
- 🏥 **Health Check** — Status popup with live server health monitoring
- 🔌 **Providers** — Built-in support for **Sweep** and **Zeta** *(more coming soon)*
- 🤖 **Backends** — Connects to any OpenAI-compatible API or Ollama

---

## 📦 Installation

### Requirements

- **Neovim 0.9+**
- A running model backend (see [Running a Local Model](#-running-a-local-model) below)

### lazy.nvim

```lua
{
  "BlinkResearchLabs/blink-edit.nvim",
  config = function()
    require("blink-edit").setup({
      llm = {
        provider = "sweep",
        backend = "openai",
        url = "http://localhost:8000",
        model = "sweep",
      },
    })
  end,
}
```

### packer.nvim

```lua
use({
  "BlinkResearchLabs/blink-edit.nvim",
  config = function()
    require("blink-edit").setup({
      llm = {
        provider = "sweep",
        backend = "openai",
        url = "http://localhost:8000",
        model = "sweep",
      },
    })
  end,
})
```

---

## 🚀 Quick Start

1. **Setup the plugin:**

```lua
require("blink-edit").setup({
  llm = {
    provider = "sweep",
    backend = "openai",
    url = "http://localhost:8000",
    model = "sweep",
  },
})
```

2. **Start typing** in Insert mode. Predictions will appear as ghost text.

3. **Control:**
   - `<Tab>` to **Accept**
   - `<Esc>` to **Reject**
   - `:BlinkEditStatus` to check server health

---

## 🔌 Providers

### Sweep

Default provider. Uses `<|file_sep|>` delimiters for context sections. Works best with the Sweep Next-Edit model.

```lua
llm = { provider = "sweep", backend = "openai", url = "http://localhost:8000", model = "sweep" }
```

### Zeta

Instruction-style prompt with editable region markers. Supports **next-edit mode only**.

```lua
llm = { provider = "zeta", backend = "openai", url = "http://localhost:8000", model = "zeta" }
```

### Generic (Not Validated)

Template-based provider. Exists but is not validated. Avoid in production until tested.

---

## 🤖 Backends

### OpenAI-compatible

Uses `/v1/completions`. Works with llama.cpp, vLLM, text-generation-webui, and other OpenAI-compatible servers.

### Ollama

Uses `/api/generate`. Works with any model available through Ollama. See [Running a Local Model](#-running-a-local-model) for setup.

---

## ⚙️ Configuration Reference

<details>
<summary>Click to view full default configuration</summary>

```lua
require("blink-edit").setup({
  llm = {
    backend = "openai",           -- "openai" | "ollama"
    provider = "sweep",           -- "sweep" | "zeta" | "generic"
    url = "http://localhost:8000",-- Model server URL
    model = "sweep",              -- Model name sent to backend
    temperature = 0.0,            -- Sampling temperature (0 = deterministic)
    max_tokens = 512,             -- Max tokens to generate
    timeout_ms = 5000,            -- Request timeout in ms
  },

  context = {
    enabled = true,               -- Master switch for context collection
    lines_before = nil,           -- Lines before cursor (nil = provider default)
    lines_after = nil,            -- Lines after cursor (nil = provider default)
    max_tokens = 512,             -- Token budget for context

    selection = {
      enabled = true,             -- Include visual selection in context
      max_lines = 10,             -- Max lines from selection
    },

    lsp = {
      enabled = true,             -- Fetch LSP references for cursor symbol
      max_definitions = 2,        -- Max definition locations
      max_references = 2,         -- Max reference locations
      timeout_ms = 100,           -- LSP request timeout
    },

    same_file = {
      enabled = true,             -- Include surrounding lines from same file
      max_lines_before = 20,      -- Lines above the window
      max_lines_after = 20,       -- Lines below the window
    },

    history = {
      enabled = false,            -- Include recent edit history
      max_items = 5,              -- Number of history entries
      max_tokens = 512,           -- Token budget for history
      max_files = 2,              -- Max files in history
      global = true,              -- Share history across buffers
    },
  },

  ui = {
    progress = true,              -- Show "thinking..." indicator
    suppress_lsp_floats = true,   -- Hide LSP floats while prediction visible
  },

  prefetch = {
    enabled = false,              -- Speculative prefetch (uses extra tokens)
    strategy = "n-1",             -- Prefetch when one hunk remains
  },

  normal_mode = {
    enabled = false,              -- Trigger predictions on idle in normal mode
  },

  accept_key = "<Tab>",           -- Key to accept prediction
  reject_key = "<Esc>",           -- Key to reject prediction
})
```

</details>

---

## ⌨️ Keymaps & Commands

| Key | Action |
|-----|--------|
| `<Tab>` | **Accept** prediction |
| `<Esc>` | **Reject** prediction |

> **Note:** If you use `blink.cmp` or `nvim-cmp`, the `<Tab>` keymap automatically checks if the completion menu is visible before accepting predictions.

**Customization:**

```lua
require("blink-edit").setup({
  accept_key = "<C-y>",  -- Use Ctrl+y to accept
  reject_key = "<C-n>",  -- Use Ctrl+n to reject
})
```

| Command | Description |
|---------|-------------|
| `:BlinkEditStatus` | Show status popup with health, config, and state |
| `:BlinkEditEnable` | Enable predictions |
| `:BlinkEditDisable` | Disable predictions |
| `:BlinkEditToggle` | Toggle predictions on/off |

---

## 🛠️ Public API

```lua
require("blink-edit").setup(opts)     -- Initialize with config

require("blink-edit").enable()        -- Enable predictions
require("blink-edit").disable()       -- Disable predictions
require("blink-edit").toggle()        -- Toggle predictions

require("blink-edit").trigger()       -- Manually trigger a prediction
require("blink-edit").accept()        -- Accept current prediction
require("blink-edit").reject()        -- Reject current prediction

require("blink-edit").status()        -- Get status table
require("blink-edit").health_check()  -- Check backend health
```

---

## 📊 Status UI

`:BlinkEditStatus` opens a popup showing:

- Provider / Backend / Model / URL
- Server health (with live refresh)
- In-flight request state
- Current prediction visibility
- History entry count

Press `r` to refresh health, `q` or `<Esc>` to close.

---

## 📝 Notes

### LSP References

- References are fetched **only for the symbol under the cursor** at InsertEnter.
- If your LSP server returns an error or is still indexing, references won't appear in the prompt.
- Some LSP servers (e.g. certain Pyright versions) have known bugs with reference requests.

### Selection Context

- Selection is captured from visual selection and yank events.
- When enabled, selected text is included in the prompt even if you're editing elsewhere.

---

## 🔧 Troubleshooting

<details>
<summary><strong>Predictions aren't showing up</strong></summary>

1. Run `:BlinkEditStatus` to check if the server is healthy.
2. Ensure your model server (Ollama/llama.cpp) is running and accessible.

</details>

<details>
<summary><strong>LSP references are missing</strong></summary>

1. Check `:LspInfo` to verify an LSP is attached to the buffer.
2. Your LSP server may have errors — test with `:lua vim.print(vim.lsp.buf_request_sync(...))`.

</details>

<details>
<summary><strong>Predictions are slow</strong></summary>

1. Try using a quantized model (e.g., q4_0 or q8_0).
2. Reduce `context.max_tokens` or `context.lsp.timeout_ms` in your config.

</details>

<details>
<summary><strong>Tab conflicts with completion menu</strong></summary>

We check for blink.cmp/nvim-cmp visibility, but you can change `accept_key` if needed.

</details>

---

## 🐛 Debugging

```lua
vim.g.blink_edit_debug = true   -- Summary logs
vim.g.blink_edit_debug = 2      -- Verbose (prompts + responses)
```

---

## 🧠 Running a Local Model

### Option A: Sweep (Recommended)

*A 1.5B parameter model optimized for next-edit prediction.*

**Using `llama-server`:**

```bash
# Download and run directly
llama-server -hf sweepai/sweep-next-edit-1.5b-GGUF --port 8000

# Or download manually first
huggingface-cli download sweepai/sweep-next-edit-1.5b-GGUF \
  sweep-next-edit-1.5b.q8_0.gguf --local-dir ./models

llama-server -m ./models/sweep-next-edit-1.5b.q8_0.gguf --port 8000
```

*Config:*

```lua
llm = { provider = "sweep", backend = "openai", url = "http://localhost:8000", model = "sweep" }
```

### Option B: Zeta

*A 7B parameter model from Zed Industries, fine-tuned from Qwen2.5-Coder-7B.*

**Using `vLLM` (Recommended):**

```bash
vllm serve zed-industries/zeta --served-model-name zeta --port 8000

# With optimizations (requires compatible GPU)
vllm serve zed-industries/zeta --served-model-name zeta --port 8000 \
  --enable-prefix-caching --quantization="fp8"
```

*Config:*

```lua
llm = { provider = "zeta", backend = "openai", url = "http://localhost:8000", model = "zeta" }
```

**Using `Ollama`:**

```bash
ollama pull lennyerik/zeta
# Runs on port 11434 by default
```

*Config for Ollama:*

```lua
llm = { provider = "zeta", backend = "ollama", url = "http://localhost:11434", model = "lennyerik/zeta" }
```

---

## 🗺️ Roadmap

- [ ] Validate and expand generic provider support
- [ ] Support non-local / remote model backends
- [ ] Explore other editor integrations
- [ ] ...

---

## 🤝 Contributing

Issues and PRs are welcome! This is an alpha project — your feedback helps shape the future of local AI coding in Neovim.

---

## 📄 License

MIT — see [LICENSE](LICENSE).
