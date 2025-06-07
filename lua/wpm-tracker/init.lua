local M = {}

-- Plugin state
local config = {
  log_file = vim.fn.stdpath("data") .. "/wpm-tracker.csv",
  average_window = 10, -- Number of entries to average over
  min_session_length = 5000, -- Only log sessions longer than 5 seconds (in milliseconds)
  update_interval = 1000, -- Update status line every 1 second (in milliseconds)
  idle_timeout = 5000, -- Stop tracking after 5 seconds of inactivity in insert mode (in milliseconds)
}

local state = {
  insert_start_time = nil,
  manually_typed_chars = 0,
  total_inserted_chars = 0,
  manual_wpm_history = {},
  assisted_wpm_history = {},
  current_avg_manual_wpm = 0,
  current_avg_assisted_wpm = 0,
  current_session_manual_wpm = 0,
  current_session_assisted_wpm = 0,
  is_tracking = false,
  update_timer = nil,
  idle_timer = nil,
  last_activity_time = nil,
  last_buffer_size = 0,
  last_file_size = 0,
  last_history_reload = 0,
}

-- Utility functions
local function get_timestamp()
  return os.time()
end

local function get_formatted_time()
  return os.date("%Y-%m-%d %H:%M:%S")
end

local function calculate_wpm(chars, time_seconds)
  if time_seconds <= 0 then return 0 end
  -- Standard WPM calculation: (characters / 5) / (time in minutes)
  local words = chars / 5
  local minutes = time_seconds / 60
  return math.floor(words / minutes + 0.5) -- Round to nearest integer
end

local function update_rolling_averages(manual_wpm, assisted_wpm)
  -- Update manual WPM history
  table.insert(state.manual_wpm_history, manual_wpm)
  if #state.manual_wpm_history > config.average_window then
    table.remove(state.manual_wpm_history, 1)
  end
  
  -- Update assisted WPM history  
  table.insert(state.assisted_wpm_history, assisted_wpm)
  if #state.assisted_wpm_history > config.average_window then
    table.remove(state.assisted_wpm_history, 1)
  end
  
  -- Calculate manual average
  local manual_sum = 0
  for _, wpm in ipairs(state.manual_wpm_history) do
    manual_sum = manual_sum + wpm
  end
  state.current_avg_manual_wpm = #state.manual_wpm_history > 0 and math.floor(manual_sum / #state.manual_wpm_history + 0.5) or 0
  
  -- Calculate assisted average
  local assisted_sum = 0
  for _, wpm in ipairs(state.assisted_wpm_history) do
    assisted_sum = assisted_sum + wpm
  end
  state.current_avg_assisted_wpm = #state.assisted_wpm_history > 0 and math.floor(assisted_sum / #state.assisted_wpm_history + 0.5) or 0
end

local function log_session(manual_wpm, assisted_wpm, duration, manual_chars, total_chars)
  local timestamp = get_formatted_time()
  local log_entry = string.format("%s,%d,%d,%.1f,%d,%d\n", timestamp, manual_wpm, assisted_wpm, duration, manual_chars, total_chars)
  
  local file = io.open(config.log_file, "a")
  if file then
    -- Write CSV header if file is new/empty
    local file_size = file:seek("end")
    if file_size == 0 then
      file:write("timestamp,manual_wpm,assisted_wpm,duration,manual_chars,total_chars\n")
    end
    file:write(log_entry)
    file:close()
  end
end

local function update_current_wpm()
  if not state.is_tracking or not state.insert_start_time then 
    state.current_session_manual_wpm = 0
    state.current_session_assisted_wpm = 0
    return 
  end
  
  local current_time = get_timestamp()
  local duration = current_time - state.insert_start_time
  
  if duration > 0 then
    -- Calculate manual WPM (keystrokes only)
    if state.manually_typed_chars > 0 then
      state.current_session_manual_wpm = calculate_wpm(state.manually_typed_chars, duration)
    else
      state.current_session_manual_wpm = 0
    end
    
    -- Calculate assisted WPM (all text insertions)
    if state.total_inserted_chars > 0 then
      state.current_session_assisted_wpm = calculate_wpm(state.total_inserted_chars, duration)
    else
      state.current_session_assisted_wpm = 0
    end
  else
    state.current_session_manual_wpm = 0
    state.current_session_assisted_wpm = 0
  end
