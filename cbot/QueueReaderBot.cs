using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using cAlgo.API;

namespace cAlgo.Robots
{
    [Robot(TimeZone = TimeZones.UTC)]
    public class QueueReaderBot : Robot
    {
        // 输入参数（P0/P1：默认走 /queue/lease + /queue/ack）
        [Parameter("服务器地址", DefaultValue = "http://127.0.0.1:6699/queue/lease")]
        public string ServerURL { get; set; }

        [Parameter("轮询间隔（毫秒）", DefaultValue = 100, MinValue = 50)]
        public int RequestIntervalMs { get; set; }

        [Parameter("单次租约最大条数", DefaultValue = 10, MinValue = 1, MaxValue = 50)]
        public int LeaseBatchLimit { get; set; }

        [Parameter("Lease 超时毫秒（服务端未收到 ack 则回队）", DefaultValue = 120000, MinValue = 5000)]
        public int LeaseTtlMs { get; set; }

        [Parameter("消息过期时间（秒）", DefaultValue = 10, MinValue = 1)]
        public int MessageExpireSeconds { get; set; }

        [Parameter("固定手数", DefaultValue = 0, MinValue = 0)]
        public double FixedVolume { get; set; }

        [Parameter("仓位检查标的", DefaultValue = "XAUUSD")]
        public string CheckSymbols { get; set; }

        // 私有变量
        private HttpClient _httpClient;
        private long _accountId = 0;  // 账户ID（在主线程中获取）
        private int _requestCount = 0;
        private int _successCount = 0;
        private int _failCount = 0;
        private int _expiredCount = 0;  // 过期消息计数
        private int _tradeSuccessCount = 0;  // 交易成功计数
        private int _tradeFailCount = 0;  // 交易失败计数
        private DateTime _lastLeaseCycleEndUtc = DateTime.MinValue;
        private volatile bool _leaseCycleBusy;
        /// <summary>各 MT5 账号最近一次仓位同步成功平掉至少一单的时间（UTC），用于解释紧随其后的队列 close/modify 找不到持仓</summary>
        private readonly System.Collections.Generic.Dictionary<string, DateTime> _lastAccountSyncCloseUtc =
            new System.Collections.Generic.Dictionary<string, DateTime>(System.StringComparer.Ordinal);

        protected override void OnStart()
        {
            // 在主线程中获取账户ID（必须在主线程中访问 Account.Number）
            _accountId = Account.Number;
            
            // 初始化HTTP客户端
            _httpClient = new HttpClient();
            _httpClient.Timeout = TimeSpan.FromSeconds(5);

            double timerSec = Math.Max(0.05, RequestIntervalMs / 1000.0);
            Timer.Start(timerSec);

            Print("Queue Reader Bot 已启动");
            Print("服务器地址: " + ServerURL);
            Print("当前账户ID: " + _accountId);
            Print("轮询间隔: " + RequestIntervalMs + " ms（定时器 " + timerSec + " s）");
            Print("单次租约条数上限: " + LeaseBatchLimit);
            Print("Lease TTL(ms): " + LeaseTtlMs);
            Print("消息过期时间: " + MessageExpireSeconds + " 秒");
            if (FixedVolume > 0)
                Print("固定手数: " + FixedVolume + " 手（将忽略消息中的手数）");
            else
                Print("手数模式: 跟随消息中的手数");
        }

        protected override void OnTimer()
        {
            if (_leaseCycleBusy)
                return;

            double msSinceLast = (DateTime.UtcNow - _lastLeaseCycleEndUtc).TotalMilliseconds;
            if (_lastLeaseCycleEndUtc != DateTime.MinValue && msSinceLast < RequestIntervalMs)
                return;

            string[] checkSymbolsArray = CheckSymbols.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
            int totalPositions = 0;
            int buyPositions = 0;
            int sellPositions = 0;
            var accountPositionCounts = new System.Collections.Generic.Dictionary<string, int>(System.StringComparer.Ordinal);

            foreach (var position in Positions)
            {
                bool shouldCheck = false;
                if (checkSymbolsArray.Length == 0)
                {
                    shouldCheck = true;
                }
                else
                {
                    foreach (string symbol in checkSymbolsArray)
                    {
                        if (position.SymbolName.Trim() == symbol.Trim())
                        {
                            shouldCheck = true;
                            break;
                        }
                    }
                }

                if (shouldCheck)
                {
                    totalPositions++;
                    if (position.TradeType == TradeType.Buy)
                        buyPositions++;
                    else if (position.TradeType == TradeType.Sell)
                        sellPositions++;

                    string labelAccount;
                    if (!string.IsNullOrEmpty(position.Label) && TryExtractMt5AccountFromLabel(position.Label, out labelAccount))
                    {
                        int oldCount = 0;
                        accountPositionCounts.TryGetValue(labelAccount, out oldCount);
                        accountPositionCounts[labelAccount] = oldCount + 1;
                    }
                }
            }

            string accountPositionsParam = BuildAccountPositionsParam(accountPositionCounts);

            _leaseCycleBusy = true;
            Task.Run(async () => await RunLeaseHttpCycleAsync(totalPositions, buyPositions, sellPositions, accountPositionsParam));
        }

        /// <summary>
        /// P0：串行完整周期（GET lease → 主线程处理 → POST ack）；P1：ack 后 lease 才最终消费。
        /// </summary>
        private async Task RunLeaseHttpCycleAsync(int totalPositions, int buyPositions, int sellPositions, string accountPositionsParam)
        {
            _requestCount++;

            try
            {
                string urlWithAccountId = ServerURL;
                if (ServerURL.Contains("?"))
                    urlWithAccountId += "&accountId=" + _accountId;
                else
                    urlWithAccountId += "?accountId=" + _accountId;

                urlWithAccountId += "&total=" + totalPositions;
                urlWithAccountId += "&buy=" + buyPositions;
                urlWithAccountId += "&sell=" + sellPositions;
                if (!string.IsNullOrEmpty(accountPositionsParam))
                    urlWithAccountId += "&accountPositions=" + Uri.EscapeDataString(accountPositionsParam);

                if (ServerURL.Contains("/queue/lease"))
                {
                    urlWithAccountId += "&limit=" + LeaseBatchLimit;
                    urlWithAccountId += "&leaseTtlMs=" + LeaseTtlMs;
                }

                HttpResponseMessage response = await _httpClient.GetAsync(urlWithAccountId);
                response.EnsureSuccessStatusCode();

                string responseBody = await response.Content.ReadAsStringAsync();
                _successCount++;

                var tcs = new TaskCompletionSource<string>();
                BeginInvokeOnMainThread(() =>
                {
                    try
                    {
                        string deliveryId = ProcessQueueResponseOnMainThread(responseBody);
                        tcs.TrySetResult(deliveryId ?? "");
                    }
                    catch (Exception ex)
                    {
                        tcs.TrySetException(ex);
                    }
                });

                string ackId = await tcs.Task.ConfigureAwait(false);
                if (!string.IsNullOrEmpty(ackId))
                    await PostAckCommittedAsync(ackId).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _failCount++;
                BeginInvokeOnMainThread(() =>
                {
                    Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 请求失败 #" + _requestCount);
                    Print("错误: " + ex.Message);
                });
            }
            finally
            {
                _leaseCycleBusy = false;
                _lastLeaseCycleEndUtc = DateTime.UtcNow;
            }
        }

        private async Task PostAckCommittedAsync(string deliveryId)
        {
            try
            {
                string ackUrl = BuildAckPostUrl();
                string json = "{\"accountId\":" + _accountId.ToString() + ",\"deliveryId\":\"" + deliveryId + "\",\"status\":\"committed\"}";
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                HttpResponseMessage resp = await _httpClient.PostAsync(ackUrl, content).ConfigureAwait(false);
                resp.EnsureSuccessStatusCode();
            }
            catch (Exception ex)
            {
                BeginInvokeOnMainThread(() =>
                {
                    Print("⚠️  POST /queue/ack 失败（lease 将超时回队）: " + ex.Message);
                });
            }
        }

