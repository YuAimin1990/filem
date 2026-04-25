local cjson = require "cjson"

local _M = {}

local DATA_DIR = "/awork/fm/monitor/data"
local DATA_FILE = DATA_DIR .. "/monitor.jsonl"
local STATE_FILE = DATA_DIR .. "/monitor_state.json"

-- action 白名单
local VALID_ACTIONS = {
    status = true,
    snapshot = true,
    trend = true,
    alerts = true,
    process_trend = true,
    process_detail = true,
    dashboard = true
}

-- range 白名单
local VALID_RANGES = {
    ["1m"] = true,
    ["15m"] = true,
    ["1h"] = true,
    ["6h"] = true
}

-- range 到 limit 的映射
local RANGE_LIMITS = {
    ["1m"] = 2,
    ["15m"] = 30,
    ["1h"] = 60,
    ["6h"] = 72
}

local function json_response(data, status)
    ngx.header.content_type = "application/json; charset=utf-8"
    ngx.header["Access-Control-Allow-Origin"] = "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "Content-Type"
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

-- 参数校验函数
local function validate_action(action)
    if not action or action == "" then
        return nil, "Missing required parameter: action"
    end
    if not VALID_ACTIONS[action] then
        return nil, "Unknown action: " .. tostring(action)
    end
    return true, nil
end

local function validate_range(range)
    if not range then
        return nil, "Missing required parameter: range"
    end
    if not VALID_RANGES[range] then
        return nil, "Invalid range: " .. tostring(range) .. ". Valid ranges: 1m, 15m, 1h, 6h"
    end
    return true, nil
end

local function validate_pid(pid_str)
    if not pid_str or pid_str == "" then
        return nil, "Missing required parameter: pid"
    end
    local pid = tonumber(pid_str)
    if not pid then
        return nil, "Invalid pid: " .. tostring(pid_str) .. ". Must be a positive integer"
    end
    if pid <= 0 or pid ~= math.floor(pid) then
        return nil, "Invalid pid: " .. tostring(pid) .. ". Must be a positive integer"
    end
    -- 检查是否超出 32 位有符号整数范围
    if pid > 2147483647 then
        return nil, "Invalid pid: " .. tostring(pid) .. ". Exceeds maximum value"
    end
    return pid, nil
end

