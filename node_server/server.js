const express = require('express');
const nodemailer = require('nodemailer');
const screenshot = require('screenshot-desktop');
const cors = require('cors');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);

// ==================== 配置区域 ====================
const CONFIG = {
    // 服务器端口
    PORT: 5000,
    
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
    TEMP_FILE_RETENTION: 10000
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
    console.log('\n可用端点:');
    console.log(`  GET  /health      - 健康检查`);
    console.log(`  POST /test        - 测试连接（不截图）`);
    console.log(`  POST /screenshot  - 接收信号 + 截图 + 发邮件`);
    console.log(`  POST /notify      - 仅发送邮件通知`);
    console.log('='.repeat(60));
    console.log('\n⚠️  重要提示:');
    console.log('1. 截图模式设置为 "window"，将仅截取 cTrader 窗口');
    console.log('2. 确保 cTrader 窗口可见（不要最小化）');
    console.log('3. 按 Ctrl+C 停止服务器');
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

