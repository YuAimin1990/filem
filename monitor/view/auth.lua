--[[
认证与权限模块
管理用户登录、session、权限检查
]]

local cjson = require "cjson"
local resty_sha256 = require "resty.sha256"

local _M = {}

-- 配置
local SESSION_TTL = 86400  -- 24小时
local USER_DATA_FILE = "/awork/fm/monitor/data/users.jsonl"
local PERM_DATA_FILE = "/awork/fm/monitor/data/permissions.jsonl"
local SESSION_DICT = ngx.shared.user_sessions

-- 权限级别：read < write < delete < admin
local PERM_LEVELS = {
    read = 1,
    write = 2,
    delete = 3,
    admin = 4
}

-- 生成随机 salt (hex encoded)
local function generate_salt()
    local random = require "resty.random"
    local bytes = random.bytes(16)
    local hex = ""
    for i = 1, #bytes do
        hex = hex .. string.format("%02x", string.byte(bytes, i))
    end
    return hex
end

-- SHA256 哈希 (hex encoded)
local function sha256(data)
    local sha = resty_sha256:new()
    sha:update(data)
    local digest = sha:final()
    local hex = ""
    for i = 1, #digest do
        hex = hex .. string.format("%02x", string.byte(digest, i))
    end
    return hex
end

-- 密码哈希 (salt:iterations:hash)
local function hash_password(password)
    local salt = generate_salt()
    local iterations = 10000
    local result = salt .. password
    for i = 1, iterations do
        result = sha256(result)
    end
    return salt .. ":" .. iterations .. ":" .. result
end

-- 验证密码
local function verify_password(password, stored)
    local parts = {}
    for part in stored:gmatch("[^:]+") do
        table.insert(parts, part)
    end
    if #parts ~= 3 then return false end
    local salt, iterations_str, stored_hash = parts[1], parts[2], parts[3]
    local iterations = tonumber(iterations_str) or 10000
    local result = salt .. password
    for i = 1, iterations do
        result = sha256(result)
    end
    return result == stored_hash
end

-- 生成 session token (hex encoded)
local function generate_token()
    local random = require "resty.random"
    local bytes = random.bytes(32)
    -- Convert to hex
    local hex = ""
    for i = 1, #bytes do
        hex = hex .. string.format("%02x", string.byte(bytes, i))
    end
    return hex
end

-- 确保数据目录存在
local function ensure_data_dir()
    local cmd = "mkdir -p /awork/fm/monitor/data"
    os.execute(cmd)
end

-- 读取用户列表
local function load_users()
    ensure_data_dir()
    local file = io.open(USER_DATA_FILE, "r")
    if not file then return {} end
    local users = {}
    for line in file:lines() do
        if line and line ~= "" then
            local ok, u = pcall(cjson.decode, line)
            if ok and u then users[u.id] = u end
        end
    end
    file:close()
    return users
end

-- 保存用户到文件
local function save_user(user)
    ensure_data_dir()
    local users = load_users()
    users[user.id] = user
    local file = io.open(USER_DATA_FILE, "w")
    if not file then return false end
    for _, u in pairs(users) do
        file:write(cjson.encode(u) .. "\n")
    end
    file:close()
    return true
end

-- 初始化默认管理员
local function init_default_admin()
    local users = load_users()
    if not users["admin"] then
        -- 优先使用环境变量 ADMIN_PASSWORD，未设置则生成随机密码
        local admin_pwd = os.getenv("ADMIN_PASSWORD")
        if not admin_pwd or admin_pwd == "" then
            admin_pwd = generate_token():sub(1, 16)
        end
        local admin = {
            id = "admin",
            username = "admin",
            password_hash = hash_password(admin_pwd),
            role = "admin",
            created_at = os.time(),
            updated_at = os.time()
        }
        save_user(admin)
        ngx.log(ngx.WARN, "[auth] Admin user created. Username: admin, Password: " .. admin_pwd)
    end
end

-- 初始化时创建默认管理员
init_default_admin()

