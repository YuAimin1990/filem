# FM — File Manager & System Monitor

基于 OpenResty + Lua + Alpine.js 的轻量级文件管理和系统监控 Web 系统。

## 功能特性

### 用户认证与权限
- 用户登录/登出（Session Token 认证）
- 管理员和普通用户两种角色
- 文件级权限控制（读/写/删除/管理）
- 默认管理员账户：`admin`（首次启动自动创建，密码请查看日志输出或通过环境变量 `ADMIN_PASSWORD` 设置）
- 未登录自动重定向到登录页（支持 `?next=` 回跳）
- 权限不足时显示友好错误提示

### 文件管理器
- 可视化目录浏览（左侧树形导航 + 右侧文件列表）
- 文件上传、下载、预览、编辑
- 文本编辑器（行号、当前行指示、Markdown 实时预览）
- 目录创建、打包下载（tar.gz）
- 批量文件打包
- **可配置的侧边栏文件夹**（通过环境变量自定义名称和路径）

### 系统监控
- 实时 CPU、内存、磁盘、分区监控
- Top 进程列表（按内存/CPU 排序）
- 历史趋势图表
- 告警规则（内存占用、线程数阈值）

### 用户管理（仅管理员）
- 创建、编辑、删除用户
- 角色分配（admin/user）
- 密码修改（带确认校验）
- 自我保护（不可删除自己、不可修改自己角色）

## 目录结构

```
fm/
├── start.sh              # 启动脚本
├── stop.sh               # 停止脚本
├── restart.sh            # 重启脚本
├── data/                 # 运行时数据（监控历史等）
│
├── running/              # 运行时目录（配置、HTML、日志）
│   ├── conf/
│   │   ├── nginx.conf        # 主配置
│   │   ├── site.conf         # 站点路由配置
│   │   ├── httpserver.conf   # HTTP 服务器配置
│   │   └── sidebar_init.lua  # 侧边栏配置初始化
│   └── html/
│       ├── index.html        # 首页
│       ├── monitor/          # 监控模块页面
│       │   ├── index.html    # 监控仪表板
│       │   ├── login.html    # 登录页
│       │   ├── files.html    # 文件管理器
│       │   └── users.html    # 用户管理页（admin）
│       └── static/           # 前端静态资源
│
├── monitor/              # 后端模块
│   ├── view/
│   │   ├── api.lua           # 监控 REST API
│   │   ├── auth.lua          # 认证与权限核心模块
│   │   ├── auth_entry.lua    # 认证 API 入口
│   │   ├── users_entry.lua   # 用户管理 API 入口
│   │   ├── perms_entry.lua   # 权限管理 API 入口
│   │   ├── files.lua         # 文件操作核心逻辑
│   │   └── files_entry.lua   # 文件 API 入口
│   ├── collect_data.lua      # 系统数据采集脚本
│   ├── collect.sh            # 采集入口
│   └── data/                 # 数据存储（JSONL）
│       ├── monitor.jsonl     # 监控数据
│       ├── users.jsonl       # 用户数据
│       └── permissions.jsonl # 权限数据
│
└── openresty/            # OpenResty 运行时（bundled）
    ├── nginx/sbin/nginx
    ├── luajit/
    └── lualib/
```

## 快速启动

```bash
cd /awork/fm
bash start.sh
```

访问地址：
- 首页：`http://localhost:8095/`
- 登录页：`http://localhost:8095/monitor/login.html`
- 文件管理器：`http://localhost:8095/monitor/files.html`（需登录）
- 用户管理：`http://localhost:8095/monitor/users.html`（需 admin）
- 监控仪表板：`http://localhost:8095/monitor/`
- 文件 API：`http://localhost:8095/files/`
- 认证 API：`http://localhost:8095/api/auth/`
- 监控 API：`http://localhost:8095/monitor/api/`

## 配置说明

### 侧边栏文件夹

通过环境变量 `SIDEBAR_FOLDERS` 配置侧边栏的文件夹列表，格式：`"名称:路径,名称:路径,..."`

