--[[
认证与权限模块
管理用户登录、session、权限检查
]]

local cjson = require "cjson"
local resty_sha256 = require "resty.sha256"

local _M = {}

-- 配置
local SESSION_TTL = 86400  -- 24小时
local APP_ROOT = ngx.shared.sidebar_config and ngx.shared.sidebar_config:get("APP_ROOT") or os.getenv("APP_ROOT") or "/awork/fm"
local USER_DATA_FILE = APP_ROOT .. "/monitor/data/users.jsonl"
local PERM_DATA_FILE = APP_ROOT .. "/monitor/data/permissions.jsonl"
local GROUP_DATA_FILE = APP_ROOT .. "/monitor/data/groups.jsonl"
local SESSION_DICT = ngx.shared.user_sessions

-- 权限位: owner(64) / group(8) / others(1) * r(4) / w(2) / x(1)
-- 例: owner r=256, w=128, x=64; group r=32, w=16, x=8; others r=4, w=2, x=1
local BIT_OWNER_R = 256; local BIT_OWNER_W = 128; local BIT_OWNER_X = 64
local BIT_GROUP_R = 32;  local BIT_GROUP_W = 16;  local BIT_GROUP_X = 8
local BIT_OTHER_R = 4;   local BIT_OTHER_W = 2;   local BIT_OTHER_X = 1

local MAX_RECURSE = 5

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
    local cmd = "mkdir -p " .. APP_ROOT .. "/monitor/data"
    os.execute(cmd)
end

-- 读取用户列表
local function load_users()
    ensure_data_dir()
    local file = io.open(USER_DATA_FILE, "r")
    if not file then return {} end
    local users = {}
    local needs_migration = false
    for line in file:lines() do
        if line and line ~= "" then
            local ok, u = pcall(cjson.decode, line)
            if ok and u then
                if u.primary_group == nil then
                    u.primary_group = (u.role == "admin") and "g_admin" or "g_users"
                    needs_migration = true
                end
                users[u.id] = u
            end
        end
    end
    file:close()
    if needs_migration then
        local out = io.open(USER_DATA_FILE, "w")
        if out then
            for _, u in pairs(users) do
                out:write(cjson.encode(u) .. "\n")
            end
            out:close()
        end
        ngx.log(ngx.WARN, "[auth] Migrated users with default primary_group")
    end
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

-- ==================== 用户组管理 ====================

local function load_groups()
    ensure_data_dir()
    local file = io.open(GROUP_DATA_FILE, "r")
    if not file then return {} end
    local groups = {}
    for line in file:lines() do
        if line and line ~= "" then
            local ok, g = pcall(cjson.decode, line)
            if ok and g then groups[g.id] = g end
        end
    end
    file:close()
    return groups
end

local function save_groups(groups)
    ensure_data_dir()
    local file = io.open(GROUP_DATA_FILE, "w")
    if not file then return false end
    for _, g in pairs(groups) do
        file:write(cjson.encode(g) .. "\n")
    end
    file:close()
    return true
end

-- 首次启动初始化默认组
local function init_default_groups()
    local groups = load_groups()
    if next(groups) == nil then
        groups["g_admin"] = { id = "g_admin", name = "admin", members = { "admin" }, created_at = os.time() }
        groups["g_users"] = { id = "g_users", name = "users", members = {}, created_at = os.time() }
        save_groups(groups)
        ngx.log(ngx.WARN, "[auth] Default groups created: admin, users")
    end
end
init_default_groups()

function _M.get_all_groups()
    local groups = load_groups()
    local list = {}
    for _, g in pairs(groups) do
        table.insert(list, {
            id = g.id,
            name = g.name,
            members = g.members or {},
            created_at = g.created_at
        })
    end
    return list
end

function _M.create_group(name, members, session)
    if session.role ~= "admin" then
        return nil, "需要管理员权限"
    end
    local groups = load_groups()
    -- check name uniqueness
    for _, g in pairs(groups) do
        if g.name == name then
            return nil, "组名已存在"
        end
    end
    local group = {
        id = "g_" .. generate_token():sub(1, 16),
        name = name,
        members = members or {},
        created_at = os.time()
    }
    groups[group.id] = group
    save_groups(groups)
    return group
end

function _M.update_group(group_id, name, members, session)
    if session.role ~= "admin" then
        return nil, "需要管理员权限"
    end
    local groups = load_groups()
    local group = groups[group_id]
    if not group then
        return nil, "组不存在"
    end
    if name then group.name = name end
    if members then group.members = members end
    save_groups(groups)
    return group
end

function _M.delete_group(group_id, session)
    if session.role ~= "admin" then
        return nil, "需要管理员权限"
    end
    local groups = load_groups()
    if not groups[group_id] then
        return nil, "组不存在"
    end
    groups[group_id] = nil
    save_groups(groups)
    return true
end

function _M.user_in_group(user_id, group_id)
    if not group_id then return false end
    local groups = load_groups()
    local group = groups[group_id]
    if not group then return false end
    for _, m in ipairs(group.members or {}) do
        if m == user_id then return true end
    end
    return false
end

-- ==================== Linux rwx 权限 ====================

