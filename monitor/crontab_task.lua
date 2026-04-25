-- 监控模块 crontab 任务管理
local Crontab_model = require "htwtime.crontab.Crontab_model"
local Crontab_operation = require "htwtime.crontab.Crontab_operation"

local _M = {}

-- 任务 ID
_M.ID = "system_monitor"

-- 启用监控任务
function _M.enable_monitor(interval_sec)
    interval_sec = interval_sec or 30
    
    Crontab_operation.prepare_crontab_path()
    
    local model = Crontab_model:new(_M.ID)
    
    -- 计算 crontab 时间格式
    -- 每 interval_sec 秒执行一次
    if interval_sec < 60 then
        -- 少于60秒，使用 */n 格式
        model.minute = "*"
    else
        model.minute = "*/" .. math.floor(interval_sec / 60)
    end
    model.hour = "*"
    model.day = "*"
    model.month = "*"
    model.days_of_week = "*"
    
    -- 执行命令
    model.command = "/awork/xserver/monitor/collect.sh"
    
    local code, message = Crontab_operation.add_or_update_according_id(model)
    return code, message
end

-- 禁用监控任务
function _M.disable_monitor()
    Crontab_operation.remove_by_id(_M.ID)
    return 0, "OK"
end

-- 检查监控任务是否启用
function _M.is_enabled()
    local model = Crontab_operation.query_crontab_with_id(_M.ID)
    return model ~= nil
end

return _M
