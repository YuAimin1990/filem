--!/usr/bin/env lua
--[[
文件管理API入口 - 带认证
]]

local cjson = require "cjson"
local files_api = require "monitor.view.files"
local auth = require "monitor.view.auth"

-- 调试日志函数
local function debug_log(msg)
    local f = io.open("/tmp/files_api_debug.log", "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

-- 路由分发
local method = ngx.req.get_method()

-- 验证 session
local session = auth.get_session()
if not session then
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.status = 401
    ngx.say(cjson.encode({ code = -401, message = "请先登录" }))
    return ngx.exit(ngx.OK)
end

-- 将 session 传递给 files_api (通过 ngx.ctx)
ngx.ctx.session = session
ngx.ctx.is_admin = (session.role == "admin")

debug_log("Method: " .. tostring(method) .. " user: " .. tostring(session.username))

if method == "GET" then
    files_api.GET()
elseif method == "POST" then
    files_api.POST()
elseif method == "PUT" then
    files_api.PUT()
elseif method == "DELETE" then
    files_api.DELETE()
else
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.status = 405
    ngx.say(cjson.encode({ code = -405, message = "Method not allowed" }))
    ngx.exit(ngx.OK)
end