//+------------------------------------------------------------------+
//|                                              HealthCheckEA.mq5   |
//|                                 每秒钟请求一次健康检查接口的EA    |
//+------------------------------------------------------------------+
#property copyright "Health Check EA"
#property link      ""
#property version   "1.00"

//--- 输入参数
input string   ServerURL = "http://127.0.0.1:6699/health";  // 健康检查服务器地址
input string   TradeServerURL = "http://127.0.0.1:6699/trade";  // 交易信息服务器地址
input string   PositionReportURL = "http://127.0.0.1:6699/position/report";  // 仓位上报服务器地址
input int      RequestInterval = 1;                          // 请求间隔（秒）
input int      PositionReportInterval = 5;                   // 仓位上报间隔（秒，默认5秒）
input string   CheckSymbols = "XAUUSD";                     // 仓位检查的交易标的（多个用逗号分隔，如"XAUUSD,EURUSD"）

//--- 全局变量
int requestCount = 0;  // 请求计数
int successCount = 0;  // 成功计数
int failCount = 0;     // 失败计数
ulong processedDeals[];  // 已处理的成交单列表（用于去重）
datetime lastPositionReportTime = 0;  // 上次仓位上报时间
ulong trackedPendingTickets[]; // 已观测到的挂单ticket（用于删除事件兜底）

bool IsTrackedPendingTicket(ulong ticket)
{
    int n = ArraySize(trackedPendingTickets);
    for(int i = 0; i < n; i++)
    {
        if(trackedPendingTickets[i] == ticket)
            return true;
    }
    return false;
}

void TrackPendingTicket(ulong ticket)
{
    if(ticket == 0) return;
    if(IsTrackedPendingTicket(ticket)) return;
    int n = ArraySize(trackedPendingTickets);
    ArrayResize(trackedPendingTickets, n + 1);
    trackedPendingTickets[n] = ticket;
}

void UntrackPendingTicket(ulong ticket)
{
    int n = ArraySize(trackedPendingTickets);
    for(int i = 0; i < n; i++)
    {
        if(trackedPendingTickets[i] == ticket)
        {
            for(int j = i; j < n - 1; j++)
                trackedPendingTickets[j] = trackedPendingTickets[j + 1];
            ArrayResize(trackedPendingTickets, n - 1);
            return;
        }
    }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    EventSetTimer(RequestInterval);
    long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
    Print("Health Check EA 已启动 - ", ServerURL);
    Print("当前账户ID: ", accountId);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    Print("Health Check EA 已停止 - 总请求: ", requestCount, " | 成功: ", successCount, " | 失败: ", failCount);
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
    // 发送HTTP请求
    SendHealthCheckRequest();
    
    // 检查是否需要上报仓位信息
    datetime currentTime = TimeCurrent();
    if(currentTime - lastPositionReportTime >= PositionReportInterval)
    {
        SendPositionReport();
        lastPositionReportTime = currentTime;
    }
}

//+------------------------------------------------------------------+
//| 发送健康检查请求                                                 |
//+------------------------------------------------------------------+
void SendHealthCheckRequest()
{
    char data[];
    char result[];
    string result_headers;
    
    ArrayResize(data, 0);
    int res = WebRequest("GET", ServerURL, "", "", 5000, data, 0, result, result_headers);
    
    requestCount++;
    
    if(res == -1)
    {
        failCount++;
    }
    else
    {
        successCount++;
    }
}

