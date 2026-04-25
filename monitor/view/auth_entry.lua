--[[
认证 API 入口
POST /api/auth/login  - 登录
POST /api/auth/logout - 登出
GET  /api/auth/session - 获取当前 session
]]

local cjson = require "cjson"
local auth = require "monitor.view.auth"

local method = ngx.req.get_method()

local function json_response(data, status)
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
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

if method == "POST" or method == "GET" then
    local action = ngx.var.arg_action or (method == "POST" and "login" or "session")

    if action == "login" then
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

        if not username or not password then
            return json_response({ code = -400, message = "用户名和密码不能为空" }, 400)
        end

        local token, session = auth.login(username, password)
        if not token then
            return json_response({ code = -401, message = session or "登录失败" }, 401)
        end

        -- 设置 cookie
        ngx.header["Set-Cookie"] = "session=" .. token .. "; path=/; HttpOnly; SameSite=Lax"
        return json_response({
            code = 0,
            data = {
                session_token = token,
                user = {
                    id = session.user_id,
                    username = session.username,
                    role = session.role
                }
            }
        })

    elseif action == "logout" then
        local session = auth.get_session()
        if session then
            auth.logout(ngx.var.http_x_session_token or ngx.var.cookie_session)
        end
        ngx.header["Set-Cookie"] = "session=; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT"
        return json_response({ code = 0, data = { message = "已登出" } })

    elseif action == "session" then
        local session = auth.get_session()
        if not session then
            return json_response({ code = -401, message = "未登录" }, 401)
        end
        return json_response({
            code = 0,
            data = {
                user_id = session.user_id,
                username = session.username,
                role = session.role
            }
        })

    else
        return json_response({ code = -400, message = "未知 action: " .. action }, 400)
    end
else
    return json_response({ code = -405, message = "Method not allowed" }, 405)
end