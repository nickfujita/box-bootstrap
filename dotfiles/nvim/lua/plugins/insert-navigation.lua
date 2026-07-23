return {
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      -- Let Command+Right (sent by iTerm2 as Ctrl+E) reach our Insert-mode
      -- end-of-line mapping instead of using it to cancel completion.
      keymap = {
        ["<C-e>"] = { "fallback" },
      },
    },
  },
}
