-- jobcontrol/utils.lua
-- Utility functions for JobControl.nvim

local M = {}

-- Generate a unique buffer name
function M.generate_unique_buffer_name(base_name)
	local counter = 0
	local name = base_name

	while vim.fn.bufexists(name) ~= 0 do
		counter = counter + 1
		name = base_name .. "_" .. counter
	end

	return name
end

-- Safely encode JSON data
function M.safe_json_encode(data)
	local status, result = pcall(vim.json.encode, data)
	if status then
		return result
	else
		vim.notify("Failed to encode job data: " .. tostring(result), vim.log.levels.ERROR)
		return "{}"
	end
end

-- Safely decode JSON data
function M.safe_json_decode(str)
	if not str or str == "" then
		return {}
	end

	local status, result = pcall(vim.json.decode, str)
	if status then
		return result
	else
		vim.notify("Failed to decode job data: " .. tostring(result), vim.log.levels.ERROR)
		return {}
	end
end

-- Strip ANSI escape sequences from text
function M.strip_ansi_escapes(text)
	-- Remove ANSI escape sequences: ESC[ ... m
	-- Match a wider range of ANSI sequences
	return text
		:gsub("\027%[[^%a]*%a", "")
		:gsub("\027%(%a", "") -- Special character set sequences
		:gsub("\027%[[%d;]-[HJKmsu]", "") -- Cursor movement and clear sequences
		:gsub("\027%]%d+;[^\007]*\007", "") -- OSC sequences (window title, etc.)
end

-- Extract URLs from text
function M.extract_urls(text)
	local urls = {}

	-- Extract URLs starting with http:// or https://
	for url in text:gmatch("https?://[%w%p]+") do
		table.insert(urls, url)
	end

	return urls
end

-- Format timestamp according to configuration
function M.format_timestamp(config)
	return os.date(config.timestamps.format)
end

-- Parse cd command and extract working directory and actual command
function M.parse_cd_command(cmd_str)
	local cwd = nil
	local cmd = cmd_str

	-- Match common cd patterns
	local cd_pattern = "^%s*cd%s+([^&;]+)%s*&&%s*(.+)$"
	local dir, remaining = string.match(cmd_str, cd_pattern)

	if dir and remaining then
		-- Remove quotes if present
		dir = dir:gsub('^"(.-)"$', "%1"):gsub("^'(.-)'$", "%1"):gsub("%s+$", "")
		cwd = dir
		cmd = remaining
	end

	return cwd, cmd
end

-- Expand path with tilde support
function M.expand_path(path)
	if path:sub(1, 1) == "~" then
		return vim.fn.expand(path)
	end
	return path
end

-- Format a log line with timestamp
function M.format_log_line(content, config)
	if config.timestamps.enabled then
		return "[" .. M.format_timestamp(config) .. "] " .. content
	else
		return content
	end
end

-- Format ngrok output into a readable form
function M.format_ngrok_output(text)
	-- Create a buffer to hold our reformatted output
	local formatted = {}

	-- Extract the forwarding URL (the most important info)
	local forwarding_url = text:match("Forwarding%s+(%S+)%s+%->")
	if forwarding_url then
		table.insert(formatted, "🌐 FORWARDING URL: " .. forwarding_url)
		table.insert(formatted, "")
	end

	-- Extract session status
	local session_status = text:match("Session%s+Status%s+(%S+)")
	if session_status then
		table.insert(formatted, "Status: " .. session_status)
	end

	-- Extract account info
	local account = text:match("Account%s+([^%\n]+)")
	if account then
		table.insert(formatted, "Account: " .. account:gsub("%s+", " "))
	end

	-- Extract region
	local region = text:match("Region%s+([^%\n]+)")
	if region then
		table.insert(formatted, "Region: " .. region:gsub("%s+", " "))
	end

	-- Extract web interface
	local web_interface = text:match("Web%s+Interface%s+(%S+)")
	if web_interface then
		table.insert(formatted, "Web Interface: " .. web_interface)
	end

	-- Extract HTTP requests
	local http_requests = {}
	for http_method, path, status in text:gmatch("([A-Z]+)%s*(%S+)%s*(%d+%s[^%\n]+)") do
		table.insert(http_requests, http_method .. " " .. path .. " → " .. status:gsub("%s+", " "))
	end

	if #http_requests > 0 then
		table.insert(formatted, "")
		table.insert(formatted, "📊 HTTP REQUESTS:")
		for _, req in ipairs(http_requests) do
			table.insert(formatted, "- " .. req)
		end
	end

	-- Return formatted text or original if nothing was extracted
	if #formatted > 0 then
		return table.concat(formatted, "\n")
	else
		return text
	end
end

-- Create a floating window
function M.create_floating_window(buf, config)
	local width = math.floor(vim.o.columns * config.floating_window.width)
	local height = math.floor(vim.o.lines * config.floating_window.height)

	local win_opts = {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = config.floating_window.style,
		border = config.floating_window.border,
	}

	return vim.api.nvim_open_win(buf, true, win_opts)
end

-- Get color for a service name
function M.get_service_color(name, config)
	if not config.log_colors.enabled then
		return nil
	end

	-- Hash the name to get a consistent color
	local hash = 0
	for i = 1, #name do
		hash = hash + string.byte(name, i)
	end

	local colors = config.log_colors.service_colors
	local color_idx = (hash % #colors) + 1

	return colors[color_idx]
end

-- Add syntax highlighting for timestamps, service names, and URLs
function M.setup_log_highlighting(buf, jobs, config)
	-- Clear any existing highlighting
	vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)

	-- Add highlight groups if they don't exist
	vim.cmd("highlight JobControlTimestamp guifg=" .. config.log_colors.timestamp_color)
	vim.cmd("highlight JobControlURL guifg=#4499ff gui=underline")

	-- Add service name highlighting
	for name, _ in pairs(jobs) do
		local color = M.get_service_color(name, config)
		if color then
			vim.cmd("highlight JobControl_" .. name .. " guifg=" .. color)
			-- Match [service-name] pattern
			vim.fn.matchadd("JobControl_" .. name, "\\[" .. name .. "\\]")
		end
	end

	-- Add timestamp highlighting for [HH:MM:SS] pattern
	vim.fn.matchadd("JobControlTimestamp", "\\[\\d\\d:\\d\\d:\\d\\d\\]")

	-- Add URL highlighting
	vim.fn.matchadd("JobControlURL", "https\\?://\\S\\+")
end

-- Process output from a PTY job
function M.process_pty_output(lines, job_info, config)
	local result = {}
	local extracted_urls = {}
	local combined_text = table.concat(lines, "\n")

	-- Check if this is ngrok and needs special formatting
	if job_info.cmd[1] and job_info.cmd[1]:match("ngrok") then
		-- First clean ANSI codes
		local cleaned_text = M.strip_ansi_escapes(combined_text)

		-- Then apply ngrok-specific formatting
		local formatted_text = M.format_ngrok_output(cleaned_text)

		-- Split back into lines
		for line in formatted_text:gmatch("([^\n]*)\n?") do
			table.insert(result, line)
		end

		-- Extract URLs as we normally would
		if config.pty.extract_urls then
			local urls = M.extract_urls(cleaned_text)
			for _, url in ipairs(urls) do
				if not vim.tbl_contains(extracted_urls, url) then
					table.insert(extracted_urls, url)
				end
			end
		end
	else
		-- Normal processing for non-ngrok commands
		for _, line in ipairs(lines) do
			if line and line ~= "" then
				-- Always strip ANSI sequences from PTY output
				local cleaned_line = M.strip_ansi_escapes(line)

				-- Extract URLs for special display
				if config.pty.extract_urls then
					local urls = M.extract_urls(cleaned_line)
					for _, url in ipairs(urls) do
						if not vim.tbl_contains(extracted_urls, url) then
							table.insert(extracted_urls, url)
						end
					end
				end

				-- Only add non-empty lines after stripping ANSI codes
				if cleaned_line ~= "" then
					table.insert(result, cleaned_line)
				end
			else
				table.insert(result, line) -- Keep empty lines as they were
			end
		end
	end

	-- Add extracted URLs to a special section
	if #extracted_urls > 0 and not job_info.extracted_urls_added then
		job_info.extracted_urls_added = true

		table.insert(result, "")
		table.insert(result, "=== Extracted URLs ===")
		for _, url in ipairs(extracted_urls) do
			table.insert(result, "• " .. url)
		end
		table.insert(result, "====================")
	end

	return result
end

-- Check if a command needs special handling
function M.get_special_handler(cmd_name, config)
	if not cmd_name then
		return nil
	end

	-- Extract the executable name (without path and arguments)
	local exec_name = cmd_name:match("([^/\\]+)$") or cmd_name
	exec_name = exec_name:match("^([^%s]+)") or exec_name

	-- Check if we have a special handler for this command
	for pattern, handler in pairs(config.special_handlers) do
		if exec_name:match(pattern) then
			return handler
		end
	end

	return nil
end

-- Parse timestamp from a log line
function M.parse_timestamp(line)
	-- Look for a timestamp at the beginning of the line [HH:MM:SS]
	local timestamp = line:match("^%[(%d%d:%d%d:%d%d)%]")

	-- If found, return the timestamp and the content after it
	if timestamp then
		local content = line:gsub("^%[%d%d:%d%d:%d%d%]%s*", "")
		return timestamp, content
	end

	return nil, line
end

return M