//+------------------------------------------------------------------+
//| 交易事务回调函数                                                 |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // 处理挂单事件（新增/修改/删除），用于同步 MT5 限价单到 cTrader
    if(trans.type == TRADE_TRANSACTION_ORDER_ADD ||
       trans.type == TRADE_TRANSACTION_ORDER_UPDATE ||
       trans.type == TRADE_TRANSACTION_ORDER_DELETE)
    {
        ulong orderTicket = trans.order;
        if(orderTicket > 0)
        {
            bool isDeleteEvent = (trans.type == TRADE_TRANSACTION_ORDER_DELETE);
            bool selected = false;
            ENUM_ORDER_TYPE orderKind = ORDER_TYPE_BUY;
            ENUM_ORDER_STATE orderState = ORDER_STATE_STARTED;
            string symbol = "";
            double volume = 0;
            double price = 0;
            double sl = 0;
            double tp = 0;
            // 事件时间：优先使用订单自身时间，最后再兜底到当前时间（秒转毫秒）
            // 注意：MqlTradeTransaction 在当前环境无 time_msc 字段
            long eventTimeMs = 0;
            string comment = "";

            // 新增/修改优先从当前挂单读取；删除事件通常在历史订单里
            if(!isDeleteEvent && OrderSelect(orderTicket))
            {
                selected = true;
                orderKind = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
                orderState = (ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE);
                symbol = OrderGetString(ORDER_SYMBOL);
                volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
                price = OrderGetDouble(ORDER_PRICE_OPEN);
                sl = OrderGetDouble(ORDER_SL);
                tp = OrderGetDouble(ORDER_TP);
                // 时间戳策略：
                // - ORDER_ADD：可用 setup 时间
                // - ORDER_UPDATE：必须使用“当前事件时间”，避免后期改SL/TP仍携带建单时间导致过期
                if(trans.type == TRADE_TRANSACTION_ORDER_UPDATE)
                    eventTimeMs = (long)TimeCurrent() * 1000;
                else
                    eventTimeMs = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);
                comment = OrderGetString(ORDER_COMMENT);
            }

            if(!selected && HistoryOrderSelect(orderTicket))
            {
                selected = true;
                orderKind = (ENUM_ORDER_TYPE)HistoryOrderGetInteger(orderTicket, ORDER_TYPE);
                orderState = (ENUM_ORDER_STATE)HistoryOrderGetInteger(orderTicket, ORDER_STATE);
                symbol = HistoryOrderGetString(orderTicket, ORDER_SYMBOL);
                volume = HistoryOrderGetDouble(orderTicket, ORDER_VOLUME_CURRENT);
                price = HistoryOrderGetDouble(orderTicket, ORDER_PRICE_OPEN);
                sl = HistoryOrderGetDouble(orderTicket, ORDER_SL);
                tp = HistoryOrderGetDouble(orderTicket, ORDER_TP);
                // 删除事件优先使用成交/撤销完成时间；仍不可用再回退创建时间
                eventTimeMs = (long)HistoryOrderGetInteger(orderTicket, ORDER_TIME_DONE_MSC);
                if(eventTimeMs <= 0)
                    eventTimeMs = (long)HistoryOrderGetInteger(orderTicket, ORDER_TIME_SETUP_MSC);
                comment = HistoryOrderGetString(orderTicket, ORDER_COMMENT);
            }

            // 删除事件兜底：当订单池/历史池暂时读不到详情时，若请求动作为 REMOVE，
            // 说明这是明确的“撤挂单”，仍应下发 pending_cancel；否则忽略以避免误报。
            if(isDeleteEvent && !selected)
            {
                bool likelyCancelByRequest = (request.action == TRADE_ACTION_REMOVE);
                bool likelyKnownPending = IsTrackedPendingTicket(orderTicket);
                if(!likelyCancelByRequest && !likelyKnownPending)
                    return;

                if(eventTimeMs <= 0)
                    eventTimeMs = (long)TimeCurrent() * 1000;
                SendTradeInfo("pending_cancel", "", "", 0, 0, 0, 0, (long)orderTicket, "", 0, eventTimeMs, "");
                UntrackPendingTicket(orderTicket);
                return;
            }

            if(selected)
            {
                string orderType = "";
                string pendingType = "";

                if(orderKind == ORDER_TYPE_BUY_LIMIT)
                {
                    orderType = "buy";
                    pendingType = "limit";
                }
                else if(orderKind == ORDER_TYPE_SELL_LIMIT)
                {
                    orderType = "sell";
                    pendingType = "limit";
                }
                else if(orderKind == ORDER_TYPE_BUY_STOP)
                {
                    orderType = "buy";
                    pendingType = "stop";
                }
                else if(orderKind == ORDER_TYPE_SELL_STOP)
                {
                    orderType = "sell";
                    pendingType = "stop";
                }
                else
                {
                    // 删除事件在类型不可识别时，若该ticket曾是挂单，仍按撤挂单处理，防漏撤
                    if(isDeleteEvent && IsTrackedPendingTicket(orderTicket))
                    {
                        if(eventTimeMs <= 0)
                            eventTimeMs = (long)TimeCurrent() * 1000;
                        SendTradeInfo("pending_cancel", "", symbol, volume, price, sl, tp, (long)orderTicket, comment, 0, eventTimeMs, "");
                        UntrackPendingTicket(orderTicket);
                        return;
                    }
                    // 非挂单类型（如市价单）不在挂单同步链路处理
                    return;
                }

                // 已识别为挂单类型，纳入本地跟踪，供删除事件兜底使用
                TrackPendingTicket(orderTicket);

                // 成交删除（FILLED）不下发 pending_cancel，避免和 open 事件重复
                if(isDeleteEvent && orderState == ORDER_STATE_FILLED)
                {
                    UntrackPendingTicket(orderTicket);
                    return;
                }

                string pendingAction = "pending_open";
                if(trans.type == TRADE_TRANSACTION_ORDER_UPDATE)
                {
                    // 关键修正：有些券商在手动撤单时先推 ORDER_UPDATE 且状态已是 CANCELED/EXPIRED，
                    // 若仍按 modify 处理会导致 cTrader 端“撤单变改挂单”。
                    if(orderState == ORDER_STATE_CANCELED || orderState == ORDER_STATE_EXPIRED || orderState == ORDER_STATE_REJECTED)
                        pendingAction = "pending_cancel";
                    else
                        pendingAction = "pending_modify";
                }
                else if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
                    pendingAction = "pending_cancel";

                if(eventTimeMs <= 0)
                    eventTimeMs = (long)TimeCurrent() * 1000;

                SendTradeInfo(pendingAction, orderType, symbol, volume, price, sl, tp,
                              (long)orderTicket, comment, 0, eventTimeMs, pendingType);
                if(pendingAction == "pending_cancel")
                    UntrackPendingTicket(orderTicket);
            }
        }
        return;
    }

    // 处理仓位修改事件
    if(trans.type == TRADE_TRANSACTION_POSITION)
    {
        ulong positionId = trans.position;
        if(positionId > 0 && PositionSelectByTicket(positionId))
        {
            string symbol = PositionGetString(POSITION_SYMBOL);
            double sl = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);
            long ticket = (long)positionId;
            
            // 获取订单类型
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            string orderType = "";
            if(posType == POSITION_TYPE_BUY)
                orderType = "buy";
            else if(posType == POSITION_TYPE_SELL)
                orderType = "sell";
            
            // 发送修改信息到服务器
            // modify 操作使用 positionId 作为 ticket
            long eventTimeMs = (long)PositionGetInteger(POSITION_TIME_UPDATE_MSC);
            SendTradeInfo("modify", orderType, symbol, 0, 0, sl, tp, ticket, "", 0, eventTimeMs, "");
        }
        return;
    }
    
    // 处理成交事件（开仓/平仓）
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
        return;
    
    // 获取成交单信息
    ulong dealTicket = trans.deal;
    if(dealTicket == 0)
        return;
    
    // 检查是否已经处理过这个成交单（去重）
    int dealCount = ArraySize(processedDeals);
    for(int i = 0; i < dealCount; i++)
    {
        if(processedDeals[i] == dealTicket)
        {
            // 已经处理过，跳过
            return;
        }
    }
    
    if(!HistoryDealSelect(dealTicket))
        return;
    
    // 获取成交单属性
    ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
    ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    
    // 只处理开仓和平仓：
    // DEAL_ENTRY_OUT_BY 在批量/对冲平仓场景也会出现，必须按 close 处理
    if(dealEntry != DEAL_ENTRY_IN && dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY)
    {
        Print("跳过非开平仓成交事件: deal=", dealTicket, " entry=", (int)dealEntry);
        return;
    }
    
    // 判断是开仓还是平仓
    string action = (dealEntry == DEAL_ENTRY_IN) ? "open" : "close";
    
    // 获取订单信息
    string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
    double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
    double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
    ulong positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
    
    // 获取订单类型
    string orderType = "";
    if(dealType == DEAL_TYPE_BUY)
        orderType = "buy";
    else if(dealType == DEAL_TYPE_SELL)
        orderType = "sell";
    
    // 如果是开仓，尝试获取止损和止盈
    double sl = 0, tp = 0;
    if(action == "open" && positionId > 0)
    {
        if(PositionSelectByTicket(positionId))
        {
            sl = PositionGetDouble(POSITION_SL);
            tp = PositionGetDouble(POSITION_TP);
        }
    }
    
    // 获取备注信息
    string comment = HistoryDealGetString(dealTicket, DEAL_COMMENT);
    
    // 记录已处理的成交单（添加到数组）
    ArrayResize(processedDeals, dealCount + 1);
    processedDeals[dealCount] = dealTicket;
    
    // 限制数组大小，防止内存溢出（保留最近1000条记录）
    if(ArraySize(processedDeals) > 1000)
    {
        // 移除最旧的记录（保留最新的1000条）
        int removeCount = ArraySize(processedDeals) - 1000;
        for(int i = 0; i < 1000; i++)
        {
            processedDeals[i] = processedDeals[i + removeCount];
        }
        ArrayResize(processedDeals, 1000);
    }
    
    // 发送交易信息到服务器
    // 注意：使用 positionId 而不是 dealTicket，因为开仓和平仓的 dealTicket 不同，但 positionId 相同
    long eventTimeMs = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
    SendTradeInfo(action, orderType, symbol, volume, price, sl, tp, (long)positionId, comment, (long)dealTicket, eventTimeMs, "");
    
    // 开仓或平仓后立即上报仓位信息（不等待定时器）
    SendPositionReport();
    lastPositionReportTime = TimeCurrent();  // 更新上报时间，避免定时器立即再次触发
}