-- 登录
function _M.login(username, password)
    local users = load_users()
    local user = nil
    for _, u in pairs(users) do
        if u.username == username then
            user = u
            break
        end
    end

    if not user then
        return nil, "用户名或密码错误"
    end

    if not verify_password(password, user.password_hash) then
        return nil, "用户名或密码错误"
    end

    -- 创建 session
    local token = generate_token()
    local session = {
        user_id = user.id,
        username = user.username,
        role = user.role,
        created_at = os.time(),
        expires_at = os.time() + SESSION_TTL
    }

    SESSION_DICT:set(token, cjson.encode(session), SESSION_TTL)

    return token, session
end

-- 登出
function _M.logout(token)
    if token then
        SESSION_DICT:delete(token)
    end
    return true
end

-- 获取 session
function _M.get_session()
    -- 优先从 header 获取 X-Session-Token
    local token = ngx.var.http_x_session_token
    -- 其次从 cookie 获取
    if not token then
        token = ngx.var.cookie_session
    end

    if not token or token == "" then
        return nil
    end

    local data = SESSION_DICT:get(token)
    if not data then
        return nil
    end

    local ok, session = pcall(cjson.decode, data)
    if not ok or not session then
        return nil
    end

    -- 检查过期
    if session.expires_at and session.expires_at < os.time() then
        SESSION_DICT:delete(token)
        return nil
    end

    return session
end

-- 验证是否已登录（中间件）
function _M.require_auth()
    local session = _M.get_session()
    if not session then
        ngx.header.content_type = "application/json; charset=utf-8"
        ngx.status = 401
        ngx.say(cjson.encode({ code = -401, message = "请先登录" }))
        return ngx.exit(ngx.OK)
    end
    return session
end

-- 获取当前用户信息（不带权限验证）
function _M.get_current_user()
    return _M.get_session()
end

-- 读取权限记录
local function load_permissions()
    ensure_data_dir()
    local file = io.open(PERM_DATA_FILE, "r")
    if not file then return {} end
    local perms = {}
    for line in file:lines() do
        if line and line ~= "" then
            local ok, p = pcall(cjson.decode, line)
            if ok and p then
                perms[p.resource_path] = p
            end
        end
    end
    file:close()
    return perms
end

-- 保存权限记录
local function save_permission(perm)
    ensure_data_dir()
    local perms = load_permissions()
    perms[perm.resource_path] = perm
    -- 重写整个文件
    local file = io.open(PERM_DATA_FILE, "w")
    if not file then return false end
    for _, p in pairs(perms) do
        file:write(cjson.encode(p) .. "\n")
    end
    file:close()
    return true
end

-- 检查权限级别
local function has_perm_level(granted, required)
    local g = PERM_LEVELS[granted] or 0
    local r = PERM_LEVELS[required] or 0
    return g >= r
end

-- 获取资源的权限记录
local function get_resource_permission(path)
    local perms = load_permissions()
    return perms[path]
end

-- 检查权限
function _M.check_permission(session, path, required_action)
    -- admin 拥有所有权限
    if session.role == "admin" then
        return true
    end

    -- 获取权限记录
    local perm = get_resource_permission(path)

    -- 无权限记录：递归检查父目录权限（用于继承）
    if not perm then
        local parent_path = path:gsub("/[^/]+$", "")
        -- 如果已经是根目录或没有父路径，不再递归
        if parent_path == path or parent_path == "" or parent_path == "/" then
            return true  -- 根路径无记录时允许访问
        end
        return _M.check_permission(session, parent_path, required_action)
    end

    -- 所有者拥有 admin 权限
    if perm.owner_id == session.user_id then
        return true
    end

    -- 检查显式授权
    if perm.grants then
        for _, grant in ipairs(perm.grants) do
            if grant.user_id == session.user_id or grant.user_id == "*" then
                if has_perm_level(grant.permission, required_action) then
                    return true
                end
            end
        end
    end

    -- 如果有权限记录但用户没有足够权限，拒绝访问（不继承父目录）
    return false, "权限不足: 需要 " .. required_action .. " 权限"
end

