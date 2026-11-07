-- sidekick only shows and focuses sessions that live in a Neovim terminal, and
-- only accepts tmux or zellij as a backend name. These patches route those
-- calls to Rex sessions. They lean on sidekick internals, so each one checks
-- that what it patches still exists and fails loudly if not.
local Cli = require("sidekick.cli")
local Config = require("sidekick.config")
local State = require("sidekick.cli.state")

local M = {}

---@param mod table
---@param modname string
---@param name string
local function original(mod, modname, name)
    local fn = mod[name]
    assert(type(fn) == "function", ("sidekick-rex: `%s.%s` is gone, sidekick changed"):format(modname, name))
    return fn
end

---@param state? sidekick.cli.State
local function is_rex(state)
    return state ~= nil and state.session ~= nil and state.session.backend == "rex"
end

local function patch_validate()
    local validate = original(Config, "sidekick.config", "validate")
    Config.validate = function(key, t)
        if key == "cli.mux.backend" and type(t) == "table" then
            t = vim.list_extend({"rex"}, t)
        end
        return validate(key, t)
    end
end

-- Showing happens when sidekick attaches with `show = true`: on show(),
-- send(), focus() and when picking a session from select()
local function patch_attach()
    local attach = original(State, "sidekick.cli.state", "attach")
    State.attach = function(state, opts)
        local ret, attached = attach(state, opts)
        if is_rex(ret) and opts and opts.show and opts.focus ~= false then
            ret.session:focus()
        end
        return ret, attached
    end
end

--- Wraps a `sidekick.cli` function so that its State.with callback, which
--- returns early for anything that isn't a Neovim terminal, switches to the
--- agent's tab for Rex sessions
---@param name string
local function patch_focus(name)
    local fn = original(Cli, "sidekick.cli", name)
    local with = original(State, "sidekick.cli.state", "with")
    Cli[name] = function(opts)
        State.with = function(cb, with_opts)
            return with(function(state, attached)
                if not is_rex(state) then
                    return cb(state, attached)
                elseif type(opts) ~= "table" or opts.focus ~= false then
                    state.session:focus()
                end
            end, with_opts)
        end
        local ok, err = pcall(fn, opts)
        State.with = with
        if not ok then
            error(err, 0)
        end
    end
end

-- The location is the part of a picker row highlighted as "Special", and the
-- padding before the path follows it
---@param parts snacks.picker.Highlight[]
local function location(parts)
    for i, part in ipairs(parts) do
        if part[2] == "Special" and parts[i + 1] then
            return i
        end
    end
end

-- sidekick's picker pads every location to a fixed width, so a long Rex
-- location (session, tab position and title) pushes that row's path out of
-- line. Pad each one to the widest location in the picker instead.
local function patch_select()
    local Select = require("sidekick.cli.ui.select")
    local select = original(Select, "sidekick.cli.ui.select", "select")
    local format = original(Select, "sidekick.cli.ui.select", "format")
    local sw = vim.api.nvim_strwidth

    ---@param states sidekick.cli.State[]
    local function aligned(states)
        local width = 0
        for _, state in ipairs(states) do
            local parts = format(state)
            local i = location(parts)
            if i then
                width = math.max(width, sw(parts[i][1]))
            end
        end
        return function(state, picker)
            local parts = format(state, picker)
            local i = location(parts)
            if i then
                parts[i + 1] = {string.rep(" ", width - sw(parts[i][1]) + 2)}
            end
            return parts
        end
    end

    -- Select.select builds the rows and hands them to vim.ui.select right away,
    -- so that's where all of them can be measured
    Select.select = function(opts)
        local ui_select = vim.ui.select
        vim.ui.select = function(items, select_opts, on_choice)
            local fmt = aligned(items)
            select_opts = vim.tbl_extend("force", select_opts, {
                format_item = function(state)
                    return table.concat(vim.tbl_map(function(part) return part[1] end, fmt(state)))
                end,
                snacks = vim.tbl_extend("force", select_opts.snacks or {}, {format = fmt}),
            })
            return ui_select(items, select_opts, on_choice)
        end
        local ok, err = pcall(select, opts)
        vim.ui.select = ui_select
        if not ok then
            error(err, 0)
        end
    end
end

function M.apply()
    patch_validate()
    patch_select()
    patch_attach()
    patch_focus("toggle")
    patch_focus("focus")
end

return M