在 `running/conf/nginx.conf` 的 `env` 指令中修改：

```nginx
env SIDEBAR_FOLDERS=Documents:/home/user/docs,USB Drive:/mnt/usbdisk,Temp:/tmp;
```

不配置时默认使用：
- 应用与数据 → `/usrdata`
- U盘 → `/mnt/usbdisk`
- 临时目录 → `/tmp`

### 监控数据采集

采集脚本通过 crontab 定时运行，默认间隔 30 秒。可通过监控仪表板的控制按钮（开始/暂停/停止）管理。

### 文件访问路径限制

仅允许访问 `SIDEBAR_FOLDERS` 中配置的路径，不可访问系统目录（`/etc`、`/root`、`/var/log`、`/proc`、`/sys`、`/dev`）和隐藏文件。

## API 文档

### 认证 API (`/api/auth/`)

| 方法 | action | 参数 | 说明 |
|------|--------|------|------|
| POST | `login` | `username`, `password` | 登录，返回 session_token |
| POST | `logout` | - | 登出 |
| GET | `session` | - (Header: `X-Session-Token`) | 获取当前会话信息 |

所有需要认证的 API 均需在请求头携带 `X-Session-Token`。

### 用户管理 API (`/api/users/`)（仅 admin）

| 方法 | action | 参数 | 说明 |
|------|--------|------|------|
| GET | - | - | 获取用户列表 |
| POST | - | `username`, `password`, `role` | 创建用户 |
| PUT | `update` | `id`, `password?`, `role?` | 更新用户 |
| DELETE | `delete` | `id` | 删除用户 |

### 文件管理 API (`/files/`)

| 方法 | action | 参数 | 说明 |
|------|--------|------|------|
| GET | `config` | - | 获取侧边栏文件夹配置 |
| GET | `list` | `path` | 列出目录内容 |
| GET | `download` | `path`, `inline` | 下载文件 |
| GET | `preview` | `path`, `maxSize` | 预览文本文件 |
| POST | `upload` | `path`, `filename` | 上传文件 |
| POST | `mkdir` | `path` | 创建目录 |
| POST | `pack` | `path` | 打包目录为 tar.gz |
| PUT | `move` | `src`, `dst` | 移动/重命名 |
| PUT | `pack_batch` | `items[]` | 批量打包 |
| PUT | `save` | `path`, `content` | 保存文件（带备份） |
| DELETE | - | `path`, `recursive` | 删除文件/目录 |

#### 响应格式

```json
{
  "code": 0,
  "data": { ... }
}
```

`code` 非 0 表示错误。

### 监控 API (`/monitor/api/`)

| action | 参数 | 说明 |
|--------|------|------|
| `status` | - | 采集器状态 |
| `snapshot` | - | 当前系统快照 |
| `trend` | `range` (1m/15m/1h/6h) | 历史趋势 |
| `alerts` | - | 当前告警列表 |
| `dashboard` | `range` | 合并返回以上所有数据 |
| `process_trend` | `pid`, `range` | 指定进程历史 |
| `process_detail` | `pid` | 指定进程详情 |

#### 响应格式

```json
{
  "code": 0,
  "data": {
    "system": {
      "timestamp": 1743000000,
      "memory": { "total": 512000000, "used": 123000000 },
      "cpu": { "total": { "usage": 21, "idle": 79 }, "cores": [...] },
      "fd": { "used": 1120, "total": 44690 },
      "process_count": 15,
      "partitions": [...]
    },
    "processes": [...],
    "alerts": [...]
  }
}
```

## 服务管理

```bash
bash start.sh    # 启动（端口检测 + reload）
bash stop.sh     # 停止（SIGTERM 优雅退出，最长等待 15s）
bash restart.sh  # 重启（清空日志后重启）
```

## 依赖

- **运行时**: OpenResty (bundled in `openresty/`)
- **前端**: Alpine.js + TailwindCSS + Chart.js (bundled in `running/html/static/`)
- **数据存储**: JSONL 文本文件（无需数据库）

所有前端库均为本地静态文件，无 CDN 依赖，适合离线环境。
