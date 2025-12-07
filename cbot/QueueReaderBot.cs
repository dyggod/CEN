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
                // 使用 Task.Run 在后台执行异步操作
                Task.Run(async () => await RequestQueueMessage());
            }
        }

        private async Task RequestQueueMessage()
        {
            _requestCount++;

            try
            {
                // 构建带账户ID的URL（使用预先获取的账户ID，避免在后台线程访问 Account.Number）
                string urlWithAccountId = ServerURL;
                if (ServerURL.Contains("?"))
                {
                    urlWithAccountId += "&accountId=" + _accountId;
                }
                else
                {
                    urlWithAccountId += "?accountId=" + _accountId;
                }
                
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
                    
                    // 计算时间差（秒）
                    double timeDiff = Math.Abs((nowUtc - messageTimeUtc).TotalSeconds);
                    
                    if (timeDiff > MessageExpireSeconds)
                    {
                        Print("消息时间 (UTC+8): " + messageTime.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("当前时间 (UTC): " + nowUtc.ToString("yyyy-MM-dd HH:mm:ss"));
                        Print("时间差: " + Math.Round(timeDiff, 2) + " 秒");
                        return true;
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

                // 先执行开仓（不设置TP/SL，因为可能不准确）
                var result = ExecuteMarketOrder(tradeType, symbol.Name, volumeInUnits, "QueueBot");

                if (result.IsSuccessful && result.Position != null)
                {
                    _tradeSuccessCount++;
                    string volumeInfo = FixedVolume > 0 
                        ? volumeToUse + "手（固定手数，消息中为" + message.Volume + "手）" 
                        : volumeToUse + "手";
                    Print("✅ 开仓成功: " + tradeType + " " + message.Symbol + " " + volumeInfo);
                    Print("   订单号: " + result.Position.Id);
                    
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

                // 根据订单号查找持仓
                Position position = null;
                
                // 先尝试通过订单号查找
                foreach (var pos in Positions)
                {
                    if (pos.Id == message.Ticket.Value)
                    {
                        position = pos;
                        break;
                    }
                }
                
                // 如果没找到，尝试通过标签和品种查找
                if (position == null)
                {
                    position = Positions.Find("QueueBot", message.Symbol, TradeType.Buy);
                    if (position == null)
                        position = Positions.Find("QueueBot", message.Symbol, TradeType.Sell);
                }

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

                // 根据订单号查找持仓
                Position position = null;
                
                // 先尝试通过订单号查找
                foreach (var pos in Positions)
                {
                    if (pos.Id == message.Ticket.Value)
                    {
                        position = pos;
                        break;
                    }
                }
                
                // 如果没找到，尝试通过标签和品种查找
                if (position == null)
                {
                    position = Positions.Find("QueueBot", message.Symbol, TradeType.Buy);
                    if (position == null)
                        position = Positions.Find("QueueBot", message.Symbol, TradeType.Sell);
                }

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

