# 系统监控仪表板

基于 OpenResty + LuaJIT + Alpine.js 的实时系统监控解决方案，提供 CPU、内存、进程、磁盘等系统指标的可视化监控。

## 目录结构

```
monitor/
├── collect_data.lua      # 数据采集脚本（核心）
├── collect.sh            # 数据收集入口脚本
├── view/
│   ├── api.lua          # 监控 REST API 接口
│   ├── auth.lua         # 认证与权限模块（核心）
│   ├── auth_entry.lua   # 认证 API 入口
│   ├── users_entry.lua  # 用户管理 API 入口（admin only）
│   ├── perms_entry.lua  # 权限管理 API 入口
│   ├── files.lua        # 文件操作核心逻辑
│   └── files_entry.lua  # 文件管理 API 入口
├── data/
│   ├── monitor.jsonl    # 监控数据存储（JSONL格式）
│   ├── users.jsonl      # 用户数据存储
│   └── permissions.jsonl # 权限数据存储
├── lib/                 # 前端静态资源
│   ├── alpine.js        # Alpine.js 响应式框架
│   ├── chart.js         # Chart.js 图表库
│   ├── htmx.js          # HTMX 动态加载
│   ├── tailwindcss.js   # TailwindCSS 样式框架
│   └── tailwind.min.css # TailwindCSS 最小化样式
├── monitor.md           # 设计文档
└── README.md            # 本文件
```

## 工作原理

### 数据采集流程

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

### 数据存储格式

采用 **JSONL** (JSON Lines) 格式，每行一个完整的 JSON 对象：

```json
{
  "timestamp": 1740723600,
  "memory": {"total": 476651520, "used": 122990592, "free": 262533120},
  "cpu": {
    "total": {"usage": 21, "idle": 78},
    "cores": [{"id": 0, "usage": 26, "idle": 5}, ...]
  },
  "process_count": 15,
  "processes": [...],
  "partitions": [...],
  "fd": {"used": 1120, "total": 44690},
  "alerts": [...]
}
```

### 采集的数据源

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

## 配置说明

### 1. 用户认证系统

系统内置用户认证和权限控制，首次启动自动创建默认管理员账户。

**默认管理员**: 用户名 `admin`，密码通过环境变量 `ADMIN_PASSWORD` 设置（未设置时自动生成随机密码并输出到日志）

**认证方式**: Session Token（存储在 nginx `lua_shared_dict user_sessions`）

**角色权限**:
| 角色 | 说明 |
|------|------|
| admin | 管理员，拥有所有权限，可管理用户和所有文件 |
| user | 普通用户，只能访问自己创建的文件或被授权的文件 |

**认证流程**:
1. 前端登录后获取 session_token，存储在 localStorage
2. 后续请求通过 `X-Session-Token` 请求头或 `session` Cookie 携带
3. 未登录访问受保护页面时，重定向到登录页（带 `?next=` 参数）
4. 登录成功后自动跳转回原页面

**前端页面**:
| 页面 | 路径 | 说明 |
|------|------|------|
| 登录页 | `/monitor/login.html` | 用户认证入口 |
| 文件管理器 | `/monitor/files.html` | 文件浏览与管理（需登录） |
| 用户管理 | `/monitor/users.html` | 用户 CRUD（仅 admin） |
| 系统监控 | `/monitor/index.html` | 系统指标监控（无需登录） |

### 2. Nginx 路由配置

在 `running/conf/nginx.conf` 中添加：

```nginx
lua_shared_dict user_sessions 2m;  # session 存储
```

在 `running/conf/nginx.conf` 中配置应用根目录：

```nginx
env APP_ROOT=/path/to/fm;
```

在 `running/conf/site.conf` 中配置路由（使用相对路径）：

```nginx
# Monitor module routes
location /monitor/api {
    default_type 'application/json';
    content_by_lua_file ../monitor/view/api.lua;
}

# Auth API
location /api/auth {
    default_type 'application/json';
    content_by_lua_file ../monitor/view/auth_entry.lua;
}

# User management API (admin only)
location /api/users {
    default_type 'application/json';
    content_by_lua_file ../monitor/view/users_entry.lua;
}

# Permission API
location /api/permissions {
    default_type 'application/json';
    content_by_lua_file ../monitor/view/perms_entry.lua;
}

# File manager API
location ^~ /files/ {
    default_type 'application/json';
    content_by_lua_file ../monitor/view/files_entry.lua;
}

location /monitor/ {
    alias html/monitor/;
    index index.html;
    try_files $uri $uri/ =404;
}
```

