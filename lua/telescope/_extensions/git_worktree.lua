local strings = require("plenary.strings")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local actions = require("telescope.actions")
local utils = require("telescope.utils")
local action_set = require("telescope.actions.set")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config").values
local git_worktree = require("git-worktree")

local force_next_deletion = false

local wt_actions = {}

local get_worktree_path = function(prompt_bufnr)
    local selection = action_state.get_selected_entry(prompt_bufnr)
    return selection.path
end

local switch_worktree = function(prompt_bufnr)
    local worktree_path = get_worktree_path(prompt_bufnr)
    actions.close(prompt_bufnr)
    if worktree_path ~= nil then
        git_worktree.switch_worktree(worktree_path)
    end
end

wt_actions.toggle_forced_deletion = function()
    -- redraw otherwise the message is not displayed when in insert mode
    if force_next_deletion then
        print("The next deletion will not be forced")
        vim.fn.execute("redraw")
    else
        print("The next deletion will be forced")
        vim.fn.execute("redraw")
        force_next_deletion = true
    end
end

local delete_success_handler = function()
    force_next_deletion = false
end

local delete_failure_handler = function()
    print("Deletion failed, use <C-f> to force the next deletion")
end

local ask_to_confirm_deletion = function(forcing)
    if forcing then
        return vim.fn.input("Force deletion of worktree? [y/n]: ")
    end

    return vim.fn.input("Delete worktree? [y/n]: ")
end

local confirm_deletion = function(forcing)
    if not git_worktree._config.confirm_telescope_deletions then
        return true
    end

    local confirmed = ask_to_confirm_deletion(forcing)

    if string.sub(string.lower(confirmed), 0, 1) == "y" then
        return true
    end

    print("Didn't delete worktree")
    return false
end

wt_actions.delete_worktree = function(prompt_bufnr)
    if not confirm_deletion() then
        return
    end

    local worktree_path = get_worktree_path(prompt_bufnr)
    actions.close(prompt_bufnr)
    if worktree_path ~= nil then
        git_worktree.delete_worktree(worktree_path, force_next_deletion, {
            on_failure = delete_failure_handler,
            on_success = delete_success_handler,
        })
    end
end

local use_current_worktree_as_base_prompt = function()
    return vim.fn.confirm("Use current worktree as base?", "&Yes\n&No", 1) == 1
end

local get_base_branch = function(opts, name, branch)
    local base_branch_selection_opts = opts or {}
    base_branch_selection_opts.attach_mappings = function()
        actions.select_default:replace(function(prompt_bufnr, _)
            local selected_entry = action_state.get_selected_entry()
            local current_line = action_state.get_current_line()

            actions.close(prompt_bufnr)

            local base_branch = selected_entry ~= nil and selected_entry.value or current_line

            git_worktree.create_worktree(name, branch, nil, base_branch)
        end)

        -- do we need to replace other default maps?

        return true
    end
    require("telescope.builtin").git_branches(base_branch_selection_opts)
end

local pconf = {
    mappings = {
        ["i"] = {
            ["<C-d>"] = wt_actions.delete_worktree,
            ["<C-f>"] = wt_actions.toggle_forced_deletion,
        },
        ["n"] = {
            ["<C-d>"] = wt_actions.delete_worktree,
            ["<C-f>"] = wt_actions.toggle_forced_deletion,
        },
    },
    attach_mappings = function(_, _)
        action_set.select:replace(switch_worktree)
        return true
    end,
}

local get_default_opts = function(opts)
    opts = opts or {}
    local defaults = (function()
        if pconf.theme then
            return require("telescope.themes")["get_" .. pconf.theme](pconf)
        end
        return vim.deepcopy(pconf)
    end)()

    if pconf.mappings then
        defaults.attach_mappings = function(prompt_bufnr, map)
            if pconf.attach_mappings then
                pconf.attach_mappings(prompt_bufnr, map)
            end
            for mode, tbl in pairs(pconf.mappings) do
                for key, action in pairs(tbl) do
                    map(mode, key, action)
                end
            end
            return true
        end
    end

    if opts.attach_mappings then
        local opts_attach = opts.attach_mappings
        opts.attach_mappings = function(prompt_bufnr, map)
            defaults.attach_mappings(prompt_bufnr, map)
            return opts_attach(prompt_bufnr, map)
        end
    end
    return vim.tbl_deep_extend("force", defaults, opts)
end

