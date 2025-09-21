--[[
文档_ https://github.com/hooke007/mpv_PlayKit/discussions/624

使用 MediaInfo 解析当前文件信息（不含外部或追加合并的轨道）并输出至OSD
]]

local mp = require "mp"
mp.options = require "mp.options"
mp.utils = require "mp.utils"

local user_opt = {
	load = true,
	key_scroll_up = "UP",
	key_scroll_down = "DOWN",
	key_scroll_pgup = "PGUP",
	key_scroll_pgdwn = "PGDWN",
	key_refresh = "",

	mediainfo_path = "MediaInfo",
	verbose = false,
	network = false,

	font_mono = "Consolas",
	font_size = 28,
	font_size2 = 20,
	font_size3 = 14,
	font_size4 = 12,
	indent_size = 2,
	max_lines = 22,
	extraspaces = 24,
}

mp.options.read_options(user_opt)

if user_opt.load == false then
	mp.msg.info("脚本已被初始化禁用")
	return
end
-- 原因：没测过更老掉牙的版本
local min_major = 0
local min_minor = 36
local min_patch = 0
local mpv_ver_curr = mp.get_property_native("mpv-version", "unknown")
local function incompat_check(full_str, tar_major, tar_minor, tar_patch)
	if full_str == "unknown" then
		return true
	end

	local clean_ver_str = full_str:gsub("^[^%d]*", "")
	local major, minor, patch = clean_ver_str:match("^(%d+)%.(%d+)%.(%d+)")
	major = tonumber(major)
	minor = tonumber(minor)
	patch = tonumber(patch or 0)
	if major < tar_major then
		return true
	elseif major == tar_major then
		if minor < tar_minor then
			return true
		elseif minor == tar_minor then
			if patch < tar_patch then
				return true
			end
		end
	end

	return false
end
if incompat_check(mpv_ver_curr, min_major, min_minor, min_patch) then
	mp.msg.warn("当前mpv版本 (" .. (mpv_ver_curr or "未知") .. ") 低于 " .. min_major .. "." .. min_minor .. "." .. min_patch .. "，已终止脚本。")
	return
end

local msg = require "mp.msg"
local overlay = nil
local visible = false
local all_lines = {}
local scroll_offset = 0

local cache = {}
local clipboard_cache = {}
local current_path = nil
local is_loading = false
local is_fresh_load = true  -- Track if current data is freshly loaded

local sp_fields = {
	["url"] = true,
	["CodecID_Url"] = true,
	["Format_Extensions"] = true,
	["Format_url"] = true,
	["Format_Url"] = true,
	["UniqueID"] = true,
	["UniqueID_String"] = true,
	["Encoded_Library"] = true,
	["Encoded_Library_Name"] = true,
	["Encoded_Library_String"] = true,
	["Encoded_Library_Version"] = true,
	["HDR_Format_String"] = true,
	["MD5_Unencoded"] = true,
}

local path_fields = {
	["CompleteName"] = true,
	["FolderName"] = true,
	["FilePath"] = true,
	["FileName"] = true,
	["FileNameExtension"] = true,
	["DirectoryName"] = true,
	["Path"] = true,
	["Source"] = true,
	["Cover_Data"] = true,
}

local function escape_ass(str)
	if not str then return "" end
	str = tostring(str)
	str = str:gsub("\\", "\\\\")
	str = str:gsub("{", "\\{")
	str = str:gsub("}", "\\}")
	str = str:gsub("\n", " ")
	str = str:gsub("\r", " ")
	return str
end

local function format_value(key, value)
	if not value then return "" end
	value = tostring(value)
	if path_fields[key] then
		value = value:gsub("\\", "/")
	end
	return escape_ass(value)
end

local function get_alignment_spacing(key)
	if user_opt.extraspaces <= 0 then
		return ""
	end
	local spaces_needed = user_opt.extraspaces - string.len(key)
	if spaces_needed <= 0 then
		return ""
	end
	return string.rep("\\h", spaces_needed)
end

local function get_indent(level)
	return string.rep("\\h", level * user_opt.indent_size)
end

local function get_font_size_for_field(key)
	if sp_fields[key] then
		return user_opt.font_size2
	elseif path_fields[key] then
		return user_opt.font_size3
	elseif key == "Encoded_Library_Settings" or key == "Encoding_settings" then
		return user_opt.font_size4
	else
		return nil
	end
end

local function wrap_with_font_size(value, key)
	local font_size = get_font_size_for_field(key)
	if font_size then
		return "{\\fs" .. font_size .. "}" .. value .. "{\\fs" .. user_opt.font_size .. "}"
	else
		return value
	end
end

