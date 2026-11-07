# sidekick-rex.nvim

Run [sidekick.nvim](https://github.com/folke/sidekick.nvim)'s AI CLI agents in
their own [Rex](https://www.superlogical.com) tabs.

`sidekick.nvim` can keep CLI sessions in a terminal multiplexer (tmux or
zellij) so they survive Neovim restarts. This plugin adds Rex as a third
backend: each agent runs in its own Rex tab, and sidekick can find, show, focus
and send text to it like any other session.

## Requirements

- [Rex](https://www.superlogical.com), with the `rex` CLI on your `PATH`
- Neovim started inside Rex, so `$REX_SESSION` is set
- [sidekick.nvim](https://github.com/folke/sidekick.nvim)
- Tested on Neovim 0.12

## Installation

### lazy.nvim

```lua
{
  "folke/sidekick.nvim",
  dependencies = {"gonstoll/sidekick-rex.nvim"},
  opts = {
    cli = {
      mux = {
        enabled = true,
        -- "rex" is only a valid backend inside Rex
        backend = vim.env.REX_SESSION and "rex" or "tmux",
      },
    },
  },
  config = function(_, opts)
    -- Must come first: it lets sidekick accept "rex" as a backend
    require("sidekick-rex").setup()
    require("sidekick").setup(opts)
  end,
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/folke/sidekick.nvim",
  "https://github.com/gonstoll/sidekick-rex.nvim",
})

-- Must come first: it lets sidekick accept "rex" as a backend
require("sidekick-rex").setup()
require("sidekick").setup({
  cli = {
    mux = {
      enabled = true,
      -- "rex" is only a valid backend inside Rex
      backend = vim.env.REX_SESSION and "rex" or "tmux",
    },
  },
})
```

## Configuration

sidekick-rex has no options of its own. Two things matter:

- **Call `require("sidekick-rex").setup()` before `require("sidekick").setup()`.**
  sidekick validates `cli.mux.backend` during its setup and only knows `tmux`
  and `zellij`. `setup()` registers the Rex backend and teaches sidekick to
  accept `"rex"`.
- **Only pick `"rex"` inside Rex.** Outside Rex, `setup()` does nothing, so
  sidekick would reject `"rex"` and fail to start agents. The
  `vim.env.REX_SESSION and "rex" or "tmux"` line above keeps the same config
  working in any terminal.

## Behavior

- Each agent starts in a new Rex tab named after the tool. A second agent of
  the same tool in the same Rex session gets its working directory as a suffix,
  e.g. `claude·my-project`.
- sidekick's picker lists agents from every Rex session, labeled with the
  session name and tab position and title, e.g. `work 2:claude`.
- Showing, toggling or focusing an agent switches Rex to its tab, and to its
  session if it lives in another one.
- Agents live in Rex, not in Neovim, so they keep running after Neovim exits.
  A new Neovim finds them again.

## Caveats

- sidekick only shows and focuses sessions that live in a Neovim terminal, so
  this plugin patches a few of its internals (`Config.validate`,
  `State.attach`, `State.with`, `cli.toggle` and `cli.focus`). Each patch checks
  that what it replaces still exists and errors loudly if sidekick changed. The
  plugin tracks sidekick.nvim's `main` branch.
- `cli.mux.create` is ignored: agents always open in their own Rex tab.

## Development

Run the tests with:

```sh
tests/run.sh
```

They run headless against a fake `rex` (`tests/bin/rex`) and check the exact
commands the backend sends. sidekick.nvim is loaded from
`~/.local/share/nvim/lazy/sidekick.nvim`; set `SIDEKICK_DIR` to use another
checkout.

## License

[MIT](LICENSE)
