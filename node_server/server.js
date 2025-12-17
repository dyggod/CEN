const express = require('express');
const nodemailer = require('nodemailer');
const screenshot = require('screenshot-desktop');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);
const { convertMT5TimeToUTC8 } = require('./tools/utils');
const messageQueue = require('./tools/messageQueue');

// ==================== 配置区域 ====================
const CONFIG = {
    // 服务器端口
    PORT: 6699,
    
    // 邮件配置
    EMAIL: {
        FROM: '648093171@qq.com',
        TO: 'dyggod@163.com',
        SMTP_HOST: 'smtp.qq.com',
        SMTP_PORT: 465,
        // 重要：这里填写您的QQ邮箱授权码
        SMTP_PASSWORD: 'lmefrkcflwgrbecb'
    },
    
    // 截图保存路径
    SCREENSHOT_DIR: path.join(__dirname, 'screenshots'),
    
    // 截图模式：'window' = 仅 cTrader 窗口, 'fullscreen' = 整个屏幕
    SCREENSHOT_MODE: 'window',
    
    // cTrader 窗口标题关键词（用于窗口识别）
    CTRADER_WINDOW_TITLE: 'IC Markets cTrader 5.5.13',
    
    // 截图延迟（毫秒）- 给 cTrader 窗口聚焦的时间
    SCREENSHOT_DELAY: 500,
    
    // 临时文件保留时间（毫秒）
    TEMP_FILE_RETENTION: 10000,
    
    // 允许的账户ID列表
    ALLOWED_ACCOUNTS: {
        // MT5 账户ID列表（用于 trade 接口）
        MT5: [
            '7412666', // 真实
            '52615313' // 模拟
        ],
        // cTrader 账户ID列表（用于 queue/read 接口）
        CTRADER: [
            '6098214', // 真实
            '9694550' // 模拟
        ]
    },
    // 账户对应关系：指定哪个 cTrader 账户可以消费哪个 MT5 账户推送的消息
    // 格式：{ cTrader账户ID: [MT5账户ID1, MT5账户ID2, ...] }
    ACCOUNT_MAPPING: {
        // 默认配置：cTrader账户 6098214 可以读取 MT5账户 7412666 的消息
        '6098214': ['7412666'], // 真实 ctrader > 真实mt5
        '9694550': ['52615313'] // 模拟 ctrader > 模拟mt5
    }
};

// ==================== 初始化 ====================
const app = express();

// 中间件
app.use(cors()); // 允许跨域
app.use(express.json()); // 解析 JSON
app.use(express.urlencoded({ extended: true })); // 解析 URL 编码

// 创建截图目录
if (!fs.existsSync(CONFIG.SCREENSHOT_DIR)) {
    fs.mkdirSync(CONFIG.SCREENSHOT_DIR, { recursive: true });
    console.log(`📁 创建截图目录: ${CONFIG.SCREENSHOT_DIR}`);
}

// 配置邮件传输器
let transporter = null;
try {
    transporter = nodemailer.createTransport({
        host: CONFIG.EMAIL.SMTP_HOST,
        port: CONFIG.EMAIL.SMTP_PORT,
        secure: true,
        auth: {
            user: CONFIG.EMAIL.FROM,
            pass: CONFIG.EMAIL.SMTP_PASSWORD
        }
    });
    console.log('📧 邮件服务配置完成');
} catch (error) {
    console.error('❌ 邮件服务配置失败:', error.message);
}

// ==================== 仓位信息存储 ====================
// 存储格式: { accountId: { total: number, buy: number, sell: number, lastUpdate: timestamp } }
const positionData = {
    // MT5 (EA) 仓位信息
    mt5: {},
    // cTrader 仓位信息
    ctrader: {}
};

// ==================== 邮件发送频率控制 ====================
// 记录每个账户对的上次发送邮件时间
// 格式: { "ctraderAccountId_mt5AccountId": timestamp }
const lastEmailSentTime = {};
// 最小发送间隔（毫秒），默认2分钟
const EMAIL_NOTIFY_INTERVAL = 2 * 60 * 1000; // 5分钟

// ==================== 工具函数 ====================

/**
 * 延迟函数
 */
function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * 格式化时间戳
 */
function formatTimestamp() {
    const now = new Date();
    return now.toISOString().replace(/[:.]/g, '-').slice(0, -5);
}

/**
 * 截取 cTrader 窗口（使用 PowerShell）
 */
