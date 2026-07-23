-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Keep common mode changes and line navigation close to the home row.
vim.keymap.set("i", "jk", "<Esc>", { desc = "Exit Insert Mode" })
vim.keymap.set({ "n", "x", "o" }, "B", "^", { desc = "Beginning of Line" })
vim.keymap.set({ "n", "x", "o" }, "E", "$", { desc = "End of Line" })
