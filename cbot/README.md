# Queue Reader Bot - cTrader 消息队列读取机器人

## 📋 功能说明

这是一个 cTrader 的 cBot 程序，默认每 **100ms** 请求一次 `GET /queue/lease`（单次最多 **10** 条），在主线程执行交易后 `POST /queue/ack` 确认；仍可将 **ServerURL** 设为 `/queue/read` 使用旧版单条读即删。

## 🚀 安装步骤

### 1. 复制文件到 cTrader

将 `QueueReaderBot.cs` 文件复制到 cTrader 的 cBot 目录：

```
C:\Users\你的用户名\Documents\cTrader\cBots\
```

或者通过 cTrader 菜单：
- 在 cTrader 中：**Automate** → **新建 cBot**
- 复制代码到编辑器中

### 2. 编译 cBot

1. 在 cTrader 的 **Automate** 模块中
2. 找到 `QueueReaderBot`
3. 点击 **"编译"** 按钮
4. 检查编译输出，确保没有错误

### 3. 配置网络权限

**重要：** cBot 需要网络访问权限才能发送 HTTP 请求。

在 cBot 代码中已经设置了：
```csharp
[Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.Internet)]
```

如果编译时提示需要权限，请确认：
- cTrader 设置中允许 cBot 访问网络
- 防火墙允许 cTrader 访问本地服务器

### 4. 运行 cBot

1. 在 **Automate** 模块中找到 `QueueReaderBot`
2. 点击 **"启动"** 按钮
3. cBot 将按「轮询间隔 + lease 周期」拉取队列（默认约每 100ms 一轮，含网络与执行时间）

## ⚙️ 参数说明

cBot 提供以下可配置参数：

- **ServerURL** (默认: `http://127.0.0.1:6699/queue/lease`)
  - 使用 **lease 批量** 时指向 `/queue/lease`；若改为 `.../queue/read` 则走旧协议（无 ack）
  
- **RequestIntervalMs** (默认: 100)：上一轮「GET + 主线程处理 + POST ack」结束后再开始下一轮的最短间隔（毫秒）
- **LeaseBatchLimit** (默认: 10)：单次 `GET /queue/lease` 最多取几条（上限 50，与 Node 一致）
- **LeaseTtlMs** (默认: 120000)：服务端 lease 超时未 ack 时自动回队（毫秒）

## 📊 运行状态

cBot 运行后会在 cTrader 的 **日志** 窗口中显示信息：

- ✅ 请求成功时会显示消息的详细信息（操作类型、订单类型、交易品种、价格等）
- ⚠️ 队列为空时会显示提示信息
- ❌ 请求失败时会显示错误信息
- 📊 cBot 停止时会显示统计信息（总请求数、成功数、失败数）

### 示例日志输出：

```
Queue Reader Bot 已启动
服务器地址: http://127.0.0.1:6699/queue/lease
轮询间隔: 100 ms（定时器 0.1 s）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2025-12-05 00:30:01] 收到消息 #1
操作类型: open
订单类型: buy
交易品种: EURUSD
手数: 0.1
价格: 1.0850
订单号: 123456
时间 (UTC+8): 2025/12/05 00:22:52
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
队列剩余: 5 条消息
```

## ⚠️ 常见问题

### 1. 编译错误

**问题：** 找不到 `System.Text.Json` 命名空间

**解决：** 
- cTrader 可能不支持 `System.Text.Json`，代码已使用兼容方式
- 如果仍有问题，可以简化JSON解析，直接打印原始响应

### 2. 网络连接失败

**问题：** 无法连接到服务器

**解决：**
- 确保 Node.js 服务器正在运行（端口 6699）
- 检查服务器地址是否正确
- 检查防火墙设置
- 可以在浏览器中访问 `http://127.0.0.1:6699/queue/read` 测试

### 3. cBot 不工作

**检查清单：**
- ✅ cBot 已启动
- ✅ 服务器正在运行
- ✅ 网络权限已启用
- ✅ 服务器地址配置正确

## 🔧 技术说明

- **语言：** C#
- **平台：** cTrader
- **请求方式：** HTTP GET
- **请求频率：** 每秒 1 次（可配置）
- **超时时间：** 5 秒

## 📝 注意事项

1. 此 cBot **不会进行任何交易操作**，仅用于读取消息队列
2. 消息读取后会自动从队列中删除（FIFO方式）
3. 如果队列为空，cBot 会继续运行但不会报错
4. 建议在测试环境中先验证功能

## 🛑 停止 cBot

要停止 cBot，只需在 cTrader 的 **Automate** 模块中点击 **"停止"** 按钮。

cBot 停止时会自动显示统计信息。

