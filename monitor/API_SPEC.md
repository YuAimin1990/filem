# 资源监控模块 API 规范

## 1. 概述

| 项目 | 说明 |
|------|------|
| 基础 URL | `http://{host}:8090/monitor/api/` |
| 协议 | HTTP/1.1 |
| 数据格式 | JSON |
| 编码 | UTF-8 |

## 2. 认证

监控 API（`/monitor/api/`）无需认证。

文件管理 API 和用户管理 API 需要认证，详见 `FILE_API_SPEC.md`。

## 3. 通用响应格式

```json
{
    "code": 0,
    "message": "success",
    "data": { }
}
```

### 错误码定义

| 错误码 | 说明 |
|--------|------|
| 0 | 成功 |
| -400 | 请求参数错误 |
| -404 | 资源不存在 |
| -405 | 方法不允许 |
| -500 | 服务器内部错误 |

## 4. API 列表

### 4.1 获取监控状态

**GET** `/monitor/api/?action=status`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| action | string | 否 | 操作类型，默认为 `status` |

> **注意**: 所有 API 的 `action` 参数都是可选的，默认为 `status`。

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "running": true,
        "interval": 30,
        "status_text": "运行中"
    }
}
```

#### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| running | boolean | 监控是否运行中 |
| interval | integer | 数据采集间隔（秒） |
| status_text | string | 状态描述文本 |

---

### 4.2 获取系统快照

**GET** `/monitor/api/?action=snapshot`

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "system": {
            "timestamp": 1704067200,
            "uptime": 86400,
            "memory": {
                "total": 8589934592,
                "used": 4294967296
            },
            "cpu": {
                "total": { "usage": 25, "idle": 75 },
                "cores": [
                    { "id": 0, "usage": 20, "idle": 80 },
                    { "id": 1, "usage": 30, "idle": 70 }
                ]
            },
            "fd": { "used": 1024, "total": 65535 },
            "process_count": 45,
            "partitions": [
                {
                    "name": "/dev/mmcblk0p1",
                    "mount": "/",
                    "total": 10737418240,
                    "used": 5368709120,
                    "free": 5368709120,
                    "percent": 50
                }
            ]
        },
        "processes": [
            {
                "pid": 1234,
                "name": "nginx",
                "rss": 10485760,
                "vsz": 20971520,
                "cpu": 5,
                "threads": 4,
                "fd": 15,
                "status": "Normal",
                "rss_percent": 10
            }
        ],
        "total_rss": 104857600,
        "alerts": {
            "normal": 10,
            "warning": 2,
            "critical": 1,
            "threshold_hint": "RSS > 50MB"
        }
    }
}
```

---

### 4.3 获取历史趋势

**GET** `/monitor/api/?action=trend&range={range}`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| range | string | 否 | 时间范围：1m, 15m, 1h, 6h（默认 15m） |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "range": "15m",
        "points": [
            {
                "time": 1704067200,
                "memory": 4096,
                "cpu": 25
            }
        ]
    }
}
```

---

### 4.4 获取告警日志

**GET** `/monitor/api/?action=alerts`

#### 响应示例

```json
{
    "code": 0,
    "data": [
        {
            "time": "12:00:00",
            "level": "Normal",
            "message": "系统监控运行中"
        },
        {
            "time": "11:59:30",
            "level": "Warning",
            "message": "进程 nginx (PID 1234) 资源占用较高"
        }
    ]
}
```

---

### 4.5 获取仪表盘聚合数据（推荐）

**GET** `/monitor/api/?action=dashboard&range={range}`

合并返回 status + snapshot + alert_logs + trend，**建议前端使用此接口减少请求数**。

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| range | string | 否 | 时间范围：1m, 15m, 1h, 6h（默认 15m） |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "status": {
            "running": true,
            "interval": 30,
            "status_text": "运行中"
        },
        "snapshot": {
            "system": { },
            "processes": [ ],
            "total_rss": 104857600,
            "alerts": { }
        },
        "alert_logs": [ ],
        "trend": {
            "range": "15m",
            "points": [ ]
        }
    }
}
```

---

### 4.6 获取进程趋势

**GET** `/monitor/api/?action=process_trend&pid={pid}&range={range}`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| pid | integer | 是 | 进程 ID |
| range | string | 否 | 时间范围：1m, 15m, 1h, 6h（默认 15m） |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "pid": 1234,
        "range": "15m",
        "points": [
            {
                "time": 1704067200,
                "rss": 10485760,
                "rss_mb": 10,
                "threads": 4,
                "fd": 15,
                "cpu_percent": 5
            }
        ]
    }
}
```

---

### 4.7 获取进程详情

**GET** `/monitor/api/?action=process_detail&pid={pid}`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| pid | integer | 是 | 进程 ID |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "pid": 1234,
        "name": "nginx",
        "status": "Normal",
        "rss": 10485760,
        "pss": 9437184,
        "vms": 20971520,
        "threads": 4,
        "fd": 15,
        "cpu_percent": 5,
        "rss_percent": 10,
        "trend": [
            { "time": 1704067200, "rss": 10, "cpu_percent": 5 }
        ]
    }
}
```

---

### 4.8 控制监控状态

**POST** `/monitor/api/`

#### 请求体

```json
{
    "action": "start"
}
```

#### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| action | string | 是 | start / pause / stop |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "running": true,
        "interval": 30,
        "status_text": "运行中"
    }
}
```

## 5. 前端优化建议

### 4.1 请求合并策略

| 场景 | 推荐做法 | 请求数 |
|------|----------|--------|
| 页面加载/定时刷新 | 使用 `action=dashboard` | 1 |
| 选中进程查看详情 | 复用列表数据 + `action=process_trend` | 1 |
| 切换时间范围 | 仅刷新对应图表接口 | 1 |

### 4.2 刷新频率建议

- 仪表盘数据：每 5 秒 1 次
- 进程趋势图：仅在选中/切换范围时加载

## 6. 数据结构定义

### ProcessStatus（进程状态）

| 值 | 说明 | 判定条件 |
|----|------|----------|
| Normal | 正常 | RSS ≤ 20MB 且 线程数 ≤ 20 |
| Warning | 警告 | RSS > 20MB 或 线程数 > 20 |
| Critical | 严重 | RSS > 50MB 或 线程数 > 30 |

> 注：代码中判定条件见 `collect_data.lua`，文档 threshold_hint 提示 "RSS > 50MB"

### TimeRange（时间范围）

| 值 | 数据点数 | 时间跨度 |
|----|----------|----------|
| 1m | 2 | 1 分钟 |
| 15m | 30 | 15 分钟 |
| 1h | 60 | 1 小时 |
| 6h | 72 | 6 小时 |

> 数据采集间隔为 30 秒，因此 6 小时只保留 72 个采样点。