访问地址：
- 仪表板：`http://<host>:8095/monitor/`
- 文件管理器：`http://<host>:8095/monitor/files.html`
- 用户管理：`http://<host>:8095/monitor/users.html`（需 admin）
- 认证 API：`http://<host>:8095/api/auth/login`

### 3. 数据采集配置

编辑 `collect_data.lua` 修改配置参数：

```lua
-- 数据文件存储路径
local data_file = "/usrdata/app/xserver/monitor/data/monitor.jsonl"

-- 最大保留历史记录数（防止文件无限增长）
local max_lines = 1000

-- 采集间隔：在 run_collector.sh 中设置（默认 30 秒）
```

### 4. 启动数据采集

**方式一：手动启动**

```bash
cd /usrdata/app/xserver/monitor
sh run_collector.sh &
```

**方式二：开机自启**（添加到 `/usrdata/run.sh`）

```bash
# 延迟10秒启动监控收集器，等待系统初始化完成
(sleep 10 && sh /usrdata/app/xserver/monitor/run_collector.sh) &
```

## API 接口文档

### 认证 API

#### 登录

```http
POST /api/auth/login
Content-Type: application/json

{ "username": "admin", "password": "<your-password>" }
```

响应：
```json
{
  "code": 0,
  "data": {
    "session_token": "hex_token...",
    "user": { "id": "admin", "username": "admin", "role": "admin" }
  }
}
```

#### 获取当前会话

```http
GET /api/auth/session
X-Session-Token: <token>
```

#### 登出

```http
POST /api/auth/logout?action=logout
X-Session-Token: <token>
```

### 用户管理 API（仅 admin）

#### 用户列表

```http
GET /api/users
X-Session-Token: <token>
```

#### 创建用户

```http
POST /api/users
X-Session-Token: <token>
Content-Type: application/json

{ "username": "alice", "password": "<user-password>", "role": "user" }
```

#### 更新用户

```http
PUT /api/users?action=update&id=<user_id>
X-Session-Token: <token>
Content-Type: application/json

{ "password": "newpass", "role": "user" }
```

#### 删除用户

```http
DELETE /api/users?action=delete&id=<user_id>
X-Session-Token: <token>
```

### 监控 API

#### 获取实时快照

```http
GET /monitor/api/?action=snapshot
```

响应：
```json
{
  "code": 0,
  "data": {
    "system": {
      "timestamp": 1740723600,
      "memory": {"total": 512000000, "used": 123000000},
      "cpu": {"total": {"usage": 21}, "cores": [...]},
      "fd": {"used": 1120, "total": 44690},
      "process_count": 15,
      "partitions": [...]
    },
    "processes": [...],
    "alerts": {...}
  }
}
```

### 2. 获取历史趋势

```http
GET /monitor/api/?action=trend&range=15m
```

参数：
- `range`: 时间范围，可选 `1m`, `15m`, `1h`, `6h`

响应：
```json
{
  "code": 0,
  "data": {
    "range": "15m",
    "points": [
      {"time": 1740723500, "memory": 120, "cpu": 18},
      {"time": 1740723530, "memory": 121, "cpu": 22},
      ...
    ]
  }
}
```

### 3. 获取进程趋势

```http
GET /monitor/api/?action=process_trend&pid=1234&range=15m
```

响应：
```json
{
  "code": 0,
  "data": {
    "pid": 1234,
    "points": [
      {"time": 1740723500, "rss": 42000, "rss_mb": 42, "cpu_percent": 5},
      ...
    ]
  }
}
```

### 4. 获取进程详情

```http
GET /monitor/api/?action=process_detail&pid=1234
```

## 前端功能

### 页面布局

两栏式响应式布局：

