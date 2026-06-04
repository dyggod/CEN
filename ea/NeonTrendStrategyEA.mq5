//+------------------------------------------------------------------+
//|                                        NeonTrendStrategyEA.mq5   |
//|  Neon 蓝/红区 + hist/sig + 鳄鱼醒来/进食进场；近N根K止损；2R TP/收盘破唇/睡离场 |
//+------------------------------------------------------------------+
#property copyright "NeonTrend Strategy"
#property version   "2.06"
#property description "进场:鳄鱼方向与Neon一致+柱阈值+hist/sig; 离场:2R/破唇/睡"

// 仅 Market 路径（勿写 NeonTrend.ex5，测试器会去 Indicators 根目录找错文件）
#property tester_indicator "Market\\NeonTrend.ex5"

#include <Trade/Trade.mqh>

//--- Neon Trend（与 Market 版输入一致，不含 @group）
input int                 InpRsiPeriod      = 14;
input int                 InpSmoothPeriod   = 5;
input ENUM_APPLIED_PRICE  InpAppliedPrice   = PRICE_CLOSE;
input bool                InpShowDashboard  = true;
input color               InpBullishColor   = clrDeepSkyBlue;
input color               InpBearishColor   = clrHotPink;
input color               InpTextColor      = clrWhite;
input color               InpPanelBgColor   = C'30,30,30';
input int                 InpFontSize       = 9;
input string              InpNeonIndicatorPath = "Market\\NeonTrend"; // 指标路径(相对 MQL5/Indicators，无 .ex5)
input bool                InpPreferChartIndicator = true;
input bool                InpForceICustom     = false;
input bool                InpShowNeonOnChart  = true;   // 回测/实盘：把 Neon 画到副图（仅 iCustom 句柄）

//--- Alligator（形态判定同 PositionChangeEmailEA）
input int    InpAlgJawPeriod          = 13;
input int    InpAlgJawShift           = 8;
input int    InpAlgTeethPeriod        = 8;
input int    InpAlgTeethShift         = 5;
input int    InpAlgLipsPeriod         = 5;
input int    InpAlgLipsShift          = 3;
input int    InpAlgAtrPeriod          = 14;
input double InpAlgSleepSpreadAtrMult = 0.50;  // 睡觉：三线间距 < 该值×ATR
input double InpAlgEatSpreadAtrMult   = 0.35;  // 进食：间距≥该值×ATR 且张口有序

//--- 交易
input double InpLotSize           = 0.01;
input ulong  InpMagic             = 20260603;
input int    InpSlippagePoints    = 30;
input int    InpSlLookbackBars    = 5;     // 止损：近N根已收盘K的最低/最高
input double InpRewardRiskRatio   = 2.0;     // 止盈距离 = 止损距离 × 该值(2=盈亏比2:1)
input int    InpMaxZoneLookback   = 50;
input bool   InpUseBufferColor    = true;  // 蓝/红区用 Buffer[1]
input double InpBlueHistMin       = 10.0;  // 蓝柱进场: hist 需大于该值
input double InpRedHistMax        = -10.0; // 红柱进场: hist 需小于该值
input double InpHistSigEps        = 1e-4;  // hist 与 sig 比较容差
input bool   InpLogEachBar        = false;
input bool   InpLogEntryDiag      = true;   // 无持仓时每根新K打印未进场原因(限频)
input int    InpLogEntryDiagEvery = 1;      // 每N根新K打印一次诊断(1=每根)
input string InpTradeComment      = "NTS";

#define NTS_BUF_HIST    0
#define NTS_BUF_COLOR   1   // 柱色 0蓝 1粉 2灰（与副图 DRAW_COLOR 一致）
#define NTS_BUF_SIGNAL  2

#define NTS_COLOR_BLUE  0
#define NTS_COLOR_RED   1
#define NTS_COLOR_GREY  2

enum NtsAlgPhase
{
   NTS_ALG_UNKNOWN  = 0,
   NTS_ALG_SLEEP    = 1,
   NTS_ALG_AWAKEN   = 2,
   NTS_ALG_EAT_BULL = 3,
   NTS_ALG_EAT_BEAR = 4
};

CTrade g_trade;
int    g_neonHandle      = INVALID_HANDLE;
int    g_alligatorHandle = INVALID_HANDLE;
int    g_atrHandle       = INVALID_HANDLE;
bool   g_ownNeonHandle  = false;
bool   g_neonOnChart    = false;
int    g_attachRetries  = 0;
datetime g_lastBarTime  = 0;
int      g_entryDiagBarCount = 0;

//+------------------------------------------------------------------+
void NtsLog(const string msg)
{
   Print("[NeonTrendStrategy] ", msg);
}

//+------------------------------------------------------------------+
bool NtsIsTester()
{
   return (MQLInfoInteger(MQL_TESTER) != 0);
}

//+------------------------------------------------------------------+
bool NtsIsNeonName(const string name)
{
   string s = name;
   StringToLower(s);
   return (StringFind(s, "neon") >= 0 && StringFind(s, "trend") >= 0);
}

//+------------------------------------------------------------------+
int NtsFindChartNeon()
{
   int winMax = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int w = 0; w < winMax; w++)
   {
      int n = ChartIndicatorsTotal(0, w);
      for(int i = 0; i < n; i++)
      {
         string shortName = ChartIndicatorName(0, w, i);
         if(shortName == "" || !NtsIsNeonName(shortName))
            continue;
         ResetLastError();
         int h = ChartIndicatorGet(0, w, shortName);
         if(h != INVALID_HANDLE)
         {
            NtsLog("图表 Neon: " + shortName + " handle=" + IntegerToString(h));
            return h;
         }
      }
   }
   return INVALID_HANDLE;
}

