-- Runs against a fake `rex` (tests/bin/rex) and checks the exact commands
-- the backend sends. Run with tests/run.sh.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
local sidekick_dir = vim.env.SIDEKICK_DIR or vim.fn.expand("~/.local/share/nvim/lazy/sidekick.nvim")
vim.opt.rtp:prepend(sidekick_dir)
vim.opt.rtp:prepend(root)

local fake = vim.fn.tempname()
vim.fn.mkdir(fake, "p")
vim.env.REX_FAKE_DIR = fake
vim.env.PATH = root .. "/tests/bin:" .. vim.env.PATH

local notes = {} ---@type {msg: string, level: integer}[]
vim.notify = function(msg, level)
    notes[#notes + 1] = {msg = msg, level = level or vim.log.levels.INFO}
end

local failed, passed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
    vim.fn.delete(fake, "rf")
    vim.fn.mkdir(fake, "p")
    notes = {}
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n" .. err)
    end
end

---@param file string
---@param data table
local function fixture(file, data)
    vim.fn.writefile({vim.json.encode(data)}, fake .. "/" .. file)
end

--- Every rex call so far, each one a list of arguments
---@return string[][]
local function calls()
    local f = io.open(fake .. "/calls")
    if not f then
        return {}
    end
    local data = f:read("*a")
    f:close()
    local ret = {}
    for call in data:gmatch("([^\30]*)\30") do
        local args = {}
        for arg in call:gmatch("([^\31]*)\31") do
            args[#args + 1] = arg
        end
        ret[#ret + 1] = args
    end
    return ret
end

---@param prefix string[]
local function find(prefix)
    for _, call in ipairs(calls()) do
        if vim.deep_equal(vim.list_slice(call, 1, #prefix), prefix) then
            return call
        end
    end
end

local function eq(actual, expected, what)
    if not vim.deep_equal(actual, expected) then
        error(("%s\nexpected: %s\nactual:   %s"):format(what or "values differ", vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

--- The params of the first `rex api call <method>`
local function api_params(method)
    local call = find({"api", "call", method})
    assert(call, "no api call to " .. method .. ", calls: " .. vim.inspect(calls()))
    return vim.json.decode(call[4])
end

local function errors()
    return vim.tbl_filter(function(n)
        return n.level >= vim.log.levels.WARN
    end, notes)
end

local S, AGENT = "session:test", "block:agent"

-- Outside Rex nothing may register, so must run before Rex's env is set
vim.env.REX_SESSION = nil
require("sidekick-rex").setup()
local Session = require("sidekick.cli.session")
test("registers nothing outside Rex", function()
    eq(Session.backends.rex, nil, "rex backend")
    eq(require("sidekick-rex").did_setup, false, "did_setup")
end)

vim.env.REX_SESSION = S
require("sidekick-rex").setup()
require("sidekick").setup({
    nes = {enabled = false},
    cli = {
        mux = {enabled = true, backend = "rex"},
        tools = {sleeper = {cmd = {"sleep", "31"}, is_proc = "\\<sleep 31\\>"}},
    },
})

test("accepts rex as sidekick's mux backend", function()
    vim.wait(100)
    require("sidekick.config").validate("cli.mux.backend", {"tmux", "zellij"})
    eq(errors(), {}, "notifications")
    assert(Session.backends.rex, "rex backend not registered")
end)

---@param id? string
local function new_session(id)
    local session = Session.new({tool = "sleeper", cwd = "/tmp/project"})
    if id then
        session.rex_block_id = id
        session.id = "rex " .. id
        session.started = true
    end
    return session --[[@as sidekick.cli.muxer.Rex]]
end

test("starts in a new tab named after the tool", function()
    local session = new_session()
    eq(session.backend, "rex", "backend")
    eq(session:start(), nil, "start returns no terminal command")
    eq(find({"run"}), {
        "run", "-s", S, "-c", "/tmp/project", "--label", "sleeper", "--focus=false", "--json",
        "--", "sleep", "31",
    }, "run")
    eq(find({"window", "rename"}), {"window", "rename", "-s", S, "window:new", "sleeper"}, "rename")
    eq(session.rex_block_id, "block:new", "block id")
    eq(session.id, "rex block:new", "session id")
    eq(session.started, true, "started")
end)

test("a second agent of the same tool gets its cwd as a suffix", function()
    fixture("blocks.json", {blocks = {{block_id = AGENT, label = "sleeper", placement = "placed"}}})
    new_session():start()
    eq(find({"run"})[7], "sleeper·project", "label")
end)

--- Starts an agent with mux.create = "split" and returns the arguments the
--- split added to `rex run`, between `--json` and `--`. Config, REX_BLOCK and
--- the editor size are restored afterwards, even when `fn` fails.
---@param opts {vertical: boolean, size: number, layout?: string, block?: string|false, columns?: integer, lines?: integer, env?: table}
---@param fn? fun(session: sidekick.cli.muxer.Rex)
---@return string[]
local function split_args(opts, fn)
    local Config = require("sidekick.config")
    local saved = {
        mux = vim.deepcopy(Config.cli.mux),
        layout = Config.cli.win.layout,
        block = vim.env.REX_BLOCK,
        columns = vim.o.columns,
        lines = vim.o.lines,
    }
    vim.fn.delete(fake .. "/calls")
    local ok, ret = pcall(function()
        Config.cli.mux.create = "split"
        Config.cli.mux.split = {vertical = opts.vertical, size = opts.size}
        Config.cli.win.layout = opts.layout or "right"
        vim.env.REX_BLOCK = opts.block == nil and "block:nvim" or opts.block or nil
        vim.o.columns = opts.columns or saved.columns
        vim.o.lines = opts.lines or saved.lines
        local session = new_session()
        session.tool.env = opts.env
        local started = pcall(session.start, session)
        session.tool.env = nil
        assert(started, "start failed")
        if fn then
            fn(session)
        end
        local run = find({"run"})
        assert(run, "no rex run, calls: " .. vim.inspect(calls()))
        eq(run[9], "--json", "split args come after the common ones")
        return vim.list_slice(run, 10, (vim.fn.index(run, "--")))
    end)
    Config.cli.mux, Config.cli.win.layout, vim.env.REX_BLOCK = saved.mux, saved.layout, saved.block
    vim.o.columns, vim.o.lines = saved.columns, saved.lines
    if not ok then
        error(ret, 0)
    end
    return ret
end

test("mux.create = split opens beside Neovim's block and leaves its tab alone", function()
    split_args({vertical = true, size = 0.4, layout = "left"}, function(session)
        eq(find({"run"}), {
            "run", "-s", S, "-c", "/tmp/project", "--label", "sleeper", "--focus=false", "--json",
            "--split=left", "--ratio", "40", "-b", "block:nvim",
            "--", "sleep", "31",
        }, "run")
        eq(find({"window", "rename"}), nil, "Neovim's tab keeps its name")
        eq(session.rex_block_id, "block:new", "block id")
        eq(session.id, "rex block:new", "session id")
        eq(session.started, true, "started")
        assert(vim.wait(500, function()
            return vim.iter(notes):any(function(n)
                return n.msg:find("Started **sleeper** in a new Rex split", 1, true) ~= nil
            end)
        end), "no split notification, notes: " .. vim.inspect(notes))
    end)
end)

test("split side follows win.layout when it lies on mux.split.vertical's axis", function()
    for _, case in ipairs({
        {vertical = true, layout = "left", side = "left"},
        {vertical = true, layout = "right", side = "right"},
        {vertical = false, layout = "top", side = "above"},
        {vertical = false, layout = "bottom", side = "below"},
    }) do
        local args = split_args({vertical = case.vertical, size = 0.5, layout = case.layout})
        eq(args[1], "--split=" .. case.side, ("side for layout %s"):format(case.layout))
    end
end)

test("split side falls back to right or below when win.layout doesn't fit", function()
    for _, case in ipairs({
        -- on the other axis
        {vertical = true, layout = "top", side = "right"},
        {vertical = true, layout = "bottom", side = "right"},
        {vertical = false, layout = "left", side = "below"},
        {vertical = false, layout = "right", side = "below"},
        -- not a side at all
        {vertical = true, layout = "float", side = "right"},
        {vertical = false, layout = "float", side = "below"},
    }) do
        local args = split_args({vertical = case.vertical, size = 0.5, layout = case.layout})
        eq(args[1], "--split=" .. case.side, ("side for vertical=%s, layout %s"):format(case.vertical, case.layout))
    end
end)

test("split size up to 1 is a fraction of Neovim's block, rounded to a percent", function()
    for _, case in ipairs({
        {size = 0.5, ratio = "50"},
        {size = 0.333, ratio = "33"},
        {size = 0.335, ratio = "34"},
        {size = 1, ratio = "99"}, -- Rex needs room left for Neovim
        {size = 0.001, ratio = "1"},
        {size = 0, ratio = "1"},
    }) do
        local args = split_args({vertical = true, size = case.size})
        eq({args[2], args[3]}, {"--ratio", case.ratio}, ("ratio for size %s"):format(case.size))
    end
end)

test("split size over 1 is cells, across columns or lines", function()
    eq(split_args({vertical = true, size = 50, columns = 200, lines = 40})[3], "25", "50 of 200 columns")
    eq(split_args({vertical = false, size = 10, columns = 200, lines = 40})[3], "25", "10 of 40 lines")
    eq(split_args({vertical = true, size = 500, columns = 200})[3], "99", "more cells than columns")
end)

test("split anchors on Neovim's block only when REX_BLOCK is set", function()
    eq(split_args({vertical = true, size = 0.4, block = false}), {"--split=right", "--ratio", "40"}, "without REX_BLOCK")
    eq(split_args({vertical = true, size = 0.4, block = "block:other"}), {
        "--split=right", "--ratio", "40", "-b", "block:other",
    }, "with REX_BLOCK")
end)

test("split keeps the tool's env ahead of its command", function()
    split_args({vertical = true, size = 0.4, env = {FOO = "bar"}})
    eq(vim.list_slice(find({"run"}), 15), {"--", "env", "FOO=bar", "sleep", "31"}, "command")
end)

test("a failed split start leaves the session unstarted", function()
    fixture("run.json", {})
    split_args({vertical = true, size = 0.4}, function(session)
        eq(session.started, nil, "started")
        eq(session.rex_block_id, nil, "block id")
        eq(find({"window", "rename"}), nil, "rename")
    end)
end)

test("sends text as a paste, including text that starts with a dash", function()
    local text = "- item\nsecond line\n"
    new_session(AGENT):send(text)
    eq(api_params("block.event"), {
        session_id = S,
        block_id = AGENT,
        event = {type = "paste", payload = {text = text}},
    }, "paste event")
    eq(#calls(), 1, "a single call")
end)

test("sends a focus-in event first to tools that need it", function()
    local session = new_session(AGENT)
    session.tool.mux_focus = true
    session:send("hi")
    vim.wait(200, function()
        return #calls() == 2
    end)
    local events = vim.tbl_map(function(call)
        return vim.json.decode(call[4]).event.type
    end, calls())
    eq(events, {"focus", "paste"}, "event order")
    session.tool.mux_focus = nil
end)

test("submits with an enter key press", function()
    new_session(AGENT):submit()
    eq(calls(), {{"send-key", "-s", S, "-b", AGENT, "enter"}}, "calls")
end)

test("is running until the block's process exits", function()
    local session = new_session(AGENT)
    eq(session:is_running(), true, "running")
    eq(find({"block", "call"}), {"block", "call", "-s", S, "-b", AGENT, "process"}, "process call")
    fixture("process.json", {child = {pid = 1}, last_exit = 0})
    eq(session:is_running(), false, "exited")
end)

test("finds agents across sessions and names them by session and tab", function()
    local a = vim.system({"sleep", "31"})
    local b = vim.system({"sleep", "31"})
    local other = vim.system({"sleep", "32"})
    fixture("list.json", {
        {session_id = S, session_label = "dots", window_index = 2, window_label = "Agents", block_id = "block:a", pid = a.pid, cwd = "/tmp"},
        {session_id = "session:other", session_label = "app", window_index = 1, window_label = "claude", block_id = "block:b", pid = b.pid, cwd = "/tmp"},
        {session_id = S, session_label = "dots", window_index = 3, window_label = "zsh", block_id = "block:shell", pid = other.pid, cwd = "/tmp"},
    })
    local ok, err = pcall(function()
        local found = require("sidekick-rex.backend").sessions()
        table.sort(found, function(x, y)
            return x.id < y.id
        end)
        eq(vim.tbl_map(function(s)
            return {s.id, s.rex_session_id, s.mux_session, s.tool.name, s.rex_block_id}
        end, found), {
            {"rex block:a", S, "dots 2:Agents", "sleeper", "block:a"},
            {"rex block:b", "session:other", "app 1:claude", "sleeper", "block:b"},
        }, "sessions")
        eq(found[1].pids, {a.pid}, "pids")
    end)
    for _, p in ipairs({a, b, other}) do
        p:kill(9)
    end
    assert(ok, err)
end)

test("sidekick's picker lines up the path after locations of any length", function()
    local a = vim.system({"sleep", "31"})
    local b = vim.system({"sleep", "31"})
    fixture("list.json", {
        {session_id = S, session_label = "dots", window_index = 2, window_label = "a", block_id = "block:a", pid = a.pid, cwd = "/tmp/a"},
        {session_id = S, session_label = "dots", window_index = 3, window_label = "a much longer tab title", block_id = "block:b", pid = b.pid, cwd = "/tmp/b"},
    })
    local ui_select = vim.ui.select
    local rows ---@type string[]?
    vim.ui.select = function(items, opts)
        rows = vim.tbl_map(opts.format_item, items)
    end
    local ok, err = pcall(function()
        require("sidekick.cli.ui.select").select({filter = {started = true}, cb = function() end})
        eq(vim.ui.select ~= ui_select, true, "the stub is back in place")
        assert(rows, "the picker never opened")
        -- sidekick also lists agents it finds running on this machine, so keep
        -- only the two from the fixture
        local all = rows
        rows = vim.tbl_filter(function(row)
            return row:match("%ssleeper%s") ~= nil
        end, rows)
        assert(#rows == 2, "rows: " .. vim.inspect(all))
        local cols = vim.tbl_map(function(row)
            return vim.fn.strdisplaywidth(row:match("^(.-)/tmp/"))
        end, rows)
        eq(cols[1], cols[2], "path columns of " .. vim.inspect(rows))
    end)
    vim.ui.select = ui_select
    for _, p in ipairs({a, b}) do
        p:kill(9)
    end
    assert(ok, err)
end)

test("focus switches to the agent's tab", function()
    new_session(AGENT):focus()
    eq(calls(), {{"api", "call", "session.focus_block", vim.json.encode({session_id = S, block_id = AGENT})}}, "calls")
end)

test("focus switches the app to an agent in another session", function()
    local session = new_session(AGENT)
    session.rex_session_id = "session:other"
    session:focus()
    eq(api_params("session.focus_block"), {session_id = "session:other", block_id = AGENT}, "focus")
    eq(find({"do", "session.select"}), {"do", "session.select", "session_id=session:other"}, "select")
end)

test("sidekick's toggle and focus reach attached Rex sessions", function()
    local session = new_session(AGENT)
    Session.attach(session)
    require("sidekick.cli").toggle({name = "sleeper"})
    assert(vim.wait(500, function()
        return find({"api", "call", "session.focus_block"}) ~= nil
    end), "toggle did not focus, calls: " .. vim.inspect(calls()))
    vim.fn.delete(fake .. "/calls")
    require("sidekick.cli").focus({name = "sleeper"})
    assert(vim.wait(500, function()
        return find({"api", "call", "session.focus_block"}) ~= nil
    end), "focus did not focus, calls: " .. vim.inspect(calls()))
    Session.detach(session)
end)

test("detach leaves the agent running", function()
    local session = new_session(AGENT)
    Session.attach(session)
    local state = require("sidekick.cli.state").get({attached = true, name = "sleeper"})[1]
    vim.fn.delete(fake .. "/calls")
    require("sidekick.cli.state").detach(state)
    eq(session:is_attached(), false, "attached")
    eq(vim.tbl_filter(function(call)
        return call[1] ~= "block" -- the liveness check
    end, calls()), {}, "calls besides liveness checks")
end)

vim.fn.delete(fake, "rf")
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
