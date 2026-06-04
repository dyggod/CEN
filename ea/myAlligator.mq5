//+------------------------------------------------------------------+
//|                                                   myAlligator.mq5 |
//|  标准 Bill Williams 鳄鱼三线 + 左下角面板(三线数值与形态状态)      |
//+------------------------------------------------------------------+
#property copyright "myAlligator"
#property version   "1.05"
#property description "进仓/离场邮件+Neon止损参考; 发过进仓邮件后监测唇线/鳄鱼睡眠离场"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3

#property indicator_label1  "Jaws"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

#property indicator_label2  "Teeth"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

#property indicator_label3  "Lips"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrLime
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1

//--- 鳄鱼参数（与 NeonTrendStrategyEA / PositionChangeEmailEA 默认一致）
input group "=== Alligator ==="
input int    InpJawPeriod          = 13;   // 颚周期
input int    InpJawShift           = 8;    // 颚位移
input int    InpTeethPeriod        = 8;    // 齿周期
input int    InpTeethShift         = 5;    // 齿位移
input int    InpLipsPeriod         = 5;    // 唇周期
input int    InpLipsShift          = 3;    // 唇位移

input group "=== 形态判定 ==="
input int    InpAtrPeriod          = 14;   // ATR 周期
input double InpSleepSpreadAtrMult = 0.50; // 睡眠：三线间距 < 该值×ATR
input double InpEatSpreadAtrMult   = 0.35; // 进食：间距≥该值×ATR 且张口有序

input group "=== Neon Trend（与图表指标参数一致）==="
input bool                InpShowNeonInPanel   = true;  // 面板显示 Neon 数据
input bool                InpPreferChartNeon   = true;  // 优先读取图表已挂 Neon
input string              InpNeonIndicatorPath = "Market\\NeonTrend"; // iCustom 路径
input int                 InpNeonRsiPeriod     = 14;
input int                 InpNeonSmoothPeriod  = 5;
input ENUM_APPLIED_PRICE  InpNeonAppliedPrice  = PRICE_CLOSE;
input bool                InpNeonShowDashboard = true;
input color               InpNeonBullishColor  = clrDeepSkyBlue;
input color               InpNeonBearishColor  = clrHotPink;
input color               InpNeonTextColor     = clrWhite;
input color               InpNeonPanelBgColor  = C'30,30,30';
input int                 InpNeonFontSize      = 9;

input group "=== 面板 ==="
input bool   InpShowPanel          = true; // 显示左下角面板
input int    InpPanelBarShift      = 0;    // 面板读值 shift(0=当前K,1=上一根收盘K)
input int    InpPanelX             = 12;   // 面板距左边缘像素
input int    InpPanelY             = 18;   // 面板距下边缘像素
input int    InpFontSize           = 9;    // 字体大小
input color  InpTextColor          = clrWhite;
input color  InpPanelBgColor       = C'30,30,30';
input color  InpSleepColor         = clrSilver;
input color  InpAwakenColor        = clrGold;
input color  InpEatBullColor       = clrDeepSkyBlue;
input color  InpEatBearColor       = clrHotPink;
input color  InpUnknownColor       = clrGray;

input group "=== 邮件提醒 ==="
input bool   InpEnableMail             = true;  // 启用条件满足邮件
input string InpMailSubjectPrefix      = "[myAlligator]"; // 邮件标题前缀
input int    InpMailBarShift           = 1;     // 判定用K线 shift(1=已收盘K)
input int    InpMailCooldownSeconds    = 300;   // 同方向邮件最小间隔(秒)
input bool   InpMailOnEdgeOnly         = true;  // 仅条件由假变真时发送
input bool   InpMailSendTestOnInit     = true;  // 启动时发全量状态邮件
input bool   InpEnableExitMail         = true;  // 发过进仓提醒后监测离场并邮件

input group "=== 前波段止损参考 ==="
input int    InpWaveLookbackBars       = 300;   // 波段扫描回看K数
input bool   InpShowSlOnChart          = true;  // 图表标注止损参考价
input color  InpSlLongLineColor        = clrDeepSkyBlue; // 做多参考线(前波峰K最低价)
input color  InpSlShortLineColor       = clrHotPink;     // 做空参考线(前波峰K最高价)

#define MYALG_PREFIX "MYALG_"
#define MYALG_TITLE  MYALG_PREFIX "Title"
#define MYALG_JAW    MYALG_PREFIX "Jaw"
#define MYALG_TEETH  MYALG_PREFIX "Teeth"
#define MYALG_LIPS   MYALG_PREFIX "Lips"
#define MYALG_STATE  MYALG_PREFIX "State"
#define MYALG_SPREAD MYALG_PREFIX "Spread"
#define MYALG_NEON_SEP   MYALG_PREFIX "NeonSep"
#define MYALG_NEON_COLOR MYALG_PREFIX "NeonColor"
#define MYALG_NEON_HIST  MYALG_PREFIX "NeonHist"
#define MYALG_NEON_SIG   MYALG_PREFIX "NeonSig"
#define MYALG_NEON_SL_L  MYALG_PREFIX "NeonSlLong"
#define MYALG_NEON_SL_S  MYALG_PREFIX "NeonSlShort"
#define MYALG_SL_HLINE_L MYALG_PREFIX "SlHLineLong"
#define MYALG_SL_HLINE_S MYALG_PREFIX "SlHLineShort"
#define MYALG_SL_LBL_L   MYALG_PREFIX "SlLblLong"
#define MYALG_SL_LBL_S   MYALG_PREFIX "SlLblShort"
#define MYALG_MAIL_SEP   MYALG_PREFIX "MailSep"
#define MYALG_MAIL_LONG  MYALG_PREFIX "MailLong"
#define MYALG_MAIL_SHORT MYALG_PREFIX "MailShort"

#define NEON_BUF_HIST    0
#define NEON_BUF_COLOR   1   // 0蓝 1粉(红) 2灰
#define NEON_BUF_SIGNAL  2

#define NEON_COLOR_BLUE  0
#define NEON_COLOR_RED   1
#define NEON_COLOR_GREY  2

enum MyAlgPhase
{
   MYALG_UNKNOWN  = 0,
   MYALG_SLEEP    = 1,
   MYALG_AWAKEN   = 2,
   MYALG_EAT_BULL = 3,
   MYALG_EAT_BEAR = 4
};

double g_jawBuffer[];
double g_teethBuffer[];
double g_lipsBuffer[];

int g_maJaw   = INVALID_HANDLE;
int g_maTeeth = INVALID_HANDLE;
int g_maLips  = INVALID_HANDLE;
int g_atrHandle = INVALID_HANDLE;
int g_alligatorExitHandle = INVALID_HANDLE; // iAlligator(含位移)用于收盘vs唇线离场判定

int  g_neonHandle    = INVALID_HANDLE;
bool g_ownNeonHandle = false;
int  g_panelTotalRows = 0;

datetime g_lastMailBarTime    = 0;
datetime g_lastLongMailAt     = 0;
datetime g_lastShortMailAt    = 0;
bool     g_prevLongMailSignal = false;
bool     g_prevShortMailSignal = false;
bool     g_armedLongMail  = false;  // 已发「可做多」邮件，监测离场
bool     g_armedShortMail = false;  // 已发「可做空」邮件，监测离场

