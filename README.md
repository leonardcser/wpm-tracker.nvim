# WPM Tracker for Neovim

A comprehensive typing speed tracker plugin that monitors both manual typing and
AI-assisted coding productivity in Neovim.

## ✨ Features

- **📊 Dual WPM Tracking**: Separate metrics for manual typing vs AI-assisted
  coding
- **⚡ Live Updates**: Real-time WPM display in lualine while typing
- **🔄 Multi-Instance Sync**: Syncs averages across all Neovim instances
- **💾 CSV Logging**: Clean data export for analysis
- **🎯 Smart Detection**: Distinguishes between manual keystrokes and
  completions
- **⚙️ Memory Efficient**: Only reads necessary data, not entire history

## 📈 Metrics

- **Manual WPM**: Pure typing speed (keystrokes only)
- **Assisted WPM**: Total productivity including Supermaven, LSP completions,
  etc.
- **Rolling Averages**: Configurable window for historical averages
- **Session Tracking**: Current session stats vs historical data

## 🚀 Installation

### With [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "leonardcser/wpm-tracker.nvim",
  config = function()
    require("wpm-tracker").setup({
      -- Log file location (CSV format)
      log_file = vim.fn.stdpath("data") .. "/wpm-tracker.csv",
      -- Rolling average window size
      average_window = 10,
      -- Minimum session length to record (seconds)
      min_session_length = 5,
      -- Update interval for lualine (milliseconds)
      update_interval = 1000,
    })

    -- Optional keymaps
    vim.keymap.set("n", "<leader>ws", "<cmd>WPMStats<cr>", { desc = "Show WPM statistics" })
    vim.keymap.set("n", "<leader>wl", "<cmd>WPMLog<cr>", { desc = "Open WPM log file" })
  end,
}
```

## 🎨 Lualine Integration

Add to your lualine configuration:

```lua
-- In your lualine setup
sections = {
  lualine_x = {
    {
      function()
        local wpm_tracker = require("wpm-tracker")
        return wpm_tracker.get_wpm_display()
      end,
      cond = function()
        local wpm_tracker = require("wmp-tracker")
        return wpm_tracker.get_current_wpm() > 0
      end,
      color = { fg = "#3EFFDC" },
    },
    -- ... other components
  },
}
```

## 📊 Display Format

- **While Typing**: `⚡120 wpm` (current assisted WPM)
- **When Idle**: Shows rolling average

## 🔧 Commands

- `:WPMStats` - Show detailed statistics
- `:WPMLog` - Open CSV log file

## 📁 CSV Format

```csv
timestamp,manual_wpm,assisted_wpm,duration,manual_chars,total_chars
2024-01-15 14:30:25,65,120,12.3,95,185
```

## ⚙️ Configuration

```lua
require("wpm-tracker").setup({
  log_file = vim.fn.stdpath("data") .. "/wpm-tracker.csv",
  average_window = 10,        -- Number of sessions for rolling average
  min_session_length = 5,     -- Minimum seconds to record a session
  update_interval = 1000,     -- Lualine update frequency (ms)
})
```

## 🎯 How It Works

1. **Manual Tracking**: Uses `InsertCharPre` to count actual keystrokes
2. **Assisted Tracking**: Uses `TextChangedI` to count all text insertions
3. **Smart Detection**: Large insertions (>3 chars) are treated as completions
4. **Multi-Instance Sync**: Updates averages when switching between Neovim
   windows
5. **Efficient Storage**: Only reads last N entries, not entire file

## 🤝 Contributing

Contributions welcome! Please feel free to submit issues and pull requests.

## 📄 License

MIT License
