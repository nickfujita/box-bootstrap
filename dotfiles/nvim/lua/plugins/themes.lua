return {
  -- LazyVim ships these themes by default; disable them so VS Code is the
  -- only additional colorscheme installed by this setup.
  { "folke/tokyonight.nvim", enabled = false },
  { "catppuccin/nvim", name = "catppuccin", enabled = false },
  {
    "Mofiqul/vscode.nvim",
    opts = {
      style = "dark",
    },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "vscode",
    },
  },
}
