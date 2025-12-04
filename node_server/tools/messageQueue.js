/**
 * 消息队列管理类
 * 采用先进先出（FIFO）方式管理消息
 */
class MessageQueue {
    constructor() {
        this.queue = []; // 消息队列数组
        this.maxSize = 1000; // 队列最大容量，防止内存溢出
    }

    /**
     * 添加消息到队列末尾
     * @param {Object} message - 消息对象
     * @returns {boolean} 是否添加成功
     */
    add(message) {
        try {
            // 添加时间戳（如果消息中没有）
            if (!message.queueTime) {
                message.queueTime = new Date().toISOString();
            }

            // 检查队列是否已满
            if (this.queue.length >= this.maxSize) {
                console.warn('⚠️  消息队列已满，移除最早的消息');
                this.queue.shift(); // 移除最早的消息
            }

            this.queue.push(message);
            return true;
        } catch (error) {
            console.error('❌ 添加消息到队列失败:', error.message);
            return false;
        }
    }

    /**
     * 从队列中删除指定消息（根据索引或消息ID）
     * @param {number|string} identifier - 消息索引或消息ID
     * @returns {boolean} 是否删除成功
     */
    remove(identifier) {
        try {
            if (typeof identifier === 'number') {
                // 根据索引删除
                if (identifier >= 0 && identifier < this.queue.length) {
                    this.queue.splice(identifier, 1);
                    return true;
                }
            } else if (typeof identifier === 'string') {
                // 根据消息ID删除（如果消息有id字段）
                const index = this.queue.findIndex(msg => msg.id === identifier);
                if (index !== -1) {
                    this.queue.splice(index, 1);
                    return true;
                }
            }
            return false;
        } catch (error) {
            console.error('❌ 从队列删除消息失败:', error.message);
            return false;
        }
    }

    /**
     * 读取并删除队列中最早的消息（FIFO）
     * @returns {Object|null} 最早的消息，如果队列为空则返回null
     */
    read() {
        try {
            if (this.queue.length === 0) {
                return null;
            }
            // 从队列头部取出最早的消息（先进先出）
            return this.queue.shift();
        } catch (error) {
            console.error('❌ 读取队列消息失败:', error.message);
            return null;
        }
    }

    /**
     * 查看队列中最早的消息（不删除）
     * @returns {Object|null} 最早的消息，如果队列为空则返回null
     */
    peek() {
        try {
            if (this.queue.length === 0) {
                return null;
            }
            return this.queue[0];
        } catch (error) {
            console.error('❌ 查看队列消息失败:', error.message);
            return null;
        }
    }

    /**
     * 获取队列长度
     * @returns {number} 队列中消息的数量
     */
    size() {
        return this.queue.length;
    }

    /**
     * 清空队列
     */
    clear() {
        this.queue = [];
    }

    /**
     * 获取队列中所有消息（不删除）
     * @returns {Array} 消息数组
     */
    getAll() {
        return [...this.queue]; // 返回副本，避免外部修改
    }

    /**
     * 获取队列统计信息
     * @returns {Object} 统计信息
     */
    getStats() {
        return {
            size: this.queue.length,
            maxSize: this.maxSize,
            oldestMessageTime: this.queue.length > 0 ? this.queue[0].queueTime : null,
            newestMessageTime: this.queue.length > 0 ? this.queue[this.queue.length - 1].queueTime : null
        };
    }
}

// 创建单例实例
const messageQueue = new MessageQueue();

module.exports = messageQueue;

