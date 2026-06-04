//+------------------------------------------------------------------+
//|                                       PositionChangeEmailEA.mq5  |
//|  监听当前账户持仓变化并通过 MT5 SendMail 推送邮件                 |
//|  可选：市价接近限价挂单时推送邮件                                   |
//|  可选：比尔·威廉姆斯鳄鱼(Alligator)睡觉/醒来/进食形态邮件           |
//+------------------------------------------------------------------+
#property strict
#property version   "1.05"
#property description "持仓/限价接近/鳄鱼形态提醒邮件（正文中文），通过 SendMail 发送"

input int      PollIntervalSeconds = 1;         // 轮询间隔（秒）
input string   SubjectPrefix = "[MT5 Position]";// 邮件标题前缀
input bool     SendStartupSnapshot = false;     // 启动时是否发送当前持仓快照
input bool     IncludeUnchangedHeartbeat = false; // 是否发送无变化心跳邮件（调试用）
input int      MinSendIntervalSeconds = 5;      // 最小发信间隔（秒），防止SMTP瞬时拒绝
input int      RetryIntervalSeconds = 10;       // 发送失败后的重试间隔（秒）

input bool     EnableLimitProximityAlert = true;   // 是否启用「市价接近限价单」邮件
input bool     LimitAlertCurrentSymbolOnly = true; // 仅监控当前图表品种（否则监控账户内全部挂单）
input double   LimitProximityMaxPriceDiff = 2.0;   // 市价与限价绝对价差阈值（如 XAUUSD 可设 2.0）
input int      LimitProximityEmailCooldownSeconds = 60; // 限价接近邮件最小间隔（秒），不影响持仓变化邮件

input group    "=== 鳄鱼(Alligator)形态邮件 ==="
input bool     EnableAlligatorSleepAlert = false;   // 进入「睡觉」形态时发邮件
input bool     EnableAlligatorAwakenAlert = false;  // 进入「醒来」形态时发邮件
input bool     EnableAlligatorEatAlert = false;     // 进入「进食」形态时发邮件
input int      AlligatorJawPeriod = 13;             // 下颚周期
input int      AlligatorJawShift = 8;               // 下颚位移
input int      AlligatorTeethPeriod = 8;            // 牙齿周期
input int      AlligatorTeethShift = 5;             // 牙齿位移
input int      AlligatorLipsPeriod = 5;             // 嘴唇周期
input int      AlligatorLipsShift = 3;              // 嘴唇位移
input int      AlligatorAtrPeriod = 14;             // 聚拢/张口判定用 ATR 周期
input double   AlligatorSleepSpreadAtrMult = 0.50;  // 睡觉：三线间距 < 该值 × ATR
input double   AlligatorEatSpreadAtrMult = 0.35;    // 进食：三线间距 ≥ 该值 × ATR 且张口有序
input bool     AlligatorDebugLog = false;           // 每根新K线在「专家」日志打印形态（测试用）
input bool     AlligatorSendTestMailOnInit = false; // 启动时发一封鳄鱼测试邮件（验证 SMTP）
input bool     AlligatorTestMailEveryNewBar = false;// 每根新K线发当前形态邮件（仅测试，勿长期开启）

enum AlligatorPhase
{
   ALG_UNKNOWN = 0,
   ALG_SLEEP   = 1,
   ALG_AWAKEN  = 2,
   ALG_EAT_BULL = 3,
   ALG_EAT_BEAR = 4
};

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
datetime g_lastLimitProximityEmailAt = 0; // 上次成功发送「限价接近」邮件的时间

struct LimitProximityTrack
{
   ulong  ticket;
   bool   alerted; // 在「接近」区间内已发过提醒；价差扩大离开区间后清零，可再次提醒
};

LimitProximityTrack g_limitProximityTrack[];

int        g_alligatorHandle = INVALID_HANDLE;
int        g_alligatorAtrHandle = INVALID_HANDLE;
datetime   g_alligatorLastBar0Time = 0;           // 已处理过的当前 K 线开盘时间
datetime   g_alligatorEmailedClosedBarTime = 0;   // 已发过鳄鱼邮件的已收盘 K 线时间

bool AnyAlligatorAlertEnabled()
{
   return EnableAlligatorSleepAlert || EnableAlligatorAwakenAlert || EnableAlligatorEatAlert;
}

bool AlligatorLineValid(double v)
{
   if(v == EMPTY_VALUE || v == 0.0 || !MathIsValidNumber(v))
      return false;
   return true;
}

