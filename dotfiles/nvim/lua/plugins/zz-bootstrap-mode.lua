-- The normal LazyVim specs install Mason tools and Tree-sitter parsers in
-- parallel. On a brand-new VM that creates a large temporary disk/RAM spike.
-- box-bootstrap sets this environment flag and installs the same pinned lists
-- sequentially in scripts/bootstrap-nvim.lua instead.
if vim.env.BOX_BOOTSTRAP_NVIM ~= "1" then
  return {}
end

return {
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = {}
    end,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    opts = function(_, opts)
      opts.ensure_installed = {}
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = {}
    end,
  },
}
