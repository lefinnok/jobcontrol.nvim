-- jobcontrol/config.lua
-- Configuration module for JobControl.nvim

local M = {}

-- Default configuration
M.defaults = {
	floating_window = {
		width = 0.8,
		height = 0.8,
		border = "rounded",
		style = "minimal",
	},
	jobs = {},
	state_file = vim.fn.stdpath("data") .. "/jobcontrol_state.json",
	log_colors = {
		enabled = true,
		service_colors = {
			-- Color cycle for different services
			"#7AABD4", -- Light blue
			"#D47A9D", -- Pink
			"#7AD495", -- Light green
			"#D4C57A", -- Light yellow
			"#9D7AD4", -- Purple
			"#D4AA7A", -- Light orange
		},
		timestamp_color = "#8899AA", -- Grayish blue for timestamps
	},
	max_log_history = 1000, -- Maximum lines of log history to show in combined view
	timestamps = {
		enabled = true,
		format = "%H:%M:%S", -- Time format (hours:minutes:seconds)
		log_creation_time = true, -- Add timestamps to individual job logs too
	},
	special_handlers = {
		-- Programs that need special handling
		-- Format: name_pattern = { pty = bool, log_file = string, args = { extra_args } }
		ngrok = { pty = true, clean_ansi = true },
		htop = { pty = true, clean_ansi = true },
		top = { pty = true, clean_ansi = true },
		vim = { pty = true, clean_ansi = true },
		nano = { pty = true, clean_ansi = true },
	},
	pty = {
		clean_ansi = true, -- Strip ANSI escape sequences in PTY mode by default
		extract_urls = true, -- Extract and highlight URLs from PTY output
	},
	auto_restore = false, -- Whether to automatically restore jobs from previous session
}

-- Default project template
M.default_project_template = [[
# jobcontrol.yaml - Project jobs configuration
version: 1
project_name: my-project

# Define jobs for this project
jobs:
  # Basic web service example
  backend:
    cmd: node server.js  # The command to run
    cwd: ./backend       # Working directory (relative to this file)
    auto_restart: true   # Restart on failure

  # Frontend development server
  frontend:
    cmd: npm run dev
    cwd: ./frontend

  # Database using docker
  database:
    cmd: docker-compose up postgres

  # Public URL with ngrok (using PTY mode for interactive output)
  tunnel:
    cmd: ngrok http 3000
    pty: true
    clean_ansi: true     # Clean up ANSI escape sequences

# Advanced configuration examples (commented out)
# jobs:
#   advanced-example:
#     cmd: python -m http.server 8080
#     env:
#       PORT: 8080
#       DEBUG: true
#     startup_delay: 2000  # milliseconds to wait before starting the next job
]]

return M