local create_worktree = function(opts)
    local branch_selection_opts = get_default_opts(opts)
    branch_selection_opts.attach_mappings = function()
        actions.select_default:replace(function(prompt_bufnr, _)
            local selected_entry = action_state.get_selected_entry()
            local current_line = action_state.get_current_line()

            actions.close(prompt_bufnr)

            local branch = selected_entry ~= nil and selected_entry.value or current_line

            if branch == nil then
                return
            end

            -- for some reason this prompt immediately returns so we have to add another one to
            -- actually accept user input
            vim.fn.input("Path to subtree > ", branch)
            local name = vim.fn.input("Path to subtree > ", branch)
            if name == "" then
                name = branch
            end

            if string.match(name, '/') == nil and git_worktree._config.base_directory then
                name = git_worktree._config.base_directory .. name
            end

            local has_branch = git_worktree.has_branch(branch)

            if not has_branch then
                if use_current_worktree_as_base_prompt() then
                    git_worktree.create_worktree(name, branch)
                else
                    get_base_branch(opts, name, branch)
                end
            else
                git_worktree.create_worktree(name, branch)
            end
        end)

        -- do we need to replace other default maps?

        return true
    end
    require("telescope.builtin").git_branches(branch_selection_opts)
end

local telescope_git_worktree = function(opts)
    opts = get_default_opts(opts)
    local output = utils.get_os_command_output({ "git", "worktree", "list" })
    local results = {}

    local items = vim.F.if_nil(opts.items, {
        { "branch", 0 },
        { "path", 0 },
        { "sha", 0 },
    })
    local displayer_items = {}

    local parse_line = function(line)
        local fields = vim.split(string.gsub(line, "%s+", " "), " ")
        local entry = {
            path = fields[1],
            sha = fields[2],
            branch = fields[3],
        }

        if entry.sha ~= "(bare)" then
            local index = #results + 1
            for key, item in ipairs(items) do
                if not opts.items then
                    if item[1] == "path" then
                        -- Some users have found that transform_path raises an error because telescope.state#get_status
                        -- outputs an empty table. When that happens, we need to use the default value.
                        -- This seems to happen in distros such as AstroNvim and NvChad
                        --
                        -- Reference: https://github.com/ThePrimeagen/git-worktree.nvim/issues/97
                        local transformed_ok, new_path = pcall(utils.transform_path, opts, entry[item[1]])

                        if transformed_ok then
                            local path_len = strings.strdisplaywidth(new_path or "")
                            item[2] = math.max(item[2], path_len)
                        else
                            item[2] = math.max(item[2], strings.strdisplaywidth(entry[item[1]] or ""))
                        end
                    else
                        item[2] = math.max(item[2], strings.strdisplaywidth(entry[item[1]] or ""))
                    end
                end
                displayer_items[key] = { width = item[2] }
            end

            table.insert(results, index, entry)
        end
    end

    for _, line in ipairs(output) do
        parse_line(line)
    end

    if #results == 0 then
        error("No git branches found")
        return
    end

    local displayer = require("telescope.pickers.entry_display").create({
        separator = " ",
        items = displayer_items,
    })

    local make_display = function(entry)
        local foo = {}
        for _, item in ipairs(items) do
            if item[1] == "branch" then
                table.insert(foo, { entry[item[1]], "TelescopeResultsIdentifier" })
            elseif item[1] == "path" then
                table.insert(foo, { utils.transform_path(opts, entry[item[1]]) })
            elseif item[1] == "sha" then
                table.insert(foo, { entry[item[1]] })
            else
                error("Invalid git-worktree entry item: " .. tostring(item[1]))
            end
        end
        return displayer(foo)
    end

    pickers
        .new(opts or {}, {
            prompt_title = opts.prompt_title or "Git Worktrees",
            finder = finders.new_table({
                results = results,
                entry_maker = function(entry)
                    entry.value = entry.branch
                    entry.ordinal = entry.branch
                    entry.display = make_display
                    return entry
                end,
            }),
            sorter = conf.generic_sorter(opts),
        })
        :find()
end

local git_worktree_setup = function(opts)
    pconf.mappings = vim.tbl_deep_extend("force", pconf.mappings, require("telescope.config").values.mappings)
    pconf = vim.tbl_deep_extend("force", pconf, opts)
end

return require("telescope").register_extension({
    setup = git_worktree_setup,
    exports = {
        git_worktree = telescope_git_worktree,
        git_worktrees = telescope_git_worktree,
        create_git_worktree = create_worktree,
        actions = wt_actions,
    },
})
