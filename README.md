# CEN - cTrader EA Node

跨平台交易消息中间件，桥接 **MetaTrader 5 (MT5)** 和 **cTrader** 两大交易平台，实现多账户的订单同步、仓位监控与异常告警。

## 系统架构

```
┌──────────────────┐     ┌────────────────────┐     ┌──────────────────┐
│   MT5 (多账户)    │     │  Node.js 服务器      │     │  cTrader (多账户) │
│                  │     │  (端口 6699)        │     │                  │
│ HealthCheckEA    │────▶│                    │◀────│ QueueReaderBot   │
│ (MQL5)           │     │  ┌─ FIFO 消息队列 ─┐│     │ (C#)             │
│                  │     │  │ 按 MT5 账号分组  ││     │                  │
│ PositionChange   │     │  │ 去重/乱序保护    ││     │  每秒轮询队列     │
│ EmailEA (MQL5)   │     │  └────────────────┘│     │  执行交易操作     │
│                  │     │                    │     │                  │
│ POST /trade      │     │  仓位对比告警       │     │  GET /queue/read │
│ POST /position/  │     │  截图 (cTrader窗口) │     │                  │
│   report         │     │  邮件通知           │     │                  │
│ POST /health     │     │                    │     │                  │
└──────────────────┘     └────────────────────┘     └──────────────────┘
```

**数据流：**
1. MT5 EA 检测到交易事件 → `POST /trade` 推送到 Node 服务器
2. 服务器按 MT5 账户 ID 存入内存 FIFO 队列（去重 + 乱序保护）
3. cTrader cBot 每秒轮询 `GET /queue/read`，获取并执行消息（开仓/平仓/修改/挂单）
4. 服务器持续对比 MT5 vs cTrader 仓位，不匹配时发邮件告警并触发同步强平

---

## 项目结构

```
CEN/
├── README.md                     # 本文档
├── AGENTS.md                     # Trellis AI 工作流配置
├── PLAN-optimization.md          # 优化计划
├── .trellis/                     # Trellis 框架目录（spec/task/workspace）
│
├── node_server/                  # Node.js 中间件服务器（核心）
│   ├── server.js                 # 主服务器（~1230行）
│   ├── config.js                 # 配置模块
│   ├── package.json              # 依赖：express, nodemailer, screenshot-desktop, cors
│   ├── tools/
│   │   ├── messageQueue.js       # FIFO 内存队列（去重、乱序保护、过期清理）
│   │   └── utils.js              # 时区转换工具
│   ├── scripts/
│   │   ├── rotate-logs.js        # 日志按日自动滚动归档
│   │   └── clear-logs.js         # 日志清理工具
│   ├── pm2/
│   │   ├── ecosystem.config.js   # PM2 进程管理配置
│   │   ├── PM2启动.bat           # 快捷启动脚本
│   │   ├── PM2停止.bat
│   │   ├── PM2重启.bat
│   │   ├── PM2查看状态.bat
│   │   ├── PM2查看日志.bat
│   │   └── PM2设置开机启动.bat
│   ├── capture-window.ps1        # cTrader 窗口截图 PowerShell 脚本
│   ├── list-windows.ps1          # 列出可见窗口的 PowerShell 脚本
│   ├── 快速启动.bat               # 普通启动脚本
│   ├── 一键诊断.bat               # 诊断工具
│   ├── logs/                     # 日志目录
│   └── screenshots/              # 截图缓存目录
│
├── ea/                           # MT5 Expert Advisors (MQL5)
│   ├── HealthCheckEA.mq5         # 健康检查 + 交易事件推送 EA
│   └── PositionChangeEmailEA.mq5 # 仓位变动邮件通知 EA
│
└── cbot/                         # cTrader cBot (C#)
    └── QueueReaderBot.cs         # 消息队列读取与执行 cBot
```

---

## 组件详情

### 1. Node.js 服务器 (`node_server/server.js`)

核心消息中间件，运行在端口 **6699**。

**功能：**
- 接收 MT5 EA 的交易事件并写入 FIFO 消息队列
- 提供队列读取接口供 cTrader cBot 轮询
- 对比 MT5 vs cTrader 仓位，不匹配时发送邮件告警
- 下发同步强平指令（syncCloseInstructions）
- 截图 cTrader 窗口并通过邮件发送
- 内置去重（指纹窗口 5 分钟）和乱序保护
- 内存队列上限 1000 条/账户，自动清理过期指纹

**配置项（`CONFIG` 对象）：**
| 配置 | 说明 |
|------|------|
| `PORT` | 服务器端口（默认 6699） |
| `EMAIL` | QQ 邮箱 SMTP 配置 |
| `SCREENSHOT_MODE` | 截图模式：`window` 或 `fullscreen` |
| `ALLOWED_ACCOUNTS.MT5` | 允许的 MT5 账户白名单 |
| `ALLOWED_ACCOUNTS.CTRADER` | 允许的 cTrader 账户白名单 |
| `ACCOUNT_MAPPING` | cTrader 账户 → MT5 账户的映射关系 |
| `POSITION_CHECK_SYMBOLS` | 仓位检查的交易品种（默认 XAUUSD） |
| `MT5_UTC_OFFSET` | EA 服务器时区偏移（默认 UTC+3） |

