//+------------------------------------------------------------------+
//|                                       PositionChangeEmailEA.mq5  |
//|  监听当前账户持仓变化并通过 MT5 SendMail 推送邮件                 |
//|  可选：市价接近限价挂单时推送邮件                                   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.02"
#property description "持仓/限价接近提醒邮件（正文中文），通过 SendMail 发送"

input int      PollIntervalSeconds = 1;         // 轮询间隔（秒）
input string   SubjectPrefix = "[MT5 Position]";// 邮件标题前缀
input bool     SendStartupSnapshot = false;     // 启动时是否发送当前持仓快照
input bool     IncludeUnchangedHeartbeat = false; // 是否发送无变化心跳邮件（调试用）
input int      MinSendIntervalSeconds = 5;      // 最小发信间隔（秒），防止SMTP瞬时拒绝
input int      RetryIntervalSeconds = 10;       // 发送失败后的重试间隔（秒）

input bool     EnableLimitProximityAlert = true;   // 是否启用「市价接近限价单」邮件
input bool     LimitAlertCurrentSymbolOnly = true; // 仅监控当前图表品种（否则监控账户内全部挂单）
input double   LimitProximityMaxPriceDiff = 2.0;   // 市价与限价绝对价差阈值（如 XAUUSD 可设 2.0）

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

struct LimitProximityTrack
{
   ulong  ticket;
   bool   alerted; // 在「接近」区间内已发过提醒；价差扩大离开区间后清零，可再次提醒
};

LimitProximityTrack g_limitProximityTrack[];

string DealReasonText(long reason)
{
   if(reason == DEAL_REASON_SL)       return "止损";
   if(reason == DEAL_REASON_TP)       return "止盈";
   if(reason == DEAL_REASON_CLIENT)   return "手动(客户端)";
   if(reason == DEAL_REASON_EXPERT)   return "EA/脚本";
   if(reason == DEAL_REASON_SO)       return "爆仓";
   if(reason == DEAL_REASON_VMARGIN)  return "可变保证金";
   if(reason == DEAL_REASON_ROLLOVER) return "隔夜展期";
   return "其它";
}

string BuildMarketPriceLine(string symbol)
{
   double bid = 0.0, ask = 0.0;
   int dig = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(dig < 1) dig = (int)_Digits;
   bool okBid = SymbolInfoDouble(symbol, SYMBOL_BID, bid);
   bool okAsk = SymbolInfoDouble(symbol, SYMBOL_ASK, ask);
   if(okBid && okAsk)
      return StringFormat("品种 %s 即时报价：买价(Bid)=%.*f | 卖价(Ask)=%.*f",
                         symbol, dig, bid, dig, ask);
   return StringFormat("品种 %s 即时报价不可用", symbol);
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
   if(t == POSITION_TYPE_BUY)  return "买入";
   if(t == POSITION_TYPE_SELL) return "卖出";
   return "未知";
}

string PendingLimitTypeText(long t)
{
   if(t == ORDER_TYPE_BUY_LIMIT)  return "买入限价";
   if(t == ORDER_TYPE_SELL_LIMIT) return "卖出限价";
   return "其它";
}

int FindLimitTrackIndex(ulong ticket)
{
   int n = ArraySize(g_limitProximityTrack);
   for(int i = 0; i < n; i++)
   {
      if(g_limitProximityTrack[i].ticket == ticket)
         return i;
   }
   return -1;
}

void RemoveLimitTrackAt(int idx)
{
   int n = ArraySize(g_limitProximityTrack);
   if(idx < 0 || idx >= n) return;
   for(int j = idx; j < n - 1; j++)
      g_limitProximityTrack[j] = g_limitProximityTrack[j + 1];
   ArrayResize(g_limitProximityTrack, n - 1);
}

void PruneLimitProximityTrack()
{
   for(int j = ArraySize(g_limitProximityTrack) - 1; j >= 0; j--)
   {
      ulong tk = g_limitProximityTrack[j].ticket;
      if(!OrderSelect(tk))
      {
         RemoveLimitTrackAt(j);
         continue;
      }
      long typ = OrderGetInteger(ORDER_TYPE);
      if(typ != ORDER_TYPE_BUY_LIMIT && typ != ORDER_TYPE_SELL_LIMIT)
         RemoveLimitTrackAt(j);
   }
}

