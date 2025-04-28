-- jobcontrol/init.lua
-- Main module for JobControl.nvim

-- Import submodules
local config_module = require("jobcontrol.config")
local utils = require("jobcontrol.utils")

local M = {}

-- Initialize configuration
M.config = vim.deepcopy(config_module.defaults)

-- Project utilities
M.project = {}

-- Save current job state
local function save_job_state()
	local data = {}

	for name, job in pairs(M.config.jobs) do
		data[name] = {
			cmd = job.cmd,
			cwd = job.cwd,
			opts = job.opts or {},
			auto_restart = job.auto_restart or false,
		}
	end

	local file = io.open(M.config.state_file, "w")
	if file then
		file:write(utils.safe_json_encode(data))
		file:close()
	else
		vim.notify("Failed to write job state to " .. M.config.state_file, vim.log.levels.ERROR)
	end
end

-- Load job state
local function load_job_state()
	local file = io.open(M.config.state_file, "r")
	if not file then
		return {}
	end

	local content = file:read("*all")
	file:close()

	return utils.safe_json_decode(content)
end

-- Parse all log lines from a job buffer and extract timestamps
local function parse_job_logs(name, job)
	-- Skip parsing jobs in PTY mode since we can't reliably parse their timestamps
	if job.uses_pty then
		return {}
	end

	if not vim.api.nvim_buf_is_valid(job.buffer) then
		return {}
	end

	local logs = {}
	local total_lines = vim.api.nvim_buf_line_count(job.buffer)
	local header_lines = 6 -- Skip header lines

	-- Get all log lines
	for line_num = header_lines, total_lines - 1 do
		local line = vim.api.nvim_buf_get_lines(job.buffer, line_num, line_num + 1, false)[1]

		-- Skip empty lines or separator lines
		if line and line ~= "" and not line:match("^===") and not line:match("^%-%-%-") then
			-- Extract timestamp if present
			local timestamp, content = utils.parse_timestamp(line)

			if timestamp then
				-- Calculate approximate time_seconds for sorting
				-- Parse HH:MM:SS into seconds
				local h, m, s = timestamp:match("(%d%d):(%d%d):(%d%d)")
				local time_seconds = job.started_at + (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s))

				table.insert(logs, {
					name = name,
					timestamp = timestamp,
					content = content,
					time_seconds = time_seconds,
					line_num = line_num,
				})
			else
				-- No timestamp, generate one based on line number
				local approx_time = job.started_at + (line_num - header_lines) / 10
				local generated_timestamp = os.date(M.config.timestamps.format, approx_time)

				table.insert(logs, {
					name = name,
					timestamp = generated_timestamp,
					content = line,
					time_seconds = approx_time,
					line_num = line_num,
				})
			end
		end
	end

	return logs
end

-- Find project configuration file
function M.project.find_config(dir)
	dir = dir or vim.fn.getcwd()

	-- Look for these filenames in order
	local possible_names = {
		"jobcontrol.yaml",
		"jobcontrol.yml",
		".jobcontrol.yaml",
		".jobcontrol.yml",
	}

	for _, name in ipairs(possible_names) do
		local path = dir .. "/" .. name
		if vim.fn.filereadable(path) == 1 then
			return path
		end
	end

	return nil
end

-- Create or edit project configuration
function M.project.edit_config()
	local config_path = M.project.find_config()

	if not config_path then
		-- Create new config file
		config_path = vim.fn.getcwd() .. "/jobcontrol.yaml"

		-- Ensure the file doesn't exist
		if vim.fn.filereadable(config_path) == 0 then
			local file = io.open(config_path, "w")
			if file then
				file:write(config_module.default_project_template)
				file:close()

				vim.notify("Created new project configuration at " .. config_path, vim.log.levels.INFO)
			else
				vim.notify("Failed to create project configuration at " .. config_path, vim.log.levels.ERROR)
				return
			end
		end
	end

	-- Open the config file in a new buffer
	vim.cmd("edit " .. config_path)
end

