local wezterm = require("wezterm")
local act = wezterm.action
local mux = wezterm.mux

local M = {}

--- Platform detection
local is_windows = string.find(wezterm.target_triple, "windows") ~= nil

--- User configuration storage
local user_config = {}

--- Default configuration options
local default_options = {
  --- Default icons for different workspace types
  icons = {
    directory = "📁",
    worktree = "🌳",
    zoxide = "⚡",
    workspace = "🖥️",
  },
  --- Default colors for different workspace types
  colors = {
    directory = "#61afef", -- Blue
    worktree = "#98c379", -- Green
    zoxide = "#e5c07b", -- Yellow
    workspace = "#c678dd", -- Purple
  },
  --- Whether to use fuzzy matching in the workspace selector
  fuzzy = true,
  --- Sort order in fuzzy mode: "current_first" (current at top, previous second),
  --- "previous_first" (previous at top, current second), or "none" (no reordering)
  fuzzy_sort = "previous_first",
}

--- Current options (merged with defaults)
local options = {}

-- Track workspace history for "switch to previous workspace" functionality
local last_active_workspace = nil
local current_active_workspace = nil

--- Helper to safely get the active workspace name for a window
--- @param window table: WezTerm window object
--- @return string|nil: active workspace name or nil
local function get_window_active_workspace(window)
  if not window then
    return nil
  end

  -- Try window:active_workspace() if available
  local ok, name = pcall(function()
    return window:active_workspace()
  end)
  if ok and type(name) == "string" and name ~= "" then
    return name
  end

  -- Fallback to mux.get_active_workspace()
  local ok2, name2 = pcall(function()
    return mux.get_active_workspace()
  end)
  if ok2 and type(name2) == "string" and name2 ~= "" then
    return name2
  end

  return nil
end

--- Expand tilde (~) in paths to home directory
--- @param path string: Path that may contain ~
--- @return string|nil: Expanded path or nil if home directory cannot be determined
--- @return string|nil: Error message if expansion fails
local function expand_home_path(path)
  if not path or type(path) ~= "string" then
    return nil, "Invalid path: expected string"
  end

  if path:sub(1, 1) == "~" then
    local home = wezterm.home_dir
    if not home then
      return nil, "Unable to determine home directory"
    end
    path = home .. path:sub(2)
  end
  return path, nil
end

--- Run shell command and return output with proper error handling
--- @param cmd string: Command to execute
--- @return string: Command output (empty string on error)
--- @return string|nil: Error message if command failed
local function run_command(cmd)
  if not cmd or type(cmd) ~= "string" then
    return "", "Invalid command: expected string"
  end

  local args = { os.getenv("SHELL"), "-l", "-c", cmd }
  if is_windows then
    args = { "cmd", "/c", cmd }
  end

  local ok, stdout, stderr = wezterm.run_child_process(args)
  if not ok then
    local error_msg = string.format("Failed to run '%s': %s", cmd, stderr or "unknown error")
    wezterm.log_error(error_msg)
    return "", error_msg
  end

  return stdout or "", nil
end

--- Create a formatted label for a workspace entry
--- @param path string: Path to format
--- @param icon string: Icon to use
--- @param workspace_type string: Type of workspace (directory, worktree, zoxide, workspace)
--- @return table: WezTerm formatted text
local function format_workspace_label(path, icon, workspace_type)
  local display_path = path:gsub(wezterm.home_dir or "", "~")

  -- Get color from options, fallback to defaults, then to light gray
  local color = options.colors and options.colors[workspace_type]
    or default_options.colors[workspace_type]
    or "#abb2bf"

  return wezterm.format({
    { Foreground = { Color = color } },
    { Text = icon .. "  " .. display_path },
  })
end

