--[[
侧边栏文件夹配置初始化
从环境变量 SIDEBAR_FOLDERS 读取配置，格式：
  SIDEBAR_FOLDERS="name1:path1,name2:path2,..."
示例：
  SIDEBAR_FOLDERS="应用与数据:/usrdata,U盘:/mnt/usbdisk,临时目录:/tmp"
]]

local cjson = require "cjson"

local config = ngx.shared.sidebar_config

-- 解析 SIDEBAR_FOLDERS 环境变量
local env = os.getenv("SIDEBAR_FOLDERS")
if env and env ~= "" then
    local folders = {}
    for entry in env:gmatch("[^,]+") do
        local name, path = entry:match("^([^:]+):(.+)$")
        if name and path then
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            path = path:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" and path ~= "" then
                table.insert(folders, { name = name, path = path })
            end
        end
    end
    if #folders > 0 then
        local ok, err = config:set("sidebar_folders", cjson.encode(folders))
        if not ok then
            ngx.log(ngx.ERR, "sidebar_init: failed to set sidebar_folders: ", err)
        else
            ngx.log(ngx.INFO, "sidebar_init: loaded ", #folders, " sidebar folders")
        end
    end
else
    -- 默认配置
    local default_folders = {
        { name = "应用与数据", path = "/usrdata" },
        { name = "U盘", path = "/mnt/usbdisk" },
        { name = "临时目录", path = "/tmp" }
    }
    local ok, err = config:set("sidebar_folders", cjson.encode(default_folders))
    if not ok then
        ngx.log(ngx.ERR, "sidebar_init: failed to set default sidebar_folders: ", err)
    end
end

-- 同步更新 ALLOWED_ROOTS（通过共享字典共享给 files.lua）
local folders_json, err = config:get("sidebar_folders")
if folders_json then
    local ok, folders = pcall(cjson.decode, folders_json)
    if ok and folders then
        local roots = {}
        local roots_arr = {}
        for _, f in ipairs(folders) do
            roots[f.path] = true
            table.insert(roots_arr, f.path)
        end
        config:set("allowed_roots", cjson.encode(roots))
        config:set("allowed_roots_arr", cjson.encode(roots_arr))
    end
end
