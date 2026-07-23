-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Keep common mode changes and line navigation close to the home row.
vim.keymap.set("i", "jk", "<Esc>", { desc = "Exit Insert Mode" })
vim.keymap.set({ "n", "x", "o" }, "B", "^", { desc = "Beginning of Line" })
vim.keymap.set({ "n", "x", "o" }, "E", "$", { desc = "End of Line" })

-- Match the macOS text-navigation shortcuts emitted by iTerm2.
vim.keymap.set("i", "<M-b>", "<C-o>b", { desc = "Previous Word" })
vim.keymap.set("i", "<M-f>", "<C-o>e<Right>", { desc = "After Word" })
vim.keymap.set("i", "<C-a>", "<C-o>0", { desc = "Beginning of Line" })
vim.keymap.set("i", "<C-e>", "<C-o>$", { desc = "End of Line" })
vim.keymap.set("i", "<C-Home>", "<C-o>gg<C-o>0", { desc = "Beginning of File" })
vim.keymap.set("i", "<C-End>", "<C-o>G<C-o>$<Right>", { desc = "End of File" })