async function captureWindow(outputPath) {
    try {
        const psScript = path.join(__dirname, 'capture-window.ps1');
        
        // 检查脚本是否存在
        if (!fs.existsSync(psScript)) {
            throw new Error('PowerShell 脚本不存在: ' + psScript);
        }
        
        const command = `powershell -ExecutionPolicy Bypass -File "${psScript}" -WindowTitle "${CONFIG.CTRADER_WINDOW_TITLE}" -OutputPath "${outputPath}"`;
        
        console.log('📸 使用 PowerShell 截取 cTrader 窗口...');
        
        const { stdout, stderr } = await execPromise(command);
        
        if (stdout) console.log(stdout.trim());
        if (stderr) console.warn('PowerShell 警告:', stderr.trim());
        
        // 读取截图文件
        if (fs.existsSync(outputPath)) {
            const buffer = fs.readFileSync(outputPath);
            console.log('✅ 窗口截图成功');
            return buffer;
        } else {
            throw new Error('截图文件未生成');
        }
        
    } catch (error) {
        console.error('❌ 窗口截图失败:', error.message);
        throw error;
    }
}

/**
 * 截图函数（支持全屏或窗口模式）
 */
async function takeScreenshot(tempFilePath = null) {
    try {
        console.log('📸 开始截图...');
        
        // 等待一下，确保窗口状态稳定
        await sleep(CONFIG.SCREENSHOT_DELAY);
        
        let imgBuffer;
        
        if (CONFIG.SCREENSHOT_MODE === 'window') {
            // 窗口模式：仅截取 cTrader 窗口
            if (!tempFilePath) {
                tempFilePath = path.join(CONFIG.SCREENSHOT_DIR, `temp_${Date.now()}.png`);
            }
            imgBuffer = await captureWindow(tempFilePath);
        } else {
            // 全屏模式：截取整个屏幕
            console.log('📸 截取整个屏幕...');
            imgBuffer = await screenshot({ format: 'png' });
            console.log('✅ 全屏截图成功');
        }
        
        return imgBuffer;
        
    } catch (error) {
        console.error('❌ 截图失败:', error.message);
        
        // 如果窗口模式失败，尝试降级到全屏模式
        if (CONFIG.SCREENSHOT_MODE === 'window') {
            console.warn('⚠️  窗口截图失败，降级为全屏模式...');
            try {
                const imgBuffer = await screenshot({ format: 'png' });
                console.log('✅ 全屏截图成功（降级）');
                return imgBuffer;
            } catch (fallbackError) {
                console.error('❌ 全屏截图也失败:', fallbackError.message);
                throw fallbackError;
            }
        }
        
        throw error;
    }
}

/**
 * 比较仓位信息并发送通知（如果不匹配）
 */