--- Get static and worktree-based workspace entries from user configuration
--- @return table: List of workspace entries
local function get_config_entries()
  local entries = {}

  for _, entry in ipairs(user_config) do
    if entry.type == "worktreeroot" then
      -- Handle git worktree root
      local expanded_path, err = expand_home_path(entry.path)
      if not expanded_path then
        wezterm.log_error(
          "Failed to expand worktree path '" .. entry.path .. "': " .. (err or "unknown error")
        )
      else
        local output, cmd_err =
          run_command("git -C " .. expanded_path .. " worktree list --porcelain")
        if cmd_err then
          wezterm.log_error("Failed to get worktrees for '" .. expanded_path .. "': " .. cmd_err)
        else
          for line in output:gmatch("[^\r\n]+") do
            if line:match("^worktree ") then
              local worktree_path = line:match("^worktree (.+)$")
              if worktree_path and worktree_path ~= expanded_path then
                table.insert(entries, {
                  id = worktree_path,
                  label = format_workspace_label(worktree_path, options.icons.worktree, "worktree"),
                  type = "worktree",
                  tabs = entry.tabs,
                })
              end
            end
          end
        end
      end
    elseif entry.path then
      -- Handle static directory entry
      local expanded_path, err = expand_home_path(entry.path)
      if not expanded_path then
        wezterm.log_error(
          "Failed to expand path '" .. entry.path .. "': " .. (err or "unknown error")
        )
      else
        table.insert(entries, {
          id = expanded_path,
          label = format_workspace_label(expanded_path, options.icons.directory, "directory"),
          type = "directory",
          tabs = entry.tabs,
        })
      end
    end
  end

  return entries
end

--- Get zoxide-tracked directory sessions
--- @return table: List of zoxide workspace entries
local function get_zoxide_sessions()
  local sessions = {}
  local output, err = run_command("zoxide query -l")

  if err then
    wezterm.log_warn("Zoxide not available or failed: " .. err)
    return sessions
  end

  for line in output:gmatch("[^\r\n]+") do
    if line and line ~= "" then
      table.insert(sessions, {
        id = line,
        label = format_workspace_label(line, options.icons.zoxide, "zoxide"),
        type = "zoxide",
        tabs = nil,
      })
    end
  end

  return sessions
end

--- Get existing WezTerm workspace names
--- @return table: List of existing workspace entries
local function get_existing_workspaces()
  local workspaces = {}
  local names = mux.get_workspace_names()

  for _, name in ipairs(names or {}) do
    table.insert(workspaces, {
      id = name,
      label = format_workspace_label(name, options.icons.workspace, "workspace"),
      type = "workspace",
      tabs = nil,
    })
  end

  return workspaces
end

--- Get all available workspace choices, deduplicating by ID
--- @return table: Array of workspace choice objects
local function get_all_workspace_choices()
  local all_items = {}
  local seen_ids = {} -- Track seen IDs to avoid duplicates

  --- Add items to the list, skipping duplicates
  --- @param items table: Array of workspace items to add
  local function add_unique_items(items)
    for _, item in ipairs(items or {}) do
      if item.id and not seen_ids[item.id] then
        table.insert(all_items, item)
        seen_ids[item.id] = true
      end
    end
  end

  -- Add items in priority order (existing workspaces first, then configured, then zoxide)
  add_unique_items(get_existing_workspaces())
  add_unique_items(get_config_entries())
  add_unique_items(get_zoxide_sessions())

  -- When fuzzy mode is enabled, optionally reorder current/previous workspace
  if options.fuzzy and options.fuzzy_sort ~= "none" then
    local current_item = nil
    local previous_item = nil

    for _, item in ipairs(all_items) do
      if
        current_active_workspace
        and item.id == current_active_workspace
        and item.type == "workspace"
      then
        current_item = item
      elseif
        last_active_workspace
        and item.id == last_active_workspace
        and item.type == "workspace"
      then
        previous_item = item
      end
    end

    local first, second
    if options.fuzzy_sort == "previous_first" then
      first, second = previous_item, current_item
    else
      first, second = current_item, previous_item
    end

    local reordered = {}
    if first then
      table.insert(reordered, first)
    end
    if second then
      table.insert(reordered, second)
    end
    for _, item in ipairs(all_items) do
      if (not first or item.id ~= first.id) and (not second or item.id ~= second.id) then
        table.insert(reordered, item)
      end
    end
    return reordered
  end

  return all_items
end