struct MyAlgPrevWavePeak
{
   bool     valid;
   int      waveColor;
   int      peakShift;
   double   peakHist;
   datetime barTime;
   double   barHigh;
   double   barLow;
   double   slPrice;
};

MyAlgPrevWavePeak g_lastLongSlPeak;
MyAlgPrevWavePeak g_lastShortSlPeak;

//+------------------------------------------------------------------+
bool MyAlgLineValid(const double v)
{
   return (v != EMPTY_VALUE && v != 0.0 && MathIsValidNumber(v));
}

//+------------------------------------------------------------------+
double MyAlgSpread(const double jaw, const double teeth, const double lips)
{
   const double hi = MathMax(jaw, MathMax(teeth, lips));
   const double lo = MathMin(jaw, MathMin(teeth, lips));
   return hi - lo;
}

//+------------------------------------------------------------------+
MyAlgPhase MyAlgClassify(const double jaw, const double teeth, const double lips,
                         const double atr)
{
   if(!MyAlgLineValid(jaw) || !MyAlgLineValid(teeth) || !MyAlgLineValid(lips))
      return MYALG_UNKNOWN;
   if(!MathIsValidNumber(atr) || atr <= 0.0)
      return MYALG_UNKNOWN;

   const double spread = MyAlgSpread(jaw, teeth, lips);
   if(spread <= InpSleepSpreadAtrMult * atr)
      return MYALG_SLEEP;

   if(spread >= InpEatSpreadAtrMult * atr)
   {
      if(lips > teeth && teeth > jaw)
         return MYALG_EAT_BULL;
      if(lips < teeth && teeth < jaw)
         return MYALG_EAT_BEAR;
   }
   return MYALG_AWAKEN;
}

//+------------------------------------------------------------------+
string MyAlgPhaseText(const MyAlgPhase p)
{
   if(p == MYALG_SLEEP)    return "睡眠";
   if(p == MYALG_AWAKEN)   return "醒来";
   if(p == MYALG_EAT_BULL) return "进食(多)";
   if(p == MYALG_EAT_BEAR) return "进食(空)";
   return "未知";
}

//+------------------------------------------------------------------+
color MyAlgPhaseColor(const MyAlgPhase p)
{
   if(p == MYALG_SLEEP)    return InpSleepColor;
   if(p == MYALG_AWAKEN)   return InpAwakenColor;
   if(p == MYALG_EAT_BULL) return InpEatBullColor;
   if(p == MYALG_EAT_BEAR) return InpEatBearColor;
   return InpUnknownColor;
}

//+------------------------------------------------------------------+
bool MyAlgObjectExists(const string name)
{
   return ObjectFind(0, name) >= 0;
}

//+------------------------------------------------------------------+
// 左下角锚点：yRow=0 为面板顶行，行号越大越靠近图表底边
int MyAlgPanelYDistance(const int yRowFromTop)
{
   const int rowH = InpFontSize + 6;
   if(g_panelTotalRows <= 1)
      return InpPanelY;
   return InpPanelY + (g_panelTotalRows - 1 - yRowFromTop) * rowH;
}

//+------------------------------------------------------------------+
int MyAlgCountPanelRows(const int sh)
{
   int rows = 6;
   if(InpEnableMail)
      rows += 3;

   if(!InpShowNeonInPanel)
      return rows;

   rows += 1;
   double hist = 0.0, sig = 0.0;
   int barColor = -1;
   if(g_neonHandle != INVALID_HANDLE && MyAlgReadNeon(sh, hist, sig, barColor))
   {
      rows += 3;
      if(g_lastLongSlPeak.valid || g_lastShortSlPeak.valid)
         rows += 2;
   }
   else
      rows += 1;
   return rows;
}

//+------------------------------------------------------------------+
void MyAlgCreateOrUpdateLabel(const string name, const int yRow,
                              const string text, const color bg, const color fg)
{
   if(!MyAlgObjectExists(name))
   {
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
         return;
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }

   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, MyAlgPanelYDistance(yRow));
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Microsoft YaHei");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
}

//+------------------------------------------------------------------+
void MyAlgDeletePanel()
{
   const string names[] =
   {
      MYALG_TITLE, MYALG_JAW, MYALG_TEETH, MYALG_LIPS, MYALG_STATE, MYALG_SPREAD,
      MYALG_NEON_SEP, MYALG_NEON_COLOR, MYALG_NEON_HIST, MYALG_NEON_SIG,
      MYALG_NEON_SL_L, MYALG_NEON_SL_S,
      MYALG_MAIL_SEP, MYALG_MAIL_LONG, MYALG_MAIL_SHORT
   };
   for(int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, names[i]);
}

//+------------------------------------------------------------------+
bool MyAlgIsNeonName(const string name)
{
   string s = name;
   StringToLower(s);
   return (StringFind(s, "neon") >= 0 && StringFind(s, "trend") >= 0);
}

//+------------------------------------------------------------------+
int MyAlgFindChartNeon()
{
   const int winMax = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int w = 0; w < winMax; w++)
   {
      const int n = ChartIndicatorsTotal(0, w);
      for(int i = 0; i < n; i++)
      {
         const string shortName = ChartIndicatorName(0, w, i);
         if(shortName == "" || !MyAlgIsNeonName(shortName))
            continue;
         ResetLastError();
         const int h = ChartIndicatorGet(0, w, shortName);
         if(h != INVALID_HANDLE)
            return h;
      }
   }
   return INVALID_HANDLE;
}

//+------------------------------------------------------------------+
int MyAlgCreateNeonICustom(const string indPath)
{
   ResetLastError();
   const int h = iCustom(_Symbol, _Period, indPath,
                         InpNeonRsiPeriod,
                         InpNeonSmoothPeriod,
                         InpNeonAppliedPrice,
                         InpNeonShowDashboard,
                         InpNeonBullishColor,
                         InpNeonBearishColor,
                         InpNeonTextColor,
                         InpNeonPanelBgColor,
                         InpNeonFontSize);
   if(h == INVALID_HANDLE)
      return INVALID_HANDLE;
   g_ownNeonHandle = true;
   return h;
}

//+------------------------------------------------------------------+
int MyAlgResolveNeonHandle()
{
   if(g_neonHandle != INVALID_HANDLE && !g_ownNeonHandle)
      return g_neonHandle;

   if(g_ownNeonHandle && g_neonHandle != INVALID_HANDLE)
      IndicatorRelease(g_neonHandle);
   g_neonHandle = INVALID_HANDLE;
   g_ownNeonHandle = false;

   if(InpPreferChartNeon)
   {
      g_neonHandle = MyAlgFindChartNeon();
      if(g_neonHandle != INVALID_HANDLE)
         return g_neonHandle;
   }

   const string paths[] =
   {
      InpNeonIndicatorPath,
      "Market\\NeonTrend",
      "NeonTrend"
   };
   for(int i = 0; i < ArraySize(paths); i++)
   {
      if(paths[i] == "")
         continue;
      g_neonHandle = MyAlgCreateNeonICustom(paths[i]);
      if(g_neonHandle != INVALID_HANDLE)
      {
         Print("myAlligator: Neon iCustom OK path=", paths[i], " h=", g_neonHandle);
         return g_neonHandle;
      }
   }
   return INVALID_HANDLE;
}

