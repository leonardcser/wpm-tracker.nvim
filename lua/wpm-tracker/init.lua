-- Bit operations compatibility (Lua 5.2+ has bit32, LuaJIT has bit)
---@diagnostic disable-next-line: undefined-global
local bit32 = bit32 or bit or require("bit32")

---@class WPMTrackerConfig
---@field log_file string Path to the CSV log file
---@field average_window number Number of entries to average over
---@field min_session_length number Minimum session length in milliseconds
---@field update_interval number Update status line interval in milliseconds
---@field idle_timeout number Idle timeout in milliseconds

---@class Timer
---@field start fun(self: Timer, delay: number, interval: number, callback: function)
---@field stop fun(self: Timer)
---@field close fun(self: Timer)

---@class uv
---@field new_timer fun(): Timer

---@class WPMTrackerState
---@field insert_start_time number|nil Timestamp when insert mode started
---@field manually_typed_chars number Count of manually typed characters
---@field total_inserted_chars number Count of all inserted characters (including completions)
---@field manual_wpm_history number[] History of manual WPM values
---@field assisted_wpm_history number[] History of assisted WPM values
---@field current_avg_manual_wpm number Current rolling average of manual WPM
---@field current_avg_assisted_wpm number Current rolling average of assisted WPM
---@field current_session_manual_wpm number Current session manual WPM
---@field current_session_assisted_wpm number Current session assisted WPM
---@field is_tracking boolean Whether currently tracking typing
---@field update_timer Timer|nil Timer for status updates
---@field idle_timer Timer|nil Timer for idle detection
---@field last_activity_time number|nil Timestamp of last activity
---@field last_buffer_size number Previous buffer size for change detection
---@field last_file_size number Previous log file size for change detection
---@field last_history_reload number Timestamp of last history reload

---@class WPMTrackerStats
---@field current_avg_manual number Current rolling average manual WPM
---@field current_avg_assisted number Current rolling average assisted WPM
---@field current_session_manual number Current session manual WPM
---@field current_session_assisted number Current session assisted WPM
---@field is_tracking boolean Whether currently tracking
---@field manual_history_size number Size of manual WPM history
---@field assisted_history_size number Size of assisted WPM history
---@field manual_chars number Current session manual characters
---@field total_chars number Current session total characters

---@class WPMDataPoint
---@field timestamp string Formatted timestamp
---@field manual_wpm number Manual WPM value
---@field assisted_wpm number Assisted WPM value
---@field duration number Session duration in seconds
---@field manual_chars number Manual characters typed
---@field total_chars number Total characters inserted

local M = {}

-- Namespace for plot highlights (extmarks)
local NS_PLOT = (vim and vim.api and vim.api.nvim_create_namespace)
		and vim.api.nvim_create_namespace("wpm-tracker-plot")
	or 0

-- Plugin state
---@type WPMTrackerConfig
local config = {
	log_file = vim.fn.stdpath("data") .. "/wpm-tracker.csv",
	average_window = 10, -- Number of entries to average over
	min_session_length = 5000, -- Only log sessions longer than 5 seconds (in milliseconds)
	update_interval = 1000, -- Update status line every 1 second (in milliseconds)
	idle_timeout = 5000, -- Stop tracking after 5 seconds of inactivity in insert mode (in milliseconds)
}

---@type WPMTrackerState
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
---@return number
local function get_timestamp()
	return os.time()
end

---@return string
local function get_formatted_time()
	return os.date("%Y-%m-%d %H:%M:%S") --[[@as string]]
end

---@param chars number Number of characters typed
---@param time_seconds number Time in seconds
---@return number WPM value
local function calculate_wpm(chars, time_seconds)
	if time_seconds <= 0 then
		return 0
	end
	-- Standard WPM calculation: (characters / 5) / (time in minutes)
	local words = chars / 5
	local minutes = time_seconds / 60
	return math.floor(words / minutes + 0.5) -- Round to nearest integer
end