//+------------------------------------------------------------------+
int NtsCreateNeonICustomWithName(const string indName)
{
   ResetLastError();
   return iCustom(_Symbol, _Period, indName,
                  InpRsiPeriod, InpSmoothPeriod, InpAppliedPrice,
                  InpShowDashboard, InpBullishColor, InpBearishColor,
                  InpTextColor, InpPanelBgColor, InpFontSize);
}

//+------------------------------------------------------------------+
bool NtsNeonEx5ExistsOnDisk()
{
   const string base = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Indicators\\";
   const string paths[] =
   {
      base + "Market\\NeonTrend.ex5",
      base + "NeonTrend.ex5"
   };
   for(int i = 0; i < ArraySize(paths); i++)
   {
      if(FileIsExist(paths[i]))
      {
         NtsLog("找到指标文件: " + paths[i]);
         return true;
      }
   }
   NtsLog("未找到 NeonTrend.ex5，请从 MT5 市场安装到: " + base + "Market\\");
   return false;
}

//+------------------------------------------------------------------+
int NtsCreateNeonIndicatorCreate(const string indPath)
{
   MqlParam p[9];
   int n = 0;

   p[n].type = TYPE_STRING;
   p[n].string_value = indPath;
   n++;

   p[n].type = TYPE_INT;
   p[n].integer_value = InpRsiPeriod;
   n++;
   p[n].type = TYPE_INT;
   p[n].integer_value = InpSmoothPeriod;
   n++;
   p[n].type = TYPE_INT;
   p[n].integer_value = (int)InpAppliedPrice;
   n++;
   p[n].type = TYPE_BOOL;
   p[n].integer_value = InpShowDashboard ? 1 : 0;
   n++;
   p[n].type = TYPE_COLOR;
   p[n].integer_value = (long)InpBullishColor;
   n++;
   p[n].type = TYPE_COLOR;
   p[n].integer_value = (long)InpBearishColor;
   n++;
   p[n].type = TYPE_COLOR;
   p[n].integer_value = (long)InpTextColor;
   n++;
   p[n].type = TYPE_COLOR;
   p[n].integer_value = (long)InpPanelBgColor;
   n++;
   p[n].type = TYPE_INT;
   p[n].integer_value = InpFontSize;
   n++;

   ResetLastError();
   const int h = IndicatorCreate(_Symbol, _Period, IND_CUSTOM, n, p);
   if(h == INVALID_HANDLE)
      NtsLog("IndicatorCreate 失败 path=" + indPath + " err=" + IntegerToString(GetLastError()));
   else
      NtsLog("IndicatorCreate 成功 path=" + indPath + " handle=" + IntegerToString(h));
   return h;
}

//+------------------------------------------------------------------+
int NtsCreateNeonICustom()
{
   string names[];
   ArrayResize(names, 0);

   if(StringLen(InpNeonIndicatorPath) > 0)
   {
      int c = ArraySize(names);
      ArrayResize(names, c + 1);
      names[c] = InpNeonIndicatorPath;
   }

   const string fallbacks[] = { "Market\\NeonTrend", "NeonTrend" };
   for(int i = 0; i < ArraySize(fallbacks); i++)
   {
      bool dup = false;
      for(int j = 0; j < ArraySize(names); j++)
      {
         if(names[j] == fallbacks[i])
         {
            dup = true;
            break;
         }
      }
      if(!dup)
      {
         int c = ArraySize(names);
         ArrayResize(names, c + 1);
         names[c] = fallbacks[i];
      }
   }

   NtsNeonEx5ExistsOnDisk();

   for(int i = 0; i < ArraySize(names); i++)
   {
      int h = NtsCreateNeonICustomWithName(names[i]);
      if(h != INVALID_HANDLE)
      {
         g_ownNeonHandle = true;
         NtsLog("iCustom 成功 name=" + names[i] + " handle=" + IntegerToString(h));
         return h;
      }
      NtsLog("iCustom 失败 name=" + names[i] + " err=" + IntegerToString(GetLastError()));
   }

   for(int i = 0; i < ArraySize(names); i++)
   {
      int h = NtsCreateNeonIndicatorCreate(names[i]);
      if(h != INVALID_HANDLE)
      {
         g_ownNeonHandle = true;
         return h;
      }
   }

   return INVALID_HANDLE;
}

