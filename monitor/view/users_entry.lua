--[[
用户管理 API 入口（GET 所有已登录用户，写操作需 admin）
GET  /api/users      - 用户列表
POST /api/users      - 创建用户
PUT  /api/users/:id  - 更新用户
DELETE /api/users/:id - 删除用户
]]

local cjson = require "cjson"
local auth = require "monitor.view.auth"

local method = ngx.req.get_method()

local function json_response(data, status)
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
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

-- 检查登录（GET 开放所有用户，写操作需 admin）
local session = auth.get_session()
if not session then
    return json_response({ code = -401, message = "请先登录" }, 401)
end

if method == "GET" then
    local users = auth.get_all_users()
    local user_list = {}
    for _, u in pairs(users) do
        table.insert(user_list, {
            id = u.id,
            username = u.username,
            role = u.role,
            primary_group = u.primary_group or "",
            created_at = u.created_at,
            updated_at = u.updated_at
        })
    end
    return json_response({ code = 0, data = { users = user_list } })

elseif method == "POST" then
    -- admin only for mutations
    if session.role ~= "admin" then
        return json_response({ code = -403, message = "需要管理员权限" }, 403)
    end
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local post_data = {}

    if body then
        local ok, decoded = pcall(cjson.decode, body)
        if ok then
            post_data = decoded
        end
    end

    local username = post_data.username
    local password = post_data.password
    local role = post_data.role or "user"
    local primary_group = post_data.primary_group or "g_users"

    if not username or not password then
        return json_response({ code = -400, message = "用户名和密码不能为空" }, 400)
    end

    if role ~= "user" and role ~= "admin" then
        return json_response({ code = -400, message = "角色必须是 user 或 admin" }, 400)
    end

    local user, err = auth.create_user(username, password, role, primary_group, session)
    if not user then
        return json_response({ code = -400, message = err or "创建用户失败" }, 400)
    end

    return json_response({ code = 0, data = user })

elseif method == "PUT" then
    if session.role ~= "admin" then
        return json_response({ code = -403, message = "需要管理员权限" }, 403)
    end
    local user_id = ngx.var.arg_id
    if not user_id then
        return json_response({ code = -400, message = "缺少用户 ID" }, 400)
    end

    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local post_data = {}

    if body then
        local ok, decoded = pcall(cjson.decode, body)
        if ok then
            post_data = decoded
        end
    end

    local updates = {}
    if post_data.password then updates.password = post_data.password end
    if post_data.role then updates.role = post_data.role end

    local user, err = auth.update_user(user_id, updates, session)
    if not user then
        return json_response({ code = -400, message = err or "更新用户失败" }, 400)
    end

    return json_response({ code = 0, data = user })

elseif method == "DELETE" then
    local user_id = ngx.var.arg_id
    if not user_id then
        return json_response({ code = -400, message = "缺少用户 ID" }, 400)
    end

    local ok, err = auth.delete_user(user_id, session)
    if not ok then
        return json_response({ code = -400, message = err or "删除用户失败" }, 400)
    end

    return json_response({ code = 0, data = { message = "用户已删除" } })

else
    return json_response({ code = -405, message = "Method not allowed" }, 405)
end