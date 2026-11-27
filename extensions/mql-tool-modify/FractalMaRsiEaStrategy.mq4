//+------------------------------------------------------------------+
//|                                           分型均线RSIEA.mq4      |
//|  模型：3条均线(21/50/200，默认平滑SMMA)同向 + RSI(14)过50          |
//|        + 分型确认（回看3/4/5根：有底分型且无顶分型）               |
//|  止损：进场价附近最近的一条均线（外扩缓冲）                        |
//|        均线止损过近 → 改用最近分型结构极值（底分型低点/顶分型高点） |
//|        结构止损仍不足 → ATR兜底                                    |
//|  止盈：止损距离 × 2（可调）                                       |
//|  依赖：MT4自带指标 iMA / iRSI / iFractals，无需额外指标             |
//+------------------------------------------------------------------+
#property copyright "Fractal MA RSI Model"
#property version   "1.10"
#property strict

//====================== 均线参数 ======================
input int    InpMaFastPeriod  = 21;                   // 快线周期
input int    InpMaMidPeriod   = 50;                   // 中线周期
input int    InpMaSlowPeriod  = 200;                  // 慢线周期
input int    InpMaMethod      = 2;                    // 均线类型 0=SMA 1=EMA 2=SMMA平滑 3=LWMA
input int    InpMaPrice       = 0;                    // 适用价 0=Close 1=Open 2=High 3=Low 4=Median 5=Typical 6=Weighted
input int    InpMaSlopeBars   = 1;                    // 斜率回看根数(MA[1]对比MA[1+N])，1=仅比前一根

//====================== RSI 参数 ======================
input int    InpRsiPeriod     = 14;                   // RSI周期（默认14）
input int    InpRsiPrice      = 0;                    // RSI适用价 0=Close
input double InpRsiLevel      = 50.0;                 // RSI多空分界

//====================== 分型参数 ======================
input int    InpFractalBars   = 5;                    // 分型回看根数（3/4/5）
input int    InpFractalStart  = 2;                    // 回看起始shift（2=刚确认的那根）
input bool   InpNoOppFractal  = true;                 // 回看窗口内不允许出现反向分型

//====================== 止损止盈 ======================
input double InpSlBufferPts   = 30;                   // 止损外扩(点)
input double InpMinStopPts    = 0;                    // 最小止损距离(点)，0=不限（另受点差/ATR下限约束）
input double InpMaxStopPts    = 0;                    // 最大止损距离(点)，0=不限（另受ATR上限约束）
input double InpMinStopSpreadMult = 8.0;              // 最小止损 = 当前点差 × 该倍数，0=不用
input double InpMinStopAtr    = 1.2;                  // 最小止损 = ATR × 该倍数，0=不用
input double InpMaxStopAtr    = 4.0;                  // 最大止损 = ATR × 该倍数，0=不用
input double InpFallbackAtr   = 1.5;                  // 无均线且无结构位时用ATR兜底倍数，0=放弃该信号
input int    InpAtrPeriod     = 14;                   // ATR周期（止损下限/上限/兜底共用）
input double InpRr            = 2.0;                  // 止盈 = 止损距离 × 该倍数

//====================== 分型结构止损 ==================
input bool   InpUseFractalStop = true;                // 均线止损过近时改用分型结构极值
input int    InpStructBars    = 24;                   // 结构止损扫描根数
input double InpStructMinAtr  = 0.8;                  // 分型极值至少低于/高于进场价多少ATR才采纳
input double InpStructMaxAtr  = 3.5;                  // 分型极值最多低于/高于进场价多少ATR，0=不限

//====================== 资金管理 ======================
input bool   InpUseFixedRisk  = false;                // 按固定风险金额反算手数（止损越宽手数越小）
input double InpRiskMoney     = 10.0;                 // 每笔风险金额(账户货币)
input double InpLotsMin       = 0.01;                 // 反算手数下限
input double InpLotsMax       = 0.10;                 // 反算手数上限

//====================== 交易参数 ======================
input double InpLots          = 0.01;                 // 手数
input int    InpMagic         = 20251110;             // 魔术号
input int    InpSlippage      = 30;                   // 滑点(点)
input double InpMaxSpreadPt   = 0;                    // 最大点差(点)，0=不限制
input bool   InpEcnMode       = false;                // ECN模式：先裸单再补挂SL/TP
input bool   InpOnePosition   = true;                 // 已有持仓时不再进场
input string InpComment       = "FMRSI";              // 订单注释

