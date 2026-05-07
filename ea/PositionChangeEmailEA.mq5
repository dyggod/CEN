//+------------------------------------------------------------------+
//|                                       PositionChangeEmailEA.mq5  |
//|  监听当前账户持仓变化并通过 MT5 SendMail 推送邮件                 |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Push position changes to email via SendMail"

input int      PollIntervalSeconds = 1;         // 轮询间隔（秒）
input string   SubjectPrefix = "[MT5 Position]";// 邮件标题前缀
input bool     SendStartupSnapshot = false;     // 启动时是否发送当前持仓快照
input bool     IncludeUnchangedHeartbeat = false; // 是否发送无变化心跳邮件（调试用）
input int      MinSendIntervalSeconds = 5;      // 最小发信间隔（秒），防止SMTP瞬时拒绝
input int      RetryIntervalSeconds = 10;       // 发送失败后的重试间隔（秒）

struct PositionState
{
   ulong   ticket;
   string  symbol;
   long    type;
   double  volume;
   double  openPrice;
   double  sl;
   double  tp;
   long    updateMsc;
};

PositionState g_knownPositions[];
bool   g_dirty = true;
datetime g_lastSendAt = 0;
string g_pendingTitle = "";
string g_pendingContent = "";
datetime g_nextRetryAt = 0;

string DealReasonText(long reason)
{
   if(reason == DEAL_REASON_SL)       return "StopLoss";
   if(reason == DEAL_REASON_TP)       return "TakeProfit";
   if(reason == DEAL_REASON_CLIENT)   return "Manual(Client)";
   if(reason == DEAL_REASON_EXPERT)   return "Expert";
   if(reason == DEAL_REASON_SO)       return "StopOut";
   if(reason == DEAL_REASON_VMARGIN)  return "VariationMargin";
   if(reason == DEAL_REASON_ROLLOVER) return "Rollover";
   return "Other";
}

string BuildMarketPriceLine(string symbol)
{
   double bid = 0.0, ask = 0.0;
   bool okBid = SymbolInfoDouble(symbol, SYMBOL_BID, bid);
   bool okAsk = SymbolInfoDouble(symbol, SYMBOL_ASK, ask);
   if(okBid && okAsk)
      return StringFormat("market=%s bid=%.5f ask=%.5f", symbol, bid, ask);
   return StringFormat("market=%s bid/ask unavailable", symbol);
}

bool GetLatestCloseDealInfo(ulong positionTicket, long &dealReason, double &dealPrice, long &dealTimeMsc)
{
   dealReason = -1;
   dealPrice = 0.0;
   dealTimeMsc = 0;

   datetime now = TimeCurrent();
   if(!HistorySelect(now - 7 * 24 * 60 * 60, now + 60))
      return false;

   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong dealTk = HistoryDealGetTicket(i);
      if(dealTk == 0) continue;

      long posId = HistoryDealGetInteger(dealTk, DEAL_POSITION_ID);
      if((ulong)posId != positionTicket) continue;

      long entry = HistoryDealGetInteger(dealTk, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

      dealReason = HistoryDealGetInteger(dealTk, DEAL_REASON);
      dealPrice = HistoryDealGetDouble(dealTk, DEAL_PRICE);
      dealTimeMsc = HistoryDealGetInteger(dealTk, DEAL_TIME_MSC);
      return true;
   }
   return false;
}

string PositionTypeText(long t)
{
   if(t == POSITION_TYPE_BUY)  return "BUY";
   if(t == POSITION_TYPE_SELL) return "SELL";
   return "UNKNOWN";
}

bool DoubleChanged(double a, double b, double eps = 0.0000001)
{
   return MathAbs(a - b) > eps;
}

int FindByTicket(PositionState &arr[], ulong ticket)
{
   int n = ArraySize(arr);
   for(int i = 0; i < n; i++)
   {
      if(arr[i].ticket == ticket)
         return i;
   }
   return -1;
}

void BuildCurrentSnapshot(PositionState &outArr[])
{
   ArrayResize(outArr, 0);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;

      PositionState p;
      p.ticket    = tk;
      p.symbol    = PositionGetString(POSITION_SYMBOL);
      p.type      = PositionGetInteger(POSITION_TYPE);
      p.volume    = PositionGetDouble(POSITION_VOLUME);
      p.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      p.sl        = PositionGetDouble(POSITION_SL);
      p.tp        = PositionGetDouble(POSITION_TP);
      p.updateMsc = PositionGetInteger(POSITION_TIME_UPDATE_MSC);

      int n = ArraySize(outArr);
      ArrayResize(outArr, n + 1);
      outArr[n] = p;
   }
}

string BuildPositionLine(PositionState &p)
{
   return StringFormat("ticket=%I64u | %s %s | vol=%.2f | open=%.5f | sl=%.5f | tp=%.5f | updateMsc=%I64d",
                       p.ticket,
                       p.symbol,
                       PositionTypeText(p.type),
                       p.volume,
                       p.openPrice,
                       p.sl,
                       p.tp,
                       p.updateMsc);
}

bool SendPositionMail(string title, string content)
{
   long acc = AccountInfoInteger(ACCOUNT_LOGIN);
   string server = AccountInfoString(ACCOUNT_SERVER);
   string body = StringFormat("account=%I64d\nserver=%s\ntime=%s\n\n%s",
                              acc,
                              server,
                              TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                              content);
   bool ok = SendMail(SubjectPrefix + " " + title, body);
   if(!ok)
   {
      Print("SendMail failed, error=", GetLastError(), ", title=", title);
      return false;
   }
   g_lastSendAt = TimeCurrent();
   return true;
}