---@param manual_wpm number Manual WPM value
---@param assisted_wpm number Assisted WPM value
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
	state.current_avg_manual_wpm = #state.manual_wpm_history > 0
			and math.floor(manual_sum / #state.manual_wpm_history + 0.5)
		or 0

	-- Calculate assisted average
	local assisted_sum = 0
	for _, wpm in ipairs(state.assisted_wpm_history) do
		assisted_sum = assisted_sum + wpm
	end
	state.current_avg_assisted_wpm = #state.assisted_wpm_history > 0
			and math.floor(assisted_sum / #state.assisted_wpm_history + 0.5)
		or 0
end

---@param manual_wpm number Manual WPM value
---@param assisted_wpm number Assisted WPM value
---@param duration number Session duration in seconds
---@param manual_chars number Manual characters typed
---@param total_chars number Total characters inserted
local function log_session(manual_wpm, assisted_wpm, duration, manual_chars, total_chars)
	local timestamp = get_formatted_time()
	local log_entry =
		string.format("%s,%d,%d,%.1f,%d,%d\n", timestamp, manual_wpm, assisted_wpm, duration, manual_chars, total_chars)

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

---@return nil
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
---@return boolean
local function should_reload_history()
	local file = io.open(config.log_file, "r")
	if not file then
		return false
	end

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
---@param filepath string Path to the file to read
---@param n number Number of lines to read from the end
---@return string[] Array of lines
local function read_last_lines(filepath, n)
	local file = io.open(filepath, "rb")
	if not file then
		return {}
	end

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
---@return nil
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

---@return nil
local function stop_update_timer()
	if state.update_timer then
		state.update_timer:stop()
		state.update_timer:close()
		state.update_timer = nil
	end
end

---@return nil
local function start_update_timer()
	if state.update_timer then
		return
	end

	---@type uv
	local loop = vim.loop
	state.update_timer = loop.new_timer()
	state.update_timer:start(
		0,
		config.update_interval,
		vim.schedule_wrap(function()
			if state.is_tracking then
				update_current_wpm()
				vim.cmd("redrawstatus")
			else
				-- Stop timer if not tracking
				if state.update_timer then
					state.update_timer:stop()
					state.update_timer:close()
					state.update_timer = nil
				end
			end
		end)
	)
end

---@return number Total character count in current buffer
local function get_buffer_size()
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local total = 0
	for _, line in ipairs(lines) do
		total = total + #line
	end
	return total
end

---@return nil
local function stop_idle_timer()
	if state.idle_timer then
		state.idle_timer:stop()
		state.idle_timer:close()
		state.idle_timer = nil
	end
end

---@return nil
local function stop_tracking()
	if not state.is_tracking or not state.insert_start_time then
		return
	end

	local end_time = get_timestamp()
	local duration = end_time - state.insert_start_time

	-- Only record sessions longer than minimum duration
	if
		duration >= (config.min_session_length / 1000)
		and (state.manually_typed_chars > 0 or state.total_inserted_chars > 0)
	then
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

---@return nil
local function start_idle_timer()
	if state.idle_timer then
		return
	end

	---@type uv
	local loop = vim.loop
	state.idle_timer = loop.new_timer()
	state.idle_timer:start(
		config.idle_timeout,
		0,
		vim.schedule_wrap(function()
			-- Check if we've been idle for too long
			if state.is_tracking and state.last_activity_time then
				local current_time = get_timestamp()
				local idle_time = current_time - state.last_activity_time

				-- If idle timeout exceeded and no meaningful activity, stop tracking
				if
					idle_time >= (config.idle_timeout / 1000)
					and state.manually_typed_chars == 0
					and state.total_inserted_chars == 0
				then
					stop_tracking()
				end
			end

			-- Clean up timer
			if state.idle_timer then
				state.idle_timer:stop()
				state.idle_timer:close()
				state.idle_timer = nil
			end
		end)
	)
end

---@return nil
local function reset_idle_timer()
	state.last_activity_time = get_timestamp()
	stop_idle_timer()
	start_idle_timer()
end

---@return nil
local function start_tracking()
	if state.is_tracking then
		return
	end

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

---@return nil
local function on_char_typed()
	if state.is_tracking then
		state.manually_typed_chars = state.manually_typed_chars + 1
		reset_idle_timer()
	end
end

---@return nil
local function on_text_changed()
	if not state.is_tracking then
		return
	end

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
---@return nil
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
				vim.cmd("redrawstatus")
			end
		end,
	})