//+------------------------------------------------------------------+
void MyAlgReleaseNeon()
{
   if(g_neonHandle == INVALID_HANDLE)
      return;
   if(g_ownNeonHandle)
      IndicatorRelease(g_neonHandle);
   g_neonHandle = INVALID_HANDLE;
   g_ownNeonHandle = false;
}

//+------------------------------------------------------------------+
int MyAlgNeonColorFromBuffer(const double colorRaw)
{
   if(colorRaw == EMPTY_VALUE)
      return -1;
   const int c = (int)MathRound(colorRaw);
   if(c < 0 || c > 2)
      return -1;
   return c;
}

//+------------------------------------------------------------------+
int MyAlgNeonDeriveBarColor(const double hist, const double sig)
{
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE)
      return NEON_COLOR_GREY;
   if(MathAbs(hist - sig) <= 1e-9 * MathMax(1.0, MathMax(MathAbs(hist), MathAbs(sig))))
   {
      if(hist > 1e-4)  return NEON_COLOR_BLUE;
      if(hist < -1e-4) return NEON_COLOR_RED;
      return NEON_COLOR_GREY;
   }
   if(hist > 0.0 && hist > sig) return NEON_COLOR_BLUE;
   if(hist < 0.0 && hist < sig) return NEON_COLOR_RED;
   return NEON_COLOR_GREY;
}

//+------------------------------------------------------------------+
int MyAlgNeonResolveBarColor(const double colorRaw, const double hist, const double sig)
{
   const int buf = MyAlgNeonColorFromBuffer(colorRaw);
   if(buf >= 0)
      return buf;
   return MyAlgNeonDeriveBarColor(hist, sig);
}

//+------------------------------------------------------------------+
string MyAlgNeonBarColorText(const int barColor)
{
   if(barColor == NEON_COLOR_BLUE) return "蓝柱";
   if(barColor == NEON_COLOR_RED)  return "红柱";
   if(barColor == NEON_COLOR_GREY) return "灰柱";
   return "未知";
}

//+------------------------------------------------------------------+
color MyAlgNeonBarColorFg(const int barColor)
{
   if(barColor == NEON_COLOR_BLUE) return InpNeonBullishColor;
   if(barColor == NEON_COLOR_RED)  return InpNeonBearishColor;
   return clrSilver;
}

//+------------------------------------------------------------------+
bool MyAlgReadNeon(const int shift, double &hist, double &sig, int &barColor)
{
   hist = EMPTY_VALUE;
   sig  = EMPTY_VALUE;
   barColor = -1;

   if(g_neonHandle == INVALID_HANDLE)
      return false;
   if(BarsCalculated(g_neonHandle) <= shift)
      return false;

   double bHist[], bSig[], bClr[];
   ArraySetAsSeries(bHist, true);
   ArraySetAsSeries(bSig, true);
   ArraySetAsSeries(bClr, true);

   if(CopyBuffer(g_neonHandle, NEON_BUF_HIST,   shift, 1, bHist) != 1) return false;
   if(CopyBuffer(g_neonHandle, NEON_BUF_SIGNAL, shift, 1, bSig)  != 1) return false;
   CopyBuffer(g_neonHandle, NEON_BUF_COLOR, shift, 1, bClr);

   hist = bHist[0];
   sig  = bSig[0];
   if(hist == EMPTY_VALUE || sig == EMPTY_VALUE || !MathIsValidNumber(hist) || !MathIsValidNumber(sig))
      return false;

   const double colorRaw = (ArraySize(bClr) == 1 ? bClr[0] : EMPTY_VALUE);
   barColor = MyAlgNeonResolveBarColor(colorRaw, hist, sig);
   return true;
}

//+------------------------------------------------------------------+
int MyAlgNeonBarColorAtShift(const int shift, double &hist, double &sig)
{
   int barColor = -1;
   if(!MyAlgReadNeon(shift, hist, sig, barColor))
      return -1;
   return barColor;
}

//+------------------------------------------------------------------+
// 当前蓝柱→前红柱整段K线最低价；当前红柱→前蓝柱整段K线最高价
bool MyAlgFindOppositeWaveSl(const int anchorShift, const bool forLongSl, MyAlgPrevWavePeak &out)
{
   out.valid = false;
   out.waveColor = -1;
   out.peakShift = -1;
   out.peakHist = 0.0;
   out.barTime = 0;
   out.barHigh = 0.0;
   out.barLow = 0.0;
   out.slPrice = 0.0;

   if(g_neonHandle == INVALID_HANDLE || anchorShift < 0)
      return false;

   const int lookback = MathMax(20, InpWaveLookbackBars);
   double bHist[], bSig[], bClr[];
   ArraySetAsSeries(bHist, true);
   ArraySetAsSeries(bSig, true);
   ArraySetAsSeries(bClr, true);

   if(CopyBuffer(g_neonHandle, NEON_BUF_HIST,   anchorShift, lookback, bHist) <= 0)
      return false;
   if(CopyBuffer(g_neonHandle, NEON_BUF_SIGNAL, anchorShift, lookback, bSig) <= 0)
      return false;
   CopyBuffer(g_neonHandle, NEON_BUF_COLOR, anchorShift, lookback, bClr);

   const int n = ArraySize(bHist);
   if(n < 5)
      return false;

   int colors[];
   ArrayResize(colors, n);
   for(int i = 0; i < n; i++)
   {
      const double colorRaw = (i < ArraySize(bClr) ? bClr[i] : EMPTY_VALUE);
      colors[i] = MyAlgNeonResolveBarColor(colorRaw, bHist[i], bSig[i]);
   }

   const int curColor = colors[0];
   const int targetColor = forLongSl ? NEON_COLOR_RED : NEON_COLOR_BLUE;
   const int needCurColor = forLongSl ? NEON_COLOR_BLUE : NEON_COLOR_RED;

   if(curColor != needCurColor)
      return false;

   int waveEndIdx = 0;
   while(waveEndIdx + 1 < n && colors[waveEndIdx + 1] == curColor)
      waveEndIdx++;

   int p = waveEndIdx + 1;
   int waveStartIdx = -1;
   int waveEndTargetIdx = -1;

   while(p < n)
   {
      while(p < n && colors[p] != targetColor)
         p++;
      if(p >= n)
         break;
      waveStartIdx = p;
      while(p < n && colors[p] == targetColor)
         p++;
      waveEndTargetIdx = p - 1;
      break;
   }

   if(waveStartIdx < 0 || waveEndTargetIdx < waveStartIdx)
      return false;

   if(forLongSl)
   {
      double minLow = DBL_MAX;
      int extIdx = waveStartIdx;
      for(int i = waveStartIdx; i <= waveEndTargetIdx; i++)
      {
         const int sh = anchorShift + i;
         const double lo = iLow(_Symbol, _Period, sh);
         if(lo > 0.0 && lo < minLow)
         {
            minLow = lo;
            extIdx = i;
         }
      }
      if(minLow >= DBL_MAX)
         return false;

      const int extShift = anchorShift + extIdx;
      out.valid = true;
      out.waveColor = targetColor;
      out.peakShift = extShift;
      out.peakHist = bHist[extIdx];
      out.barTime = iTime(_Symbol, _Period, extShift);
      out.barHigh = iHigh(_Symbol, _Period, extShift);
      out.barLow = minLow;
      out.slPrice = minLow;
      return true;
   }

   double maxHigh = -DBL_MAX;
   int extIdx = waveStartIdx;
   for(int i = waveStartIdx; i <= waveEndTargetIdx; i++)
   {
      const int sh = anchorShift + i;
      const double hi = iHigh(_Symbol, _Period, sh);
      if(hi > 0.0 && hi > maxHigh)
      {
         maxHigh = hi;
         extIdx = i;
      }
   }
   if(maxHigh <= -DBL_MAX)
      return false;

   const int extShift = anchorShift + extIdx;
   out.valid = true;
   out.waveColor = targetColor;
   out.peakShift = extShift;
   out.peakHist = bHist[extIdx];
   out.barTime = iTime(_Symbol, _Period, extShift);
   out.barHigh = maxHigh;
   out.barLow = iLow(_Symbol, _Period, extShift);
   out.slPrice = maxHigh;
   return true;
}

