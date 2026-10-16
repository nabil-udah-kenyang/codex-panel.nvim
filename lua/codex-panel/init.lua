local M = {}

local state = {
  job = nil,
  next_id = 0,
  pending = {},
  buffer = nil,
  window = nil,
  input_buffer = nil,
  input_window = nil,
  threads = {},
  usage = nil,
  models = {},
  model = nil,
  reasoning_effort = nil,
  thread_id = nil,
  thread_name = "New chat",
  account = nil,
  status = "Starting Codex…",
  output = {},
  partial = "",
  loading = false,
  initialized = false,
  login_after_init = false,
  queued_prompt = nil,
  source_path = nil,
  source_line = nil,
  highlights = {},
  placeholder_ns = nil,
}

local set_account_login
local send_prompt

local function table_or_nil(value)
  if type(value) == "table" then
    return value
  end
  return nil
end

local function as_text(value, fallback)
  if value == nil or value == vim.NIL then
    return fallback or ""
  end
  if type(value) == "string" then
    return value
  end
  return tostring(value)
end

local function notify(message, level)
  vim.schedule(function()
    vim.notify("Codex: " .. message, level or vim.log.levels.INFO)
  end)
end

local function rpc(method, params, callback)
  if not state.job then
    return nil
  end
  state.next_id = state.next_id + 1
  local id = state.next_id
  if callback then
    state.pending[id] = callback
  end
  local payload = vim.json.encode({ id = id, method = method, params = params or {} }) .. "\n"
  vim.fn.chansend(state.job, payload)
  return id
end