end

-- Public API
---@param opts WPMTrackerConfig|nil Configuration options
---@return nil
function M.setup(opts)
	config = vim.tbl_extend("force", config, opts or {})

	-- Ensure log directory exists
	local log_dir = vim.fn.fnamemodify(config.log_file, ":h")
	vim.fn.mkdir(log_dir, "p")

	load_history()
	setup_autocmds()
end

---@return number Current manual WPM
function M.get_current_manual_wpm()
	-- Return current session manual WPM if actively typing, otherwise return rolling average
	if state.is_tracking and state.current_session_manual_wpm > 0 then
		return state.current_session_manual_wpm
	end
	return state.current_avg_manual_wpm
end

---@return number Current assisted WPM
function M.get_current_assisted_wpm()
	-- Return current session assisted WPM if actively typing, otherwise return rolling average
	if state.is_tracking and state.current_session_assisted_wpm > 0 then
		return state.current_session_assisted_wpm
	end
	return state.current_avg_assisted_wpm
end

---@return number Current WPM (assisted)
function M.get_current_wpm()
	return M.get_current_assisted_wpm()
end

---@return string Formatted WPM display string
function M.get_wpm_display()
	local wpm = M.get_current_wpm()

	if wpm == 0 then
		return ""
	end

	local display_text = string.format("⚡%d wpm", wpm)
	return display_text
end

---@return boolean Whether currently tracking
function M.is_currently_tracking()
	return state.is_tracking
end

---@return WPMTrackerStats Current statistics
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
	print(
		string.format(
			"WPM Stats:\n"
				.. "  Manual: Session=%d, Avg=%d, Chars=%d\n"
				.. "  Assisted: Session=%d, Avg=%d, Chars=%d\n"
				.. "  Tracking=%s, History=%d/%d",
			stats.current_session_manual,
			stats.current_avg_manual,
			stats.manual_chars,
			stats.current_session_assisted,
			stats.current_avg_assisted,
			stats.total_chars,
			stats.is_tracking and "yes" or "no",
			stats.manual_history_size,
			stats.assisted_history_size
		)
	)
end, { desc = "Show WPM tracker statistics" })

vim.api.nvim_create_user_command("WPMLog", function()
	vim.cmd("tabnew " .. config.log_file)
end, { desc = "Open WPM log file" })

vim.api.nvim_create_user_command("WPMClear", function()
	local confirm =
		vim.fn.input("Are you sure you want to clear all WPM history? This action cannot be undone. (y/N): ")
	if confirm:lower() == "y" or confirm:lower() == "yes" then
		M.clear_history()
	else
		print("WPM history clear cancelled")
	end
end, { desc = "Clear WPM history and log file" })

vim.api.nvim_create_user_command("WPMPlot", function(opts)
	local max_points = nil
	if opts.args and opts.args ~= "" then
		max_points = tonumber(opts.args)
		if not max_points or max_points <= 0 then
			print("Error: Invalid number of points. Please provide a positive integer.")
			return
		end
	end
	M.plot_data(max_points)
end, {
	desc = "Plot ASCII charts of WPM data with moving average smoothing",
	nargs = "?",
	complete = function()
		return { "20", "30", "50", "80", "100", "150", "200" }
	end,
})

---@return nil
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
	vim.cmd("redrawstatus")
end

