# WPM Tracker for Neovim

Track your typing speed in Neovim with separate metrics for manual typing and
completions/AI-assisted coding.

## Features

- **📝 Manual WPM**: Track your pure typing speed
- **🤖 Assisted WPM**: Include completions and AI assistance
- **📊 Live Display**: Real-time WPM in your statusline
- **💾 Data Export**: Save sessions to CSV for analysis

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

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
      -- Stop tracking after inactivity (seconds)
      idle_timeout = 5,
    })

    -- Optional keymaps
    vim.keymap.set("n", "<leader>ws", "<cmd>WPMStats<cr>", { desc = "Show WPM statistics" })
    vim.keymap.set("n", "<leader>wl", "<cmd>WPMLog<cr>", { desc = "Open WPM log file" })
    vim.keymap.set("n", "<leader>wc", "<cmd>WPMClear<cr>", { desc = "Clear WPM history" })
  end,
}
```

### Add to Lualine (Optional)

```lua
-- Add to your lualine configuration
sections = {
  lualine_x = {
    {
      function()
        return require("wpm-tracker").get_wpm_display()
      end,
      cond = function()
        return require("wpm-tracker").get_current_wpm() > 0
      end,
      color = { fg = "#3EFFDC" },
    },
    -- ... other components
  },
}
```

#### Custom Display Format

Use the `get_current_wpm()` function to get the current WPM instead of calling
`get_wpm_display()`.

```lua
sections = {
  lualine_x = {
    {
      function()
        local wpm = require("wpm-tracker").get_current_wpm()
        -- Format the WPM as you like
        return string.format("WPM: %d", wpm)
      end,
      cond = function()
        return require("wpm-tracker").get_current_wpm() > 0
      end,
      color = { fg = "#3EFFDC" },
    },
    -- ... other components
  },
}
```

## Usage

Just start typing! The plugin automatically tracks your WPM and shows it in
lualine.

**Commands:**

- `:WPMStats` - Show detailed statistics
- `:WPMLog` - Open your WPM log file
- `:WPMClear` - Clear all WPM history and log file

## How It Works

The plugin tracks two types of WPM:

- **Manual WPM**: Only counts characters you actually type
- **Assisted WPM**: Includes completions from LSP, Supermaven, etc.

The plugin automatically stops tracking if you enter insert mode but don't type
anything within the configured idle timeout period, preventing empty sessions
from being recorded.

This gives you insight into both your raw typing speed and your overall coding
productivity.

## CSV Export

Your typing sessions are automatically saved to a CSV file:

```csv
timestamp,manual_wpm,assisted_wpm,duration,manual_chars,total_chars
2024-01-15 14:30:25,65,120,12.3,95,185
```

## Documentation

For advanced usage and API details:

```vim
:help wpm-tracker
```

## Contributing

Contributions welcome! Please feel free to submit issues and pull requests.

## License

MIT License