async function compareAndNotifyPositions(ctraderAccountId, ctraderPos) {
    try {
        // 查找该 cTrader 账户对应的 MT5 账户列表
        const allowedMT5Accounts = CONFIG.ACCOUNT_MAPPING[ctraderAccountId];
        
        if (!allowedMT5Accounts || !Array.isArray(allowedMT5Accounts) || allowedMT5Accounts.length === 0) {
            // 没有配置对应关系，跳过比较
            return;
        }
        
        // 保存 cTrader 仓位信息
        positionData.ctrader[ctraderAccountId] = {
            total: ctraderPos.total || 0,
            buy: ctraderPos.buy || 0,
            sell: ctraderPos.sell || 0,
            lastUpdate: new Date().toISOString()
        };
        
        // 汇总所有对应的 MT5 账户的仓位信息
        let mt5TotalSum = 0;
        let mt5BuySum = 0;
        let mt5SellSum = 0;
        const mt5AccountDetails = []; // 记录每个 MT5 账户的详细信息
        let hasMT5Data = false;
        
        for (const mt5AccountId of allowedMT5Accounts) {
            const mt5Pos = positionData.mt5[mt5AccountId];
            
            if (mt5Pos) {
                hasMT5Data = true;
                mt5TotalSum += mt5Pos.total || 0;
                mt5BuySum += mt5Pos.buy || 0;
                mt5SellSum += mt5Pos.sell || 0;
                mt5AccountDetails.push({
                    accountId: mt5AccountId,
                    total: mt5Pos.total || 0,
                    buy: mt5Pos.buy || 0,
                    sell: mt5Pos.sell || 0,
                    lastUpdate: mt5Pos.lastUpdate
                });
            }
        }
        
        // 如果没有任何 MT5 账户上报仓位信息，跳过比较
        if (!hasMT5Data) {
            return;
        }
        
        // 比较汇总后的仓位数量
        const ctraderTotal = ctraderPos.total || 0;
        const ctraderBuy = ctraderPos.buy || 0;
        const ctraderSell = ctraderPos.sell || 0;
        
        // 检查是否不匹配
        if (ctraderTotal !== mt5TotalSum || ctraderBuy !== mt5BuySum || ctraderSell !== mt5SellSum) {
            // 生成账户对的唯一标识（使用所有 MT5 账户ID的组合）
            const mt5AccountsKey = allowedMT5Accounts.join('_');
            const accountPairKey = `${ctraderAccountId}_${mt5AccountsKey}`;
            const now = Date.now();
            const lastSentTime = lastEmailSentTime[accountPairKey] || 0;
            const timeSinceLastEmail = now - lastSentTime;
            
            // 判断是否需要发送邮件
            // 1. 第一次检测到不匹配（lastSentTime === 0）：立即发送
            // 2. 后续持续不匹配：需要间隔至少 EMAIL_NOTIFY_INTERVAL 才发送
            const shouldSendEmail = lastSentTime === 0 || timeSinceLastEmail >= EMAIL_NOTIFY_INTERVAL;
            
            if (shouldSendEmail) {
                // 构建 MT5 账户详情文本
                let mt5DetailsText = '';
                for (const detail of mt5AccountDetails) {
                    mt5DetailsText += `
MT5 账户: ${detail.accountId}
  - 总仓位: ${detail.total}
  - 多单: ${detail.buy}
  - 空单: ${detail.sell}
  - 最后更新: ${detail.lastUpdate}`;
                }
                
                // 发送邮件通知
                const emailSubject = `[仓位不匹配警告] cTrader ${ctraderAccountId} vs MT5 [${allowedMT5Accounts.join(', ')}]`;
                const emailBody = `
⚠️  仓位数量不匹配！

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 仓位对比信息
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

cTrader 账户: ${ctraderAccountId}
  - 总仓位: ${ctraderTotal}
  - 多单: ${ctraderBuy}
  - 空单: ${ctraderSell}
  - 最后更新: ${positionData.ctrader[ctraderAccountId].lastUpdate}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MT5 账户汇总（${allowedMT5Accounts.length} 个账户）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${mt5DetailsText}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📊 MT5 汇总统计
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  - 总仓位: ${mt5TotalSum}
  - 多单: ${mt5BuySum}
  - 空单: ${mt5SellSum}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔍 差异分析
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

总仓位差异: ${ctraderTotal - mt5TotalSum > 0 ? '+' : ''}${ctraderTotal - mt5TotalSum}
多单差异: ${ctraderBuy - mt5BuySum > 0 ? '+' : ''}${ctraderBuy - mt5BuySum}
空单差异: ${ctraderSell - mt5SellSum > 0 ? '+' : ''}${ctraderSell - mt5SellSum}

${ctraderTotal > 0 && mt5TotalSum === 0 ? '⚠️  警告: cTrader 有仓位但所有 MT5 EA 已空仓！' : ''}
${ctraderTotal === 0 && mt5TotalSum > 0 ? '⚠️  警告: MT5 EA 有仓位但 cTrader 已空仓！' : ''}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⏰ 检测时间
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${new Date().toLocaleString('zh-CN')}

${lastSentTime > 0 ? `\n📌 注：上次通知时间: ${new Date(lastSentTime).toLocaleString('zh-CN')}\n` : ''}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                `.trim();
                
                try {
                    await sendEmail(emailSubject, emailBody, null, null);
                    // 更新上次发送时间
                    lastEmailSentTime[accountPairKey] = now;
                    console.log(`⚠️  仓位不匹配，已发送邮件通知: cTrader ${ctraderAccountId} vs MT5 [${allowedMT5Accounts.join(', ')}]`);
                } catch (emailError) {
                    console.error('❌ 发送仓位不匹配邮件失败:', emailError.message);
                }
            } else {
                // 不发送邮件，但记录日志（降低频率）
                const remainingTime = Math.ceil((EMAIL_NOTIFY_INTERVAL - timeSinceLastEmail) / 1000);
                console.log(`⚠️  仓位不匹配（已抑制邮件，还需等待 ${remainingTime} 秒）: cTrader ${ctraderAccountId} vs MT5 [${allowedMT5Accounts.join(', ')}]`);
            }
        } else {
            // 仓位匹配，清除该账户对的发送记录（下次不匹配时立即发送）
            const mt5AccountsKey = allowedMT5Accounts.join('_');
            const accountPairKey = `${ctraderAccountId}_${mt5AccountsKey}`;
            if (lastEmailSentTime[accountPairKey]) {
                delete lastEmailSentTime[accountPairKey];
            }
        }
    } catch (error) {
        console.error('❌ 比较仓位信息失败:', error.message);
    }
}