//+------------------------------------------------------------------+
bool NtsChartHasNeonIndicator()
{
   const long cid = ChartID();
   const int winMax = (int)ChartGetInteger(cid, CHART_WINDOWS_TOTAL);
   for(int w = 0; w < winMax; w++)
   {
      int n = ChartIndicatorsTotal(cid, w);
      for(int i = 0; i < n; i++)
      {
         string nm = ChartIndicatorName(cid, w, i);
         if(nm != "" && NtsIsNeonName(nm))
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool NtsAttachNeonToChart(const int handle)
{
   if(handle == INVALID_HANDLE || !InpShowNeonOnChart)
      return false;

   if(g_neonOnChart || NtsChartHasNeonIndicator())
   {
      g_neonOnChart = true;
      return true;
   }

   if(!g_ownNeonHandle)
   {
      NtsLog("Neon 来自图表已有实例，无需 ChartIndicatorAdd");
      g_neonOnChart = true;
      return true;
   }

   const long cid = ChartID();
   const int bars = BarsCalculated(handle);
   if(bars <= 0)
      NtsLog("ChartIndicatorAdd 前 BarsCalculated=0，稍后重试");

   ResetLastError();
   if(ChartIndicatorAdd(cid, 1, handle))
   {
      g_neonOnChart = true;
      NtsLog("ChartIndicatorAdd OK chart=" + IntegerToString(cid) + " sub=1 bars=" + IntegerToString(bars));
      ChartSetInteger(cid, CHART_SHOW, true);
      ChartRedraw(cid);
      return true;
   }

   const int err1 = GetLastError();
   const int subNew = (int)ChartGetInteger(cid, CHART_WINDOWS_TOTAL);
   ResetLastError();
   if(ChartIndicatorAdd(cid, subNew, handle))
   {
      g_neonOnChart = true;
      NtsLog("ChartIndicatorAdd OK chart=" + IntegerToString(cid) + " sub=" + IntegerToString(subNew));
      ChartRedraw(cid);
      return true;
   }

   NtsLog("ChartIndicatorAdd 失败 err=" + IntegerToString(err1) + "/" + IntegerToString(GetLastError()) +
          " chart=" + IntegerToString(cid) + " 将 OnTick 重试");
   return false;
}

//+------------------------------------------------------------------+
void NtsTryAttachNeonLater()
{
   if(g_neonOnChart || g_neonHandle == INVALID_HANDLE)
      return;
   if(g_attachRetries >= 30)
      return;
   g_attachRetries++;
   if(NtsAttachNeonToChart(g_neonHandle))
      return;
   if(g_attachRetries == 1 || g_attachRetries == 10 || g_attachRetries == 30)
      NtsLog("挂图重试 #" + IntegerToString(g_attachRetries) +
             " BarsCalculated=" + IntegerToString(BarsCalculated(g_neonHandle)));
}

//+------------------------------------------------------------------+
bool NtsWaitBars(const int handle, const int minBars, const int ms = 8000)
{
   uint t0 = GetTickCount();
   while((int)(GetTickCount() - t0) < ms)
   {
      if(BarsCalculated(handle) >= minBars)
         return true;
      Sleep(50);
   }
   return BarsCalculated(handle) >= minBars;
}

//+------------------------------------------------------------------+
int NtsResolveNeonHandle()
{
   if(InpForceICustom || NtsIsTester())
   {
      NtsLog(NtsIsTester() ? "策略测试器: 强制 iCustom" : "InpForceICustom=true");
      return NtsCreateNeonICustom();
   }
   if(InpPreferChartIndicator)
   {
      int h = NtsFindChartNeon();
      if(h != INVALID_HANDLE)
         return h;
      NtsLog("图表无 Neon，改用 iCustom");
   }
   return NtsCreateNeonICustom();
}

//+------------------------------------------------------------------+
bool NtsGetAlligator(const int shift, double &jaw, double &teeth, double &lips)
{
   double bJ[], bT[], bL[];
   ArraySetAsSeries(bJ, true);
   ArraySetAsSeries(bT, true);
   ArraySetAsSeries(bL, true);
   if(CopyBuffer(g_alligatorHandle, 0, shift, 1, bJ) != 1) return false;
   if(CopyBuffer(g_alligatorHandle, 1, shift, 1, bT) != 1) return false;
   if(CopyBuffer(g_alligatorHandle, 2, shift, 1, bL) != 1) return false;
   jaw = bJ[0]; teeth = bT[0]; lips = bL[0];
   return MathIsValidNumber(jaw) && MathIsValidNumber(teeth) && MathIsValidNumber(lips);
}

//+------------------------------------------------------------------+
bool NtsAlgLineValid(const double v)
{
   return (v != EMPTY_VALUE && v != 0.0 && MathIsValidNumber(v));
}

//+------------------------------------------------------------------+
double NtsAlgSpread(const double jaw, const double teeth, const double lips)
{
   const double hi = MathMax(jaw, MathMax(teeth, lips));
   const double lo = MathMin(jaw, MathMin(teeth, lips));
   return hi - lo;
}

//+------------------------------------------------------------------+
bool NtsGetAtr(const int shift, double &atr)
{
   atr = 0.0;
   if(g_atrHandle == INVALID_HANDLE)
      return false;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(g_atrHandle, 0, shift, 1, b) != 1)
      return false;
   if(!MathIsValidNumber(b[0]) || b[0] <= 0.0)
      return false;
   atr = b[0];
   return true;
}

//+------------------------------------------------------------------+
NtsAlgPhase NtsClassifyAlligator(const int shift)
{
   double jaw, teeth, lips;
   if(!NtsGetAlligator(shift, jaw, teeth, lips))
      return NTS_ALG_UNKNOWN;
   if(!NtsAlgLineValid(jaw) || !NtsAlgLineValid(teeth) || !NtsAlgLineValid(lips))
      return NTS_ALG_UNKNOWN;

   double atr = 0.0;
   if(!NtsGetAtr(shift, atr))
      return NTS_ALG_UNKNOWN;

   const double spread = NtsAlgSpread(jaw, teeth, lips);
   if(spread <= InpAlgSleepSpreadAtrMult * atr)
      return NTS_ALG_SLEEP;

   if(spread >= InpAlgEatSpreadAtrMult * atr)
   {
      if(lips > teeth && teeth > jaw)
         return NTS_ALG_EAT_BULL;
      if(lips < teeth && teeth < jaw)
         return NTS_ALG_EAT_BEAR;
   }
   return NTS_ALG_AWAKEN;
}

//+------------------------------------------------------------------+
string NtsAlgPhaseName(const NtsAlgPhase p)
{
   if(p == NTS_ALG_SLEEP)    return "睡觉";
   if(p == NTS_ALG_AWAKEN)   return "醒来";
   if(p == NTS_ALG_EAT_BULL) return "进食(多)";
   if(p == NTS_ALG_EAT_BEAR) return "进食(空)";
   return "未知";
}

//+------------------------------------------------------------------+
bool NtsAlgAwakeOrEat(const int shift)
{
   const NtsAlgPhase p = NtsClassifyAlligator(shift);
   return (p == NTS_ALG_AWAKEN || p == NTS_ALG_EAT_BULL || p == NTS_ALG_EAT_BEAR);
}

//+------------------------------------------------------------------+
// 做多：进食(多) 或 醒来且唇>齿；禁止 进食(空)
bool NtsAlgAllowsLongEntry(const int shift)
{
   const NtsAlgPhase p = NtsClassifyAlligator(shift);
   if(p == NTS_ALG_EAT_BULL)
      return true;
   if(p == NTS_ALG_EAT_BEAR || p == NTS_ALG_SLEEP || p == NTS_ALG_UNKNOWN)
      return false;

   double jaw, teeth, lips;
   if(!NtsGetAlligator(shift, jaw, teeth, lips))
      return false;
   if(!NtsAlgLineValid(lips) || !NtsAlgLineValid(teeth))
      return false;
   return (lips > teeth);
}

//+------------------------------------------------------------------+
// 做空：进食(空) 或 醒来且唇<齿；禁止 进食(多)
bool NtsAlgAllowsShortEntry(const int shift)
{
   const NtsAlgPhase p = NtsClassifyAlligator(shift);
   if(p == NTS_ALG_EAT_BEAR)
      return true;
   if(p == NTS_ALG_EAT_BULL || p == NTS_ALG_SLEEP || p == NTS_ALG_UNKNOWN)
      return false;

   double jaw, teeth, lips;
   if(!NtsGetAlligator(shift, jaw, teeth, lips))
      return false;
   if(!NtsAlgLineValid(lips) || !NtsAlgLineValid(teeth))
      return false;
   return (lips < teeth);
}

//+------------------------------------------------------------------+
string NtsAlgLongEntryRejectReason(const int shift)
{
   const NtsAlgPhase p = NtsClassifyAlligator(shift);
   if(p == NTS_ALG_SLEEP)
      return "鳄鱼睡觉 ";
   if(p == NTS_ALG_UNKNOWN)
      return "鳄鱼未知 ";
   if(p == NTS_ALG_EAT_BEAR)
      return "鳄鱼进食(空)与多不符 ";
   if(p == NTS_ALG_AWAKEN)
   {
      double jaw, teeth, lips;
      if(NtsGetAlligator(shift, jaw, teeth, lips) &&
         NtsAlgLineValid(lips) && NtsAlgLineValid(teeth) &&
         lips <= teeth)
         return "鳄鱼醒来但唇<=齿 ";
   }
   return "鳄鱼方向不符 ";
}

//+------------------------------------------------------------------+
string NtsAlgShortEntryRejectReason(const int shift)
{
   const NtsAlgPhase p = NtsClassifyAlligator(shift);
   if(p == NTS_ALG_SLEEP)
      return "鳄鱼睡觉 ";
   if(p == NTS_ALG_UNKNOWN)
      return "鳄鱼未知 ";
   if(p == NTS_ALG_EAT_BULL)
      return "鳄鱼进食(多)与空不符 ";
   if(p == NTS_ALG_AWAKEN)
   {
      double jaw, teeth, lips;
      if(NtsGetAlligator(shift, jaw, teeth, lips) &&
         NtsAlgLineValid(lips) && NtsAlgLineValid(teeth) &&
         lips >= teeth)
         return "鳄鱼醒来但唇>=齿 ";
   }
   return "鳄鱼方向不符 ";
}

//+------------------------------------------------------------------+
bool NtsAlgIsSleep(const int shift)
{
   return NtsClassifyAlligator(shift) == NTS_ALG_SLEEP;
}

//+------------------------------------------------------------------+
bool NtsHistAboveSig(const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE)
      return false;
   return (hist > sig + InpHistSigEps);
}

//+------------------------------------------------------------------+
bool NtsHistBelowSig(const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE)
      return false;
   return (hist < sig - InpHistSigEps);
}