end

-- Check if file has been modified and needs reloading
local function should_reload_history()
  local file = io.open(config.log_file, "r")
  if not file then return false end
  
  file:seek("end")
  local current_size = file:seek()
  file:close()
  
  local current_time = get_timestamp()
  local size_changed = current_size ~= state.last_file_size
  local time_elapsed = current_time - state.last_history_reload > 30 -- Reload every 30 seconds
  
  if size_changed or time_elapsed then
    state.last_file_size = current_size
    state.last_history_reload = current_time
    return true
  end
  
  return false
end

-- Efficiently read last N lines from file
local function read_last_lines(filepath, n)
  local file = io.open(filepath, "rb")
  if not file then return {} end
  
  -- Get file size
  file:seek("end")
  local filesize = file:seek()
  
  -- If file is too small, just read all
  if filesize < 1024 then
    file:seek("set", 0)
    local lines = {}
    for line in file:lines() do
      table.insert(lines, line)
    end
    file:close()
    -- Return last n lines
    local start_idx = math.max(1, #lines - n + 1)
    local result = {}
    for i = start_idx, #lines do
      table.insert(result, lines[i])
    end
    return result
  end
  
  -- For larger files, read from end in chunks
  local lines = {}
  local chunk_size = 1024
  local pos = filesize
  local buffer = ""
  
  while pos > 0 and #lines < n + 10 do -- Read extra lines to be safe
    local read_size = math.min(chunk_size, pos)
    pos = pos - read_size
    file:seek("set", pos)
    local chunk = file:read(read_size)
    buffer = chunk .. buffer
    
    -- Split into lines
    local temp_lines = {}
    for line in buffer:gmatch("([^\n]*)\n") do
      table.insert(temp_lines, 1, line)
    end
    
    -- Add to our lines (in reverse order since we're reading backwards)
    for i = 1, #temp_lines do
      table.insert(lines, 1, temp_lines[i])
    end
    
    -- Keep remaining buffer for next iteration
    local last_newline = buffer:find("\n[^\n]*$")
    if last_newline then
      buffer = buffer:sub(last_newline + 1)
    end
  end
  
  file:close()
  
  -- Return last n lines
  local start_idx = math.max(1, #lines - n + 1)
  local result = {}
  for i = start_idx, #lines do
    if lines[i] and lines[i] ~= "" then
      table.insert(result, lines[i])
    end
  end
  
  return result
end

-- Load historical data for averages (only last N entries)
local function load_history()
  local lines = read_last_lines(config.log_file, config.average_window)
  
  local recent_manual_wpms = {}
  local recent_assisted_wpms = {}
  
  -- Parse last N WPM values
  for _, line in ipairs(lines) do
    -- Skip header line and parse CSV format: timestamp,manual_wpm,assisted_wpm,duration,manual_chars,total_chars
    if line and not line:match("^timestamp,") then
      local parts = {}
      for part in line:gmatch("([^,]+)") do
        table.insert(parts, part)
      end
      if #parts >= 3 then
        local manual_wpm = tonumber(parts[2])
        local assisted_wpm = tonumber(parts[3])
        if manual_wpm then
          table.insert(recent_manual_wpms, manual_wpm)
        end
        if assisted_wpm then
          table.insert(recent_assisted_wpms, assisted_wpm)
        end
      end
    end
  end
  
  -- Set histories
  state.manual_wpm_history = recent_manual_wpms
  state.assisted_wpm_history = recent_assisted_wpms
  
  -- Calculate averages
  if #recent_manual_wpms > 0 then
    local sum = 0
    for _, wpm in ipairs(recent_manual_wpms) do
      sum = sum + wpm
    end
    state.current_avg_manual_wpm = math.floor(sum / #recent_manual_wpms + 0.5)
  end
  
  if #recent_assisted_wpms > 0 then
    local sum = 0
    for _, wpm in ipairs(recent_assisted_wpms) do
      sum = sum + wpm
    end
    state.current_avg_assisted_wpm = math.floor(sum / #recent_assisted_wpms + 0.5)
  end
  
  state.last_history_reload = get_timestamp()
end

local function stop_update_timer()
  if state.update_timer then
    state.update_timer:stop()
    state.update_timer:close()
    state.update_timer = nil
  end
end

local function start_update_timer()
  if state.update_timer then return end
  
  state.update_timer = vim.loop.new_timer()
  state.update_timer:start(0, config.update_interval, vim.schedule_wrap(function()
    if state.is_tracking then
      update_current_wpm()
      vim.cmd('redrawstatus')
    else
      -- Stop timer if not tracking
      if state.update_timer then
        state.update_timer:stop()
        state.update_timer:close()
        state.update_timer = nil
      end
    end
  end))
end

local function get_buffer_size()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local total = 0
  for _, line in ipairs(lines) do
    total = total + #line
  end
  return total
end

local function stop_idle_timer()
  if state.idle_timer then
    state.idle_timer:stop()
    state.idle_timer:close()
    state.idle_timer = nil
  end
end

local function stop_tracking()
  if not state.is_tracking or not state.insert_start_time then return end
  
  local end_time = get_timestamp()
  local duration = end_time - state.insert_start_time
  
  -- Only record sessions longer than minimum duration
  if duration >= (config.min_session_length / 1000) and (state.manually_typed_chars > 0 or state.total_inserted_chars > 0) then
    local manual_wpm = calculate_wpm(state.manually_typed_chars, duration)
    local assisted_wpm = calculate_wpm(state.total_inserted_chars, duration)
    update_rolling_averages(manual_wpm, assisted_wpm)
    log_session(manual_wpm, assisted_wpm, duration, state.manually_typed_chars, state.total_inserted_chars)
  end
  
  state.is_tracking = false
  state.insert_start_time = nil
  state.manually_typed_chars = 0
  state.total_inserted_chars = 0
  state.current_session_manual_wpm = 0
  state.current_session_assisted_wpm = 0
  state.last_buffer_size = 0
  state.last_activity_time = nil
  stop_update_timer()
  stop_idle_timer()
end

local function start_idle_timer()
  if state.idle_timer then return end
  
  state.idle_timer = vim.loop.new_timer()
  state.idle_timer:start(config.idle_timeout, 0, vim.schedule_wrap(function()
    -- Check if we've been idle for too long
    if state.is_tracking and state.last_activity_time then
      local current_time = get_timestamp()
      local idle_time = current_time - state.last_activity_time
      
      -- If idle timeout exceeded and no meaningful activity, stop tracking
      if idle_time >= (config.idle_timeout / 1000) and state.manually_typed_chars == 0 and state.total_inserted_chars == 0 then
        stop_tracking()
      end
    end
    
    -- Clean up timer
    if state.idle_timer then
      state.idle_timer:stop()
      state.idle_timer:close()
      state.idle_timer = nil
    end
  end))
end

local function reset_idle_timer()
  state.last_activity_time = get_timestamp()
  stop_idle_timer()
  start_idle_timer()
end

local function start_tracking()
  if state.is_tracking then return end
  
  state.is_tracking = true
  state.insert_start_time = get_timestamp()
  state.manually_typed_chars = 0
  state.total_inserted_chars = 0
  state.current_session_manual_wpm = 0
  state.current_session_assisted_wpm = 0
  
  -- Initialize buffer size tracking
  state.last_buffer_size = get_buffer_size()
  
  -- Start idle timer to handle inactivity
  state.last_activity_time = get_timestamp()
  start_idle_timer()
  
  start_update_timer()
end

local function on_char_typed()
  if state.is_tracking then
    state.manually_typed_chars = state.manually_typed_chars + 1
    reset_idle_timer()
  end
end

local function on_text_changed()
  if not state.is_tracking then return end
  
  -- Get total buffer size to track all insertions
  local current_buffer_size = get_buffer_size()
  local size_diff = current_buffer_size - state.last_buffer_size
  
  if size_diff > 0 then
    -- Track all insertions for assisted WPM (includes completions)
    state.total_inserted_chars = state.total_inserted_chars + size_diff
    reset_idle_timer()
  end
  
  state.last_buffer_size = current_buffer_size
end

-- Setup autocmds
local function setup_autocmds()
  local augroup = vim.api.nvim_create_augroup("WPMTracker", { clear = true })
  
  -- Start tracking on insert mode
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    callback = start_tracking,
  })
  
  -- Stop tracking on leaving insert mode
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    callback = stop_tracking,
  })
  
  -- Track manual character input
  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = augroup,
    callback = on_char_typed,
  })
  
  -- Track all text changes (including completions)
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = augroup,
    callback = on_text_changed,
  })
  
  -- Handle vim exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      stop_tracking()
      stop_update_timer()
      stop_idle_timer()
    end,
  })
  
  -- Sync history when window gains focus (multi-instance sync)
  vim.api.nvim_create_autocmd("FocusGained", {
    group = augroup,
    callback = function()
      if should_reload_history() then
        load_history()
        -- Refresh status line to show updated averages
        vim.cmd('redrawstatus')
      end
    end,
  })