-- Parse project configuration
function M.project.parse_config(config_path)
	if not config_path then
		config_path = M.project.find_config()
		if not config_path then
			vim.notify("No project configuration found", vim.log.levels.ERROR)
			return nil
		end
	end

	-- Read the file
	local file = io.open(config_path, "r")
	if not file then
		vim.notify("Failed to open project configuration at " .. config_path, vim.log.levels.ERROR)
		return nil
	end

	local content = file:read("*all")
	file:close()

	-- Parse YAML
	local status, yaml = pcall(function()
		-- Check if we have yaml.load function (from yaml.lua library)
		if vim.is_callable(vim.yaml) and vim.is_callable(vim.yaml.load) then
			return vim.yaml.load(content)
		end

		-- Try using plenary.nvim's YAML parser if available
		local has_plenary, plenary_yaml = pcall(require, "plenary.yaml")
		if has_plenary then
			return plenary_yaml.decode(content)
		end

		-- Use yq command if available
		if vim.fn.executable("yq") == 1 then
			local tmp_file = os.tmpname()
			local f = io.open(tmp_file, "w")
			f:write(content)
			f:close()

			-- Pipe the content to yq
			local cat_cmd = "cat " .. vim.fn.shellescape(tmp_file) .. " | yq"

			local output = vim.fn.system(cat_cmd)
			os.remove(tmp_file)

			if vim.v.shell_error == 0 and output:sub(1, 1) == "{" then
				return vim.json.decode(output)
			else
				vim.notify("yq command failed, output: " .. output, vim.log.levels.ERROR)
				return nil
			end
		end

		vim.notify("No YAML parser available. Please install plenary.nvim or yq", vim.log.levels.ERROR)
		return nil
	end)

	if not status or not yaml then
		vim.notify("Failed to parse project configuration: " .. (yaml or "Unknown error"), vim.log.levels.ERROR)
		return nil
	end

	-- Check version
	if not yaml.version or yaml.version ~= 1 then
		vim.notify("Unsupported project configuration version", vim.log.levels.ERROR)
		return nil
	end

	-- Check for jobs
	if not yaml.jobs or vim.tbl_isempty(yaml.jobs) then
		vim.notify("No jobs defined in project configuration", vim.log.levels.ERROR)
		return nil
	end

	-- Get project directory for relative paths
	local project_dir = vim.fn.fnamemodify(config_path, ":h")

	-- Add project directory to each job's cwd if it's relative
	for name, job in pairs(yaml.jobs) do
		if job.cwd and not job.cwd:match("^/") and not job.cwd:match("^%a:") then
			job.cwd = project_dir .. "/" .. job.cwd
		end

		-- Convert cmd from string to array if needed
		if type(job.cmd) == "string" then
			job.cmd = vim.split(job.cmd, " ", { trimempty = true })
		end
	end

	return {
		path = config_path,
		project_name = yaml.project_name or vim.fn.fnamemodify(project_dir, ":t"),
		jobs = yaml.jobs,
		dir = project_dir,
	}
end

