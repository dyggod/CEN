/**
 * 消息队列管理类
 * 采用先进先出（FIFO）方式管理消息
 * 支持按 MT5 账户ID 分组存储
 */
class MessageQueue {
    constructor() {
        this.queues = {}; // 按 MT5 账户ID 分组的队列对象 { mt5AccountId: [messages] }
        this.maxSize = 1000; // 每个队列的最大容量，防止内存溢出
        this.processedMessages = {}; // 已处理的消息记录，用于去重 { mt5AccountId: Set<messageKey> }
        this.maxProcessedSize = 10000; // 每个账户最多保留的已处理记录数
    }
    
    /**
     * 生成消息的唯一键（用于去重）
     * @param {Object} message - 消息对象
     * @returns {string} 唯一键
     */
    _getMessageKey(message) {
        // 使用 accountId + ticket + action 作为唯一键
        // 对于 modify 操作，使用 accountId + ticket + action + sl + tp
        if (message.action === 'modify') {
            return `${message.accountId}_${message.ticket}_${message.action}_${message.sl || 0}_${message.tp || 0}`;
        }
        return `${message.accountId}_${message.ticket}_${message.action}`;
    }

    /**
     * 添加消息到队列末尾（按 MT5 账户ID 分组）
     * @param {Object} message - 消息对象（必须包含 accountId 字段）
     * @returns {boolean} 是否添加成功
     */
    add(message) {
        try {
            // 检查消息是否包含账户ID
            if (!message.accountId) {
                console.error('❌ 消息缺少 accountId 字段，无法添加到队列');
                return false;
            }

            const mt5AccountId = String(message.accountId);

            // 生成消息唯一键，检查是否重复
            const messageKey = this._getMessageKey(message);
            
            // 初始化已处理消息记录（如果不存在）
            if (!this.processedMessages[mt5AccountId]) {
                this.processedMessages[mt5AccountId] = new Set();
            }
            
            // 检查是否已经处理过这条消息（去重）
            if (this.processedMessages[mt5AccountId].has(messageKey)) {
                console.warn(`⚠️  重复消息已忽略: [MT5:${mt5AccountId}] ${message.action} ticket:${message.ticket}`);
                return false; // 重复消息，不添加
            }

            // 如果该账户的队列不存在，创建新队列
            if (!this.queues[mt5AccountId]) {
                this.queues[mt5AccountId] = [];
            }

            // 添加时间戳（如果消息中没有）
            if (!message.queueTime) {
                message.queueTime = new Date().toISOString();
            }

            // 检查队列是否已满
            if (this.queues[mt5AccountId].length >= this.maxSize) {
                console.warn(`⚠️  MT5账户 ${mt5AccountId} 的消息队列已满，移除最早的消息`);
                this.queues[mt5AccountId].shift(); // 移除最早的消息
            }

            // 添加到队列
            this.queues[mt5AccountId].push(message);
            
            // 记录已处理的消息
            this.processedMessages[mt5AccountId].add(messageKey);
            
            // 限制已处理记录的大小（防止内存溢出）
            if (this.processedMessages[mt5AccountId].size > this.maxProcessedSize) {
                // 移除最旧的记录（Set 没有顺序，这里简单处理：清空并重新添加最近的）
                // 实际场景中，可以考虑使用 LRU 缓存
                const currentSize = this.processedMessages[mt5AccountId].size;
                if (currentSize > this.maxProcessedSize) {
                    // 保留最近的记录，移除最旧的（简化处理：保留一半）
                    const toKeep = Math.floor(this.maxProcessedSize / 2);
                    const allKeys = Array.from(this.processedMessages[mt5AccountId]);
                    this.processedMessages[mt5AccountId] = new Set(allKeys.slice(-toKeep));
                }
            }
            
            return true;
        } catch (error) {
            console.error('❌ 添加消息到队列失败:', error.message);
            return false;
        }
    }