-- 设置资源所有者（文件创建时调用）
function _M.set_owner(path, owner_id, resource_type)
    local perm = get_resource_permission(path)
    if not perm then
        perm = {
            id = "p_" .. generate_token():sub(1, 16),
            resource_path = path,
            resource_type = resource_type or "file",
            owner_id = owner_id,
            grants = {},
            created_at = os.time(),
            updated_at = os.time()
        }
    end
    perm.updated_at = os.time()
    save_permission(perm)
    return true
end

-- 添加权限授权
function _M.add_grant(path, user_id, permission, session)
    -- 需要 admin 权限或 owner 才能授权
    local ok, err = _M.check_permission(session, path, "admin")
    if not ok then
        return false, err
    end

    local perm = get_resource_permission(path)
    if not perm then
        perm = {
            id = "p_" .. generate_token():sub(1, 16),
            resource_path = path,
            resource_type = "file",
            owner_id = session.user_id,
            grants = {},
            created_at = os.time(),
            updated_at = os.time()
        }
    end

    -- 添加或更新授权
    local found = false
    for _, grant in ipairs(perm.grants) do
        if grant.user_id == user_id then
            grant.permission = permission
            found = true
            break
        end
    end
    if not found then
        table.insert(perm.grants, { user_id = user_id, permission = permission })
    end

    perm.updated_at = os.time()
    save_permission(perm)
    return true
end

-- 移除授权
function _M.remove_grant(path, user_id, session)
    local ok, err = _M.check_permission(session, path, "admin")
    if not ok then
        return false, err
    end

    local perm = get_resource_permission(path)
    if not perm then
        return true  -- 没有记录无所谓
    end

    local new_grants = {}
    for _, grant in ipairs(perm.grants) do
        if grant.user_id ~= user_id then
            table.insert(new_grants, grant)
        end
    end
    perm.grants = new_grants
    perm.updated_at = os.time()
    save_permission(perm)
    return true
end

-- 获取权限信息
function _M.get_permissions(path)
    return get_resource_permission(path)
end

-- 获取所有用户
function _M.get_all_users()
    return load_users()
end

-- 创建用户
function _M.create_user(username, password, role, creator_session)
    -- 只有 admin 可以创建用户
    if not creator_session or creator_session.role ~= "admin" then
        return nil, "需要管理员权限"
    end

    local users = load_users()
    -- 检查用户名是否已存在
    for _, u in pairs(users) do
        if u.username == username then
            return nil, "用户名已存在"
        end
    end

    local user_id = "user_" .. generate_token():sub(1, 16)
    local user = {
        id = user_id,
        username = username,
        password_hash = hash_password(password),
        role = role or "user",
        created_at = os.time(),
        updated_at = os.time()
    }

    save_user(user)
    user.password_hash = nil  -- 不返回密码哈希
    return user
end

-- 更新用户
function _M.update_user(user_id, updates, session)
    -- 只有 admin 或本人可以更新
    if session.role ~= "admin" and session.user_id ~= user_id then
        return nil, "权限不足"
    end

    local users = load_users()
    local user = users[user_id]
    if not user then
        return nil, "用户不存在"
    end

    -- admin 可以修改角色，普通用户只能修改密码
    if updates.password and (session.role == "admin" or session.user_id == user_id) then
        user.password_hash = hash_password(updates.password)
    end
    if updates.role and session.role == "admin" then
        user.role = updates.role
    end

    user.updated_at = os.time()
    save_user(user)
    user.password_hash = nil
    return user
end

-- 删除用户
function _M.delete_user(user_id, session)
    if session.role ~= "admin" then
        return nil, "需要管理员权限"
    end

    if user_id == "admin" then
        return nil, "不能删除管理员账户"
    end

    local users = load_users()
    if not users[user_id] then
        return nil, "用户不存在"
    end

    users[user_id] = nil
    local file = io.open(USER_DATA_FILE, "w")
    if file then
        for _, u in pairs(users) do
            file:write(cjson.encode(u) .. "\n")
        end
        file:close()
    end

    return true
end

return _M