local function process_json_tree(data, level, lines)
	level = level or 0
	lines = lines or {}
	local indent = get_indent(level)

	if type(data) == "table" then
		local is_array = false
		local max_index = 0
		for k, v in pairs(data) do
			if type(k) == "number" and k > 0 and math.floor(k) == k then
				is_array = true
				if k > max_index then max_index = k end
			else
				is_array = false
				break
			end
		end

		if is_array then
			for i = 1, max_index do
				if data[i] ~= nil then
					if type(data[i]) == "table" then
						if data[i]["@type"] then
							local track_type = data[i]["@type"]
							table.insert(lines, "")
							table.insert(lines, indent .. "{\\b1\\c&H00CC00&}[" .. track_type .. "]{\\c&H0080FF&\\b0}") -- 轨道类型标题

							local sorted_keys = {}
							for k, _ in pairs(data[i]) do
								if k ~= "@type" then
									table.insert(sorted_keys, k)
								end
							end
							table.sort(sorted_keys)

							for _, k in ipairs(sorted_keys) do
								local v = data[i][k]
								if type(v) == "table" then
									table.insert(lines, get_indent(level + 1) .. "{\\c&HFF66B2&}" .. escape_ass(k) .. ":{\\c&H0080FF&}")
									process_json_tree(v, level + 2, lines)
								else
									local value_str = format_value(k, v)
									if value_str ~= "" then
										local alignment = get_alignment_spacing(k)
										local formatted_value = wrap_with_font_size(value_str, k)
										table.insert(lines, get_indent(level + 1) .. "{\\c&HFF66B2&}" .. escape_ass(k) .. ":{\\c&H0080FF&}" .. alignment .. "\\h" .. formatted_value)
									end
								end
							end
						else
							process_json_tree(data[i], level, lines)
						end
					else
						table.insert(lines, indent .. "-" .. "\\h" .. escape_ass(data[i]))
					end
				end
			end
		else

			local sorted_keys = {}
			for k, _ in pairs(data) do
				table.insert(sorted_keys, k)
			end
			table.sort(sorted_keys)

			for _, k in ipairs(sorted_keys) do
				local v = data[k]
				if type(v) == "table" then
					if k == "media" and v.track then
						table.insert(lines, indent .. "{\\b1\\c&HFF8000&}MEDIA INFO{\\c&H0080FF&\\b0}") -- 次标题
						process_json_tree(v.track, level + 1, lines)
					else
						table.insert(lines, indent .. "{\\c&HFF66B2&}" .. escape_ass(k) .. ":{\\c&H0080FF&}")
						process_json_tree(v, level + 1, lines)
					end
				elseif type(v) == "boolean" then
					local alignment = get_alignment_spacing(k)
					table.insert(lines, indent .. "{\\c&HFF66B2&}" .. escape_ass(k) .. ":{\\c&H0080FF&}" .. alignment .. "\\h" .. (v and "Yes" or "No"))
				elseif v ~= nil then
					local value_str = format_value(k, v)
					if value_str ~= "" then
						local alignment = get_alignment_spacing(k)
						local formatted_value = wrap_with_font_size(value_str, k)
						table.insert(lines, indent .. "{\\c&HFF66B2&}" .. escape_ass(k) .. ":{\\c&H0080FF&}" .. alignment .. "\\h" .. formatted_value)
					end
				end
			end
		end
	else
		table.insert(lines, indent .. escape_ass(data))
	end

	return lines
end

local function parse_mediainfo_json(json_str)
	local success, result = pcall(mp.utils.parse_json, json_str)
	if not success then
		msg.error("parse_mediainfo_json: " .. tostring(result))
		return nil
	end
	return result
end

local function expand_path(path)
	if not path then return nil end
	local result = mp.command_native({"expand-path", path})
	if result then
		msg.verbose("expand_path: FM '" .. path .. "' TO '" .. result .. "'")
		return result
	else
		msg.warn("expand_path: " .. path)
		return path
	end
	return path
end

