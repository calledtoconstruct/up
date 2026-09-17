-- Up Linux theme watcher
-- Watches generated theme files and reloads theme in running Neovim instances.

local uv = vim.uv or vim.loop
local M = {}

local watchers = {}
local debounce_timer = nil

local function notify(msg, level)
  vim.schedule(function()
    vim.notify(msg, level or vim.log.levels.INFO, { title = "Up Theme" })
  end)
end

local function cleanup_watchers()
  for _, watcher in ipairs(watchers) do
    pcall(function()
      watcher:stop()
    end)
    pcall(function()
      watcher:close()
    end)
  end
  watchers = {}
end

local function reload_theme()
  package.loaded["config.theme"] = nil
  local ok, err = pcall(require, "config.theme")
  if not ok then
    notify("Theme reload failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

local function schedule_reload()
  if not uv or not uv.new_timer then
    reload_theme()
    return
  end

  if not debounce_timer then
    debounce_timer = uv.new_timer()
  end

  debounce_timer:stop()
  debounce_timer:start(
    120,
    0,
    vim.schedule_wrap(function()
      reload_theme()
    end)
  )
end

local function watch_file(path)
  if not uv or not uv.new_fs_event then
    return
  end

  local dir = vim.fn.fnamemodify(path, ":h")
  local filename = vim.fn.fnamemodify(path, ":t")

  if vim.fn.isdirectory(dir) == 0 then
    return
  end

  local watcher = uv.new_fs_event()
  if not watcher then
    return
  end

  local ok, err = pcall(function()
    watcher:start(dir, {}, function(fs_err, changed_name)
      if fs_err then
        return
      end

      if not changed_name or changed_name == filename then
        schedule_reload()
      end
    end)
  end)

  if ok then
    table.insert(watchers, watcher)
  else
    pcall(function()
      watcher:close()
    end)
    notify("Failed to watch " .. path .. ": " .. tostring(err), vim.log.levels.WARN)
  end
end

function M.setup()
  if M._initialized then
    return
  end
  M._initialized = true

  local state_file = vim.fn.expand("~/.config/up-theme")
  local theme_file = vim.fn.stdpath("config") .. "/lua/config/theme.lua"

  watch_file(state_file)
  watch_file(theme_file)

  vim.api.nvim_create_user_command("UpThemeReload", function()
    reload_theme()
  end, { desc = "Reload Up theme configuration" })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if debounce_timer then
        pcall(function()
          debounce_timer:stop()
        end)
        pcall(function()
          debounce_timer:close()
        end)
      end
      cleanup_watchers()
    end,
  })
end

return M