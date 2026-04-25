# 监控模块技术实现文档

本文档描述监控模块的内部实现细节，供开发和维护人员参考。

---

## 1. 架构概述

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  collect.sh     │────▶│ collect_data.lua│────▶│ monitor.jsonl   │
│  (定时触发)      │     │ (数据收集逻辑)   │     │ (JSONL存储)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                              ┌─────────────────────────┘
                              ▼
                       ┌─────────────────┐
                       │   view/api.lua  │
                       │  (REST API接口)  │
                       └─────────────────┘
                               │
                               ▼
                       ┌─────────────────┐
                       │  index.html     │
                       │  (前端仪表板)   │
                       └─────────────────┘
```

---

## 2. 数据存储

### 2.1 存储格式

监控数据以 **JSONL** (JSON Lines) 格式存储：
- 文件路径: `/usrdata/app/xserver/monitor/data/monitor.jsonl`
- 每行一个完整的 JSON 对象
- 追加写入，不修改历史数据

### 2.2 数据保留策略

| 配置项 | 值 | 说明 |
|--------|-----|------|
| 最大保留记录数 | 1000 | 超过后自动删除最旧的数据 |
| 采集间隔 | 30 秒 | 固定值 |
| 理论保留时间 | ~8.3 小时 | 1000 × 30 秒 |

### 2.3 单行数据示例

```json
{
  "timestamp": 1740723600,
  "uptime": 3600,
  "memory": {"total": 476651520, "used": 122990592, "free": 262533120},
  "cpu": {
    "total": {"usage": 21, "idle": 78},
    "cores": [{"id": 0, "usage": 26, "idle": 5}]
  },
  "process_count": 15,
  "processes": [...],
  "partitions": [...],
  "fd": {"used": 1120, "total": 44690},
  "alerts": [...],
  "loadavg": {"load1": 3.81, "load5": 3.72, "load15": 2.29}
}
```

---

## 3. 数据采集

### 3.1 数据源

| 指标 | 数据源 | 采集方式 |
|------|--------|----------|
| 内存使用 | `/proc/meminfo` | 解析 MemTotal/MemFree/Buffers/Cached |
| CPU 总体使用率 | `/proc/stat` | 两次采样差值计算 |
| 各核心使用率 | `/proc/stat` | cpu0, cpu1, ... 逐核解析 |
| 负载均衡 | `/proc/loadavg` | 1/5/15分钟负载 |
| 进程列表 | `/proc/[pid]/status` | 遍历 /proc 目录 |
| 进程 CPU | `top -bn1` | 解析 top 输出 |
| 进程内存 | `/proc/[pid]/statm` | RSS/VmSize |
| 分区使用 | `df -k` | 磁盘空间统计 |
| 文件句柄 | `/proc/sys/fs/file-nr` | 系统级句柄统计 |
| 进程 FD | `/proc/[pid]/fd/` | 目录链接计数 |
| 运行时间 | `/proc/uptime` | 系统启动时间 |

### 3.2 CPU 计算优化

采用两次采样差值法计算实时 CPU 使用率：

```lua
-- 采样1
local stats1 = parse_cpu_line(read_file("/proc/stat"))
os.execute("sleep 1")
-- 采样2
local stats2 = parse_cpu_line(read_file("/proc/stat"))
-- 计算差值
local usage = (stats2.used - stats1.used) / (stats2.total - stats1.total)
```

### 3.3 进程状态分级

```lua
if rss > 50MB or threads > 30 then
    status = "Critical"
elseif rss > 20MB or threads > 20 then
    status = "Warning"
else
    status = "Normal"
end
```

---

## 4. API 实现优化

### 4.1 数据读取优化

使用 `tail` 命令只读取文件尾部，避免加载整个大文件：

```lua
-- 优化前：读取整个文件
local f = io.open(DATA_FILE, "r")
for line in f:lines() do ... end

