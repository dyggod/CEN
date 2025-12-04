# Keltner Webhook Server

这是一个本地 Webhook 服务器，用于接收 cTrader Keltner Signal cBot 的交易信号，自动截图并发送邮件通知。

## 🚀 快速开始

### 1. 安装 Node.js

如果还没有安装 Node.js：
- 访问 https://nodejs.org/
- 下载并安装 LTS 版本（推荐 18.x 或更高）

### 2. 安装依赖

打开命令行（CMD 或 PowerShell），进入 `node_server` 目录：

```bash
cd node_server
npm install
```

**注意：** PM2 会在首次使用时自动安装（如果使用 PM2 启动脚本）

这将安装所需的依赖包：
- `express` - Web 服务器框架
- `nodemailer` - 邮件发送
- `screenshot-desktop` - 屏幕截图
- `cors` - 跨域支持

### 3. 配置邮箱

编辑 `server.js` 文件，找到配置区域：

```javascript
const CONFIG = {
    EMAIL: {
        FROM: '648093171@qq.com',        // 您的发件邮箱
        TO: 'dyggod@163.com',            // 接收邮箱
        SMTP_HOST: 'smtp.qq.com',
        SMTP_PORT: 465,
        SMTP_PASSWORD: 'your-qq-auth-code-here'  // ⚠️ 改成您的授权码！
    }
};
```

**重要：获取 QQ 邮箱授权码**

1. 登录 QQ 邮箱网页版：https://mail.qq.com
2. 设置 → 账户 → 开启 SMTP 服务
3. 点击"生成授权码"
4. 按提示发送短信验证
5. 复制 16 位授权码
6. 粘贴到 `SMTP_PASSWORD`

### 4. 启动服务器

**方法 A：使用 PM2（推荐生产环境）**

双击运行：`PM2启动.bat`

或命令行：
```bash
npm run pm2:start
```

**优点：**
- ✅ 后台运行，不占用终端
- ✅ 自动重启，稳定可靠
- ✅ 可设置开机自启
- ✅ 便于管理和监控

详见：[PM2使用指南.md](./PM2使用指南.md)

---

**方法 B：普通启动（开发测试）**

双击运行：`快速启动.bat`

或命令行：
```bash
npm start
```

**优点：**
- ✅ 简单直接
- ✅ 实时查看日志

**缺点：**
- ❌ 需要保持终端窗口打开
- ❌ 关闭窗口即停止服务

---

如果一切正常，你会看到：

```
🚀 Keltner Webhook 服务器启动成功!
====================================================
📡 监听地址: http://localhost:5000
📧 邮件发送: 648093171@qq.com → dyggod@163.com
📸 截图目录: D:\code\trading_pine\node_server\screenshots
====================================================

可用端点:
  GET  /health      - 健康检查
  POST /test        - 测试连接（不截图）
  POST /screenshot  - 接收信号 + 截图 + 发邮件
  POST /notify      - 仅发送邮件通知
====================================================

等待信号中...
```

## 🧪 测试服务器

### 测试 1：健康检查

在浏览器中打开：
```
http://localhost:5000/health
```

应该看到：
```json
{
  "status": "OK",
  "timestamp": "2025-11-24T12:00:00.000Z",
  "service": "Keltner Webhook Server",
  "version": "1.0.0"
}
```

### 测试 2：测试连接（使用 PowerShell）

```powershell
$body = @{
    signal = "测试信号"
    message = "这是一条测试消息"
    symbol = "XAUUSD"
    timeframe = "m15"
    price = 4100.50
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:5000/test" -Method Post -Body $body -ContentType "application/json"
```

### 测试 3：测试截图和邮件

```powershell
$body = @{
    signal = "新压力线"
    message = "测试截图和邮件功能"
    symbol = "XAUUSD"
    timeframe = "m15"
    price = 4100.50
    timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:5000/screenshot" -Method Post -Body $body -ContentType "application/json"
```

## 📡 API 端点说明

### GET /health

健康检查端点，用于验证服务器是否运行。

**响应示例：**
```json
{
  "status": "OK",
  "timestamp": "2025-11-24T12:00:00.000Z"
}
```

### POST /test

测试端点，不执行截图和邮件发送，仅返回接收到的数据。

**请求体：**
```json
{
  "signal": "测试信号",
  "message": "消息内容",
  "symbol": "XAUUSD"
}
```

**响应示例：**
```json
{
  "success": true,
  "message": "测试成功！服务运行正常",
  "receivedData": { ... }
}
```

### POST /screenshot

主要端点，接收信号、截图并发送邮件。

**请求体：**
```json
{
  "signal": "新压力线",
  "message": "详细的信号信息",
  "symbol": "XAUUSD",
  "timeframe": "m15",
  "price": 4100.68,
  "timestamp": "2025-11-24 11:45:00"
}
```

**响应示例：**
```json
{
  "success": true,
  "message": "信号处理成功",
  "screenshot": "已截图并发送",
  "duration": "1234ms"
}
```

### POST /notify

仅发送邮件通知，不截图。

**请求体：**
```json
{
  "signal": "止盈成功",
  "message": "达到止盈目标",
  "symbol": "XAUUSD"
}
```