-- Start jobs from project configuration
function M.project.start_jobs(config_path, opts)
	opts = opts or {}

	local config = M.project.parse_config(config_path)
	if not config then
		return false
	end

	-- Get a list of job names to start, or all if not specified
	local job_names = opts.jobs or vim.tbl_keys(config.jobs)

	-- Track started jobs
	local started_jobs = {}
	local failed_jobs = {}
	local pending_jobs = {}

	-- Start jobs sequentially with potential delays
	local function start_next_job()
		local name = table.remove(pending_jobs, 1)
		if not name then
			-- All jobs started
			if #failed_jobs > 0 then
				vim.notify("Failed to start jobs: " .. table.concat(failed_jobs, ", "), vim.log.levels.WARN)
			end

			if #started_jobs > 0 then
				vim.notify("Started " .. #started_jobs .. " jobs for project " .. config.project_name, vim.log.levels.INFO)
			end

			return
		end

		local job = config.jobs[name]
		if not job then
			table.insert(failed_jobs, name .. " (not found)")
			vim.defer_fn(start_next_job, 0)
			return
		end

		-- Check if job is already running
		if M.config.jobs[name] then
			table.insert(failed_jobs, name .. " (already running)")
			vim.defer_fn(start_next_job, 0)
			return
		end

		-- Prepare job options
		local job_opts = {
			cwd = job.cwd,
			auto_restart = job.auto_restart,
			pty = job.pty,
			clean_ansi = job.clean_ansi,
			env = job.env,
		}

		-- Start the job
		local job_id = M.start_job(name, job.cmd, job_opts)

		if job_id then
			table.insert(started_jobs, name)
		else
			table.insert(failed_jobs, name)
		end

		-- Start next job after delay
		local delay = job.startup_delay or 0
		vim.defer_fn(start_next_job, delay)
	end

	-- Queue jobs to start
	for _, name in ipairs(job_names) do
		table.insert(pending_jobs, name)
	end

	-- Start first job
	start_next_job()

	return true
end

-- Stop jobs from project configuration
function M.project.stop_jobs(config_path, opts)
	opts = opts or {}

	local config = M.project.parse_config(config_path)
	if not config then
		return false
	end

	-- Get a list of job names to stop, or all if not specified
	local job_names = opts.jobs or vim.tbl_keys(config.jobs)

	local stopped_count = 0

	for _, name in ipairs(job_names) do
		if M.config.jobs[name] then
			M.stop_job(name)
			stopped_count = stopped_count + 1
		end
	end

	if stopped_count > 0 then
		vim.notify("Stopped " .. stopped_count .. " jobs for project " .. config.project_name, vim.log.levels.INFO)
	else
		vim.notify("No running jobs to stop for project " .. config.project_name, vim.log.levels.INFO)
	end

	return true
end

-- Restart jobs from project configuration
function M.project.restart_jobs(config_path, opts)
	opts = opts or {}

	local config = M.project.parse_config(config_path)
	if not config then
		return false
	end

	-- Get a list of job names to restart, or all if not specified
	local job_names = opts.jobs or vim.tbl_keys(config.jobs)

	local restarted_count = 0

	for _, name in ipairs(job_names) do
		if M.config.jobs[name] then
			M.restart_job(name)
			restarted_count = restarted_count + 1
		else
			-- Job not running, start it
			local job = config.jobs[name]
			if job then
				local job_opts = {
					cwd = job.cwd,
					auto_restart = job.auto_restart,
					pty = job.pty,
					clean_ansi = job.clean_ansi,
					env = job.env,
				}

				M.start_job(name, job.cmd, job_opts)
				restarted_count = restarted_count + 1
			end
		end
	end

	if restarted_count > 0 then
		vim.notify("Restarted " .. restarted_count .. " jobs for project " .. config.project_name, vim.log.levels.INFO)
	else
		vim.notify("No jobs to restart for project " .. config.project_name, vim.log.levels.INFO)
	end

	return true
end

-- Start a job
M.start_job = function(name, cmd, opts)
	opts = opts or {}

	-- Check for duplicate job name
	if M.config.jobs[name] then
		vim.notify("Job '" .. name .. "' already exists", vim.log.levels.WARN)
		return nil
	end

	-- Create unique buffer for job output
	local buf_name = utils.generate_unique_buffer_name("job:" .. name)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, buf_name)

	-- Ensure cmd is in the correct format
	local cmd_table
	if type(cmd) == "string" then
		cmd_table = vim.split(cmd, " ", { trimempty = true })
	elseif type(cmd) == "table" then
		cmd_table = cmd
	else
		vim.notify("Invalid command type for job '" .. name .. "'", vim.log.levels.ERROR)
		vim.api.nvim_buf_delete(buf, { force = true })
		return nil
	end

	-- Ensure we have a valid command
	if not cmd_table or #cmd_table == 0 then
		vim.notify("Empty command for job '" .. name .. "'", vim.log.levels.ERROR)
		vim.api.nvim_buf_delete(buf, { force = true })
		return nil
	end

	-- Add header to buffer
	local cmd_str = table.concat(cmd_table, " ")
	local header_lines = {
		"=== Job: " .. name .. " ===",
		"Command: " .. cmd_str,
	}

	-- Add working directory info if present
	if opts.cwd then
		table.insert(header_lines, "Working Dir: " .. opts.cwd)
	end

	-- Add started time and separator
	table.insert(header_lines, "Started: " .. os.date("%Y-%m-%d %H:%M:%S"))
	table.insert(header_lines, "------------------------------------------")
	table.insert(header_lines, "")

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, header_lines)

	-- Check for special handlers
	local special_handler = utils.get_special_handler(cmd_table[1], M.config)
	local use_pty = false
	local clean_ansi = M.config.pty.clean_ansi -- Default from config

	if special_handler then
		-- Apply special handler options
		if special_handler.pty then
			use_pty = true

			-- Check if we should override the default clean_ansi setting
			if special_handler.clean_ansi ~= nil then
				clean_ansi = special_handler.clean_ansi
			end

			table.insert(header_lines, "Note: Using PTY mode for this interactive program")
			if clean_ansi then
				table.insert(header_lines, "Note: ANSI escape sequences are being cleaned from output")
			end
			table.insert(header_lines, "")
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, header_lines)
		end

		-- Add any extra arguments if specified
		if special_handler.args then
			for _, arg in ipairs(special_handler.args) do
				table.insert(cmd_table, arg)
			end
		end
	elseif opts.pty then
		-- Manual PTY mode specified
		use_pty = true
		table.insert(header_lines, "Note: Using PTY mode for this interactive program")
		if clean_ansi then
			table.insert(header_lines, "Note: ANSI escape sequences are being cleaned from output")
		end
		table.insert(header_lines, "")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, header_lines)
	end

	-- Store job information early for use in callbacks
	local job_info = {
		name = name,
		cmd = cmd_table,
		cwd = opts.cwd,
		status = "starting",
		buffer = buf,
		buffer_name = buf_name,
		started_at = os.time(),
		opts = opts,
		auto_restart = opts.auto_restart or false,
		uses_pty = use_pty,
		clean_ansi = clean_ansi,
		extracted_urls = {},
	}

	-- Set up job options
	local job_opts = {
		on_stdout = function(_, data, _)
			if data and #data > 1 or (data[1] and data[1] ~= "") then
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(buf) then
						local line_count = vim.api.nvim_buf_line_count(buf)

						-- Process output differently for PTY mode
						local processed_data = data
						if use_pty and clean_ansi then
							processed_data = utils.process_pty_output(data, job_info, M.config)
						end

						-- Add timestamps to each line if enabled
						if M.config.timestamps.enabled and M.config.timestamps.log_creation_time then
							local timestamped_data = {}
							for _, line in ipairs(processed_data) do
								if line and line ~= "" then
									table.insert(timestamped_data, utils.format_log_line(line, M.config))
								else
									table.insert(timestamped_data, line)
								end
							end
							vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, timestamped_data)
						else
							vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, processed_data)
						end
					end
				end)
			end
		end,
		on_stderr = function(_, data, _)
			if data and #data > 1 or (data[1] and data[1] ~= "") then
				vim.schedule(function()
					if vim.api.nvim_buf_is_valid(buf) then
						local line_count = vim.api.nvim_buf_line_count(buf)

						-- Process output differently for PTY mode
						local processed_data = data
						if use_pty and clean_ansi then
							processed_data = utils.process_pty_output(data, job_info, M.config)
						end

						-- Add timestamps to each line if enabled
						if M.config.timestamps.enabled and M.config.timestamps.log_creation_time then
							local timestamped_data = {}
							for _, line in ipairs(processed_data) do
								if line and line ~= "" then
									table.insert(timestamped_data, utils.format_log_line(line, M.config))
								else
									table.insert(timestamped_data, line)
								end
							end
							vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, timestamped_data)
						else
							vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, processed_data)
						end
					end
				end)
			end
		end,
		on_exit = function(_, exit_code, _)
			vim.schedule(function()
				if not vim.api.nvim_buf_is_valid(buf) then
					return
				end

				local line_count = vim.api.nvim_buf_line_count(buf)
				local exit_message = utils.format_log_line("=== Job ended with exit code: " .. exit_code .. " ===", M.config)

				vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, {
					"",
					exit_message,
					"Time: " .. os.date("%Y-%m-%d %H:%M:%S"),
				})

				if M.config.jobs[name] then
					M.config.jobs[name].status = "stopped"
					M.config.jobs[name].exit_code = exit_code

					-- Auto-restart if configured
					if exit_code ~= 0 and M.config.jobs[name].auto_restart then
						vim.defer_fn(function()
							if M.config.jobs[name] then -- Check if job still exists
								M.restart_job(name)
							end
						end, 2000)
					end
				end
			end)
		end,
		stdout_buffered = false,
		stderr_buffered = false,
		pty = use_pty, -- Enable PTY mode for interactive programs
	}

	-- Add cwd if specified
	if opts.cwd then
		job_opts.cwd = utils.expand_path(opts.cwd)
	end

	-- Start the job
	local job_id = vim.fn.jobstart(cmd_table, job_opts)

	if job_id <= 0 then
		vim.notify("Failed to start job '" .. name .. "'", vim.log.levels.ERROR)
		vim.api.nvim_buf_delete(buf, { force = true })
		return nil
	end

	-- Special message for PTY mode
	if use_pty then
		if clean_ansi then
			vim.notify("Started " .. name .. " in PTY mode with ANSI escape cleaning", vim.log.levels.INFO)
		else
			vim.notify("Started " .. name .. " in PTY mode", vim.log.levels.INFO)
		end
	end

	-- Complete job info and store it
	job_info.job_id = job_id
	job_info.status = "running"
	M.config.jobs[name] = job_info

	-- Set up highlighting for the individual job buffer
	if M.config.timestamps.enabled and M.config.timestamps.log_creation_time then
		vim.api.nvim_buf_set_option(buf, "filetype", "log")
		utils.setup_log_highlighting(buf, M.config.jobs, M.config)
	end

	-- Save state for persistence
	save_job_state()

	vim.notify("Started job '" .. name .. "'", vim.log.levels.INFO)
	return job_id
