# JobControl.nvim

A Neovim plugin for managing background processes with Docker-style log management.

(Disclaimer: Recently Packaged from Personal Library)

## Features

- Start, stop, restart, and monitor background jobs
- View job logs in floating windows with Docker-style formatting
- Auto-restart jobs on failure
- PTY mode support for interactive programs like ngrok, htop, etc.
- Project-based configuration with YAML files
- Special handling for common tools (ngrok, htop, top, etc.)
- URL detection and highlighting in logs
- ANSI escape sequence cleaning for better readability
- Timestamp support for log entries

## Installation

### Using Packer

```lua
use {
  'lefinnok/jobcontrol.nvim',
  config = function()
    require('jobcontrol').setup({
      -- your configuration options (see below)
    })
  end
}
```

### Using lazy.nvim

```lua
{
  'lefinnok/jobcontrol.nvim',
  config = function()
    require('jobcontrol').setup({
      -- your configuration options
    })
  end
}
```

## Configuration

Here's an example configuration with all defaults:

```lua
require('jobcontrol').setup({
  floating_window = {
    width = 0.8,
    height = 0.8,
    border = "rounded",
    style = "minimal",
  },
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
    -- Format: name_pattern = { pty = bool, clean_ansi = true/false, args = { extra_args } }
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
  auto_restore = false, -- Automatically restore jobs from previous session
})
```

## Usage

### User Commands

- `:JobStart name command [args...]` - Start a new job
  - Add `!` for auto-restart (`:JobStart! name command`)
  - Use `--pty` flag for interactive programs
  - Use `--ansi-clean` or `--no-ansi-clean` to control ANSI escape cleaning
  - Use `-d=directory` to set working directory

- `:JobStop name` - Stop a running job
- `:JobDelete name` - Delete a job and its buffer
- `:JobRestart name` - Restart a running job
- `:JobToggleAutoRestart name` - Toggle auto-restart for a job
- `:JobToggleAnsiCleaning name` - Toggle ANSI escape cleaning for a PTY job
- `:JobManager` - Open the job management UI
- `:JobLogs name` - View logs for a specific job
- `:JobLogs all` - View combined logs for all jobs

### Project Management

- `:JobProject edit` - Create or edit project configuration
- `:JobProject start [job1 job2...]` - Start all or specific jobs from project config
- `:JobProject stop [job1 job2...]` - Stop all or specific jobs from project config
- `:JobProject restart [job1 job2...]` - Restart all or specific jobs from project config

### Project Configuration (YAML)

Create a `jobcontrol.yaml` file in your project root:

```yaml
version: 1
project_name: my-project

# Define jobs for this project
jobs:
  # Basic web service
  backend:
    cmd: node server.js
    cwd: ./backend
    auto_restart: true

  # Frontend development
  frontend:
    cmd: npm run dev
    cwd: ./frontend

  # Database
  database:
    cmd: docker-compose up postgres

  # Public URL with ngrok
  tunnel:
    cmd: ngrok http 3000
    pty: true
    clean_ansi: true
```

## Job Manager UI

The job manager UI provides a convenient interface to:
- View all running jobs
- Start, stop, restart jobs
- View logs for individual jobs
- Toggle auto-restart and ANSI cleaning
- Monitor combined logs with Docker-style formatting

## License

MIT