        private string BuildAckPostUrl()
        {
            string u = ServerURL.Trim();
            if (u.Contains("/queue/lease"))
                return u.Replace("/queue/lease", "/queue/ack");
            if (u.Contains("/queue/read"))
                return u.Replace("/queue/read", "/queue/ack");
            int q = u.IndexOf("?");
            string baseNoQuery = q >= 0 ? u.Substring(0, q) : u;
            baseNoQuery = baseNoQuery.TrimEnd('/');
            if (baseNoQuery.EndsWith("/queue/ack", StringComparison.OrdinalIgnoreCase))
                return u;
            return baseNoQuery + "/queue/ack";
        }

        /// <summary>
        /// 从 JSON 中解析 "items":[ {...}, ... ] 里每个对象的子串（无外部 JSON 库）。
        /// </summary>
        private static System.Collections.Generic.List<string> ExtractJsonObjectsFromArrayProperty(string json, string arrayPropertyName)
        {
            var result = new System.Collections.Generic.List<string>();
            string key = "\"" + arrayPropertyName + "\":[";
            int start = json.IndexOf(key);
            if (start < 0)
                return result;

            int i = start + key.Length;
            while (i < json.Length && char.IsWhiteSpace(json[i]))
                i++;
            if (i < json.Length && json[i] == ']')
                return result;

            while (i < json.Length)
            {
                while (i < json.Length && char.IsWhiteSpace(json[i]))
                    i++;
                if (i >= json.Length || json[i] == ']')
                    break;
                if (json[i] == ',')
                {
                    i++;
                    continue;
                }
                if (json[i] != '{')
                    break;

                int depth = 0;
                int objStart = i;
                bool closed = false;
                for (int j = i; j < json.Length; j++)
                {
                    char c = json[j];
                    if (c == '{')
                        depth++;
                    else if (c == '}')
                    {
                        depth--;
                        if (depth == 0)
                        {
                            result.Add(json.Substring(objStart, j - objStart + 1));
                            i = j + 1;
                            closed = true;
                            break;
                        }
                    }
                }
                if (!closed)
                    break;
            }
            return result;
        }

        /// <summary>
        /// 主线程：仓位同步 + 单条 read 或 批量 lease；返回需 ack 的 deliveryId（无则空串）。
        /// </summary>
        private string ProcessQueueResponseOnMainThread(string jsonResponse)
        {
            try
            {
                var syncCloseInstructions = ParseSyncCloseInstructions(jsonResponse);
                if (syncCloseInstructions != null && syncCloseInstructions.Count > 0)
                {
                    Print("═══════════════════════════════════════════════════════════");
                    Print("★★★ 仓位同步告警 ★★★");
                    Print("收到按 MT5 账号维度的仓位同步指令，开始执行定向平仓");
                    foreach (var ins in syncCloseInstructions)
                    {
                        if (ins == null || string.IsNullOrEmpty(ins.MT5Account) || ins.Symbols == null || ins.Symbols.Count == 0)
                            continue;
                        string symbolsStr = string.Join(", ", ins.Symbols);
                        Print("[仓位同步] MT5账号=" + ins.MT5Account + " | 标的=" + symbolsStr);
                        CloseAllPositionsForAccountSymbols(ins.MT5Account, ins.Symbols);
                    }
                    Print("═══════════════════════════════════════════════════════════");
                }
                else
                {
                    var syncCloseSymbols = ParseSyncCloseSymbols(jsonResponse);
                    if (syncCloseSymbols != null && syncCloseSymbols.Count > 0)
                    {
                        string symbolsStr = string.Join(", ", syncCloseSymbols);
                        Print("═══════════════════════════════════════════════════════════");
                        Print("★★★ 仓位同步告警（旧协议兼容） ★★★");
                        Print("未收到账号维度指令，按旧逻辑平掉以下标的: " + symbolsStr);
                        Print("═══════════════════════════════════════════════════════════");
                        CloseAllPositionsForSymbols(syncCloseSymbols);
                    }
                }

                // ---------- P1：/queue/lease 批量 ----------
                if (jsonResponse.IndexOf("\"items\":[", StringComparison.Ordinal) >= 0)
                {
                    var itemJsons = ExtractJsonObjectsFromArrayProperty(jsonResponse, "items");
                    string deliveryId = "";
                    if (jsonResponse.IndexOf("\"deliveryId\":null", StringComparison.Ordinal) >= 0)
                        deliveryId = "";
                    else
                        deliveryId = ExtractStringValue(jsonResponse, "deliveryId");

                    if (itemJsons.Count == 0)
                        return deliveryId;

                    Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                    Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 收到批量 lease 共 " + itemJsons.Count + " 条 #" + _requestCount);
                    if (!string.IsNullOrEmpty(deliveryId))
                        Print("deliveryId: " + deliveryId);

                    for (int idx = 0; idx < itemJsons.Count; idx++)
                    {
                        string one = itemJsons[idx];
                        var messageData = ParseMessageData(one);
                        if (messageData == null)
                            continue;

                        Print("--- 第 " + (idx + 1) + "/" + itemJsons.Count + " 条 ---");
                        Print("操作类型: " + messageData.Action + " | 品种: " + messageData.Symbol);

                        if (IsMessageExpired(messageData.Action, messageData.EventTimeMs, messageData.Utc8Time))
                        {
                            _expiredCount++;
                            Print("⚠️  消息已过期，跳过（超过 " + MessageExpireSeconds + " 秒）");
                            continue;
                        }

                        ExecuteTrade(messageData);
                    }

                    int queueSizeIndex = jsonResponse.IndexOf("\"queueSize\":");
                    if (queueSizeIndex >= 0)
                    {
                        int qsStart = queueSizeIndex + 12;
                        int qsEnd = jsonResponse.IndexOf(",", qsStart);
                        if (qsEnd < 0) qsEnd = jsonResponse.IndexOf("}", qsStart);
                        if (qsEnd > qsStart)
                        {
                            string queueSizeStr = jsonResponse.Substring(qsStart, qsEnd - qsStart).Trim();
                            Print("队列剩余: " + queueSizeStr + " 条消息");
                        }
                    }
                    Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

                    return string.IsNullOrEmpty(deliveryId) ? "" : deliveryId;
                }

                // ---------- 兼容旧 GET /queue/read 单条 ----------
                if (jsonResponse.Contains("\"data\":null") || jsonResponse.Contains("\"data\": null"))
                    return "";

                if (jsonResponse.Contains("\"data\":{"))
                {
                    var messageData = ParseMessageData(jsonResponse);
                    if (messageData != null)
                    {
                        Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                        Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 收到消息 #" + _requestCount);
                        Print("操作类型: " + messageData.Action);
                        Print("订单类型: " + messageData.OrderType);
                        if (!string.IsNullOrEmpty(messageData.PendingType))
                            Print("挂单类型: " + messageData.PendingType);
                        Print("交易品种: " + messageData.Symbol);
                        Print("手数: " + messageData.Volume);
                        Print("价格: " + messageData.Price);
                        if (!string.IsNullOrEmpty(messageData.MT5Account))
                            Print("MT5账号: " + messageData.MT5Account);
                        if (messageData.Ticket > 0)
                            Print("订单号: " + messageData.Ticket);
                        if (!string.IsNullOrEmpty(messageData.Utc8Time))
                            Print("时间 (UTC+8): " + messageData.Utc8Time);
                        if (messageData.EventTimeMs.HasValue)
                            Print("消息时间戳(ms): " + messageData.EventTimeMs.Value);

                        if (IsMessageExpired(messageData.Action, messageData.EventTimeMs, messageData.Utc8Time))
                        {
                            _expiredCount++;
                            Print("⚠️  消息已过期，丢弃（超过 " + MessageExpireSeconds + " 秒）");
                            Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                            return "";
                        }

                        Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                        ExecuteTrade(messageData);

                        int queueSizeIndex = jsonResponse.IndexOf("\"queueSize\":");
                        if (queueSizeIndex >= 0)
                        {
                            int start = queueSizeIndex + 12;
                            int end = jsonResponse.IndexOf(",", start);
                            if (end < 0) end = jsonResponse.IndexOf("}", start);
                            if (end > start)
                            {
                                string queueSizeStr = jsonResponse.Substring(start, end - start).Trim();
                                Print("队列剩余: " + queueSizeStr + " 条消息");
                            }
                        }
                    }
                    return "";
                }

                Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 请求成功 #" + _requestCount);
                Print("响应内容: " + jsonResponse);
                return "";
            }
            catch (Exception ex)
            {
                Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 解析响应失败: " + ex.Message);
                Print("原始响应: " + jsonResponse);
                return "";
            }
        }