//+------------------------------------------------------------------+
//| 发送交易信息到服务器                                             |
//+------------------------------------------------------------------+
void SendTradeInfo(string action, string orderType, string symbol, 
                   double volume, double price, double sl, double tp, 
                   long positionId, string comment, long dealTicket, long eventTimeMs, string pendingType = "")
{
    // 获取账户ID
    long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
    string sendSymbol = NormalizeSymbolBeforeSend(symbol);
    
    // 构建JSON数据
    string json = "{";
    json += "\"accountId\":" + IntegerToString(accountId) + ",";
    json += "\"action\":\"" + action + "\",";
    json += "\"orderType\":\"" + orderType + "\",";
    json += "\"symbol\":\"" + sendSymbol + "\",";
    json += "\"volume\":" + DoubleToString(volume, 2) + ",";
    json += "\"price\":" + DoubleToString(price, 5);
    
    if(sl > 0)
        json += ",\"sl\":" + DoubleToString(sl, 5);
    if(tp > 0)
        json += ",\"tp\":" + DoubleToString(tp, 5);
    // ticket 字段使用 positionId（仓位ID），因为开仓和平仓的 dealTicket 不同，但 positionId 相同
    if(positionId > 0)
        json += ",\"ticket\":" + IntegerToString(positionId);
    // 可选：添加 dealTicket 字段用于记录成交单号（调试用）
    if(dealTicket > 0)
        json += ",\"dealTicket\":" + IntegerToString(dealTicket);
    if(comment != "")
        json += ",\"comment\":\"" + comment + "\"";
    if(pendingType != "")
        json += ",\"pendingType\":\"" + pendingType + "\"";
    
    json += ",\"timestamp\":\"" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\"";
    if(eventTimeMs > 0)
        json += ",\"eventTimeMs\":" + IntegerToString(eventTimeMs);
    json += "}";
    
    // 转换为字符数组
    char data[];
    char result[];
    string result_headers;
    string headers = "Content-Type: application/json\r\n";
    
    int jsonLen = StringLen(json);
    ArrayResize(data, jsonLen);
    StringToCharArray(json, data, 0, jsonLen);
    
    // 发送POST请求（使用WebRequest的第二个版本，带自定义headers）
    int res = WebRequest("POST", TradeServerURL, headers, 5000, data, result, result_headers);
    
    if(res == -1)
    {
        int error = GetLastError();
        Print("发送交易信息失败 - 错误代码: ", error);
    }
    else
    {
        Print("交易信息已发送: ", action, " ", orderType, " ", symbol, " ", volume, "手 @ ", price);
    }
}

