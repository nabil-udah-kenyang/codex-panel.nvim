local M = {}

function M.setup(codex)
  require("dressing").setup({
    input = { enabled = false },
    select = {
      enabled = true,
      backend = { "telescope", "builtin" },
      builtin = { show_numbers = false },
    },
  })


  -- Keep the scrolling transcript, pinned controls, and attachment UI together.
  local state
  local original_render = codex.render
  local original_close = codex.close

  local function get_upvalue(fn, wanted)
    local index = 1
    while true do
      local name, value = debug.getupvalue(fn, index)
      if not name then
        return nil
      end
      if name == wanted then
        return value, index
      end
      index = index + 1
    end
  end

  state = get_upvalue(original_render, "state")

  local footer_height = 2
  local footer_highlight_sources = {
    CodexPanelFooterUsage = "BranchName",
    CodexPanelFooterPercent = "PercentageText",
    CodexPanelFooterReset = "DiagWarn",
    CodexPanelFooterModelLabel = "ModeText",
    CodexPanelFooterModel = "FileText",
    CodexPanelFooterReasoning = "FileType",
    CodexPanelFooterEmail = "StGitBlame",
    CodexPanelFooterSeparator = "Separator2",
    CodexPanelFooterPlan = "DiagHint",
  }
  local footer_highlight_names = {
    BranchName = "CodexPanelFooterUsage",
    PercentageText = "CodexPanelFooterPercent",
    DiagWarn = "CodexPanelFooterReset",
    ModeText = "CodexPanelFooterModelLabel",
    FileText = "CodexPanelFooterModel",
    FileType = "CodexPanelFooterReasoning",
    StGitBlame = "CodexPanelFooterEmail",
    Separator2 = "CodexPanelFooterSeparator",
    DiagHint = "CodexPanelFooterPlan",
  }
  local footer_fallback_colors = {
    BranchName = "#69bfce",
    PercentageText = "#5599e2",
    DiagWarn = "#e5c07b",
    ModeText = "#956dca",
    FileText = "#f4f3ee",
    FileType = "#e37e4f",
    StGitBlame = "#7a8599",
    Separator2 = "#3a435a",
    DiagHint = "#98c379",
  }
  local function refresh_footer_highlights()
    for target, source in pairs(footer_highlight_sources) do
      local source_highlight = vim.api.nvim_get_hl(0, { name = source, link = false })
      local target_highlight = {
        fg = source_highlight.fg or footer_fallback_colors[source],
        bg = "NONE",
      }
      for _, attribute in ipairs({ "bold", "italic", "underline", "undercurl", "strikethrough", "sp" }) do
        if source_highlight[attribute] ~= nil then
          target_highlight[attribute] = source_highlight[attribute]
        end
      end
      vim.api.nvim_set_hl(0, target, target_highlight)
    end
  end
  refresh_footer_highlights()
  local footer_highlights_group = vim.api.nvim_create_augroup("CodexPanelFooterHighlights", { clear = true })
  vim.api.nvim_create_autocmd({ "ColorScheme", "ModeChanged" }, {
    group = footer_highlights_group,
    callback = refresh_footer_highlights,
    desc = "Keep Codex footer text in sync with the statusline palette without backgrounds",
  })
  local update_attachment_marks
  local update_image_preview

  local function as_text(value, fallback)
    if value == nil or value == vim.NIL then
      return fallback or ""
    end
    return type(value) == "string" and value or tostring(value)
  end

  local function usage_bucket()
    local usage = type(state.usage) == "table" and state.usage or nil
    if not usage then
      return nil
    end
    local buckets = type(usage.rateLimitsByLimitId) == "table" and usage.rateLimitsByLimitId or nil
    local codex_bucket = buckets and buckets.codex
    if type(codex_bucket) == "table" then
      return codex_bucket
    end
    for _, bucket in pairs(buckets or {}) do
      if type(bucket) == "table" then
        return bucket
      end
    end
    return type(usage.rateLimits) == "table" and usage.rateLimits or nil
  end

  local function format_usage_window(window)
    if type(window) ~= "table" or type(window.usedPercent) ~= "number" then
      return nil
    end
    local duration = tonumber(window.windowDurationMins)
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
    local reset = ""
    if type(window.resetsAt) == "number" then
      local seconds = math.max(0, window.resetsAt - os.time())
      if seconds >= 86400 then
        reset = " · reset " .. math.floor(seconds / 86400) .. "d"
      elseif seconds >= 3600 then
        reset = " · reset " .. math.floor(seconds / 3600) .. "h"
      elseif seconds > 0 then
        reset = " · reset " .. math.max(1, math.floor(seconds / 60)) .. "m"
      else
        reset = " · resetting"
      end
    end
    return string.format("%s %d%% left%s", label, remaining, reset)
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
    local usage = type(state.usage) == "table" and state.usage or nil
    local credits = usage and usage.rateLimitResetCredits
    if type(credits) == "table" and type(credits.availableCount) == "number"
        and credits.availableCount > 0 then
      windows[#windows + 1] = credits.availableCount .. " reset credit"
        .. (credits.availableCount == 1 and "" or "s")
    end
    return #windows > 0 and ("Usage: " .. table.concat(windows, "  ·  "))
      or "Usage: unavailable"
  end

  local function capitalize(value)
    value = as_text(value, "Default")
    return value:sub(1, 1):upper() .. value:sub(2)
  end

  local function truncate(text, width)
    if vim.fn.strdisplaywidth(text) <= width then
      return text
    end
    if width <= 1 then
      return "…"
    end
    return vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end

  local function footer_lines(width)
    local model = state.model
    local model_name = model
        and as_text(model.displayName or model.model or model.id, "Default")
      or "Default"
    local model_text = "Model: " .. model_name .. " " .. capitalize(state.reasoning_effort)
    local usage_text = usage_summary()
    local available = math.max(12, width - 4)
    local gap = "   "
    local first = truncate(usage_text, math.floor(available * 0.56))
    local remaining = available - vim.fn.strdisplaywidth(first) - vim.fn.strdisplaywidth(gap)
    local second = truncate(model_text, math.max(1, remaining))
    local line = "  " .. first .. gap .. second

    local account = state.account
    local email = account and as_text(account.email, "ChatGPT") or nil
    local plan = account and as_text(account.planType, "active") or nil
    local identity = account and (email .. " · " .. plan) or as_text(state.status, "Ready")
    identity = truncate(identity, math.max(1, width - 2))
    local identity_line = "  " .. identity
    local lines = { truncate(line, width), identity_line }
    local highlights = {}
    local function add_highlight(row, first_byte, last_byte, group)
      local text = lines[row + 1]
      first_byte = math.max(0, first_byte)
      last_byte = math.min(#text, last_byte)
      if last_byte > first_byte then
        highlights[#highlights + 1] = {
          row,
          first_byte,
          last_byte,
          footer_highlight_names[group] or group,
        }
      end
    end

    local usage_start = 2
    add_highlight(0, usage_start, usage_start + #first, "BranchName")
    local percent_start, percent_end = first:find("%d+%%")
    if percent_start then
      add_highlight(0, usage_start + percent_start - 1, usage_start + percent_end, "PercentageText")
    end
    local reset_start = first:find("reset", 1, true)
    if reset_start then
      add_highlight(0, usage_start + reset_start - 1, usage_start + #first, "DiagWarn")
    end

    local model_start = usage_start + #first + #gap
    local label_start, label_end = second:find("Model:", 1, true)
    if label_start then
      add_highlight(0, model_start + label_start - 1, model_start + label_end, "ModeText")
      local value_start = label_end + 2
      local reasoning = capitalize(state.reasoning_effort)
      local reasoning_start = second:find(" " .. reasoning .. "$", value_start)
      if reasoning_start then
        add_highlight(0, model_start + value_start - 1, model_start + reasoning_start - 1, "FileText")
        add_highlight(0, model_start + reasoning_start, model_start + #second, "FileType")
      else
        add_highlight(0, model_start + value_start - 1, model_start + #second, "FileText")
      end
    end

    if email then
      local email_end = math.min(#email, #identity)
      add_highlight(1, 2, 2 + email_end, "StGitBlame")
      local separator = " · "
      local separator_start = identity:find(separator, 1, true)
      if separator_start then
        local separator_col = 2 + separator_start - 1
        local plan_col = separator_col + #separator
        add_highlight(1, separator_col, plan_col, "Separator2")
        add_highlight(1, plan_col, 2 + #identity, "DiagHint")
      end
    else
      add_highlight(1, 2, #identity_line, "StGitBlame")
    end
    return lines, highlights
  end

  local function ensure_footer()
    if not state.window or not vim.api.nvim_win_is_valid(state.window) then
      return
    end
    if state.footer_window and vim.api.nvim_win_is_valid(state.footer_window) then
      return
    end
    state.footer_buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[state.footer_buffer].buftype = "nofile"
    vim.bo[state.footer_buffer].bufhidden = "wipe"
    vim.bo[state.footer_buffer].filetype = "codex_panel_footer"
    state.footer_window = vim.api.nvim_open_win(state.footer_buffer, false, {
      relative = "win",
      win = state.window,
      anchor = "NW",
      row = math.max(0, vim.api.nvim_win_get_height(state.window) - footer_height),
      col = 0,
      width = vim.api.nvim_win_get_width(state.window),
      height = footer_height,
      style = "minimal",
      focusable = false,
      zindex = 40,
    })
    vim.wo[state.footer_window].wrap = false
    vim.wo[state.footer_window].number = false
    vim.wo[state.footer_window].relativenumber = false
    vim.wo[state.footer_window].signcolumn = "no"
    vim.wo[state.footer_window].winhighlight = "Normal:Normal"
  end

  local function update_footer()
    ensure_footer()
    if not state.footer_window or not vim.api.nvim_win_is_valid(state.footer_window) then
      return
    end
    local width = vim.api.nvim_win_get_width(state.footer_window)
    local lines, highlights = footer_lines(width)
    vim.bo[state.footer_buffer].modifiable = true
    vim.api.nvim_buf_set_lines(state.footer_buffer, 0, -1, false, lines)
    vim.bo[state.footer_buffer].modifiable = false
    vim.api.nvim_buf_clear_namespace(state.footer_buffer, -1, 0, -1)
    for _, highlight in ipairs(highlights) do
      vim.api.nvim_buf_add_highlight(
        state.footer_buffer, -1, highlight[4], highlight[1], highlight[2], highlight[3]
      )
    end
  end

  local function resize_layout()
    if not state.window or not vim.api.nvim_win_is_valid(state.window) then
      return
    end
    if not state.input_window or not vim.api.nvim_win_is_valid(state.input_window) then
      return
    end

    local panel_width = vim.api.nvim_win_get_width(state.window)
    local panel_height = vim.api.nvim_win_get_height(state.window)
    local bordered = panel_width >= 12
    local col = bordered and 1 or 0
    local footer_row = math.max(0, panel_height - footer_height)
    local input_height = math.max(1, math.min(
      5,
      panel_height - footer_height - (bordered and 2 or 0)
    ))
    local input_frame_height = input_height + (bordered and 2 or 0)
    vim.api.nvim_win_set_config(state.input_window, {
      relative = "win",
      win = state.window,
      anchor = "NW",
      row = math.max(0, footer_row - input_frame_height),
      col = col,
      width = math.max(1, panel_width - (bordered and 2 or 0)),
      height = input_height,
      border = bordered and "rounded" or "none",
      style = "minimal",
    })
    ensure_footer()
    vim.api.nvim_win_set_config(state.footer_window, {
      relative = "win",
      win = state.window,
      anchor = "NW",
      row = footer_row,
      col = 0,
      width = panel_width,
      height = footer_height,
      style = "minimal",
      focusable = false,
      zindex = 40,
    })
    update_footer()
  end

  local function panel_lines()
    local panel_width = state.window and vim.api.nvim_win_is_valid(state.window)
        and vim.api.nvim_win_get_width(state.window) or 60
    local message_width = math.max(12, panel_width - 8)
    state.transcript_image_slots = {}
    local lines = {
      "  [c] chats  [n] new  [l] login  [m] model  [r] effort",
      "  <C-k> toolbar · <C-j> type · <C-v> paste image",
      "  <M-a> attach file · <M-x> remove last",
      "  :CodexPanelAttach [path] · :CodexPanelClearAttachments",
      "",
      "  " .. as_text(state.thread_name, "New chat"),
    }
    state.highlights = {
      { 0, "CodexPanelToolbar" },
      { 1, "CodexPanelMuted" },
      { 2, "CodexPanelMuted" },
      { 3, "CodexPanelMuted" },
      { 5, "CodexPanelSection" },
    }

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
      if #(item.images or {}) > 0 then
        lines[#lines + 1] = ""
        local image_row = #lines
        for image_index, path in ipairs(item.images) do
          state.transcript_image_slots[#state.transcript_image_slots + 1] = {
            path = path,
            row = image_row,
            reserve_space = image_index == 1,
          }
        end
        -- image.nvim maps normal-window positions through screenpos(),
        -- which returns column 0 when the target column is past EOL.
        -- Keep this spacer row as wide as the panel so images placed
        -- side by side remain addressable, even when the text is blank.
        lines[#lines + 1] = string.rep(" ", math.max(2, panel_width))
      end
    end
    lines[#lines + 1] = "  " .. as_text(state.status, "Ready") .. "   ·   <C-n> new  <C-p> chats  L login"
    state.highlights[#state.highlights + 1] = { #lines - 1, "CodexPanelMuted" }
    return lines
  end

  local function focus_composer()
    if state.input_window and vim.api.nvim_win_is_valid(state.input_window) then
      vim.api.nvim_set_current_win(state.input_window)
      vim.cmd.startinsert()
    end
  end

  local function attachment_name(path)
    return vim.fn.fnamemodify(path, ":t")
  end

  local function is_image_path(path)
    local lower = path:lower()
    return lower:match("%.png$")
      or lower:match("%.jpe?g$")
      or lower:match("%.gif$")
      or lower:match("%.webp$")
      or lower:match("%.bmp$")
      or lower:match("%.svg$")
      or lower:match("%.avif$")
  end

  local function image_mime(path)
    local lower = path:lower()
    if lower:match("%.jpe?g$") then
      return "image/jpeg"
    elseif lower:match("%.webp$") then
      return "image/webp"
    elseif lower:match("%.gif$") then
      return "image/gif"
    elseif lower:match("%.bmp$") then
      return "image/bmp"
    elseif lower:match("%.svg$") then
      return "image/svg+xml"
    elseif lower:match("%.avif$") then
      return "image/avif"
    end
    return "image/png"
  end

  local function image_input(path)
    local file = io.open(path, "rb")
    if not file then
      return { type = "localImage", path = path, detail = "auto" }
    end
    local data = file:read("*a")
    file:close()
    if not data or data == "" then
      return { type = "localImage", path = path, detail = "auto" }
    end
    return {
      type = "image",
      url = "data:" .. image_mime(path) .. ";base64," .. vim.base64.encode(data),
      detail = "auto",
    }
  end

  local function add_attachment(path, temporary)
    path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
    if path == "" or vim.fn.filereadable(path) == 0 then
      vim.notify("Codex: file not found: " .. path, vim.log.levels.WARN)
      return false
    end

    state.attachments = state.attachments or {}
    local name = attachment_name(path)
    local image = is_image_path(path)
    local input = image and image_input(path)
      or { type = "mention", name = name, path = path }
    state.attachments[#state.attachments + 1] = {
      name = name,
      path = path,
      input = input,
      image = image,
      temporary = temporary == true,
    }
    if temporary then
      state.temp_attachments = state.temp_attachments or {}
      state.temp_attachments[#state.temp_attachments + 1] = path
    end
    focus_composer()
    update_attachment_marks()
    return true
  end

  local function clipboard_types()
    local commands = {
      { "wl-paste", "--list-types" },
      { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
    }
    for _, command in ipairs(commands) do
      local ok, process = pcall(vim.system, command, { text = true })
      if ok then
        local result = process:wait()
        if result.code == 0 and result.stdout and result.stdout ~= "" then
          local types = {}
          for value in result.stdout:gmatch("[^\r\n]+") do
            types[#types + 1] = value
          end
          return command[1], types
        end
      end
    end
    return nil, {}
  end

  local function clipboard_image()
    local provider, types = clipboard_types()
    local preferred = { "image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp" }
    local selected
    for _, wanted in ipairs(preferred) do
      for _, available in ipairs(types) do
        if available == wanted then
          selected = wanted
          break
        end
      end
      if selected then
        break
      end
    end
    if not provider or not selected then
      return nil
    end

    local command
    if provider == "wl-paste" then
      command = { provider, "--no-newline", "--type", selected }
    else
      command = { provider, "-selection", "clipboard", "-t", selected, "-o" }
    end
    local ok, process = pcall(vim.system, command, { text = false })
    if not ok then
      return nil
    end
    local result = process:wait()
    if result.code ~= 0 or not result.stdout or result.stdout == "" then
      return nil
    end
    return result.stdout, selected
  end

  local function save_clipboard_image(data, mime)
    local extension = ({
      ["image/png"] = ".png",
      ["image/jpeg"] = ".jpg",
      ["image/webp"] = ".webp",
      ["image/gif"] = ".gif",
      ["image/bmp"] = ".bmp",
    })[mime] or ".png"
    local path = vim.fn.tempname() .. extension
    local file = io.open(path, "wb")
    if not file then
      vim.notify("Codex: could not create clipboard image file", vim.log.levels.ERROR)
      return nil
    end
    file:write(data)
    file:close()
    return path
  end

  local function clear_image_preview()
    for _, image in pairs(state.image_previews or {}) do
      pcall(image.clear, image)
    end
    state.image_previews = {}
    if state.image_preview_window and vim.api.nvim_win_is_valid(state.image_preview_window) then
      pcall(vim.api.nvim_win_close, state.image_preview_window, true)
    end
    state.image_preview_window = nil
    state.image_preview_buffer = nil
    state.image_preview_geometry = nil
  end

  local function clear_transcript_images()
    for _, image in pairs(state.transcript_images or {}) do
      pcall(image.clear, image)
    end
    state.transcript_images = {}
    state.transcript_image_count = 0
  end

  local function render_transcript_images()
    if not state.buffer or not vim.api.nvim_buf_is_valid(state.buffer)
        or not state.window or not vim.api.nvim_win_is_valid(state.window) then
      return
    end
    local slots = state.transcript_image_slots or {}
    if #slots == 0 then
      for index, image in pairs(state.transcript_images or {}) do
        pcall(image.clear, image)
        state.transcript_images[index] = nil
      end
      state.transcript_image_count = 0
      return
    end
    local ok, image_api = pcall(require, "image")
    if not ok or not image_api or (image_api.is_enabled and not image_api.is_enabled()) then
      return
    end

    state.transcript_images = state.transcript_images or {}
    local width = math.max(1, math.min(30, vim.api.nvim_win_get_width(state.window) - 4))
    local terminal_size
    local utils_ok, image_utils = pcall(require, "image/utils")
    if utils_ok and image_utils.term then
      terminal_size = image_utils.term.get_size()
    end
    local cell_ratio = terminal_size and terminal_size.cell_height > 0
        and terminal_size.cell_width > 0
        and (terminal_size.cell_height / terminal_size.cell_width) or 2
    local groups = {}
    for index, slot in ipairs(slots) do
      local group = groups[#groups]
      if not group or group.row ~= slot.row then
        group = { row = slot.row, items = {} }
        groups[#groups + 1] = group
      end
      group.items[#group.items + 1] = { index = index, slot = slot }
    end

    for _, group in ipairs(groups) do
      local images = {}
      for _, item in ipairs(group.items) do
        local index = item.index
        local slot = item.slot
        local path = vim.fn.fnamemodify(slot.path, ":p")
        local image = state.transcript_images[index]
        if image and image.original_path ~= path then
          pcall(image.clear, image)
          state.transcript_images[index] = nil
          image = nil
        end
        if not image then
          local image_ok
          image_ok, image = pcall(image_api.from_file, path, {
            id = "codex-panel-transcript-" .. tostring(state.buffer) .. "-" .. index,
            window = state.window,
            buffer = state.buffer,
            x = 2,
            y = group.row,
            width = 1,
            height = 1,
            inline = slot.reserve_space,
            with_virtual_padding = slot.reserve_space,
          })
          if not image_ok then
            image = nil
          end
          state.transcript_images[index] = image
        end
        if image then
          images[#images + 1] = {
            index = index,
            image = image,
            aspect = (tonumber(image.image_width) or 1)
              / math.max(1, tonumber(image.image_height) or 1) * cell_ratio,
            reserve_space = slot.reserve_space,
          }
        end
      end

      local image_height = 8
      local gap = 1
      local function image_widths(height)
        local widths, total = {}, math.max(0, #images - 1) * gap
        for index, entry in ipairs(images) do
          widths[index] = math.max(1, math.ceil(entry.aspect * height))
          total = total + widths[index]
        end
        return widths, total
      end
      local widths, total_width = image_widths(image_height)
      while image_height > 1 and total_width > width do
        image_height = image_height - 1
        widths, total_width = image_widths(image_height)
      end
      if total_width > width then
        local content_width = math.max(1, width - math.max(0, #images - 1) * gap)
        local aspect_total = 0
        for _, entry in ipairs(images) do
          aspect_total = aspect_total + entry.aspect
        end
        total_width = math.max(0, #images - 1) * gap
        for index, entry in ipairs(images) do
          widths[index] = math.max(1, math.floor(content_width * entry.aspect / aspect_total))
          total_width = total_width + widths[index]
        end
      end

      local image_x = 2
      for index, entry in ipairs(images) do
        local image = entry.image
        image.window = state.window
        image.buffer = state.buffer
        local image_inline = index == 1
        if image.inline ~= image_inline or image.with_virtual_padding ~= image_inline then
          pcall(image.clear, image, true)
          image.inline = image_inline
          image.with_virtual_padding = image_inline
        end
        local geometry = {
          x = image_x,
          y = group.row,
          width = widths[index],
          height = image_height,
        }
        local previous = image.geometry or {}
        local changed = previous.x ~= geometry.x or previous.y ~= geometry.y
          or previous.width ~= geometry.width or previous.height ~= geometry.height
        if changed and image.is_rendered and image_inline then
          pcall(image.clear, image, true)
        end
        if changed or not image.is_rendered then
          pcall(image.render, image, geometry)
        end
        image_x = image_x + widths[index] + gap
      end
    end
    for index = #slots + 1, state.transcript_image_count or 0 do
      local image = state.transcript_images[index]
      if image then
        pcall(image.clear, image)
      end
      state.transcript_images[index] = nil
    end
    state.transcript_image_count = #slots
  end

  update_image_preview = function()
    local image_paths = {}
    for _, attachment in ipairs(state.attachments or {}) do
      if attachment.image then
        image_paths[#image_paths + 1] = vim.fn.fnamemodify(attachment.path, ":p")
      end
    end
    if #image_paths == 0
        or not state.input_window
        or not vim.api.nvim_win_is_valid(state.input_window) then
      clear_image_preview()
      return
    end

    local ok, image_api = pcall(require, "image")
    if not ok or not image_api or (image_api.is_enabled and not image_api.is_enabled()) then
      return
    end

    local input_config = vim.api.nvim_win_get_config(state.input_window)
    if input_config.relative ~= "win" or input_config.win ~= state.window then
      return
    end
    -- The composer now uses an NW anchor relative to the transcript. Use
    -- that exact frame position so previews stay attached through redraws.
    local input_top = math.max(0, math.floor(input_config.row))
    local input_border = input_config.border ~= nil and input_config.border ~= "none" and 1 or 0
    local input_left = math.max(0, math.floor(input_config.col) + input_border)
    local panel_width = vim.api.nvim_win_get_width(state.window)
    local max_width = math.max(1, math.min(34, panel_width - 4))
    local max_height = math.max(1, math.min(6, input_top))
    local terminal_size
    local utils_ok, image_utils = pcall(require, "image/utils")
    if utils_ok and image_utils.term then
      terminal_size = image_utils.term.get_size()
    end
    local cell_ratio = terminal_size and terminal_size.cell_height > 0
        and terminal_size.cell_width > 0
        and (terminal_size.cell_height / terminal_size.cell_width) or 2

    state.image_previews = state.image_previews or {}
    local images = {}
    for index, path in ipairs(image_paths) do
      local image = state.image_previews[index]
      if image and image.original_path ~= path then
        pcall(image.clear, image)
        state.image_previews[index] = nil
        image = nil
      end
      if not image then
        local image_ok
        image_ok, image = pcall(image_api.from_file, path, {
          id = "codex-panel-attachment-preview-" .. tostring(index),
          max_width_window_percentage = 100,
          max_height_window_percentage = 100,
        })
        if not image_ok then
          image = nil
        end
        state.image_previews[index] = image
      end
      if image then
        local source_ratio = (tonumber(image.image_width) or 1)
          / math.max(1, tonumber(image.image_height) or 1)
        images[#images + 1] = {
          image = image,
          aspect = source_ratio * cell_ratio,
        }
      end
    end
    for index, image in pairs(state.image_previews) do
      if index > #image_paths then
        pcall(image.clear, image)
        state.image_previews[index] = nil
      end
    end
    if #images == 0 then
      clear_image_preview()
      return
    end

    -- Keep one horizontal strip. Reserve two tile slots from the outset,
    -- so adding the second image leaves the first image's geometry intact.
    local horizontal_gap = 1
    local tile_count = math.max(2, #images)
    local tile_width = math.max(1, math.floor((max_width - horizontal_gap * (tile_count - 1)) / tile_count))
    local preview_height = max_height
    local widths, positions = {}, {}
    local preview_width = 0
    for index, entry in ipairs(images) do
      local image_width = math.max(1, math.min(tile_width, math.ceil(entry.aspect * preview_height)))
      local x = preview_width > 0 and (preview_width + horizontal_gap) or 0
      widths[index] = image_width
      positions[index] = { x = x, y = 0 }
      preview_width = x + image_width
    end
    preview_width = math.min(max_width, preview_width)
    local preview_total_height = preview_height
    -- Place the preview in the parent panel, ending immediately above
    -- the composer's outer border.
    local relative = "win"
    local relative_win = state.window
    local row = math.max(0, input_top - preview_total_height)
    local col = input_left
    local geometry = {
      relative = relative,
      win = relative_win,
      row = row,
      col = col,
      width = preview_width,
      height = preview_total_height,
    }

    local window_recreated = not state.image_preview_window
      or not vim.api.nvim_win_is_valid(state.image_preview_window)
    local previous_geometry = state.image_preview_geometry or {}
    local preview_position_changed = previous_geometry.row ~= row or previous_geometry.col ~= col
    if window_recreated then
      if state.image_preview_window and vim.api.nvim_win_is_valid(state.image_preview_window) then
        pcall(vim.api.nvim_win_close, state.image_preview_window, true)
      end
      state.image_preview_buffer = vim.api.nvim_create_buf(false, true)
      vim.bo[state.image_preview_buffer].buftype = "nofile"
      vim.bo[state.image_preview_buffer].bufhidden = "wipe"
      vim.bo[state.image_preview_buffer].filetype = "codex_panel_image_preview"
      state.image_preview_window = vim.api.nvim_open_win(state.image_preview_buffer, false, {
        relative = relative,
        win = relative_win,
        row = row,
        col = col,
        width = preview_width,
        height = preview_total_height,
        border = "none",
        style = "minimal",
        focusable = false,
        zindex = 45,
      })
      vim.wo[state.image_preview_window].number = false
      vim.wo[state.image_preview_window].relativenumber = false
      vim.wo[state.image_preview_window].signcolumn = "no"
      vim.wo[state.image_preview_window].winhighlight = "Normal:Normal,FloatBorder:FloatBorder"
    else
      if previous_geometry.row ~= row or previous_geometry.col ~= col
          or previous_geometry.width ~= preview_width or previous_geometry.height ~= preview_total_height then
        vim.api.nvim_win_set_config(state.image_preview_window, {
          relative = relative,
          win = relative_win,
          row = row,
          col = col,
          width = preview_width,
          height = preview_total_height,
          border = "none",
          style = "minimal",
          focusable = false,
          zindex = 45,
        })
      end
    end
    state.image_preview_geometry = geometry

    for index, entry in ipairs(images) do
      local image = entry.image
      image.window = state.image_preview_window
      image.buffer = state.image_preview_buffer
      local image_geometry = {
        x = positions[index].x,
        y = positions[index].y,
        width = widths[index],
        height = preview_height,
      }
      local previous = image.geometry or {}
      local changed = previous.x ~= image_geometry.x or previous.y ~= image_geometry.y
        or previous.width ~= image_geometry.width or previous.height ~= image_geometry.height
      if window_recreated or preview_position_changed or changed or not image.is_rendered then
        pcall(image.render, image, image_geometry)
      end
    end
  end

  local function paste_clipboard()
    local data, mime = clipboard_image()
    if data then
      local path = save_clipboard_image(data, mime)
      if path and add_attachment(path, true) then
        return
      end
    end
    local text = vim.fn.getreg("+")
    if text and text ~= "" then
      vim.api.nvim_paste(text, true, -1)
    else
      vim.notify("Codex: clipboard has no text or supported image", vim.log.levels.INFO)
    end
  end

  local function attach_file_prompt()
    vim.ui.input({ prompt = "Attach file: ", completion = "file" }, function(path)
      if path and vim.trim(path) ~= "" then
        add_attachment(path, false)
      else
        focus_composer()
      end
    end)
  end

  local function clear_last_attachment()
    state.attachments = state.attachments or {}
    local attachment = table.remove(state.attachments)
    if attachment and attachment.temporary then
      vim.fn.delete(attachment.path)
    end
    focus_composer()
    update_attachment_marks()
  end

  update_attachment_marks = function()
    if not state.input_buffer or not vim.api.nvim_buf_is_valid(state.input_buffer) then
      return
    end
    state.attachments = state.attachments or {}
    if #state.attachments == 0 then
      update_image_preview()
      return
    end
    update_image_preview()
  end

  local function ensure_attachment_ui()
    if not state.input_buffer or not vim.api.nvim_buf_is_valid(state.input_buffer) then
      return
    end
    if state.attachment_ui_buffer == state.input_buffer then
      update_attachment_marks()
      return
    end
    state.attachments = state.attachments or {}
    state.attachment_ui_ready = true
    state.attachment_ui_buffer = state.input_buffer
    vim.keymap.set({ "n", "i" }, "<C-v>", paste_clipboard, {
      buffer = state.input_buffer,
      desc = "Paste text or attach clipboard image to Codex",
    })
    vim.keymap.set({ "n", "i" }, "<M-v>", paste_clipboard, {
      buffer = state.input_buffer,
      desc = "Paste text or attach clipboard image to Codex",
    })
    vim.keymap.set({ "n", "i" }, "<C-S-v>", paste_clipboard, {
      buffer = state.input_buffer,
      desc = "Paste text or attach clipboard image to Codex",
    })
    vim.keymap.set({ "n", "i" }, "<M-a>", attach_file_prompt, {
      buffer = state.input_buffer,
      desc = "Attach a file to Codex",
    })
    vim.keymap.set({ "n", "i" }, "<M-x>", clear_last_attachment, {
      buffer = state.input_buffer,
      desc = "Remove the last Codex attachment",
    })
    pcall(vim.api.nvim_del_user_command, "CodexPanelAttach")
    vim.api.nvim_create_user_command("CodexPanelAttach", function(command)
      local path = vim.trim(table.concat(command.fargs, " "))
      if path == "" then
        attach_file_prompt()
      else
        add_attachment(path, false)
      end
    end, { nargs = "*", complete = "file", desc = "Attach a file to Codex" })
    pcall(vim.api.nvim_del_user_command, "CodexPanelClearAttachments")
    vim.api.nvim_create_user_command("CodexPanelClearAttachments", function()
      state.attachments = {}
      update_attachment_marks()
      focus_composer()
    end, { desc = "Clear Codex attachments" })
    local preview_group = vim.api.nvim_create_augroup("CodexPanelAttachmentPreview", { clear = true })
    local preview_resize_pending = false
    local preview_restore_pending = false
    local function restore_image_overlays()
      if preview_restore_pending then
        return
      end
      preview_restore_pending = true
      vim.schedule(function()
        preview_restore_pending = false
        -- A transient float can cover Kitty placements. Invalidate only
        -- image.nvim's geometry cache and re-place the same image IDs;
        -- clearing first makes the previews visibly blink.
        if state.attachments and #state.attachments > 0
            and state.image_preview_window
            and vim.api.nvim_win_is_valid(state.image_preview_window) then
          for _, image in pairs(state.image_previews or {}) do
            image.window = state.image_preview_window
            image.buffer = state.image_preview_buffer
            image.rendered_geometry = { x = nil, y = nil, width = nil, height = nil }
            pcall(image.render, image)
          end
        end
        if state.transcript_image_count and state.transcript_image_count > 0 then
          for _, image in pairs(state.transcript_images or {}) do
            image.window = state.window
            image.buffer = state.buffer
            image.rendered_geometry = { x = nil, y = nil, width = nil, height = nil }
            pcall(image.render, image)
          end
        end
      end)
    end
    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      group = preview_group,
      callback = function()
        local has_attachments = state.attachments and #state.attachments > 0
        local has_transcript_images = state.transcript_image_count and state.transcript_image_count > 0
        if preview_resize_pending or (not has_attachments and not has_transcript_images) then
          return
        end
        preview_resize_pending = true
        vim.schedule(function()
          preview_resize_pending = false
          if has_attachments and state.input_buffer and vim.api.nvim_buf_is_valid(state.input_buffer) then
            pcall(update_image_preview)
          end
          pcall(render_transcript_images)
        end)
      end,
      desc = "Reposition Codex image previews after resize",
    })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = preview_group,
      callback = function()
        if (state.attachments and #state.attachments > 0)
            or (state.transcript_image_count and state.transcript_image_count > 0) then
          restore_image_overlays()
        end
      end,
      desc = "Restore Codex image previews after floating windows close",
    })
    update_attachment_marks()
  end

  local create_ui = get_upvalue(codex.open, "create_ui")
  local original_send_prompt = create_ui and get_upvalue(create_ui, "send_prompt")
  local original_rpc
  local rpc_index
  if original_send_prompt then
    original_rpc, rpc_index = get_upvalue(original_send_prompt, "rpc")
  end

  local function send_prompt_with_attachments()
    state.attachments = state.attachments or {}
    if #state.attachments > 0 then
      local prompt = vim.trim(table.concat(vim.api.nvim_buf_get_lines(
        state.input_buffer, 0, -1, false
      ), "\n"))
      if prompt == "" then
        vim.api.nvim_buf_set_lines(
          state.input_buffer, 0, -1, false,
          { "Please review the attached file(s)." }
        )
      end
    end
    original_send_prompt()
  end

  local function rpc_with_attachments(method, params, callback)
    if method == "turn/start" and state.attachments and #state.attachments > 0 then
      local sent = state.attachments
      params.input = params.input or {}
      local image_paths = {}
      local file_names = {}
      for _, attachment in ipairs(sent) do
        params.input[#params.input + 1] = attachment.input
        if attachment.image then
          image_paths[#image_paths + 1] = attachment.path
        else
          file_names[#file_names + 1] = attachment.name
        end
      end
      state.attachments = {}
      local last = state.output[#state.output]
      local labels = {}
      if last and last.role == "You" and #image_paths > 0 then
        last.images = last.images or {}
        vim.list_extend(last.images, image_paths)
      end
      if #file_names > 0 then
        labels[#labels + 1] = "[Files attached: " .. table.concat(file_names, ", ") .. "]"
      end
      if last and last.role == "You" and #labels > 0 then
        last.body = last.body .. "\n\n" .. table.concat(labels, "\n")
      end
      codex.render()
    end
    return original_rpc(method, params, callback)
  end

  if create_ui and original_send_prompt and rpc_index then
    debug.setupvalue(original_send_prompt, rpc_index, rpc_with_attachments)
    local send_prompt_index = select(2, get_upvalue(create_ui, "send_prompt"))
    if send_prompt_index then
      debug.setupvalue(create_ui, send_prompt_index, send_prompt_with_attachments)
    end
  end

  local render_lines_index = select(2, get_upvalue(original_render, "lines_for_panel"))
  if render_lines_index then
    debug.setupvalue(original_render, render_lines_index, panel_lines)
  end

  local setup_resize_index = select(2, get_upvalue(codex.setup, "resize_composer"))
  if setup_resize_index then
    debug.setupvalue(codex.setup, setup_resize_index, resize_layout)
  end

  local transcript_highlights_ns = vim.api.nvim_create_namespace("CodexPanelTranscriptHighlights")
  local function render_panel_preserving_images(...)
    local args = { ... }
    local api = vim.api
    local original_set_lines = api.nvim_buf_set_lines
    local original_clear_namespace = api.nvim_buf_clear_namespace
    local original_add_highlight = api.nvim_buf_add_highlight
    api.nvim_buf_set_lines = function(buf, first, last, strict, replacement)
      if buf ~= state.buffer or first ~= 0 or last ~= -1 then
        return original_set_lines(buf, first, last, strict, replacement)
      end
      local previous = api.nvim_buf_get_lines(buf, 0, -1, false)
      local prefix = 0
      while prefix < #previous and prefix < #replacement
          and previous[prefix + 1] == replacement[prefix + 1] do
        prefix = prefix + 1
      end
      local suffix = 0
      while suffix < #previous - prefix and suffix < #replacement - prefix
          and previous[#previous - suffix] == replacement[#replacement - suffix] do
        suffix = suffix + 1
      end
      if prefix == #previous and prefix == #replacement then
        return
      end
      local changed = {}
      for index = prefix + 1, #replacement - suffix do
        changed[#changed + 1] = replacement[index]
      end
      return original_set_lines(buf, prefix, #previous - suffix, strict, changed)
    end
    api.nvim_buf_clear_namespace = function(buf, namespace, first, last)
      if buf == state.buffer and namespace == -1 then
        namespace = transcript_highlights_ns
      end
      return original_clear_namespace(buf, namespace, first, last)
    end
    api.nvim_buf_add_highlight = function(buf, namespace, group, line, first, last)
      if buf == state.buffer and namespace == -1 then
        namespace = transcript_highlights_ns
      end
      return original_add_highlight(buf, namespace, group, line, first, last)
    end
    local ok, result = xpcall(function()
      return original_render(unpack(args))
    end, debug.traceback)
    api.nvim_buf_set_lines = original_set_lines
    api.nvim_buf_clear_namespace = original_clear_namespace
    api.nvim_buf_add_highlight = original_add_highlight
    if not ok then
      error(result)
    end
    return result
  end

  codex.render = function(...)
    local result = render_panel_preserving_images(...)
    ensure_attachment_ui()
    update_footer()
    render_transcript_images()
    return result
  end

  codex.close = function(...)
    clear_image_preview()
    clear_transcript_images()
    if state.footer_window and vim.api.nvim_win_is_valid(state.footer_window) then
      pcall(vim.api.nvim_win_close, state.footer_window, true)
    end
    state.footer_window = nil
    state.footer_buffer = nil
    state.attachments = {}
    state.attachment_ui_buffer = nil
    for _, path in ipairs(state.temp_attachments or {}) do
      if vim.fn.filereadable(path) == 1 then
        vim.fn.delete(path)
      end
    end
    state.temp_attachments = {}
    return original_close(...)
  end

  -- codex-panel creates its transcript as a `text` buffer, so Markdown
  -- responses (headings, lists, emphasis and code fences) are shown raw.
  -- Detect its distinctive toolbar after the panel has finished creating
  -- the buffer, then let markview render the transcript as Markdown.
  local group = vim.api.nvim_create_augroup("CodexPanelMarkdown", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function()
      vim.defer_fn(function()
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(bufnr)
            and vim.bo[bufnr].buftype == "nofile"
            and vim.bo[bufnr].filetype == "text"
          then
            local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
            if first_line:match("^%s*%[c%] chats") then
              vim.bo[bufnr].filetype = "markdown"
              for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
                vim.wo[winid].conceallevel = 2
                vim.wo[winid].concealcursor = "nc"
                vim.wo[winid].wrap = true
                vim.wo[winid].linebreak = true
                vim.wo[winid].breakindent = true
                vim.wo[winid].list = false
              end
            end
          end
        end
      end, 30)
    end,
    desc = "Render Codex panel responses as Markdown",
  })
end

return M