/**
 * 发送邮件
 */
async function sendEmail(subject, body, screenshotBuffer, filename) {
    try {
        console.log('📧 准备发送邮件...');
        
        if (!transporter) {
            throw new Error('邮件服务未配置');
        }
        
        if (CONFIG.EMAIL.SMTP_PASSWORD === 'your-qq-auth-code-here') {
            throw new Error('请先配置 QQ 邮箱授权码');
        }
        
        const mailOptions = {
            from: CONFIG.EMAIL.FROM,
            to: CONFIG.EMAIL.TO,
            subject: subject,
            text: body,
            attachments: []
        };
        
        // 如果有截图，添加为附件
        if (screenshotBuffer) {
            mailOptions.attachments.push({
                filename: filename,
                content: screenshotBuffer,
                contentType: 'image/png'
            });
        }
        
        const info = await transporter.sendMail(mailOptions);
        console.log('✅ 邮件发送成功:', info.messageId);
        
        return info;
        
    } catch (error) {
        console.error('❌ 邮件发送失败:', error.message);
        throw error;
    }
}

// ==================== API 端点 ====================

/**
 * 健康检查端点
 */
app.get('/health', (req, res) => {
    res.json({
        status: 'OK',
        timestamp: new Date().toISOString(),
        service: 'Keltner Webhook Server',
        version: '1.0.0'
    });
});

/**
 * 测试端点（不截图）
 */