//+------------------------------------------------------------------+
string MyAlgPrevWavePeakMailText(const MyAlgPrevWavePeak &pk, const bool forLong)
{
   if(!pk.valid)
      return StringFormat("前%s波段止损: 未识别到(当前柱色不符或历史不足)\n",
                          (forLong ? "红" : "蓝"));

   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(forLong)
   {
      return StringFormat(
         "前红柱区间止损参考(做多)\n"
         "前波段柱色: %s (共扫描相邻红柱区间)\n"
         "区间最低价: %.*f  (位于 shift=%d)\n"
         "该K时间: %s  hist=%.4f\n"
         "该K高/低: %.*f / %.*f\n",
         MyAlgNeonBarColorText(pk.waveColor),
         digs, pk.slPrice, pk.peakShift,
         TimeToString(pk.barTime, TIME_DATE | TIME_MINUTES), pk.peakHist,
         digs, pk.barHigh, digs, pk.barLow);
   }
   return StringFormat(
      "前蓝柱区间止损参考(做空)\n"
      "前波段柱色: %s (共扫描相邻蓝柱区间)\n"
      "区间最高价: %.*f  (位于 shift=%d)\n"
      "该K时间: %s  hist=%.4f\n"
      "该K高/低: %.*f / %.*f\n",
      MyAlgNeonBarColorText(pk.waveColor),
      digs, pk.slPrice, pk.peakShift,
      TimeToString(pk.barTime, TIME_DATE | TIME_MINUTES), pk.peakHist,
      digs, pk.barHigh, digs, pk.barLow);
}

//+------------------------------------------------------------------+
void MyAlgDeleteSlChartMarks()
{
   ObjectDelete(0, MYALG_SL_HLINE_L);
   ObjectDelete(0, MYALG_SL_HLINE_S);
   ObjectDelete(0, MYALG_SL_LBL_L);
   ObjectDelete(0, MYALG_SL_LBL_S);
}