//====================== 调试参数 ======================
input bool   InpDebug         = true;                 // 输出诊断日志
input int    InpDebugEveryNBars = 100;                // 每N根bar打印一次诊断（另有"原因变化即打印"）
input bool   InpShowPanel     = true;                 // 图表左上角显示状态面板

//====================== 全局状态 ======================
string   g_blockReason = "";      // 本次未成交原因
string   g_prevReason  = "";      // 上一次未成交原因（用于变化检测）
int      g_barCounter  = 0;       // 诊断节流计数
int      g_sigCount    = 0;       // 累计信号数
int      g_orderCount  = 0;       // 累计开仓数
datetime g_lastEntry   = 0;       // 上次开仓bar时间（防同一bar重复进场）
string   g_slRefName   = "";      // 止损参考来源（MA21 / 底分型 / 顶分型 / ATR兜底）
double   g_slRefValue  = 0;       // 止损参考数值
double   g_slDistFinal = 0;       // 最终止损距离
double   g_lotsUsed    = 0;       // 本次实际手数
int      g_frLowerCnt  = 0;       // 窗口内底分型数量
int      g_frUpperCnt  = 0;       // 窗口内顶分型数量
int      g_frLowerShift = -1;     // 最近底分型shift
int      g_frUpperShift = -1;     // 最近顶分型shift
double   g_structLow   = 0;       // 结构止损用的底分型低点（最低的那个）
double   g_structHigh  = 0;       // 结构止损用的顶分型高点（最高的那个）
int      g_structLowShift  = -1;  // 对应shift
int      g_structHighShift = -1;  // 对应shift
int      g_stopMode    = 0;       // 0=无 1=均线 2=分型结构 3=ATR兜底

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMaFastPeriod < 2 || InpMaMidPeriod < 2 || InpMaSlowPeriod < 2 ||
      InpRsiPeriod < 2 || InpAtrPeriod < 2)
     {
      Print("参数非法：均线 / RSI / ATR 周期必须 >= 2");
      return(INIT_FAILED);
     }
   if(InpMaSlopeBars < 1 || InpFractalBars < 1 || InpFractalStart < 1)
     {
      Print("参数非法：InpMaSlopeBars / InpFractalBars / InpFractalStart 必须 >= 1");
      return(INIT_FAILED);
     }
   if(InpRr <= 0)
     {
      Print("参数非法：InpRr 必须 > 0");
      return(INIT_FAILED);
     }
   if(InpStructBars < 2)
     {
      Print("参数非法：InpStructBars 必须 >= 2");
      return(INIT_FAILED);
     }
   if(InpUseFixedRisk && InpRiskMoney <= 0)
     {
      Print("参数非法：启用固定风险时 InpRiskMoney 必须 > 0");
      return(INIT_FAILED);
     }

   g_blockReason  = "";
   g_prevReason   = "";
   g_barCounter   = 0;
   g_sigCount     = 0;
   g_orderCount   = 0;
   g_lastEntry    = 0;
   g_slRefName    = "";
   g_slRefValue   = 0;
   g_slDistFinal  = 0;
   g_lotsUsed     = 0;
   g_structLow    = 0;
   g_structHigh   = 0;
   g_structLowShift  = -1;
   g_structHighShift = -1;
   g_stopMode     = 0;
   g_frLowerCnt   = 0;
   g_frUpperCnt   = 0;
   g_frLowerShift = -1;
   g_frUpperShift = -1;

   Print("=== 分型均线RSIEA 初始化 ===");
   Print("品种=", Symbol(), " 周期=", Period(), " 点数=", Point,
         " Digits=", Digits, " StopsLevel=", (int)MarketInfo(Symbol(), MODE_STOPLEVEL));
   Print("均线：MA", InpMaFastPeriod, " / MA", InpMaMidPeriod, " / MA", InpMaSlowPeriod,
         " 类型=", InpMaMethod, "（2=SMMA平滑）");
   Print("RSI：周期=", InpRsiPeriod, " 分界=", DoubleToStr(InpRsiLevel, 1),
         "  分型回看=", InpFractalBars, "根（起于shift ", InpFractalStart, "）");
   Print("止损：均线优先 +", DoubleToStr(InpSlBufferPts, 0), "点外扩；过近时改用分型结构(",
         (InpUseFractalStop ? "开" : "关"), " 扫描", InpStructBars, "根, >= ",
         DoubleToStr(InpStructMinAtr, 2), "ATR)");
   Print("止损区间：下限=max(", DoubleToStr(InpMinStopPts, 0), "点, ",
         DoubleToStr(InpMinStopSpreadMult, 1), "×点差, ", DoubleToStr(InpMinStopAtr, 2),
         "ATR)  上限=", DoubleToStr(InpMaxStopAtr, 2), "ATR / ",
         DoubleToStr(InpMaxStopPts, 0), "点  止盈=", DoubleToStr(InpRr, 2), "倍");
   Print("资金管理：", (InpUseFixedRisk ? "固定风险 " + DoubleToStr(InpRiskMoney, 2) + " " + AccountCurrency() : "固定手数 " + DoubleToStr(InpLots, 2)),
         "  手数区间=", DoubleToStr(InpLotsMin, 2), "~", DoubleToStr(InpLotsMax, 2));

   double f1 = MaVal(InpMaFastPeriod, 1);
   double m1 = MaVal(InpMaMidPeriod, 1);
   double s1 = MaVal(InpMaSlowPeriod, 1);
   double r1 = iRSI(NULL, 0, InpRsiPeriod, InpRsiPrice, 1);

   if(f1 <= 0 || m1 <= 0 || s1 <= 0)
      Print("【错误】读不到均线数据，请检查K线数量（至少需要 ", InpMaSlowPeriod + InpFractalBars + 30, " 根）");
   else
      Print("均线读取正常：MA", InpMaFastPeriod, "=", DoubleToStr(f1, Digits),
            " MA", InpMaMidPeriod, "=", DoubleToStr(m1, Digits),
            " MA", InpMaSlowPeriod, "=", DoubleToStr(s1, Digits));

   if(r1 <= 0)
      Print("【错误】读不到 RSI 数据，请检查K线数量");
   else
      Print("RSI 读取正常：", DoubleToStr(r1, 2));

   Print("Bars=", Bars, " 建议最少=", InpMaSlowPeriod + InpFractalBars + 30);

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   static datetime lastBarTime = 0;
   bool newBar = (Time[0] != lastBarTime);
   if(newBar) lastBarTime = Time[0];
   if(!newBar) return;

   g_barCounter++;

   if(!IsTradeAllowed() || IsTradeContextBusy())
     {
      g_blockReason = "交易环境不允许";
      FinishBar();
      return;
     }

   if(Bars < InpMaSlowPeriod + InpFractalBars + 30)
     {
      g_blockReason = "K线数量不足";
      FinishBar();
      return;
     }

   if(Time[1] == g_lastEntry)
     {
      g_blockReason = "本bar已开过仓";
      FinishBar();
      return;
     }

   // 先判形态，再拦点差：否则"点差过大"会掩盖真实拦截原因
   int dir = CheckSignal();

   if(dir == 0)
     {
      FinishBar();
      return;
     }

   g_sigCount++;
   Print("【信号】", (dir == 1 ? "做多" : "做空"), " bar=", TimeToStr(Time[1], TIME_DATE | TIME_MINUTES),
         " 第", g_sigCount, "个信号");

   double spreadPt = (Ask - Bid) / Point;
   if(InpMaxSpreadPt > 0 && spreadPt > InpMaxSpreadPt)
     {
      g_blockReason = "形态命中但点差过大(" + DoubleToStr(spreadPt, 0) + "点)";
      Print("【拦截】形态已命中，但点差 ", DoubleToStr(spreadPt, 0),
            "点 > 上限 ", DoubleToStr(InpMaxSpreadPt, 0), "点");
      FinishBar();
      return;
     }

   if(InpOnePosition && HasOurOrders())
     {
      g_blockReason = "已有持仓，不再进场";
      Print("【跳过】已有持仓，本次信号不进场");
      FinishBar();
      return;
     }

   double price = (dir == 1) ? Ask : Bid;
   double sl    = 0;
   double dist  = 0;
   if(!CalcStop(dir, price, sl, dist))
     {
      Print("【拦截】止损计算失败：", g_blockReason);
      FinishBar();
      return;
     }

   DoEntry(dir, price, sl, dist);
   FinishBar();
  }