local function get_mediainfo_async(callback)
	local path = mp.get_property("path")
	if not path then
		msg.error("get_mediainfo_async: No file")
		callback(nil, "get_mediainfo_async: No file")
		return
	end

	if user_opt.network == false and path:match("^[a-zA-Z0-9]+://") then
		msg.info("get_mediainfo_async: Network stream parsing is disabled")
		callback(nil, "get_mediainfo_async: Network stream parsing is disabled")
		return
	end

	if cache[path] then
		msg.verbose("get_mediainfo_async: Using cache for: " .. path)
		is_fresh_load = false
		callback(cache[path], nil)
		return
	end

	is_loading = true
	is_fresh_load = true

	local mediainfo_executable = expand_path(user_opt.mediainfo_path)
	local args = {mediainfo_executable, "--Output=JSON"}
	if user_opt.verbose then
		table.insert(args, "--Full")
		msg.verbose("get_mediainfo_async: Verbose output")
	end
	table.insert(args, path)

	mp.command_native_async({
		name = "subprocess",
		args = args,
		capture_stdout = true,
		capture_stderr = true,
	}, function(success, result, error)
		is_loading = false

		if success and result.status == 0 then
			local parsed = parse_mediainfo_json(result.stdout)
			if parsed then
				cache[path] = parsed
				callback(parsed, nil)
			else
				callback(nil, "get_mediainfo_async: JSON parse error")
			end
		else
			local error_msg = error or result.error_string or "Unknown error"
			msg.error("get_mediainfo_async: mediainfo command failed: " .. error_msg)

			-- 模式 --Full 失败时返回一般模式
			if user_opt.verbose and not (success and result.status == 0) then
				msg.warn("get_mediainfo_async: try std output")

				args = {mediainfo_executable, "--Output=JSON", path}
				mp.command_native_async({
					name = "subprocess",
					args = args,
					capture_stdout = true,
					capture_stderr = true,
				}, function(success2, result2, error2)
					is_loading = false

					if success2 and result2.status == 0 then
						local parsed = parse_mediainfo_json(result2.stdout)
						if parsed then
							-- Store in cache
							cache[path] = parsed
							callback(parsed, nil)
						else
							callback(nil, "get_mediainfo_async: JSON parse error")
						end
					else
						callback(nil, error2 or result2.error_string or "get_mediainfo_async: get media info error")
					end
				end)
			else
				callback(nil, error_msg)
			end
		end
	end)
end

local function get_mediainfo_text_async(callback)
	local path = mp.get_property("path")
	if not path then
		msg.error("get_mediainfo_text_async: No file")
		callback(nil, "get_mediainfo_text_async: No file")
		return
	end

	if user_opt.network == false and path:match("^[a-zA-Z0-9]+://") then
		msg.info("get_mediainfo_text_async: Network stream parsing is disabled")
		callback(nil, "get_mediainfo_text_async: Network stream parsing is disabled")
		return
	end

	if clipboard_cache[path] then
		msg.verbose("get_mediainfo_text_async: Using cache for: " .. path)
		callback(clipboard_cache[path], nil)
		return
	end

	local mediainfo_executable = expand_path(user_opt.mediainfo_path)
	local args = {mediainfo_executable}
	if user_opt.verbose then
		table.insert(args, "--Full")
		msg.verbose("get_mediainfo_text_async: Verbose output enabled")
	end
	table.insert(args, path)

	mp.osd_message("get_mediainfo_text_async: Copying MediaInfo to clipboard...", 2)

	mp.command_native_async({
		name = "subprocess",
		args = args,
		capture_stdout = true,
		capture_stderr = true,
	}, function(success, result, error)
		if success and result.status == 0 then
			local text_output = result.stdout
			clipboard_cache[path] = text_output
			callback(text_output, nil)
		else
			local error_msg = error or result.error_string or "Unknown error"
			msg.error("get_mediainfo_text_async: mediainfo command failed: " .. error_msg)
			callback(nil, "get_mediainfo_text_async: mediainfo command failed: " .. error_msg)
		end
	end)
end