//+------------------------------------------------------------------+
void MyAlgDrawSlHLine(const string name, const double price, const color clr,
                      const ENUM_LINE_STYLE style)
{
   if(price <= 0.0 || !MathIsValidNumber(price))
   {
      ObjectDelete(0, name);
      return;
   }

   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
         return;
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

//+------------------------------------------------------------------+
void MyAlgDrawSlLabel(const string name, const datetime t, const double price,
                      const string text, const color clr)
{
   if(price <= 0.0 || !MathIsValidNumber(price))
   {
      ObjectDelete(0, name);
      return;
   }

   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
         return;
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   }
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Microsoft YaHei");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
void MyAlgUpdateSlChartMarks(const int anchorShift)
{
   if(!InpShowSlOnChart)
   {
      MyAlgDeleteSlChartMarks();
      return;
   }

   if(g_lastLongSlPeak.valid)
   {
      const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      MyAlgDrawSlHLine(MYALG_SL_HLINE_L, g_lastLongSlPeak.slPrice, InpSlLongLineColor, STYLE_DASH);
      MyAlgDrawSlLabel(MYALG_SL_LBL_L, g_lastLongSlPeak.barTime, g_lastLongSlPeak.slPrice,
                       StringFormat("多SL %.*f (前红柱区间最低)",
                                    digs, g_lastLongSlPeak.slPrice),
                       InpSlLongLineColor);
   }
   else
   {
      ObjectDelete(0, MYALG_SL_HLINE_L);
      ObjectDelete(0, MYALG_SL_LBL_L);
   }

   if(g_lastShortSlPeak.valid)
   {
      const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      MyAlgDrawSlHLine(MYALG_SL_HLINE_S, g_lastShortSlPeak.slPrice, InpSlShortLineColor, STYLE_DASH);
      MyAlgDrawSlLabel(MYALG_SL_LBL_S, g_lastShortSlPeak.barTime, g_lastShortSlPeak.slPrice,
                       StringFormat("空SL %.*f (前蓝柱区间最高)",
                                    digs, g_lastShortSlPeak.slPrice),
                       InpSlShortLineColor);
   }
   else
   {
      ObjectDelete(0, MYALG_SL_HLINE_S);
      ObjectDelete(0, MYALG_SL_LBL_S);
   }
}

//+------------------------------------------------------------------+
void MyAlgRefreshPrevWavePeaks(const int anchorShift)
{
   g_lastLongSlPeak.valid = false;
   g_lastShortSlPeak.valid = false;
   if(g_neonHandle == INVALID_HANDLE)
      return;

   double hist = 0.0, sig = 0.0;
   int curColor = -1;
   if(!MyAlgReadNeon(anchorShift, hist, sig, curColor))
      return;

   if(curColor == NEON_COLOR_BLUE)
      MyAlgFindOppositeWaveSl(anchorShift, true, g_lastLongSlPeak);
   if(curColor == NEON_COLOR_RED)
      MyAlgFindOppositeWaveSl(anchorShift, false, g_lastShortSlPeak);

   MyAlgUpdateSlChartMarks(anchorShift);
}

//+------------------------------------------------------------------+
bool MyAlgPhaseAllowsLongMail(const MyAlgPhase p)
{
   return (p == MYALG_AWAKEN || p == MYALG_EAT_BULL);
}

//+------------------------------------------------------------------+
bool MyAlgPhaseAllowsShortMail(const MyAlgPhase p)
{
   return (p == MYALG_AWAKEN || p == MYALG_EAT_BEAR);
}

//+------------------------------------------------------------------+
bool MyAlgEvalLongMailSignal(const int shift, MyAlgPhase &phase,
                             double &hist, double &sig, int &barColor)
{
   phase = MYALG_UNKNOWN;
   hist = 0.0;
   sig = 0.0;
   barColor = -1;

   double jaw = 0.0, teeth = 0.0, lips = 0.0, atr = 0.0;
   if(!MyAlgReadLines(shift, jaw, teeth, lips) || !MyAlgReadAtr(shift, atr))
      return false;

   phase = MyAlgClassify(jaw, teeth, lips, atr);
   if(!MyAlgPhaseAllowsLongMail(phase))
      return false;

   if(!MyAlgReadNeon(shift, hist, sig, barColor))
      return false;
   if(barColor != NEON_COLOR_BLUE)
      return false;

   return (hist > sig);
}

//+------------------------------------------------------------------+
bool MyAlgEvalShortMailSignal(const int shift, MyAlgPhase &phase,
                              double &hist, double &sig, int &barColor)
{
   phase = MYALG_UNKNOWN;
   hist = 0.0;
   sig = 0.0;
   barColor = -1;

   double jaw = 0.0, teeth = 0.0, lips = 0.0, atr = 0.0;
   if(!MyAlgReadLines(shift, jaw, teeth, lips) || !MyAlgReadAtr(shift, atr))
      return false;

   phase = MyAlgClassify(jaw, teeth, lips, atr);
   if(!MyAlgPhaseAllowsShortMail(phase))
      return false;

   if(!MyAlgReadNeon(shift, hist, sig, barColor))
      return false;
   if(barColor != NEON_COLOR_RED)
      return false;

   return (hist < sig);
}

//+------------------------------------------------------------------+
bool MyAlgSendMail(const string subject, const string body)
{
   const string title = InpMailSubjectPrefix + " " + subject;
   if(!SendMail(title, body))
   {
      Print("myAlligator SendMail 失败 err=", GetLastError(), " title=", title);
      return false;
   }
   Print("myAlligator 已发邮件: ", title);
   return true;
}

//+------------------------------------------------------------------+
string MyAlgBuildSignalMailBody(const string action,
                                const int shift,
                                const MyAlgPhase phase,
                                const double jaw,
                                const double teeth,
                                const double lips,
                                const double hist,
                                const double sig,
                                const int barColor,
                                const MyAlgPrevWavePeak &slPeak,
                                const bool forLong)
{
   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const datetime barTime = iTime(_Symbol, _Period, shift);
   return StringFormat(
      "【myAlligator 交易条件提醒】\n"
      "结论: %s\n"
      "品种: %s  周期: %s\n"
      "K线时间(shift=%d): %s\n\n"
      "鳄鱼状态: %s\n"
      "颚: %.*f  齿: %.*f  唇: %.*f\n\n"
      "NeonTrend(当前)\n"
      "柱色: %s\n"
      "柱值(hist): %.4f\n"
      "信号线(sig): %.4f\n"
      "关系: hist %s sig\n\n"
      "%s\n"
      "说明: 本邮件由指标自动发送，非下单指令；请结合风控自行决策。",
      action,
      _Symbol,
      EnumToString(_Period),
      shift,
      TimeToString(barTime, TIME_DATE | TIME_MINUTES),
      MyAlgPhaseText(phase),
      digs, jaw, digs, teeth, digs, lips,
      MyAlgNeonBarColorText(barColor),
      hist, sig,
      (hist > sig ? ">" : (hist < sig ? "<" : "=")),
      MyAlgPrevWavePeakMailText(slPeak, forLong));
}

//+------------------------------------------------------------------+
string MyAlgBuildInitMailBody(const int shift)
{
   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double jaw = 0.0, teeth = 0.0, lips = 0.0, atr = 0.0;
   MyAlgPhase phase = MYALG_UNKNOWN;
   if(MyAlgReadLines(shift, jaw, teeth, lips) && MyAlgReadAtr(shift, atr))
      phase = MyAlgClassify(jaw, teeth, lips, atr);

   double hist = 0.0, sig = 0.0;
   int barColor = -1;
   const bool neonOk = MyAlgReadNeon(shift, hist, sig, barColor);

   MyAlgPhase phaseL = MYALG_UNKNOWN, phaseS = MYALG_UNKNOWN;
   double histL = 0.0, sigL = 0.0, histS = 0.0, sigS = 0.0;
   int bcL = -1, bcS = -1;
   const bool longSig  = MyAlgEvalLongMailSignal(shift, phaseL, histL, sigL, bcL);
   const bool shortSig = MyAlgEvalShortMailSignal(shift, phaseS, histS, sigS, bcS);

   MyAlgPrevWavePeak pkL, pkS;
   double h0 = 0.0, s0 = 0.0;
   int c0 = -1;
   if(MyAlgReadNeon(shift, h0, s0, c0))
   {
      if(c0 == NEON_COLOR_BLUE)
         MyAlgFindOppositeWaveSl(shift, true, pkL);
      if(c0 == NEON_COLOR_RED)
         MyAlgFindOppositeWaveSl(shift, false, pkS);
   }

   string neonBlock = "NeonTrend: 未连接\n";
   if(neonOk)
   {
      neonBlock = StringFormat(
         "NeonTrend(shift=%d)\n"
         "柱色: %s\n"
         "柱值(hist): %.4f\n"
         "信号线(sig): %.4f\n"
         "关系: hist %s sig\n",
         shift,
         MyAlgNeonBarColorText(barColor),
         hist, sig,
         (hist > sig ? ">" : (hist < sig ? "<" : "=")));
   }

   return StringFormat(
      "【myAlligator 启动状态报告】\n"
      "指标已加载，SMTP 通道测试。\n"
      "品种: %s  周期: %s\n"
      "报告K线(shift=%d): %s\n\n"
      "鳄鱼状态: %s\n"
      "颚: %.*f  齿: %.*f  唇: %.*f\n\n"
      "%s\n"
      "邮件条件(当前K):\n"
      "可做多: %s\n"
      "可做空: %s\n"
      "进仓监测: 多=%s 空=%s\n\n"
      "%s\n"
      "%s\n"
      "图表: 蓝虚线=前红柱区间最低(当前蓝柱时) 粉虚线=前蓝柱区间最高(当前红柱时)\n",
      _Symbol,
      EnumToString(_Period),
      shift,
      TimeToString(iTime(_Symbol, _Period, shift), TIME_DATE | TIME_MINUTES),
      MyAlgPhaseText(phase),
      digs, jaw, digs, teeth, digs, lips,
      neonBlock,
      (longSig ? "是" : "否"),
      (shortSig ? "是" : "否"),
      (g_armedLongMail ? "监测离场中" : "无"),
      (g_armedShortMail ? "监测离场中" : "无"),
      MyAlgPrevWavePeakMailText(pkL, true),
      MyAlgPrevWavePeakMailText(pkS, false));
}

//+------------------------------------------------------------------+
void MyAlgCheckMailSignals()
{
   if(!InpEnableMail)
      return;

   if(g_neonHandle == INVALID_HANDLE)
      MyAlgResolveNeonHandle();
   if(g_neonHandle == INVALID_HANDLE)
      return;

   const int sh = (InpMailBarShift < 0 ? 0 : InpMailBarShift);
   const datetime barTime = iTime(_Symbol, _Period, sh);
   if(barTime == 0)
      return;

   if(barTime == g_lastMailBarTime)
      return;
   g_lastMailBarTime = barTime;

   MyAlgCheckExitMails(sh);

   MyAlgPhase phaseL = MYALG_UNKNOWN, phaseS = MYALG_UNKNOWN;
   double histL = 0.0, sigL = 0.0, histS = 0.0, sigS = 0.0;
   int barColorL = -1, barColorS = -1;
   const bool longNow  = MyAlgEvalLongMailSignal(sh, phaseL, histL, sigL, barColorL);
   const bool shortNow = MyAlgEvalShortMailSignal(sh, phaseS, histS, sigS, barColorS);

   const datetime now = TimeCurrent();

   if(longNow)
   {
      const bool edgeOk = (!InpMailOnEdgeOnly || !g_prevLongMailSignal);
      const bool coolOk = (g_lastLongMailAt == 0 ||
                           (now - g_lastLongMailAt) >= InpMailCooldownSeconds);
      if(edgeOk && coolOk)
      {
         double jaw = 0.0, teeth = 0.0, lips = 0.0;
         MyAlgReadLines(sh, jaw, teeth, lips);
         MyAlgPrevWavePeak pk;
         MyAlgFindOppositeWaveSl(sh, true, pk);
         g_lastLongSlPeak = pk;
         MyAlgUpdateSlChartMarks(sh);
         const string body = MyAlgBuildSignalMailBody(
            "有条件做多",
            sh, phaseL, jaw, teeth, lips, histL, sigL, barColorL, pk, true);
         if(MyAlgSendMail("可做多", body))
         {
            g_lastLongMailAt = now;
            g_armedLongMail = true;
         }
      }
   }

   if(shortNow)
   {
      const bool edgeOk = (!InpMailOnEdgeOnly || !g_prevShortMailSignal);
      const bool coolOk = (g_lastShortMailAt == 0 ||
                           (now - g_lastShortMailAt) >= InpMailCooldownSeconds);
      if(edgeOk && coolOk)
      {
         double jaw = 0.0, teeth = 0.0, lips = 0.0;
         MyAlgReadLines(sh, jaw, teeth, lips);
         MyAlgPrevWavePeak pk;
         MyAlgFindOppositeWaveSl(sh, false, pk);
         g_lastShortSlPeak = pk;
         MyAlgUpdateSlChartMarks(sh);
         const string body = MyAlgBuildSignalMailBody(
            "有条件做空",
            sh, phaseS, jaw, teeth, lips, histS, sigS, barColorS, pk, false);
         if(MyAlgSendMail("可做空", body))
         {
            g_lastShortMailAt = now;
            g_armedShortMail = true;
         }
      }
   }

   g_prevLongMailSignal  = longNow;
   g_prevShortMailSignal = shortNow;
}

//+------------------------------------------------------------------+
void MyAlgUpdateMailArmPanelRows(const int rowStart, int &nextRow)
{
   nextRow = rowStart;
   if(!InpEnableMail)
   {
      ObjectDelete(0, MYALG_MAIL_SEP);
      ObjectDelete(0, MYALG_MAIL_LONG);
      ObjectDelete(0, MYALG_MAIL_SHORT);
      return;
   }

   MyAlgCreateOrUpdateLabel(MYALG_MAIL_SEP, nextRow++,
                            "── 进仓邮件状态 ──", InpPanelBgColor, InpTextColor);

   string longTxt = "多单: 暂无多单";
   color longFg = InpTextColor;
   if(g_armedLongMail)
   {
      longTxt = "多单: 已发进仓邮件(监测离场)";
      longFg = InpEatBullColor;
   }

   string shortTxt = "空单: 暂无空单";
   color shortFg = InpTextColor;
   if(g_armedShortMail)
   {
      shortTxt = "空单: 已发进仓邮件(监测离场)";
      shortFg = InpEatBearColor;
   }

   if(!g_armedLongMail && !g_armedShortMail)
   {
      MyAlgCreateOrUpdateLabel(MYALG_MAIL_LONG, nextRow++,
                               "进仓监测: 暂无多空单", InpPanelBgColor, InpTextColor);
      ObjectDelete(0, MYALG_MAIL_SHORT);
      return;
   }

   MyAlgCreateOrUpdateLabel(MYALG_MAIL_LONG, nextRow++, longTxt, InpPanelBgColor, longFg);
   MyAlgCreateOrUpdateLabel(MYALG_MAIL_SHORT, nextRow++, shortTxt, InpPanelBgColor, shortFg);
}

//+------------------------------------------------------------------+
void MyAlgUpdateNeonPanelRows(const int rowStart, int &nextRow)
{
   nextRow = rowStart;
   if(!InpShowNeonInPanel)
   {
      ObjectDelete(0, MYALG_NEON_SEP);
      ObjectDelete(0, MYALG_NEON_COLOR);
      ObjectDelete(0, MYALG_NEON_HIST);
      ObjectDelete(0, MYALG_NEON_SIG);
      return;
   }

   const int sh = (InpPanelBarShift < 0 ? 0 : InpPanelBarShift);
   double hist = 0.0, sig = 0.0;
   int barColor = -1;
   const bool neonOk = MyAlgReadNeon(sh, hist, sig, barColor);

   MyAlgCreateOrUpdateLabel(MYALG_NEON_SEP, nextRow++,
                            "── Neon Trend ──", InpPanelBgColor, InpTextColor);

   if(!neonOk)
   {
      MyAlgCreateOrUpdateLabel(MYALG_NEON_COLOR, nextRow++,
                               "Neon: 未连接(请同图挂指标)", InpUnknownColor, InpTextColor);
      ObjectDelete(0, MYALG_NEON_HIST);
      ObjectDelete(0, MYALG_NEON_SIG);
      return;
   }

   const color barFg = MyAlgNeonBarColorFg(barColor);
   MyAlgCreateOrUpdateLabel(MYALG_NEON_COLOR, nextRow++,
                            "柱色: " + MyAlgNeonBarColorText(barColor),
                            InpPanelBgColor, barFg);
   MyAlgCreateOrUpdateLabel(MYALG_NEON_HIST, nextRow++,
                            StringFormat("柱值(hist): %.4f", hist),
                            InpPanelBgColor, barFg);
   MyAlgCreateOrUpdateLabel(MYALG_NEON_SIG, nextRow++,
                            StringFormat("信号线(sig): %.4f", sig),
                            InpPanelBgColor, InpTextColor);

   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_lastLongSlPeak.valid)
      MyAlgCreateOrUpdateLabel(MYALG_NEON_SL_L, nextRow++,
                               StringFormat("多SL: %.*f (前红柱区间最低)", digs, g_lastLongSlPeak.slPrice),
                               InpPanelBgColor, InpSlLongLineColor);
   else
      ObjectDelete(0, MYALG_NEON_SL_L);

   if(g_lastShortSlPeak.valid)
      MyAlgCreateOrUpdateLabel(MYALG_NEON_SL_S, nextRow++,
                               StringFormat("空SL: %.*f (前蓝柱区间最高)", digs, g_lastShortSlPeak.slPrice),
                               InpPanelBgColor, InpSlShortLineColor);
   else
      ObjectDelete(0, MYALG_NEON_SL_S);
}

