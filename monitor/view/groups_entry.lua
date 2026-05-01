--[[
用户组管理 API (admin only)
GET    /api/groups        — 列出所有组
POST   /api/groups        — 创建组
PUT    /api/groups?id=xxx — 更新组
DELETE /api/groups?id=xxx — 删除组
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

local session = auth.get_session()
if not session then
    return json_response({ code = -401, message = "请先登录" }, 401)
end

-- GET 对所有人开放（权限对话框需要组列表），写操作 admin only
if method == "GET" then
    local groups = auth.get_all_groups()
    return json_response({ code = 0, data = { groups = groups } })

elseif method == "POST" then
    if session.role ~= "admin" then
        return json_response({ code = -403, message = "需要管理员权限" }, 403)
    end
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local post_data = {}
    if body then
        local ok, decoded = pcall(cjson.decode, body)
        if ok then post_data = decoded end
    end

    local name = post_data.name
    local members = post_data.members

    if not name or name == "" then
        return json_response({ code = -400, message = "组名不能为空" }, 400)
    end

    local group, err = auth.create_group(name, members, session)
    if not group then
        return json_response({ code = -400, message = err or "创建组失败" }, 400)
    end
    return json_response({ code = 0, data = group })

elseif method == "PUT" then
    if session.role ~= "admin" then
        return json_response({ code = -403, message = "需要管理员权限" }, 403)
    end
    local group_id = ngx.var.arg_id
    if not group_id then
        return json_response({ code = -400, message = "缺少组 ID" }, 400)
    end
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local post_data = {}
    if body then
        local ok, decoded = pcall(cjson.decode, body)
        if ok then post_data = decoded end
    end

    local group, err = auth.update_group(group_id, post_data.name, post_data.members, session)
    if not group then
        return json_response({ code = -400, message = err or "更新组失败" }, 400)
    end
    return json_response({ code = 0, data = group })

elseif method == "DELETE" then
    if session.role ~= "admin" then
        return json_response({ code = -403, message = "需要管理员权限" }, 403)
    end
    local group_id = ngx.var.arg_id
    if not group_id then
        return json_response({ code = -400, message = "缺少组 ID" }, 400)
    end

    local ok, err = auth.delete_group(group_id, session)
    if not ok then
        return json_response({ code = -400, message = err or "删除组失败" }, 400)
    end
    return json_response({ code = 0, data = { message = "组已删除" } })

else
    return json_response({ code = -405, message = "Method not allowed" }, 405)
end