//+------------------------------------------------------------------+
//| 每bar收尾：决定是否写日志 / 刷新面板                             |
//+------------------------------------------------------------------+
void FinishBar()
  {
   bool needLog = false;
   if(InpDebug)
     {
      needLog = (g_barCounter % InpDebugEveryNBars == 0) || (g_blockReason != g_prevReason);
      g_prevReason = g_blockReason;
     }
   bool needPanel = (InpShowPanel && !IsTesting());
   if(needLog || needPanel)
      DoDiagnostics(needLog);
  }
//+------------------------------------------------------------------+
//| 均线取值（shift=1 为最近一根已收盘K线）                          |
//+------------------------------------------------------------------+
double MaVal(int period, int shift)
  {
   return(iMA(NULL, 0, period, 0, InpMaMethod, InpMaPrice, shift));
  }
//+------------------------------------------------------------------+
//| 均线是否向上 / 向下：MA[1] 对比 MA[1+InpMaSlopeBars]             |
//+------------------------------------------------------------------+
bool MaUp(int period)
  {
   double a = MaVal(period, 1);
   double b = MaVal(period, 1 + InpMaSlopeBars);
   return(a > b);
  }
bool MaDn(int period)
  {
   double a = MaVal(period, 1);
   double b = MaVal(period, 1 + InpMaSlopeBars);
   return(a < b);
  }