--- Compute sequential split sizes using weight logic.
--- Each pane may define `size` as a positive number weight. Omitted => weight 1.
--- Final space is distributed proportionally to weights.
--- @param panes table
--- @return table: size values for successive split calls
local function compute_split_sizes(panes)
  if not panes or #panes < 2 then
    return {}
  end

  local weights = {}
  local total = 0
  for i, p in ipairs(panes) do
    local w = p.size
    if type(w) ~= "number" or w <= 0 then
      if w ~= nil then
        wezterm.log_error("Invalid pane size (must be positive number weight): index " .. i)
      end
      w = 1
    end
    weights[i] = w
    total = total + w
  end

  -- Convert weights to final fractions
  local fractions = {}
  for i, w in ipairs(weights) do
    fractions[i] = w / total
  end

  -- Convert target final fractions to sequential split sizes.
  -- For pane i (i>=2): size = tail_sum(i) / tail_sum(i-1)
  local sizes = {}
  for i = 2, #fractions do
    local tail = 0
    for k = i, #fractions do
      tail = tail + fractions[k]
    end
    local prev_tail = tail + fractions[i - 1]
    local split_size = prev_tail > 0 and (tail / prev_tail) or 0.5
    table.insert(sizes, split_size)
  end

  return sizes
end

--- Recursively create pane splits based on configuration
--- @param mux_pane table: WezTerm mux pane object
--- @param node table: Pane configuration node
local function create_pane_splits(mux_pane, node)
  -- Base case: leaf node with optional command
  if not node or not node.panes or #node.panes == 0 then
    if node and node.command then
      mux_pane:send_text(node.command .. "\r")
    end
    return
  end

  -- Validate node structure
  if not node.panes or type(node.panes) ~= "table" then
    wezterm.log_error("Invalid pane configuration: 'panes' must be a table")
    return
  end

  local fractions = compute_split_sizes(node.panes)
  local current_pane = mux_pane

  for i, pane_config in ipairs(node.panes) do
    if i > 1 then
      -- Create split for additional panes
      local direction = node.direction or "Right"
      local size = fractions[i - 1]

      current_pane = current_pane:split({
        direction = direction,
        size = size,
      })

      if not current_pane then
        wezterm.log_error("Failed to create pane split")
        return
      end
    end

    -- Recursively process child panes
    create_pane_splits(current_pane, pane_config)
  end
end

--- Create tabs with their pane configurations
--- @param window table: WezTerm window object
--- @param tabs table: Array of tab configurations
local function create_tabs_with_panes(window, tabs)
  if not window then
    wezterm.log_error("Window is nil in create_tabs_with_panes")
    return
  end

  if not tabs or type(tabs) ~= "table" then
    wezterm.log_error("Invalid tabs configuration: expected table")
    return
  end

  for i, tab_config in ipairs(tabs) do
    if i > 1 then
      -- Create additional tabs
      window:spawn_tab({ title = tab_config.name })
    end

    -- Get the first pane of the current tab
    local window_tabs = window:tabs()
    if not window_tabs or not window_tabs[i] then
      wezterm.log_error("Failed to access tab " .. i)
      return
    end

    local tab = window_tabs[i]
    local panes = tab:panes()
    if not panes or not panes[1] then
      wezterm.log_error("Failed to access first pane of tab " .. i)
      return
    end

    local first_pane = panes[1]
    create_pane_splits(first_pane, tab_config)
  end

  -- focus on the first tab again once done
  local first_tab = window:tabs()[1]
  first_tab:activate()
end

--- Create or switch to a workspace with proper configuration
--- @param item table: Workspace item with id, type, and tabs
--- @param window table: WezTerm window object
--- @param pane table: WezTerm pane object
local function create_or_switch_workspace(item, window, pane)
  local active = get_window_active_workspace(window)
  if active then
    if current_active_workspace ~= active then
      last_active_workspace = current_active_workspace
      current_active_workspace = active
    end
  end

  if item.type == "workspace" then
    window:perform_action(
      act.SwitchToWorkspace({
        name = item.id,
      }),
      pane
    )
    local new_active = item.id
    if new_active and new_active ~= current_active_workspace then
      last_active_workspace = current_active_workspace
      current_active_workspace = new_active
    end
  else
    local cwd, err = expand_home_path(item.id)
    if err then
      wezterm.log_error("Failed to expand workspace path '" .. item.id .. "': " .. err)
      cwd = item.id -- fallback to original path
    end

    window:perform_action(
      act.SwitchToWorkspace({
        name = item.id,
        spawn = {
          cwd = expand_home_path(item.id),
        },
      }),
      pane
    )

    local new_active = item.id
    if new_active and new_active ~= current_active_workspace then
      last_active_workspace = current_active_workspace
      current_active_workspace = new_active
    end

    if item.tabs and #item.tabs > 0 then
      create_tabs_with_panes(new_window, item.tabs)
    end
  end
end

