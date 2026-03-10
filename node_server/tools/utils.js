/**
 * 工具函数模块
 */

/**
 * 将 MT5/EA 服务器时间转换为 UTC+8（北京时间）
 * @param {string} mt5Timestamp - MT5 时间戳，格式: "2025.12.04 18:11:10" 或 "2025/12/04 18:11:10"
 * @param {number} mt5UtcOffset - MT5/EA 服务器相对 UTC 的时区偏移（如 3 表示 UTC+3），默认 2
 * @returns {Object} 包含原始时间、UTC 时间和 UTC+8 时间的对象
 */
function convertMT5TimeToUTC8(mt5Timestamp, mt5UtcOffset = 2) {
    if (!mt5Timestamp) {
        return null;
    }

    try {
        // 解析 MT5 时间格式（支持 . 或 / 分隔）: "2025.12.04 18:11:10"
        const mt5TimeMatch = mt5Timestamp.match(/(\d{4})[.\/](\d{2})[.\/](\d{2})\s+(\d{2}):(\d{2}):(\d{2})/);
        
        if (!mt5TimeMatch) {
            return {
                error: '时间格式解析失败',
                original: mt5Timestamp
            };
        }

        const [, year, month, day, hour, minute, second] = mt5TimeMatch;

        // 把 EA 发来的时间当作 UTC+mt5UtcOffset 时区的本地时间
        // 先创建一个 UTC 时间对象（使用输入的年月日时分秒）
        const utcTime = Date.UTC(
            parseInt(year),
            parseInt(month) - 1,
            parseInt(day),
            parseInt(hour),
            parseInt(minute),
            parseInt(second)
        );
        
        // 减去 mt5UtcOffset 小时，得到真正的 UTC 时间
        // （因为输入时间是 UTC+mt5UtcOffset，所以要减去偏移才能得到 UTC）
        const trueUtcTime = utcTime - mt5UtcOffset * 60 * 60 * 1000;
        
        // 加上 8 小时，得到 UTC+8 时间
        const utc8Time = trueUtcTime + 8 * 60 * 60 * 1000;
        
        const utcDate = new Date(trueUtcTime);
        const utc8Date = new Date(utc8Time);

        const utc8Year = utc8Date.getUTCFullYear();
        const utc8Month = String(utc8Date.getUTCMonth() + 1).padStart(2, '0');
        const utc8Day = String(utc8Date.getUTCDate()).padStart(2, '0');
        const utc8Hour = String(utc8Date.getUTCHours()).padStart(2, '0');
        const utc8Min = String(utc8Date.getUTCMinutes()).padStart(2, '0');
        const utc8Sec = String(utc8Date.getUTCSeconds()).padStart(2, '0');
        const utc8TimeStr = `${utc8Year}/${utc8Month}/${utc8Day} ${utc8Hour}:${utc8Min}:${utc8Sec}`;

        return {
            original: mt5Timestamp,
            originalTimezone: 'UTC+' + mt5UtcOffset,
            utc: utcDate.toISOString(),
            utc8: utc8TimeStr,
            utc8Date: utc8Date
        };

    } catch (error) {
        return {
            error: error.message,
            original: mt5Timestamp
        };
    }
}

module.exports = {
    convertMT5TimeToUTC8
};