-- Read all CSV data from log file
---@return WPMDataPoint[] Array of WPM data points
local function read_all_csv_data()
	local file = io.open(config.log_file, "r")
	if not file then
		return {}
	end

	local data = {}
	for line in file:lines() do
		-- Skip header line
		if line and not line:match("^timestamp,") then
			local parts = {}
			for part in line:gmatch("([^,]+)") do
				table.insert(parts, part)
			end
			if #parts >= 6 then
				table.insert(data, {
					timestamp = parts[1],
					manual_wpm = tonumber(parts[2]) or 0,
					assisted_wpm = tonumber(parts[3]) or 0,
					duration = tonumber(parts[4]) or 0,
					manual_chars = tonumber(parts[5]) or 0,
					total_chars = tonumber(parts[6]) or 0,
				})
			end
		end
	end
	file:close()
	return data
end

-- Generate ASCII chart for WPM data
---@param data_points WPMDataPoint[] Array of WPM data points
---@param chart_type "manual"|"assisted" Type of chart to generate
---@param max_points number|nil Maximum number of points to display
---@return string ASCII chart string
local function generate_ascii_chart(data_points, chart_type, max_points)
	if #data_points == 0 then
		return "No data available for plotting"
	end

	-- Limit data points if specified (take the most recent). If no limit, keep all.
	local points = data_points
	if max_points and #points > max_points then
		local start_idx = #points - max_points + 1
		points = {}
		for i = start_idx, #data_points do
			table.insert(points, data_points[i])
		end
	end

	-- Determine chart width from available columns, with sensible bounds
	local columns = (vim and vim.o and vim.o.columns) or 80
	local left_margin = 4 -- space for y-axis labels like " 80│" (4 chars)
	local max_width = math.max(30, math.min(120, columns - (left_margin + 2)))

	local width
	if not max_points then
		-- No limit requested: approximate to fit window width
		width = math.min(#points, max_width)
	else
		width = math.min(#points, max_width)
		if #points > width then
			-- Focus on most recent data for fixed-width chart
			local start_idx = #points - width + 1
			local trimmed = {}
			for i = start_idx, #points do
				trimmed[#trimmed + 1] = points[i]
			end
			points = trimmed
		end
	end

	-- Extract raw values and compute smoothed values (window size = 5 or up to length)
	local raw_values = {}
	for _, p in ipairs(points) do
		raw_values[#raw_values + 1] = (chart_type == "manual" and p.manual_wpm or p.assisted_wpm) or 0
	end

	-- First pass: compute statistics for outlier detection on raw values
	local sum = 0
	for _, v in ipairs(raw_values) do
		sum = sum + v
	end
	local mean = sum / math.max(1, #raw_values)

	local variance = 0
	for _, v in ipairs(raw_values) do
		variance = variance + (v - mean) ^ 2
	end
	local std_dev = math.sqrt(variance / math.max(1, #raw_values))

	-- Outlier rejection: exclude values beyond ±3σ from raw data
	local outlier_threshold_min = mean - 3 * std_dev
	local outlier_threshold_max = mean + 3 * std_dev

	-- Filter raw values to remove extreme outliers
	local filtered_raw = {}
	local outlier_count = 0
	for _, v in ipairs(raw_values) do
		if v >= outlier_threshold_min and v <= outlier_threshold_max then
			filtered_raw[#filtered_raw + 1] = v
		else
			-- Replace outliers with mean to avoid gaps in the chart
			filtered_raw[#filtered_raw + 1] = mean
			outlier_count = outlier_count + 1
		end
	end

	-- Compute smoothed values from filtered data
	local smoothed_values = {}
	local window_size = math.min(5, #filtered_raw)
	if window_size < 1 then
		window_size = 1
	end
	for i = 1, #filtered_raw do
		local s, c = 0, 0
		local a = math.max(1, i - math.floor(window_size / 2))
		local b = math.min(#filtered_raw, i + math.floor(window_size / 2))
		for j = a, b do
			s = s + filtered_raw[j]
			c = c + 1
		end
		smoothed_values[i] = s / math.max(1, c)
	end

	-- If needed, downsample values to fit width (approximate all data)
	local function resample(values, target_len)
		local n = #values
		if n <= target_len then
			return values
		end
		local out = {}
		local ratio = n / target_len
		for i = 1, target_len do
			local a = math.floor((i - 1) * ratio) + 1
			local b = math.floor(i * ratio)
			if b < a then
				b = a
			end
			local s, c = 0, 0
			for j = a, b do
				s = s + values[j]
				c = c + 1
			end
			out[i] = s / math.max(1, c)
		end
		return out
	end

	-- Resample to 2x width since braille has 2 horizontal pixels per character
	local disp_smooth = resample(smoothed_values, width * 2)

	-- Determine plot range from filtered data
	local min_val, max_val = math.huge, -math.huge
	for _, v in ipairs(disp_smooth) do
		if v < min_val then
			min_val = v
		end
		if v > max_val then
			max_val = v
		end
	end
	if min_val == max_val then
		max_val = min_val + 1
	end

	-- Choose y-ticks (nice numbers)
	local function nice_step(range)
		if range <= 0 then
			return 1
		end
		local rough = range / 4
		local mag = 10 ^ math.floor((math.log(rough) / math.log(10)))
		local norm = rough / mag
		local step
		if norm < 1.5 then
			step = 1
		elseif norm < 3 then
			step = 2
		elseif norm < 7 then
			step = 5
		else
			step = 10
		end
		return step * mag
	end

	local range = max_val - min_val
	local step = nice_step(range)
	local tick_min = math.floor(min_val / step) * step
	local tick_max = math.ceil(max_val / step) * step

	-- Chart dimensions
	local height = 15
	local chart = {}
	for i = 1, height do
		chart[i] = {}
		for j = 1, width do
			chart[i][j] = " "
		end
	end

	-- Helper to map value -> row
	local function row_for(v)
		local t = (v - min_val) / (max_val - min_val)
		local r = height - math.floor(t * (height - 1) + 0.5)
		return math.max(1, math.min(height, r))
	end

	-- Braille character mapping: each character has 2 columns × 4 rows of dots
	-- Braille pattern: dots 1-8 map to bits in a specific pattern
	-- 0x2800 is the base braille character (no dots)
	local braille_base = 0x2800
	-- Dot positions (1-indexed for Lua):
	-- Column 1: dots 1,2,3,7 (left column, top to bottom)
	-- Column 2: dots 4,5,6,8 (right column, top to bottom)
	local dot_map = {
		{1, 2, 3, 7}, -- left column (dots for rows 1-4)
		{4, 5, 6, 8}  -- right column (dots for rows 1-4)
	}

	-- Braille canvas: each cell can have 2×4 dots
	-- We'll use pixel coordinates: (px, py) where px is in [1, width*2] and py is in [1, height*4]
	local braille_width = width
	local braille_height = height
	local pixels = {}
	for r = 1, braille_height * 4 do
		pixels[r] = {}
		for c = 1, braille_width * 2 do
			pixels[r][c] = false
		end
	end

	-- Helper to set a pixel in braille coordinates
	local function set_pixel(px, py)
		if px >= 1 and px <= braille_width * 2 and py >= 1 and py <= braille_height * 4 then
			pixels[py][px] = true
		end
	end

	-- Map value to pixel row (inverted: high values at top)
	local function pixel_row_for(v)
		local t = (v - min_val) / (max_val - min_val)
		local py = (braille_height * 4) - math.floor(t * (braille_height * 4 - 1) + 0.5)
		return math.max(1, math.min(braille_height * 4, py))
	end

	-- Compute y-axis tick rows (in character rows, not pixels)
	local grid_rows = {}
	for y = tick_min, tick_max, step do
		local r = row_for(y)
		grid_rows[r] = y
	end

	-- Plot smoothed series with line drawing
	for i = 1, #disp_smooth do
		if i > width * 2 then break end
		local pr = pixel_row_for(disp_smooth[i])
		set_pixel(i, pr)

		-- Draw line to previous point
		if i > 1 then
			local prev_pr = pixel_row_for(disp_smooth[i - 1])
			local steps = math.abs(pr - prev_pr)
			if steps > 1 then
				local dir = (pr > prev_pr) and 1 or -1
				for s = 1, steps - 1 do
					set_pixel(i, prev_pr + s * dir)
				end
			end
		end
	end

	-- Convert pixel array to braille characters
	local chart_lines = {}
	for char_row = 1, braille_height do
		local line = {}
		for char_col = 1, braille_width do
			local code = braille_base
			-- Check each of the 8 dots in this character cell
			for dot_col = 1, 2 do
				for dot_row = 1, 4 do
					local px = (char_col - 1) * 2 + dot_col
					local py = (char_row - 1) * 4 + dot_row
					if pixels[py] and pixels[py][px] then
						local dot_num = dot_map[dot_col][dot_row]
						code = code + bit32.lshift(1, dot_num - 1)
					end
				end
			end
			line[char_col] = vim.fn.nr2char(code)
		end
		chart_lines[char_row] = table.concat(line)
	end

	-- Title and legend
	local result = {}
	local title = string.format(
		"%s WPM (n=%d, avg=%d, smooth=%d)",
		chart_type == "manual" and "Manual" or "Assisted",
		#points,
		math.floor(mean + 0.5),
		math.min(5, #raw_values)
	)
	if outlier_count > 0 then
		title = title .. string.format("  [%d outliers excluded]", outlier_count)
	end
	table.insert(result, title)
	table.insert(result, "")

	-- Y-axis with selective tick labels
	for i = 1, height do
		local tick_label = grid_rows[i]
		local label
		if tick_label then
			label = string.format("%3.0f│", tick_label)
		else
			label = "   │"
		end
		table.insert(result, label .. chart_lines[i])
	end

	-- X-axis with ticks every ~10 cols
	local x_axis = {}
	for i = 1, width do
		x_axis[i] = "─"
	end
	local tick_every = math.max(10, math.floor(width / 6))
	for i = 1, width, tick_every do
		x_axis[i] = "┬"
	end
	table.insert(result, string.rep(" ", left_margin) .. table.concat(x_axis))

	-- X labels: show dates if span crosses multiple days; otherwise show times (HH:MM)
	local function short_date(ts)
		if not ts or #ts < 10 then
			return ts or ""
		end
		return ts:sub(1, 10)
	end
	local function short_time(ts)
		if not ts or #ts < 16 then
			return ts or ""
		end
		return ts:sub(12, 16)
	end
	local first_ts = points[1] and points[1].timestamp or ""
	local mid_ts = points[math.floor(#points / 2)] and points[math.floor(#points / 2)].timestamp or ""
	local last_ts = points[#points] and points[#points].timestamp or ""
	local spans_multiple_days = (short_date(first_ts) ~= short_date(last_ts))
	local labels_line = string.rep(" ", left_margin)
	local first_label = spans_multiple_days and short_date(first_ts) or short_time(first_ts)
	local mid_label = spans_multiple_days and short_date(mid_ts) or short_time(mid_ts)
	local last_label = spans_multiple_days and short_date(last_ts) or short_time(last_ts)

	-- Place labels at approximate positions
	local lbl = {}
	for i = 1, width do
		lbl[i] = " "
	end
	local function put_label(pos, text)
		pos = math.max(1, math.min(width - #text + 1, pos))
		for k = 1, #text do
			lbl[pos + k - 1] = text:sub(k, k)
		end
	end
	put_label(1, first_label)
	put_label(math.floor(width / 2 - #mid_label / 2), mid_label)
	put_label(width - #last_label + 1, last_label)
	table.insert(result, labels_line .. table.concat(lbl))

	table.insert(result, "")
	return table.concat(result, "\n")
end

---@param max_points number|nil Maximum number of points to plot
---@return nil
function M.plot_data(max_points)
	local data = read_all_csv_data()
	if #data == 0 then
		print("No WPM data available for plotting")
		return
	end

	local manual_chart = generate_ascii_chart(data, "manual", max_points)
	local assisted_chart = generate_ascii_chart(data, "assisted", max_points)

	print("WPM Charts (raw + smoothed):")
	print(string.rep("=", 60))
	print("")
	print(manual_chart)
	print("")
	print(assisted_chart)
	print("")
	print(string.format("Total sessions: %d", #data))
end

-- Open plots in a scratch buffer with highlights (no ANSI escapes)
---@param max_points number|nil
---@return nil
function M.plot_data_buffer(max_points)
	local data = read_all_csv_data()
	if #data == 0 then
		print("No WPM data available for plotting")
		return
	end

	local header = "WPM Charts (buffer)"
	local divider = string.rep("=", 60)
	local manual_chart = generate_ascii_chart(data, "manual", max_points)
	local assisted_chart = generate_ascii_chart(data, "assisted", max_points)
	local summary = string.format("Total sessions: %d", #data)

	-- Split into lines
	local lines = {}
	local function split_lines(s)
		for line in tostring(s):gmatch("([^\n]*)\n?") do
			if line == nil then
				break
			end
			if #line == 0 and s:sub(-1) ~= "\n" then
				break
			end
			table.insert(lines, line)
		end
	end
	table.insert(lines, header)
	table.insert(lines, divider)
	table.insert(lines, "")
	split_lines(manual_chart)
	table.insert(lines, "")
	split_lines(assisted_chart)
	table.insert(lines, "")
	table.insert(lines, summary)

	-- Create scratch buffer and window
	vim.cmd("tabnew")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.bo[buf].filetype = "wpmplot"

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false

	-- Define highlight groups (minimal defaults, theme-friendly)
	local function set_hl(name, opts)
		pcall(vim.api.nvim_set_hl, 0, name, opts)
	end
	set_hl("WPMPlotGrid", { ctermfg = 8, fg = "#6a6a6a" })
	set_hl("WPMPlotMean", { ctermfg = 7, fg = "#bcbcbc", bold = true })
	set_hl("WPMPlotSmooth", { ctermfg = 2, fg = "#98c379" })
	set_hl("WPMPlotRaw", { ctermfg = 4, fg = "#61afef" })

	-- Helper to add contiguous runs for a given pattern after the chart margin
	local function add_runs_for_pattern(row_idx, line, margin_byte, patt, hl)
		local init = margin_byte + 1
		while true do
			local s, e = line:find(patt, init)
			if not s then
				break
			end
			if s <= margin_byte then
				s = margin_byte + 1
			end
			if e > s - 1 then
				pcall(vim.api.nvim_buf_set_extmark, buf, NS_PLOT, row_idx, s - 1, {
					end_row = row_idx,
					end_col = e,
					hl_group = hl,
					hl_mode = "combine",
				})
			end
			init = e + 1
		end
	end

	-- Clear and apply highlights for plot areas
	pcall(vim.api.nvim_buf_clear_namespace, buf, NS_PLOT, 0, -1)
	for i, line in ipairs(lines) do
		local pipe_pos = line:find("│", 1, true)
		if pipe_pos then
			-- Highlight within the chart region only
			add_runs_for_pattern(i - 1, line, pipe_pos, "o+", "WPMPlotSmooth")
			add_runs_for_pattern(i - 1, line, pipe_pos, "%.+", "WPMPlotSmooth")
			add_runs_for_pattern(i - 1, line, pipe_pos, "%++", "WPMPlotRaw")
		end
	end
end

-- User command to open colored plot in a buffer
vim.api.nvim_create_user_command("WPMPlotBuffer", function(opts)
	local max_points = nil
	if opts.args and opts.args ~= "" then
		max_points = tonumber(opts.args)
		if not max_points or max_points <= 0 then
			print("Error: Invalid number of points. Please provide a positive integer.")
			return
		end
	end
	M.plot_data_buffer(max_points)
end, {
	desc = "Open WPM ASCII charts in a scratch buffer with highlights",
	nargs = "?",
	complete = function()
		return { "20", "30", "50", "80", "100", "150", "200" }
	end,
})

return M