## ⚙️ 配置选项

在 `server.js` 的 `CONFIG` 对象中可以修改：

```javascript
const CONFIG = {
    // 服务器端口（默认 5000）
    PORT: 5000,
    
    // 邮件配置
    EMAIL: {
        FROM: '648093171@qq.com',
        TO: 'dyggod@163.com',
        SMTP_HOST: 'smtp.qq.com',
        SMTP_PORT: 465,
        SMTP_PASSWORD: 'your-auth-code'
    },
    
    // 截图保存路径
    SCREENSHOT_DIR: path.join(__dirname, 'screenshots'),
    
    // ⭐ 截图模式（新增）
    SCREENSHOT_MODE: 'window',  // 'window' = 仅 cTrader 窗口, 'fullscreen' = 整个屏幕
    
    // ⭐ cTrader 窗口标题（新增）
    CTRADER_WINDOW_TITLE: 'cTrader',  // 用于识别 cTrader 窗口
    
    // 截图延迟（毫秒）
    SCREENSHOT_DELAY: 500,
    
    // 临时文件保留时间（毫秒）
    TEMP_FILE_RETENTION: 10000
};
```

### 截图模式说明

#### 窗口模式（推荐）

```javascript
SCREENSHOT_MODE: 'window',
CTRADER_WINDOW_TITLE: 'cTrader',
```

**优点：**
- ✅ 仅截取 cTrader 窗口，图片更清晰
- ✅ 文件大小更小（~200KB）
- ✅ 邮件加载更快

**要求：**
- ⚠️ cTrader 窗口必须可见（不要最小化）
- ⚠️ 窗口标题包含 "cTrader"

#### 全屏模式

```javascript
SCREENSHOT_MODE: 'fullscreen',
```

**优点：**
- ✅ 兼容性好，不挑窗口
- ✅ 截取所有屏幕内容

**缺点：**
- ❌ 文件大小较大（~500KB）
- ❌ 包含不相关内容

## 📸 截图功能说明

### 工作原理

1. 接收到信号后，等待 1 秒（给窗口聚焦时间）
2. 使用 `screenshot-desktop` 库截取整个屏幕
3. 将截图保存为 PNG 格式
4. 作为邮件附件发送
5. 10 秒后自动删除临时文件

### 最佳实践

为了获得最好的截图效果：

1. **保持 cTrader 窗口可见**
   - 不要最小化
   - 不要被其他窗口完全遮挡

2. **调整窗口大小**
   - 确保图表区域清晰可见
   - 可以隐藏不必要的面板

3. **使用多显示器**
   - 将 cTrader 放在主显示器
   - 截图会捕获主显示器内容

## 🔧 故障排除

### 问题 1：截图失败

**错误信息：** `截图失败: ...`

**解决方案：**
1. 确保 cTrader 窗口没有最小化
2. 检查是否有权限限制
3. 尝试以管理员身份运行

### 问题 2：邮件发送失败

**错误信息：** `邮件发送失败: 身份验证失败`

**解决方案：**
1. 检查授权码是否正确（16位）
2. 确认 QQ 邮箱已开启 SMTP 服务
3. 检查网络连接

### 问题 3：端口被占用

**错误信息：** `Error: listen EADDRINUSE: address already in use`

**解决方案：**
1. 关闭其他占用 5000 端口的程序
2. 或修改 `CONFIG.PORT` 为其他端口

### 问题 4：依赖安装失败

**解决方案：**
```bash
# 清除缓存
npm cache clean --force

# 重新安装
rm -rf node_modules
npm install
```

## 📝 日志说明

服务器运行时会输出详细日志：

```
🔔 收到信号通知
时间: 2025-11-24 11:45:00
信号类型: 新压力线
交易品种: XAUUSD
时间周期: m15
当前价格: 4100.68
====================================================
📸 开始截图...
✅ 截图成功
💾 截图已保存: Keltner_XAUUSD_2025-11-24T11-45-00.png
📧 准备发送邮件...
✅ 邮件发送成功: <message-id>
✅ 处理完成，耗时: 1234ms
🗑️  临时文件已删除
```

## 🔄 开发模式

如果需要频繁修改代码，可以使用开发模式（自动重启）：

```bash
# 安装 nodemon（如果还没安装）
npm install -g nodemon

# 使用开发模式启动
npm run dev
```

## 📦 文件结构

```
node_server/
├── server.js           # 主服务器文件
├── package.json        # 依赖配置
├── README.md          # 说明文档（本文件）
├── screenshots/       # 截图保存目录（自动创建）
└── node_modules/      # 依赖包（npm install 后生成）
```

## 🎯 下一步

1. ✅ 启动 Webhook 服务器
2. ⏭️ 配置 cTrader cBot（参考 cBot 文档）
3. 🧪 测试信号和截图功能
4. 🚀 开始实际使用

## 📞 技术支持

如遇问题，请检查：
1. 服务器日志输出
2. 邮箱配置是否正确
3. 网络连接是否正常

---

**版本：** 1.0.0  
**更新日期：** 2025-11-24  
**作者：** Keltner Signal Team