//+------------------------------------------------------------------+
bool MyAlgReadLines(const int shift, double &jaw, double &teeth, double &lips)
{
   jaw = 0.0;
   teeth = 0.0;
   lips = 0.0;
   if(shift < 0 || shift >= ArraySize(g_jawBuffer))
      return false;

   jaw   = g_jawBuffer[shift];
   teeth = g_teethBuffer[shift];
   lips  = g_lipsBuffer[shift];
   return MyAlgLineValid(jaw) && MyAlgLineValid(teeth) && MyAlgLineValid(lips);
}

//+------------------------------------------------------------------+
bool MyAlgReadAtr(const int shift, double &atr)
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
// 离场判定用 iAlligator(含位移)，与图表唇线一致
bool MyAlgGetExitAlligator(const int shift, double &jaw, double &teeth, double &lips)
{
   jaw = 0.0;
   teeth = 0.0;
   lips = 0.0;

   if(g_alligatorExitHandle != INVALID_HANDLE)
   {
      double bJ[], bT[], bL[];
      ArraySetAsSeries(bJ, true);
      ArraySetAsSeries(bT, true);
      ArraySetAsSeries(bL, true);
      if(CopyBuffer(g_alligatorExitHandle, 0, shift, 1, bJ) != 1) return false;
      if(CopyBuffer(g_alligatorExitHandle, 1, shift, 1, bT) != 1) return false;
      if(CopyBuffer(g_alligatorExitHandle, 2, shift, 1, bL) != 1) return false;
      jaw = bJ[0];
      teeth = bT[0];
      lips = bL[0];
      return MyAlgLineValid(jaw) && MyAlgLineValid(teeth) && MyAlgLineValid(lips);
   }

   return MyAlgReadLines(shift, jaw, teeth, lips);
}