**API 端点：**
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/health` | 健康检查 |
| POST | `/test` | 测试连接 |
| POST | `/screenshot` | 接收信号 + 截图 + 发邮件 |
| POST | `/notify` | 仅发送邮件通知 |
| POST | `/trade` | 接收 EA 交易事件（开/关/改/挂单） |
| POST | `/position/report` | 接收 EA 仓位快照 |
| GET | `/queue/read` | cBot 读取队列消息（FIFO） |
| GET | `/queue/stats` | 队列统计信息 |

---

### 2. MT5 EA 层 (`ea/`)

#### HealthCheckEA.mq5
- 每秒发送心跳到服务器
- 监听 `OnTradeTransaction` 事件，推送交易信息到 `POST /trade`
- 定时上报仓位快照到 `POST /position/report`
- 自动将 `XAUUSDm`、`XAUUSD-ECN` 归一化为 `XAUUSD`
- 处理开仓、平仓、挂单添加/修改/删除等事件

#### PositionChangeEmailEA.mq5
- 每秒检测仓位变动（开/改/平）
- 通过 MT5 `SendMail()` 发送仓位变动邮件
- 支持止盈/止损/手动平仓等不同平仓原因的区分
- 内含频率限制和重试队列

---

### 3. cTrader cBot (`cbot/QueueReaderBot.cs`)

- 每秒轮询 `GET /queue/read`
- 上报当前 cTrader 仓位统计
- 执行以下消息类型：
  - `open` — 市价开仓（带 TP/SL）
  - `close` — 按订单号平仓
  - `modify` — 修改止盈止损
  - `pending_open` — 挂单（限价/止损）
  - `pending_modify` — 修改挂单
  - `pending_cancel` — 撤销挂单
- 支持服务端下发的同步强平指令
- 使用 `QueueBot_<MT5账户>_<PositionId>` 标签实现幂等控制
- 消息过期丢弃机制（排除 `pending_cancel`）

---

## 安装与部署

### Node.js 服务器

```bash
cd node_server
npm install

# 配置邮箱授权码（编辑 config.js 或设置环境变量）
export SMTP_PASSWORD="your-qq-auth-code"

# 启动（开发）
npm start

# 启动（生产，推荐 PM2）
npm run pm2:start
```

### MT5 EA

1. 将 `.mq5` 文件复制到 MT5 的 `MQL5/Experts/` 目录
2. 在 MetaEditor 中编译（F7）
3. 在 MT5 中启用 **工具 → 选项 → 专家顾问 → 允许 WebRequest**
4. 添加 `http://localhost:6699` 到允许 URL 列表
5. 将 EA 拖到图表上运行

### cTrader cBot

1. 将 `QueueReaderBot.cs` 复制到 `Documents/cTrader/cBots/`
2. 在 cTrader Automate 中编译并启动
3. 确保网络权限已启用（`AccessRights.Internet`）

---

## 安全注意事项

- **SMTP 授权码** 请勿硬编码在代码中，使用环境变量 `SMTP_PASSWORD` 配置
- **账户白名单** 已启用，需在 `ALLOWED_ACCOUNTS` 中注册才可访问
- 端口 **6699** 仅供本地访问，请勿暴露到公网

---

## 开发

### 依赖

```
node >= 18
npm
```

### 本地开发

```bash
cd node_server
npm run dev          # nodemon 自动重启
node scripts/rotate-logs.js   # 手动日志归档
node scripts/clear-logs.js    # 清理日志
```

---

## 变更历史

| 日期 | 提交 | 说明 |
|------|------|------|
| - | `247a574` | 初始 Node 服务器 |
| - | `daed3e2` | V1.0 基础功能 |
| - | `b9ed0a8` | V1.1 改进 |
| - | `8d5619a` | 固定手数设置 |
| - | `d4cf241` | 日志清理工具 |
| - | `3108f86` | V1.2 账户ID映射 + 重复推送过滤 |
| - | `2bdc099` | EA 到 cBot 仓位不匹配通知 |
| - | `4210600` | 仓位判断过滤 + cTrader 仓位与 MT5 Position ID 绑定 |
| - | `074063b` | MT5 对 cBot 的强平同步 |
| - | `1f6e598` | Label 添加 MT5 账户绑定 |
| - | `00e3c2e` | 按 MT5 账号过滤的仓位同步告警 |
| - | `5fc3d28` | 时间按时间戳统一 + EA 上报 XAUUSDm 等同于 XAUUSD |
| - | `b91bcbf` / `9969dbd` | 功能优化更新 |
| - | `8ab4588` | 代码优化 |
| - | `ef3999e` | 添加邮件 EA（PositionChangeEmailEA） |

---

## 维护

### 日志管理
- 自动按自然日滚动归档到 `logs/history/`
- 也可手动运行 `npm run logs:rotate` 或 `npm run logs:clear`

### PM2 常用命令
```bash
pm2 status                     # 查看状态
pm2 logs EA&CTrader-Webhook    # 查看日志
pm2 restart EA&CTrader-Webhook # 重启服务
pm2 monit                      # 资源监控
```

### 监听方式
- cBot 每秒轮询 `/queue/read`
- HealthCheckEA 每秒发送心跳
- PositionChangeEmailEA 每秒检测仓位变动
- 服务器每 10 分钟检查日志滚动
