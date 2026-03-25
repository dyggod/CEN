using System;
using System.Net.Http;
using System.Threading.Tasks;
using cAlgo.API;

namespace cAlgo.Robots
{
    [Robot(TimeZone = TimeZones.UTC)]
    public class QueueReaderBot : Robot
    {
        // 输入参数
        [Parameter("服务器地址", DefaultValue = "http://127.0.0.1:6699/queue/read")]
        public string ServerURL { get; set; }

        [Parameter("请求间隔（秒）", DefaultValue = 1, MinValue = 1)]
        public int RequestInterval { get; set; }

        [Parameter("消息过期时间（秒）", DefaultValue = 5, MinValue = 1)]
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
        private DateTime _lastRequestTime = DateTime.MinValue;

        protected override void OnStart()
        {
            // 在主线程中获取账户ID（必须在主线程中访问 Account.Number）
            _accountId = Account.Number;
            
            // 初始化HTTP客户端
            _httpClient = new HttpClient();
            _httpClient.Timeout = TimeSpan.FromSeconds(5);

            // 启动定时器，每秒触发一次 OnTimer
            Timer.Start(1);

            Print("Queue Reader Bot 已启动");
            Print("服务器地址: " + ServerURL);
            Print("当前账户ID: " + _accountId);
            Print("请求间隔: " + RequestInterval + " 秒");
            Print("消息过期时间: " + MessageExpireSeconds + " 秒");
            if (FixedVolume > 0)
                Print("固定手数: " + FixedVolume + " 手（将忽略消息中的手数）");
            else
                Print("手数模式: 跟随消息中的手数");
        }

        protected override void OnTimer()
        {
            // 检查是否到了请求时间（根据 RequestInterval 参数控制）
            if ((DateTime.Now - _lastRequestTime).TotalSeconds >= RequestInterval)
            {
                _lastRequestTime = DateTime.Now;
                
                // 在主线程中获取仓位信息（Positions 只能在主线程访问）
                // 只统计指定标的的仓位
                string[] checkSymbolsArray = CheckSymbols.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
                int totalPositions = 0;
                int buyPositions = 0;
                int sellPositions = 0;
                
                foreach (var position in Positions)
                {
                    // 检查是否在要检查的标的列表中
                    bool shouldCheck = false;
                    if (checkSymbolsArray.Length == 0)
                    {
                        // 如果没有配置标的，默认检查所有（兼容旧版本）
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
                    }
                }
                
                // 使用 Task.Run 在后台执行异步操作，传递仓位信息
                Task.Run(async () => await RequestQueueMessage(totalPositions, buyPositions, sellPositions));
            }
        }

        private async Task RequestQueueMessage(int totalPositions, int buyPositions, int sellPositions)
        {
            _requestCount++;

            try
            {
                // 构建带账户ID和仓位信息的URL（使用预先获取的账户ID，避免在后台线程访问 Account.Number）
                string urlWithAccountId = ServerURL;
                if (ServerURL.Contains("?"))
                {
                    urlWithAccountId += "&accountId=" + _accountId;
                }
                else
                {
                    urlWithAccountId += "?accountId=" + _accountId;
                }
                
                // 添加仓位信息到URL查询参数
                urlWithAccountId += "&total=" + totalPositions;
                urlWithAccountId += "&buy=" + buyPositions;
                urlWithAccountId += "&sell=" + sellPositions;
                
                // 发送GET请求
                HttpResponseMessage response = await _httpClient.GetAsync(urlWithAccountId);
                response.EnsureSuccessStatusCode();
                
                // 读取响应内容
                string responseBody = await response.Content.ReadAsStringAsync();
                
                _successCount++;
                
                // 在主线程中处理消息（Print 和交易操作必须在主线程）
                BeginInvokeOnMainThread(() => {
                    ProcessMessage(responseBody);
                });
                
            }
            catch (Exception ex)
            {
                _failCount++;
                // 错误信息也要在主线程中打印
                BeginInvokeOnMainThread(() => {
                    Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 请求失败 #" + _requestCount);
                    Print("错误: " + ex.Message);
                });
            }
        }