        /// <summary>
        /// 解析并处理消息
        /// </summary>
        private void ProcessMessage(string jsonResponse)
        {
            ProcessQueueResponseOnMainThread(jsonResponse);
        }

        /// <summary>
        /// 消息数据类
        /// </summary>
        private class MessageData
        {
            public string Action { get; set; }
            public string OrderType { get; set; }
            public string PendingType { get; set; }
            public string Symbol { get; set; }
            public double Volume { get; set; }
            public double Price { get; set; }
            public double? SL { get; set; }
            public double? TP { get; set; }
            public long? Ticket { get; set; }
            public string Utc8Time { get; set; }
            public long? EventTimeMs { get; set; }
            public string MT5Account { get; set; }
        }

        /// <summary>
        /// 仓位同步平仓指令（按 MT5 账号维度）
        /// </summary>
        private class SyncCloseInstruction
        {
            public string MT5Account { get; set; }
            public System.Collections.Generic.List<string> Symbols { get; set; }
        }

        /// <summary>
        /// 解析消息数据
        /// </summary>
        private MessageData ParseMessageData(string json)
        {
            try
            {
                var data = new MessageData();
                
                data.Action = ExtractStringValue(json, "action");
                data.OrderType = ExtractStringValue(json, "orderType");
                data.PendingType = ExtractStringValue(json, "pendingType");
                data.Symbol = ExtractStringValue(json, "symbol");
                data.Volume = ExtractDoubleValue(json, "volume");
                data.Price = ExtractDoubleValue(json, "price");
                data.MT5Account = ExtractStringValue(json, "mt5Account");
                
                double? sl = ExtractDoubleValueNullable(json, "sl");
                if (sl.HasValue && sl.Value > 0) data.SL = sl.Value;
                
                double? tp = ExtractDoubleValueNullable(json, "tp");
                if (tp.HasValue && tp.Value > 0) data.TP = tp.Value;
                
                long? ticket = ExtractLongValueNullable(json, "ticket");
                if (ticket.HasValue && ticket.Value > 0) data.Ticket = ticket.Value;

                long? eventTimeMs = ExtractLongValueNullable(json, "eventTimeMs");
                if (eventTimeMs.HasValue && eventTimeMs.Value > 0) data.EventTimeMs = eventTimeMs.Value;
                
                // 提取时间信息
                if (json.Contains("\"timeConverted\""))
                {
                    int timeIndex = json.IndexOf("\"utc8\":\"");
                    if (timeIndex >= 0)
                    {
                        int start = timeIndex + 8;
                        int end = json.IndexOf("\"", start);
                        if (end > start)
                        {
                            data.Utc8Time = json.Substring(start, end - start);
                        }
                    }
                }
                
                return data;
            }
            catch (Exception ex)
            {
                Print("解析消息数据失败: " + ex.Message);
                return null;
            }
        }