local function update_osd()
	if not overlay then
		overlay = mp.create_osd_overlay("ass-events")
	end

	if is_loading then
		overlay.data = "{\\rDefault\\an7\\b1\\bord1\\blur2\\fn" .. user_opt.font_mono .. "\\fs" .. user_opt.font_size .. "}" ..
						   "{\\b1}MediaInfo Tree{\\b0}\\N\\N" ..
						   "{\\c&HFF66B2&}Loading ...{\\c&H0080FF&}"
	elseif #all_lines == 0 then
		overlay.data = "{\\fs" .. user_opt.font_size .. "}No media information available"
	else
		local visible_lines = {}
		local start_line = scroll_offset + 1
		local end_line = math.min(scroll_offset + user_opt.max_lines, #all_lines)

		local header = "{\\fs" .. (user_opt.font_size + 2) .. "\\b1}MediaInfo Tree{\\b0\\fs" .. user_opt.font_size .. "}"
		if #all_lines > user_opt.max_lines then
			header = header .. "  {\\c&H808080&}[Lines " .. start_line .. "-" .. end_line .. " of " .. #all_lines .. "]{\\c&H0080FF&}"
		end

		if not is_fresh_load then
			header = header .. "  {\\c&HFF8000&}[Cached]{\\c&H0080FF&}"
		end

		table.insert(visible_lines, header)
		table.insert(visible_lines, "")

		for i = start_line, end_line do
			table.insert(visible_lines, all_lines[i])
		end

		overlay.data = "{\\rDefault\\an7\\b1\\bord1\\blur2\\fn" .. user_opt.font_mono .. "\\fs" .. user_opt.font_size .. "}" ..
						   table.concat(visible_lines, "\\N")
	end

	overlay:update()
end

local function load_mediainfo()
	all_lines = {}
	scroll_offset = 0

	if visible then
		update_osd()
	end

	get_mediainfo_async(function(info, error)
		if error then
			all_lines = {"{\\c&HFF0000&}Error: " .. error .. "{\\c&H0080FF&}"}
			msg.error("load_mediainfo: " .. error)
		elseif info then
			all_lines = process_json_tree(info, 0)
		else
			all_lines = {"{\\fs" .. user_opt.font_size .. "}Failed to get media information"}
		end

		if visible then
			update_osd()
		end
	end)
end

local function copy2clipboard()
	get_mediainfo_text_async(function(text, error)
		if text then
			mp.set_property("clipboard/text", text)
			mp.osd_message("copy2clipboard: MediaInfo text copied", 2)
			msg.info("copy2clipboard: MediaInfo text copied")
		else
			mp.osd_message("copy2clipboard: Error: " .. error, 3)
			msg.error("copy2clipboard: " .. error)
		end
	end)
end

local function clear_cache(path)
	if path then
		cache[path] = nil
		msg.verbose("clear_cache: " .. path)
	else
		cache = {}
		msg.verbose("clear_cache: all")
	end
end

local function scroll(direction)
	if not visible or #all_lines <= user_opt.max_lines then
		return
	end

	local old_offset = scroll_offset

	if direction == "up" then
		scroll_offset = math.max(0, scroll_offset - 1)
	elseif direction == "down" then
		scroll_offset = math.min(#all_lines - user_opt.max_lines, scroll_offset + 1)
	elseif direction == "pgup" then
		scroll_offset = math.max(0, scroll_offset - user_opt.max_lines)
	elseif direction == "pgdwn" then
		scroll_offset = math.min(#all_lines - user_opt.max_lines, scroll_offset + user_opt.max_lines)
	end

	if scroll_offset ~= old_offset then
		update_osd()
	end
end

local function add_dy_bindings()
	mp.add_forced_key_binding(user_opt.key_scroll_up, "stats_mediainfo_scroll_up", 
		function() scroll("up") end, {repeatable = true})
	mp.add_forced_key_binding(user_opt.key_scroll_down, "stats_mediainfo_scroll_down", 
		function() scroll("down") end, {repeatable = true})
	mp.add_forced_key_binding(user_opt.key_scroll_pgup, "stats_mediainfo_scroll_pgup", 
		function() scroll("pgup") end)
	mp.add_forced_key_binding(user_opt.key_scroll_pgdwn, "stats_mediainfo_scroll_pgdn", 
		function() scroll("pgdwn") end)
	if user_opt.key_refresh and user_opt.key_refresh ~= "" then
		mp.add_forced_key_binding(user_opt.key_refresh, "stats_mediainfo_refresh", force_refresh)
	end
end

local function remove_dy_bindings()
	mp.remove_key_binding("stats_mediainfo_scroll_up")
	mp.remove_key_binding("stats_mediainfo_scroll_down")
	mp.remove_key_binding("stats_mediainfo_scroll_pgup")
	mp.remove_key_binding("stats_mediainfo_scroll_pgdn")
	if user_opt.key_refresh and user_opt.key_refresh ~= "" then
		mp.remove_key_binding("stats_mediainfo_refresh")
	end
end

local function toggle_display()
	visible = not visible
	if visible then
		load_mediainfo()
		add_dy_bindings()
	else
		if overlay then
			overlay:remove()
		end
		remove_dy_bindings()
	end
end

local function on_file_loaded()
	local new_path = mp.get_property("path")
	if current_path and current_path ~= new_path then
		-- clear_cache(current_path) -- 只清理当前缓存
		clear_cache()
		clipboard_cache = {} -- 清空待粘贴文本的缓存
		msg.verbose("on_file_loaded: cache cleared")
	end
	current_path = new_path

	if visible then
		load_mediainfo()
	end
end

local function force_refresh()
	if visible then
		local path = mp.get_property("path")
		if path then
			clear_cache(path)
			clipboard_cache[path] = nil
			is_fresh_load = true
			load_mediainfo()
		end
	end
end

mp.register_event("file-loaded", on_file_loaded)
mp.add_key_binding(nil, "display_toggle", toggle_display)
mp.add_key_binding(nil, "copy2clipboard", copy2clipboard)
