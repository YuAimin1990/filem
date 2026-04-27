local cjson = require "cjson"
cjson.encode_empty_table_as_object(false)

local _M = {}

-- ==================== 配置 ====================

-- 从共享字典获取允许的根目录
local function get_allowed_roots()
    local config = ngx.shared.sidebar_config
    local roots_json = config and config:get("allowed_roots_arr")
    if roots_json then
        local ok, roots_arr = pcall(cjson.decode, roots_json)
        if ok and roots_arr then
            local roots = {}
            for _, r in ipairs(roots_arr) do roots[r] = true end
            return roots
        end
    end
    -- 回退默认值
    return {
        ["/usrdata"] = true,
        ["/mnt/usbdisk"] = true,
        ["/tmp"] = true,
    }
end

-- 允许访问的根目录（惰性加载）
local ALLOWED_ROOTS = nil
local function get_ALLOWED_ROOTS()
    if not ALLOWED_ROOTS then
        ALLOWED_ROOTS = get_allowed_roots()
    end
    return ALLOWED_ROOTS
end

-- 禁止访问的路径模式
local FORBIDDEN_PATTERNS = {
    "^/etc",
    "^/root",
    "^/var/log",
    "^/proc",
    "^/sys",
    "^/dev",
    "%.%.",  -- 路径遍历
}

-- 大小限制 (字节)
local LIMITS = {
    upload = 100 * 1024 * 1024,      -- 100MB
    pack = 500 * 1024 * 1024,        -- 500MB
    preview = 1024 * 1024,           -- 1MB
}

-- Windows预留设备名
local RESERVED_NAMES = {
    CON = true, PRN = true, AUX = true, NUL = true,
    COM1 = true, COM2 = true, COM3 = true, COM4 = true,
    COM5 = true, COM6 = true, COM7 = true, COM8 = true, COM9 = true,
    LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true,
    LPT5 = true, LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}

-- 可预览的文本文件扩展名
local PREVIEWABLE_EXTENSIONS = {
    txt = true, log = true, csv = true,
    json = true, xml = true, yaml = true, yml = true,
    lua = true, py = true, js = true, sh = true,
    conf = true, cfg = true, ini = true,
    md = true, rst = true,
    html = true, htm = true, css = true,
    sql = true,
    c = true, h = true, cpp = true, hpp = true,
    java = true, go = true, rs = true,
    properties = true,
}

-- MIME类型映射
local MIME_TYPES = {
    txt = "text/plain", log = "text/plain", csv = "text/csv",
    json = "application/json", xml = "application/xml",
    yaml = "text/plain", yml = "text/plain",
    lua = "text/plain", py = "text/plain", js = "text/plain", sh = "text/plain",
    conf = "text/plain", cfg = "text/plain", ini = "text/plain",
    md = "text/plain", rst = "text/plain",
    html = "text/html", htm = "text/html", css = "text/css",
    sql = "text/plain",
    c = "text/plain", h = "text/plain", cpp = "text/plain", hpp = "text/plain",
    java = "text/plain", go = "text/plain", rs = "text/plain",
    properties = "text/plain",
    jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png",
    gif = "image/gif", webp = "image/webp", svg = "image/svg+xml",
    pdf = "application/pdf",
    zip = "application/zip", tar = "application/x-tar",
    gz = "application/gzip", tgz = "application/gzip",
    bz2 = "application/x-bzip2", xz = "application/x-xz",
    bin = "application/octet-stream", dat = "application/octet-stream",
    exe = "application/octet-stream", so = "application/octet-stream",
}

local ILLEGAL_CHARS = '[/\\:?*"<>|]'

-- ==================== 工具函数 ====================

-- 获取当前 session
local function get_session()
    return ngx.ctx.session
end

-- 是否管理员
local function is_admin()
    return ngx.ctx.is_admin == true
end

-- 权限检查辅助（内部使用 auth 模块）
local function check_file_permission(path, required_action)
    local auth = require "monitor.view.auth"
    local session = get_session()
    if not session then
        return false, "未登录"
    end
    return auth.check_permission(session, path, required_action)
end

