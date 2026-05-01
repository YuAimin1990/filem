--[[
Linux chmod 权限 API
GET  /api/permissions?path=xxx  — 返回 {owner_id, group_id, mode, mode_str, owner_name, group_name}
PUT  /api/permissions           — 设置 {resource_path, mode}
]]

local cjson = require "cjson"
local auth = require "monitor.view.auth"

local method = ngx.req.get_method()

local function json_response(data, status)
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, PUT, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "Content-Type, X-Session-Token"
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

-- 需要登录
local session = auth.get_session()
if not session then
    return json_response({ code = -401, message = "请先登录" }, 401)
end

-- 解析用户名（从用户列表中查）
local function resolve_username(user_id)
    if not user_id or user_id == "" then return "未知" end
    local users = auth.get_all_users()
    for _, u in pairs(users) do
        if u.id == user_id then
            return u.username
        end
    end
    return user_id
end

local function resolve_groupname(group_id)
    if not group_id or group_id == "" then return "" end
    local groups = auth.get_all_groups()
    for _, g in ipairs(groups) do
        if g.id == group_id then
            return g.name
        end
    end
    return group_id
end

if method == "GET" then
    local path = ngx.var.arg_path
    if not path or path == "" then
        return json_response({ code = -400, message = "缺少 path 参数" }, 400)
    end
    -- URL 解码路径（%2F → /）
    path = ngx.unescape_uri(path)

    local perm = auth.get_permissions(path)
    if not perm then
        return json_response({
            code = 0,
            data = {
                resource_path = path,
                owner_id = "",
                group_id = "",
                mode = 0,
                mode_str = "---------",
                mode_octal = "0000",
                owner_name = "",
                group_name = "",
                message = "无权限记录 — 默认允许所有操作"
            }
        })
    end

    local mode = perm.mode or 0
    local mode_str = auth.mode_to_octal_str(mode)
    -- 手动 oct 转换: mode=420 → 0o644
    local mode_octal = string.format("0%d%d%d",
        math.floor(mode / 64),
        math.floor(mode / 8) % 8,
        mode % 8)

    return json_response({
        code = 0,
        data = {
            resource_path = perm.resource_path,
            owner_id = perm.owner_id or "",
            group_id = perm.group_id or "",
            mode = mode,
            mode_str = mode_str,
            mode_octal = mode_octal,
            owner_name = resolve_username(perm.owner_id),
            group_name = resolve_groupname(perm.group_id),
            created_at = perm.created_at,
            updated_at = perm.updated_at
        }
    })

elseif method == "PUT" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local post_data = {}

    if body then
        local ok, decoded = pcall(cjson.decode, body)
        if ok then post_data = decoded end
    end

    local path = post_data.resource_path
    if not path or path == "" then
        return json_response({ code = -400, message = "缺少 resource_path" }, 400)
    end

    if post_data.mode then
        local ok, err = auth.set_mode(path, tonumber(post_data.mode), session)
        if not ok then
            return json_response({ code = -403, message = err or "设置权限失败" }, 403)
        end
        return json_response({ code = 0, data = { message = "权限已更新" } })
    end

    if post_data.owner_id then
        local ok, err = auth.set_owner(path, post_data.owner_id, post_data.group_id, post_data.resource_type)
        if not ok then
            return json_response({ code = -403, message = err or "设置所有者失败" }, 403)
        end
        return json_response({ code = 0, data = { message = "所有者已更新" } })
    end

    return json_response({ code = -400, message = "需要 mode 或 owner_id" }, 400)

else
    return json_response({ code = -405, message = "Method not allowed" }, 405)
end
