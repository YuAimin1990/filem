# 文件管理模块 API 规范

## 1. 概述

| 项目 | 说明 |
|------|------|
| 基础 URL | `http://{host}:8090/files/` |
| 协议 | HTTP/1.1 |
| 数据格式 | JSON / Binary |
| 编码 | UTF-8 |

## 2. 认证

所有文件管理 API 请求需要携带有效的 Session Token：

```
X-Session-Token: <session_token>
```

或通过 Cookie `session` 携带。

未认证请求将返回：

```json
{ "code": -401, "message": "请先登录" }
```

权限不足时返回：

```json
{ "code": -403, "message": "权限不足: 需要 write 权限" }
```

## 3. 安全限制

### 2.1 允许访问的根目录
- `/usrdata` - 应用数据目录
- `/mnt/usbdisk` - U盘目录
- `/tmp` - 临时目录

### 2.2 路径安全规则
- 禁止包含 `..` 的路径遍历
- 禁止访问隐藏文件 (以 `.` 开头)
- 禁止访问系统敏感目录 (`/etc`, `/root`, `/var/log`, `/proc`, `/sys`, `/dev`)

### 2.3 大小限制
| 操作 | 限制 |
|------|------|
| 单文件上传 | 100MB |
| 打包下载 | 500MB |
| 预览文件 | 1MB |

## 3. API 列表

### 3.1 列出目录内容

**GET** `/files/?path={path}&action=list`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 否 | 目录路径，默认 `/usrdata` |
| action | string | 否 | 固定值 `list` |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "path": "/usrdata",
        "parent": "/",
        "items": [
            {
                "name": "app",
                "type": "directory",
                "size": 4096,
                "size_formatted": "4.0 KB",
                "mtime": 1704067200,
                "permissions": "rwxr-xr-x"
            },
            {
                "name": "data.csv",
                "type": "file",
                "size": 102456,
                "size_formatted": "100.1 KB",
                "mtime": 1704067200,
                "permissions": "rw-r--r--",
                "mime": "text/csv"
            }
        ]
    }
}
```

#### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| name | string | 文件名 |
| type | string | `file` / `directory` / `link` |
| size | integer | 文件大小 (字节) |
| size_formatted | string | 格式化大小 (如 "4.0 KB") |
| mtime | integer | 修改时间戳 (Unix 秒) |
| permissions | string | 权限字符串 |
| mime | string | MIME 类型 (仅文件) |

---

### 3.2 下载文件

**GET** `/files/?path={path}&action=download`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 文件路径 |
| action | string | 是 | 固定值 `download` |
| inline | string | 否 | 值为 `true` 时内联显示 |

#### 响应
- 成功: 文件二进制流 + `Content-Disposition: attachment`
- 失败: JSON 错误信息

---

### 3.3 上传文件

**POST** `/files/?path={path}&action=upload&filename={filename}`

#### 请求头
```
Content-Type: multipart/form-data
```

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 否 | 目标目录，默认 `/usrdata` |
| action | string | 是 | 固定值 `upload` |
| filename | string | 是 | 文件名 |
| file | binary | 是 | 文件内容 (form-data) |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "name": "uploaded.txt",
        "size": 1024,
        "path": "/usrdata/uploaded.txt"
    }
}
```

---

### 3.4 创建目录

**POST** `/files/?path={path}&action=mkdir`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 新目录完整路径 |
| action | string | 是 | 固定值 `mkdir` |

---

### 3.5 移动/重命名文件

**PUT** `/files/`

#### 请求体

```json
{
    "action": "move",
    "src": "/usrdata/old.txt",
    "dst": "/usrdata/new.txt"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| action | string | 是 | `move` / `rename` |
| src | string | 是 | 源路径 |
| dst | string | 是 | 目标路径 |

---

### 3.6 保存文件

**PUT** `/files/`

#### 请求体

```json
{
    "action": "save",
    "path": "/usrdata/config.json",
    "content": "{\n  \"key\": \"value\"\n}"
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| action | string | 是 | 固定值 `save` |
| path | string | 是 | 文件路径 |
| content | string | 是 | 文件内容 |

#### 行为说明
- 如果文件已存在，自动创建备份 (`原文件名.bak.时间戳`)
- 原子写入：先写新内容，备份旧文件

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "path": "/usrdata/config.json",
        "message": "保存成功",
        "backup": "/usrdata/config.json.bak.20260331_080000"
    }
}
```

---

### 3.7 删除文件/目录

**DELETE** `/files/?path={path}&recursive={recursive}`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 要删除的路径 |
| recursive | string | 否 | 值为 `true` 时递归删除目录 |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "path": "/usrdata/temp",
        "message": "删除成功"
    }
}
```

#### 限制
- 不允许删除根目录 (`/usrdata`, `/mnt/usbdisk`, `/tmp`)

---

### 3.8 打包目录

**POST** `/files/?path={path}&action=pack`

将目录打包为 tar.gz 归档文件，存放于 `/tmp/`。

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 要打包的目录路径 |
| action | string | 是 | 固定值 `pack` |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "archive": "/tmp/local_1704067200.tar.gz",
        "name": "local.tar.gz",
        "size": 3342368,
        "size_formatted": "3.2 MB",
        "source_size": 66146304,
        "source_size_formatted": "63.1 MB"
    }
}
```

#### 前端下载流程
1. POST 打包请求，获取 `archive` 路径
2. 使用 `GET /files/?action=download&path={archive路径}` 下载归档

---

### 3.9 预览文本文件

**GET** `/files/?path={path}&action=preview&maxSize={maxSize}`

#### 请求参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 文件路径 |
| action | string | 是 | 固定值 `preview` |
| maxSize | integer | 否 | 最大读取字节数，默认 1048576 (1MB) |

#### 响应示例

```json
{
    "code": 0,
    "data": {
        "path": "/usrdata/log.txt",
        "size": 1024,
        "encoding": "utf-8",
        "content": "Line 1\nLine 2\nLine 3...",
        "truncated": false,
        "lines": 50,
        "mime": "text/plain"
    }
}
```

---

## 4. 错误码

| 错误码 | 说明 |
|--------|------|
| 0 | 成功 |
| -400 | 请求参数错误 |
| -401 | 未登录（需要认证） |
| -403 | 权限不足（路径不允许访问或缺少操作权限） |
| -404 | 文件/目录不存在 |
| -409 | 文件已存在 (上传时) |
| -413 | 文件过大 |
| -415 | 文件类型不支持预览 |
| -422 | 文件名非法 (含非法字符/过长/系统保留名) |
| -500 | 服务器内部错误 |

## 5. 前端交互

### 5.1 键盘快捷键
| 快捷键 | 功能 |
|--------|------|
| F5 | 刷新文件列表 |
| Delete | 删除选中项 |
| Ctrl+A | 全选 |
| Ctrl+F | 聚焦搜索框 |
| Esc | 取消选择/关闭对话框 |
| Alt+← | 后退 |
| Alt+→ | 前进 |
| Alt+↑ | 返回上级目录 |

### 5.2 交互操作
- 双击目录进入，双击文件预览
- 单击选中，Ctrl+单击多选，Shift+单击范围选
- 拖拽文件到目录树可移动文件
- 拖拽文件到列表区域可上传
- 右键菜单：打开/下载/编辑/预览/重命名/删除

---

**API 版本**: 1.2
**最后更新**: 2026-04-27