end

-- Stop a job
M.stop_job = function(name)
	local job = M.config.jobs[name]
	if not job then
		vim.notify("No job named '" .. name .. "'", vim.log.levels.WARN)
		return false
	end

	if job.status == "running" then
		vim.fn.jobstop(job.job_id)
		job.status = "stopping"
		vim.notify("Stopping job '" .. name .. "'", vim.log.levels.INFO)
		return true
	else
		vim.notify("Job '" .. name .. "' is not running", vim.log.levels.WARN)
		return false
	end
end

-- Delete a job completely
M.delete_job = function(name)
	local job = M.config.jobs[name]
	if not job then
		vim.notify("No job named '" .. name .. "'", vim.log.levels.WARN)
		return false
	end

	-- Stop job if running
	if job.status == "running" then
		vim.fn.jobstop(job.job_id)
	end

	-- Delete buffer if valid
	if job.buffer and vim.api.nvim_buf_is_valid(job.buffer) then
		vim.api.nvim_buf_delete(job.buffer, { force = true })
	end

	-- Remove from jobs list
	M.config.jobs[name] = nil
	save_job_state()

	vim.notify("Deleted job '" .. name .. "'", vim.log.levels.INFO)
	return true
end

-- Restart a job
M.restart_job = function(name)
	local job = M.config.jobs[name]
	if not job then
		vim.notify("No job named '" .. name .. "'", vim.log.levels.WARN)
		return false
	end

	local cmd = job.cmd
	local opts = job.opts or {}

	-- Preserve working directory
	if job.cwd then
		opts.cwd = job.cwd
	end

	-- Store auto_restart setting
	opts.auto_restart = job.auto_restart
	opts.pty = job.uses_pty

	-- Delete existing job
	M.delete_job(name)

	-- Start a new job with the same settings
	vim.defer_fn(function()
		M.start_job(name, cmd, opts)
	end, 500)

	return true
end