bool GetAlligatorLines(int shift, double &jaw, double &teeth, double &lips)
{
   jaw = 0.0;
   teeth = 0.0;
   lips = 0.0;
   if(g_alligatorHandle == INVALID_HANDLE)
      return false;

   double bJ[], bT[], bL[];
   ArraySetAsSeries(bJ, true);
   ArraySetAsSeries(bT, true);
   ArraySetAsSeries(bL, true);

   if(CopyBuffer(g_alligatorHandle, 0, shift, 1, bJ) != 1) return false;
   if(CopyBuffer(g_alligatorHandle, 1, shift, 1, bT) != 1) return false;
   if(CopyBuffer(g_alligatorHandle, 2, shift, 1, bL) != 1) return false;

   jaw = bJ[0];
   teeth = bT[0];
   lips = bL[0];
   return AlligatorLineValid(jaw) && AlligatorLineValid(teeth) && AlligatorLineValid(lips);
}

bool GetAtrAt(int shift, double &atr)
{
   atr = 0.0;
   if(g_alligatorAtrHandle == INVALID_HANDLE)
      return false;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(g_alligatorAtrHandle, 0, shift, 1, b) != 1)
      return false;
   if(!MathIsValidNumber(b[0]) || b[0] <= 0.0)
      return false;
   atr = b[0];
   return true;
}

bool AlligatorIndicatorsReady()
{
   if(g_alligatorHandle == INVALID_HANDLE || g_alligatorAtrHandle == INVALID_HANDLE)
      return false;
   int need = MathMax(AlligatorJawPeriod + AlligatorJawShift,
              MathMax(AlligatorTeethPeriod + AlligatorTeethShift,
                      AlligatorLipsPeriod + AlligatorLipsShift));
   need = MathMax(need, AlligatorAtrPeriod) + 10;
   if(BarsCalculated(g_alligatorHandle) < need)
      return false;
   if(BarsCalculated(g_alligatorAtrHandle) < need)
      return false;
   return true;
}

void LogAlligatorDiag(const string msg)
{
   if(AlligatorDebugLog)
      Print("[Alligator] ", msg);
}

double AlligatorSpread(double jaw, double teeth, double lips)
{
   double hi = MathMax(jaw, MathMax(teeth, lips));
   double lo = MathMin(jaw, MathMin(teeth, lips));
   return hi - lo;
}

bool AlligatorBullMouth(double jaw, double teeth, double lips)
{
   return (lips > teeth && teeth > jaw);
}

bool AlligatorBearMouth(double jaw, double teeth, double lips)
{
   return (lips < teeth && teeth < jaw);
}

AlligatorPhase ClassifyAlligatorPhase(int shift)
{
   double jaw, teeth, lips;
   if(!GetAlligatorLines(shift, jaw, teeth, lips))
      return ALG_UNKNOWN;

   double atr = 0.0;
   if(!GetAtrAt(shift, atr) || atr <= 0.0)
      return ALG_UNKNOWN;

   double spread = AlligatorSpread(jaw, teeth, lips);
   double sleepThr = AlligatorSleepSpreadAtrMult * atr;
   double eatThr = AlligatorEatSpreadAtrMult * atr;

   if(spread <= sleepThr)
      return ALG_SLEEP;

   if(spread >= eatThr)
   {
      if(AlligatorBullMouth(jaw, teeth, lips))
         return ALG_EAT_BULL;
      if(AlligatorBearMouth(jaw, teeth, lips))
         return ALG_EAT_BEAR;
   }

   return ALG_AWAKEN;
}

string AlligatorPhaseText(AlligatorPhase p)
{
   if(p == ALG_SLEEP) return "睡觉";
   if(p == ALG_AWAKEN) return "醒来";
   if(p == ALG_EAT_BULL) return "进食(多头张口：唇>齿>颚)";
   if(p == ALG_EAT_BEAR) return "进食(空头张口：唇<齿<颚)";
   return "未知";
}

string BuildAlligatorMailBody(AlligatorPhase phase, int shift)
{
   double jaw, teeth, lips;
   GetAlligatorLines(shift, jaw, teeth, lips);
   double atr = 0.0;
   GetAtrAt(shift, atr);
   double spread = AlligatorSpread(jaw, teeth, lips);

   int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(dig < 1) dig = (int)_Digits;

   string tf = EnumToString((ENUM_TIMEFRAMES)_Period);
   datetime barTime = iTime(_Symbol, _Period, shift);

   return StringFormat(
      "【鳄鱼 Alligator 形态】%s\n"
      "品种=%s | 周期=%s | K线时间=%s\n"
      "下颚=%.*f | 牙齿=%.*f | 嘴唇=%.*f\n"
      "三线间距=%.*f | ATR(%d)=%.*f | 睡觉阈值(间距)=%.*f | 进食阈值(间距)=%.*f\n\n"
      "%s",
      AlligatorPhaseText(phase),
      _Symbol,
      tf,
      TimeToString(barTime, TIME_DATE|TIME_MINUTES),
      dig, jaw, dig, teeth, dig, lips,
      dig, spread,
      AlligatorAtrPeriod, dig, atr,
      dig, AlligatorSleepSpreadAtrMult * atr,
      dig, AlligatorEatSpreadAtrMult * atr,
      BuildMarketPriceLine(_Symbol));
}

