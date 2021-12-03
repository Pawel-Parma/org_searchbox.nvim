local M = {}
local utils = require('searchbox.utils')
local Input = require('nui.input')

local buf_call = function(state, fn)
  return vim.api.nvim_buf_call(state.bufnr, fn)
end

local clear_matches = function(state)
  utils.clear_matches(state.bufnr)
end

M.incsearch = {
  buf_leave = clear_matches,
  on_close = clear_matches,
  on_submit = function(value, opts, state)
    clear_matches(state)
    vim.cmd('normal n')
  end,
  on_change = function(value, opts, state)
    utils.clear_matches(state.bufnr)

    if value == '' then
      return
    end

    opts = opts or {}
    local search_flags = 'c'
    local query = utils.build_search(value, opts)

    if opts.reverse then
      search_flags = 'bc'
    end

    local start_pos = opts.visual_mode
      and state.range.start
      or state.start_cursor

    local searchpos = function()
      vim.fn.setpos('.', {state.bufnr, start_pos[1], start_pos[2]})

      local pos = vim.fn.searchpos(query, search_flags, state.range.ends[1])
      local offset = vim.fn.searchpos(query, 'cne')
      pos[3] = offset[2]

      return pos
    end

    local pos = vim.api.nvim_buf_call(state.bufnr, searchpos)
    local no_match = pos[1] == 0 and pos[2] == 0

    if no_match then
      return
    end

    state.line = pos[1]
    local col = pos[2]
    local off = pos[3]

    vim.api.nvim_buf_add_highlight(
      state.bufnr,
      utils.hl_namespace,
      utils.hl_name,
      state.line - 1,
      col - 1,
      off
    )

    if state.line ~= state.line_prev then
      vim.api.nvim_win_set_cursor(state.winid, {state.line, col - 1})
      state.line_prev = state.line
    end
  end
}

M.match_all = {
  buf_leave = clear_matches,
  on_close = clear_matches,
  on_submit = function(value, opts, state)
    if opts.clear_matches then
      clear_matches(state)
    end

    if opts.reverse then
      vim.cmd('normal N')
    else
      vim.cmd('normal n')
    end
  end,
  on_change = function(value, opts, state)
    utils.clear_matches(state.bufnr)
    if value == '' then return end

    -- figure out 'maxcount' for searchcount
    state.max_match = state.max_match or buf_call(state, function()
      local size = vim.fn.getfsize(vim.fn.expand('%'))

      if size < 0 then
        size = vim.o.lines * 10000
      end

      return size
    end)

    opts = opts or {}
    local query = utils.build_search(value, opts)

    local searchpos = function()
      local stopline = state.range.ends[1]
      local pos = vim.fn.searchpos(query, '', stopline)
      local offset = vim.fn.searchpos(query, 'cne', stopline)
      pos[3] = offset[2]

      return pos
    end

    vim.fn.setreg('/', query)
    local results = buf_call(state, function()
      return vim.fn.searchcount({maxcount = state.max_match})
    end)

    if results.total == 0 then
      return
    end

    buf_call(state, function()
      local start = state.range.start
      vim.fn.setpos('.', {0, start[1], start[2]})
    end)

    state.total_matches = results.total

    for i = 1, results.total, 1 do
      local pos = buf_call(state, searchpos)

      local line = pos[1]
      local col = pos[2]
      local off = pos[3]

      -- check if there is a match
      if line == 0 and col == 0 then
        break
      end

      if i == 1 then
        state.first_match = pos
      end

      vim.api.nvim_buf_add_highlight(
        state.bufnr,
        utils.hl_namespace,
        utils.hl_name,
        line - 1,
        col - 1,
        off
      )
    end

    local pos = opts.visual_mode
      and state.range.start
      or state.start_cursor

    buf_call(state, function()
      vim.fn.setpos('.', {0, pos[1], pos[2]})
    end)
  end
}