//+------------------------------------------------------------------+
// 进场：回测常见 hist==sig，蓝区且 hist>0 时视为柱在信号线上方
bool NtsHistAboveSigForEntry(const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE)
      return false;
   if(hist > sig + InpHistSigEps)
      return true;
   if(NtsHistEqualsSig(hist, sig) && hist > InpHistSigEps)
      return true;
   return false;
}

//+------------------------------------------------------------------+
bool NtsHistBelowSigForEntry(const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE)
      return false;
   if(hist < sig - InpHistSigEps)
      return true;
   if(NtsHistEqualsSig(hist, sig) && hist < -InpHistSigEps)
      return true;
   return false;
}

//+------------------------------------------------------------------+
bool NtsIsBlueBarColor(const int barColor, const double colorRaw,
                       const double hist, const double sig)
{
   if(barColor == NTS_COLOR_BLUE)
      return true;
   return (NtsPaintBarColor(colorRaw, hist, sig) == NTS_COLOR_BLUE);
}

//+------------------------------------------------------------------+
bool NtsIsRedBarColor(const int barColor, const double colorRaw,
                      const double hist, const double sig)
{
   if(barColor == NTS_COLOR_RED)
      return true;
   return (NtsPaintBarColor(colorRaw, hist, sig) == NTS_COLOR_RED);
}

//+------------------------------------------------------------------+
bool NtsIsBlueZone(const int barColor, const double colorRaw,
                   const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || !MathIsValidNumber(hist))
      return false;
   if(!NtsIsBlueBarColor(barColor, colorRaw, hist, sig))
      return false;
   return (hist > InpBlueHistMin);
}

//+------------------------------------------------------------------+
bool NtsIsRedZone(const int barColor, const double colorRaw,
                  const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || !MathIsValidNumber(hist))
      return false;
   if(!NtsIsRedBarColor(barColor, colorRaw, hist, sig))
      return false;
   return (hist < InpRedHistMax);
}

//+------------------------------------------------------------------+
bool NtsRecentLowestLow(const int bars, double &lowest)
{
   if(bars < 1)
      return false;
   lowest = DBL_MAX;
   for(int s = 1; s <= bars; s++)
   {
      const double l = iLow(_Symbol, _Period, s);
      if(l > 0.0 && l < lowest)
         lowest = l;
   }
   return lowest < DBL_MAX;
}

