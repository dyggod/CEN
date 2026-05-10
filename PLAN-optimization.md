# CEN 仓库优化计划

## Context
该仓库是一个连接 MT5 EA 和 cTrader cBot 的交易消息中间件 Node.js 服务器。经全面审查，发现以下可优化领域：安全风险（SMTP 密码明文硬编码）、配置与代码耦合严重、server.js 单文件达 1230 行、内存管理无清理机制、优雅关闭不完整。

---

## 优化项

### 1. 安全：SMTP 密码迁移到 .env
- **问题**: `server.js:26` 明文存储 QQ 邮箱授权码 (`lmefrkcflwgrbecb`)，已提交到 git 历史
- **方案**:
  - 新建 `.env.example`，添加 `SMTP_PASSWORD`、`EMAIL_FROM`、`EMAIL_TO` 等变量
  - server.js 中 `CONFIG.EMAIL.SMTP_PASSWORD` 改为 `process.env.SMTP_PASSWORD || 'your-qq-auth-code-here'`
  - 更新 `.gitignore` 确保 `.env` 不被提交
  - **注意**: 不删除已有的 CONFIG 默认值，保持向后兼容
- **涉及文件**: `server.js`, `.gitignore`, `.env.example`（新建）

### 2. 配置提取到独立模块
- **问题**: 服务器端口、账户白名单、账户映射等所有配置硬编码在 server.js 顶部
- **方案**: 新建 `config.js`，从 `server.js` 中提取整个 `CONFIG` 对象，支持 `process.env` 覆盖
- **涉及文件**: `config.js`（新建）, `server.js`

### 3. server.js 模块化拆分
- **问题**: 1230 行单文件，所有路由、业务逻辑、工具函数混杂
- **方案**: 按职责拆分：
  - `routes/health.js` - 健康检查
  - `routes/trade.js` - 交易相关（POST /trade, /position/report）
  - `routes/queue.js` - 队列相关（GET /queue/read, /queue/stats）
  - `routes/screenshot.js` - 截图邮件（POST /screenshot, /notify, /test）
  - `services/email.js` - 邮件服务
  - `services/screenshot.js` - 截图服务
  - `middleware/auth.js` - 账户验证中间件
  - `middleware/errorHandler.js` - 统一错误处理
- **涉及文件**: 新建 `routes/`, `services/`, `middleware/` 目录及文件, `server.js` 大幅精简

### 4. 内存管理：定期清理过期数据
- **问题**: `positionData` 和 `lastEmailSentTime` 会无限增长，长期运行可能内存泄漏
- **方案**: 添加定时清理任务，定期清理超过 `MT5_POSITION_STALE_MS` 阈值的陈旧仓位记录
- **涉及文件**: `server.js`

### 5. 优雅关闭改进
- **问题**: SIGINT/SIGTERM 直接 `process.exit(0)`，不关闭 HTTP 服务器，可能丢失正在处理的请求
- **方案**: 先调用 `server.close()` 再退出
- **涉及文件**: `server.js`

### 6. 日志系统增强
- **问题**: 所有日志使用 `console.log/error`，无日志级别区分
- **方案**: 添加简单的日志工具模块 `tools/logger.js`，支持 `info/warn/error/debug` 级别以及时间戳前缀
- **涉及文件**: `tools/logger.js`（新建），逐步替换 server.js 中的 `console.log` 调用

### 7. 状态管理优化
- **问题**: 模块级全局变量（positionData, lastEmailSentTime）放在 server.js 中，拆分后需要集中管理
- **方案**: 新建 `state.js` 管理所有应用状态，提供读写接口和过期清理方法
- **涉及文件**: `state.js`（新建）

---

## 执行顺序

1. 创建 `.env.example` 和更新 `.gitignore`（安全先行）
2. 创建 `tools/logger.js`（日志工具）
3. 创建 `config.js`（配置提取）
4. 创建 `state.js`（状态管理）
5. 创建 `middleware/auth.js`, `middleware/errorHandler.js`
6. 创建 `services/email.js`, `services/screenshot.js`
7. 创建 `routes/` 下的各路由文件
8. 重写 `server.js` 为入口文件，组装各模块
9. 更新 `pm2/ecosystem.config.js` 环境变量配置

---

## 验证方式
- 启动服务器: `node server.js` 确认启动日志正常
- `GET /health` 返回 200
- `POST /trade` 发送交易消息，确认队列正常
- `GET /queue/read?accountId=xxx` 读取消息
- 检查 `.env` 配置是否被正确读取
