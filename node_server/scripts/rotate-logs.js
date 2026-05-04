/**
 * 日志滚动：将 logs/output.log、logs/error.log 复制到 logs/history/ 后清空原文件（保留句柄，适合 PM2）。
 * - npm run logs:rotate — 手动滚动
 * - startAutoLogRotation() — 由 server.js 启动，按自然日自动滚动
 */
const fs = require('fs');
const path = require('path');

const LOGS_DIR = path.join(__dirname, '../logs');
const HISTORY_DIR = path.join(LOGS_DIR, 'history');
const SESSION_DATE_FILE = path.join(LOGS_DIR, '.current-log-session-date');
const LOG_FILES = ['output.log', 'error.log'];

/** 本地日历日期 YYYY-MM-DD */
function getLocalDateString(d = new Date()) {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
}

function getHistoryFilename(logName, d = new Date()) {
    const date = getLocalDateString(d);
    const h = String(d.getHours()).padStart(2, '0');
    const min = String(d.getMinutes()).padStart(2, '0');
    const s = String(d.getSeconds()).padStart(2, '0');
    const base = logName.replace(/\.log$/i, '');
    return `${base}-${date}T${h}${min}${s}.log`;
}

function readSessionDate() {
    try {
        if (!fs.existsSync(SESSION_DATE_FILE)) return null;
        return fs.readFileSync(SESSION_DATE_FILE, 'utf8').trim();
    } catch {
        return null;
    }
}

/**
 * 将当前日志复制到 history 并 truncate 原文件
 * @param {{ silent?: boolean }} options
 * @returns { number } 成功归档的文件数
 */
function rotateLogs(options = {}) {
    const { silent = false } = options;

    if (!fs.existsSync(LOGS_DIR)) {
        fs.mkdirSync(LOGS_DIR, { recursive: true });
    }
    if (!fs.existsSync(HISTORY_DIR)) {
        fs.mkdirSync(HISTORY_DIR, { recursive: true });
    }

    const now = new Date();
    let archived = 0;

    for (const name of LOG_FILES) {
        const src = path.join(LOGS_DIR, name);
        if (!fs.existsSync(src)) continue;

        let st;
        try {
            st = fs.statSync(src);
        } catch {
            continue;
        }
        if (st.size === 0) continue;

        const destName = getHistoryFilename(name, now);
        const dest = path.join(HISTORY_DIR, destName);
        try {
            fs.copyFileSync(src, dest);
            fs.truncateSync(src, 0);
            archived++;
            if (!silent) {
                const mb = (st.size / (1024 * 1024)).toFixed(2);
                console.log(`✅ 已归档: ${name} → history/${destName} (${mb} MB)`);
            }
        } catch (err) {
            if (!silent) console.error(`❌ 归档失败: ${name} - ${err.message}`);
        }
    }

    try {
        fs.writeFileSync(SESSION_DATE_FILE, getLocalDateString(now) + '\n', 'utf8');
    } catch (err) {
        if (!silent) console.error(`❌ 写入会话日期失败: ${err.message}`);
    }

    if (!silent && archived === 0) {
        console.log('ℹ️  无内容可归档（日志为空或文件不存在）');
    }

    return archived;
}

/** 当前自然日已晚于上次滚动所记日期时执行滚动 */
function checkAndRotateIfNewCalendarDay(options = {}) {
    const { silent = false } = options;
    const today = getLocalDateString();
    const session = readSessionDate();

    if (!session) {
        try {
            fs.writeFileSync(SESSION_DATE_FILE, today + '\n', 'utf8');
        } catch { /* ignore */ }
        return false;
    }

    if (today > session) {
        if (!silent) {
            console.log(`\n📜 日志按自然日自动滚动 (${session} → ${today})...\n`);
        }
        rotateLogs({ silent });
        return true;
    }
    return false;
}

/**
 * 启动定时检查；首次若存在会话日期且已跨自然日则立即滚动一次
 * @param {number} intervalMs 检查间隔，默认 10 分钟
 */
function startAutoLogRotation(intervalMs = 10 * 60 * 1000) {
    const today = getLocalDateString();
    if (!readSessionDate()) {
        try {
            fs.writeFileSync(SESSION_DATE_FILE, today + '\n', 'utf8');
        } catch { /* ignore */ }
    } else {
        checkAndRotateIfNewCalendarDay({ silent: false });
    }

    setInterval(() => {
        checkAndRotateIfNewCalendarDay({ silent: false });
    }, intervalMs);
}

if (require.main === module) {
    console.log('📜 开始滚动日志（归档到 logs/history，并清空当前文件）...\n');
    rotateLogs({ silent: false });
    console.log('\n✅ 滚动完成');
}

module.exports = {
    rotateLogs,
    checkAndRotateIfNewCalendarDay,
    startAutoLogRotation,
    getLocalDateString
};