//+------------------------------------------------------------------+
MyAlgPhase MyAlgClassifyAtShift(const int shift)
{
   double jaw, teeth, lips, atr;
   if(!MyAlgGetExitAlligator(shift, jaw, teeth, lips))
      return MYALG_UNKNOWN;
   if(!MyAlgReadAtr(shift, atr))
      return MYALG_UNKNOWN;
   return MyAlgClassify(jaw, teeth, lips, atr);
}

//+------------------------------------------------------------------+
bool MyAlgCloseBelowLips(const int shift)
{
   const double closePx = iClose(_Symbol, _Period, shift);
   if(closePx <= 0.0)
      return false;
   double jaw, teeth, lips;
   if(!MyAlgGetExitAlligator(shift, jaw, teeth, lips))
      return false;
   if(!MyAlgLineValid(lips))
      return false;
   return (closePx < lips);
}

//+------------------------------------------------------------------+
bool MyAlgCloseAboveLips(const int shift)
{
   const double closePx = iClose(_Symbol, _Period, shift);
   if(closePx <= 0.0)
      return false;
   double jaw, teeth, lips;
   if(!MyAlgGetExitAlligator(shift, jaw, teeth, lips))
      return false;
   if(!MyAlgLineValid(lips))
      return false;
   return (closePx > lips);
}

