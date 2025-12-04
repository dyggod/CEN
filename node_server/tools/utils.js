/**
 * 工具函数模块
 */

/**
 * 将MT5时间（UTC+2）转换为UTC+8（中国时区）
 * @param {string} mt5Timestamp - MT5时间戳，格式: "2025.12.04 18:11:10"
 * @returns {Object} 包含原始时间、UTC时间和UTC+8时间的对象
 */
function convertMT5TimeToUTC8(mt5Timestamp) {
    if (!mt5Timestamp) {
        return null;
    }

    try {
        // 解析MT5时间格式: "2025.12.04 18:11:10"
        const mt5TimeMatch = mt5Timestamp.match(/(\d{4})\.(\d{2})\.(\d{2})\s+(\d{2}):(\d{2}):(\d{2})/);
        
        if (!mt5TimeMatch) {
            return {
                error: '时间格式解析失败',
                original: mt5Timestamp
            };
        }

        const [, year, month, day, hour, minute, second] = mt5TimeMatch;

        // MT5服务器时区是UTC+2，创建UTC时间对象
        const mt5Date = new Date(Date.UTC(
            parseInt(year),
            parseInt(month) - 1, // 月份从0开始
            parseInt(day),
            parseInt(hour),
            parseInt(minute),
            parseInt(second)
        ));

        // 转换为UTC时间（减去2小时）
        const utcDate = new Date(mt5Date.getTime() - 2 * 60 * 60 * 1000);

        // 转换为UTC+8时间（加6小时，因为MT5是UTC+2，到UTC+8需要加6小时）
        const utc8Date = new Date(mt5Date.getTime() + 6 * 60 * 60 * 1000);

        // 格式化UTC+8时间
        const utc8Year = utc8Date.getUTCFullYear();
        const utc8Month = String(utc8Date.getUTCMonth() + 1).padStart(2, '0');
        const utc8Day = String(utc8Date.getUTCDate()).padStart(2, '0');
        const utc8Hour = String(utc8Date.getUTCHours()).padStart(2, '0');
        const utc8Min = String(utc8Date.getUTCMinutes()).padStart(2, '0');
        const utc8Sec = String(utc8Date.getUTCSeconds()).padStart(2, '0');
        const utc8TimeStr = `${utc8Year}/${utc8Month}/${utc8Day} ${utc8Hour}:${utc8Min}:${utc8Sec}`;

        return {
            original: mt5Timestamp,
            originalTimezone: 'UTC+2',
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