void QueuePendingMail(string title, string content)
{
   g_pendingTitle = title;
   g_pendingContent = content;
   g_nextRetryAt = TimeCurrent() + MathMax(1, RetryIntervalSeconds);
}

void FlushPendingMailIfNeeded()
{
   if(g_pendingTitle == "" || g_pendingContent == "")
      return;
   if(TimeCurrent() < g_nextRetryAt)
      return;
   if(!SendPositionMail(g_pendingTitle, g_pendingContent))
   {
      g_nextRetryAt = TimeCurrent() + MathMax(1, RetryIntervalSeconds);
      return;
   }
   Print("Pending email sent successfully: ", g_pendingTitle);
   g_pendingTitle = "";
   g_pendingContent = "";
   g_nextRetryAt = 0;
}

void SendOrQueueMail(string title, string content)
{
   // 如果有待重试邮件，优先保留，不覆盖
   if(g_pendingTitle != "" || g_pendingContent != "")
   {
      Print("Mail queued because previous pending mail exists. title=", title);
      return;
   }

   if((TimeCurrent() - g_lastSendAt) < MathMax(1, MinSendIntervalSeconds))
   {
      Print("Mail queued by rate limit. title=", title);
      QueuePendingMail(title, content);
      return;
   }

   if(!SendPositionMail(title, content))
   {
      QueuePendingMail(title, content);
   }
}

void CheckAndNotify()
{
   PositionState current[];
   BuildCurrentSnapshot(current);

   bool changed = false;
   string report = "";

   // 新增/修改
   int curN = ArraySize(current);
   for(int i = 0; i < curN; i++)
   {
      int oldIdx = FindByTicket(g_knownPositions, current[i].ticket);
      if(oldIdx < 0)
      {
         changed = true;
         report += "[OPEN]\n" + BuildPositionLine(current[i]) + "\n\n";
         continue;
      }

      PositionState oldP = g_knownPositions[oldIdx];
      bool updated = false;
      string diff = "";

      if(oldP.type != current[i].type)
      {
         updated = true;
         diff += StringFormat("type: %s -> %s\n", PositionTypeText(oldP.type), PositionTypeText(current[i].type));
      }
      if(DoubleChanged(oldP.volume, current[i].volume))
      {
         updated = true;
         diff += StringFormat("volume: %.2f -> %.2f\n", oldP.volume, current[i].volume);
      }
      if(DoubleChanged(oldP.openPrice, current[i].openPrice))
      {
         updated = true;
         diff += StringFormat("openPrice: %.5f -> %.5f\n", oldP.openPrice, current[i].openPrice);
      }
      if(DoubleChanged(oldP.sl, current[i].sl))
      {
         updated = true;
         diff += StringFormat("sl: %.5f -> %.5f\n", oldP.sl, current[i].sl);
      }
      if(DoubleChanged(oldP.tp, current[i].tp))
      {
         updated = true;
         diff += StringFormat("tp: %.5f -> %.5f\n", oldP.tp, current[i].tp);
      }

      if(updated)
      {
         changed = true;
         report += "[MODIFY]\n";
         report += BuildPositionLine(current[i]) + "\n";
         report += diff + "\n";
      }
   }

   // 平仓
   int oldN = ArraySize(g_knownPositions);
   for(int j = 0; j < oldN; j++)
   {
      int curIdx = FindByTicket(current, g_knownPositions[j].ticket);
      if(curIdx < 0)
      {
         changed = true;
         long reason = -1;
         double closePrice = 0.0;
         long closeTimeMsc = 0;
         bool gotCloseDeal = GetLatestCloseDealInfo(g_knownPositions[j].ticket, reason, closePrice, closeTimeMsc);

         report += "[CLOSE]\n" + BuildPositionLine(g_knownPositions[j]) + "\n";
         if(gotCloseDeal)
            report += StringFormat("closeReason=%s | closePrice=%.5f | closeTimeMsc=%I64d\n",
                                   DealReasonText(reason), closePrice, closeTimeMsc);
         else
            report += "closeReason=Unknown | close deal not found in recent history\n";
         report += BuildMarketPriceLine(g_knownPositions[j].symbol) + "\n\n";
      }
   }

   if(changed)
   {
      SendOrQueueMail("Position Changed", report);
      Print("Position change detected, email attempted.");
   }
   else if(IncludeUnchangedHeartbeat)
   {
      SendOrQueueMail("Heartbeat", "No position changes.");
   }

   // 覆盖旧快照
   ArrayResize(g_knownPositions, curN);
   for(int k = 0; k < curN; k++)
      g_knownPositions[k] = current[k];
}

int OnInit()
{
   EventSetTimer(MathMax(1, PollIntervalSeconds));
   BuildCurrentSnapshot(g_knownPositions);
   Print("PositionChangeEmailEA started.");
   Print("account=", AccountInfoInteger(ACCOUNT_LOGIN),
         ", server=", AccountInfoString(ACCOUNT_SERVER),
         ", poll=", PollIntervalSeconds, "s");

   if(SendStartupSnapshot)
   {
      string msg = "Startup snapshot:\n";
      int n = ArraySize(g_knownPositions);
      if(n == 0)
         msg += "(no positions)";
      for(int i = 0; i < n; i++)
         msg += BuildPositionLine(g_knownPositions[i]) + "\n";
      SendOrQueueMail("Startup Snapshot", msg);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("PositionChangeEmailEA stopped. reason=", reason);
}

void OnTimer()
{
   FlushPendingMailIfNeeded();
   if(g_dirty || IncludeUnchangedHeartbeat)
   {
      CheckAndNotify();
      g_dirty = false;
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // 交易事件只做置脏，避免与OnTimer并发连发邮件触发SMTP拒绝
   g_dirty = true;
}