local function text_of(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end
  local pieces = {}
  for _, part in ipairs(content) do
    if type(part) == "table" and type(part.text) == "string" then
      pieces[#pieces + 1] = part.text
    end
  end
  return table.concat(pieces, "")
end

local function append(role, body)
  body = vim.trim(body or "")
  if body == "" then
    return
  end
  state.output[#state.output + 1] = { role = role, body = body }
  if #state.output > 100 then
    table.remove(state.output, 1)
  end
  M.render()
end

local function open_url(url)
  if vim.ui.open then
    vim.ui.open(url)
  else
    vim.fn.jobstart({ "xdg-open", url }, { detach = true })
  end
end

local function focus_composer()
  if state.input_window and vim.api.nvim_win_is_valid(state.input_window) then
    vim.api.nvim_set_current_win(state.input_window)
    vim.cmd.startinsert()
  end
end

local function focus_toolbar()
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    vim.api.nvim_set_current_win(state.window)
    vim.api.nvim_win_set_cursor(state.window, { 1, 0 })
  end
end

local function account_read()
  rpc("account/read", { refreshToken = false }, function(result)
    result = table_or_nil(result)
    state.account = result and table_or_nil(result.account) or nil
    state.status = state.account and "Connected" or "Not signed in"
    M.render()
  end)
end

local function read_usage()
  rpc("account/rateLimits/read", { excludeResetCreditDetails = true }, function(result)
    state.usage = table_or_nil(result)
    M.render()
  end)
end

local function usage_bucket()
  local usage = table_or_nil(state.usage)
  if not usage then
    return nil
  end
  local buckets = table_or_nil(usage.rateLimitsByLimitId)
  local codex_bucket = buckets and table_or_nil(buckets.codex)
  if codex_bucket then
    return codex_bucket
  end
  for _, bucket in pairs(buckets or {}) do
    bucket = table_or_nil(bucket)
    if bucket then
      return bucket
    end
  end
  return table_or_nil(usage.rateLimits)
end

local function format_usage_window(window)
  window = table_or_nil(window)
  if not window or type(window.usedPercent) ~= "number" then
    return nil
  end
  local raw_duration = window.windowDurationMins
  local duration = (type(raw_duration) == "number" or type(raw_duration) == "string")
      and tonumber(raw_duration)
    or nil
  local label = "Usage"
  if duration then
    if duration >= 1440 then
      label = math.floor(duration / 1440) .. "d"
    elseif duration >= 60 then
      label = math.floor(duration / 60) .. "h"
    else
      label = math.floor(duration) .. "m"
    end
  end
  local remaining = math.min(100, math.max(0, 100 - window.usedPercent))
  local reset_text = ""
  if type(window.resetsAt) == "number" then
    local seconds = math.max(0, window.resetsAt - os.time())
    if seconds >= 86400 then
      reset_text = " · reset " .. math.floor(seconds / 86400) .. "d"
    elseif seconds >= 3600 then
      reset_text = " · reset " .. math.floor(seconds / 3600) .. "h"
    elseif seconds > 0 then
      reset_text = " · reset " .. math.max(1, math.floor(seconds / 60)) .. "m"
    else
      reset_text = " · resetting"
    end
  end
  return string.format("%s %d%% left%s", label, remaining, reset_text)
end

local function usage_summary()
  local bucket = usage_bucket()
  if not bucket then
    return state.account and "Usage: unavailable" or "Usage: sign in to view"
  end
  local windows = {}
  local primary = format_usage_window(bucket.primary)
  local secondary = format_usage_window(bucket.secondary)
  if primary then
    windows[#windows + 1] = primary
  end
  if secondary then
    windows[#windows + 1] = secondary
  end
  local usage = table_or_nil(state.usage)
  local credits = usage and table_or_nil(usage.rateLimitResetCredits)
  if credits and type(credits.availableCount) == "number" and credits.availableCount > 0 then
    windows[#windows + 1] = credits.availableCount .. " reset credit" .. (credits.availableCount == 1 and "" or "s")
  end
  return #windows > 0 and ("Usage: " .. table.concat(windows, "  ·  ")) or "Usage: unavailable"
end

local function load_models()
  rpc("model/list", { includeHidden = false, limit = 100 }, function(result)
    result = table_or_nil(result)
    state.models = result and table_or_nil(result.data) or {}
    if not state.model then
      for _, model in ipairs(state.models) do
        if model.isDefault then
          state.model = model
          state.reasoning_effort = model.defaultReasoningEffort
          break
        end
      end
    end
    M.render()
  end)
end

local function pick_model()
  if #state.models == 0 then
    notify("Model list is not ready yet")
    return
  end
  vim.ui.select(state.models, {
    prompt = "Codex model",
    format_item = function(model)
      local name = as_text(model.displayName or model.model or model.id, "Model")
      return (state.model and state.model.id == model.id and "● " or "  ") .. name
    end,
  }, function(model)
    if not model then
      focus_composer()
      return
    end
    state.model = model
    state.reasoning_effort = model.defaultReasoningEffort
    state.status = "Model: " .. as_text(model.displayName or model.model or model.id)
    M.render()
    focus_composer()
  end)
end

local function pick_reasoning()
  if not state.model then
    notify("Choose a model first")
    return
  end
  local options = state.model.supportedReasoningEfforts or {}
  if #options == 0 then
    notify("This model does not expose reasoning options")
    return
  end
  vim.ui.select(options, {
    prompt = "Reasoning effort · " .. as_text(state.model.displayName or state.model.model),
    format_item = function(option)
      local value = as_text(option.reasoningEffort or option, "default")
      local description = option.description and (" — " .. option.description) or ""
      return (state.reasoning_effort == value and "● " or "  ") .. value .. description
    end,
  }, function(option)
    if not option then
      focus_composer()
      return
    end
    state.reasoning_effort = option.reasoningEffort or option
    state.status = "Reasoning: " .. as_text(state.reasoning_effort)
    M.render()
    focus_composer()
  end)
end

local function list_threads()
  rpc("thread/list", { limit = 30, sortDirection = "desc", archived = false }, function(result)
    result = table_or_nil(result)
    local threads = result and (table_or_nil(result.threads) or table_or_nil(result.data)) or {}
    state.threads = {}
    for _, thread in ipairs(threads) do
      thread = table_or_nil(thread)
      if thread then
        state.threads[#state.threads + 1] = thread
      end
    end
    M.render()
  end)
end

local function handle_approval(message)
  local method = message.method or ""
  local p = message.params or {}
  local title = method:find("fileChange", 1, true) and "Codex wants to change files" or "Codex wants to run a command"
  local detail = p.command or p.reason or p.cwd or p.grantRoot or "Review the requested action"
  if type(detail) == "table" then
    detail = table.concat(detail, " ")
  end
  vim.schedule(function()
    vim.ui.select({ "Approve once", "Approve for this session", "Decline", "Cancel turn" }, {
      prompt = title .. ": " .. tostring(detail),
    }, function(choice)
      local decision = "decline"
      if choice == "Approve once" then
        decision = "accept"
      elseif choice == "Approve for this session" then
        decision = "acceptForSession"
      elseif choice == "Cancel turn" then
        decision = "cancel"
      end
      if state.job then
        vim.fn.chansend(state.job, vim.json.encode({ id = message.id, result = { decision = decision } }) .. "\n")
      end
    end)
  end)
end

local function handle_message(message)
  if message.id and state.pending[message.id] then
    local callback = state.pending[message.id]
    state.pending[message.id] = nil
    if message.error then
      state.status = message.error.message or "Codex request failed"
      notify(state.status, vim.log.levels.ERROR)
      M.render()
    else
      callback(message.result or {})
    end
    return
  end

  if message.id and message.method then
    handle_approval(message)
    return
  end

  local p = message.params or {}
  if message.method == "item/agentMessage/delta" then
    local delta = p.delta or p.text or ""
    if delta ~= "" then
      local last = state.output[#state.output]
      if not last or last.role ~= "Codex" or not last.streaming then
        last = { role = "Codex", body = "", streaming = true }
        state.output[#state.output + 1] = last
      end
      last.body = last.body .. delta
      M.render()
    end
  elseif message.method == "turn/completed" then
    local last = state.output[#state.output]
    if last then
      last.streaming = false
    end
    state.loading = false
    state.status = "Ready"
    list_threads()
    read_usage()
    M.render()
  elseif message.method == "account/updated" then
    account_read()
    read_usage()
  elseif message.method == "account/rateLimits/updated" then
    read_usage()
  elseif message.method == "thread/name/updated" then
    list_threads()
  elseif message.method == "item/commandExecution/requestApproval"
      or message.method == "item/fileChange/requestApproval"
      or message.method == "execCommandApproval"
      or message.method == "applyPatchApproval" then
    handle_approval(message)
  end
end

local function on_stdout(_, data, _)
  if not data then
    return
  end
  for i, chunk in ipairs(data) do
    if i == 1 then
      state.partial = state.partial .. chunk
    else
      local line = state.partial
      state.partial = chunk
      if line ~= "" then
        local ok, message = pcall(vim.json.decode, line)
        if ok then
          vim.schedule(function()
            handle_message(message)
          end)
        end
      end
    end
  end
end

local function start_server()
  if state.job and vim.fn.jobwait({ state.job }, 0)[1] == -1 then
    return
  end
  state.status = "Starting Codex…"
  state.output = {}
  state.pending = {}
  state.partial = ""
  state.job = vim.fn.jobstart({ "codex", "app-server", "--listen", "stdio://" }, {
    stdin = "pipe",
    stdout = "pipe",
    stderr = "pipe",
    on_stdout = on_stdout,
    on_stderr = function(_, data)
      local line = table.concat(data or {}, " ")
      if line:find("error", 1, true) then
        notify(line, vim.log.levels.WARN)
      end
    end,
    on_exit = function(_, code)
      state.job = nil
      state.initialized = false
      state.status = "Stopped (" .. tostring(code) .. ")"
      M.render()
    end,
  })
  if state.job <= 0 then
    state.job = nil
    state.status = "Could not start codex app-server"
    notify(state.status, vim.log.levels.ERROR)
    return
  end
  rpc("initialize", {
    clientInfo = { name = "nvim_codex_panel", title = "Neovim Codex Panel", version = "0.1.0" },
  }, function()
    vim.fn.chansend(state.job, vim.json.encode({ method = "initialized", params = {} }) .. "\n")
    state.initialized = true
    state.status = "Connected"
    account_read()
    read_usage()
    load_models()
    list_threads()
    M.render()
    if state.login_after_init then
      state.login_after_init = false
      set_account_login()
    end
    if state.queued_prompt then
      local queued = state.queued_prompt
      state.queued_prompt = nil
      vim.schedule(function()
        if state.input_buffer and vim.api.nvim_buf_is_valid(state.input_buffer) then
          vim.api.nvim_buf_set_lines(state.input_buffer, 0, -1, false, { queued })
          send_prompt()
        end
      end)
    end
  end)
end

local function extract_turns(result)
  local turns = result and (result.turns or result.data) or {}
  local messages = {}
  for _, turn in ipairs(turns) do
    for _, item in ipairs(turn.items or {}) do
      local kind = item.type or ""
      if kind == "userMessage" or kind == "agentMessage" then
        local body = text_of(item.content or item.text)
        if body ~= "" then
          messages[#messages + 1] = { role = kind == "userMessage" and "You" or "Codex", body = body }
        end
      end
    end
  end
  state.output = messages
  M.render()
end

local function resume_thread(thread)
  state.thread_id = thread.id
  state.thread_name = as_text(thread.name or thread.preview, "Codex chat")
  state.output = {}
  state.status = "Loading conversation…"
  rpc("thread/resume", { threadId = thread.id, cwd = vim.fn.getcwd(), excludeTurns = true }, function()
    rpc("thread/turns/list", {
      threadId = thread.id,
      limit = 30,
      sortDirection = "asc",
      itemsView = "full",
    }, extract_turns)
  end)
end

local function new_thread()
  state.thread_id = nil
  state.thread_name = "New chat"
  state.output = {}
  state.status = "New conversation"
  M.render()
end

local function thread_picker()
  if #state.threads == 0 then
    notify("No saved conversations yet")
    return
  end
  local labels = {}
  for i, thread in ipairs(state.threads) do
    labels[i] = as_text(thread.name or thread.preview or thread.id, "Untitled chat")
  end
  vim.ui.select(labels, { prompt = "Codex conversations" }, function(_, index)
    if index then
      resume_thread(state.threads[index])
    end
    focus_composer()
  end)
end

local function get_context()
  local filename = state.source_path
  if not filename or filename == "" then
    return ""
  end
  return "\n\nIDE context: @" .. filename .. (state.source_line and (" at line " .. state.source_line) or "")
end

local send_prompt_after_thread
send_prompt = function()
  if not state.input_buffer or not vim.api.nvim_buf_is_valid(state.input_buffer) then
    return
  end
  local prompt = vim.trim(table.concat(vim.api.nvim_buf_get_lines(state.input_buffer, 0, -1, false), "\n"))
  if prompt == "" then
    return
  end
  if not state.initialized then
    state.queued_prompt = prompt
    state.status = "Waiting for Codex…"
    M.render()
    return
  end
  local full_prompt = prompt .. get_context()
  if not state.thread_id then
    state.status = "Creating conversation…"
    rpc("thread/start", {
      cwd = vim.fn.getcwd(),
      approvalPolicy = "on-request",
      model = state.model and (state.model.model or state.model.id) or nil,
    }, function(result)
      state.thread_id = result.thread and result.thread.id
      state.thread_name = as_text(result.thread and (result.thread.name or result.thread.preview), "New chat")
      if state.thread_id then
        send_prompt_after_thread(full_prompt, prompt)
      end
    end)
  else
    send_prompt_after_thread(full_prompt, prompt)
  end
end

send_prompt_after_thread = function(full_prompt, visible_prompt)
  append("You", visible_prompt)
  state.loading = true
  state.status = "Codex is working…"
  vim.api.nvim_buf_set_lines(state.input_buffer, 0, -1, false, { "" })
  vim.bo[state.input_buffer].modified = false
  M.render()
  rpc("turn/start", {
    threadId = state.thread_id,
    cwd = vim.fn.getcwd(),
    model = state.model and (state.model.model or state.model.id) or nil,
    effort = state.reasoning_effort,
    input = { { type = "text", text = full_prompt } },
  })
end

set_account_login = function()
  focus_composer()
  rpc("account/login/start", { type = "chatgpt" }, function(result)
    if result.authUrl then
      open_url(result.authUrl)
      state.status = "Finish sign-in in your browser…"
      M.render()
    else
      notify("Login URL was not returned", vim.log.levels.ERROR)
    end
  end)
end

local function lines_for_panel()
  local panel_width = state.window and vim.api.nvim_win_is_valid(state.window)
      and vim.api.nvim_win_get_width(state.window) or 60
  local message_width = math.max(12, panel_width - 8)
  local account = state.account
  local identity = account
      and (as_text(account.email, "ChatGPT") .. " · " .. as_text(account.planType, "active"))
    or as_text(state.status, "Ready")
  local lines = {
    "  [c] chats  [n] new  [l] login  [m] model  [r] effort",
    "  Chats  ·  " .. identity,
    "  Model: " .. as_text(state.model and (state.model.displayName or state.model.model), "Default")
      .. "  ·  Reasoning: " .. as_text(state.reasoning_effort, "Default"),
    "  " .. usage_summary(),
    "  <C-k> toolbar · i / <C-j> type · u refresh usage",
    "",
  }
  state.highlights = {
    { 0, "CodexPanelToolbar" },
    { 1, "CodexPanelSection" },
    { 2, "CodexPanelSection" },
    { 3, "CodexPanelUsage" },
    { 4, "CodexPanelMuted" },
  }
  lines[#lines + 1] = "  " .. as_text(state.thread_name, "New chat")
  state.highlights[#state.highlights + 1] = { #lines - 1, "CodexPanelSection" }
  lines[#lines + 1] = ""
  for _, item in ipairs(state.output) do
    local is_user = item.role == "You"
    local role_hl = is_user and "CodexPanelUserLabel" or "CodexPanelAssistantLabel"
    local message_hl = is_user and "CodexPanelUserMessage" or "CodexPanelMessage"
    local role = is_user and "You" or "Codex"
    local function add_aligned(text, group)
      local bubble = not is_user and group == "CodexPanelAssistantBubble"
      local rendered = bubble and ("  " .. text .. "  ") or text
      local pad = is_user and math.max(2, panel_width - vim.fn.strdisplaywidth(rendered) - 2) or 2
      lines[#lines + 1] = string.rep(" ", pad) .. rendered
      state.highlights[#state.highlights + 1] = { #lines - 1, group, pad, -1 }
    end
    lines[#lines + 1] = ""
    add_aligned(role, role_hl)
    for _, paragraph in ipairs(vim.split(item.body, "\n", { plain = true })) do
      local current = ""
      for word in paragraph:gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if current ~= "" and vim.fn.strdisplaywidth(candidate) > message_width then
          add_aligned(current, is_user and message_hl or "CodexPanelAssistantBubble")
          current = word
        else
          current = candidate
        end
      end
      if current ~= "" then
        add_aligned(current, is_user and message_hl or "CodexPanelAssistantBubble")
      end
    end
  end
  lines[#lines + 1] = "  " .. state.status .. "   ·   <C-n> new  <C-p> chats  L login"
  state.highlights[#state.highlights + 1] = { #lines - 1, "CodexPanelMuted" }
  return lines
end

local function update_placeholder()
  if not state.input_buffer or not vim.api.nvim_buf_is_valid(state.input_buffer) then
    return
  end
  state.placeholder_ns = state.placeholder_ns or vim.api.nvim_create_namespace("codex-panel-placeholder")
  vim.api.nvim_buf_clear_namespace(state.input_buffer, state.placeholder_ns, 0, -1)
  local content = vim.api.nvim_buf_get_lines(state.input_buffer, 0, -1, false)
  if #content == 1 and content[1] == "" then
    vim.api.nvim_buf_set_extmark(state.input_buffer, state.placeholder_ns, 0, 0, {
      virt_text = { { "Do anything", "CodexPanelMuted" } },
      virt_text_pos = "overlay",
    })
  end
end

local function resize_composer()
  if not state.window or not vim.api.nvim_win_is_valid(state.window) then
    return
  end
  if not state.input_window or not vim.api.nvim_win_is_valid(state.input_window) then
    return
  end

  local panel_width = vim.api.nvim_win_get_width(state.window)
  local panel_height = vim.api.nvim_win_get_height(state.window)
  local use_border = panel_width >= 12
  local col = use_border and 1 or 0
  vim.api.nvim_win_set_config(state.input_window, {
    relative = "win",
    win = state.window,
    anchor = "SW",
    row = math.max(0, panel_height - 1),
    col = col,
    width = math.max(1, panel_width - (use_border and 2 or 0)),
    height = math.max(1, math.min(5, panel_height)),
    border = use_border and "rounded" or "none",
    style = "minimal",
  })
end

function M.render()
  if not state.buffer or not vim.api.nvim_buf_is_valid(state.buffer) then
    return
  end
  local lines = lines_for_panel()
  vim.bo[state.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(state.buffer, 0, -1, false, lines)
  vim.bo[state.buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buffer, -1, 0, -1)
  for _, entry in ipairs(state.highlights) do
    vim.api.nvim_buf_add_highlight(state.buffer, -1, entry[2], entry[1], entry[3] or 0, entry[4] or -1)
  end
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    vim.api.nvim_win_set_cursor(state.window, { #lines, 0 })
  end
  update_placeholder()
end

local function create_ui()
  local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local menu_hl = vim.api.nvim_get_hl(0, { name = "Pmenu", link = false })
  local float_hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  vim.api.nvim_set_hl(0, "CodexPanelSection", { link = "Title" })
  vim.api.nvim_set_hl(0, "CodexPanelToolbar", { link = "Title" })
  vim.api.nvim_set_hl(0, "CodexPanelMuted", { link = "Comment" })
  vim.api.nvim_set_hl(0, "CodexPanelUsage", { link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "CodexPanelActive", { link = "PmenuSel" })
  -- Everblush cyan, used for the user's own messages and label.
  vim.api.nvim_set_hl(0, "CodexPanelUserMessage", { fg = "#6cbfbf", bg = "NONE" })
  vim.api.nvim_set_hl(0, "CodexPanelUserLabel", { link = "CodexPanelUserMessage" })
  vim.api.nvim_set_hl(0, "CodexPanelAssistantLabel", { link = "Special" })
  vim.api.nvim_set_hl(0, "CodexPanelMessage", { link = "Normal" })
  vim.api.nvim_set_hl(0, "CodexPanelAssistantBubble", {
    fg = normal_hl.fg,
    bg = menu_hl.bg or float_hl.bg or normal_hl.bg,
  })
  vim.cmd("botright 64vnew")
  state.window = vim.api.nvim_get_current_win()
  state.buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.window, state.buffer)
  vim.api.nvim_win_set_width(state.window, math.min(68, math.max(28, math.floor(vim.o.columns * 0.42))))
  vim.bo[state.buffer].buftype = "nofile"
  vim.bo[state.buffer].bufhidden = "hide"
  vim.bo[state.buffer].filetype = "text"
  vim.wo[state.window].wrap = true
  vim.wo[state.window].linebreak = true
  vim.wo[state.window].breakindent = true
  vim.wo[state.window].showbreak = ""
  vim.wo[state.window].list = false
  vim.wo[state.window].conceallevel = 0
  vim.wo[state.window].number = false
  vim.wo[state.window].relativenumber = false
  vim.wo[state.window].signcolumn = "no"
  vim.wo[state.window].winfixwidth = false
  vim.wo[state.window].winhighlight = "Normal:Normal"

  state.input_buffer = vim.api.nvim_create_buf(false, true)
  -- NvimTree excludes nofile windows from its window picker, so opening a file
  -- cannot target this composer (the picker label used to appear as "B").
  vim.bo[state.input_buffer].buftype = "nofile"
  vim.bo[state.input_buffer].bufhidden = "hide"
  vim.bo[state.input_buffer].filetype = "codex_panel_prompt"
  vim.api.nvim_buf_set_lines(state.input_buffer, 0, -1, false, { "" })
  vim.bo[state.input_buffer].modified = false
  local panel_width = vim.api.nvim_win_get_width(state.window)
  local bordered = panel_width >= 12
  state.input_window = vim.api.nvim_open_win(state.input_buffer, false, {
    relative = "win",
    win = state.window,
    anchor = "SW",
    row = vim.api.nvim_win_get_height(state.window) - 1,
    col = bordered and 1 or 0,
    width = math.max(1, panel_width - (bordered and 2 or 0)),
    height = math.max(1, math.min(5, vim.api.nvim_win_get_height(state.window))),
    border = bordered and "rounded" or "none",
    style = "minimal",
  })
  vim.wo[state.input_window].wrap = true
  vim.wo[state.input_window].number = false
  vim.wo[state.input_window].relativenumber = false
  vim.wo[state.input_window].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"
  resize_composer()
  vim.keymap.set({ "n", "i" }, "<CR>", send_prompt, { buffer = state.input_buffer, desc = "Send to Codex" })
  vim.keymap.set("i", "<S-CR>", "<C-o>o", { buffer = state.input_buffer, desc = "New line in Codex prompt" })
  vim.keymap.set("n", "<S-CR>", "o<Esc>k", { buffer = state.input_buffer, desc = "New line in Codex prompt" })
  vim.keymap.set({ "n", "i" }, "<M-m>", pick_model, { buffer = state.input_buffer, desc = "Choose Codex model" })
  vim.keymap.set({ "n", "i" }, "<M-r>", pick_reasoning, { buffer = state.input_buffer, desc = "Choose Codex reasoning effort" })
  vim.keymap.set({ "n", "i" }, "<M-u>", read_usage, { buffer = state.input_buffer, desc = "Refresh Codex usage" })
  vim.keymap.set({ "n", "i" }, "<M-c>", thread_picker, { buffer = state.input_buffer, desc = "Choose Codex chat" })
  vim.keymap.set({ "n", "i" }, "<M-l>", set_account_login, { buffer = state.input_buffer, desc = "Sign in to ChatGPT" })
  vim.keymap.set({ "n", "i" }, "<M-n>", function()
    new_thread()
    focus_composer()
  end, { buffer = state.input_buffer, desc = "New Codex chat" })
  vim.keymap.set({ "n", "i" }, "<C-k>", focus_toolbar, { buffer = state.input_buffer, desc = "Focus Codex toolbar" })
  vim.keymap.set("n", "q", M.close, { buffer = state.buffer, desc = "Close Codex panel" })
  vim.keymap.set("n", "i", focus_composer, { buffer = state.buffer, desc = "Return to Codex composer" })
  vim.keymap.set("n", "<C-j>", focus_composer, { buffer = state.buffer, desc = "Return to Codex composer" })
  vim.keymap.set("n", "<C-n>", new_thread, { buffer = state.buffer, desc = "New Codex chat" })
  vim.keymap.set("n", "<C-p>", thread_picker, { buffer = state.buffer, desc = "Choose Codex chat" })
  vim.keymap.set("n", "c", thread_picker, { buffer = state.buffer, desc = "Choose Codex chat" })
  vim.keymap.set("n", "l", set_account_login, { buffer = state.buffer, desc = "Sign in to ChatGPT" })
  vim.keymap.set("n", "n", function()
    new_thread()
    focus_composer()
  end, { buffer = state.buffer, desc = "New Codex chat" })
  vim.keymap.set("n", "L", set_account_login, { buffer = state.buffer, desc = "Sign in to ChatGPT" })
  vim.keymap.set("n", "m", pick_model, { buffer = state.buffer, desc = "Choose Codex model" })
  vim.keymap.set("n", "r", pick_reasoning, { buffer = state.buffer, desc = "Choose Codex reasoning effort" })
  vim.keymap.set("n", "u", read_usage, { buffer = state.buffer, desc = "Refresh Codex usage" })
  vim.keymap.set("n", "<CR>", thread_picker, { buffer = state.buffer, desc = "Open Codex chat" })
  vim.keymap.set("n", "<LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= state.window or mouse.line ~= 1 then
      return
    end
    local controls = {
      { token = "[c] chats", action = thread_picker },
      { token = "[n] new", action = function()
        new_thread()
        focus_composer()
      end },
      { token = "[l] login", action = set_account_login },
      { token = "[m] model", action = pick_model },
      { token = "[r] effort", action = pick_reasoning },
    }
    for _, control in ipairs(controls) do
      local first, last = lines_for_panel()[1]:find(control.token, 1, true)
      if first and mouse.column >= first and mouse.column <= last then
        control.action()
        return
      end
    end
  end, { buffer = state.buffer, desc = "Click a Codex toolbar control" })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = state.input_buffer,
    callback = function()
      update_placeholder()
      vim.bo[state.input_buffer].modified = false
    end,
    desc = "Update Codex composer placeholder",
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = state.input_buffer,
    callback = function()
      if vim.fn.mode() == "i" then
        vim.cmd.stopinsert()
      end
    end,
    desc = "Leave Codex insert mode before switching windows",
  })
  update_placeholder()
  M.render()
end

function M.open()
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    vim.api.nvim_set_current_win(state.window)
  else
    local source_buf = vim.api.nvim_get_current_buf()
    local source_name = vim.api.nvim_buf_get_name(source_buf)
    if source_name ~= "" and source_buf ~= state.buffer and source_buf ~= state.input_buffer then
      state.source_path = source_name
      state.source_line = vim.api.nvim_win_get_cursor(0)[1]
    end
    create_ui()
  end
  if not state.job then
    start_server()
  end
  if state.input_window and vim.api.nvim_win_is_valid(state.input_window) then
    vim.api.nvim_set_current_win(state.input_window)
    vim.cmd.startinsert()
  end
end

function M.close()
  if state.input_window and vim.api.nvim_win_is_valid(state.input_window) then
    pcall(vim.api.nvim_win_close, state.input_window, true)
  end
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    pcall(vim.api.nvim_win_close, state.window, true)
  end
  state.input_window = nil
  state.window = nil
end

function M.toggle()
  if state.window and vim.api.nvim_win_is_valid(state.window) then
    M.close()
  else
    M.open()
  end
end

function M.command(args)
  local action = args.args
  if action == "login" then
    if not state.job then
      state.login_after_init = true
      M.open()
    elseif state.initialized then
      set_account_login()
    else
      state.login_after_init = true
    end
  elseif action == "new" then
    new_thread()
  elseif action == "chats" then
    thread_picker()
  elseif action == "model" then
    pick_model()
  elseif action == "reasoning" then
    pick_reasoning()
  else
    M.toggle()
  end
end

function M.setup()
  vim.api.nvim_create_user_command("CodexPanel", M.command, {
    nargs = "?",
    complete = function()
      return { "login", "new", "chats", "model", "reasoning" }
    end,
    desc = "Open the native Codex chat panel",
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if state.job then
        vim.fn.jobstop(state.job)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    callback = function()
      vim.schedule(function()
        resize_composer()
        M.render()
      end)
    end,
    desc = "Resize Codex composer and chat layout with its panel",
  })
end

return M
