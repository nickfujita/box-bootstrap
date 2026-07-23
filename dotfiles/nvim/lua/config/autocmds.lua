-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- AI completion is installed and authenticated, but deliberately starts disabled.
-- Use <leader>uA to enable or disable both Copilot inline completion and
-- Sidekick Next Edit Suggestions for the current Neovim session.
vim.g.ai_suggestions_enabled = false
vim.schedule(function()
  vim.lsp.inline_completion.enable(false)
end)