    /**
     * 从指定 MT5 账户的队列中删除指定消息（根据索引或消息ID）
     * @param {string} mt5AccountId - MT5 账户ID
     * @param {number|string} identifier - 消息索引或消息ID
     * @returns {boolean} 是否删除成功
     */
    remove(mt5AccountId, identifier) {
        try {
            const queue = this.queues[String(mt5AccountId)];
            if (!queue) {
                return false;
            }

            if (typeof identifier === 'number') {
                // 根据索引删除
                if (identifier >= 0 && identifier < queue.length) {
                    queue.splice(identifier, 1);
                    return true;
                }
            } else if (typeof identifier === 'string') {
                // 根据消息ID删除（如果消息有id字段）
                const index = queue.findIndex(msg => msg.id === identifier);
                if (index !== -1) {
                    queue.splice(index, 1);
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
     * 从指定 MT5 账户的队列中读取并删除最早的消息（FIFO）
     * @param {string} mt5AccountId - MT5 账户ID
     * @returns {Object|null} 最早的消息，如果队列为空则返回null
     */
    read(mt5AccountId) {
        try {
            const queue = this.queues[String(mt5AccountId)];
            if (!queue || queue.length === 0) {
                return null;
            }
            // 从队列头部取出最早的消息（先进先出）
            return queue.shift();
        } catch (error) {
            console.error('❌ 读取队列消息失败:', error.message);
            return null;
        }
    }

    /**
     * 从多个 MT5 账户的队列中读取并删除最早的消息（FIFO）
     * 按账户优先级顺序查找，返回第一个非空队列的消息
     * @param {Array<string>} mt5AccountIds - MT5 账户ID数组
     * @returns {Object|null} 最早的消息，如果所有队列都为空则返回null
     */
    readFromAccounts(mt5AccountIds) {
        try {
            if (!Array.isArray(mt5AccountIds) || mt5AccountIds.length === 0) {
                return null;
            }

            // 按顺序查找每个账户的队列
            for (const mt5AccountId of mt5AccountIds) {
                const queue = this.queues[String(mt5AccountId)];
                if (queue && queue.length > 0) {
                    return queue.shift();
                }
            }

            return null;
        } catch (error) {
            console.error('❌ 从多个账户队列读取消息失败:', error.message);
            return null;
        }
    }

    /**
     * 查看指定 MT5 账户队列中最早的消息（不删除）
     * @param {string} mt5AccountId - MT5 账户ID
     * @returns {Object|null} 最早的消息，如果队列为空则返回null
     */
    peek(mt5AccountId) {
        try {
            const queue = this.queues[String(mt5AccountId)];
            if (!queue || queue.length === 0) {
                return null;
            }
            return queue[0];
        } catch (error) {
            console.error('❌ 查看队列消息失败:', error.message);
            return null;
        }
    }

    /**
     * 获取指定 MT5 账户队列的长度
     * @param {string} mt5AccountId - MT5 账户ID（可选，不提供则返回所有队列的总长度）
     * @returns {number} 队列中消息的数量
     */
    size(mt5AccountId = null) {
        if (mt5AccountId) {
            const queue = this.queues[String(mt5AccountId)];
            return queue ? queue.length : 0;
        }
        // 返回所有队列的总长度
        return Object.values(this.queues).reduce((total, queue) => total + queue.length, 0);
    }

    /**
     * 获取多个 MT5 账户队列的总长度
     * @param {Array<string>} mt5AccountIds - MT5 账户ID数组
     * @returns {number} 所有指定账户队列中消息的总数量
     */
    sizeFromAccounts(mt5AccountIds) {
        if (!Array.isArray(mt5AccountIds) || mt5AccountIds.length === 0) {
            return 0;
        }
        return mt5AccountIds.reduce((total, mt5AccountId) => {
            const queue = this.queues[String(mt5AccountId)];
            return total + (queue ? queue.length : 0);
        }, 0);
    }

    /**
     * 清空指定 MT5 账户的队列（不提供则清空所有队列）
     * @param {string} mt5AccountId - MT5 账户ID（可选）
     */
    clear(mt5AccountId = null) {
        if (mt5AccountId) {
            delete this.queues[String(mt5AccountId)];
        } else {
            this.queues = {};
        }
    }

    /**
     * 获取指定 MT5 账户队列中所有消息（不删除）
     * @param {string} mt5AccountId - MT5 账户ID（可选，不提供则返回所有队列的消息）
     * @returns {Array} 消息数组
     */
    getAll(mt5AccountId = null) {
        if (mt5AccountId) {
            const queue = this.queues[String(mt5AccountId)];
            return queue ? [...queue] : []; // 返回副本，避免外部修改
        }
        // 返回所有队列的消息（合并）
        const allMessages = [];
        for (const queue of Object.values(this.queues)) {
            allMessages.push(...queue);
        }
        return allMessages;
    }

    /**
     * 获取队列统计信息
     * @param {string} mt5AccountId - MT5 账户ID（可选，不提供则返回所有队列的统计）
     * @returns {Object} 统计信息
     */
    getStats(mt5AccountId = null) {
        if (mt5AccountId) {
            const queue = this.queues[String(mt5AccountId)];
            if (!queue || queue.length === 0) {
                return {
                    size: 0,
                    maxSize: this.maxSize,
                    oldestMessageTime: null,
                    newestMessageTime: null
                };
            }
            return {
                size: queue.length,
                maxSize: this.maxSize,
                oldestMessageTime: queue[0].queueTime,
                newestMessageTime: queue[queue.length - 1].queueTime
            };
        }

        // 返回所有队列的统计信息
        const allQueues = Object.values(this.queues);
        const totalSize = allQueues.reduce((sum, queue) => sum + queue.length, 0);
        const allMessages = [];
        for (const queue of allQueues) {
            allMessages.push(...queue);
        }
        
        // 按时间排序，找到最早和最晚的消息
        allMessages.sort((a, b) => {
            const timeA = new Date(a.queueTime || 0);
            const timeB = new Date(b.queueTime || 0);
            return timeA - timeB;
        });

        return {
            size: totalSize,
            maxSize: this.maxSize,
            queueCount: Object.keys(this.queues).length,
            accountQueues: Object.keys(this.queues).reduce((acc, accountId) => {
                acc[accountId] = this.queues[accountId].length;
                return acc;
            }, {}),
            oldestMessageTime: allMessages.length > 0 ? allMessages[0].queueTime : null,
            newestMessageTime: allMessages.length > 0 ? allMessages[allMessages.length - 1].queueTime : null
        };
    }
}

// 创建单例实例
const messageQueue = new MessageQueue();

module.exports = messageQueue;