-- 优化后：只读取尾部 N 行
local handle = io.popen("tail -n " .. n .. " " .. DATA_FILE)
```

### 4.2 参数校验

- **action 白名单**: status, snapshot, trend, alerts, process_trend, process_detail
- **range 白名单**: 1m, 15m, 1h, 6h
- **pid 校验**: 正整数 1 ~ 2147483647

### 4.3 错误响应规范

| HTTP 状态码 | 场景 |
|-------------|------|
| 200 | 请求成功处理（含业务逻辑错误） |
| 400 | 请求参数错误 |
| 404 | URL 路径不存在 |
| 405 | 方法不允许 |
| 500 | 服务器内部错误 |

---

## 5. Nginx 配置

### 5.1 路由配置

```nginx
# API 接口
location ~ ^/monitor/api/ {
    default_type 'application/json';
    content_by_lua_file ../monitor/view/api.lua;
}

# 静态页面
location /monitor/ {
    alias html/monitor/;
    index index.html;
    try_files $uri $uri/ =404;
}
```

### 5.2 访问控制（建议）

```nginx
location ~ ^/monitor/api/ {
    # 仅允许本机/内网访问
    allow 127.0.0.1;
    # allow 192.168.0.0/16;
    deny all;
    
    content_by_lua_file ../monitor/view/api.lua;
}
```

### 5.3 CORS 配置（如需跨域）

```nginx
location ~ ^/monitor/api/ {
    add_header 'Access-Control-Allow-Origin' '*';
    add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
    add_header 'Access-Control-Allow-Headers' 'Content-Type';
    add_header 'Access-Control-Max-Age' '600';
    
    if ($request_method = 'OPTIONS') {
        return 204;
    }
    
    content_by_lua_file ../monitor/view/api.lua;
}
```

### 5.4 限流配置（可选）

```nginx
location ~ ^/monitor/api/ {
    limit_req_zone $binary_remote_addr zone=monitor:10m rate=10r/s;
    limit_req zone=monitor burst=20 nodelay;
    
    content_by_lua_file ../monitor/view/api.lua;
}
```

---

## 6. 部署说明

### 6.1 文件结构

```
monitor/
├── collect_data.lua      # 数据采集脚本
├── collect.sh            # 数据收集入口脚本
├── view/
│   ├── api.lua          # 监控 REST API 接口
│   ├── auth.lua         # 认证与权限模块（核心）
│   ├── auth_entry.lua   # 认证 API 入口（login/logout/session）
│   ├── users_entry.lua  # 用户管理 API（CRUD，admin only）
│   ├── perms_entry.lua  # 权限管理 API
│   ├── files.lua        # 文件操作核心逻辑
│   └── files_entry.lua  # 文件管理 API 入口
├── data/
│   ├── monitor.jsonl    # 监控数据存储
│   ├── users.jsonl      # 用户数据（JSONL）
│   └── permissions.jsonl # 权限数据（JSONL）
└── README.md            # 使用文档

running/html/monitor/
├── index.html           # 系统监控仪表板（无需登录）
├── login.html           # 登录页
├── files.html           # 文件管理器（需登录）
└── users.html           # 用户管理页（需 admin）
```

### 6.2 启动数据采集

**方式一：手动启动**
```bash
cd /usrdata/app/xserver/monitor
sh run_collector.sh &
```

**方式二：开机自启**（添加到 `/usrdata/run.sh`）
```bash
(sleep 10 && sh /usrdata/app/xserver/monitor/run_collector.sh) &
```

### 6.3 运行状态检查

```bash
# 检查收集器是否在运行
ps | grep collect

# 检查数据文件
ls -lh /usrdata/app/xserver/monitor/data/monitor.jsonl

# 查看最新数据
tail -1 /usrdata/app/xserver/monitor/data/monitor.jsonl
```

---

## 7. 认证与权限系统

### 7.1 架构

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  login.html  │────▶│ auth_entry   │────▶│  auth.lua        │
│  (前端登录)   │     │ (API路由)     │     │  (核心逻辑)      │
└─────────────┘     └──────────────┘     ├─────────────────┤
                                          │ user_sessions   │
┌─────────────┐     ┌──────────────┐     │ (nginx shared   │
│  users.html  │────▶│ users_entry  │────▶│  dict)          │
│  (用户管理)   │     │ (API路由)     │     ├─────────────────┤
└─────────────┘     └──────────────┘     │ users.jsonl     │
                                          │ permissions.jsonl│
                                          └─────────────────┘
```

