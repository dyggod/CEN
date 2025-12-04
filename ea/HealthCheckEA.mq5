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
input int      RequestInterval = 1;                          // 请求间隔（秒）

//--- 全局变量
int requestCount = 0;  // 请求计数
int successCount = 0;  // 成功计数
int failCount = 0;     // 失败计数

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    EventSetTimer(RequestInterval);
    Print("Health Check EA 已启动 - ", ServerURL);
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
    // 只处理成交事件
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
        return;
    
    // 获取成交单信息
    ulong dealTicket = trans.deal;
    if(dealTicket == 0)
        return;
    
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
    
    // 发送交易信息到服务器
    SendTradeInfo(action, orderType, symbol, volume, price, sl, tp, (long)dealTicket, comment);
}

//+------------------------------------------------------------------+
//| 发送交易信息到服务器                                             |
//+------------------------------------------------------------------+
void SendTradeInfo(string action, string orderType, string symbol, 
                   double volume, double price, double sl, double tp, 
                   long ticket, string comment)
{
    // 构建JSON数据
    string json = "{";
    json += "\"action\":\"" + action + "\",";
    json += "\"orderType\":\"" + orderType + "\",";
    json += "\"symbol\":\"" + symbol + "\",";
    json += "\"volume\":" + DoubleToString(volume, 2) + ",";
    json += "\"price\":" + DoubleToString(price, 5);
    
    if(sl > 0)
        json += ",\"sl\":" + DoubleToString(sl, 5);
    if(tp > 0)
        json += ",\"tp\":" + DoubleToString(tp, 5);
    if(ticket > 0)
        json += ",\"ticket\":" + IntegerToString(ticket);
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