//+------------------------------------------------------------------+
bool NtsRecentHighestHigh(const int bars, double &highest)
{
   if(bars < 1)
      return false;
   highest = -DBL_MAX;
   for(int s = 1; s <= bars; s++)
   {
      const double h = iHigh(_Symbol, _Period, s);
      if(h > 0.0 && h > highest)
         highest = h;
   }
   return highest > -DBL_MAX;
}

//+------------------------------------------------------------------+
// Buffer[1]：0=蓝 1=粉(红) 2=灰 — 与 NeonTrendReaderEA / 副图柱色一致
int NtsColorFromBuffer(const double colorRaw)
{
   if(colorRaw == EMPTY_VALUE)
      return -1;
   const int c = (int)MathRound(colorRaw);
   if(c < 0 || c > 2)
      return -1;
   return c;
}

//+------------------------------------------------------------------+
bool NtsHistEqualsSig(const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE)
      return false;
   const double rel = MathMax(1.0, MathMax(MathAbs(hist), MathAbs(sig)));
   return (MathAbs(hist - sig) <= MathMax(InpHistSigEps, rel * 1e-9));
}

//+------------------------------------------------------------------+
int NtsDeriveBarColor(const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE)
      return NTS_COLOR_GREY;

   // 回测里 hist 常与 sig 完全相等；此时 hist>sig / hist<sig 均为假 → 旧逻辑会恒为灰
   if(NtsHistEqualsSig(hist, sig))
   {
      if(hist > InpHistSigEps)
         return NTS_COLOR_BLUE;
      if(hist < -InpHistSigEps)
         return NTS_COLOR_RED;
      return NTS_COLOR_GREY;
   }

   if(hist > 0.0 && hist > sig)
      return NTS_COLOR_BLUE;
   if(hist < 0.0 && hist < sig)
      return NTS_COLOR_RED;
   return NTS_COLOR_GREY;
}

//+------------------------------------------------------------------+
// 柱线色：hist≈sig 时用 Buffer[1](与副图 DRAW 一致)，否则用 hist/线 推算
int NtsPaintBarColor(const double colorRaw, const double hist, const double sig)
{
   const int buf = NtsColorFromBuffer(colorRaw);
   if(buf >= 0 && NtsHistEqualsSig(hist, sig))
      return buf;
   return NtsDeriveBarColor(hist, sig);
}

//+------------------------------------------------------------------+
int NtsBarColor(const double colorRaw, const double hist, const double sig)
{
   if(InpUseBufferColor)
   {
      const int buf = NtsColorFromBuffer(colorRaw);
      if(buf >= 0)
         return buf;
   }
   return NtsPaintBarColor(colorRaw, hist, sig);
}

//+------------------------------------------------------------------+
string NtsColorName(const int c)
{
   if(c == NTS_COLOR_BLUE) return "蓝";
   if(c == NTS_COLOR_RED)  return "红";
   return "灰";
}

//+------------------------------------------------------------------+
string NtsColorBufEnglish(const int c)
{
   if(c == NTS_COLOR_BLUE) return "Blue";
   if(c == NTS_COLOR_RED)  return "Pink";
   return "Grey";
}

//+------------------------------------------------------------------+
void NtsLogBarLikeReader(const int seriesIdx, const double hist, const double sig,
                         const double colorRaw, const int barColor)
{
   const int bufIdx = NtsColorFromBuffer(colorRaw);
   const int paintIdx = NtsPaintBarColor(colorRaw, hist, sig);
   const int showIdx = (bufIdx >= 0 ? bufIdx : (int)MathRound(colorRaw));
   NtsLog(StringFormat("shift%d | hist=%.4f sig=%.4f buf=%d %s 柱线=%s 信号色=%s%s",
                       seriesIdx + 1, hist, sig, showIdx,
                       (bufIdx >= 0 ? NtsColorBufEnglish(bufIdx) : "?"),
                       NtsColorName(paintIdx), NtsColorName(barColor),
                       (NtsHistEqualsSig(hist, sig) ? " (h≈s)" : "")));
}

//+------------------------------------------------------------------+
bool NtsLoadNeonSeries(const int count, double &hist[], double &sigLine[],
                       double &colorRaw[], int &barColor[])
{
   ArrayResize(hist, count);
   ArrayResize(sigLine, count);
   ArrayResize(colorRaw, count);
   ArrayResize(barColor, count);
   ArraySetAsSeries(hist, true);
   ArraySetAsSeries(sigLine, true);
   ArraySetAsSeries(colorRaw, true);
   ArraySetAsSeries(barColor, true);

   if(CopyBuffer(g_neonHandle, NTS_BUF_HIST,   1, count, hist)     != count) return false;
   if(CopyBuffer(g_neonHandle, NTS_BUF_SIGNAL, 1, count, sigLine)  != count) return false;
   if(CopyBuffer(g_neonHandle, NTS_BUF_COLOR,  1, count, colorRaw) != count) return false;

   for(int i = 0; i < count; i++)
      barColor[i] = NtsBarColor(colorRaw[i], hist[i], sigLine[i]);
   return true;
}

//+------------------------------------------------------------------+
int NtsColorAt(const int &barColor[], const int seriesIdx)
{
   if(seriesIdx < 0 || seriesIdx >= ArraySize(barColor))
      return NTS_COLOR_GREY;
   return barColor[seriesIdx];
}