local function mode_to_octal_str(mode)
    -- 十进制 mode → "rwxrwxrwx" 字符串
    return string.format("%s%s%s%s%s%s%s%s%s",
        (mode / 256) % 8 >= 4 and "r" or "-",
        (mode / 128) % 2 >= 1 and "w" or "-",
        (mode / 64) % 2 >= 1  and "x" or "-",
        (mode / 32) % 8 >= 4  and "r" or "-",
        (mode / 16) % 2 >= 1  and "w" or "-",
        (mode / 8) % 2 >= 1   and "x" or "-",
        (mode / 4) % 8 >= 4   and "r" or "-",
        (mode / 2) % 2 >= 1   and "w" or "-",
        mode % 2 >= 1          and "x" or "-"
    )
end

_M.mode_to_octal_str = mode_to_octal_str

local function load_permissions()
    ensure_data_dir()
    local file = io.open(PERM_DATA_FILE, "r")
    if not file then return {} end
    local perms = {}
    local needs_migration = false
    for line in file:lines() do
        if line and line ~= "" then
            local ok, p = pcall(cjson.decode, line)
            if ok and p then
                -- 迁移旧格式 (grants → mode)
                if p.mode == nil then
                    p.mode = 511  -- 0777: 原有 ACL 权限通过 rwx 落地为全开放
                    p.group_id = p.group_id or "g_users"
                    needs_migration = true
                end
                perms[p.resource_path] = p
            end
        end
    end
    file:close()
    if needs_migration then
        save_all_permissions(perms)
        ngx.log(ngx.WARN, "[auth] Migrated old permissions to rwx mode")
    end
    return perms
end

local function save_all_permissions(perms)
    ensure_data_dir()
    local file = io.open(PERM_DATA_FILE, "w")
    if not file then return false end
    for _, p in pairs(perms) do
        file:write(cjson.encode(p) .. "\n")
    end
    file:close()
    return true
end

local function get_resource_permission(path)
    local perms = load_permissions()
    return perms[path]
end

-- 三级权限检查: owner > group > others
local function check_mode_bit(mode, is_owner, is_member)
    -- 返回该用户能访问的 r/w/x 位集合 (0-7)
    if is_owner then
        return math.floor(mode / 64)  -- owner 位在高 3 bit
    end
    if is_member then
        return math.floor(mode / 8) % 8  -- group 位在中间 3 bit
    end
    return mode % 8  -- others 位在低 3 bit
end

local function has_bit(user_bits, required)
    -- user_bits: 0-7, 每 bit: 4=read, 2=write, 1=execute
    if required == "read" then
        return user_bits % 8 >= 4
    elseif required == "write" then
        return user_bits % 4 >= 2
    elseif required == "enter" then
        return user_bits % 2 == 1
    end
    return false
end

local function _check_perm(session, path, required_action, depth)
    if depth > MAX_RECURSE then
        return false, "路径层级过深，拒绝访问"
    end

    local perm = get_resource_permission(path)

    if not perm then
        local parent = path:gsub("/[^/]+$", "")
        if parent == "" or parent == path or parent == "/" then
            return true
        end
        return _check_perm(session, parent, required_action, depth + 1)
    end

    local is_owner = (perm.owner_id == session.user_id)
    local is_member = _M.user_in_group(session.user_id, perm.group_id)
    local user_bits = check_mode_bit(perm.mode or 0, is_owner, is_member)

    if has_bit(user_bits, required_action) then
        return true
    end

    return false, "权限不足: 需要 " .. required_action .. " 权限"
end

function _M.check_permission(session, path, required_action)
    -- admin 拥有所有权限 (root)
    if session.role == "admin" then
        return true
    end

    -- delete 检查父目录的 w 位
    if required_action == "delete" then
        local parent = path:gsub("/[^/]+$", "")
        if parent == "" or parent == path then parent = "/" end
        return _M.check_permission(session, parent, "write")
    end

    return _check_perm(session, path, required_action, 0)
end

function _M.set_owner(path, owner_id, group_id, resource_type)
    local perm = get_resource_permission(path)
    if not perm then
        perm = {
            resource_path = path,
            resource_type = resource_type or "file",
            owner_id = owner_id,
            group_id = group_id,
            mode = 420,  -- 0644 default for files
            created_at = os.time(),
            updated_at = os.time()
        }
    else
        perm.owner_id = owner_id
        if group_id then perm.group_id = group_id end
    end
    perm.updated_at = os.time()
    local perms = load_permissions()
    perms[perm.resource_path] = perm
    save_all_permissions(perms)
    return true
end

function _M.set_mode(path, mode, session)
    local ok, err = _M.check_permission(session, path, "write")
    if not ok and session.role ~= "admin" then
        -- owner or admin can chmod
        local perm = get_resource_permission(path)
        if not perm or perm.owner_id ~= session.user_id then
            return false, err or "需要所有者或管理员权限"
        end
    end

    local perms = load_permissions()
    local perm = perms[path]
    if not perm then
        perm = {
            resource_path = path,
            resource_type = "file",
            owner_id = session.user_id,
            group_id = "",
            mode = mode,
            created_at = os.time(),
            updated_at = os.time()
        }
    else
        perm.mode = mode
    end
    perm.updated_at = os.time()
    perms[path] = perm
    save_all_permissions(perms)
    return true
end

function _M.get_permissions(path)
    return get_resource_permission(path)
end

-- 获取所有用户
function _M.get_all_users()
    return load_users()
end

-- 创建用户
function _M.create_user(username, password, role, primary_group, creator_session)
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
        primary_group = primary_group or "g_users",
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