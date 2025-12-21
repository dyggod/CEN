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
input int      PositionReportInterval = 60;                  // 仓位上报间隔（秒，默认60秒=1分钟）
input string   CheckSymbols = "XAUUSD";                     // 仓位检查的交易标的（多个用逗号分隔，如"XAUUSD,EURUSD"）

//--- 全局变量
int requestCount = 0;  // 请求计数
int successCount = 0;  // 成功计数
int failCount = 0;     // 失败计数
ulong processedDeals[];  // 已处理的成交单列表（用于去重）
datetime lastPositionReportTime = 0;  // 上次仓位上报时间

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
            SendTradeInfo("modify", orderType, symbol, 0, 0, sl, tp, ticket, "", 0);
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
    
    // 只处理开仓和平仓
    if(dealEntry != DEAL_ENTRY_IN && dealEntry != DEAL_ENTRY_OUT)
        return;
    
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
    SendTradeInfo(action, orderType, symbol, volume, price, sl, tp, (long)positionId, comment, (long)dealTicket);
    
    // 开仓或平仓后立即上报仓位信息（不等待定时器）
    SendPositionReport();
    lastPositionReportTime = TimeCurrent();  // 更新上报时间，避免定时器立即再次触发
}

//+------------------------------------------------------------------+
//| 发送交易信息到服务器                                             |
//+------------------------------------------------------------------+
void SendTradeInfo(string action, string orderType, string symbol, 
                   double volume, double price, double sl, double tp, 
                   long positionId, string comment, long dealTicket)
{
    // 获取账户ID
    long accountId = AccountInfoInteger(ACCOUNT_LOGIN);
    
    // 构建JSON数据
    string json = "{";
    json += "\"accountId\":" + IntegerToString(accountId) + ",";
    json += "\"action\":\"" + action + "\",";
    json += "\"orderType\":\"" + orderType + "\",";
    json += "\"symbol\":\"" + symbol + "\",";
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
    
    json += ",\"timestamp\":\"" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\"";
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
            string posSymbol = PositionGetString(POSITION_SYMBOL);
            
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