//+------------------------------------------------------------------+
bool NtsNormalizeSlOnly(const bool isBuy, const double entry, double &sl)
{
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minDist = stopsLevel * pt;

   sl = NormalizeDouble(sl, digs);
   const double e = NormalizeDouble(entry, digs);

   if(isBuy)
   {
      if(sl >= e)
         return false;
      if(e - sl < minDist)
         return false;
   }
   else
   {
      if(sl <= e)
         return false;
      if(sl - e < minDist)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool NtsCalcTakeProfit(const bool isBuy, const double entry, const double sl, double &tp)
{
   const double risk = isBuy ? (entry - sl) : (sl - entry);
   if(risk <= 0.0 || InpRewardRiskRatio <= 0.0)
      return false;
   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   tp = NormalizeDouble(isBuy ? entry + InpRewardRiskRatio * risk
                              : entry - InpRewardRiskRatio * risk, digs);
   return true;
}

//+------------------------------------------------------------------+
bool NtsNormalizeTpOnly(const bool isBuy, const double entry, double &tp)
{
   const double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double minDist = stopsLevel * pt;

   tp = NormalizeDouble(tp, digs);
   const double e = NormalizeDouble(entry, digs);

   if(isBuy)
   {
      if(tp <= e)
         return false;
      if(tp - e < minDist)
         return false;
   }
   else
   {
      if(tp >= e)
         return false;
      if(e - tp < minDist)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool NtsSetupFilling()
{
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
   {
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
      return true;
   }
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
   {
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
      return true;
   }
   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   return true;
}

//+------------------------------------------------------------------+
bool NtsSelectMyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
long NtsMyPositionType()
{
   if(!NtsSelectMyPosition())
      return -1;
   return PositionGetInteger(POSITION_TYPE);
}

//+------------------------------------------------------------------+
bool NtsCloseMyPosition()
{
   if(!NtsSelectMyPosition())
      return true;
   ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(g_trade.PositionClose(ticket))
      return true;
   NtsLog("平仓失败 ticket=" + IntegerToString(ticket) + " " + g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
bool NtsOpenBuy(const double sl)
{
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slN = sl;
   double tpN = 0.0;
   if(!NtsNormalizeSlOnly(true, ask, slN))
   {
      NtsLog("Buy 止损无效 entry=" + DoubleToString(ask) + " sl=" + DoubleToString(sl));
      return false;
   }
   if(!NtsCalcTakeProfit(true, ask, slN, tpN) || !NtsNormalizeTpOnly(true, ask, tpN))
   {
      NtsLog("Buy 止盈无效 entry=" + DoubleToString(ask) + " sl=" + DoubleToString(slN));
      return false;
   }
   if(g_trade.Buy(InpLotSize, _Symbol, ask, slN, tpN, InpTradeComment))
   {
      NtsLog(StringFormat("做多入场 sl=%.5f tp=%.5f (RR %.1f:1)",
                          slN, tpN, InpRewardRiskRatio));
      return true;
   }
   NtsLog("Buy 失败 " + g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
bool NtsOpenSell(const double sl)
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slN = sl;
   double tpN = 0.0;
   if(!NtsNormalizeSlOnly(false, bid, slN))
   {
      NtsLog("Sell 止损无效 entry=" + DoubleToString(bid) + " sl=" + DoubleToString(sl));
      return false;
   }
   if(!NtsCalcTakeProfit(false, bid, slN, tpN) || !NtsNormalizeTpOnly(false, bid, tpN))
   {
      NtsLog("Sell 止盈无效 entry=" + DoubleToString(bid) + " sl=" + DoubleToString(slN));
      return false;
   }
   if(g_trade.Sell(InpLotSize, _Symbol, bid, slN, tpN, InpTradeComment))
   {
      NtsLog(StringFormat("做空入场 sl=%.5f tp=%.5f (RR %.1f:1)",
                          slN, tpN, InpRewardRiskRatio));
      return true;
   }
   NtsLog("Sell 失败 " + g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
bool NtsReadClosedBar(double &hist, double &sig, int &barColor, double &colorRaw)
{
   double h[], s[], c[];
   int bc[];
   if(!NtsLoadNeonSeries(3, h, s, c, bc))
      return false;
   hist = h[0];
   sig = s[0];
   colorRaw = c[0];
   barColor = bc[0];
   return true;
}

//+------------------------------------------------------------------+
void NtsLogEntryDiagnostics(const double hist, const double sig,
                            const double colorRaw, const int barColor)
{
   if(!InpLogEntryDiag || InpLogEntryDiagEvery < 1)
      return;

   g_entryDiagBarCount++;
   if((g_entryDiagBarCount % InpLogEntryDiagEvery) != 0)
      return;

   const NtsAlgPhase ap = NtsClassifyAlligator(1);
   const bool algLongOk  = NtsAlgAllowsLongEntry(1);
   const bool algShortOk = NtsAlgAllowsShortEntry(1);
   const bool blueColor = NtsIsBlueBarColor(barColor, colorRaw, hist, sig);
   const bool redColor  = NtsIsRedBarColor(barColor, colorRaw, hist, sig);
   const bool blue = NtsIsBlueZone(barColor, colorRaw, hist, sig);
   const bool red  = NtsIsRedZone(barColor, colorRaw, hist, sig);
   const bool hGtS = NtsHistAboveSigForEntry(hist, sig);
   const bool hLtS = NtsHistBelowSigForEntry(hist, sig);
   const int bufIdx = NtsColorFromBuffer(colorRaw);

   string longMiss = "";
   if(!algLongOk) longMiss += NtsAlgLongEntryRejectReason(1);
   if(!blueColor)
      longMiss += "非蓝区 ";
   else if(!blue)
      longMiss += StringFormat("蓝柱hist<= %.1f(h=%.3f) ", InpBlueHistMin, hist);
   if(!hGtS)  longMiss += StringFormat("柱未>线(h=%.3f s=%.3f%s) ",
                                        hist, sig, (NtsHistEqualsSig(hist, sig) ? " h=s" : ""));

   string shortMiss = "";
   if(!algShortOk) shortMiss += NtsAlgShortEntryRejectReason(1);
   if(!redColor)
      shortMiss += "非红区 ";
   else if(!red)
      shortMiss += StringFormat("红柱hist>= %.1f(h=%.3f) ", InpRedHistMax, hist);
   if(!hLtS)  shortMiss += StringFormat("柱未<线(h=%.3f s=%.3f%s) ",
                                        hist, sig, (NtsHistEqualsSig(hist, sig) ? " h=s" : ""));

   NtsLog(StringFormat("诊断 @%s | 鳄鱼=%s buf=%d %s | 多:%s | 空:%s",
                       TimeToString(iTime(_Symbol, _Period, 1), TIME_DATE | TIME_MINUTES),
                       NtsAlgPhaseName(ap), bufIdx, NtsColorName(barColor),
                       (longMiss == "" ? "可试多" : longMiss),
                       (shortMiss == "" ? "可试空" : shortMiss)));
}

//+------------------------------------------------------------------+
// 离场 shift=1：上一根已收盘 K 的收盘价 vs 同根鳄鱼唇线
bool NtsCloseBelowLips(const int shift)
{
   const double closePx = iClose(_Symbol, _Period, shift);
   if(closePx <= 0.0)
      return false;
   double jaw, teeth, lips;
   if(!NtsGetAlligator(shift, jaw, teeth, lips))
      return false;
   if(!NtsAlgLineValid(lips))
      return false;
   return (closePx < lips);
}

//+------------------------------------------------------------------+
bool NtsCloseAboveLips(const int shift)
{
   const double closePx = iClose(_Symbol, _Period, shift);
   if(closePx <= 0.0)
      return false;
   double jaw, teeth, lips;
   if(!NtsGetAlligator(shift, jaw, teeth, lips))
      return false;
   if(!NtsAlgLineValid(lips))
      return false;
   return (closePx > lips);
}

//+------------------------------------------------------------------+
bool NtsEvalExitLong(string &reason)
{
   reason = "";
   const int sh = 1;

   if(NtsAlgIsSleep(sh))
   {
      reason = "鳄鱼睡觉";
      return true;
   }
   if(NtsCloseBelowLips(sh))
   {
      double jaw = 0.0, teeth = 0.0, lips = 0.0;
      NtsGetAlligator(sh, jaw, teeth, lips);
      reason = StringFormat("收盘<唇 (c=%.5f 唇=%.5f)", iClose(_Symbol, _Period, sh), lips);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool NtsEvalExitShort(string &reason)
{
   reason = "";
   const int sh = 1;

   if(NtsAlgIsSleep(sh))
   {
      reason = "鳄鱼睡觉";
      return true;
   }
   if(NtsCloseAboveLips(sh))
   {
      double jaw = 0.0, teeth = 0.0, lips = 0.0;
      NtsGetAlligator(sh, jaw, teeth, lips);
      reason = StringFormat("收盘>唇 (c=%.5f 唇=%.5f)", iClose(_Symbol, _Period, sh), lips);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void NtsManageExits()
{
   if(!NtsSelectMyPosition())
      return;

   const long ptype = NtsMyPositionType();
   string reason = "";
   bool shouldExit = false;

   if(ptype == POSITION_TYPE_BUY)
      shouldExit = NtsEvalExitLong(reason);
   else if(ptype == POSITION_TYPE_SELL)
      shouldExit = NtsEvalExitShort(reason);

   if(shouldExit && NtsCloseMyPosition())
      NtsLog((ptype == POSITION_TYPE_BUY ? "多单" : "空单") + "平仓: " + reason);
}

//+------------------------------------------------------------------+
bool NtsTryEnterLong()
{
   if(NtsMyPositionType() != -1)
      return false;

   double hist = 0.0, sig = 0.0, colorRaw = 0.0;
   int barColor = NTS_COLOR_GREY;
   if(!NtsReadClosedBar(hist, sig, barColor, colorRaw))
      return false;

   if(!NtsAlgAllowsLongEntry(1))
      return false;
   if(!NtsIsBlueZone(barColor, colorRaw, hist, sig))
      return false;
   if(!NtsHistAboveSigForEntry(hist, sig))
      return false;

   double sl = 0.0;
   if(!NtsRecentLowestLow(InpSlLookbackBars, sl))
      return false;

   const NtsAlgPhase ap = NtsClassifyAlligator(1);
   NtsLog(StringFormat("多头条件满足 | 鳄鱼=%s | 蓝区 hist=%.3f>%.1f | h=%.3f>s=%.3f",
                       NtsAlgPhaseName(ap), hist, InpBlueHistMin, hist, sig));
   return NtsOpenBuy(sl);
}

//+------------------------------------------------------------------+
bool NtsTryEnterShort()
{
   if(NtsMyPositionType() != -1)
      return false;

   double hist = 0.0, sig = 0.0, colorRaw = 0.0;
   int barColor = NTS_COLOR_GREY;
   if(!NtsReadClosedBar(hist, sig, barColor, colorRaw))
      return false;

   if(!NtsAlgAllowsShortEntry(1))
      return false;
   if(!NtsIsRedZone(barColor, colorRaw, hist, sig))
      return false;
   if(!NtsHistBelowSigForEntry(hist, sig))
      return false;

   double sl = 0.0;
   if(!NtsRecentHighestHigh(InpSlLookbackBars, sl))
      return false;

   const NtsAlgPhase ap = NtsClassifyAlligator(1);
   NtsLog(StringFormat("空头条件满足 | 鳄鱼=%s | 红区 hist=%.3f<%.1f | h=%.3f<s=%.3f",
                       NtsAlgPhaseName(ap), hist, InpRedHistMax, hist, sig));
   return NtsOpenSell(sl);
}

//+------------------------------------------------------------------+
void NtsUpdateComment(const string extra)
{
   string pos = "无持仓";
   if(NtsSelectMyPosition())
   {
      const long t = PositionGetInteger(POSITION_TYPE);
      pos = (t == POSITION_TYPE_BUY ? "多单" : "空单");
      pos += " vol=" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2);
   }
   const NtsAlgPhase ap = NtsClassifyAlligator(1);
   Comment("NeonTrend Strategy v2.06\n",
           "进场: 鳄鱼方向同Neon | 蓝hist>", DoubleToString(InpBlueHistMin, 1),
           " 红hist<", DoubleToString(InpRedHistMax, 1), "\n",
           "离场: 2R止盈 | 多:收盘<唇 空:收盘>唇 | 鳄鱼睡\n",
           "鳄鱼(shift1): ", NtsAlgPhaseName(ap), "\n",
           extra, "\n", pos);
}

//+------------------------------------------------------------------+
void NtsOnNewBar()
{
   const int need = MathMax(InpMaxZoneLookback, InpSlLookbackBars + 2);
   double hist[], sigLine[], colorRaw[];
   int barColor[];
   if(!NtsLoadNeonSeries(need, hist, sigLine, colorRaw, barColor))
   {
      NtsLog("CopyBuffer 失败");
      return;
   }

   if(InpLogEachBar)
      NtsLogBarLikeReader(0, hist[0], sigLine[0], colorRaw[0], barColor[0]);

   NtsManageExits();

   if(NtsMyPositionType() == -1)
   {
      NtsLogEntryDiagnostics(hist[0], sigLine[0], colorRaw[0], barColor[0]);
      if(NtsTryEnterLong())
         NtsUpdateComment("刚开多");
      else if(NtsTryEnterShort())
         NtsUpdateComment("刚开空");
      else
         NtsUpdateComment("等待进场");
   }
   else
      NtsUpdateComment("持仓中(条件离场)");
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_lastBarTime = 0;
   g_entryDiagBarCount = 0;
   g_ownNeonHandle = false;

   g_trade.SetExpertMagicNumber((long)InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   NtsSetupFilling();

   g_neonHandle = NtsResolveNeonHandle();
   if(g_neonHandle == INVALID_HANDLE)
   {
      NtsLog("致命: 无法加载 Neon Trend。请在当前 MT5 数据目录安装市场指标:");
      NtsLog(TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Indicators\\Market\\NeonTrend.ex5");
      NtsLog("安装后重新编译本 EA，再运行策略测试器。");
      Alert("NeonTrend 加载失败，详见专家日志（需要 Market\\NeonTrend.ex5）");
      return INIT_FAILED;
   }

   g_alligatorHandle = iAlligator(_Symbol, _Period,
                                  InpAlgJawPeriod, InpAlgJawShift,
                                  InpAlgTeethPeriod, InpAlgTeethShift,
                                  InpAlgLipsPeriod, InpAlgLipsShift,
                                  MODE_SMMA, PRICE_MEDIAN);
   g_atrHandle = iATR(_Symbol, _Period, MathMax(1, InpAlgAtrPeriod));
   if(g_alligatorHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      NtsLog("iAlligator/iATR 失败");
      return INIT_FAILED;
   }

   const int minBars = MathMax(InpMaxZoneLookback, 50);
   if(!NtsWaitBars(g_neonHandle, minBars) ||
      !NtsWaitBars(g_alligatorHandle, minBars) ||
      !NtsWaitBars(g_atrHandle, minBars))
   {
      NtsLog("指标数据未就绪");
      return INIT_FAILED;
   }

   NtsAttachNeonToChart(g_neonHandle);

   const int neonBars = BarsCalculated(g_neonHandle);
   NtsLog("初始化 v2.06 " + _Symbol + " " + EnumToString(_Period) +
          " 鳄鱼方向须与Neon一致" +
          " 蓝hist>" + DoubleToString(InpBlueHistMin, 1) +
          " 红hist<" + DoubleToString(InpRedHistMax, 1) +
          " RR=" + DoubleToString(InpRewardRiskRatio, 1) + ":1" +
          " SL近" + IntegerToString(InpSlLookbackBars) + "根K" +
          " 进场诊断=" + (InpLogEntryDiag ? "开" : "关") +
          " NeonBars=" + IntegerToString(neonBars) +
          " 鳄鱼=" + NtsAlgPhaseName(NtsClassifyAlligator(1)));

   if(neonBars <= 0)
      NtsLog("警告: Neon 未计算出数据，请确认 Market\\NeonTrend.ex5 在测试器终端的 MQL5/Indicators 下");

   string tip = "等待新K线";
   if(!g_neonOnChart && !NtsChartHasNeonIndicator())
      tip += "\nNeon 副图未挂上，请看专家日志";
   else
      tip += "\nNeon 已挂副图(窗口1或下方标签)";
   NtsUpdateComment(tip);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   if(g_ownNeonHandle && g_neonHandle != INVALID_HANDLE)
   {
      // 从图表移除 EA 添加的指标实例，再释放句柄
      for(int w = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL) - 1; w >= 0; w--)
      {
         int n = ChartIndicatorsTotal(0, w);
         for(int i = n - 1; i >= 0; i--)
         {
            string nm = ChartIndicatorName(0, w, i);
            if(nm != "" && NtsIsNeonName(nm))
               ChartIndicatorDelete(0, w, nm);
         }
      }
      IndicatorRelease(g_neonHandle);
      g_neonHandle = INVALID_HANDLE;
   }
   if(g_alligatorHandle != INVALID_HANDLE)
      IndicatorRelease(g_alligatorHandle);
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   NtsTryAttachNeonLater();
   NtsManageExits();

   const datetime t0 = iTime(_Symbol, _Period, 0);
   if(t0 == 0 || t0 == g_lastBarTime)
      return;
   g_lastBarTime = t0;
   NtsOnNewBar();
}

//+------------------------------------------------------------------+
