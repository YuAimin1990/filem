--[[
权限管理 API 入口
GET  /api/permissions?path=xxx - 获取路径权限
PUT  /api/permissions         - 设置权限
]]

local cjson = require "cjson"
local auth = require "monitor.view.auth"

local APP_ROOT = ngx.shared.sidebar_config and ngx.shared.sidebar_config:get("APP_ROOT") or os.getenv("APP_ROOT") or "/awork/fm"
local PERM_DATA_FILE = APP_ROOT .. "/monitor/data/permissions.jsonl"

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

if method == "GET" then
    local path = ngx.var.arg_path
    if not path or path == "" then
        return json_response({ code = -400, message = "缺少 path 参数" }, 400)
    end

    local perm = auth.get_permissions(path)
    if not perm then
        -- 没有权限记录，返回默认状态
        return json_response({
            code = 0,
            data = {
                resource_path = path,
                owner_id = nil,
                grants = {},
                message = "无权限记录"
            }
        })
    end

    return json_response({
        code = 0,
        data = {
            resource_path = perm.resource_path,
            resource_type = perm.resource_type,
            owner_id = perm.owner_id,
            grants = perm.grants or {},
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
        if ok then
            post_data = decoded
        end
    end

    local path = post_data.resource_path
    if not path or path == "" then
        return json_response({ code = -400, message = "缺少 resource_path" }, 400)
    end

    -- 如果是设置所有者（新建权限记录）
    if post_data.owner_id and not post_data.grants and not post_data.grant then
        -- 直接设置 owner（需要 admin 或当前 owner）
        local ok, err
        if session.role == "admin" then
            ok = true
        else
            local existing = auth.get_permissions(path)
            if existing and existing.owner_id == session.user_id then
                ok = true
            else
                ok, err = false, "需要管理员权限或所有者身份"
            end
        end

        if not ok then
            return json_response({ code = -403, message = err }, 403)
        end

        -- 创建权限记录
        local perm = {
            id = "p_" .. tostring(os.time()),
            resource_path = path,
            resource_type = post_data.resource_type or "file",
            owner_id = post_data.owner_id,
            grants = {},
            created_at = os.time(),
            updated_at = os.time()
        }

        -- 保存
        local perms = {}
        local file = io.open(PERM_DATA_FILE, "r")
        if file then
            for line in file:lines() do
                if line and line ~= "" then
                    local ok, p = pcall(cjson.decode, line)
                    if ok and p then
                        perms[p.resource_path] = p
                    end
                end
            end
            file:close()
        end

        perms[path] = perm
        file = io.open(PERM_DATA_FILE, "w")
        if file then
            for _, p in pairs(perms) do
                file:write(cjson.encode(p) .. "\n")
            end
            file:close()
        end

        return json_response({ code = 0, data = perm })
    end

    -- 添加或更新授权
    local grant = post_data.grant
    if grant and grant.user_id and grant.permission then
        local ok, err = auth.add_grant(path, grant.user_id, grant.permission, session)
        if not ok then
            return json_response({ code = -403, message = err }, 403)
        end
        return json_response({ code = 0, data = { message = "权限已更新" } })
    end

    -- 批量设置授权
    if post_data.grants then
        -- 需要 admin 权限
        local ok, err = auth.check_permission(session, path, "admin")
        if not ok then
            return json_response({ code = -403, message = err }, 403)
        end

        -- 读取现有权限
        local perm = auth.get_permissions(path) or {
            id = "p_" .. tostring(os.time()),
            resource_path = path,
            resource_type = post_data.resource_type or "file",
            owner_id = session.user_id,
            grants = {},
            created_at = os.time(),
            updated_at = os.time()
        }

        perm.grants = post_data.grants
        perm.updated_at = os.time()

        -- 保存
        local perms = {}
        local file = io.open(PERM_DATA_FILE, "r")
        if file then
            for line in file:lines() do
                if line and line ~= "" then
                    local ok, p = pcall(cjson.decode, line)
                    if ok and p then
                        perms[p.resource_path] = p
                    end
                end
            end
            file:close()
        end

        perms[path] = perm
        file = io.open(PERM_DATA_FILE, "w")
        if file then
            for _, p in pairs(perms) do
                file:write(cjson.encode(p) .. "\n")
            end
            file:close()
        end

        return json_response({ code = 0, data = { message = "权限已更新", grants = post_data.grants } })
    end

    return json_response({ code = -400, message = "无效的请求格式" }, 400)

else
    return json_response({ code = -405, message = "Method not allowed" }, 405)
end