//+------------------------------------------------------------------+
bool MyAlgEvalExitLong(const int shift, string &reason)
{
   reason = "";
   if(MyAlgClassifyAtShift(shift) == MYALG_SLEEP)
   {
      reason = "鳄鱼睡眠";
      return true;
   }
   if(MyAlgCloseBelowLips(shift))
   {
      double jaw = 0.0, teeth = 0.0, lips = 0.0;
      MyAlgGetExitAlligator(shift, jaw, teeth, lips);
      reason = StringFormat("收盘<唇线 (收=%.5f 唇=%.5f)",
                            iClose(_Symbol, _Period, shift), lips);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool MyAlgEvalExitShort(const int shift, string &reason)
{
   reason = "";
   if(MyAlgClassifyAtShift(shift) == MYALG_SLEEP)
   {
      reason = "鳄鱼睡眠";
      return true;
   }
   if(MyAlgCloseAboveLips(shift))
   {
      double jaw = 0.0, teeth = 0.0, lips = 0.0;
      MyAlgGetExitAlligator(shift, jaw, teeth, lips);
      reason = StringFormat("收盘>唇线 (收=%.5f 唇=%.5f)",
                            iClose(_Symbol, _Period, shift), lips);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
string MyAlgBuildExitMailBody(const bool wasLong, const int shift, const string &reason)
{
   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const MyAlgPhase phase = MyAlgClassifyAtShift(shift);
   double jaw = 0.0, teeth = 0.0, lips = 0.0;
   MyAlgGetExitAlligator(shift, jaw, teeth, lips);
   const double closePx = iClose(_Symbol, _Period, shift);

   return StringFormat(
      "【myAlligator 离场提醒】\n"
      "结论: 可离场(%s方向)\n"
      "触发: %s\n"
      "品种: %s  周期: %s\n"
      "K线(shift=%d): %s\n\n"
      "鳄鱼状态: %s\n"
      "颚: %.*f  齿: %.*f  唇: %.*f\n"
      "收盘: %.*f\n\n"
      "进仓邮件状态已清零，可重新等待新的进仓条件邮件。",
      (wasLong ? "多" : "空"),
      reason,
      _Symbol,
      EnumToString(_Period),
      shift,
      TimeToString(iTime(_Symbol, _Period, shift), TIME_DATE | TIME_MINUTES),
      MyAlgPhaseText(phase),
      digs, jaw, digs, teeth, digs, lips,
      digs, closePx);
}

//+------------------------------------------------------------------+
void MyAlgClearLongMailState()
{
   g_armedLongMail = false;
   g_prevLongMailSignal = false;
}

//+------------------------------------------------------------------+
void MyAlgClearShortMailState()
{
   g_armedShortMail = false;
   g_prevShortMailSignal = false;
}

//+------------------------------------------------------------------+
void MyAlgCheckExitMails(const int sh)
{
   if(!InpEnableMail || !InpEnableExitMail)
      return;

   if(g_armedLongMail)
   {
      string reason = "";
      if(MyAlgEvalExitLong(sh, reason))
      {
         const string body = MyAlgBuildExitMailBody(true, sh, reason);
         if(MyAlgSendMail("可平多(离场)", body))
            MyAlgClearLongMailState();
      }
   }

   if(g_armedShortMail)
   {
      string reason = "";
      if(MyAlgEvalExitShort(sh, reason))
      {
         const string body = MyAlgBuildExitMailBody(false, sh, reason);
         if(MyAlgSendMail("可平空(离场)", body))
            MyAlgClearShortMailState();
      }
   }
}

//+------------------------------------------------------------------+
void MyAlgUpdatePanel()
{
   if(!InpShowPanel)
   {
      MyAlgDeletePanel();
      return;
   }

   const int sh = (InpPanelBarShift < 0 ? 0 : InpPanelBarShift);
   g_panelTotalRows = MyAlgCountPanelRows(sh);

   double jaw = 0.0, teeth = 0.0, lips = 0.0, atr = 0.0;
   const bool ok = MyAlgReadLines(sh, jaw, teeth, lips) && MyAlgReadAtr(sh, atr);
   const MyAlgPhase phase = ok ? MyAlgClassify(jaw, teeth, lips, atr) : MYALG_UNKNOWN;
   const int digs = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const color stateBg = MyAlgPhaseColor(phase);

   MyAlgCreateOrUpdateLabel(MYALG_TITLE, 0, "My Alligator", InpPanelBgColor, InpTextColor);

   int nextRow = 0;
   if(!ok)
   {
      MyAlgCreateOrUpdateLabel(MYALG_JAW,   ++nextRow, "颚: --", InpPanelBgColor, InpTextColor);
      MyAlgCreateOrUpdateLabel(MYALG_TEETH, ++nextRow, "齿: --", InpPanelBgColor, InpTextColor);
      MyAlgCreateOrUpdateLabel(MYALG_LIPS,  ++nextRow, "唇: --", InpPanelBgColor, InpTextColor);
      MyAlgCreateOrUpdateLabel(MYALG_STATE, ++nextRow, "状态: 计算中", InpUnknownColor, InpTextColor);
      MyAlgCreateOrUpdateLabel(MYALG_SPREAD, ++nextRow, "间距: --", InpPanelBgColor, InpTextColor);
      MyAlgUpdateMailArmPanelRows(nextRow + 1, nextRow);
      MyAlgUpdateNeonPanelRows(nextRow + 1, nextRow);
      return;
   }

   const double spread = MyAlgSpread(jaw, teeth, lips);
   nextRow = 0;
   MyAlgCreateOrUpdateLabel(MYALG_JAW, ++nextRow,
                            StringFormat("颚(Jaw):   %.*f", digs, jaw),
                            InpPanelBgColor, clrDeepSkyBlue);
   MyAlgCreateOrUpdateLabel(MYALG_TEETH, ++nextRow,
                            StringFormat("齿(Teeth): %.*f", digs, teeth),
                            InpPanelBgColor, clrRed);
   MyAlgCreateOrUpdateLabel(MYALG_LIPS, ++nextRow,
                            StringFormat("唇(Lips):  %.*f", digs, lips),
                            InpPanelBgColor, clrLime);
   MyAlgCreateOrUpdateLabel(MYALG_STATE, ++nextRow,
                            "状态: " + MyAlgPhaseText(phase),
                            stateBg, InpTextColor);
   MyAlgCreateOrUpdateLabel(MYALG_SPREAD, ++nextRow,
                            StringFormat("间距: %.*f  ATR×%.2f/%.2f",
                                         digs, spread,
                                         InpSleepSpreadAtrMult, InpEatSpreadAtrMult),
                            InpPanelBgColor, InpTextColor);
   MyAlgUpdateMailArmPanelRows(nextRow + 1, nextRow);
   MyAlgUpdateNeonPanelRows(nextRow + 1, nextRow);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpJawPeriod < 1 || InpTeethPeriod < 1 || InpLipsPeriod < 1)
   {
      Print("myAlligator: 周期参数无效");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, g_jawBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, g_teethBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, g_lipsBuffer, INDICATOR_DATA);

   ArraySetAsSeries(g_jawBuffer, true);
   ArraySetAsSeries(g_teethBuffer, true);
   ArraySetAsSeries(g_lipsBuffer, true);

   PlotIndexSetInteger(0, PLOT_SHIFT, InpJawShift);
   PlotIndexSetInteger(1, PLOT_SHIFT, InpTeethShift);
   PlotIndexSetInteger(2, PLOT_SHIFT, InpLipsShift);

   IndicatorSetString(INDICATOR_SHORTNAME,
                        StringFormat("myAlligator(%d/%d/%d)",
                                     InpJawPeriod, InpTeethPeriod, InpLipsPeriod));

   g_maJaw   = iMA(_Symbol, _Period, InpJawPeriod,  0, MODE_SMMA, PRICE_MEDIAN);
   g_maTeeth = iMA(_Symbol, _Period, InpTeethPeriod, 0, MODE_SMMA, PRICE_MEDIAN);
   g_maLips  = iMA(_Symbol, _Period, InpLipsPeriod,  0, MODE_SMMA, PRICE_MEDIAN);
   g_atrHandle = iATR(_Symbol, _Period, MathMax(1, InpAtrPeriod));

   g_alligatorExitHandle = iAlligator(_Symbol, _Period,
                                      InpJawPeriod, InpJawShift,
                                      InpTeethPeriod, InpTeethShift,
                                      InpLipsPeriod, InpLipsShift,
                                      MODE_SMMA, PRICE_MEDIAN);

   if(g_maJaw == INVALID_HANDLE || g_maTeeth == INVALID_HANDLE ||
      g_maLips == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE ||
      g_alligatorExitHandle == INVALID_HANDLE)
   {
      Print("myAlligator: iMA/iATR/iAlligator 初始化失败 err=", GetLastError());
      return INIT_FAILED;
   }

   g_lastMailBarTime = 0;
   g_lastLongMailAt = 0;
   g_lastShortMailAt = 0;
   g_prevLongMailSignal = false;
   g_prevShortMailSignal = false;
   g_armedLongMail = false;
   g_armedShortMail = false;

   if(InpShowNeonInPanel || InpEnableMail)
   {
      g_neonHandle = MyAlgResolveNeonHandle();
      if(g_neonHandle == INVALID_HANDLE)
         Print("myAlligator: 未连接 NeonTrend，请在同图挂 Market\\NeonTrend 或检查 iCustom 路径");
      else if(!g_ownNeonHandle)
         Print("myAlligator: 已连接图表 NeonTrend handle=", g_neonHandle);
   }

   const int initSh = (InpMailBarShift < 0 ? 0 : InpMailBarShift);
   MyAlgRefreshPrevWavePeaks(initSh);

   if(InpEnableMail && InpMailSendTestOnInit)
      MyAlgSendMail("启动状态报告", MyAlgBuildInitMailBody(initSh));

   MyAlgUpdatePanel();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   MyAlgDeletePanel();
   MyAlgDeleteSlChartMarks();
   MyAlgReleaseNeon();
   if(g_maJaw != INVALID_HANDLE)     IndicatorRelease(g_maJaw);
   if(g_maTeeth != INVALID_HANDLE)   IndicatorRelease(g_maTeeth);
   if(g_maLips != INVALID_HANDLE)    IndicatorRelease(g_maLips);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_alligatorExitHandle != INVALID_HANDLE) IndicatorRelease(g_alligatorExitHandle);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < 2)
      return 0;

   if(CopyBuffer(g_maJaw,   0, 0, rates_total, g_jawBuffer)   <= 0 ||
      CopyBuffer(g_maTeeth, 0, 0, rates_total, g_teethBuffer) <= 0 ||
      CopyBuffer(g_maLips,  0, 0, rates_total, g_lipsBuffer)  <= 0)
      return prev_calculated;

   if((InpShowNeonInPanel || InpEnableMail || InpShowSlOnChart) && g_neonHandle == INVALID_HANDLE)
      MyAlgResolveNeonHandle();

   const int panelSh = (InpPanelBarShift < 0 ? 0 : InpPanelBarShift);
   MyAlgRefreshPrevWavePeaks(panelSh);
   MyAlgUpdatePanel();
   MyAlgCheckMailSignals();
   return rates_total;
}

//+------------------------------------------------------------------+