bool IsEatingPhase(AlligatorPhase p)
{
   return (p == ALG_EAT_BULL || p == ALG_EAT_BEAR);
}

bool AlligatorAlertEnabledForPhase(AlligatorPhase p)
{
   if(p == ALG_SLEEP && EnableAlligatorSleepAlert) return true;
   if(p == ALG_AWAKEN && EnableAlligatorAwakenAlert) return true;
   if(IsEatingPhase(p) && EnableAlligatorEatAlert) return true;
   return false;
}

void CheckAlligatorPhaseAndNotify()
{
   const bool needRun = AnyAlligatorAlertEnabled() || AlligatorDebugLog ||
                        AlligatorTestMailEveryNewBar;
   if(!needRun)
      return;

   datetime bar0 = iTime(_Symbol, _Period, 0);
   if(bar0 == 0)
      return;
   if(bar0 == g_alligatorLastBar0Time)
      return;

   if(!AlligatorIndicatorsReady())
   {
      LogAlligatorDiag(StringFormat("指标数据未就绪 jawBars=%d atrBars=%d，下秒重试",
                                    BarsCalculated(g_alligatorHandle),
                                    BarsCalculated(g_alligatorAtrHandle)));
      return;
   }

   g_alligatorLastBar0Time = bar0;

   datetime closedBarTime = iTime(_Symbol, _Period, 1);
   if(closedBarTime == 0)
      return;
   if(closedBarTime == g_alligatorEmailedClosedBarTime)
      return;

   AlligatorPhase cur = ClassifyAlligatorPhase(1);
   AlligatorPhase prev = ClassifyAlligatorPhase(2);

   double jaw = 0, teeth = 0, lips = 0, atr = 0;
   GetAlligatorLines(1, jaw, teeth, lips);
   GetAtrAt(1, atr);
   double spread = AlligatorSpread(jaw, teeth, lips);

   if(AlligatorDebugLog)
   {
      LogAlligatorDiag(StringFormat(
         "新K线 | 收盘K=%s | 形态 前一根=%s -> 当前=%s | 间距=%.5f ATR=%.5f 睡阈=%.5f 食阈=%.5f",
         TimeToString(closedBarTime, TIME_DATE|TIME_MINUTES),
         AlligatorPhaseText(prev),
         AlligatorPhaseText(cur),
         spread, atr,
         AlligatorSleepSpreadAtrMult * atr,
         AlligatorEatSpreadAtrMult * atr));
   }

   if(cur == ALG_UNKNOWN)
   {
      LogAlligatorDiag("无法判定形态（CopyBuffer 失败或数值无效）");
      return;
   }

   if(AlligatorTestMailEveryNewBar && AnyAlligatorAlertEnabled())
   {
      string tTitle = "鳄鱼测试(每根K线)";
      if(SendOrQueueMail(tTitle, BuildAlligatorMailBody(cur, 1)))
      {
         g_alligatorEmailedClosedBarTime = closedBarTime;
         LogAlligatorDiag("已发送测试邮件(每根K线模式)");
      }
      else
         LogAlligatorDiag("测试邮件发送失败或被队列阻塞，见 SendMail/队列 日志");
      return;
   }

   if(cur == prev)
   {
      LogAlligatorDiag("形态未变化，不触发「进入形态」邮件（沿边触发）");
      return;
   }

   if(!AlligatorAlertEnabledForPhase(cur))
   {
      LogAlligatorDiag(StringFormat("形态变化 %s -> %s，但未开启对应提醒",
                                    AlligatorPhaseText(prev), AlligatorPhaseText(cur)));
      return;
   }

   string title = "";
   string body = "";

   if(cur == ALG_SLEEP)
   {
      title = "鳄鱼睡觉";
      body = BuildAlligatorMailBody(cur, 1);
   }
   else if(cur == ALG_AWAKEN)
   {
      title = "鳄鱼醒来";
      body = BuildAlligatorMailBody(cur, 1);
   }
   else if(IsEatingPhase(cur))
   {
      title = "鳄鱼进食";
      body = BuildAlligatorMailBody(cur, 1);
   }

   if(title == "" || body == "")
      return;

   LogAlligatorDiag(StringFormat("触发邮件: %s (%s -> %s)",
                                 title, AlligatorPhaseText(prev), AlligatorPhaseText(cur)));

   if(SendOrQueueMail(title, body))
      g_alligatorEmailedClosedBarTime = closedBarTime;
   else
      LogAlligatorDiag("SendOrQueueMail 返回 false（可能被待重试队列阻塞），本根收盘K线未标记已发信");
}

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

   if(report == "")
      return;

   if(g_lastLimitProximityEmailAt > 0 &&
      (TimeCurrent() - g_lastLimitProximityEmailAt) < MathMax(1, LimitProximityEmailCooldownSeconds))
   {
      Print("Limit proximity mail skipped: cooldown ",
            LimitProximityEmailCooldownSeconds, "s not elapsed");
      return;
   }

   if(!SendOrQueueMail("限价单接近市价", report, true))
      return;

   // 邮件已发出或进入重试队列后，才标记各挂单已提醒
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

      double refPx = (typ == ORDER_TYPE_BUY_LIMIT ? bid : ask);
      if(MathAbs(refPx - limitPrice) > maxDiff)
         continue;

      int trIdx = FindLimitTrackIndex(ot);
      if(trIdx >= 0)
         g_limitProximityTrack[trIdx].alerted = true;
   }
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

