const fs = require('fs');
const path = require('path');

const logsDir = path.join(__dirname, '../logs');
const logFiles = ['error.log', 'output.log'];

console.log('🧹 开始清理日志文件...\n');

let clearedCount = 0;
let totalSize = 0;

logFiles.forEach(file => {
    const filePath = path.join(logsDir, file);
    
    if (fs.existsSync(filePath)) {
        try {
            const stats = fs.statSync(filePath);
            const sizeInMB = (stats.size / (1024 * 1024)).toFixed(2);
            totalSize += stats.size;
            
            // 清空文件内容（保留文件）
            fs.writeFileSync(filePath, '');
            
            console.log(`✅ 已清理: ${file} (${sizeInMB} MB)`);
            clearedCount++;
        } catch (error) {
            console.error(`❌ 清理失败: ${file} - ${error.message}`);
        }
    } else {
        console.log(`ℹ️  文件不存在: ${file}`);
    }
});

const totalSizeMB = (totalSize / (1024 * 1024)).toFixed(2);
console.log(`\n📊 清理完成: ${clearedCount} 个文件，共释放 ${totalSizeMB} MB 空间`);