        /// <summary>
        /// 解析并处理消息
        /// </summary>
        private void ProcessMessage(string jsonResponse)
        {
            try
            {
                // 优先处理仓位同步：MT5 已空仓但 cTrader 仍有仓位时，服务器会返回 syncCloseSymbols，需平掉这些标的的仓位
                var syncCloseSymbols = ParseSyncCloseSymbols(jsonResponse);
                if (syncCloseSymbols != null && syncCloseSymbols.Count > 0)
                {
                    string symbolsStr = string.Join(", ", syncCloseSymbols);
                    Print("═══════════════════════════════════════════════════════════");
                    Print("★★★ 仓位同步告警 ★★★");
                    Print("MT5 对应标的已空仓，cTrader 仍有仓位，正在平掉以下标的: " + symbolsStr);
                    Print("═══════════════════════════════════════════════════════════");
                    CloseAllPositionsForSymbols(syncCloseSymbols);
                }

                // 检查是否包含"data":null（队列为空）
                if (jsonResponse.Contains("\"data\":null") || jsonResponse.Contains("\"data\": null"))
                {
                    // 队列为空，不打印日志，直接返回
                    return;
                }

                // 检查是否有消息数据
                if (jsonResponse.Contains("\"data\":{"))
                {
                    // 解析消息数据
                    var messageData = ParseMessageData(jsonResponse);
                    
                    if (messageData != null)
                    {
                        Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                        Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 收到消息 #" + _requestCount);
                        Print("操作类型: " + messageData.Action);
                        Print("订单类型: " + messageData.OrderType);
                        Print("交易品种: " + messageData.Symbol);
                        Print("手数: " + messageData.Volume);
                        Print("价格: " + messageData.Price);
                        if (!string.IsNullOrEmpty(messageData.MT5Account))
                            Print("MT5账号: " + messageData.MT5Account);
                        if (messageData.Ticket > 0)
                            Print("订单号: " + messageData.Ticket);
                        if (!string.IsNullOrEmpty(messageData.Utc8Time))
                            Print("时间 (UTC+8): " + messageData.Utc8Time);
                        
                        // 检查消息是否过期
                        if (IsMessageExpired(messageData.Utc8Time))
                        {
                            _expiredCount++;
                            Print("⚠️  消息已过期，丢弃（超过 " + MessageExpireSeconds + " 秒）");
                            Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                            return;
                        }
                        
                        Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                        
                        // 执行交易操作
                        ExecuteTrade(messageData);
                        
                        // 提取队列大小
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
                }
                else
                {
                    // 无法解析，打印原始响应
                    Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 请求成功 #" + _requestCount);
                    Print("响应内容: " + jsonResponse);
                }
            }
            catch (Exception ex)
            {
                Print("[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] 解析响应失败: " + ex.Message);
                Print("原始响应: " + jsonResponse);
            }
        }

        /// <summary>
        /// 消息数据类
        /// </summary>
        private class MessageData
        {
            public string Action { get; set; }
            public string OrderType { get; set; }
            public string Symbol { get; set; }
            public double Volume { get; set; }
            public double Price { get; set; }
            public double? SL { get; set; }
            public double? TP { get; set; }
            public long? Ticket { get; set; }
            public string Utc8Time { get; set; }
            public string MT5Account { get; set; }
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
        private bool IsMessageExpired(string utc8Time)
        {
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
                        Print("时间差: " + Math.Round(timeDiffSeconds, 2) + " 秒（消息已过期）");
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
                    Print("⚠️  未找到订单号 " + message.Ticket.Value + " 的持仓");
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 平仓异常: " + ex.Message);
            }
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
                    Print("⚠️  未找到订单号 " + message.Ticket.Value + " 的持仓");
                }
            }
            catch (Exception ex)
            {
                _tradeFailCount++;
                Print("❌ 修改仓位异常: " + ex.Message);
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