bool IsLimitProximityMailTitle(const string title)
{
   return (title == "限价单接近市价");
}

void MarkLimitProximityEmailSent()
{
   g_lastLimitProximityEmailAt = TimeCurrent();
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
   if(IsLimitProximityMailTitle(title))
      MarkLimitProximityEmailSent();
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

bool SendOrQueueMail(string title, string content, bool isLimitProximityAlert = false)
{
   // 待重试邮件：仅阻塞同类型邮件（限价接近不阻塞持仓变化，反之亦然）
   if(g_pendingTitle != "" || g_pendingContent != "")
   {
      bool pendingIsLimit = IsLimitProximityMailTitle(g_pendingTitle);
      if(isLimitProximityAlert == pendingIsLimit)
      {
         Print("Mail queued because previous pending mail exists (same type). title=", title);
         return false;
      }
   }

   if(isLimitProximityAlert &&
      g_lastLimitProximityEmailAt > 0 &&
      (TimeCurrent() - g_lastLimitProximityEmailAt) < MathMax(1, LimitProximityEmailCooldownSeconds))
   {
      Print("Limit proximity mail blocked by cooldown. title=", title);
      return false;
   }

   if((TimeCurrent() - g_lastSendAt) < MathMax(1, MinSendIntervalSeconds))
   {
      Print("Mail queued by rate limit. title=", title);
      QueuePendingMail(title, content);
      return true;
   }

   if(!SendPositionMail(title, content))
   {
      QueuePendingMail(title, content);
      return true;
   }
   return true;
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

   if(AnyAlligatorAlertEnabled())
   {
      g_alligatorHandle = iAlligator(_Symbol, _Period,
                                     AlligatorJawPeriod, AlligatorJawShift,
                                     AlligatorTeethPeriod, AlligatorTeethShift,
                                     AlligatorLipsPeriod, AlligatorLipsShift,
                                     MODE_SMMA, PRICE_MEDIAN);
      g_alligatorAtrHandle = iATR(_Symbol, _Period, MathMax(1, AlligatorAtrPeriod));
      if(g_alligatorHandle == INVALID_HANDLE || g_alligatorAtrHandle == INVALID_HANDLE)
      {
         Print("Alligator/ATR indicator init failed, error=", GetLastError());
         return(INIT_FAILED);
      }

      AlligatorPhase p1 = ClassifyAlligatorPhase(1);
      Print("Alligator init OK. 最近已收盘K线形态=", AlligatorPhaseText(p1),
            " sleep=", EnableAlligatorSleepAlert,
            " awaken=", EnableAlligatorAwakenAlert,
            " eat=", EnableAlligatorEatAlert,
            " debug=", AlligatorDebugLog);

      if(AlligatorSendTestMailOnInit)
      {
         string testBody = StringFormat(
            "【鳄鱼邮件通道测试】EA 已启动，若收到本邮件说明 SendMail/SMTP 正常。\n"
            "当前已收盘K线(shift=1)形态=%s\n\n%s",
            AlligatorPhaseText(p1),
            BuildAlligatorMailBody(p1, 1));
         if(SendOrQueueMail("鳄鱼邮件测试", testBody))
            Print("Alligator test mail on init: sent or queued.");
         else
            Print("Alligator test mail on init: failed or blocked, check Experts log.");
      }
   }

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
   if(g_alligatorHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_alligatorHandle);
      g_alligatorHandle = INVALID_HANDLE;
   }
   if(g_alligatorAtrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_alligatorAtrHandle);
      g_alligatorAtrHandle = INVALID_HANDLE;
   }
   Print("PositionChangeEmailEA stopped. reason=", reason);
}

void OnTimer()
{
   FlushPendingMailIfNeeded();
   CheckLimitProximityAndNotify();
   CheckAlligatorPhaseAndNotify();
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