### 7.2 认证方式

- **Session Token**: 登录后生成 64 字符 hex token
- **存储**: `lua_shared_dict user_sessions`（nginx 内存，TTL 24 小时）
- **传递方式**: `X-Session-Token` 请求头 或 `session` Cookie
- **前端存储**: localStorage（`session_token`、`user`）

### 7.3 密码安全

- 使用 SHA256 + salt 迭代哈希（10000 次）
- 格式: `salt:iterations:hash`
- 每次哈希使用独立随机 salt

### 7.4 权限模型

| 角色 | 说明 | 权限范围 |
|------|------|----------|
| admin | 管理员 | 所有文件完全控制 + 用户管理 |
| user | 普通用户 | 自己创建的文件 + 被授权的文件 |

权限级别（递增）: `read` < `write` < `delete` < `admin`

权限检查顺序:
1. admin 角色 → 完全放行
2. 文件所有者 → admin 级别
3. 显式授权（用户级别或 `*` 全体）
4. 父目录继承权限

### 7.5 默认管理员

首次加载 `auth.lua` 时自动创建:
- 用户名: `admin`
- 密码: 通过环境变量 `ADMIN_PASSWORD` 设置，未设置时自动生成随机密码（输出到 nginx 日志）
- 角色: `admin`

### 7.6 前端认证流程

1. 用户访问受保护页面（`files.html`、`users.html`）
2. `checkAuth()` 检查 localStorage 中的 session_token
3. 无 token → 重定向到 `/monitor/login.html?next=<当前路径>`
4. 有 token → 调用 `/api/auth/session` 验证
5. 验证失败 → 清除本地存储并重定向到登录页
6. 登录成功 → 跳转到 `?next=` 指定的页面（带安全校验）

### 7.7 重定向安全

`login.html` 中 `sanitizeRedirect()` 函数防止开放重定向攻击:
- 必须以 `/` 开头
- 不能以 `//` 开头（协议相对 URL）
- 不能包含 `:` 字符
- 不合法时回退到 `/monitor/files.html`

---

## 8. 故障排查

### 8.1 页面加载缓慢

**原因**: 数据文件过大，API 读取缓慢

**解决**: 检查文件大小，如超过 10MB 可手动清空或减小 max_lines

### 8.2 CPU 显示为 0%

**原因**: `/proc/stat` 是累计值，需要计算差值

**解决**: 检查 collect_data.lua 是否正确实现了两次采样

### 8.3 进程 FD 全为 0

**原因**: 权限不足，无法访问其他进程的 `/proc/[pid]/fd/`

**解决**: 以 root 运行收集器，或接受此限制

### 8.4 数据不更新

**检查步骤**:
```bash
# 1. 检查收集器是否在运行
ps | grep collect

# 2. 检查数据文件是否有新内容
tail -5 /usrdata/app/xserver/monitor/data/monitor.jsonl

# 3. 手动测试采集
/usrdata/app/bin/luajit monitor/collect_data.lua
```

---

## 9. 已知限制

| 限制项 | 说明 |
|--------|------|
| 进程 FD 采集 | 非 root 用户时可能返回 0 |
| 进程列表上限 | 固定返回 15 个进程 |
| 告警历史 | 仅保留最近一次采集的告警 |
| 数据存储 | 单文件 JSONL，无索引 |
| 并发写入 | 无文件锁，依赖单实例 |

---

## 10. 扩展开发

### 10.1 添加新指标

1. 在 `collect_data.lua` 中添加采集函数
2. 将数据加入 `main()` 返回的 data 表
3. 在 `api.lua` 中添加对应接口
4. 在 `index.html` 中添加展示组件

### 10.2 修改告警阈值

编辑 `collect_data.lua`：
```lua
if rss_mb > 100 or p.threads > 50 then
    p.status = "Critical"
elseif rss_mb > 50 or p.threads > 30 then
    p.status = "Warning"
end
```
