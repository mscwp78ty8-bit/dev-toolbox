//+------------------------------------------------------------------+
//|            Gold_M1_Scalper_HF.mq4                              |
//|       黄金M1高频头皮 v7 - 回到v4+优化盈亏比                    |
//|  去掉EMA过滤(导致信号太少), 加大止盈比例                       |
//+------------------------------------------------------------------+
#property copyright "Gold M1 HF Scalper"
#property version   "7.00"
#property description "黄金M1头皮 - 优化盈亏比版"

input int      MagicNumber     = 202426;
input string   Comment_        = "M1 HF v7";
input int      Slippage        = 30;

input int      RSIPeriod       = 7;
input double   RSIOverSold     = 25.0;
input double   RSIOverBought   = 75.0;

input double   LotSize         = 0.01;

// ★ 止盈放大到2倍, 止损还是1倍前K线范围
input double   StopLossATRMultiplier = 1.0;
input double   TakeProfitATRMultiplier = 2.0;  // 从1.5改为2.0

input int      MaxSpreadPoints = 9999;

double g_point;
int    g_digits;

datetime g_lastBarTime;
bool     g_barTraded;

int OnInit()
{
   g_point  = Point;
   g_digits = (int)MarketInfo(_Symbol, MODE_DIGITS);
   
   g_lastBarTime = 0;
   g_barTraded = false;
   
   Print("================================================");
   Print("✅ 黄金M1头皮 v7 - 优化盈亏比版");
   Print("================================================");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { }

void OnTick()
{
   if(CountPositions() > 0) return;
   
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime != g_lastBarTime)
   {
      g_lastBarTime = barTime;
      g_barTraded = false;
   }
   if(g_barTraded) return;
   
   CheckSignal();
}

void CheckSignal()
{
   double bid = MarketInfo(_Symbol, MODE_BID);
   double ask = MarketInfo(_Symbol, MODE_ASK);
   
   double rsi1 = iRSI(_Symbol, PERIOD_M1, RSIPeriod, PRICE_CLOSE, 1);
   double rsi2 = iRSI(_Symbol, PERIOD_M1, RSIPeriod, PRICE_CLOSE, 2);
   
   if(rsi1 <= 0 || rsi2 <= 0) return;
   
   double prevRange = iHigh(_Symbol, PERIOD_M1, 1) - iLow(_Symbol, PERIOD_M1, 1);
   
   double slDist = prevRange * StopLossATRMultiplier;
   if(slDist < 0.5) slDist = 0.5;
   if(slDist > 3.0) slDist = 3.0;
   double tpDist = slDist * TakeProfitATRMultiplier;
   
   bool buySignal  = (rsi2 <= RSIOverSold && rsi1 >= RSIOverSold + 5);
   bool sellSignal = (rsi2 >= RSIOverBought && rsi1 <= RSIOverBought - 5);
   
   int ticket;
   
   if(buySignal)
   {
      double buySL = NormalizeDouble(bid - slDist, g_digits);
      double buyTP = NormalizeDouble(ask + tpDist, g_digits);
      
      ticket = OrderSend(_Symbol, OP_BUY, LotSize, ask, Slippage, buySL, buyTP, Comment_, MagicNumber, 0, clrGreen);
      if(ticket > 0) g_barTraded = true;
   }
   else if(sellSignal)
   {
      double sellSL = NormalizeDouble(ask + slDist, g_digits);
      double sellTP = NormalizeDouble(bid - tpDist, g_digits);
      
      ticket = OrderSend(_Symbol, OP_SELL, LotSize, bid, Slippage, sellSL, sellTP, Comment_, MagicNumber, 0, clrRed);
      if(ticket > 0) g_barTraded = true;
   }
}

int CountPositions()
{
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderMagicNumber() == MagicNumber && OrderSymbol() == _Symbol)
            count++;
      }
   }
   return count;
}
//+------------------------------------------------------------------+
