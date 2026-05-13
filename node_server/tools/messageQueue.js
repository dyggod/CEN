const crypto = require('crypto');

/**
 * 消息队列管理类
 * 采用先进先出（FIFO）方式管理消息
 * 支持按 MT5 账户ID 分组存储
 * 支持 lease/ack：批量租约出队，确认后删除；超时或 released 则回队
 */
class MessageQueue {
    constructor() {
        this.queues = {}; // 按 MT5 账户ID 分组的队列对象 { mt5AccountId: [messages] }
        this.maxSize = 1000; // 每个队列的最大容量，防止内存溢出
        /** @type {Map<string, { items: Array<{ mt5AccountId: string, message: Object }>, expiresAt: number, ctraderAccountId: string }>} */
        this.leases = new Map();
        // 最近已接收事件（带时间戳），用于短窗口去重：{ mt5AccountId: Map<fingerprint, ts> }
        this.recentFingerprints = {};
        // 每个逻辑键最近一次事件时间，用于乱序保护：{ mt5AccountId: Map<orderKey, eventTimeMs> }
        this.latestEventTimeByOrderKey = {};
        this.dedupeWindowMs = 5 * 60 * 1000; // 指纹去重窗口（5分钟）
        this.maxFingerprintSize = 10000; // 每账户最多保留的指纹数量
        this.maxOrderKeySize = 5000; // 每账户最多保留的 orderKey 数量
    }
    
    /**
     * 生成消息事件指纹（用于短窗口去重）
     * @param {Object} message - 消息对象
     * @returns {string} 唯一键
     */
    _getFingerprint(message) {
        const action = String(message.action || '');
        const accountId = String(message.accountId || '');
        const ticket = message.ticket || 0;
        const eventTimeMs = Number.isFinite(Number(message.eventTimeMs)) ? Math.floor(Number(message.eventTimeMs)) : 0;
        const symbol = String(message.symbol || '');
        const orderType = String(message.orderType || '');
        const pendingType = String(message.pendingType || '');
        const volume = Number(message.volume || 0);
        const price = Number(message.price || 0);
        const sl = Number(message.sl || 0);
        const tp = Number(message.tp || 0);
        return [
            accountId, action, ticket, eventTimeMs,
            symbol, orderType, pendingType,
            volume, price, sl, tp
        ].join('|');
    }

    /**
     * 生成乱序保护键（同一实体+动作链路）
     * @param {Object} message
     * @returns {string}
     */
    _getOrderKey(message) {
        const accountId = String(message.accountId || '');
        const action = String(message.action || '');
        const symbol = String(message.symbol || '');
        const orderType = String(message.orderType || '');
        const pendingType = String(message.pendingType || '');
        const ticket = message.ticket || 0;
        return `${accountId}|${action}|${ticket}|${symbol}|${orderType}|${pendingType}`;
    }

    _cleanupMaps(mt5AccountId) {
        const now = Date.now();
        const fpMap = this.recentFingerprints[mt5AccountId];
        if (fpMap) {
            for (const [key, ts] of fpMap.entries()) {
                if (!Number.isFinite(ts) || (now - ts) > this.dedupeWindowMs) {
                    fpMap.delete(key);
                }
            }
            if (fpMap.size > this.maxFingerprintSize) {
                const excess = fpMap.size - this.maxFingerprintSize;
                let i = 0;
                for (const key of fpMap.keys()) {
                    fpMap.delete(key);
                    i++;
                    if (i >= excess) break;
                }
            }
        }

        const orderMap = this.latestEventTimeByOrderKey[mt5AccountId];
        if (orderMap && orderMap.size > this.maxOrderKeySize) {
            const excess = orderMap.size - this.maxOrderKeySize;
            let i = 0;
            for (const key of orderMap.keys()) {
                orderMap.delete(key);
                i++;
                if (i >= excess) break;
            }
        }
    }

    /**
     * 添加消息到队列末尾（按 MT5 账户ID 分组）
     * @param {Object} message - 消息对象（必须包含 accountId 字段）
     * @returns {boolean} 是否添加成功
     */
    add(message) {
        return this.addWithResult(message).accepted;
    }