end

-- Public API
function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  
  -- Ensure log directory exists
  local log_dir = vim.fn.fnamemodify(config.log_file, ":h")
  vim.fn.mkdir(log_dir, "p")
  
  load_history()
  setup_autocmds()
end

function M.get_current_manual_wpm()
  -- Return current session manual WPM if actively typing, otherwise return rolling average
  if state.is_tracking and state.current_session_manual_wpm > 0 then
    return state.current_session_manual_wpm
  end
  return state.current_avg_manual_wpm
end

function M.get_current_assisted_wpm()
  -- Return current session assisted WPM if actively typing, otherwise return rolling average
  if state.is_tracking and state.current_session_assisted_wpm > 0 then
    return state.current_session_assisted_wpm
  end
  return state.current_avg_assisted_wpm
end

function M.get_current_wpm()
  return M.get_current_assisted_wpm()
end

function M.get_wpm_display()
  local wpm = M.get_current_wpm()
  
  if wpm == 0 then
    return ""
  end
  
  local display_text = string.format("⚡%d wpm", wpm)
  return display_text
end

function M.is_currently_tracking()
  return state.is_tracking
end

function M.get_stats()
  return {
    current_avg_manual = state.current_avg_manual_wpm,
    current_avg_assisted = state.current_avg_assisted_wpm,
    current_session_manual = state.current_session_manual_wpm,
    current_session_assisted = state.current_session_assisted_wpm,
    is_tracking = state.is_tracking,
    manual_history_size = #state.manual_wpm_history,
    assisted_history_size = #state.assisted_wpm_history,
    manual_chars = state.manually_typed_chars,
    total_chars = state.total_inserted_chars,
  }