//+------------------------------------------------------------------+
//| 扫描分型窗口：统计底/顶分型数量与最近位置                        |
//+------------------------------------------------------------------+
void ScanFractals()
  {
   g_frLowerCnt   = 0;
   g_frUpperCnt   = 0;
   g_frLowerShift = -1;
   g_frUpperShift = -1;

   int start = InpFractalStart;
   int end   = start + InpFractalBars - 1;

   for(int s = start; s <= end; s++)
     {
      double up = iFractals(NULL, 0, MODE_UPPER, s);
      double dn = iFractals(NULL, 0, MODE_LOWER, s);

      if(up != EMPTY_VALUE && up > 0)
        {
         g_frUpperCnt++;
         if(g_frUpperShift < 0) g_frUpperShift = s;
        }
      if(dn != EMPTY_VALUE && dn > 0)
        {
         g_frLowerCnt++;
         if(g_frLowerShift < 0) g_frLowerShift = s;
        }
     }
  }
//+------------------------------------------------------------------+
//| 扫描结构分型：在最近 InpStructBars 根内找可用的结构极值          |
//| 多单用底分型低点（取最低的那个），空单用顶分型高点（取最高的）    |
//| 只采纳距离落在 [max(InpStructMinAtr,minD), min(InpStructMaxAtr,maxD)] |
//+------------------------------------------------------------------+
void ScanStructFractals(double price, double atr, int dir, double minD, double maxD)
  {
   g_structLow       = 0;
   g_structHigh      = 0;
   g_structLowShift  = -1;
   g_structHighShift = -1;

   if(!InpUseFractalStop || atr <= 0) return;

   double minDist = InpStructMinAtr * atr;
   if(minD > minDist) minDist = minD;

   double maxDist = (InpStructMaxAtr > 0 ? InpStructMaxAtr * atr : 0);
   if(maxD > 0 && (maxDist <= 0 || maxD < maxDist)) maxDist = maxD;

   int start = InpFractalStart;
   int end   = InpStructBars + 1;
   if(end > Bars - 3) end = Bars - 3;

   for(int s = start; s <= end; s++)
     {
      if(dir == 1)
        {
         double dn = iFractals(NULL, 0, MODE_LOWER, s);
         if(dn == EMPTY_VALUE || dn <= 0) continue;
         double dist = price - dn;
         if(dist < minDist) continue;
         if(maxDist > 0 && dist > maxDist) continue;
         if(g_structLow <= 0 || dn < g_structLow)
           {
            g_structLow      = dn;
            g_structLowShift = s;
           }
        }
      else if(dir == -1)
        {
         double up = iFractals(NULL, 0, MODE_UPPER, s);
         if(up == EMPTY_VALUE || up <= 0) continue;
         double dist = up - price;
         if(dist < minDist) continue;
         if(maxDist > 0 && dist > maxDist) continue;
         if(g_structHigh <= 0 || up > g_structHigh)
           {
            g_structHigh      = up;
            g_structHighShift = s;
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| 信号判定：1=多 -1=空 0=无                                        |
//| 做多：3均线向上 + RSI>50 + 窗口内有底分型且无顶分型              |
//| 做空：3均线向下 + RSI<50 + 窗口内有顶分型且无底分型              |
//+------------------------------------------------------------------+
int CheckSignal()
  {
   g_blockReason = "";

   double maF = MaVal(InpMaFastPeriod, 1);
   double maM = MaVal(InpMaMidPeriod, 1);
   double maS = MaVal(InpMaSlowPeriod, 1);
   if(maF <= 0 || maM <= 0 || maS <= 0)
     { g_blockReason = "均线数据无效"; return(0); }

   double rsi = iRSI(NULL, 0, InpRsiPeriod, InpRsiPrice, 1);
   if(rsi <= 0)
     { g_blockReason = "RSI数据无效"; return(0); }

   bool upAll = MaUp(InpMaFastPeriod) && MaUp(InpMaMidPeriod) && MaUp(InpMaSlowPeriod);
   bool dnAll = MaDn(InpMaFastPeriod) && MaDn(InpMaMidPeriod) && MaDn(InpMaSlowPeriod);

   ScanFractals();

   if(upAll)
     {
      if(rsi <= InpRsiLevel)
        {
         g_blockReason = "RSI未过" + DoubleToStr(InpRsiLevel, 0) + "(" + DoubleToStr(rsi, 2) + ")";
         return(0);
        }
      if(g_frLowerCnt == 0)
        {
         g_blockReason = "窗口内无底分型";
         return(0);
        }
      if(InpNoOppFractal && g_frUpperCnt > 0)
        {
         g_blockReason = "窗口内出现顶分型(" + IntegerToString(g_frUpperCnt) + "个)";
         return(0);
        }
      return(1);
     }

   if(dnAll)
     {
      if(rsi >= InpRsiLevel)
        {
         g_blockReason = "RSI未破" + DoubleToStr(InpRsiLevel, 0) + "(" + DoubleToStr(rsi, 2) + ")";
         return(0);
        }
      if(g_frUpperCnt == 0)
        {
         g_blockReason = "窗口内无顶分型";
         return(0);
        }
      if(InpNoOppFractal && g_frLowerCnt > 0)
        {
         g_blockReason = "窗口内出现底分型(" + IntegerToString(g_frLowerCnt) + "个)";
         return(0);
        }
      return(-1);
     }

   g_blockReason = "三条均线未同向";
   return(0);
  }
//+------------------------------------------------------------------+
//| 止损：均线优先 → 分型结构极值 → ATR兜底 → 均线距离夹取           |
//| 多单取下方最近均线/最低底分型低点，空单取上方最近均线/最高顶分型高点|
//+------------------------------------------------------------------+
bool CalcStop(int dir, double price, double &sl, double &dist)
  {
   double f = MaVal(InpMaFastPeriod, 1);
   double m = MaVal(InpMaMidPeriod, 1);
   double s = MaVal(InpMaSlowPeriod, 1);

   bool   found   = false;
   double ref     = 0;
   string refName = "";

   if(dir == 1)
     {
      if(f > 0 && f < price) { ref = f; refName = "MA" + IntegerToString(InpMaFastPeriod); found = true; }
      if(m > 0 && m < price && (!found || m > ref)) { ref = m; refName = "MA" + IntegerToString(InpMaMidPeriod); found = true; }
      if(s > 0 && s < price && (!found || s > ref)) { ref = s; refName = "MA" + IntegerToString(InpMaSlowPeriod); found = true; }
     }
   else if(dir == -1)
     {
      if(f > 0 && f > price) { ref = f; refName = "MA" + IntegerToString(InpMaFastPeriod); found = true; }
      if(m > 0 && m > price && (!found || m < ref)) { ref = m; refName = "MA" + IntegerToString(InpMaMidPeriod); found = true; }
      if(s > 0 && s > price && (!found || s < ref)) { ref = s; refName = "MA" + IntegerToString(InpMaSlowPeriod); found = true; }
     }
   else
     {
      g_blockReason = "方向非法";
      return(false);
     }

   double atr = iATR(NULL, 0, InpAtrPeriod, 1);

   double distMA = 0;
   double slMA   = 0;
   if(found)
     {
      slMA   = (dir == 1) ? ref - InpSlBufferPts * Point : ref + InpSlBufferPts * Point;
      distMA = MathAbs(price - slMA);
     }

   double minDist = MinStopDist();
   double maxDist = MaxStopDist();

   bool   ok        = false;
   double distFinal = 0;
   double slFinal   = 0;
   int    mode      = 0;
   string name      = "";

   // 1) 均线止损距离合格 → 沿用旧逻辑
   if(found && distMA >= minDist && (maxDist <= 0 || distMA <= maxDist))
     {
      distFinal = distMA;
      slFinal   = slMA;
      mode      = 1;
      name      = refName;
      ok        = true;
     }

   // 2) 均线过近/过远 → 改用分型结构极值
   if(!ok)
     {
      ScanStructFractals(price, atr, dir, minDist, maxDist);
      double stRef  = (dir == 1) ? g_structLow : g_structHigh;
      if(stRef > 0)
        {
         double stSL   = (dir == 1) ? stRef - InpSlBufferPts * Point : stRef + InpSlBufferPts * Point;
         double stDist = MathAbs(price - stSL);
         if(stDist >= minDist && (maxDist <= 0 || stDist <= maxDist))
           {
            distFinal = stDist;
            slFinal   = stSL;
            mode      = 2;
            name      = (dir == 1) ? "底分型" : "顶分型";
            ref       = stRef;
            ok        = true;
           }
        }
     }

   // 3) 结构位也不可用 → ATR兜底
   if(!ok && InpFallbackAtr > 0 && atr > 0)
     {
      double fbDist = InpFallbackAtr * atr;
      if(maxDist > 0 && fbDist > maxDist) fbDist = maxDist;
      if(fbDist >= minDist)
        {
         distFinal = fbDist;
         slFinal   = (dir == 1) ? price - fbDist : price + fbDist;
         mode      = 3;
         name      = "ATR兜底";
         ref       = slFinal;
         ok        = true;
        }
     }

   // 4) 最后兜底：仍用均线，但把距离夹到允许区间（旧版行为）
   if(!ok && found)
     {
      double cd = distMA;
      if(cd < minDist) cd = minDist;
      if(maxDist > 0 && cd > maxDist) cd = maxDist;
      distFinal = cd;
      slFinal   = (dir == 1) ? price - cd : price + cd;
      mode      = 1;
      name      = refName;
      ok        = true;
     }

   if(!ok)
     {
      g_blockReason = "均线与结构位均不可用，ATR兜底已关闭";
      return(false);
     }

   sl   = slFinal;
   dist = distFinal;

   g_slRefName  = name;
   g_slRefValue = ref;
   g_slDistFinal = distFinal;
   g_stopMode   = mode;
   return(true);
  }
//+------------------------------------------------------------------+
//| 手数：固定手数 或 按固定风险金额反算（止损越宽手数越小）          |
//+------------------------------------------------------------------+
double CalcLots(double dist)
  {
   double lots = InpLots;
   if(!InpUseFixedRisk) return(lots);
   if(dist <= 0) return(lots);

   double tickVal  = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   double lotStep  = MarketInfo(Symbol(), MODE_LOTSTEP);
   double lotMin   = MarketInfo(Symbol(), MODE_MINLOT);
   double lotMax   = MarketInfo(Symbol(), MODE_MAXLOT);
   if(tickVal <= 0 || tickSize <= 0 || lotStep <= 0) return(lots);

   double lossPerLot = dist / tickSize * tickVal;
   if(lossPerLot <= 0) return(lots);

   lots = InpRiskMoney / lossPerLot;
   lots = MathFloor(lots / lotStep) * lotStep;

   if(lots < lotMin)  lots = lotMin;
   if(lots > lotMax)  lots = lotMax;
   if(lots < InpLotsMin) lots = InpLotsMin;
   if(lots > InpLotsMax) lots = InpLotsMax;
   if(lots < lotMin)  lots = lotMin;
   if(lots > lotMax)  lots = lotMax;

   return(NormalizeDouble(lots, 2));
  }
//+------------------------------------------------------------------+
//| 开仓                                                            |
//+------------------------------------------------------------------+
void DoEntry(int dir, double price, double sl, double dist)
  {
   double tp   = (dir == 1) ? price + InpRr * dist : price - InpRr * dist;
   int    type = (dir == 1) ? OP_BUY : OP_SELL;
   double lots = CalcLots(dist);

   int ticket = SendOrder(type, lots, price, sl, tp, InpMagic);
   if(ticket < 0) return;

   g_lastEntry = Time[1];
   g_orderCount++;
   g_lotsUsed  = lots;

   Print("【开仓#", g_orderCount, "】", (dir == 1 ? "多" : "空"),
         " 价=", DoubleToStr(price, Digits),
         " 止损=", DoubleToStr(sl, Digits),
         "（来源 ", g_slRefName, "=", DoubleToStr(g_slRefValue, Digits), "）",
         " 止损距=", DoubleToStr(dist, Digits),
         " 止盈=", DoubleToStr(tp, Digits),
         " 手数=", DoubleToStr(lots, 2),
         " 票=", ticket);
  }
//+------------------------------------------------------------------+
//| 下单（含ECN补挂）                                                |
//+------------------------------------------------------------------+
int SendOrder(int type, double lots, double price, double sl, double tp, int magic)
  {
   double oPrice = NormalizeDouble(price, Digits);
   double oSL    = (InpEcnMode) ? 0 : NormalizeDouble(sl, Digits);
   double oTP    = (InpEcnMode) ? 0 : NormalizeDouble(tp, Digits);

   int ticket = OrderSend(Symbol(), type, lots, oPrice, InpSlippage, oSL, oTP,
                          InpComment, magic, 0, CLR_NONE);
   if(ticket < 0)
     {
      Print("下单失败 错误码=", GetLastError(), " magic=", magic, " type=", type);
      return(-1);
     }

   if(InpEcnMode && (sl > 0 || tp > 0))
     {
      for(int k = 0; k < 10; k++)
        {
         if(OrderSelect(ticket, SELECT_BY_TICKET) && OrderOpenPrice() > 0) break;
         Sleep(200);
        }
      if(OrderSelect(ticket, SELECT_BY_TICKET))
        {
         if(!OrderModify(ticket, OrderOpenPrice(), NormalizeDouble(sl, Digits),
                         NormalizeDouble(tp, Digits), 0, CLR_NONE))
            Print("ECN补挂失败 错误码=", GetLastError(), " ticket=", ticket);
        }
     }
   return(ticket);
  }
//+------------------------------------------------------------------+
bool HasOurOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != InpMagic) continue;
      return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| 周期转字符串                                                    |
//+------------------------------------------------------------------+
string PeriodToStr(int p)
  {
   switch(p)
     {
      case 1:     return("M1");
      case 5:     return("M5");
      case 15:    return("M15");
      case 30:    return("M30");
      case 60:    return("H1");
      case 240:   return("H4");
      case 1440:  return("D1");
      case 10080: return("W1");
      case 43200: return("MN");
      default:    return(IntegerToString(p));
     }
  }
//+------------------------------------------------------------------+
//| 均线状态文字                                                    |
//+------------------------------------------------------------------+
string MaState(int period)
  {
   double a = MaVal(period, 1);
   double b = MaVal(period, 1 + InpMaSlopeBars);
   if(a <= 0 || b <= 0) return("无数据");
   if(a > b) return("上");
   if(a < b) return("下");
   return("平");
  }
//+------------------------------------------------------------------+
//| 止损距离下限：点差倍数 / ATR倍数 / 经纪商限制 / 用户点数 取最大  |
//+------------------------------------------------------------------+
double MinStopDist()
  {
   double spread  = Ask - Bid;
   double atr     = iATR(NULL, 0, InpAtrPeriod, 1);
   double minDist = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(InpMinStopPts > 0 && InpMinStopPts * Point > minDist)
      minDist = InpMinStopPts * Point;
   if(InpMinStopSpreadMult > 0 && spread * InpMinStopSpreadMult > minDist)
      minDist = spread * InpMinStopSpreadMult;
   if(InpMinStopAtr > 0 && atr > 0 && InpMinStopAtr * atr > minDist)
      minDist = InpMinStopAtr * atr;
   return(minDist);
  }
//+------------------------------------------------------------------+
//| 止损距离上限：用户点数 / ATR倍数 取较小值，0=不限                |
//+------------------------------------------------------------------+
double MaxStopDist()
  {
   double atr     = iATR(NULL, 0, InpAtrPeriod, 1);
   double maxDist = 0;
   if(InpMaxStopPts > 0)
      maxDist = InpMaxStopPts * Point;
   if(InpMaxStopAtr > 0 && atr > 0)
     {
      double d = InpMaxStopAtr * atr;
      if(maxDist <= 0 || d < maxDist) maxDist = d;
     }
   return(maxDist);
  }
//+------------------------------------------------------------------+
//| 止损来源文字（面板显示用）                                       |
//+------------------------------------------------------------------+
string SlModeStr()
  {
   string s = "均线优先";
   if(InpUseFractalStop)
      s = s + " → 分型结构(" + IntegerToString(InpStructBars) + "根)";
   if(InpFallbackAtr > 0)
      s = s + " → ATR" + DoubleToStr(InpFallbackAtr, 1) + "倍";
   return(s);
  }
//+------------------------------------------------------------------+
//| 诊断输出：日志 + 图表面板                                        |
//+------------------------------------------------------------------+
void DoDiagnostics(bool toLog)
  {
   double maF      = MaVal(InpMaFastPeriod, 1);
   double maM      = MaVal(InpMaMidPeriod, 1);
   double maS      = MaVal(InpMaSlowPeriod, 1);
   double rsi      = iRSI(NULL, 0, InpRsiPeriod, InpRsiPrice, 1);
   double spreadPt = (Ask - Bid) / Point;

   ScanFractals();

   bool dataOk = (maF > 0 && maM > 0 && maS > 0 && rsi > 0);
   string state;
   if(!dataOk)
      state = "数据无效(检查K线数量)";
   else if(g_blockReason == "")
      state = "无信号（条件未满足）";
   else
      state = "无信号: " + g_blockReason;

   string frLower = (g_frLowerShift > 0 ? "shift=" + IntegerToString(g_frLowerShift) + "（" + IntegerToString(g_frLowerCnt) + "个）" : "无");
   string frUpper = (g_frUpperShift > 0 ? "shift=" + IntegerToString(g_frUpperShift) + "（" + IntegerToString(g_frUpperCnt) + "个）" : "无");

   string p = "\n";
   p = p + "==== 分型均线RSIEA  " + Symbol() + " " + PeriodToStr(Period()) + " ====\n";
   p = p + "bar: " + TimeToStr(Time[0], TIME_DATE | TIME_MINUTES) + "   点差: " + DoubleToStr(spreadPt, 0) + "点\n";
   p = p + "MA" + IntegerToString(InpMaFastPeriod) + "=" + DoubleToStr(maF, Digits) + "[" + MaState(InpMaFastPeriod) + "]"
     + "   MA" + IntegerToString(InpMaMidPeriod) + "=" + DoubleToStr(maM, Digits) + "[" + MaState(InpMaMidPeriod) + "]"
     + "   MA" + IntegerToString(InpMaSlowPeriod) + "=" + DoubleToStr(maS, Digits) + "[" + MaState(InpMaSlowPeriod) + "]\n";
   p = p + "RSI(" + IntegerToString(InpRsiPeriod) + ")=" + DoubleToStr(rsi, 2)
     + "  分界=" + DoubleToStr(InpRsiLevel, 1)
     + (rsi > InpRsiLevel ? "  [偏多]" : (rsi < InpRsiLevel ? "  [偏空]" : "  [等于分界]")) + "\n";
   p = p + "分型窗口(" + IntegerToString(InpFractalBars) + "根, shift " + IntegerToString(InpFractalStart) + "-"
     + IntegerToString(InpFractalStart + InpFractalBars - 1) + "):  底分型=" + frLower
     + "   顶分型=" + frUpper + "\n";
   p = p + "止损参考: " + SlModeStr() + "   止盈: " + DoubleToStr(InpRr, 2) + "倍止损距\n";
   p = p + "止损区间: 下限=" + DoubleToStr(MinStopDist() / Point, 0) + "点"
     + "  上限=" + (InpMaxStopAtr > 0 ? DoubleToStr(InpMaxStopAtr, 2) + "ATR" : "不限") + "\n";
   p = p + "结果: " + state + "\n";
   p = p + "累计信号=" + IntegerToString(g_sigCount) + "  累计开仓=" + IntegerToString(g_orderCount) + "\n";

   if(InpShowPanel) Comment(p);
   if(toLog)        Print(p);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }
//+------------------------------------------------------------------+