-- List all jobs
M.list_jobs = function()
	local jobs = {}
	for name, job in pairs(M.config.jobs) do
		table.insert(jobs, {
			name = name,
			status = job.status,
			started_at = job.started_at,
			job_id = job.job_id,
			exit_code = job.exit_code,
			auto_restart = job.auto_restart,
			cwd = job.cwd,
			uses_pty = job.uses_pty,
			clean_ansi = job.clean_ansi,
		})
	end
	return jobs
end

-- Toggle auto-restart for a job
M.toggle_auto_restart = function(name)
	local job = M.config.jobs[name]
	if not job then
		vim.notify("No job named '" .. name .. "'", vim.log.levels.WARN)
		return
	end

	job.auto_restart = not job.auto_restart
	save_job_state()

	vim.notify(
		"Auto-restart for '" .. name .. "' is now " .. (job.auto_restart and "enabled" or "disabled"),
		vim.log.levels.INFO
	)
end

-- Toggle ANSI cleaning for a PTY job
M.toggle_ansi_cleaning = function(name)
	local job = M.config.jobs[name]
	if not job then
		vim.notify("No job named '" .. name .. "'", vim.log.levels.WARN)
		return
	end

	if not job.uses_pty then
		vim.notify("Job '" .. name .. "' is not in PTY mode", vim.log.levels.WARN)
		return
	end

	job.clean_ansi = not job.clean_ansi

	vim.notify(
		"ANSI escape cleaning for '" .. name .. "' is now " .. (job.clean_ansi and "enabled" or "disabled"),
		vim.log.levels.INFO
	)

	-- Note: This change requires restarting the job to take effect
	vim.notify("Restart the job for changes to take effect", vim.log.levels.INFO)
end

-- Job manager UI
M.show_job_manager = function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, utils.generate_unique_buffer_name("JobControl:Manager"))

	local win = utils.create_floating_window(buf, M.config)

	-- Update job list
	local function update_job_list()
		local jobs = M.list_jobs()
		local lines = {
			"=== Job Control Manager ===",
			"ID | Name | Status | Working Dir | PID | Exit Code | PTY | ANSI Clean | Auto-restart",
			"---------------------------------------------------------------------------",
		}

		for i, job in ipairs(jobs) do
			local cwd = job.cwd or "default"
			local exit_code = job.exit_code or "-"
			local auto_restart = job.auto_restart and "Yes" or "No"
			local pty_mode = job.uses_pty and "Yes" or "No"
			local ansi_clean = job.uses_pty and (job.clean_ansi and "Yes" or "No") or "-"

			table.insert(
				lines,
				string.format(
					"%d | %s | %s | %s | %d | %s | %s | %s | %s",
					i,
					job.name,
					job.status,
					cwd,
					job.job_id,
					exit_code,
					pty_mode,
					ansi_clean,
					auto_restart
				)
			)
		end

		if #jobs == 0 then
			table.insert(lines, "No jobs running. Use :JobStart to start a new job.")
		else
			table.insert(lines, "")
			table.insert(lines, "Commands:")
			table.insert(lines, "  r: Restart job under cursor")
			table.insert(lines, "  s: Stop job under cursor")
			table.insert(lines, "  d: Delete job under cursor")
			table.insert(lines, "  l: View logs for job under cursor")
			table.insert(lines, "  a: Toggle auto-restart for job under cursor")
			table.insert(lines, "  c: Toggle ANSI cleaning for PTY job under cursor")
			table.insert(lines, "  q: Close this window")
		end

		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
	end

	update_job_list()

	-- Set up keymaps
	local function get_job_at_cursor()
		local line = vim.api.nvim_win_get_cursor(win)[1]
		if line <= 3 or line > 3 + #M.list_jobs() then
			return nil
		end

		local job_idx = line - 3
		local jobs = M.list_jobs()
		if jobs[job_idx] then
			return jobs[job_idx].name
		end
		return nil
	end

	-- Restart job
	vim.api.nvim_buf_set_keymap(buf, "n", "r", "", {
		noremap = true,
		callback = function()
			local job_name = get_job_at_cursor()
			if job_name then
				M.restart_job(job_name)
				update_job_list()
			end
		end,
	})

	-- Stop job
	vim.api.nvim_buf_set_keymap(buf, "n", "s", "", {
		noremap = true,
		callback = function()
			local job_name = get_job_at_cursor()
			if job_name then
				M.stop_job(job_name)
				update_job_list()
			end
		end,
	})

	-- Delete job
	vim.api.nvim_buf_set_keymap(buf, "n", "d", "", {
		noremap = true,
		callback = function()
			local job_name = get_job_at_cursor()
			if job_name then
				M.delete_job(job_name)
				update_job_list()
			end
		end,
	})

	-- Toggle auto-restart
	vim.api.nvim_buf_set_keymap(buf, "n", "a", "", {
		noremap = true,
		callback = function()
			local job_name = get_job_at_cursor()
			if job_name then
				M.toggle_auto_restart(job_name)
				update_job_list()
			end
		end,
	})

	-- Toggle ANSI cleaning
	vim.api.nvim_buf_set_keymap(buf, "n", "c", "", {
		noremap = true,
		callback = function()
			local job_name = get_job_at_cursor()
			if job_name then
				M.toggle_ansi_cleaning(job_name)
				update_job_list()
			end
		end,
	})

	-- View logs
	vim.api.nvim_buf_set_keymap(buf, "n", "l", "", {
		noremap = true,
		callback = function()
			local job_name = get_job_at_cursor()
			if job_name then
				vim.api.nvim_win_close(win, true)
				M.show_log_viewer(job_name)
			end
		end,
	})

	-- Close window
	vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
		noremap = true,
		callback = function()
			vim.api.nvim_win_close(win, true)
		end,
	})

	-- Auto-refresh
	local timer = vim.loop.new_timer()
	timer:start(
		0,
		2000,
		vim.schedule_wrap(function()
			if vim.api.nvim_win_is_valid(win) then
				local cursor_pos = vim.api.nvim_win_get_cursor(win)
				update_job_list()
				if cursor_pos[1] <= vim.api.nvim_buf_line_count(buf) then
					vim.api.nvim_win_set_cursor(win, cursor_pos)
				end
			else
				timer:stop()
			end
		end)
	)

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		callback = function()
			timer:stop()
		end,
		once = true,
	})