        /// <summary>
        /// 检查消息是否过期
        /// </summary>
        private bool IsMessageExpired(string action, long? eventTimeMs, string utc8Time)
        {
            // 撤单消息优先保证执行，避免因短暂队列拥塞导致“该撤未撤”
            if (action == "pending_cancel")
                return false;

            // 统一判定优先使用 UTC 毫秒时间戳，彻底规避经纪商时区差异
            if (eventTimeMs.HasValue && eventTimeMs.Value > 0)
            {
                try
                {
                    long nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    double timeDiffSeconds = (nowMs - eventTimeMs.Value) / 1000.0;

                    if (timeDiffSeconds > MessageExpireSeconds)
                    {
                        DateTimeOffset eventUtc = DateTimeOffset.FromUnixTimeMilliseconds(eventTimeMs.Value);
                        Print("消息时间戳(ms): " + eventTimeMs.Value);
                        Print("消息时间 (UTC): " + eventUtc.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("当前时间 (UTC): " + DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("时间差: " + Math.Round(timeDiffSeconds, 2) + " 秒（消息已过期）");
                        return true;
                    }
                    if (timeDiffSeconds < -60)
                    {
                        Print("消息时间戳(ms): " + eventTimeMs.Value);
                        Print("当前时间 (UTC): " + DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("时间差: " + Math.Round(timeDiffSeconds, 2) + " 秒");
                        Print("消息时间晚于当前约 " + Math.Round(-timeDiffSeconds / 60, 1) + " 分钟（时钟偏差），按未过期处理");
                    }

                    return false;
                }
                catch (Exception ex)
                {
                    Print("时间戳解析异常: " + ex.Message);
                }
            }

            // 兼容旧消息：没有 eventTimeMs 时退回到 UTC+8 字符串判断
            if (string.IsNullOrEmpty(utc8Time))
                return false; // 如果没有时间信息，不判断过期
            
            try
            {
                // 解析UTC+8时间字符串，格式: "2025/12/05 00:22:52"
                // 将格式转换为标准格式
                string timeStr = utc8Time.Replace("/", "-");
                DateTime messageTime;
                
                // 尝试解析时间
                if (DateTime.TryParse(timeStr, out messageTime))
                {
                    // 将UTC+8时间转换为UTC时间（减去8小时）
                    DateTime messageTimeUtc = messageTime.AddHours(-8);
                    
                    // 获取当前UTC时间
                    DateTime nowUtc = DateTime.UtcNow;
                    
                    // 时间差 = 当前 - 消息时间（正数=消息在过去，负数=消息在“未来”，多为时钟偏差）
                    double timeDiffSeconds = (nowUtc - messageTimeUtc).TotalSeconds;
                    
                    // 仅当消息时间在过去且距今超过设定秒数时才判为过期；消息在“未来”时不判过期（避免时钟快导致误丢）
                    if (timeDiffSeconds > MessageExpireSeconds)
                    {
                        Print("消息时间 (UTC+8): " + messageTime.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("当前时间 (UTC): " + nowUtc.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("时间差: " + Math.Round(timeDiffSeconds, 2) + " 秒（消息已过期）");
                        return true;
                    }
                    if (timeDiffSeconds < -60)
                    { 
                        Print("消息时间 (UTC+8): " + messageTime.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("当前时间 (UTC): " + nowUtc.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("时间差: " + Math.Round(timeDiffSeconds, 2) + " 秒");
                        // 消息时间晚于当前超过 1 分钟（多为服务器与 cTrader 时钟不一致），按未过期处理
                        Print("消息时间晚于当前约 " + Math.Round(-timeDiffSeconds / 60, 1) + " 分钟（时钟偏差），按未过期处理");
                    }
                }
                else
                {
                    Print("⚠️  时间解析失败: " + utc8Time);
                }
            }
            catch (Exception ex)
            {
                Print("时间解析异常: " + ex.Message);
            }
            
            return false;
        }

        /// <summary>
        /// 执行交易操作
        /// </summary>
        private void ExecuteTrade(MessageData message)
        {
            try
            {
                if (message.Action == "open")
                {
                    ExecuteOpenPosition(message);
                }
                else if (message.Action == "close")
                {
                    ExecuteClosePosition(message);
                }
                else if (message.Action == "modify")
                {
                    ExecuteModifyPosition(message);
                }
                else if (message.Action == "pending_open")
                {
                    ExecuteOpenPendingOrder(message);
                }
                else if (message.Action == "pending_modify")
                {
                    ExecuteModifyPendingOrder(message);
                }
                else if (message.Action == "pending_cancel")
                {
                    ExecuteCancelPendingOrder(message);
                }
                else
                {
                    Print("⚠️  未知的操作类型: " + message.Action);
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 执行交易失败: " + ex.Message);
            }
        }

        /// <summary>
        /// 执行开仓操作
        /// </summary>
        private void ExecuteOpenPosition(MessageData message)
        {
            try
            {
                // 幂等保护1：同一 MT5 账号 + ticket 的持仓已存在时，跳过重复开仓
                string expectedLabel = BuildOrderLabel(message);
                if (!string.IsNullOrEmpty(expectedLabel))
                {
                    foreach (var existingPos in Positions)
                    {
                        if (existingPos.Label == expectedLabel)
                        {
                            // 若该持仓来自挂单触发且保护位未成功落地，借 open 事件补设一次
                            ApplyPositionProtectionAbsolute(existingPos, message, "重复开仓补设保护位");
                            Print("ℹ️  检测到重复开仓消息，已跳过（标签已存在）: " + expectedLabel + " | cTrader订单号=" + existingPos.Id);
                            return;
                        }
                    }

                    // 幂等保护2：若同标签挂单仍存在，说明挂单链路尚在进行（可能即将触发）；
                    // 此时不执行市价开仓，避免“挂单成交 + open消息”双重开仓。
                    foreach (var existingOrder in PendingOrders)
                    {
                        if (existingOrder.Label == expectedLabel)
                        {
                            Print("ℹ️  检测到同标签挂单仍存在，跳过open市价开仓以避免重复: " + expectedLabel + " | cTrader挂单ID=" + existingOrder.Id);
                            return;
                        }
                    }
                }

                // 获取交易品种
                var symbol = Symbols.GetSymbol(message.Symbol);
                if (symbol == null)
                {
                    Print("❌ 找不到交易品种: " + message.Symbol);
                    _tradeFailCount++;
                    return;
                }

                // 确定交易方向
                TradeType tradeType;
                if (message.OrderType == "buy")
                    tradeType = TradeType.Buy;
                else if (message.OrderType == "sell")
                    tradeType = TradeType.Sell;
                else
                {
                    Print("❌ 未知的订单类型: " + message.OrderType);
                    _tradeFailCount++;
                    return;
                }

                // 确定使用的手数：如果设置了固定手数，则使用固定手数；否则使用消息中的手数
                double volumeToUse = FixedVolume > 0 ? FixedVolume : message.Volume;
                
                // 计算手数（转换为cTrader的单位，手数转为基础单位）
                double volumeInUnits = symbol.QuantityToVolumeInUnits(volumeToUse);

                // 构建标签：优先包含 MT5 账号 + Position ID，兼容老格式
                string label = BuildOrderLabel(message);
                
                // 先执行开仓（不设置TP/SL，因为可能不准确），标签中包含 MT5 Position ID
                var result = ExecuteMarketOrder(tradeType, symbol.Name, volumeInUnits, label);

                if (result.IsSuccessful && result.Position != null)
                {
                    _tradeSuccessCount++;
                    string volumeInfo = FixedVolume > 0 
                        ? volumeToUse + "手（固定手数，消息中为" + message.Volume + "手）" 
                        : volumeToUse + "手";
                    Print("✅ 开仓成功: " + tradeType + " " + message.Symbol + " " + volumeInfo);
                    Print("   cTrader订单号: " + result.Position.Id);
                    Print("   标签: " + label);
                    if (!string.IsNullOrEmpty(message.MT5Account))
                        Print("   MT5账号: " + message.MT5Account);
                    if (message.Ticket.HasValue)
                        Print("   MT5 Position ID: " + message.Ticket.Value + " (已写入标签)");
                    
                    // 开仓成功后，立即修改TP/SL为正确值
                    if (message.TP.HasValue || message.SL.HasValue)
                    {
                        Print("   正在设置止盈/止损...");
                        double? newTP = message.TP.HasValue ? message.TP.Value : (double?)null;
                        double? newSL = message.SL.HasValue ? message.SL.Value : (double?)null;
                        
                        // 使用新的 ModifyPosition 方法（带 ProtectionType 参数）
                        var modifyResult = ModifyPosition(result.Position, newSL, newTP, ProtectionType.Absolute);
                        
                        if (modifyResult.IsSuccessful)
                        {
                            if (newTP.HasValue)
                                Print("   ✅ 止盈已设置: " + newTP.Value);
                            if (newSL.HasValue)
                                Print("   ✅ 止损已设置: " + newSL.Value);
                        }
                        else
                        {
                            string errorMsg = modifyResult.Error.HasValue ? modifyResult.Error.Value.ToString() : "未知错误";
                            Print("   ⚠️  设置止盈/止损失败: " + errorMsg);
                            Print("   请手动检查并设置止盈/止损");
                        }
                    }
                }
                else
                {
                    _tradeFailCount++;
                    string errorMsg = result.Error.HasValue ? result.Error.Value.ToString() : "未知错误";
                    Print("❌ 开仓失败: " + errorMsg);
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 开仓异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 执行平仓操作
        /// </summary>
        private void ExecuteClosePosition(MessageData message)
        {
            try
            {
                if (!message.Ticket.HasValue || message.Ticket.Value <= 0)
                {
                    Print("⚠️  平仓消息缺少订单号，尝试平仓所有持仓");
                    // 平仓所有持仓
                    CloseAllPositions();
                    return;
                }

                Position position = FindPositionByMessageIdentity(message, "平仓");

                if (position != null)
                {
                    var result = ClosePosition(position);
                    if (result.IsSuccessful)
                    {
                        _tradeSuccessCount++;
                        Print("✅ 平仓成功: 订单号 " + message.Ticket.Value);
                    }
                    else
                    {
                        _tradeFailCount++;
                        Print("❌ 平仓失败: " + result.Error);
                    }
                }
                else
                {
                    PrintPositionNotFoundHint(message, "平仓");
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 平仓异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 按绝对价格为持仓补设保护位（用于挂单成交后 open 去重场景）
        /// </summary>
        private void ApplyPositionProtectionAbsolute(Position position, MessageData message, string scene)
        {
            try
            {
                if (position == null || message == null) return;
                double? newTP = message.TP.HasValue && message.TP.Value > 0 ? message.TP.Value : (double?)null;
                double? newSL = message.SL.HasValue && message.SL.Value > 0 ? message.SL.Value : (double?)null;
                if (!newTP.HasValue && !newSL.HasValue) return;

                var modifyResult = ModifyPosition(position, newSL, newTP, ProtectionType.Absolute);
                if (modifyResult.IsSuccessful)
                {
                    if (newTP.HasValue)
                        Print("   ✅ [" + scene + "] 止盈已设置: " + newTP.Value);
                    if (newSL.HasValue)
                        Print("   ✅ [" + scene + "] 止损已设置: " + newSL.Value);
                }
                else
                {
                    string err = modifyResult.Error.HasValue ? modifyResult.Error.Value.ToString() : "未知错误";
                    Print("   ⚠️  [" + scene + "] 补设止盈止损失败: " + err);
                }
            }
            catch (Exception ex)
            {
                Print("   ⚠️  [" + scene + "] 补设止盈止损异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 队列 close/modify 找不到持仓：若该 MT5 账号刚被仓位同步平过，提示可能为重复消息。
        /// </summary>
        private void PrintPositionNotFoundHint(MessageData message, string actionLabel)
        {
            long ticket = message.Ticket.HasValue ? message.Ticket.Value : 0;
            string acc = message.MT5Account != null ? message.MT5Account.Trim() : "";
            if (!string.IsNullOrEmpty(acc))
            {
                DateTime t;
                if (_lastAccountSyncCloseUtc.TryGetValue(acc, out t))
                {
                    double sec = (DateTime.UtcNow - t).TotalSeconds;
                    if (sec >= 0 && sec <= 30)
                    {
                        Print("ℹ️  " + actionLabel + "：未找到订单号 " + ticket + " 的持仓（该 MT5 账号约 " + Math.Round(sec, 1) +
                              " 秒前已由仓位同步平仓；队列中重复到达时可忽略）");
                        return;
                    }
                }
            }
            Print("⚠️  " + actionLabel + "：未找到订单号 " + ticket + " 的持仓");
        }

        /// <summary>
        /// 平仓所有持仓
        /// </summary>
        private void CloseAllPositions()
        {
            int closedCount = 0;
            foreach (var position in Positions)
            {
                var result = ClosePosition(position);
                if (result.IsSuccessful)
                    closedCount++;
            }
            if (closedCount > 0)
            {
                _tradeSuccessCount++;
                Print("✅ 已平仓 " + closedCount + " 个持仓");
            }
        }

        /// <summary>
        /// 平掉指定标的的所有仓位（仅处理 QueueBot 开的仓，避免误平手动单）
        /// 当 MT5 对应标的已空仓而 cTrader 仍有仓位时，由服务器下发 syncCloseSymbols，调用此方法同步清空
        /// </summary>
        private void CloseAllPositionsForSymbols(System.Collections.Generic.List<string> symbols)
        {
            if (symbols == null || symbols.Count == 0) return;
            int closedCount = 0;
            foreach (var position in Positions)
            {
                if (string.IsNullOrEmpty(position.SymbolName)) continue;
                if (!position.Label.StartsWith("QueueBot", System.StringComparison.OrdinalIgnoreCase))
                    continue;
                string symbolName = position.SymbolName.Trim();
                bool match = false;
                foreach (var sym in symbols)
                {
                    if (sym != null && sym.Trim().Equals(symbolName, System.StringComparison.OrdinalIgnoreCase))
                    {
                        match = true;
                        break;
                    }
                }
                if (!match) continue;
                var result = ClosePosition(position);
                if (result.IsSuccessful)
                {
                    closedCount++;
                    Print("✅ [仓位同步] 已平仓: " + position.SymbolName + " " + position.TradeType + " 订单号 " + position.Id);
                }
                else
                {
                    Print("❌ [仓位同步] 平仓失败: " + position.SymbolName + " " + result.Error);
                }
            }
            if (closedCount > 0)
                _tradeSuccessCount++;
        }

        /// <summary>
        /// 平掉指定 MT5 账号 + 指定标的的仓位（仅处理 QueueBot 开的仓）
        /// </summary>
        private void CloseAllPositionsForAccountSymbols(string mt5Account, System.Collections.Generic.List<string> symbols)
        {
            if (string.IsNullOrEmpty(mt5Account) || symbols == null || symbols.Count == 0) return;
            string account = mt5Account.Trim();
            int closedCount = 0;
            foreach (var position in Positions)
            {
                if (string.IsNullOrEmpty(position.SymbolName)) continue;
                if (string.IsNullOrEmpty(position.Label)) continue;
                if (!position.Label.StartsWith("QueueBot", System.StringComparison.OrdinalIgnoreCase))
                    continue;

                string labelAccount;
                if (!TryExtractMt5AccountFromLabel(position.Label, out labelAccount))
                    continue; // 无账号标签的旧仓位，不参与账号维度同步平仓

                if (!labelAccount.Equals(account, System.StringComparison.Ordinal))
                    continue;

                string symbolName = position.SymbolName.Trim();
                bool match = false;
                foreach (var sym in symbols)
                {
                    if (sym != null && sym.Trim().Equals(symbolName, System.StringComparison.OrdinalIgnoreCase))
                    {
                        match = true;
                        break;
                    }
                }
                if (!match) continue;

                var result = ClosePosition(position);
                if (result.IsSuccessful)
                {
                    closedCount++;
                    Print("✅ [仓位同步-按账号] 已平仓: MT5账号=" + account + " " + position.SymbolName + " " + position.TradeType + " 订单号 " + position.Id);
                }
                else
                {
                    Print("❌ [仓位同步-按账号] 平仓失败: MT5账号=" + account + " " + position.SymbolName + " " + result.Error);
                }
            }
            if (closedCount > 0)
            {
                _tradeSuccessCount++;
                _lastAccountSyncCloseUtc[account] = DateTime.UtcNow;
            }
        }

        /// <summary>
        /// 从 JSON 响应中解析 syncCloseSymbols 数组，如 "syncCloseSymbols":["XAUUSD"] 或 "syncCloseSymbols":[]
        /// </summary>
        private System.Collections.Generic.List<string> ParseSyncCloseSymbols(string json)
        {
            var list = new System.Collections.Generic.List<string>();
            if (string.IsNullOrEmpty(json)) return list;
            int keyIndex = json.IndexOf("\"syncCloseSymbols\"", System.StringComparison.OrdinalIgnoreCase);
            if (keyIndex < 0) return list;
            int bracketStart = json.IndexOf("[", keyIndex);
            if (bracketStart < 0) return list;
            int bracketEnd = bracketStart + 1;
            int depth = 1;
            while (bracketEnd < json.Length && depth > 0)
            {
                char c = json[bracketEnd];
                if (c == '[') depth++;
                else if (c == ']') depth--;
                bracketEnd++;
            }
            if (depth != 0) return list;
            string arrStr = json.Substring(bracketStart, bracketEnd - bracketStart);
            int i = 1;
            while (i < arrStr.Length)
            {
                int quote = arrStr.IndexOf("\"", i);
                if (quote < 0) break;
                int endQuote = arrStr.IndexOf("\"", quote + 1);
                if (endQuote < 0) break;
                string symbol = arrStr.Substring(quote + 1, endQuote - quote - 1).Trim();
                if (!string.IsNullOrEmpty(symbol))
                    list.Add(symbol);
                i = endQuote + 1;
            }
            return list;
        }

        /// <summary>
        /// 从 JSON 响应中解析 syncCloseInstructions：
        /// "syncCloseInstructions":[{"mt5Account":"123","symbols":["XAUUSD"]}]
        /// </summary>
        private System.Collections.Generic.List<SyncCloseInstruction> ParseSyncCloseInstructions(string json)
        {
            var list = new System.Collections.Generic.List<SyncCloseInstruction>();
            if (string.IsNullOrEmpty(json)) return list;

            int keyIndex = json.IndexOf("\"syncCloseInstructions\"", System.StringComparison.OrdinalIgnoreCase);
            if (keyIndex < 0) return list;
            int bracketStart = json.IndexOf("[", keyIndex);
            if (bracketStart < 0) return list;
            int bracketEnd = FindMatchingBracketEnd(json, bracketStart, '[', ']');
            if (bracketEnd < 0) return list;

            string arrStr = json.Substring(bracketStart, bracketEnd - bracketStart + 1);
            int pos = 0;
            while (pos < arrStr.Length)
            {
                int objStart = arrStr.IndexOf("{", pos);
                if (objStart < 0) break;
                int objEnd = FindMatchingBracketEnd(arrStr, objStart, '{', '}');
                if (objEnd < 0) break;

                string obj = arrStr.Substring(objStart, objEnd - objStart + 1);
                string account = ExtractStringValue(obj, "mt5Account");
                var symbols = ParseStringArrayField(obj, "symbols");
                if (!string.IsNullOrEmpty(account) && symbols.Count > 0)
                {
                    list.Add(new SyncCloseInstruction
                    {
                        MT5Account = account.Trim(),
                        Symbols = symbols
                    });
                }
                pos = objEnd + 1;
            }
            return list;
        }

        /// <summary>
        /// 从标签提取 MT5 账号。支持 QueueBot_account_ticket 与 QueueBot_account。
        /// 不支持旧格式 QueueBot_ticket（返回 false）。
        /// </summary>
        private bool TryExtractMt5AccountFromLabel(string label, out string mt5Account)
        {
            mt5Account = "";
            if (string.IsNullOrEmpty(label)) return false;
            if (!label.StartsWith("QueueBot_", System.StringComparison.Ordinal)) return false;

            string suffix = label.Substring("QueueBot_".Length);
            if (string.IsNullOrEmpty(suffix)) return false;

            int underscore = suffix.IndexOf("_", System.StringComparison.Ordinal);
            if (underscore > 0)
            {
                mt5Account = suffix.Substring(0, underscore).Trim();
                return !string.IsNullOrEmpty(mt5Account);
            }

            bool allDigits = true;
            foreach (char c in suffix)
            {
                if (!char.IsDigit(c))
                {
                    allDigits = false;
                    break;
                }
            }
            if (allDigits) return false; // 视为旧格式 ticket

            mt5Account = suffix.Trim();
            return !string.IsNullOrEmpty(mt5Account);
        }

        private int FindMatchingBracketEnd(string text, int startIndex, char openChar, char closeChar)
        {
            if (string.IsNullOrEmpty(text) || startIndex < 0 || startIndex >= text.Length) return -1;
            int depth = 0;
            for (int i = startIndex; i < text.Length; i++)
            {
                char c = text[i];
                if (c == openChar) depth++;
                else if (c == closeChar)
                {
                    depth--;
                    if (depth == 0) return i;
                }
            }
            return -1;
        }

        private System.Collections.Generic.List<string> ParseStringArrayField(string json, string key)
        {
            var list = new System.Collections.Generic.List<string>();
            if (string.IsNullOrEmpty(json) || string.IsNullOrEmpty(key)) return list;
            int keyIndex = json.IndexOf("\"" + key + "\"", System.StringComparison.OrdinalIgnoreCase);
            if (keyIndex < 0) return list;
            int bracketStart = json.IndexOf("[", keyIndex);
            if (bracketStart < 0) return list;
            int bracketEnd = FindMatchingBracketEnd(json, bracketStart, '[', ']');
            if (bracketEnd < 0) return list;

            string arrStr = json.Substring(bracketStart, bracketEnd - bracketStart + 1);
            int i = 1;
            while (i < arrStr.Length)
            {
                int quote = arrStr.IndexOf("\"", i, System.StringComparison.Ordinal);
                if (quote < 0) break;
                int endQuote = arrStr.IndexOf("\"", quote + 1, System.StringComparison.Ordinal);
                if (endQuote < 0) break;
                string value = arrStr.Substring(quote + 1, endQuote - quote - 1).Trim();
                if (!string.IsNullOrEmpty(value))
                    list.Add(value);
                i = endQuote + 1;
            }
            return list;
        }

        /// <summary>
        /// 将账号仓位计数字典序列化为 "account1:count1,account2:count2"
        /// </summary>
        private string BuildAccountPositionsParam(System.Collections.Generic.Dictionary<string, int> accountPositionCounts)
        {
            if (accountPositionCounts == null || accountPositionCounts.Count == 0)
                return "";

            var parts = new System.Collections.Generic.List<string>();
            foreach (var kv in accountPositionCounts)
            {
                if (string.IsNullOrEmpty(kv.Key)) continue;
                if (kv.Value <= 0) continue;
                parts.Add(kv.Key + ":" + kv.Value);
            }
            return string.Join(",", parts);
        }

        /// <summary>
        /// 执行修改仓位操作（修改止盈/止损）
        /// </summary>
        private void ExecuteModifyPosition(MessageData message)
        {
            try
            {
                if (!message.Ticket.HasValue || message.Ticket.Value <= 0)
                {
                    Print("⚠️  修改仓位消息缺少订单号");
                    _tradeFailCount++;
                    return;
                }

                Position position = FindPositionByMessageIdentity(message, "改仓");

                if (position != null)
                {
                    // 准备新的TP/SL值
                    double? newTP = message.TP.HasValue && message.TP.Value > 0 ? message.TP.Value : (double?)null;
                    double? newSL = message.SL.HasValue && message.SL.Value > 0 ? message.SL.Value : (double?)null;
                    
                    // 如果TP和SL都没有值，则跳过
                    if (!newTP.HasValue && !newSL.HasValue)
                    {
                        Print("⚠️  修改仓位消息中没有有效的止盈/止损值");
                        return;
                    }
                    
                    Print("   正在修改仓位止盈/止损...");
                    if (newTP.HasValue)
                        Print("   新止盈: " + newTP.Value);
                    if (newSL.HasValue)
                        Print("   新止损: " + newSL.Value);
                    
                    // 使用新的 ModifyPosition 方法（带 ProtectionType 参数）
                    var modifyResult = ModifyPosition(position, newSL, newTP, ProtectionType.Absolute);
                    
                    if (modifyResult.IsSuccessful)
                    {
                        _tradeSuccessCount++;
                        Print("✅ 仓位修改成功: 订单号 " + message.Ticket.Value);
                        if (newTP.HasValue)
                            Print("   止盈: " + newTP.Value);
                        if (newSL.HasValue)
                            Print("   止损: " + newSL.Value);
                    }
                    else
                    {
                        _tradeFailCount++;
                        string errorMsg = modifyResult.Error.HasValue ? modifyResult.Error.Value.ToString() : "未知错误";
                        Print("❌ 仓位修改失败: " + errorMsg);
                    }
                }
                else
                {
                    PrintPositionNotFoundHint(message, "改仓");
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 修改仓位异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 执行挂单新增（当前先支持限价单）
        /// </summary>
        private void ExecuteOpenPendingOrder(MessageData message)
        {
            try
            {
                string pendingType = !string.IsNullOrEmpty(message.PendingType)
                    ? message.PendingType.Trim().ToLowerInvariant()
                    : "limit";

                if (pendingType != "limit" && pendingType != "stop")
                {
                    Print("⚠️  暂不支持该挂单类型: " + message.PendingType + "（仅支持 limit/stop）");
                    return;
                }

                var symbol = Symbols.GetSymbol(message.Symbol);
                if (symbol == null)
                {
                    _tradeFailCount++;
                    Print("❌ 找不到交易品种: " + message.Symbol);
                    return;
                }

                if (message.Price <= 0)
                {
                    _tradeFailCount++;
                    Print("❌ 限价单价格无效: " + message.Price);
                    return;
                }

                TradeType tradeType;
                if (!TryGetTradeType(message.OrderType, out tradeType))
                {
                    _tradeFailCount++;
                    Print("❌ 未知的订单方向: " + message.OrderType);
                    return;
                }

                double volumeToUse = FixedVolume > 0 ? FixedVolume : message.Volume;
                if (volumeToUse <= 0)
                {
                    _tradeFailCount++;
                    Print("❌ 挂单手数无效: " + volumeToUse);
                    return;
                }

                double volumeInUnits = symbol.QuantityToVolumeInUnits(volumeToUse);
                string label = BuildOrderLabel(message);

                TradeResult result;
                if (pendingType == "stop")
                {
                    // 第一步：仅创建挂单，避免下单接口对保护位参数语义（价格/点数）存在歧义
                    result = PlaceStopOrder(tradeType, symbol.Name, volumeInUnits, message.Price, label);
                }
                else
                {
                    // 第一步：仅创建挂单，避免下单接口对保护位参数语义（价格/点数）存在歧义
                    result = PlaceLimitOrder(tradeType, symbol.Name, volumeInUnits, message.Price, label);
                }

                if (result.IsSuccessful)
                {
                    _tradeSuccessCount++;
                    string orderTypeText = pendingType == "stop" ? "止损挂单" : "限价挂单";
                    Print("✅ " + orderTypeText + "创建成功: " + tradeType + " " + symbol.Name + " @ " + message.Price);
                    Print("   标签: " + label);

                    // 第二步：显式按绝对价格写入保护位，彻底消除价格/点数语义混淆
                    ApplyPendingProtectionAbsolute(message);
                }
                else
                {
                    _tradeFailCount++;
                    string errorMsg = result.Error.HasValue ? result.Error.Value.ToString() : "未知错误";
                    Print("❌ 挂单创建失败(" + pendingType + "): " + errorMsg);
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 创建挂单异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 执行挂单修改：通过撤单再下新单实现（确保与 MT5 最新价格一致）
        /// </summary>
        private void ExecuteModifyPendingOrder(MessageData message)
        {
            try
            {
                // 改挂单必须严格按标签命中，禁止品种+方向兼容匹配（会误命中其他ticket）
                var existingOrder = FindPendingOrderByMessageIdentity(message, "改挂单", false);
                if (existingOrder == null)
                {
                    // 若同标签持仓已存在，说明该挂单已触发成交；此时忽略 modify，避免重建新挂单
                    string exactLabel = BuildOrderLabel(message);
                    if (!string.IsNullOrEmpty(exactLabel))
                    {
                        foreach (var pos in Positions)
                        {
                            if (pos.Label == exactLabel)
                            {
                                Print("ℹ️  改挂单已忽略：同标签持仓已存在（挂单已触发）: " + exactLabel + " | cTrader订单号=" + pos.Id);
                                return;
                            }
                        }
                    }
                    Print("⚠️  改挂单：未找到对应挂单（严格匹配）");
                    return;
                }

                var cancelResult = CancelPendingOrder(existingOrder);
                if (!cancelResult.IsSuccessful)
                {
                    _tradeFailCount++;
                    string cancelError = cancelResult.Error.HasValue ? cancelResult.Error.Value.ToString() : "未知错误";
                    Print("❌ 改挂单失败（撤销旧单失败）: " + cancelError);
                    return;
                }

                Print("✅ 已撤销旧挂单，开始按新参数重建");
                ExecuteOpenPendingOrder(message);
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 修改挂单异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 执行挂单撤销
        /// </summary>
        private void ExecuteCancelPendingOrder(MessageData message)
        {
            try
            {
                var existingOrder = FindPendingOrderByMessageIdentity(message, "撤挂单", true);
                if (existingOrder == null)
                {
                    Print("⚠️  撤挂单：未找到对应挂单");
                    return;
                }

                var cancelResult = CancelPendingOrder(existingOrder);
                if (cancelResult.IsSuccessful)
                {
                    _tradeSuccessCount++;
                    Print("✅ 挂单撤销成功");
                }
                else
                {
                    _tradeFailCount++;
                    string cancelError = cancelResult.Error.HasValue ? cancelResult.Error.Value.ToString() : "未知错误";
                    Print("❌ 挂单撤销失败: " + cancelError);
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 撤销挂单异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 将 buy/sell 文本转换为 cTrader TradeType
        /// </summary>
        private bool TryGetTradeType(string orderType, out TradeType tradeType)
        {
            tradeType = TradeType.Buy;
            if (orderType == "buy")
            {
                tradeType = TradeType.Buy;
                return true;
            }
            if (orderType == "sell")
            {
                tradeType = TradeType.Sell;
                return true;
            }
            return false;
        }

        /// <summary>
        /// 按消息身份查找挂单（优先标签精确匹配）
        /// </summary>
        private PendingOrder FindPendingOrderByMessageIdentity(MessageData message, string purpose, bool allowFallback)
        {
            if (message == null) return null;

            string exactLabel = BuildOrderLabel(message);
            if (!string.IsNullOrEmpty(exactLabel))
            {
                foreach (var order in PendingOrders)
                {
                    if (order.Label == exactLabel)
                    {
                        Print("   [" + purpose + "] 标签匹配命中挂单: cTrader订单号=" + order.Id + ", 标签=" + order.Label);
                        return order;
                    }
                }
            }

            if (allowFallback)
            {
                TradeType tradeType;
                if (TryGetTradeType(message.OrderType, out tradeType))
                {
                    foreach (var order in PendingOrders)
                    {
                        if (order.SymbolName == message.Symbol && order.TradeType == tradeType)
                        {
                            Print("   ⚠️  [" + purpose + "] 兼容匹配命中挂单: cTrader订单号=" + order.Id + ", 标签=" + order.Label);
                            return order;
                        }
                    }
                }
            }

            return null;
        }

        /// <summary>
        /// 为挂单写入止损止盈（绝对价格）
        /// </summary>
        private void ApplyPendingProtectionAbsolute(MessageData message)
        {
            try
            {
                if (message == null) return;
                double? stopLoss = message.SL.HasValue && message.SL.Value > 0 ? message.SL.Value : (double?)null;
                double? takeProfit = message.TP.HasValue && message.TP.Value > 0 ? message.TP.Value : (double?)null;
                if (!stopLoss.HasValue && !takeProfit.HasValue)
                    return;

                var order = FindPendingOrderByMessageIdentity(message, "设置挂单保护位", false);
                if (order == null)
                {
                    Print("⚠️  挂单已创建，但未找到可设置保护位的挂单");
                    return;
                }

                var modifyResult = ModifyPendingOrder(order, order.TargetPrice, stopLoss, takeProfit, ProtectionType.Absolute);
                if (modifyResult.IsSuccessful)
                {
                    if (stopLoss.HasValue)
                        Print("   ✅ 挂单止损已设置(价格): " + stopLoss.Value);
                    if (takeProfit.HasValue)
                        Print("   ✅ 挂单止盈已设置(价格): " + takeProfit.Value);
                }
                else
                {
                    string errorMsg = modifyResult.Error.HasValue ? modifyResult.Error.Value.ToString() : "未知错误";
                    Print("⚠️  挂单创建成功，但设置保护位失败: " + errorMsg);
                }
            }
            catch (Exception ex)
            {
                Print("⚠️  挂单创建成功，但设置保护位异常: " + ex.Message);
            }
        }

        /// <summary>
        /// 从JSON字符串中提取字符串值
        /// </summary>
        private string ExtractStringValue(string json, string fieldName)
        {
            try
            {
                string searchPattern = "\"" + fieldName + "\":";
                int index = json.IndexOf(searchPattern);
                if (index >= 0)
                {
                    int start = index + searchPattern.Length;
                    while (start < json.Length && char.IsWhiteSpace(json[start])) start++;
                    
                    if (start < json.Length && json[start] == '"')
                    {
                        start++;
                        int end = json.IndexOf("\"", start);
                        if (end > start)
                        {
                            return json.Substring(start, end - start);
                        }
                    }
                }
            }
            catch { }
            return "";
        }

        /// <summary>
        /// 从JSON字符串中提取double值
        /// </summary>
        private double ExtractDoubleValue(string json, string fieldName)
        {
            try
            {
                string searchPattern = "\"" + fieldName + "\":";
                int index = json.IndexOf(searchPattern);
                if (index >= 0)
                {
                    int start = index + searchPattern.Length;
                    while (start < json.Length && char.IsWhiteSpace(json[start])) start++;
                    
                    int end = start;
                    while (end < json.Length && (char.IsDigit(json[end]) || json[end] == '.' || json[end] == '-' || json[end] == 'e' || json[end] == 'E' || json[end] == '+'))
                    {
                        end++;
                        if (end < json.Length && (json[end] == ',' || json[end] == '}')) break;
                    }
                    if (end > start)
                    {
                        string valueStr = json.Substring(start, end - start).TrimEnd(',', ' ', '\r', '\n');
                        double value;
                        if (double.TryParse(valueStr, out value))
                            return value;
                    }
                }
            }
            catch { }
            return 0;
        }

        /// <summary>
        /// 从JSON字符串中提取可空的double值
        /// </summary>
        private double? ExtractDoubleValueNullable(string json, string fieldName)
        {
            double value = ExtractDoubleValue(json, fieldName);
            return value > 0 ? value : (double?)null;
        }

        /// <summary>
        /// 从JSON字符串中提取可空的long值
        /// </summary>
        private long? ExtractLongValueNullable(string json, string fieldName)
        {
            try
            {
                string searchPattern = "\"" + fieldName + "\":";
                int index = json.IndexOf(searchPattern);
                if (index >= 0)
                {
                    int start = index + searchPattern.Length;
                    while (start < json.Length && char.IsWhiteSpace(json[start])) start++;
                    
                    int end = start;
                    while (end < json.Length && char.IsDigit(json[end]))
                    {
                        end++;
                        if (end < json.Length && (json[end] == ',' || json[end] == '}')) break;
                    }
                    if (end > start)
                    {
                        string valueStr = json.Substring(start, end - start).TrimEnd(',', ' ', '\r', '\n');
                        long value;
                        if (long.TryParse(valueStr, out value))
                            return value;
                    }
                }
            }
            catch { }
            return null;
        }

        /// <summary>
        /// 从JSON字符串中提取并打印字段值（保留用于调试）
        /// </summary>
        private void ExtractAndPrint(string json, string fieldName, string displayName)
        {
            try
            {
                string searchPattern = "\"" + fieldName + "\":";
                int index = json.IndexOf(searchPattern);
                if (index >= 0)
                {
                    int start = index + searchPattern.Length;
                    // 跳过空格
                    while (start < json.Length && char.IsWhiteSpace(json[start])) start++;
                    
                    if (start < json.Length)
                    {
                        int end;
                        // 字符串值
                        if (json[start] == '"')
                        {
                            start++;
                            end = json.IndexOf("\"", start);
                            if (end > start)
                            {
                                string value = json.Substring(start, end - start);
                                Print(displayName + ": " + value);
                            }
                        }
                        // 数字值
                        else if (char.IsDigit(json[start]) || json[start] == '-')
                        {
                            end = start;
                            while (end < json.Length && (char.IsDigit(json[end]) || json[end] == '.' || json[end] == '-' || json[end] == 'e' || json[end] == 'E' || json[end] == '+'))
                            {
                                end++;
                                if (json[end - 1] == ',' || json[end - 1] == '}') break;
                            }
                            if (end > start)
                            {
                                string value = json.Substring(start, end - start).TrimEnd(',', ' ', '\r', '\n');
                                Print(displayName + ": " + value);
                            }
                        }
                    }
                }
            }
            catch
            {
                // 忽略解析错误
            }
        }

        /// <summary>
        /// 生成订单标签：
        /// 1) QueueBot_MT5Account_PositionId
        /// 2) QueueBot_MT5Account
        /// 3) QueueBot_PositionId（兼容旧逻辑）
        /// 4) QueueBot
        /// </summary>
        private string BuildOrderLabel(MessageData message)
        {
            string account = message != null && !string.IsNullOrEmpty(message.MT5Account)
                ? message.MT5Account.Trim()
                : "";
            string ticket = message != null && message.Ticket.HasValue && message.Ticket.Value > 0
                ? message.Ticket.Value.ToString()
                : "";

            if (!string.IsNullOrEmpty(account) && !string.IsNullOrEmpty(ticket))
                return "QueueBot_" + account + "_" + ticket;
            if (!string.IsNullOrEmpty(account))
                return "QueueBot_" + account;
            if (!string.IsNullOrEmpty(ticket))
                return "QueueBot_" + ticket;
            return "QueueBot";
        }

        /// <summary>
        /// 按消息身份查找持仓（严格 -> 兼容 -> 降级）
        /// </summary>
        private Position FindPositionByMessageIdentity(MessageData message, string purpose)
        {
            if (message == null) return null;

            string account = !string.IsNullOrEmpty(message.MT5Account) ? message.MT5Account.Trim() : "";
            string ticket = message.Ticket.HasValue && message.Ticket.Value > 0 ? message.Ticket.Value.ToString() : "";

            // 1) 精确匹配：QueueBot_account_ticket
            if (!string.IsNullOrEmpty(account) && !string.IsNullOrEmpty(ticket))
            {
                string exactLabel = "QueueBot_" + account + "_" + ticket;
                foreach (var pos in Positions)
                {
                    if (pos.Label == exactLabel)
                    {
                        Print("   [" + purpose + "] 精确匹配命中: cTrader订单号=" + pos.Id + ", 标签=" + pos.Label);
                        return pos;
                    }
                }
            }

            // 2) 账号约束 + ticket 后缀匹配（兼容同账号下标签变体）
            if (!string.IsNullOrEmpty(account) && !string.IsNullOrEmpty(ticket))
            {
                string accountPrefix = "QueueBot_" + account + "_";
                string ticketSuffix = "_" + ticket;
                foreach (var pos in Positions)
                {
                    if (!string.IsNullOrEmpty(pos.Label)
                        && pos.Label.StartsWith(accountPrefix, System.StringComparison.Ordinal)
                        && pos.Label.EndsWith(ticketSuffix, System.StringComparison.Ordinal))
                    {
                        Print("   [" + purpose + "] 账号+订单号匹配命中: cTrader订单号=" + pos.Id + ", 标签=" + pos.Label);
                        return pos;
                    }
                }
            }

            // 3) 旧格式兼容：QueueBot_ticket
            if (!string.IsNullOrEmpty(ticket))
            {
                string legacyLabel = "QueueBot_" + ticket;
                foreach (var pos in Positions)
                {
                    if (pos.Label == legacyLabel)
                    {
                        Print("   ⚠️  [" + purpose + "] 兼容匹配（旧标签格式）: cTrader订单号=" + pos.Id + ", 标签=" + pos.Label);
                        return pos;
                    }
                }
            }

            // 4) 最终降级：旧逻辑（QueueBot + 品种 + 方向）
            if (!string.IsNullOrEmpty(message.Symbol) && !string.IsNullOrEmpty(message.OrderType))
            {
                TradeType tradeType = message.OrderType == "buy" ? TradeType.Buy : TradeType.Sell;
                Position position = Positions.Find("QueueBot", message.Symbol, tradeType);
                if (position == null)
                {
                    TradeType oppositeType = message.OrderType == "buy" ? TradeType.Sell : TradeType.Buy;
                    position = Positions.Find("QueueBot", message.Symbol, oppositeType);
                }
                if (position != null)
                {
                    Print("   ⚠️  [" + purpose + "] 兼容匹配（降级策略）: cTrader订单号=" + position.Id + ", 标签=" + position.Label);
                    return position;
                }
            }

            return null;
        }

        protected override void OnStop()
        {
            // 释放HTTP客户端
            if (_httpClient != null)
            {
                _httpClient.Dispose();
            }

            Print("Queue Reader Bot 已停止");
            Print("统计: 总请求=" + _requestCount + " | 成功=" + _successCount + " | 失败=" + _failCount);
            Print("消息统计: 过期=" + _expiredCount);
            Print("交易统计: 成功=" + _tradeSuccessCount + " | 失败=" + _tradeFailCount);
        }
    }
}

