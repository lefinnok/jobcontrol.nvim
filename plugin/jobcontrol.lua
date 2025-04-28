-- jobcontrol.lua - Plugin loader for JobControl.nvim
-- Prevent loading twice
if vim.g.loaded_jobcontrol == 1 then
	return
end
vim.g.loaded_jobcontrol = 1

-- Create user commands
vim.api.nvim_create_user_command("JobStart", function(cmd_opts)
	require("jobcontrol").cmd_job_start(cmd_opts)
end, {
	nargs = "+",
	bang = true,
	complete = function()
		return {
			"Example: JobStart my-service npm run dev",
			"Example with cd: JobStart my-service cd backend && npm start",
			"Example with -d flag: JobStart my-service -d=backend npm start",
			"Example with PTY mode: JobStart my-service --pty ngrok http 3000",
			"Example with ANSI cleaning: JobStart my-service --pty --ansi-clean htop",
		}
	end,
})

vim.api.nvim_create_user_command("JobStop", function(cmd_opts)
	require("jobcontrol").cmd_job_stop(cmd_opts)
end, {
	nargs = 1,
	complete = function()
		return require("jobcontrol").get_job_completion_list()
	end,
})

vim.api.nvim_create_user_command("JobDelete", function(cmd_opts)
	require("jobcontrol").cmd_job_delete(cmd_opts)
end, {
	nargs = 1,
	complete = function()
		return require("jobcontrol").get_job_completion_list()
	end,
})

vim.api.nvim_create_user_command("JobRestart", function(cmd_opts)
	require("jobcontrol").cmd_job_restart(cmd_opts)
end, {
	nargs = 1,
	complete = function()
		return require("jobcontrol").get_job_completion_list()
	end,
})

vim.api.nvim_create_user_command("JobToggleAutoRestart", function(cmd_opts)
	require("jobcontrol").cmd_toggle_auto_restart(cmd_opts)
end, {
	nargs = 1,
	complete = function()
		return require("jobcontrol").get_job_completion_list()
	end,
})

vim.api.nvim_create_user_command("JobToggleAnsiCleaning", function(cmd_opts)
	require("jobcontrol").cmd_toggle_ansi_cleaning(cmd_opts)
end, {
	nargs = 1,
	complete = function()
		return require("jobcontrol").get_pty_job_completion_list()
	end,
})

vim.api.nvim_create_user_command("JobManager", function()
	require("jobcontrol").show_job_manager()
end, { nargs = 0 })

vim.api.nvim_create_user_command("JobLogs", function(cmd_opts)
	require("jobcontrol").cmd_show_logs(cmd_opts)
end, {
	nargs = 1,
	complete = function()
		return require("jobcontrol").get_logs_completion_list()
	end,
})

vim.api.nvim_create_user_command("JobProject", function(cmd_opts)
	require("jobcontrol").cmd_project(cmd_opts)
end, {
	nargs = "+",
	complete = function(ArgLead, CmdLine, CursorPos)
		return require("jobcontrol").get_project_completion_list(ArgLead, CmdLine, CursorPos)
	end,
})
