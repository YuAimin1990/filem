#!/usr/bin/env luajit
--[[
监控数据收集脚本 - 获取真实系统数据
数据格式: JSONL (每行一个 JSON 对象)
]]

local app_root = os.getenv("APP_ROOT") or "/awork/fm"
local data_file = app_root .. "/monitor/data/monitor.jsonl"
local cpu_state_file = app_root .. "/monitor/data/cpu_state.json"
local max_lines = 1000

-- 执行 shell 命令并返回输出
local function exec_command(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null")
    if not handle then return nil end
    local result = handle:read("*a")
    handle:close()
    return result
end

-- 读取文件内容
local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- 简单的 JSON 编码
local function json_encode(obj)
    local t = type(obj)
    if t == "string" then
        return '"' .. obj:gsub('"', '\\"') .. '"'
    elseif t == "number" then
        return tostring(obj)
    elseif t == "boolean" then
        return obj and "true" or "false"
    elseif t == "table" then
        local is_array = #obj > 0
        local parts = {}
        if is_array then
            for _, v in ipairs(obj) do
                table.insert(parts, json_encode(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(obj) do
                table.insert(parts, json_encode(k) .. ":" .. json_encode(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

-- 解析 /proc/meminfo
local function get_memory_info()
    local meminfo = read_file("/proc/meminfo")
    if not meminfo then
        return { total = 512*1024*1024, used = 200*1024*1024, free = 312*1024*1024 }
    end
    
    local mem_total = meminfo:match("MemTotal:%s*(%d+)")
    local mem_free = meminfo:match("MemFree:%s*(%d+)")
    local mem_buffers = meminfo:match("Buffers:%s*(%d+)")
    local mem_cached = meminfo:match("Cached:%s*(%d+)")
    
    mem_total = tonumber(mem_total) or (512 * 1024)
    mem_free = tonumber(mem_free) or (276 * 1024)
    mem_buffers = tonumber(mem_buffers) or 0
    mem_cached = tonumber(mem_cached) or 0
    
    local mem_used = mem_total - mem_free - mem_buffers - mem_cached
    
    return {
        total = mem_total * 1024,
        used = mem_used * 1024,
        free = mem_free * 1024
    }
end

-- 解析 /proc/loadavg
local function get_loadavg()
    local loadavg = read_file("/proc/loadavg")
    if not loadavg then return { load1 = 0, load5 = 0, load15 = 0 } end
    
    local load1, load5, load15 = loadavg:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
    return {
        load1 = tonumber(load1) or 0,
        load5 = tonumber(load5) or 0,
        load15 = tonumber(load15) or 0
    }
end

-- 获取系统运行时间（从 /proc/uptime）
local function get_uptime()
    local uptime_content = read_file("/proc/uptime")
    if not uptime_content then return 0 end
    
    local uptime_seconds = uptime_content:match("^([%d%.]+)")
    return tonumber(uptime_seconds) or 0
end

-- 解析 /proc/stat 中的CPU行，返回各字段和总和
local function parse_cpu_line(line)
    if not line then return nil end
    local fields = {}
    for num in line:gmatch("%d+") do
        table.insert(fields, tonumber(num))
    end
    if #fields < 7 then return nil end
    
    local user, nice, system, idle, iowait, irq, softirq = 
        fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7]
    
    local total = user + nice + system + idle + iowait + irq + softirq
    local used = total - idle - iowait
    
    return { total = total, used = used, idle = idle }
end

-- 获取CPU使用率（使用状态文件计算差值，避免阻塞sleep）
local function get_cpu_info()
    local cpu_info = {
        cores = {},
        total = { usage = 0, idle = 0 }
    }

    -- 读取上次CPU状态（使用 loadfile 安全解析）
    local prev_state = {}
    local prev_f = io.open(cpu_state_file, "r")
    if prev_f then
        local raw = prev_f:read("*a")
        prev_f:close()
        if raw and raw ~= "" then
            local fn, err = loadstring("return " .. raw)
            if fn then
                local ok, val = pcall(fn)
                if ok then prev_state = val or {} end
            end
        end
    end

    -- 读取当前CPU状态
    local content = read_file("/proc/stat")
    if not content then return cpu_info end

    local total_now = parse_cpu_line(content:match("^cpu%s+([^\n]+)"))
    local cores_now = {}
    for core_line in content:gmatch("(cpu%d+[^\n]*)") do
        local core_id = core_line:match("cpu(%d+)")
        local stats = parse_cpu_line(core_line)
        if core_id and stats then
            cores_now[tonumber(core_id)] = stats
        end
    end

    -- 计算CPU使用率（与上次状态对比）
    if prev_state.total and total_now and total_now.total > prev_state.total.total then
        local total_diff = total_now.total - prev_state.total.total
        local used_diff = total_now.used - prev_state.total.used
        cpu_info.total.usage = math.floor(math.max(0, math.min(100, (used_diff / total_diff) * 100)))
        cpu_info.total.idle = math.floor(math.max(0, math.min(100, ((total_now.idle - prev_state.total.idle) / total_diff) * 100)))
    end

    -- 计算每个核心
    for core_id, stats_now in pairs(cores_now) do
        local stats_prev = prev_state.cores and prev_state.cores[tostring(core_id)]
        if stats_prev and stats_now.total > stats_prev.total then
            local total_diff = stats_now.total - stats_prev.total
            local used_diff = stats_now.used - stats_prev.used
            table.insert(cpu_info.cores, {
                id = core_id,
                usage = math.floor(math.max(0, math.min(100, (used_diff / total_diff) * 100))),
                idle = math.floor(math.max(0, math.min(100, ((stats_now.idle - stats_prev.idle) / total_diff) * 100)))
            })
        end
    end

    table.sort(cpu_info.cores, function(a, b) return a.id < b.id end)

    -- 保存当前状态（供下次调用使用）
    -- 格式：简单 Lua table 字面量，避免 JSON 解析依赖
    local state_f = io.open(cpu_state_file, "w")
    if state_f then
        local function format_core(c)
            return "[" .. c.id .. "]={total=" .. c.total .. ",used=" .. c.used .. ",idle=" .. c.idle .. "}"
        end
        local cores_str = "{}"
        if total_now then
            local parts = {}
            for cid, c in pairs(cores_now) do
                table.insert(parts, "[" .. cid .. "]={total=" .. c.total .. ",used=" .. c.used .. ",idle=" .. c.idle .. "}")
            end
            if #parts > 0 then cores_str = "{" .. table.concat(parts, ",") .. "}" end
        end
        local total_str = total_now
            and ("{total=" .. total_now.total .. ",used=" .. total_now.used .. ",idle=" .. total_now.idle .. "}")
            or "nil"
        state_f:write("{total=" .. total_str .. ",cores=" .. cores_str .. "}\n")
        state_f:close()
    end

    return cpu_info
end

-- 获取文件句柄使用情况
local function get_fd_info()
    local fd_info = { total = 65535, used = 0 }
    
    -- 读取 /proc/sys/fs/file-nr
    -- 格式: 已分配句柄数 已使用但未分配句柄数 最大句柄数
    local content = read_file("/proc/sys/fs/file-nr")
    if content then
        local allocated, unused, max = content:match("(%d+)%s+(%d+)%s+(%d+)")
        if allocated and max then
            fd_info.used = tonumber(allocated) - tonumber(unused)
            fd_info.total = tonumber(max)
        end
    end
    
    return fd_info
end

-- 获取进程的文件句柄数
local function get_process_fd_count(pid)
    -- 通过计数 /proc/[pid]/fd/ 目录下的链接数量
    local count = 0
    local handle = io.popen("ls /proc/" .. pid .. "/fd/ 2>/dev/null | wc -l")
    if handle then
        local result = handle:read("*a")
        handle:close()
        count = tonumber(result) or 0
    end
    return count
end

-- 获取进程CPU使用率（从top命令）

-- 获取进程CPU使用率（从top命令）
local function get_process_cpu()
    local cpu_map = {}
    local top_output = exec_command("top -bn1 2>/dev/null | head -30")
    
    if top_output then
        for line in top_output:gmatch("[^\n]+") do
            -- 匹配: PID ... %VSZ %CPU COMMAND
            -- 例如: 417   231 root     S     817m 180%   7% mpp_vio_service
            -- 需要跳过VSZ和%VSZ，直接匹配%CPU
            local pid, vsz_pct, cpu = line:match("^%s*(%d+)%s+%d+%s+%S+%s+%S+%s+%S+%s+(%d+)%%%s+(%d+)%%")
            if pid and cpu then
                cpu_map[tonumber(pid)] = tonumber(cpu) or 0
            end
        end
    end
    
    return cpu_map
end

-- 获取进程列表（通过 /proc）
local function get_process_list()
    local processes = {}
    local total_rss = 0
    
    -- 获取进程CPU映射
    local cpu_map = get_process_cpu()
    
    local handle = io.popen("ls -d /proc/[0-9]* 2>/dev/null | head -150")
    if not handle then return processes end
    
    for proc_path in handle:lines() do
        local pid = tonumber(proc_path:match("/proc/(%d+)$"))
        if pid then
            local status_content = read_file("/proc/" .. pid .. "/status")
            local statm_content = read_file("/proc/" .. pid .. "/statm")
            local cmdline = read_file("/proc/" .. pid .. "/cmdline")
            local comm = read_file("/proc/" .. pid .. "/comm")
            
            if status_content then
                local name = comm and comm:gsub("%s", "") or "unknown"
                if cmdline and #cmdline > 0 then
                    local cmd = cmdline:gsub("%z", " "):gsub("^%s*", ""):gsub("%s*$", "")
                    if #cmd > 0 then
                        name = cmd:match("([^/]+)$") or cmd
                        name = name:sub(1, 25)
                    end
                end
                
                local vmrss_kb = status_content:match("VmRSS:%s*(%d+)")
                local rss = 0
                if vmrss_kb then
                    rss = tonumber(vmrss_kb) * 1024
                else
                    local rss_pages = statm_content and tonumber(statm_content:match("^%d+%s+(%d+)")) or 0
                    rss = rss_pages * 4096
                end
                
                local vmsize_kb = status_content:match("VmSize:%s*(%d+)")
                local vsz = (tonumber(vmsize_kb) or 0) * 1024
                
                local threads = tonumber(status_content:match("Threads:%s*(%d+)")) or 1
                local ppid = tonumber(status_content:match("PPid:%s*(%d+)")) or 0
                local uid = status_content:match("Uid:%s*(%d+)") or "0"
                local state = status_content:match("State:%s*(%S+)") or "S"
                
                total_rss = total_rss + rss
                local fd_count = get_process_fd_count(pid)
                
                table.insert(processes, {
                    pid = pid,
                    name = name,
                    rss = rss,
                    vsz = vsz,
                    cpu = cpu_map[pid] or 0,
                    threads = threads,
                    fd = fd_count,
                    user = (uid == "0") and "root" or "user",
                    stat = state,
                    ppid = ppid
                })
            end
        end
    end
    handle:close()
    
    table.sort(processes, function(a, b) return a.rss > b.rss end)
    
    local result = {}
    for i = 1, math.min(15, #processes) do
        local p = processes[i]
        p.rss_percent = math.floor((p.rss / total_rss) * 100)
        
        local rss_mb = p.rss / 1024 / 1024
        if rss_mb > 50 or p.threads > 30 then
            p.status = "Critical"
        elseif rss_mb > 20 or p.threads > 20 then
            p.status = "Warning"
        else
            p.status = "Normal"
        end
        
        table.insert(result, p)
    end
    
    return result
end

-- 获取分区使用情况
local function get_partitions()
    local partitions = {}
    local df_output = exec_command("df -k 2>/dev/null")
    
    if df_output then
        for line in df_output:gmatch("[^\n]+") do
            if not line:match("^Filesystem") then
                local fs, size, used, avail, percent, mount = 
                    line:match("^([^%s]+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%%%s+(.+)$")
                
                if fs and mount then
                    table.insert(partitions, {
                        name = fs,
                        mount = mount,
                        total = (tonumber(size) or 0) * 1024,
                        used = (tonumber(used) or 0) * 1024,
                        free = (tonumber(avail) or 0) * 1024,
                        percent = tonumber(percent) or 0
                    })
                end
            end
        end
    end
    
    return partitions
end

-- 生成告警
local function get_alerts(processes)
    local alerts = {}
    local now = os.date("%H:%M:%S")
    
    for _, p in ipairs(processes) do
        if p.status == "Critical" then
            table.insert(alerts, {
                time = now,
                level = "Critical",
                message = string.format("%s (PID %d) RSS 超过阈值: %.1fMB", p.name, p.pid, p.rss/1024/1024)
            })
        elseif p.status == "Warning" then
            table.insert(alerts, {
                time = now,
                level = "Warning",
                message = string.format("%s (PID %d) 资源占用较高", p.name, p.pid)
            })
        end
    end
    
    if #alerts == 0 then
        table.insert(alerts, { time = now, level = "Normal", message = "系统监控运行中" })
    end
    
    return alerts
end

-- 主函数
local function main()
    local timestamp = os.time()
    local mem = get_memory_info()
    local loadavg = get_loadavg()
    local cpu_info = get_cpu_info()
    local processes = get_process_list()
    local partitions = get_partitions()
    local alerts = get_alerts(processes)
    local fd_info = get_fd_info()
    local uptime = get_uptime()
    
    local data = {
        timestamp = timestamp,
        uptime = uptime,
        memory = mem,
        cpu = cpu_info,
        fd = fd_info,
        process_count = #processes,
        processes = processes,
        partitions = partitions,
        alerts = alerts,
        loadavg = loadavg
    }
    
    -- 读取现有数据
    local lines = {}
    local f = io.open(data_file, "r")
    if f then
        for line in f:lines() do
            if line:match("^%s*{") then
                table.insert(lines, line)
            end
        end
        f:close()
    end
    
    -- 保留最近的数据
    local start_idx = 1
    if #lines >= max_lines then
        start_idx = #lines - max_lines + 2
    end
    
    -- 写入文件
    os.execute("mkdir -p $(dirname " .. data_file .. ")")
    f = io.open(data_file, "w")
    if not f then
        print("Error: Cannot open file for writing")
        os.exit(1)
    end
    
    for i = start_idx, #lines do
        f:write(lines[i] .. "\n")
    end
    
    f:write(json_encode(data) .. "\n")
    f:close()
    
    print("Monitor data collected at " .. os.date("%Y-%m-%d %H:%M:%S", timestamp))
    print(string.format("  Memory: %.1fMB / %.1fMB, Load: %.2f, Processes: %d",
        mem.used / 1024 / 1024, mem.total / 1024 / 1024, loadavg.load1, #processes))
    for i, p in ipairs(processes) do
        if i <= 5 then
            print(string.format("    %s(PID:%d) RSS:%.1fMB %s",
                p.name, p.pid, p.rss/1024/1024, p.status))
        end
    end
end

main()