local noop = function() end
M.simple = {
  buf_leave = noop,
  on_close = noop,
  on_submit = function(value, opts, state)
    if opts.reverse then
      vim.cmd('normal N')
    else
      vim.cmd('normal n')
    end
  end,
  on_change = noop
}

M.replace = {
  buf_leave = clear_matches,
  on_close = clear_matches,
  on_change = M.match_all.on_change,
  on_submit = function(value, search_opts, state, popup_opts)
    local border = {
      border = {
        text = {
          top = ' With ',
          bottom = ' 2/2 ',
          bottom_align = 'right'
        }
      }
    }

    local replace_popup = utils.merge(popup_opts, border)

    local input = Input(replace_popup, {
      prompt = ' ',
      default_value = '',
      on_close = function()
        clear_matches(state)
        vim.defer_fn(function()
          search_opts.default_value = value
          require('searchbox').replace(search_opts)
        end, 3)
      end,
      on_submit = function(value)
        clear_matches(state)
        local flags = 'g'

        if search_opts.confirm == 'native' then
          flags = 'gc'
        end

        local screen = vim.opt.lines:get()
        local enough_space = screen >= 14
        local range = search_opts.visual_mode and "'<,'>s" or '%s'
        local cmd = [[ %s//%s/%s ]]

        local replace_cmd = cmd:format(range, value, flags)

        if search_opts.confirm == 'menu' and enough_space then
          return M.confirm(value, state)
        end

        -- change to native confirm if there isn't enough space
        if search_opts.confirm == 'menu' then
          replace_cmd = cmd:format(range, value, 'gc')
        end

        vim.cmd(replace_cmd)
      end
    })

    input:mount()
    require('searchbox.inputs').default_mappings(input, state.winid)
  end,
}

M.confirm = function(value, state)
  local fn = {}
  local match_index = 0
  local menu = require('searchbox.replace-menu')
  local next_match = function()
    local pos = vim.fn.searchpos(vim.fn.getreg('/'), 'cw')
    local off = vim.fn.searchpos(vim.fn.getreg('/'), 'cwe')
    pos[3] = off[2]

    return pos
  end

  local replace = function(pos)
    vim.api.nvim_buf_set_text(0, pos[1] - 1, pos[2] - 1, pos[1] - 1, pos[3], {value})
  end

  local highlight = function(pos)
    vim.api.nvim_buf_add_highlight(
      state.bufnr,
      utils.hl_namespace,
      utils.hl_name,
      pos[1] - 1,
      pos[2] - 1,
      pos[3]
    )
  end

  local cursor_pos = function(pos)
    vim.api.nvim_win_set_cursor(state.winid, {pos[1], pos[2] - 1})
  end

  fn.execute = function(item, pos)
    match_index = match_index + 1
    clear_matches(state)

    local is_last = match_index == state.total_matches

    local stop = true
    local replace_next = false

    if item.action == 'replace' then
      replace(pos)
      stop = false
    end

    if item.action == 'replace_all' then
      replace(pos)
      replace_next = true
      stop = false
    end

    if item.action == 'next' then
      -- move so next_match can do the right thing.
      cursor_pos({pos[1], pos[3]})
      stop = false
    end

    if item.action == 'quit' then
      stop = true
    end

    if item.action == 'last' then
      replace(pos)
      stop = true
    end

    if stop or is_last then
      return
    end

    local match = next_match()
    if match[1] == 0 then
      return
    end

    if replace_next then
      fn.execute({action = 'replace_all'}, match)
    else
      fn.confirm(match)
    end
  end

  fn.confirm = function(pos)
    clear_matches(state)
    highlight(pos)
    cursor_pos({pos[1], pos[2] - 1})
    menu.confirm_action({
      on_close = function()
        clear_matches(state)
      end,
      on_submit = function(item)
        fn.execute(item, pos)
      end
    })
  end

  -- Move cursor just before the first match.
  -- Make sure we don't skip anything.
  cursor_pos(state.first_match)
  fn.confirm(next_match())
end

return M