-- 使用 ngx.pipe 非阻塞执行 shell 命令
local function exec_cmd(cmd)
    local shell = require "resty.shell"

    -- 设置超时（毫秒）
    local timeout = 5000

    -- 使用 resty.shell 的 run 方法
    local ok, stdout, stderr, err = shell.run(cmd, nil, timeout)

    if not ok then
        local fh = io.open("/tmp/exec_err.log", "a")
        if fh then
            fh:write(os.date() .. " cmd=" .. cmd .. " err=" .. tostring(err) .. " stderr=" .. tostring(stderr) .. "\n")
            fh:close()
        end
        return false, "command failed: " .. (err or "unknown")
    end

    return true, stdout
end

local function url_decode(str)
    if not str then return nil end
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

local function is_hidden(name)
    return name:match("^%.") ~= nil
end

local function format_size(size)
    if size < 1024 then return size .. " B" end
    if size < 1024 * 1024 then return string.format("%.1f KB", size / 1024) end
    if size < 1024 * 1024 * 1024 then return string.format("%.1f MB", size / 1024 / 1024) end
    return string.format("%.1f GB", size / 1024 / 1024 / 1024)
end

-- ==================== 验证函数 ====================

function _M.validate_path(path)
    if not path or path == "" then
        return false, "路径不能为空"
    end
    
    path = url_decode(path) or path
    
    if path:match("%z") then
        return false, "路径包含非法字符"
    end
    
    if path:match("%.%.") then
        return false, "路径包含路径遍历攻击 (..)"
    end
    
    path = path:gsub("//+", "/")
    
    local allowed = false
    local allowed_roots = get_ALLOWED_ROOTS()
    for root, _ in pairs(allowed_roots) do
        if path == root or path:sub(1, #root + 1) == root .. "/" then
            allowed = true
            break
        end
    end
    
    if not allowed then
        return false, "访问被拒绝: 路径不在允许的范围内"
    end
    
    for _, pattern in ipairs(FORBIDDEN_PATTERNS) do
        if path:match(pattern) then
            return false, "访问被拒绝: 路径模式不允许"
        end
    end
    
    for part in path:gmatch("[^/]+") do
        if is_hidden(part) then
            return false, "访问被拒绝: 隐藏文件/目录"
        end
    end
    
    return true, nil
end

function _M.validate_filename(filename)
    if not filename or filename == "" then
        return false, "文件名不能为空"
    end
    
    if #filename > 255 then
        return false, "文件名过长 (最大255字符)"
    end
    
    if filename:match(ILLEGAL_CHARS) then
        return false, "文件名包含非法字符"
    end
    
    if is_hidden(filename) then
        return false, "不能创建隐藏文件"
    end
    
    local name_without_ext = filename:gsub("%.[^.]+$", ""):upper()
    if RESERVED_NAMES[name_without_ext] then
        return false, "文件名是系统保留名"
    end
    
    return true, nil
end

function _M.validate_upload_size(size)
    if not size or size <= 0 then
        return false, "文件大小无效"
    end
    if size > LIMITS.upload then
        return false, string.format("文件过大 (最大 %dMB)", LIMITS.upload / 1024 / 1024)
    end
    return true, nil
end

function _M.validate_pack_size(size)
    if not size or size <= 0 then
        return false, "打包大小无效"
    end
    if size > LIMITS.pack then
        return false, string.format("打包过大 (最大 %dMB)", LIMITS.pack / 1024 / 1024)
    end
    return true, nil
end

function _M.validate_preview_size(size)
    if not size or size <= 0 then
        return false, "文件大小无效"
    end
    if size > LIMITS.preview then
        return false, string.format("文件过大无法预览 (最大 %dMB)", LIMITS.preview / 1024 / 1024)
    end
    return true, nil
end

function _M.get_mime_type(filename)
    if not filename then
        return "application/octet-stream"
    end
    
    local ext = filename:match("%.([^.]+)$") or ""
    ext = ext:lower()
    
    if ext == "gz" or ext == "bz2" or ext == "xz" then
        local base = filename:match("%.tar%." .. ext .. "$")
        if base then
            ext = "tar_" .. ext
        end
    end
    
    return MIME_TYPES[ext] or "application/octet-stream"
end

function _M.can_preview_file(filename)
    if not filename then return false end
    
    local ext = filename:match("%.([^.]+)$") or ""
    ext = ext:lower()
    
    return PREVIEWABLE_EXTENSIONS[ext] == true
end

-- ==================== API响应 ====================

local function json_response(data, status)
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.status = status or 200
    local ok, encoded = pcall(cjson.encode, data)
    if not ok then
        ngx.status = 500
        ngx.say('{"code":-500,"message":"JSON encode error"}')
    else
        ngx.say(encoded)
    end
    return ngx.exit(ngx.OK)
end

-- ==================== 文件操作 ====================

-- 列出目录
function _M.handle_list(path)
    path = url_decode(path) or path
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end

    -- 权限检查：读权限
    if not is_admin() then
        local ok, err = check_file_permission(path, "read")
        if not ok then
            return json_response({ code = -403, message = err or "需要读权限" }, 403)
        end
    end

    -- 检查目录是否存在 (使用 ls -d，因为 io.open 不能打开目录)
    local check_cmd = string.format("ls -d '%s' 2>/dev/null", path:gsub("'", "'\''"))
    local check_handle = io.popen(check_cmd)
    local check_result = check_handle and check_handle:read("*a")
    if check_handle then check_handle:close() end
    if not check_result or check_result:gsub("%s+$", "") == "" then
        return json_response({ code = -404, message = "目录不存在" }, 404)
    end
    
    local cmd = string.format("ls -la '%s' 2>/dev/null", path:gsub("'", "'\\''"))
    local handle = io.popen(cmd)
    if not handle then
        return json_response({ code = -500, message = "无法读取目录" }, 500)
    end
    
    local items = {}
    for line in handle:lines() do
        -- 解析 ls -la 输出: drwxr-xr-x 2 user group 4096 Jan 1 00:00 name
        local perms, links, owner, group, size, month, day, time, name = 
            line:match("^([%-dl][rwxstST%-]+)%s+(%d+)%s+(%S+)%s+(%S+)%s+(%d+)%s+(%S+)%s+(%d+)%s+(%S+)%s+(.+)$")
        
        if name and name ~= "." and name ~= ".." and not is_hidden(name) then
            local item_type = perms:sub(1, 1) == "d" and "directory" or 
                             (perms:sub(1, 1) == "l" and "link" or "file")
            
            -- 获取修改时间戳 (使用 date 命令，设备没有 stat)
            local full_path = path .. "/" .. name
            local date_cmd = string.format("date +%%s -r '%s' 2>/dev/null", full_path:gsub("'", "'\\''"))
            local date_handle = io.popen(date_cmd)
            local mtime = 0
            if date_handle then
                mtime = tonumber(date_handle:read("*a")) or 0
                date_handle:close()
            end
            
            local item = {
                name = name,
                type = item_type,
                size = tonumber(size) or 0,
                size_formatted = format_size(tonumber(size) or 0),
                mtime = mtime,
                permissions = perms:sub(2),
            }
            
            if item_type == "file" then
                item.mime = _M.get_mime_type(name)
            end
            
            table.insert(items, item)
        end
    end
    handle:close()
    
    -- 排序: 目录在前，文件在后，按名称排序
    table.sort(items, function(a, b)
        if a.type == b.type then
            return a.name:lower() < b.name:lower()
        end
        return a.type == "directory"
    end)
    
    local parent = "/"
    if path ~= "/" then
        parent = path:match("^(.*)/[^/]+$") or "/"
    end
    
    return json_response({
        code = 0,
        data = {
            path = path,
            parent = parent,
            items = items
        }
    })
end

-- 下载文件
function _M.handle_download(path, inline)
    path = url_decode(path) or path
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end

    -- 权限检查：读权限
    if not is_admin() then
        local ok, err = check_file_permission(path, "read")
        if not ok then
            return json_response({ code = -403, message = err or "需要读权限" }, 403)
        end
    end

    local f = io.open(path, "rb")
    if not f then
        return json_response({ code = -404, message = "文件不存在" }, 404)
    end
    
    -- 检查是否为目录
    local content = f:read(1)
    if not content then
        f:close()
        return json_response({ code = -400, message = "无法读取文件" }, 400)
    end
    f:seek("set")
    
    local filename = path:match("[^/]+$") or "download"
    local mime = _M.get_mime_type(filename)
    
    ngx.header.content_type = mime
    if not inline then
        ngx.header["Content-Disposition"] = 'attachment; filename="' .. filename .. '"'
    end
    
    -- 分块发送文件
    local chunk_size = 65536
    while true do
        local chunk = f:read(chunk_size)
        if not chunk then break end
        ngx.print(chunk)
    end
    f:close()
    
    return ngx.exit(ngx.OK)
end

-- 预览文本文件
function _M.handle_preview(path, max_size)
    path = url_decode(path) or path
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end

    -- 权限检查：读权限
    if not is_admin() then
        local ok, err = check_file_permission(path, "read")
        if not ok then
            return json_response({ code = -403, message = err or "需要读权限" }, 403)
        end
    end

    local f = io.open(path, "rb")
    if not f then
        return json_response({ code = -404, message = "文件不存在" }, 404)
    end
    
    local size = f:seek("end")
    f:seek("set")
    
    -- 检查是否可预览
    local filename = path:match("[^/]+$") or ""
    if not _M.can_preview_file(filename) then
        f:close()
        return json_response({ code = -415, message = "文件类型不支持预览" }, 415)
    end
    
    local read_size = math.min(size, max_size or LIMITS.preview)
    local content = f:read(read_size)
    f:close()
    
    if not content then
        return json_response({ code = -500, message = "读取文件失败" }, 500)
    end
    
    -- 简单的编码检测 (BOM检查)
    local encoding = "utf-8"
    if content:sub(1, 3) == "\xEF\xBB\xBF" then
        content = content:sub(4)
        encoding = "utf-8-bom"
    end
    
    -- 替换不可见字符
    content = content:gsub("\x00", ""):gsub("\r\n", "\n")
    
    -- 统计行数
    local lines = 0
    for _ in content:gmatch("\n") do
        lines = lines + 1
    end
    
    return json_response({
        code = 0,
        data = {
            path = path,
            size = size,
            encoding = encoding,
            content = content,
            truncated = size > read_size,
            lines = lines,
            mime = _M.get_mime_type(filename)
        }
    })
end

-- 创建目录
function _M.handle_mkdir(path)
    path = url_decode(path) or path
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end
    
    local dirname = path:match("[^/]+$") or ""
    local name_valid, name_err = _M.validate_filename(dirname)
    if not name_valid then
        return json_response({ code = -422, message = name_err }, 422)
    end

    -- 权限检查：写权限
    if not is_admin() then
        local parent_path = path:gsub("/[^/]+$", "")
        if parent_path == path then parent_path = "/" end
        local ok, err = check_file_permission(parent_path, "write")
        if not ok then
            return json_response({ code = -403, message = err or "需要写权限" }, 403)
        end
    end

    local cmd = string.format("mkdir -p '%s'", path:gsub("'", "'\\''"))
    local ok = exec_cmd(cmd)
    if not ok then
        return json_response({ code = -500, message = "创建目录失败" }, 500)
    end

    return json_response({
        code = 0,
        data = { path = path, message = "目录创建成功" }
    })
end

-- 上传文件
function _M.handle_upload(path, filename)
    path = url_decode(path) or path
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end
    
    local name_valid, name_err = _M.validate_filename(filename)
    if not name_valid then
        return json_response({ code = -422, message = name_err }, 422)
    end

    -- 权限检查：写权限
    if not is_admin() then
        local ok, err = check_file_permission(path, "write")
        if not ok then
            return json_response({ code = -403, message = err or "需要写权限" }, 403)
        end
    end

    local full_path = path .. "/" .. filename
    
    -- 检查文件是否已存在
    local f = io.open(full_path, "r")
    if f then
        f:close()
        return json_response({ code = -409, message = "文件已存在" }, 409)
    end
    
    -- 使用临时文件方式处理上传
    local tmp_file = os.tmpname()
    local file = io.open(tmp_file, "wb")
    if not file then
        return json_response({ code = -500, message = "无法创建临时文件" }, 500)
    end

    -- 获取Content-Length
    local content_length = tonumber(ngx.var.http_content_length) or 0

    if content_length > LIMITS.upload then
        file:close()
        os.remove(tmp_file)
        return json_response({ code = -413, message = "文件过大 (最大100MB)" }, 413)
    end

    -- 使用 resty.upload 解析 multipart/form-data
    local upload = require "resty.upload"
    local chunk_size = 4096
    local form, err = upload:new(chunk_size)
    if not form then
        file:close()
        os.remove(tmp_file)
        return json_response({ code = -500, message = "无法解析上传数据: " .. (err or "") }, 500)
    end

    local total_size = 0
    while true do
        local typ, res, err2 = form:read()
        if not typ then
            file:close()
            os.remove(tmp_file)
            return json_response({ code = -500, message = "读取上传数据失败: " .. (err2 or "") }, 500)
        end
        if typ == "body" then
            file:write(res)
            total_size = total_size + #res
        elseif typ == "eof" then
            break
        end
    end
    file:close()
    
    local size_valid, size_err = _M.validate_upload_size(total_size)
    if not size_valid then
        file:close()
        os.remove(tmp_file)
        return json_response({ code = -413, message = size_err }, 413)
    end
    
    file:write(file_content)
    file:close()

    -- 移动到目标位置
    local cp_ok = exec_cmd(string.format("cp '%s' '%s' 2>/dev/null", tmp_file:gsub("'", "'\\''"), full_path:gsub("'", "'\\''")))

    -- 验证移动是否成功
    local check = io.open(full_path, "rb")
    if not check then
        os.remove(tmp_file)
        return json_response({ code = -500, message = "保存文件失败" }, 500)
    end
    check:close()
    
    return json_response({
        code = 0,
        data = {
            name = filename,
            size = total_size,
            path = full_path
        }
    })
end

-- 移动/重命名
function _M.handle_move(src, dst)
    src = url_decode(src) or src
    dst = url_decode(dst) or dst
    local valid1, err1 = _M.validate_path(src)
    local valid2, err2 = _M.validate_path(dst)
    
    if not valid1 then
        return json_response({ code = -403, message = "源路径无效: " .. (err1 or "") }, 403)
    end
    if not valid2 then
        return json_response({ code = -403, message = "目标路径无效: " .. (err2 or "") }, 403)
    end
    
    local dst_name = dst:match("[^/]+$") or ""
    local name_valid, name_err = _M.validate_filename(dst_name)
    if not name_valid then
        return json_response({ code = -422, message = name_err }, 422)
    end
    
    -- 检查源文件是否存在
    local f = io.open(src, "r")
    if not f then
        return json_response({ code = -404, message = "源文件不存在" }, 404)
    end
    f:close()

    -- 权限检查：源文件需要 delete 权限，目标目录需要 write 权限
    if not is_admin() then
        local ok, err = check_file_permission(src, "delete")
        if not ok then
            return json_response({ code = -403, message = "源文件权限不足: " .. (err or "") }, 403)
        end
        local parent_dst = dst:gsub("/[^/]+$", "")
        if parent_dst == dst then parent_dst = "/" end
        local ok2, err2 = check_file_permission(parent_dst, "write")
        if not ok2 then
            return json_response({ code = -403, message = "目标目录权限不足: " .. (err2 or "") }, 403)
        end
    end

    local cmd = string.format("mv '%s' '%s' 2>&1", src:gsub("'", "'\\''"), dst:gsub("'", "'\\''"))
    exec_cmd(cmd)

    -- 验证移动是否成功
    local check = io.open(dst, "r")
    if not check then
        return json_response({ code = -500, message = "移动失败" }, 500)
    end
    check:close()
    
    return json_response({
        code = 0,
        data = { src = src, dst = dst, message = "移动成功" }
    })
end

-- 删除文件/目录
function _M.handle_delete(path, recursive)
    path = url_decode(path) or path
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end
    
    -- 检查是否为根目录
    if get_ALLOWED_ROOTS()[path] then
        return json_response({ code = -403, message = "不能删除根目录" }, 403)
    end

    -- 权限检查：删除权限
    if not is_admin() then
        local ok, err = check_file_permission(path, "delete")
        if not ok then
            return json_response({ code = -403, message = err or "需要删除权限" }, 403)
        end
    end

    local cmd
    if recursive then
        cmd = string.format("rm -rf '%s'", path:gsub("'", "'\\''"))
    else
        cmd = string.format("rm -f '%s'", path:gsub("'", "'\\''"))
    end

    exec_cmd(cmd)

    return json_response({
        code = 0,
        data = { path = path, message = "删除成功" }
    })
end

-- 打包目录
function _M.handle_pack(path, format)
    path = url_decode(path) or path
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end
    
    -- 检查是否为目录
    local check_dir = io.open(path .. "/.", "rb")
    if not check_dir then
        return json_response({ code = -400, message = "只能打包目录" }, 400)
    end
    check_dir:close()
    
    -- 计算目录大小 (使用 -sk 兼容 BusyBox)
    local size_cmd = string.format("du -sk '%s' 2>/dev/null", path:gsub("'", "'\\''"))
    local size_handle = io.popen(size_cmd)
    local dir_size = 0
    if size_handle then
        local size_output = size_handle:read("*a")
        size_handle:close()
        -- du -sk 输出格式: "123\t/path"，取第一个字段并转为字节
        local size_kb = size_output:match("^(%d+)")
        if size_kb then
            dir_size = tonumber(size_kb) * 1024
        end
    end
    
    local size_valid, size_err = _M.validate_pack_size(dir_size)
    if not size_valid then
        return json_response({ code = -413, message = size_err }, 413)
    end
    
    local dirname = path:match("([^/]+)$") or "archive"
    local timestamp = os.time()
    local archive_name = string.format("/tmp/%s_%d.tar.gz", dirname, timestamp)
    
    local parent = path:match("^(.*)/[^/]+$") or "/"
    -- 使用管道兼容 BusyBox tar (不支持 -z)
    local tar_cmd = string.format("tar -cf - -C '%s' '%s' 2>/dev/null | gzip > '%s'",
        parent:gsub("'", "'\\''"),
        dirname:gsub("'", "'\\''"),
        archive_name:gsub("'", "'\\''"))

    local tar_handle = io.popen(tar_cmd, "r")
    if tar_handle then
        tar_handle:read("*a")  -- 等待命令完成
        tar_handle:close()
    end
    
    -- 验证打包是否成功
    local check_tar = io.open(archive_name, "rb")
    if not check_tar then
        return json_response({ code = -500, message = "打包失败" }, 500)
    end
    check_tar:close()
    
    -- 获取打包后的文件信息 (使用 wc -c 兼容 BusyBox，无 stat)
    local archive_wc = io.popen(string.format("wc -c < '%s' 2>/dev/null", archive_name:gsub("'", "'\\''")))
    local archive_size = 0
    if archive_wc then
        archive_size = tonumber(archive_wc:read("*a"):match("(%d+)")) or 0
        archive_wc:close()
    end
    
    return json_response({
        code = 0,
        data = {
            archive = archive_name,
            name = dirname .. ".tar.gz",
            size = archive_size,
            size_formatted = format_size(archive_size),
            source_size = dir_size,
            source_size_formatted = format_size(dir_size)
        }
    })
end

-- 批量打包多个文件/目录
function _M.handle_pack_batch(items)
    if not items or type(items) ~= "table" or #items == 0 then
        return json_response({ code = -400, message = "Missing or empty items parameter" }, 400)
    end

    -- 逐项验证路径安全性
    for _, item in ipairs(items) do
        local valid, err = _M.validate_path(item)
        if not valid then
            return json_response({ code = -403, message = "Invalid path: " .. err }, 403)
        end
    end

    -- 过滤出存在的项目
    local total_source_size = 0
    local valid_items = {}
    for _, item in ipairs(items) do
        local check = io.open(item, "rb")
        if check then
            check:close()
            table.insert(valid_items, item)
            local wc = io.popen(string.format("wc -c < '%s' 2>/dev/null", item:gsub("'", "'\\''")))
            if wc then
                local s = tonumber(wc:read("*a"):match("(%d+)"))
                if s then total_source_size = total_source_size + s end
                wc:close()
            end
        else
            local check_dir = io.open(item .. "/.", "rb")
            if check_dir then
                check_dir:close()
                table.insert(valid_items, item)
                local du = io.popen(string.format("du -sk '%s' 2>/dev/null", item:gsub("'", "'\\''")))
                if du then
                    local kb = tonumber(du:read("*a"):match("(%d+)"))
                    if kb then total_source_size = total_source_size + kb * 1024 end
                    du:close()
                end
            end
        end
    end

    if #valid_items == 0 then
        return json_response({ code = -404, message = "No valid items found" }, 400)
    end

    local timestamp = os.time()
    local archive_name = "/tmp/batch_" .. timestamp .. ".tar.gz"

    -- 使用 tar -C / 打包绝对路径项
    local items_escaped = {}
    for _, item in ipairs(valid_items) do
        -- 去掉开头的 / 得到相对路径（相对于 / ）
        local rel = item:sub(2)
        table.insert(items_escaped, "'" .. rel:gsub("'", "'\\''") .. "'")
    end

    local tar_cmd = string.format(
        "tar -cf - -C / %s 2>/dev/null | gzip > '%s'",
        table.concat(items_escaped, " "),
        archive_name:gsub("'", "'\\''")
    )
    local tar_handle = io.popen(tar_cmd, "r")
    if tar_handle then
        tar_handle:read("*a")
        tar_handle:close()
    end

    -- 验证打包结果
    local check_tar = io.open(archive_name, "rb")
    if not check_tar then
        return json_response({ code = -500, message = "打包失败" }, 500)
    end
    check_tar:close()

    -- 获取归档大小
    local archive_wc = io.popen(string.format("wc -c < '%s' 2>/dev/null", archive_name:gsub("'", "'\\''")))
    local archive_size = 0
    if archive_wc then
        archive_size = tonumber(archive_wc:read("*a"):match("(%d+)")) or 0
        archive_wc:close()
    end

    return json_response({
        code = 0,
        data = {
            archive = archive_name,
            name = "batch_" .. timestamp .. ".tar.gz",
            size = archive_size,
            size_formatted = format_size(archive_size),
            source_size = total_source_size,
            source_size_formatted = format_size(total_source_size)
        }
    })
end

-- ==================== HTTP方法分发 ====================

-- 获取侧边栏配置
function _M.handle_config()
    local config = ngx.shared.sidebar_config
    local folders_json = config and config:get("sidebar_folders")

    local folders = {}
    if folders_json then
        local ok, decoded = pcall(cjson.decode, folders_json)
        if ok and decoded then
            folders = decoded
        end
    end

    -- 确保至少有一个默认配置
    if #folders == 0 then
        folders = {
            { name = "应用与数据", path = "/usrdata" },
            { name = "U盘", path = "/mnt/usbdisk" },
            { name = "临时目录", path = "/tmp" }
        }
    end

    return json_response({
        code = 0,
        data = {
            folders = folders
        }
    })
end

function _M.GET()
    local action = ngx.var.arg_action or "list"
    local path = ngx.var.arg_path or "/usrdata"

    if action == "config" then
        return _M.handle_config()
    elseif action == "list" then
        return _M.handle_list(path)
    elseif action == "download" then
        local inline = ngx.var.arg_inline == "true"
        return _M.handle_download(path, inline)
    elseif action == "preview" then
        local max_size = tonumber(ngx.var.arg_maxSize) or LIMITS.preview
        return _M.handle_preview(path, max_size)
    else
        return json_response({ code = -400, message = "Unknown action" }, 400)
    end
end

function _M.POST()
    local action = ngx.var.arg_action or "upload"
    local path = ngx.var.arg_path or "/usrdata"
    
    if action == "upload" then
        local filename = url_decode(ngx.var.arg_filename) or ngx.var.arg_filename
        return _M.handle_upload(path, filename)
    elseif action == "mkdir" then
        return _M.handle_mkdir(path)
    elseif action == "pack" then
        local format = ngx.var.arg_format or "tar.gz"
        return _M.handle_pack(path, format)
    else
        return json_response({ code = -400, message = "Unknown action" }, 400)
    end
end

-- 保存文件（带备份）
function _M.handle_save(path, content)
    -- 验证路径
    local valid, err = _M.validate_path(path)
    if not valid then
        return json_response({ code = -403, message = err }, 403)
    end
    
    -- 检查是否为目录
    local check_dir = io.open(path .. "/.", "rb")
    if check_dir then
        check_dir:close()
        return json_response({ code = -400, message = "不能编辑目录" }, 400)
    end

    -- 权限检查：写权限
    if not is_admin() then
        local ok, err = check_file_permission(path, "write")
        if not ok then
            return json_response({ code = -403, message = err or "需要写权限" }, 403)
        end
    end

    -- 检查文件是否存在，如果存在则备份
    local backup_name = nil
    local exist_file = io.open(path, "r")
    if exist_file then
        exist_file:close()
        
        -- 获取文件修改时间
        local date_cmd = string.format("date +%%Y%%m%%d_%%H%%M%%S -r '%s' 2>/dev/null", path:gsub("'", "'\\''"))
        local date_handle = io.popen(date_cmd)
        local mtime_str = ""
        if date_handle then
            mtime_str = date_handle:read("*a"):gsub("%s+$", "")
            date_handle:close()
        end
        
        -- 如果获取不到时间，使用当前时间
        if mtime_str == "" then
            mtime_str = os.date("%Y%m%d_%H%M%S")
        end
        
        -- 创建备份文件名: 原文件名.bak.240307_153045
        backup_name = path .. ".bak." .. mtime_str
        
        -- 执行备份
        local backup_cmd = string.format("cp '%s' '%s' 2>&1", path:gsub("'", "'\\''"), backup_name:gsub("'", "'\\''"))
        exec_cmd(backup_cmd)
    end
    
    -- 写入新内容
    local file, open_err = io.open(path, "w")
    if not file then
        return json_response({ code = -500, message = "无法打开文件: " .. (open_err or "未知错误") }, 500)
    end
    
    local success, write_err = file:write(content)
    file:close()
    
    if not success then
        return json_response({ code = -500, message = "写入失败: " .. (write_err or "未知错误") }, 500)
    end
    
    return json_response({
        code = 0,
        data = { 
            path = path, 
            message = "保存成功",
            backup = backup_name
        }
    })
end

function _M.PUT()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        -- body 被缓存到临时文件，需要从文件读取
        local body_file = ngx.req.get_body_file()
        if body_file then
            local bf = io.open(body_file, "rb")
            if bf then
                body = bf:read("*all")
                bf:close()
            end
        end
    end
    if not body then
        return json_response({ code = -400, message = "Missing request body" }, 400)
    end
    
    local ok, data = pcall(cjson.decode, body)
    if not ok or not data then
        return json_response({ code = -400, message = "Invalid JSON: " .. tostring(data) }, 400)
    end
    
    if not data.action then
        return json_response({ code = -400, message = "Missing action parameter" }, 400)
    end
    
    if data.action == "move" or data.action == "rename" then
        return _M.handle_move(data.src, data.dst)
    elseif data.action == "pack_batch" then
        return _M.handle_pack_batch(data.items)
    elseif data.action == "save" then
        if not data.path then
            return json_response({ code = -400, message = "Missing path parameter" }, 400)
        end
        if not data.content then
            return json_response({ code = -400, message = "Missing content parameter" }, 400)
        end
        return _M.handle_save(data.path, data.content)
    else
        return json_response({ code = -400, message = "Unknown action: " .. tostring(data.action) }, 400)
    end
end

function _M.DELETE()
    local path = ngx.var.arg_path
    local recursive = ngx.var.arg_recursive == "true"
    
    if not path then
        return json_response({ code = -400, message = "Missing path parameter" }, 400)
    end
    
    return _M.handle_delete(path, recursive)
end

return _M