//+------------------------------------------------------------------+
//| 获取仓位信息并上报                                               |
//+------------------------------------------------------------------+
void SendPositionReport()
{
    // 获取账户ID
    long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
    
    // 解析要检查的交易标的列表（用逗号分隔）
    string symbols[];
    int symbolCount = StringSplit(CheckSymbols, ',', symbols);
    
    // 统计指定标的的仓位信息
    int totalPositions = 0;
    int buyPositions = 0;
    int sellPositions = 0;
    
    // 遍历所有仓位，只统计指定标的的仓位
    for(int i = 0; i < PositionsTotal(); i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0)
        {
            string posSymbol = NormalizeSymbolBeforeSend(PositionGetString(POSITION_SYMBOL));
            
            // 检查是否在要检查的标的列表中
            bool shouldCheck = false;
            if(symbolCount == 0)
            {
                // 如果没有配置标的，默认检查所有（兼容旧版本）
                shouldCheck = true;
            }
            else
            {
                for(int j = 0; j < symbolCount; j++)
                {
                    // 修剪字符串两端的空格
                    string trimmedSymbol = symbols[j];
                    StringTrimRight(trimmedSymbol);
                    StringTrimLeft(trimmedSymbol);
                    trimmedSymbol = NormalizeSymbolBeforeSend(trimmedSymbol);
                    
                    if(trimmedSymbol == posSymbol)
                    {
                        shouldCheck = true;
                        break;
                    }
                }
            }
            
            if(shouldCheck)
            {
                totalPositions++;
                ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                if(posType == POSITION_TYPE_BUY)
                    buyPositions++;
                else if(posType == POSITION_TYPE_SELL)
                    sellPositions++;
            }
        }
    }
    
    // 构建JSON数据
    string json = "{";
    json += "\"accountId\":" + IntegerToString(accountId) + ",";
    json += "\"total\":" + IntegerToString(totalPositions) + ",";
    json += "\"buy\":" + IntegerToString(buyPositions) + ",";
    json += "\"sell\":" + IntegerToString(sellPositions);
    json += "}";
    
    // 转换为字符数组
    char data[];
    char result[];
    string result_headers;
    string headers = "Content-Type: application/json\r\n";
    
    int jsonLen = StringLen(json);
    ArrayResize(data, jsonLen);
    StringToCharArray(json, data, 0, jsonLen);
    
    // 发送POST请求
    int res = WebRequest("POST", PositionReportURL, headers, 5000, data, result, result_headers);
    
    if(res == -1)
    {
        int error = GetLastError();
        Print("仓位上报失败 - 错误代码: ", error);
    }
    else
    {
        Print("仓位信息已上报: 总=", totalPositions, " 多=", buyPositions, " 空=", sellPositions);
    }
}

//+------------------------------------------------------------------+
//| 发送前统一品种：仅将 XAUUSDm 归一为 XAUUSD                        |
//+------------------------------------------------------------------+
string NormalizeSymbolBeforeSend(string symbol)
{
    string s = symbol;
    StringTrimLeft(s);
    StringTrimRight(s);
    string upper = s;
    StringToUpper(upper);

    if(upper == "XAUUSDM" || upper == "XAUUSD-ECN")
        return "XAUUSD";

    return s;
}