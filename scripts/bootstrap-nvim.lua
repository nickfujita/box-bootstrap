-- Complete the noninteractive portions of the captured LazyVim setup.
-- The shell installer runs this only after lazy.nvim has synchronized plugins.

local mason_packages = {
  -- Install Go tools first so their shared build cache can be reclaimed before
  -- the larger Node/Java packages. One-at-a-time installs keep peak resource
  -- usage reasonable on small VMs.
  "gopls",
  "goimports",
  "gofumpt",
  "golangci-lint",
  "bash-language-server",
  "biome",
  "copilot-language-server",
  "css-lsp",
  "docker-compose-language-service",
  "dockerfile-language-server",
  "hadolint",
  "html-lsp",
  "json-lsp",
  "kotlin-language-server",
  "ktlint",
  "lua-language-server",
  "markdown-toc",
  "markdownlint-cli2",
  "marksman",
  "pyright",
  "ruff",
  "shellcheck",
  "shfmt",
  "stylua",
  "tailwindcss-language-server",
  "taplo",
  "vtsls",
  "yaml-language-server",
}

local parsers = {
  "bash",
  "c",
  "css",
  "diff",
  "dockerfile",
  "go",
  "gomod",
  "gosum",
  "gowork",
  "html",
  "javascript",
  "json",
  "json5",
  "kotlin",
  "lua",
  "luadoc",
  "markdown",
  "markdown_inline",
  "python",
  "query",
  "regex",
  "sql",
  "swift",
  "toml",
  "tsx",
  "typescript",
  "vim",
  "vimdoc",
  "yaml",
}

local function fail(message)
  vim.api.nvim_err_writeln(message)
  vim.cmd("cquit 1")
end

local function install_parsers()
  io.stdout:write("Installing Tree-sitter parsers...\n")
  local ok, result = pcall(function()
    return require("nvim-treesitter").install(parsers, { summary = true }):wait(600000)
  end)
  if not ok or result == false then
    fail("Tree-sitter parser installation failed: " .. tostring(result))
    return
  end
  io.stdout:write("Tree-sitter parsers are installed.\n")
  vim.cmd("qa!")
end

local ok, lazy = pcall(require, "lazy")
if not ok then
  fail("lazy.nvim is not available; run Lazy sync before this script")
  return
end
lazy.load({ plugins = { "mason.nvim", "nvim-treesitter" } })

local registry = require("mason-registry")
local finished = false
local installed_go_tool = false

vim.defer_fn(function()
  if not finished then
    fail("Timed out waiting for Mason package installation")
  end
end, 20 * 60 * 1000)

local function install_next(index)
  if index > #mason_packages then
    if installed_go_tool then
      io.stdout:write("Reclaiming the temporary Go build cache...\n")
      vim.system({ "go", "clean", "-cache" }):wait()
    end
    io.stdout:write("All Mason packages are installed.\n")
    finished = true
    install_parsers()
    return
  end

  local name = mason_packages[index]
  local found, package = pcall(registry.get_package, name)
  if not found then
    fail("Unknown Mason package " .. name .. ": " .. tostring(package))
    return
  end
  if package:is_installed() then
    install_next(index + 1)
    return
  end
  if package:is_installing() then
    vim.defer_fn(function()
      install_next(index)
    end, 500)
    return
  end

  io.stdout:write("Installing Mason package " .. name .. "...\n")
  package:install({}, function(success, err)
    if not success then
      fail("Mason package failed: " .. name .. ": " .. tostring(err))
      return
    end
    if index <= 4 then
      installed_go_tool = true
    end
    vim.schedule(function()
      install_next(index + 1)
    end)
  end)
end

registry.refresh(function()
  install_next(1)
end)