app.post('/test', async (req, res) => {
    try {
        console.log('🧪 收到测试请求');
        console.log('数据:', JSON.stringify(req.body, null, 2));
        
        res.json({
            success: true,
            message: '测试成功！服务运行正常',
            receivedData: req.body,
            timestamp: new Date().toISOString()
        });
        
    } catch (error) {
        console.error('❌ 测试失败:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

/**
 * 主 Webhook 端点（截图 + 发邮件）
 */
app.post('/screenshot', async (req, res) => {
    const startTime = Date.now();
    let screenshotPath = null;
    
    try {
        console.log('\n' + '='.repeat(60));
        console.log('🔔 收到信号通知');
        console.log('时间:', new Date().toLocaleString('zh-CN'));
        
        // 解析请求数据
        const {
            signal = '未知信号',
            message = '',
            symbol = 'UNKNOWN',
            timeframe = '',
            price = 0,
            timestamp = ''
        } = req.body;
        
        console.log('信号类型:', signal);
        console.log('交易品种:', symbol);
        console.log('时间周期:', timeframe);
        console.log('当前价格:', price);
        console.log('='.repeat(60));
        
        // 1. 截图
        let screenshotBuffer = null;
        const filename = `Keltner_${symbol}_${formatTimestamp()}.png`;
        screenshotPath = path.join(CONFIG.SCREENSHOT_DIR, filename);
        
        try {
            screenshotBuffer = await takeScreenshot(screenshotPath);
            console.log(`💾 截图已保存: ${filename}`);
            
        } catch (screenshotError) {
            console.warn('⚠️  截图失败，将仅发送文字邮件:', screenshotError.message);
        }
        
        // 2. 构建邮件内容
        const emailSubject = `[Keltner] ${signal} - ${symbol}`;
        const emailBody = `
${message}

━━━━━━━━━━━━━━━━━━━━━━
📊 交易信号详情
━━━━━━━━━━━━━━━━━━━━━━
信号类型: ${signal}
交易品种: ${symbol}
时间周期: ${timeframe}
当前价格: ${price}
信号时间: ${timestamp}
服务器时间: ${new Date().toLocaleString('zh-CN')}

${screenshotBuffer ? '📸 图表截图已附加在邮件中' : '⚠️  截图失败，请手动查看图表'}

━━━━━━━━━━━━━━━━━━━━━━
Keltner Signal cBot
━━━━━━━━━━━━━━━━━━━━━━
        `.trim();
        
        // 3. 发送邮件
        await sendEmail(emailSubject, emailBody, screenshotBuffer, filename);
        
        // 4. 清理临时文件
        if (screenshotPath && fs.existsSync(screenshotPath)) {
            setTimeout(() => {
                try {
                    fs.unlinkSync(screenshotPath);
                    console.log(`🗑️  临时文件已删除: ${filename}`);
                } catch (err) {
                    console.error('清理文件失败:', err.message);
                }
            }, CONFIG.TEMP_FILE_RETENTION);
        }
        
        // 5. 返回响应
        const duration = Date.now() - startTime;
        console.log(`✅ 处理完成，耗时: ${duration}ms`);
        console.log('='.repeat(60) + '\n');
        
        res.json({
            success: true,
            message: '信号处理成功',
            screenshot: screenshotBuffer ? '已截图并发送' : '截图失败',
            duration: `${duration}ms`,
            timestamp: new Date().toISOString()
        });
        
    } catch (error) {
        console.error('❌ 处理失败:', error);
        console.error('错误堆栈:', error.stack);
        
        res.status(500).json({
            success: false,
            error: error.message,
            timestamp: new Date().toISOString()
        });
    }
});

/**
 * 仅发送邮件（无截图）
 */
app.post('/notify', async (req, res) => {
    try {
        console.log('📧 收到邮件通知请求');
        
        const {
            signal = '未知信号',
            message = '',
            symbol = 'UNKNOWN'
        } = req.body;
        
        const emailSubject = `[Keltner] ${signal} - ${symbol}`;
        
        await sendEmail(emailSubject, message, null, null);
        
        res.json({
            success: true,
            message: '邮件发送成功',
            timestamp: new Date().toISOString()
        });
        
    } catch (error) {
        console.error('❌ 发送失败:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

/**
 * 接收EA交易信息（开仓/平仓）
 */
app.post('/trade', async (req, res) => {
    try {
        // 解析请求数据
        const {
            accountId,        // 账户ID（必需）
            action,           // 操作类型：'open' 开仓 / 'close' 平仓
            orderType,        // 订单类型：'buy' / 'sell'
            symbol,           // 交易品种
            volume,           // 手数
            price,            // 价格
            sl,               // 止损价
            tp,               // 止盈价
            ticket,           // 订单号
            comment,           // 备注
            timestamp          // 时间戳
        } = req.body;
        
        // 验证账户ID
        if (!accountId) {
            console.log('❌ 缺少账户ID参数');
            return res.status(400).json({
                success: false,
                error: '缺少账户ID参数',
                message: '请求中必须包含 accountId 字段'
            });
        }
        
        // 检查账户ID是否在允许列表中
        const accountIdStr = String(accountId);
        if (CONFIG.ALLOWED_ACCOUNTS.MT5.length > 0 && !CONFIG.ALLOWED_ACCOUNTS.MT5.includes(accountIdStr)) {
            console.log('❌ 账户ID不在允许范围内:', accountIdStr);
            console.log('允许的MT5账户ID列表:', CONFIG.ALLOWED_ACCOUNTS.MT5);
            return res.status(403).json({
                success: false,
                error: '账户ID不在允许范围内',
                message: `账户ID ${accountIdStr} 不在允许的MT5账户列表中`,
                accountId: accountIdStr
            });
        }
        
        // 处理时间戳转换
        let timeResult = null;
        if (timestamp) {
            timeResult = convertMT5TimeToUTC8(timestamp);
        }

        // 构建完整的消息对象（包含账户ID）
        const message = {
            accountId: accountIdStr,  // MT5 账户ID
            action,
            orderType,
            symbol,
            volume,
            price,
            sl: sl || null,
            tp: tp || null,
            ticket: ticket || null,
            comment: comment || null,
            timestamp: timestamp || null,
            timeConverted: timeResult || null,
            receivedAt: new Date().toISOString()
        };

        // 将消息添加到队列（按 MT5 账户ID 分组）
        const added = messageQueue.add(message);
        if (added) {
            const queueSize = messageQueue.size(accountIdStr);
            // 只打印重要信息：操作类型、品种、手数、价格
            console.log(`📊 [MT5:${accountIdStr}] ${action.toUpperCase()} ${orderType} ${symbol} ${volume}手 @ ${price} | 队列:${queueSize}`);
        } else {
            console.warn('⚠️  消息添加到队列失败');
        }
        
        res.json({
            success: true,
            message: '交易信息接收成功',
            received: {
                accountId: accountIdStr,
                action: action,
                orderType: orderType,
                symbol: symbol,
                volume: volume,
                price: price
            },
            queueSize: messageQueue.size(accountIdStr),
            mt5AccountId: accountIdStr,
            timestamp: new Date().toISOString()
        });
        
    } catch (error) {
        console.error('❌ 处理交易信息失败:', error);
        console.error('错误堆栈:', error.stack);
        
        res.status(500).json({
            success: false,
            error: error.message,
            timestamp: new Date().toISOString()
        });
    }
});

/**
 * EA上报仓位接口
 * 接收EA上报的仓位信息：总仓位、空单仓位、多单仓位
 */
app.post('/position/report', async (req, res) => {
    try {
        // 解析请求数据
        const {
            accountId,        // 账户ID（必需）
            total,            // 总仓位数量
            buy,              // 多单仓位数量
            sell              // 空单仓位数量
        } = req.body;
        
        // 验证账户ID
        if (!accountId) {
            console.log('❌ 缺少账户ID参数');
            return res.status(400).json({
                success: false,
                error: '缺少账户ID参数',
                message: '请求中必须包含 accountId 字段'
            });
        }
        
        // 检查账户ID是否在允许列表中
        const accountIdStr = String(accountId);
        if (CONFIG.ALLOWED_ACCOUNTS.MT5.length > 0 && !CONFIG.ALLOWED_ACCOUNTS.MT5.includes(accountIdStr)) {
            console.log('❌ 账户ID不在允许范围内:', accountIdStr);
            return res.status(403).json({
                success: false,
                error: '账户ID不在允许范围内',
                message: `账户ID ${accountIdStr} 不在允许的MT5账户列表中`,
                accountId: accountIdStr
            });
        }
        
        // 验证仓位数据
        const totalPos = parseInt(total) || 0;
        const buyPos = parseInt(buy) || 0;
        const sellPos = parseInt(sell) || 0;
        
        // 保存仓位信息
        positionData.mt5[accountIdStr] = {
            total: totalPos,
            buy: buyPos,
            sell: sellPos,
            lastUpdate: new Date().toISOString()
        };
        
        console.log(`📊 [MT5:${accountIdStr}] 仓位上报 - 总:${totalPos} 多:${buyPos} 空:${sellPos}`);
        
        res.json({
            success: true,
            message: '仓位信息接收成功',
            accountId: accountIdStr,
            position: {
                total: totalPos,
                buy: buyPos,
                sell: sellPos
            },
            timestamp: new Date().toISOString()
        });
        
    } catch (error) {
        console.error('❌ 处理仓位信息失败:', error);
        console.error('错误堆栈:', error.stack);
        
        res.status(500).json({
            success: false,
            error: error.message,
            timestamp: new Date().toISOString()
        });
    }
});



/**
 * 查询消息队列接口（读取并删除最早的消息）
 */
app.get('/queue/read', (req, res) => {
    try {
        // 获取账户ID（从查询参数）
        const accountId = req.query.accountId || req.query.account_id;
        
        // 验证账户ID
        if (!accountId) {
            console.log('❌ 缺少账户ID参数');
            return res.status(400).json({
                success: false,
                error: '缺少账户ID参数',
                message: '请求中必须包含 accountId 查询参数（例如：/queue/read?accountId=12345678）'
            });
        }
        
        // 检查账户ID是否在允许列表中
        const accountIdStr = String(accountId);
        if (CONFIG.ALLOWED_ACCOUNTS.CTRADER.length > 0 && !CONFIG.ALLOWED_ACCOUNTS.CTRADER.includes(accountIdStr)) {
            console.log('❌ 账户ID不在允许范围内:', accountIdStr);
            console.log('允许的cTrader账户ID列表:', CONFIG.ALLOWED_ACCOUNTS.CTRADER);
            return res.status(403).json({
                success: false,
                error: '账户ID不在允许范围内',
                message: `账户ID ${accountIdStr} 不在允许的cTrader账户列表中`,
                accountId: accountIdStr
            });
        }
        
        // 接收 cTrader 仓位信息（从查询参数）
        // 注意：不能使用 || null，因为 0 是 falsy，会导致仓位为 0 时被误判为 null
        // 应该检查参数是否存在，而不是依赖 || 运算符
        let ctraderTotal = null;
        let ctraderBuy = null;
        let ctraderSell = null;
        
        if (req.query.total !== undefined) {
            ctraderTotal = parseInt(req.query.total);
        } else if (req.query.totalPositions !== undefined) {
            ctraderTotal = parseInt(req.query.totalPositions);
        }
        
        if (req.query.buy !== undefined) {
            ctraderBuy = parseInt(req.query.buy);
        } else if (req.query.buyPositions !== undefined) {
            ctraderBuy = parseInt(req.query.buyPositions);
        }
        
        if (req.query.sell !== undefined) {
            ctraderSell = parseInt(req.query.sell);
        } else if (req.query.sellPositions !== undefined) {
            ctraderSell = parseInt(req.query.sellPositions);
        }
        // 如果有仓位信息，保存并比较
        if (ctraderTotal !== null || ctraderBuy !== null || ctraderSell !== null) {
            const ctraderPos = {
                total: ctraderTotal !== null ? ctraderTotal : (ctraderBuy !== null && ctraderSell !== null ? ctraderBuy + ctraderSell : null),
                buy: ctraderBuy !== null ? ctraderBuy : 0,
                sell: ctraderSell !== null ? ctraderSell : 0
            };
            
            // 异步比较仓位信息（不阻塞响应）
            compareAndNotifyPositions(accountIdStr, ctraderPos).catch(err => {
                console.error('❌ 比较仓位信息异常:', err.message);
            });
        }
        
        // 查找该 cTrader 账户可以读取的 MT5 账户列表
        const allowedMT5Accounts = CONFIG.ACCOUNT_MAPPING[accountIdStr];
        
        if (!allowedMT5Accounts || !Array.isArray(allowedMT5Accounts) || allowedMT5Accounts.length === 0) {
            console.log('⚠️  cTrader账户 ' + accountIdStr + ' 没有配置允许读取的MT5账户');
            return res.status(403).json({
                success: false,
                error: '账户对应关系未配置',
                message: `cTrader账户 ${accountIdStr} 没有配置允许读取的MT5账户，请在 CONFIG.ACCOUNT_MAPPING 中配置`,
                accountId: accountIdStr
            });
        }
        
        // 从允许的 MT5 账户队列中读取消息（按优先级顺序）
        const message = messageQueue.readFromAccounts(allowedMT5Accounts);
        
        if (message === null) {
            // 所有允许的队列都为空
            const totalQueueSize = messageQueue.sizeFromAccounts(allowedMT5Accounts);
            res.json({
                success: true,
                message: '队列为空',
                data: null,
                queueSize: totalQueueSize,
                allowedMT5Accounts: allowedMT5Accounts
            });
        } else {
            // 返回最早的消息
            const messageMT5Account = message.accountId || '未知';
            console.log('\n' + '╔' + '═'.repeat(58) + '╗');
            console.log('║' + ' '.repeat(20) + '📤 消息读取成功' + ' '.repeat(20) + '║');
            console.log('╠' + '═'.repeat(58) + '╣');
            console.log('║ MT5账户ID: ' + String(messageMT5Account).padEnd(46) + '║');
            console.log('║ 操作类型: ' + (message.action || '未知').padEnd(46) + '║');
            console.log('║ 订单类型: ' + (message.orderType || '未知').padEnd(46) + '║');
            console.log('║ 交易品种: ' + (message.symbol || '未知').padEnd(46) + '║');
            if (message.volume) {
                console.log('║ 手数: ' + String(message.volume).padEnd(50) + '║');
            }
            if (message.price) {
                console.log('║ 价格: ' + String(message.price).padEnd(50) + '║');
            }
            if (message.ticket) {
                console.log('║ 订单号: ' + String(message.ticket).padEnd(48) + '║');
            }
            if (message.timeConverted && message.timeConverted.utc8) {
                console.log('║ 时间 (UTC+8): ' + message.timeConverted.utc8.padEnd(43) + '║');
            }
            console.log('╠' + '═'.repeat(58) + '╣');
            
            // 计算剩余队列大小
            const totalQueueSize = messageQueue.sizeFromAccounts(allowedMT5Accounts);
            console.log('║ 队列剩余: ' + String(totalQueueSize).padEnd(47) + '条消息 ║');
            console.log('╚' + '═'.repeat(58) + '╝\n');
            
            res.json({
                success: true,
                message: '成功读取消息',
                data: message,
                queueSize: totalQueueSize,
                mt5AccountId: messageMT5Account,
                allowedMT5Accounts: allowedMT5Accounts
            });
        }
    } catch (error) {
        console.error('❌ 读取队列失败:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

/**
 * 查看队列统计信息（不删除消息）
 * 支持查询参数 accountId 来查看特定 MT5 账户的统计
 */
app.get('/queue/stats', (req, res) => {
    try {
        const mt5AccountId = req.query.accountId || req.query.account_id || null;
        const stats = messageQueue.getStats(mt5AccountId);
        res.json({
            success: true,
            stats: stats,
            mt5AccountId: mt5AccountId || 'all'
        });
    } catch (error) {
        console.error('❌ 获取队列统计失败:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// ==================== 错误处理 ====================

app.use((err, req, res, next) => {
    console.error('服务器错误:', err);
    res.status(500).json({
        success: false,
        error: err.message || '服务器内部错误'
    });
});

// ==================== 启动服务器 ====================

app.listen(CONFIG.PORT, () => {
    console.clear();
    console.log('\n' + '='.repeat(60));
    console.log('🚀 Keltner Webhook 服务器启动成功!');
    console.log('='.repeat(60));
    console.log(`📡 监听地址: http://localhost:${CONFIG.PORT}`);
    console.log(`📧 邮件发送: ${CONFIG.EMAIL.FROM} → ${CONFIG.EMAIL.TO}`);
    console.log(`📸 截图目录: ${CONFIG.SCREENSHOT_DIR}`);
    console.log(`📸 截图模式: ${CONFIG.SCREENSHOT_MODE === 'window' ? '仅 cTrader 窗口' : '整个屏幕'}`);
    if (CONFIG.SCREENSHOT_MODE === 'window') {
        console.log(`🪟 窗口标题: ${CONFIG.CTRADER_WINDOW_TITLE}`);
    }
    console.log('='.repeat(60));
    console.log('\n🔐 账户ID验证配置:');
    if (CONFIG.ALLOWED_ACCOUNTS.MT5.length > 0) {
        console.log(`  ✅ MT5账户列表: ${CONFIG.ALLOWED_ACCOUNTS.MT5.join(', ')}`);
    } else {
        console.log(`  ⚠️  MT5账户列表: 未配置（允许所有账户）`);
    }
    if (CONFIG.ALLOWED_ACCOUNTS.CTRADER.length > 0) {
        console.log(`  ✅ cTrader账户列表: ${CONFIG.ALLOWED_ACCOUNTS.CTRADER.join(', ')}`);
    } else {
        console.log(`  ⚠️  cTrader账户列表: 未配置（允许所有账户）`);
    }
    console.log('\n📋 账户对应关系（cTrader → MT5）:');
    const mappingCount = Object.keys(CONFIG.ACCOUNT_MAPPING).length;
    if (mappingCount > 0) {
        for (const [ctraderId, mt5Ids] of Object.entries(CONFIG.ACCOUNT_MAPPING)) {
            console.log(`  ✅ cTrader ${ctraderId} → MT5 [${mt5Ids.join(', ')}]`);
        }
    } else {
        console.log(`  ⚠️  未配置账户对应关系（需要在 CONFIG.ACCOUNT_MAPPING 中配置）`);
    }
    console.log('='.repeat(60));
    console.log('\n可用端点:');
    console.log(`  GET  /health         - 健康检查`);
    console.log(`  POST /test           - 测试连接（不截图）`);
    console.log(`  POST /screenshot    - 接收信号 + 截图 + 发邮件`);
    console.log(`  POST /notify         - 仅发送邮件通知`);
    console.log(`  POST /trade          - 接收EA交易信息（开仓/平仓）[需要 accountId]`);
    console.log(`  POST /position/report - 接收EA上报仓位信息（总/多/空）[需要 accountId]`);
    console.log(`  GET  /queue/read     - 读取队列中最早的消息（FIFO，读取后删除）[需要 accountId，可选仓位参数]`);
    console.log(`  GET  /queue/stats    - 查看队列统计信息`);
    console.log('='.repeat(60));
    console.log('\n⚠️  重要提示:');
    console.log('1. 截图模式设置为 "window"，将仅截取 cTrader 窗口');
    console.log('2. 确保 cTrader 窗口可见（不要最小化）');
    console.log('3. 在 server.js 的 CONFIG.ALLOWED_ACCOUNTS 中配置允许的账户ID');
    console.log('4. 按 Ctrl+C 停止服务器');
    console.log('='.repeat(60) + '\n');
    console.log('等待信号中...\n');
});

// 优雅关闭
process.on('SIGINT', () => {
    console.log('\n\n👋 服务器正在关闭...');
    process.exit(0);
});

process.on('SIGTERM', () => {
    console.log('\n\n👋 服务器正在关闭...');
    process.exit(0);
});

