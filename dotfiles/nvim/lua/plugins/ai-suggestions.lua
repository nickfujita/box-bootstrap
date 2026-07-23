local function set_ai_suggestions(enabled)
  vim.g.ai_suggestions_enabled = enabled
  vim.lsp.inline_completion.enable(enabled)

  local ok, nes = pcall(require, "sidekick.nes")
  if ok then
    nes.enable(enabled)
  end

  vim.notify("AI coding suggestions " .. (enabled and "enabled" or "disabled"))
end

return {
  {
    "folke/sidekick.nvim",
    opts = {
      -- Keep Copilot Next Edit Suggestions off every time Neovim starts.
      nes = { enabled = false },
    },
    keys = {
      {
        "<leader>uA",
        function()
          set_ai_suggestions(not vim.g.ai_suggestions_enabled)
        end,
        desc = "Toggle AI Coding Suggestions",
      },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        copilot = {
          settings = {
            telemetry = { telemetryLevel = "off" },
          },
        },
      },
      setup = {
        -- Override LazyVim's native default, which enables inline completion
        -- immediately. The server still attaches so authentication stays warm,
        -- but it sends no completion requests until our toggle enables it.
        copilot = function()
          LazyVim.cmp.actions.ai_accept = function()
            if vim.g.ai_suggestions_enabled then
              return vim.lsp.inline_completion.get()
            end
          end
        end,
      },
    },
  },
}