end

-- Manual commands for testing/debugging
vim.api.nvim_create_user_command("WPMStats", function()
  local stats = M.get_stats()
  print(string.format(
    "WPM Stats:\n" ..
    "  Manual: Session=%d, Avg=%d, Chars=%d\n" ..
    "  Assisted: Session=%d, Avg=%d, Chars=%d\n" ..
    "  Tracking=%s, History=%d/%d",
    stats.current_session_manual,
    stats.current_avg_manual,
    stats.manual_chars,
    stats.current_session_assisted,
    stats.current_avg_assisted,
    stats.total_chars,
    stats.is_tracking and "yes" or "no",
    stats.manual_history_size,
    stats.assisted_history_size
  ))
end, { desc = "Show WPM tracker statistics" })

vim.api.nvim_create_user_command("WPMLog", function()
  vim.cmd("edit " .. config.log_file)
end, { desc = "Open WPM log file" })

vim.api.nvim_create_user_command("WPMClear", function()
  M.clear_history()
end, { desc = "Clear WPM history and log file" })

function M.clear_history()
  -- Stop tracking if currently active
  if state.is_tracking then
    stop_tracking()
  end
  
  -- Clear in-memory state
  state.manual_wpm_history = {}
  state.assisted_wpm_history = {}
  state.current_avg_manual_wpm = 0
  state.current_avg_assisted_wpm = 0
  state.current_session_manual_wpm = 0
  state.current_session_assisted_wpm = 0
  state.manually_typed_chars = 0
  state.total_inserted_chars = 0
  state.last_file_size = 0
  
  -- Clear the log file
  local file = io.open(config.log_file, "w")
  if file then
    file:close()
    print("WPM history cleared successfully")
  else
    print("Error: Could not clear WPM log file at " .. config.log_file)
  end
  
  -- Refresh status line to reflect cleared state
  vim.cmd('redrawstatus')
end

return M 