end

-- View logs for a specific job
M.show_log_viewer = function(name)
	local job = M.config.jobs[name]
	if not job then
		vim.notify("No job named '" .. name .. "'", vim.log.levels.WARN)
		return
	end

	local win = utils.create_floating_window(job.buffer, M.config)

	-- Close keybinding
	vim.api.nvim_buf_set_keymap(job.buffer, "n", "q", "", {
		noremap = true,
		callback = function()
			vim.api.nvim_win_close(win, true)
		end,
	})

	-- Toggle ANSI cleaning (only for PTY jobs)
	if job.uses_pty then
		vim.api.nvim_buf_set_keymap(job.buffer, "n", "c", "", {
			noremap = true,
			callback = function()
				M.toggle_ansi_cleaning(name)

				-- Update notice in the buffer
				local line_count = vim.api.nvim_buf_line_count(job.buffer)
				vim.api.nvim_buf_set_option(job.buffer, "modifiable", true)
				vim.api.nvim_buf_set_lines(job.buffer, line_count, line_count, false, {
					"",
					utils.format_log_line(
						"ANSI escape cleaning " .. (job.clean_ansi and "enabled" or "disabled") .. " (restart job to apply)",
						M.config
					),
				})
				vim.api.nvim_buf_set_option(job.buffer, "modifiable", false)

				-- Scroll to the new notice
				vim.api.nvim_win_set_cursor(win, { line_count + 2, 0 })
			end,
		})
	end

	-- Auto-scroll to bottom for live updates
	vim.api.nvim_win_set_option(win, "scrolloff", 0)
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(job.buffer), 0 })

	-- Keep scroll at bottom for new output
	local auto_scroll_group = vim.api.nvim_create_augroup("JobControlAutoScroll" .. name, { clear = true })
	vim.api.nvim_create_autocmd("TextChanged", {
		buffer = job.buffer,
		group = auto_scroll_group,
		callback = function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(job.buffer), 0 })
			end
		end,
	})

	-- Clean up auto-scroll when window closes
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		callback = function()
			vim.api.nvim_del_augroup_by_id(auto_scroll_group)
		end,
		once = true,
	})

	-- Add window title with job info
	local title = "Job Logs: " .. name
	if job.cwd then
		title = title .. " (" .. job.cwd .. ")"
	end
	if job.uses_pty then
		title = title .. " [PTY mode" .. (job.clean_ansi and ", ANSI cleaned" or "") .. "]"
	end
	vim.api.nvim_win_set_option(win, "winbar", title)

	-- Set up URL highlighting if we're in PTY mode
	if job.uses_pty then
		utils.setup_log_highlighting(job.buffer, M.config.jobs, M.config)
	end
end