local function read_state()
    local f = io.open(STATE_FILE, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok, state = pcall(cjson.decode, content)
        if ok then return state end
    end
    return { running = false, interval = 30, start_time = nil }
end

-- 使用 tail 命令高效读取文件尾部 N 行
local function read_tail_lines(n)
    n = n or 1
    local shell = require "resty.shell"
    local cmd = "tail -n " .. n .. " " .. DATA_FILE
    local ok, stdout, stderr, err = shell.run(cmd, nil, 3000)

    if not ok then return {} end

    local lines = {}
    for line in stdout:gmatch("[^\n]+") do
        if line:match("^%s*{") then table.insert(lines, line) end
    end
    return lines
end

local function read_latest_data()
    local lines = read_tail_lines(1)
    if #lines == 0 then return nil end
    
    local ok, data = pcall(cjson.decode, lines[1])
    if ok then return data end
    return nil
end

local function read_history_data(limit)
    limit = limit or 50
    -- 多读一些行以防止有空行或无效行
    local lines = read_tail_lines(limit * 2)
    
    local result = {}
    local start_idx = math.max(1, #lines - limit + 1)
    for i = start_idx, #lines do
        local ok, data = pcall(cjson.decode, lines[i])
        if ok and data then
            table.insert(result, {
                time = data.timestamp or 0,
                memory = math.floor((data.memory and data.memory.used or 0) / 1024 / 1024),
                cpu = data.cpu and data.cpu.total and data.cpu.total.usage or 0
            })
        end
    end
    return result
end

local function get_alert_summary(processes)
    local normal, warning, critical = 0, 0, 0
    for _, p in ipairs(processes or {}) do
        if p.status == "Normal" then normal = normal + 1
        elseif p.status == "Warning" then warning = warning + 1
        else critical = critical + 1 end
    end
    return { normal = normal, warning = warning, critical = critical, threshold_hint = "RSS > 50MB" }
end

function _M.GET()
    -- debug_log("GET called, action=" .. tostring(ngx.var.arg_action))
    local action = ngx.var.arg_action or "status"
    
    -- 校验 action 参数
    local valid, err = validate_action(action)
    if not valid then
        return json_response({ code = -400, message = err }, 400)
    end
    
    local state = read_state()
    
    if action == "status" then
        return json_response({
            code = 0,
            data = {
                running = state.running,
                interval = state.interval,
                status_text = state.running and "运行中" or "等待启动"
            }
        })
        
    elseif action == "snapshot" then
        local data = read_latest_data()
        if not data then
            return json_response({
                code = 0,
                data = {
                    system = { memory = { total = 0, used = 0 }, fd = { used = 0 }, process_count = 0, partitions = {} },
                    processes = {},
                    total_rss = 0,
                    alerts = { normal = 0, warning = 0, critical = 0, threshold_hint = "RSS > 50MB" }
                }
            })
        end
        
        local total_rss = 0
        for _, p in ipairs(data.processes or {}) do total_rss = total_rss + (p.rss or 0) end
        
        return json_response({
            code = 0,
            data = {
                system = {
                    timestamp = data.timestamp,
                    uptime = data.uptime or 0,
                    memory = data.memory,
                    cpu = data.cpu or { total = { usage = 0, idle = 0 }, cores = {} },
                    fd = data.fd,
                    process_count = data.process_count or 0,
                    partitions = data.partitions
                },
                processes = data.processes,
                total_rss = total_rss,
                alerts = get_alert_summary(data.processes)
            }
        })
        
    elseif action == "trend" then
        local range = ngx.var.arg_range or "15m"
        
        -- 校验 range 参数
        local valid, err = validate_range(range)
        if not valid then
            return json_response({ code = -400, message = err }, 400)
        end
        
        local limit = RANGE_LIMITS[range]
        return json_response({ code = 0, data = { range = range, points = read_history_data(limit) }})
        
    elseif action == "alerts" then
        local data = read_latest_data()
        local alerts = (data and data.alerts) or {{ time = os.date("%H:%M:%S"), level = "Normal", message = "系统监控运行中" }}
        return json_response({ code = 0, data = alerts })
        
    elseif action == "dashboard" then
        -- 合并返回：status + snapshot + alerts + trend
        local state = read_state()
        local data = read_latest_data()
        
        local total_rss = 0
        if data and data.processes then
            for _, p in ipairs(data.processes) do total_rss = total_rss + (p.rss or 0) end
        end
        
        -- 读取 trend 数据（默认 15m）
        local range = ngx.var.arg_range or "15m"
        if not VALID_RANGES[range] then range = "15m" end
        local trend_limit = RANGE_LIMITS[range]
        
        return json_response({
            code = 0,
            data = {
                -- status 部分
                status = {
                    running = state.running,
                    interval = state.interval,
                    status_text = state.running and "运行中" or "等待启动"
                },
                -- snapshot 部分
                snapshot = data and {
                    system = {
                        timestamp = data.timestamp,
                        uptime = data.uptime or 0,
                        memory = data.memory,
                        cpu = data.cpu or { total = { usage = 0, idle = 0 }, cores = {} },
                        fd = data.fd,
                        process_count = data.process_count or 0,
                        partitions = data.partitions
                    },
                    processes = data.processes,
                    total_rss = total_rss,
                    alerts = get_alert_summary(data.processes)
                } or {
                    system = { memory = { total = 0, used = 0 }, fd = { used = 0 }, process_count = 0, partitions = {} },
                    processes = {},
                    total_rss = 0,
                    alerts = { normal = 0, warning = 0, critical = 0, threshold_hint = "RSS > 50MB" }
                },
                -- alerts 部分
                alert_logs = data and data.alerts or {{ time = os.date("%H:%M:%S"), level = "Normal", message = "系统监控运行中" }},
                -- trend 部分
                trend = {
                    range = range,
                    points = read_history_data(trend_limit)
                }
            }
        })
        
    elseif action == "process_trend" then
        local pid_str = ngx.var.arg_pid
        local range = ngx.var.arg_range or "15m"
        
        -- 校验 pid 参数
        local pid, err = validate_pid(pid_str)
        if not pid then
            return json_response({ code = -400, message = err }, 400)
        end
        
        -- 校验 range 参数
        local valid, range_err = validate_range(range)
        if not valid then
            return json_response({ code = -400, message = range_err }, 400)
        end
        
        local limit = RANGE_LIMITS[range]
        local points = {}
        local lines = read_tail_lines(limit * 2)
        
        local start_idx = math.max(1, #lines - limit + 1)
        for i = start_idx, #lines do
            local ok, d = pcall(cjson.decode, lines[i])
            if ok and d and d.processes then
                for _, proc in ipairs(d.processes) do
                    if proc.pid == pid then
                        table.insert(points, {
                            time = d.timestamp or 0,
                            rss = proc.rss or 0,
                            rss_mb = math.floor((proc.rss or 0) / 1024 / 1024),
                            threads = proc.threads or 0,
                            fd = proc.fd or 0,
                            cpu_percent = proc.cpu or 0
                        })
                        break
                    end
                end
            end
        end
        
        return json_response({ code = 0, data = { pid = pid, range = range, points = points }})
        
    elseif action == "process_detail" then
        local pid_str = ngx.var.arg_pid
        
        -- 校验 pid 参数
        local pid, err = validate_pid(pid_str)
        if not pid then
            return json_response({ code = -400, message = err }, 400)
        end
        
        local data = read_latest_data()
        
        if not data then 
            return json_response({code = -404, message = "No data available"}, 200) 
        end
        
        for _, p in ipairs(data.processes or {}) do
            if p.pid == pid then
                local trend = {}
                local lines = read_tail_lines(20)
                
                for _, line in ipairs(lines) do
                    local ok, d = pcall(cjson.decode, line)
                    if ok and d and d.processes then
                        for _, proc in ipairs(d.processes) do
                            if proc.pid == pid then
                                table.insert(trend, { time = d.timestamp or 0, rss = math.floor((proc.rss or 0) / 1024 / 1024), cpu_percent = proc.cpu or 0 })
                                break
                            end
                        end
                    end
                end
                
                return json_response({
                    code = 0,
                    data = {
                        pid = p.pid,
                        name = p.name,
                        status = p.status,
                        rss = p.rss,
                        pss = math.floor(p.rss * 0.9),
                        vms = p.vsz,
                        threads = p.threads,
                        fd = p.fd,
                        cpu_percent = p.cpu or 0,
                        rss_percent = p.rss_percent or 0,
                        trend = trend
                    }
                })
            end
        end
        
        return json_response({code = -404, message = "Process not found"}, 404)
    end
end

local COLLECT_SCRIPT = "/awork/fm/monitor/collect_data.lua"
local CRON_TAG = "xserver_monitor"

-- 读取 crontab 内容（不含标记行）
local function read_crontab_without_tag()
    local shell = require "resty.shell"
    local ok, stdout, stderr, err = shell.run("crontab -l", nil, 3000)
    if not ok then return {} end

    local lines = {}
    for line in stdout:gmatch("[^\n]+") do
        if not line:find(CRON_TAG, 1, true) then
            table.insert(lines, line)
        end
    end
    return lines
end

local function write_crontab(lines)
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    local shell = require "resty.shell"
    local cmd = "crontab " .. tmp
    local ok, stdout, stderr, err = shell.run(cmd, nil, 3000)
    os.remove(tmp)
    return ok ~= nil
end

local function crontab_add(interval_min)
    interval_min = interval_min or 1
    local lines = read_crontab_without_tag()
    table.insert(lines, "*/" .. interval_min .. " * * * * " .. COLLECT_SCRIPT .. " # " .. CRON_TAG)
    return write_crontab(lines)
end

local function crontab_remove()
    local lines = read_crontab_without_tag()
    return write_crontab(lines)
end

function _M.POST()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    local post_data = {}

    if body then
        local ok, decoded = pcall(cjson.decode, body)
        if ok then
            post_data = decoded
        else
            return json_response({ code = -400, message = "Invalid JSON body: " .. tostring(decoded) }, 400)
        end
    end

    local action = post_data.action or "start"

    if action ~= "start" and action ~= "pause" and action ~= "stop" then
        return json_response({ code = -400, message = "Invalid action: " .. tostring(action) .. ". Valid actions: start, pause, stop" }, 400)
    end

    local state = read_state()

    if action == "start" then
        state.running = true
        state.start_time = state.start_time or os.time()
        crontab_add(state.interval and math.ceil(state.interval / 60) or 1)
    elseif action == "pause" then
        state.running = false
        crontab_remove()
    elseif action == "stop" then
        state.running = false
        state.start_time = nil
        crontab_remove()
    end

    local f = io.open(STATE_FILE, "w")
    if f then
        f:write(cjson.encode(state))
        f:close()
    else
        return json_response({ code = -500, message = "Failed to write state file" }, 500)
    end

    return json_response({
        code = 0,
        data = {
            running = state.running,
            interval = state.interval,
            status_text = state.running and "运行中" or "已暂停"
        }
    })
end

-- Execute GET handler for content_by_lua_file usage
_M.GET()
