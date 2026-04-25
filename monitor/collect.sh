#!/bin/bash
# 监控数据收集脚本入口
# 由 crontab 定时调用

cd /usrdata/app/xserver
export LUA_PATH='lib/?.lua;htwtime/?.lua;;'

# 使用设备上的 luajit 执行数据收集脚本
/usrdata/app/bin/luajit monitor/collect_data.lua