-- View all logs in a combined view with Docker-style formatting and timestamps
M.show_all_logs = function()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, utils.generate_unique_buffer_name("JobControl:AllLogs"))

	local win = utils.create_floating_window(buf, M.config)

	-- Track auto-scroll state
	local auto_scroll_enabled = true

	-- Initialize combined logs content
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
		"=== Combined Logs (Docker Style with Timestamps) ===",
		"Format: [time] [job-name] log content",
		"Use 'r' to refresh logs, 'c' to clear logs, 'q' to quit, 's' to toggle auto-scroll",
		"Auto-scroll: ENABLED - press 's' to disable",
		"",
	})

	-- Setup syntax highlighting for timestamps and service names
	vim.api.nvim_buf_set_option(buf, "filetype", "log")
	utils.setup_log_highlighting(buf, M.config.jobs, M.config)

	-- Get all logs and populate buffer
	local function update_all_logs()
		-- Get all logs from all jobs with timestamps
		local all_logs = {}
		local pty_jobs = {}

		for name, job in pairs(M.config.jobs) do
			if job.uses_pty then
				table.insert(pty_jobs, name)
			else
				-- Parse the full logs from each job buffer
				local job_logs = parse_job_logs(name, job)

				-- Add all logs to the combined list
				for _, log in ipairs(job_logs) do
					table.insert(all_logs, log)
				end
			end
		end

		-- Sort logs by timestamp
		table.sort(all_logs, function(a, b)
			return a.time_seconds < b.time_seconds
		end)

		-- Format and add logs to buffer
		local log_lines = {}

		-- Add notice about PTY jobs if there are any
		if #pty_jobs > 0 then
			table.insert(log_lines, "Note: The following jobs use PTY mode and their logs must be viewed separately:")
			for _, name in ipairs(pty_jobs) do
				table.insert(log_lines, "  - " .. name)
			end
			table.insert(log_lines, "")
		end

		-- Add formatted logs
		for _, entry in ipairs(all_logs) do
			table.insert(log_lines, string.format("[%s] [%s] %s", entry.timestamp, entry.name, entry.content))
		end

		-- Save cursor position before updating buffer
		local cursor_pos = nil
		if vim.api.nvim_win_is_valid(win) then
			cursor_pos = vim.api.nvim_win_get_cursor(win)
		end

		-- Set logs to buffer (after the header)
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 5, -1, false, log_lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)

		-- Update highlighting
		utils.setup_log_highlighting(buf, M.config.jobs, M.config)

		-- Scroll to the bottom if auto-scroll is enabled, otherwise maintain cursor position
		if vim.api.nvim_win_is_valid(win) then
			if auto_scroll_enabled then
				vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
			elseif cursor_pos and cursor_pos[1] <= vim.api.nvim_buf_line_count(buf) then
				vim.api.nvim_win_set_cursor(win, cursor_pos)
			end
		end
	end

	-- Add clear logs function
	local function clear_logs()
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 5, -1, false, {})
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
	end

	-- Toggle auto-scroll function
	local function toggle_auto_scroll()
		auto_scroll_enabled = not auto_scroll_enabled

		-- Update the header to show current state
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, 3, 4, false, {
			"Auto-scroll: "
				.. (auto_scroll_enabled and "ENABLED" or "DISABLED")
				.. " - press 's' to "
				.. (auto_scroll_enabled and "disable" or "enable"),
		})
		vim.api.nvim_buf_set_option(buf, "modifiable", false)

		-- Update winbar text
		vim.api.nvim_win_set_option(
			win,
			"winbar",
			"Combined Logs (r:refresh, c:clear, q:quit, s:toggle auto-scroll " .. (auto_scroll_enabled and "✓" or "✗") .. ")"
		)
	end

	-- Initial log update
	update_all_logs()

	-- Close window
	vim.api.nvim_buf_set_keymap(buf, "n", "q", "", {
		noremap = true,
		callback = function()
			vim.api.nvim_win_close(win, true)
		end,
	})

	-- Manual refresh logs
	vim.api.nvim_buf_set_keymap(buf, "n", "r", "", {
		noremap = true,
		callback = function()
			update_all_logs()
		end,
	})

	-- Clear logs
	vim.api.nvim_buf_set_keymap(buf, "n", "c", "", {
		noremap = true,
		callback = function()
			clear_logs()
		end,
	})

	-- Toggle auto-scroll
	vim.api.nvim_buf_set_keymap(buf, "n", "s", "", {
		noremap = true,
		callback = function()
			toggle_auto_scroll()
		end,
	})

	-- Auto-refresh
	local timer = vim.loop.new_timer()
	timer:start(
		0,
		1000,
		vim.schedule_wrap(function()
			if vim.api.nvim_win_is_valid(win) then
				update_all_logs()
			else
				timer:stop()
			end
		end)
	)

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		callback = function()
			timer:stop()
		end,
		once = true,
	})

	vim.api.nvim_win_set_option(win, "winbar", "Combined Logs (r:refresh, c:clear, q:quit, s:toggle auto-scroll ✓)")
end

-- Command handler functions
M.cmd_job_start = function(cmd_opts)
	local args = vim.split(cmd_opts.args, " ", { trimempty = true })
	if #args < 2 then
		vim.notify("Usage: JobStart <name> <command> [args...]", vim.log.levels.ERROR)
		return
	end

	local name = args[1]
	table.remove(args, 1)

	-- Parse flags for job options
	local cwd = nil
	local cmd = {}
	local use_pty = nil
	local clean_ansi = M.config.pty.clean_ansi -- Default from config
	local i = 1

	while i <= #args do
		local arg = args[i]

		if arg == "--pty" then
			use_pty = true
		elseif arg == "--no-ansi-clean" then
			clean_ansi = false
		elseif arg == "--ansi-clean" then
			clean_ansi = true
		elseif arg:match("^%-d=") then
			cwd = arg:match("^%-d=(.+)$")
		else
			-- Regular arguments for the command
			table.insert(cmd, arg)
		end

		i = i + 1
	end

	-- If no command arguments left, check for cd command in the combined arguments
	if #cmd == 0 then
		local full_cmd = table.concat(args, " ")
		local detected_cwd, remaining_cmd = utils.parse_cd_command(full_cmd)

		if detected_cwd then
			cwd = detected_cwd
			-- Split remaining command back into args
			cmd = vim.split(remaining_cmd, " ", { trimempty = true })
		else
			-- No cd command found, use args as is (excluding the flags we processed)
			for i, arg in ipairs(args) do
				if not arg:match("^%-%-") and not arg:match("^%-d=") then
					table.insert(cmd, arg)
				end
			end
		end
	end

	-- Set up job options
	local opts_table = {
		cwd = cwd,
		auto_restart = cmd_opts.bang, -- Use ! for auto-restart
		pty = use_pty,
		clean_ansi = clean_ansi,
	}

	M.start_job(name, cmd, opts_table)
