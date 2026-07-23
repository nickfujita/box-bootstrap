return {
  -- Spellguard also contains shell scripts and PostgreSQL migrations.
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "bash", "css", "html", "sql" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        bashls = {},
        cssls = {},
        html = {},
      },
    },
  },
  {
    "mason-org/mason.nvim",
    opts = {
      ensure_installed = { "shellcheck" },
    },
  },
}