    /**
     * 添加消息并返回详细结果（用于排查被拒原因）
     * @param {Object} message
     * @returns {{accepted: boolean, reason: string, detail?: string}}
     */
    addWithResult(message) {
        try {
            // 检查消息是否包含账户ID
            if (!message.accountId) {
                console.error('❌ 消息缺少 accountId 字段，无法添加到队列');
                return { accepted: false, reason: 'missing_account_id' };
            }

            const mt5AccountId = String(message.accountId);
            
            // 初始化去重/乱序结构（如果不存在）
            if (!this.recentFingerprints[mt5AccountId]) {
                this.recentFingerprints[mt5AccountId] = new Map();
            }
            if (!this.latestEventTimeByOrderKey[mt5AccountId]) {
                this.latestEventTimeByOrderKey[mt5AccountId] = new Map();
            }
            this._cleanupMaps(mt5AccountId);

            const fingerprint = this._getFingerprint(message);
            const fpMap = this.recentFingerprints[mt5AccountId];
            const now = Date.now();
            const existingTs = fpMap.get(fingerprint);
            if (Number.isFinite(existingTs) && (now - existingTs) <= this.dedupeWindowMs) {
                return { accepted: false, reason: 'duplicate_event', detail: fingerprint };
            }

            const incomingEventTimeMs = Number.isFinite(Number(message.eventTimeMs))
                ? Math.floor(Number(message.eventTimeMs))
                : null;
            if (incomingEventTimeMs !== null && incomingEventTimeMs > 0) {
                const orderKey = this._getOrderKey(message);
                const orderMap = this.latestEventTimeByOrderKey[mt5AccountId];
                const latestMs = orderMap.get(orderKey);
                if (Number.isFinite(latestMs) && incomingEventTimeMs < latestMs) {
                    return {
                        accepted: false,
                        reason: 'out_of_order_event',
                        detail: `${incomingEventTimeMs}<${latestMs}`
                    };
                }
                orderMap.set(orderKey, incomingEventTimeMs);
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
            fpMap.set(fingerprint, now);
            
            return { accepted: true, reason: 'accepted' };
        } catch (error) {
            console.error('❌ 添加消息到队列失败:', error.message);
            return { accepted: false, reason: 'queue_error', detail: error.message };
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

    /**
     * 将 lease 中的消息按原批次顺序插回各账户队列队首（逆序 unshift 以保持 FIFO）
     * @param {Array<{ mt5AccountId: string, message: Object }>} items
     */
    _requeueLeaseItems(items) {
        if (!Array.isArray(items) || items.length === 0) return;
        for (let i = items.length - 1; i >= 0; i--) {
            const row = items[i];
            const id = String(row.mt5AccountId);
            const msg = row.message;
            if (!this.queues[id]) {
                this.queues[id] = [];
            }
            this.queues[id].unshift(msg);
        }
    }

    /**
     * 处理已过期的 lease：回队并删除
     */
    expireLeases() {
        const now = Date.now();
        for (const [deliveryId, lease] of this.leases.entries()) {
            if (lease.expiresAt <= now) {
                this._requeueLeaseItems(lease.items);
                this.leases.delete(deliveryId);
                console.warn(`⏱️ lease 超时已自动回队: ${deliveryId} 共 ${lease.items.length} 条`);
            }
        }
    }

    /**
     * 与 readFromAccounts 相同优先级，一次最多租约 limit 条（每条仍 shift 出主队列）
     * @param {Array<string>} mt5AccountIds
     * @param {number} limit
     * @param {number} leaseTtlMs
     * @param {string} ctraderAccountId
     * @returns {{ deliveryId: string|null, items: Object[], leaseTtlMs: number }}
     */
    leaseBatchFromAccounts(mt5AccountIds, limit, leaseTtlMs, ctraderAccountId) {
        try {
            this.expireLeases();

            if (!Array.isArray(mt5AccountIds) || mt5AccountIds.length === 0) {
                return { deliveryId: null, items: [], leaseTtlMs: leaseTtlMs || 0 };
            }
            const cap = Math.min(50, Math.max(1, Math.floor(Number(limit)) || 10));
            const ttl = Math.min(600000, Math.max(5000, Math.floor(Number(leaseTtlMs)) || 120000));

            const picked = [];
            let count = 0;
            while (count < cap) {
                let found = false;
                for (const mt5AccountId of mt5AccountIds) {
                    const key = String(mt5AccountId);
                    const queue = this.queues[key];
                    if (queue && queue.length > 0) {
                        const message = queue.shift();
                        picked.push({ mt5AccountId: key, message });
                        count++;
                        found = true;
                        break;
                    }
                }
                if (!found) break;
            }

            if (picked.length === 0) {
                return { deliveryId: null, items: [], leaseTtlMs: ttl };
            }

            const deliveryId = crypto.randomUUID();
            const expiresAt = Date.now() + ttl;
            this.leases.set(deliveryId, {
                items: picked,
                expiresAt,
                ctraderAccountId: String(ctraderAccountId)
            });

            const items = picked.map((p) => p.message);
            return { deliveryId, items, leaseTtlMs: ttl };
        } catch (error) {
            console.error('❌ leaseBatchFromAccounts 失败:', error.message);
            return { deliveryId: null, items: [], leaseTtlMs: leaseTtlMs || 0 };
        }
    }

    /**
     * @param {string} deliveryId
     * @param {string} ctraderAccountId
     * @param {string} status committed = 确认消费；released = 主动放回队列
     * @returns {{ ok: boolean, reason?: string }}
     */
    ackLease(deliveryId, ctraderAccountId, status) {
        try {
            this.expireLeases();

            if (!deliveryId || typeof deliveryId !== 'string') {
                return { ok: false, reason: 'missing_delivery_id' };
            }
            const lease = this.leases.get(deliveryId);
            if (!lease) {
                return { ok: false, reason: 'unknown_or_expired' };
            }
            if (String(lease.ctraderAccountId) !== String(ctraderAccountId)) {
                return { ok: false, reason: 'account_mismatch' };
            }

            const st = String(status || '').toLowerCase();
            this.leases.delete(deliveryId);

            if (st === 'released') {
                this._requeueLeaseItems(lease.items);
                console.log(`↩️ lease 已释放回队: ${deliveryId} 共 ${lease.items.length} 条`);
            } else if (st === 'committed') {
                // 消息已在租约时移出主队列，committed 即永久丢弃 lease 记录
                console.log(`✅ lease 已确认: ${deliveryId} 共 ${lease.items.length} 条`);
            } else {
                this._requeueLeaseItems(lease.items);
                return { ok: false, reason: 'invalid_status_requeued' };
            }

            return { ok: true };
        } catch (error) {
            console.error('❌ ackLease 失败:', error.message);
            return { ok: false, reason: 'ack_error', detail: error.message };
        }
    }
}

// 创建单例实例
const messageQueue = new MessageQueue();

module.exports = messageQueue;