end

M.cmd_job_stop = function(cmd_opts)
	M.stop_job(cmd_opts.args)
end

M.cmd_job_delete = function(cmd_opts)
	M.delete_job(cmd_opts.args)
end

M.cmd_job_restart = function(cmd_opts)
	M.restart_job(cmd_opts.args)
end

M.cmd_toggle_auto_restart = function(cmd_opts)
	M.toggle_auto_restart(cmd_opts.args)
end

M.cmd_toggle_ansi_cleaning = function(cmd_opts)
	M.toggle_ansi_cleaning(cmd_opts.args)
end

M.cmd_show_logs = function(cmd_opts)
	if cmd_opts.args == "all" then
		M.show_all_logs()
	else
		M.show_log_viewer(cmd_opts.args)
	end
end

M.cmd_project = function(cmd_opts)
	local subcmd = cmd_opts.args
	local args = {}

	-- Check for specific jobs in the arguments
	if subcmd:find(" ") then
		subcmd, args_str = subcmd:match("^(%S+)%s+(.+)$")
		if args_str then
			args = vim.split(args_str, " ", { trimempty = true })
		end
	end

	if subcmd == "edit" then
		M.project.edit_config()
	elseif subcmd == "start" then
		M.project.start_jobs(nil, { jobs = #args > 0 and args or nil })
	elseif subcmd == "stop" then
		M.project.stop_jobs(nil, { jobs = #args > 0 and args or nil })
	elseif subcmd == "restart" then
		M.project.restart_jobs(nil, { jobs = #args > 0 and args or nil })
	else
		vim.notify("Unknown JobProject subcommand: " .. subcmd, vim.log.levels.ERROR)
	end
end

-- Command completion functions
M.get_job_completion_list = function()
	local job_names = {}
	for name, _ in pairs(M.config.jobs) do
		table.insert(job_names, name)
	end
	return job_names
end

M.get_pty_job_completion_list = function()
	local job_names = {}
	for name, job in pairs(M.config.jobs) do
		if job.uses_pty then
			table.insert(job_names, name)
		end
	end
	return job_names
end

M.get_logs_completion_list = function()
	local completions = { "all" }
	for name, _ in pairs(M.config.jobs) do
		table.insert(completions, name)
	end
	return completions
end

M.get_project_completion_list = function(ArgLead, CmdLine, CursorPos)
	local subcmds = { "edit", "start", "stop", "restart" }
	local completed = {}

	-- Get command being completed
	local cmd_parts = vim.split(CmdLine:sub(1, CursorPos), "%s+")
	local current_cmd = cmd_parts[2] or ""

	-- If we're completing the subcommand
	if #cmd_parts <= 2 then
		for _, subcmd in ipairs(subcmds) do
			if subcmd:find(current_cmd, 1, true) == 1 then
				table.insert(completed, subcmd)
			end
		end
		return completed
	end

	-- If we're completing job names for start/stop/restart
	if current_cmd == "start" or current_cmd == "stop" or current_cmd == "restart" then
		local config = M.project.parse_config()
		if config then
			local job_names = {}
			for name, _ in pairs(config.jobs) do
				if name:find(ArgLead, 1, true) == 1 then
					table.insert(job_names, name)
				end
			end
			return job_names
		end
	end

	return {}
end

-- Setup function
M.setup = function(opts)
	opts = opts or {}

	-- Merge configs
	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Clean up stale buffers on startup
	local function cleanup_stale_buffers()
		local buffers = vim.api.nvim_list_bufs()
		for _, buf in ipairs(buffers) do
			local name = vim.api.nvim_buf_get_name(buf)
			if name:match("^job:") or name:match("^JobControl:") then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end
	end

	cleanup_stale_buffers()

	-- Load previous job state if auto_restore is enabled
	if opts.auto_restore then
		local saved_state = load_job_state()

		for name, job_data in pairs(saved_state) do
			M.start_job(name, job_data.cmd, {
				cwd = job_data.cwd,
				opts = job_data.opts,
				auto_restart = job_data.auto_restart,
			})
		end
	end

	-- Clean up on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			-- Stop all jobs
			for name, _ in pairs(M.config.jobs) do
				M.stop_job(name)
			end

			-- Save state
			save_job_state()
		end,
	})

	return M
end

return M
