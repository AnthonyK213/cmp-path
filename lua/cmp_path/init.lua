local cmp = require("cmp")

local IS_WIN = (vim.fn.has("win32") == 1) or (vim.fn.has("win64") == 1)
local NAME_REGEX = "\\%([^/\\\\:\\*?<>'\"`\\|]\\)"
local PATH_REGEX

if IS_WIN then
	PATH_REGEX =
		vim.regex(([[\%(\%([/\\]PAT*[^/\\\\:\\*?<>\'"`\\|@ .~]\)\|\%(/\.\.\)\)*[/\\]\zePAT*$]]):gsub("PAT", NAME_REGEX))
else
	PATH_REGEX =
		vim.regex(([[\%(\%(/PAT*[^/\\\\:\\*?<>\'"`\\|@ .~]\)\|\%(/\.\.\)\)*/\zePAT*$]]):gsub("PAT", NAME_REGEX))
end

local source = {}

local constants = {
	max_lines = 20,
}

---@class cmp_path.Option
---@field public trailing_slash boolean
---@field public label_trailing_slash boolean
---@field public get_cwd fun(params): string
---@field public path_mappings table

---@type cmp_path.Option
local defaults = {
	trailing_slash = false,
	label_trailing_slash = true,
	get_cwd = function(params)
		return vim.fn.expand(("#%d:p:h"):format(params.context.bufnr))
	end,
	path_mappings = {},
}

source.new = function()
	return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
	if IS_WIN then
		return { "/", ".", "\\" }
	else
		return { "/", "." }
	end
end

source.get_keyword_pattern = function()
	return NAME_REGEX .. "*"
end

source.complete = function(self, params, callback)
	local option = self:_validate_option(params)
	local current_directory = vim.fn.getcwd() or ""
	local path_mappings = option.path_mappings
	local allCandidates = {}
	local addedPaths = {}

	local function processAlias(alias, value)
		if type(value) == "string" then
			local alias_string = string.gsub(value, "${folder}", current_directory, 1)
			if vim.fn.isdirectory(alias_string) == 0 then
				return callback()
			end

			self:get_candidates(params, alias, alias_string, option, function(candidates)
				if type(candidates) == "table" then
					for _, candidate in ipairs(candidates) do
						local path = candidate.data.path
						if not addedPaths[path] then
							table.insert(allCandidates, candidate)
							addedPaths[path] = true
						end
					end
				end
			end)
		end
	end

	for alias, value in pairs(path_mappings) do
		processAlias(alias, value)
	end

	callback(allCandidates)
end

source.get_candidates = function(self, params, alias, alias_string, option, callback)
	local dirname = self:_dirname(params, alias, alias_string, option)
	if not dirname then
		return callback()
	end

	local include_hidden = string.sub(params.context.cursor_before_line, params.offset, params.offset) == "."
	self:_candidates(dirname, include_hidden, option, function(err, candidates)
		if err then
			return callback()
		end
		callback(candidates)
	end)
end

source.resolve = function(self, completion_item, callback)
	local data = completion_item.data
	if data.stat and data.stat.type == "file" then
		local ok, documentation = pcall(function()
			return self:_get_documentation(data.path, constants.max_lines)
		end)
		if ok then
			completion_item.documentation = documentation
		end
	end
	callback(completion_item)
end

source._dirname = function(self, params, alias, alias_string, option)
	local replaced_string = params.context.cursor_before_line
		:gsub("'" .. alias, "'" .. alias_string, 1)
		:gsub('"' .. alias, '"' .. alias_string, 1)

	local s = PATH_REGEX:match_str(replaced_string)
	if not s then
		return nil
	end

	local dirname = string.gsub(string.sub(replaced_string, s + 2), "%a*$", "") -- exclude '/'
	local prefix = string.sub(replaced_string, 1, s + 1) -- include '/'
	local iscmdl = vim.api.nvim_get_mode().mode == "c"

	local buf_dirname = option.get_cwd(params)
	if iscmdl then
		buf_dirname = vim.fn.getcwd()
	end
	if prefix:match("%.%.[/\\]$") then
		return vim.fn.resolve(buf_dirname .. "/../" .. dirname)
	end
	if prefix:match("%.[/\\]$") or prefix:match('"$') or prefix:match("'$") then
		return vim.fn.resolve(buf_dirname .. "/" .. dirname)
	end
	if prefix:match("~[/\\]$") then
		return vim.fn.resolve(vim.fn.expand("~") .. "/" .. dirname)
	end
	local env_var_name = prefix:match("%$([%a_]+)[/\\]$")
	if not iscmdl and not env_var_name then
		env_var_name = prefix:match("%${([%a_]+)}[/\\]$")
		if IS_WIN and not env_var_name then
			env_var_name = prefix:match("%%([%a_]+)%%[/\\]$")
		end
	end
	if env_var_name then
		local env_var_value = vim.fn.getenv(env_var_name)
		if env_var_value ~= vim.NIL then
			return vim.fn.resolve(env_var_value .. "/" .. dirname)
		end
	end
	if IS_WIN then
		local driver = prefix:match("(%a:)[/\\]$")
		if driver then
			return vim.fn.resolve(driver .. "/" .. dirname)
		end
	end
	if prefix:match("/$") then
		local accept = true
		-- Ignore URL components
		accept = accept and not prefix:match("%a/$")
		-- Ignore URL scheme
		accept = accept and not prefix:match("%a+:/$") and not prefix:match("%a+://$")
		-- Ignore HTML closing tags
		accept = accept and not prefix:match("</$")
		-- Ignore math calculation
		accept = accept and not prefix:match("[%d%)]%s*/$")
		-- Ignore / comment
		accept = accept and (not prefix:match("^[%s/]*$") or not self:_is_slash_comment())
		if accept then
			return vim.fn.resolve("/" .. dirname)
		end
	end
	return nil
end

source._candidates = function(_, dirname, include_hidden, option, callback)
	local fs, err = vim.loop.fs_scandir(dirname)
	if err then
		return callback(err, nil)
	end

	local items = {}

	local function create_item(name, fs_type)
		if not (include_hidden or string.sub(name, 1, 1) ~= ".") then
			return
		end

		local path = dirname .. "/" .. name
		local stat = vim.loop.fs_stat(path)
		local lstat = nil
		if stat then
			fs_type = stat.type
		elseif fs_type == "link" then
			-- Broken symlink
			lstat = vim.loop.fs_lstat(dirname)
			if not lstat then
				return
			end
		else
			return
		end

		local item = {
			label = name,
			filterText = name,
			insertText = name,
			kind = cmp.lsp.CompletionItemKind.File,
			data = {
				path = path,
				type = fs_type,
				stat = stat,
				lstat = lstat,
			},
		}
		if fs_type == "directory" then
			item.kind = cmp.lsp.CompletionItemKind.Folder
			if option.label_trailing_slash then
				item.label = name .. "/"
			else
				item.label = name
			end
			item.insertText = name .. "/"
			if not option.trailing_slash then
				item.word = name
			end
		end
		table.insert(items, item)
	end

	while true do
		local name, fs_type, e = vim.loop.fs_scandir_next(fs)
		if e then
			return callback(fs_type, nil)
		end
		if not name then
			break
		end
		create_item(name, fs_type)
	end

	callback(nil, items)
end

source._is_slash_comment = function(_)
	local commentstring = vim.bo.commentstring or ""
	local no_filetype = vim.bo.filetype == ""
	local is_slash_comment = false
	is_slash_comment = is_slash_comment or commentstring:match("/%*")
	is_slash_comment = is_slash_comment or commentstring:match("//")
	return is_slash_comment and not no_filetype
end

---@return cmp_path.Option
source._validate_option = function(_, params)
	local option = vim.tbl_deep_extend("keep", params.option, defaults)
	vim.validate({
		trailing_slash = { option.trailing_slash, "boolean" },
		label_trailing_slash = { option.label_trailing_slash, "boolean" },
		get_cwd = { option.get_cwd, "function" },
		path_mappings = { option.path_mappings, "table" },
	})
	return option
end

source._get_documentation = function(_, filename, count)
	local binary = assert(io.open(filename, "rb"))
	local first_kb = binary:read(1024)
	if first_kb:find("\0") then
		return { kind = cmp.lsp.MarkupKind.PlainText, value = "binary file" }
	end

	local contents = {}
	for content in first_kb:gmatch("[^\r\n]+") do
		table.insert(contents, content)
		if count ~= nil and #contents >= count then
			break
		end
	end

	local filetype = vim.filetype.match({ filename = filename })
	if not filetype then
		return { kind = cmp.lsp.MarkupKind.PlainText, value = table.concat(contents, "\n") }
	end

	table.insert(contents, 1, "```" .. filetype)
	table.insert(contents, "```")
	return { kind = cmp.lsp.MarkupKind.Markdown, value = table.concat(contents, "\n") }
end

return source