void CheckLimitProximityAndNotify()
{
   if(!EnableLimitProximityAlert)
      return;

   PruneLimitProximityTrack();

   const double maxDiff = LimitProximityMaxPriceDiff;
   if(maxDiff < 0.0)
      return;

   string report = "";
   int total = OrdersTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ot = OrderGetTicket(i);
      if(ot == 0) continue;
      if(!OrderSelect(ot)) continue;

      string sym = OrderGetString(ORDER_SYMBOL);
      if(LimitAlertCurrentSymbolOnly && sym != _Symbol)
         continue;

      long typ = OrderGetInteger(ORDER_TYPE);
      if(typ != ORDER_TYPE_BUY_LIMIT && typ != ORDER_TYPE_SELL_LIMIT)
         continue;

      double limitPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double bid = 0.0, ask = 0.0;
      if(!SymbolInfoDouble(sym, SYMBOL_BID, bid)) continue;
      if(!SymbolInfoDouble(sym, SYMBOL_ASK, ask)) continue;

      double refPx = 0.0;
      if(typ == ORDER_TYPE_BUY_LIMIT)
         refPx = bid;
      else
         refPx = ask;

      double dist = MathAbs(refPx - limitPrice);

      int trIdx = FindLimitTrackIndex(ot);
      if(dist > maxDiff)
      {
         if(trIdx >= 0)
            g_limitProximityTrack[trIdx].alerted = false;
         continue;
      }

      if(trIdx < 0)
      {
         int n = ArraySize(g_limitProximityTrack);
         ArrayResize(g_limitProximityTrack, n + 1);
         g_limitProximityTrack[n].ticket = ot;
         g_limitProximityTrack[n].alerted = false;
         trIdx = n;
      }

      if(g_limitProximityTrack[trIdx].alerted)
         continue;

      g_limitProximityTrack[trIdx].alerted = true;

      int dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double vol = OrderGetDouble(ORDER_VOLUME_INITIAL);
      string refLabel = (typ == ORDER_TYPE_BUY_LIMIT ? "买价(Bid)" : "卖价(Ask)");
      string line = StringFormat(
         "【市价接近限价挂单】挂单号=%I64u | 品种=%s | 类型=%s | 手数=%.2f\n"
         "限价=%.*f | 比较用市价=%.*f (%s) | |价差|=%.*f （阈值≤%.*f）\n",
         ot,
         sym,
         PendingLimitTypeText(typ),
         vol,
         dig, limitPrice,
         dig, refPx,
         refLabel,
         dig, dist,
         dig, maxDiff);
      report += line;
      report += BuildMarketPriceLine(sym) + "\n\n";
   }

   if(report != "")
      SendOrQueueMail("限价单接近市价", report);
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
   int dig = (int)SymbolInfoInteger(p.symbol, SYMBOL_DIGITS);
   if(dig < 1) dig = 5;
   return StringFormat(
      "持仓单号=%I64u | 品种=%s | 方向=%s | 手数=%.2f | 开仓价=%.*f | 止损=%.*f | 止盈=%.*f | 最近更新(毫秒)=%I64d",
      p.ticket,
      p.symbol,
      PositionTypeText(p.type),
      p.volume,
      dig, p.openPrice,
      dig, p.sl,
      dig, p.tp,
      p.updateMsc);
}

bool SendPositionMail(string title, string content)
{
   long acc = AccountInfoInteger(ACCOUNT_LOGIN);
   string server = AccountInfoString(ACCOUNT_SERVER);
   string body = StringFormat("账户=%I64d\n服务器=%s\n时间=%s\n\n%s",
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
         report += "【新开仓】\n" + BuildPositionLine(current[i]) + "\n\n";
         continue;
      }

      PositionState oldP = g_knownPositions[oldIdx];
      bool updated = false;
      string diff = "";

      if(oldP.type != current[i].type)
      {
         updated = true;
         diff += StringFormat("方向: %s -> %s\n", PositionTypeText(oldP.type), PositionTypeText(current[i].type));
      }
      if(DoubleChanged(oldP.volume, current[i].volume))
      {
         updated = true;
         diff += StringFormat("手数: %.2f -> %.2f\n", oldP.volume, current[i].volume);
      }
      int pdig = (int)SymbolInfoInteger(current[i].symbol, SYMBOL_DIGITS);
      if(pdig < 1) pdig = 5;
      if(DoubleChanged(oldP.openPrice, current[i].openPrice))
      {
         updated = true;
         diff += StringFormat("开仓价: %.*f -> %.*f\n", pdig, oldP.openPrice, pdig, current[i].openPrice);
      }
      if(DoubleChanged(oldP.sl, current[i].sl))
      {
         updated = true;
         diff += StringFormat("止损: %.*f -> %.*f\n", pdig, oldP.sl, pdig, current[i].sl);
      }
      if(DoubleChanged(oldP.tp, current[i].tp))
      {
         updated = true;
         diff += StringFormat("止盈: %.*f -> %.*f\n", pdig, oldP.tp, pdig, current[i].tp);
      }

      if(updated)
      {
         changed = true;
         report += "【持仓修改】\n";
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

         report += "【已平仓】\n" + BuildPositionLine(g_knownPositions[j]) + "\n";
         string cdigSym = g_knownPositions[j].symbol;
         int cdig = (int)SymbolInfoInteger(cdigSym, SYMBOL_DIGITS);
         if(cdig < 1) cdig = 5;
         if(gotCloseDeal)
            report += StringFormat("平仓原因=%s | 平仓价=%.*f | 平仓时间戳(毫秒)=%I64d\n",
                                   DealReasonText(reason), cdig, closePrice, closeTimeMsc);
         else
            report += "平仓原因=未知（近期历史中未匹配到平仓成交）\n";
         report += BuildMarketPriceLine(g_knownPositions[j].symbol) + "\n\n";
      }
   }

   if(changed)
   {
      SendOrQueueMail("持仓变化", report);
      Print("Position change detected, email attempted.");
   }
   else if(IncludeUnchangedHeartbeat)
   {
      SendOrQueueMail("心跳", "暂无持仓变化。");
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
      string msg = "【启动快照】当前持仓一览：\n";
      int n = ArraySize(g_knownPositions);
      if(n == 0)
         msg += "当前无持仓。\n";
      for(int i = 0; i < n; i++)
         msg += BuildPositionLine(g_knownPositions[i]) + "\n";
      SendOrQueueMail("启动持仓快照", msg);
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
   CheckLimitProximityAndNotify();
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