```
┌─────────────────────────────────────────────────────────┐
│                   顶部控制区                              │
├────────────────────────┬────────────────────────────────┤
│       左栏 (33%)       │          右栏 (67%)            │
│  ┌─────────────────┐   │  ┌─────────────────────────┐   │
│  │   系统概览       │   │  │     系统整体趋势         │   │
│  │  - CPU使用率     │   │  │  (内存 + CPU 双轴线图)    │   │
│  │  - 内存使用      │   │  └─────────────────────────┘   │
│  │  - 文件句柄      │   │  ┌─────────────────────────┐   │
│  │  - 进程数        │   │  │     进程详情与趋势       │   │
│  └─────────────────┘   │  │  (点击进程后显示)         │   │
│  ┌─────────────────┐   │  │  - 内存趋势 + CPU趋势      │   │
│  │   进程列表       │   │  │  - 关键指标 (RSS/PSS等)   │   │
│  │  (Top 10 by RSS)│   │  └─────────────────────────┘   │
│  └─────────────────┘   │                                │
│  ┌─────────────────┐   │                                │
│  │   分区使用       │   │                                │
│  └─────────────────┘   │                                │
│  ┌─────────────────┐   │                                │
│  │   告警/事件      │   │                                │
│  └─────────────────┘   │                                │
└────────────────────────┴────────────────────────────────┘
```

### 进程状态标识

| 状态 | 条件 | 颜色 |
|------|------|------|
| Critical | RSS > 50MB 或 线程 > 30 | 红色 |
| Warning | RSS > 20MB 或 线程 > 20 | 黄色 |
| Normal | 其他 | 绿色 |

### 自动刷新

- 数据每 5 秒自动刷新
- 趋势图默认显示 1 分钟范围（可切换 15m/1h/6h）

## 性能优化

### 1. 数据读取优化

使用 `tail` 命令只读取文件尾部，避免加载整个大文件：

```lua
-- 优化前：读取整个文件
local f = io.open(DATA_FILE, "r")
for line in f:lines() do ... end

-- 优化后：只读取尾部 N 行
local handle = io.popen("tail -n " .. n .. " " .. DATA_FILE)
```

### 2. CPU 计算优化

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

### 3. 数据文件限制

设置 `max_lines = 1000`，防止数据文件无限增长：

```lua
if #lines >= max_lines then
    start_idx = #lines - max_lines + 2
end
```

## 故障排查

### 问题：页面加载缓慢

**原因**：数据文件过大，API 读取缓慢

**解决**：
1. 检查 `monitor/data/monitor.jsonl` 大小
2. 如超过 10MB，可手动清空或减小 `max_lines`
3. 确保使用了 `read_tail_lines` 优化

### 问题：CPU 显示为 0%

**原因**：`/proc/stat` 是累计值，需要计算差值

**解决**：检查 `collect_data.lua` 是否正确实现了两次采样

### 问题：进程 FD 全为 0

**原因**：权限不足，无法访问其他进程的 `/proc/[pid]/fd/`

**解决**：以 root 运行收集器，或接受此限制（不影响主要功能）

### 问题：数据不更新

**检查步骤**：

```bash
# 1. 检查收集器是否在运行
ps | grep collect

# 2. 检查数据文件是否有新内容
tail -5 /usrdata/app/xserver/monitor/data/monitor.jsonl

# 3. 手动测试采集
/usrdata/app/bin/luajit monitor/collect_data.lua
```

## 扩展开发

### 添加新指标

1. 在 `collect_data.lua` 中添加采集函数
2. 将数据加入 `main()` 返回的 data 表
3. 在 `api.lua` 中添加对应接口
4. 在 `index.html` 中添加展示组件

### 修改告警阈值

编辑 `collect_data.lua`：

```lua
if rss_mb > 100 or p.threads > 50 then
    p.status = "Critical"
elseif rss_mb > 50 or p.threads > 30 then
    p.status = "Warning"
end
```

## 依赖说明

- **后端**: OpenResty/Nginx + LuaJIT
- **前端**: Alpine.js (响应式) + Chart.js (图表) + TailwindCSS (样式)
- **数据存储**: JSONL 文本文件（无需数据库）

所有前端库均为本地静态文件，无 CDN 依赖，适合离线环境使用。
