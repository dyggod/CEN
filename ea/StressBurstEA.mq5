//+------------------------------------------------------------------+
//|                                            StressBurstEA.mq5   |
//|              压力测试：按固定间隔快速连发多笔市价（默认5买5卖）   |
//|  用途：配合 HealthCheckEA + Node + QueueReaderBot 做队列/同步压测 |
//+------------------------------------------------------------------+
#property copyright "CEN stress test"
#property link      ""
#property version   "1.00"

#include <Trade/Trade.mqh>

//--- 输入参数
input int      IntervalSeconds   = 60;       // 触发间隔（秒），默认每分钟一轮
input double   LotPerOrder       = 0.01;     // 每笔手数（请用演示仓可承受手数）
input string   SymbolToTrade     = "";      // 空 = 当前图表品种
input ulong    Magic             = 99001122; // 魔术号，便于批量平仓/识别
input int      BuysPerBurst      = 5;        // 每轮市价买单数量
input int      SellsPerBurst     = 5;        // 每轮市价卖单数量
input bool     BurstOnStart      = false;    // true = 启动后立即打一轮，再按间隔重复
input int      SlippagePoints    = 50;       // 允许滑点（点）

//--- 全局
CTrade g_trade;
string g_sym;
int    g_burstCount = 0;

bool SetupFillingMode()
{
   long mode = SymbolInfoInteger(g_sym, SYMBOL_FILLING_MODE);
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

void FireBurst()
{
   g_burstCount++;
   string baseCmt = StringFormat("STRESS#%d", g_burstCount);
   Print("══════════════════════════════════════════════════════════");
   Print("StressBurstEA 轮次 #", g_burstCount, " | ", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
   Print("品种=", g_sym, " 手数=", DoubleToString(LotPerOrder, 2),
         " 买=", BuysPerBurst, " 卖=", SellsPerBurst);

   int ok = 0, fail = 0;

   // 先连续买，再连续卖（同一轮内无 Sleep，尽量紧凑）
   for(int i = 0; i < BuysPerBurst; i++)
   {
      string cmt = baseCmt + "_B" + IntegerToString(i);
      if(g_trade.Buy(LotPerOrder, g_sym, 0.0, 0.0, 0.0, cmt))
         ok++;
      else
      {
         fail++;
         Print("  Buy[", i, "] 失败 ret=", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      }
   }

   for(int j = 0; j < SellsPerBurst; j++)
   {
      string cmt = baseCmt + "_S" + IntegerToString(j);
      if(g_trade.Sell(LotPerOrder, g_sym, 0.0, 0.0, 0.0, cmt))
         ok++;
      else
      {
         fail++;
         Print("  Sell[", j, "] 失败 ret=", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      }
   }

   Print("本轮结果: 成功=", ok, " 失败=", fail);
   Print("══════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_sym = SymbolToTrade;
   if(StringLen(g_sym) == 0)
      g_sym = _Symbol;

   if(!SymbolSelect(g_sym, true))
   {
      Print("StressBurstEA: SymbolSelect 失败: ", g_sym);
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber((long)Magic);
   g_trade.SetDeviationInPoints(SlippagePoints);
   SetupFillingMode();

   if(BuysPerBurst < 0 || SellsPerBurst < 0)
   {
      Print("StressBurstEA: Buys/Sells 不能为负");
      return INIT_FAILED;
   }
   if(BuysPerBurst + SellsPerBurst == 0)
   {
      Print("StressBurstEA: 每轮至少 1 笔");
      return INIT_FAILED;
   }

   int sec = IntervalSeconds;
   if(sec < 1)
      sec = 1;
   EventSetTimer(sec);

   if(BurstOnStart)
      FireBurst();

   Print("StressBurstEA 已启动 | 品种=", g_sym, " 间隔=", sec, "秒 | Magic=", Magic);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("StressBurstEA 停止 | 总轮次=", g_burstCount, " reason=", reason);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   FireBurst();
}

//+------------------------------------------------------------------+