--- Switch to or create a workspace by name or path
--- @param path string: Workspace name or path to switch to
--- @return table: WezTerm action callback
function M.switch_to_workspace(path)
  return wezterm.action_callback(function(window, pane)
    local expanded_path = expand_home_path(path)

    -- Look for configured workspace
    local all_choices = get_all_workspace_choices()
    for _, choice in ipairs(all_choices) do
      if choice.id == expanded_path then
        create_or_switch_workspace(choice, window, pane)
        return
      end
    end
  end)
end

--- Create the workspace switcher action
--- @return table: WezTerm action callback
function M.switch_workspace_action()
  return wezterm.action_callback(function(window, pane)
    local choices = get_all_workspace_choices()

    -- Convert to input selector format
    local selector_choices = {}
    for _, choice in ipairs(choices) do
      table.insert(selector_choices, {
        id = choice.id,
        label = choice.label,
      })
    end

    window:perform_action(
      act.InputSelector({
        title = "Select Workspace",
        choices = selector_choices,
        fuzzy = options.fuzzy,
        action = wezterm.action_callback(function(win, p, id, label)
          if not id then
            return
          end

          -- Find the selected item
          local selected_item = nil
          for _, choice in ipairs(choices) do
            if choice.id == id then
              selected_item = choice
              break
            end
          end
          wezterm.log_info("Selected workspace: " .. selected_item.id)

          if not selected_item then
            wezterm.log_error("Selected workspace not found: " .. id)
            return
          end

          create_or_switch_workspace(selected_item, win, p)
        end),
      }),
      pane
    )
  end)
end

--- Switch to previously active workspace
--- @return table: WezTerm action callback
function M.switch_to_previous_workspace()
  return wezterm.action_callback(function(window, pane)
    if not last_active_workspace or last_active_workspace == "" then
      wezterm.log_info("No previously active workspace recorded")
      return
    end

    -- Find matching choice among all known workspaces; if not found, treat as name
    local choices = get_all_workspace_choices()
    local found = nil
    for _, choice in ipairs(choices) do
      if choice.id == last_active_workspace then
        found = choice
        break
      end
    end

    if found then
      create_or_switch_workspace(found, window, pane)
    else
      -- If choice isn't found, attempt a direct switch by name
      window:perform_action(act.SwitchToWorkspace({ name = last_active_workspace }), pane)
      -- update history after switch
      local new_active = last_active_workspace
      if new_active and new_active ~= current_active_workspace then
        last_active_workspace = current_active_workspace
        current_active_workspace = new_active
      end
    end
  end)
end

--- Validate a single workspace configuration entry
--- @param entry table: Configuration entry to validate
--- @return boolean: True if valid
--- @return string|nil: Error message if invalid
local function validate_config_entry(entry)
  if type(entry) ~= "table" then
    return false, "Configuration entry must be a table"
  end

  if not entry.path then
    return false, "'path' is required for each workspace entry"
  end

  if entry.type and entry.type ~= "directory" and entry.type ~= "worktreeroot" then
    return false, "Invalid type '" .. entry.type .. "'. Must be 'directory' or 'worktreeroot'"
  end

  if entry.tabs and type(entry.tabs) ~= "table" then
    return false, "'tabs' must be a table if provided"
  end

  return true, nil
end

--- Setup the workspace picker with user configuration
--- @param config table: User configuration table
--- @param opts table|nil: Additional options to override defaults
function M.setup(config, opts)
  -- Merge options with defaults
  options = {}
  for k, v in pairs(default_options) do
    options[k] = v
  end
  if opts then
    for k, v in pairs(opts) do
      options[k] = v
    end
  end

  -- Validate and process configuration
  user_config = {}
  if config and type(config) == "table" then
    for i, entry in ipairs(config) do
      local is_valid, error_msg = validate_config_entry(entry)
      if not is_valid then
        wezterm.log_error(string.format("Configuration entry %d: %s", i, error_msg))
      else
        -- Set default type if not specified
        if not entry.type then
          entry.type = "directory"
        end

        -- Ensure tabs is a table
        if not entry.tabs then
          entry.tabs = {}
        end

        table.insert(user_config, entry)
      end
    end
  end

  -- initialize current active workspace if available
  current_active_workspace = get_window_active_workspace(
    wezterm.gui and wezterm.gui.get_window and wezterm.gui.get_window() or nil
  ) or mux.get_active_workspace()
end

--- @param config table: WezTerm configuration table
function M.apply_to_config(config) end

return M
