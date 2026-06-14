//+------------------------------------------------------------------+
//|  GoldScalperPro_M1.mq5                                           |
//|  Full-Architecture Gold Scalper · M1 · All Brokers/Digits        |
//|  Modules: MM Detector · Anomaly · Entry · TP · Recovery ·        |
//|           Anomaly Response · Dashboard · Bug Guards               |
//|  v2.00 fixes:                                                     |
//|   • OpenTrade: retry x3 on requote/price_changed with fresh tick  |
//|   • OpenTrade: use ResultRetcode() not GetLastError()             |
//|   • OnInit:    auto-detect ORDER_FILLING mode (broker-agnostic)   |
//|   • GetOldestLegType: fix inverted oldest-time comparison         |
//|   • DB_Sep: remove dead OBJ_TREND create, use OBJ_LABEL only      |
//|   • OnTimer: fix daily reset to use date-change check             |
//|  v3.00 fixes:                                                     |
//|   • InpGridStep: changed unit from points → USD (broker-agnostic) |
//|   • RecoveryEngine: convert USD→price via _pipVal, not *_point    |
//+------------------------------------------------------------------+
#property copyright   "GoldScalperPro"
#property link        ""
#property version     "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "=== Money & Risk ==="
input double   InpTP_USD        = 2.0;      // TP per trade (USD)
input double   InpDailyTarget   = 30.0;     // Daily profit target (USD)
input double   InpGridStep      = 2.0;      // Grid step distance (USD) — same unit as InpTP_USD
input int      InpMaxLegs       = 10;        // Max recovery legs

input group "=== Market Maker Detector ==="
input int      InpEMA_Fast      = 8;        // EMA Fast period
input int      InpEMA_Mid       = 21;       // EMA Mid period
input int      InpEMA_Slow      = 50;       // EMA Slow period
input ENUM_TIMEFRAMES InpHTF    = PERIOD_D1; // Higher timeframe bias

input group "=== Anomaly / Safety ==="
input int      InpMaxSpread     = 300;       // Max allowed spread (points)
input bool     InpNewsGuard     = true;     // Enable news guard
input int      InpNewsMinutes   = 5;        // Block ±N min around news
input double   InpATR_Mult      = 2.5;      // ATR spike multiplier

input group "=== Entry Filters ==="
input int      InpRSI_Period    = 7;        // RSI period
input int      InpMACD_Fast     = 12;       // MACD fast
input int      InpMACD_Slow     = 26;       // MACD slow
input int      InpMACD_Signal   = 9;        // MACD signal
input bool     InpLondonSession = true;     // Trade London session
input bool     InpNYSession     = true;     // Trade New York session

input group "=== EA Settings ==="
input int      InpMagic         = 20240101; // Magic number
input string   InpComment       = "GSP_M1"; // Order comment

//+------------------------------------------------------------------+
//|  GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade         Trade;
CPositionInfo  PosInfo;

// Indicator handles
int   hEMA_Fast, hEMA_Mid, hEMA_Slow;
int   hEMA_HTF_Fast, hEMA_HTF_Slow;
int   hRSI, hMACD, hATR;

// Normalisation
double _point;
int    _digits;
double _pipVal;    // USD per point for 0.01 lot

// State
bool   _eaActive      = true;
bool   _dailyDone     = false;
double _dailyProfit   = 0.0;
int    _totalTrades   = 0;
int    _wonToday      = 0;
string _mmDir         = "NEUTRAL";
bool   _dangerFlag    = false;
string _alertMsg      = "";
datetime _lastBarTime = 0;
double _lastEquity    = 0.0;

// Dashboard label names
string LBL_PREFIX = "GSP_";

//+------------------------------------------------------------------+
//|  OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(30);
   // Auto-detect supported filling mode (broker-agnostic)
   ENUM_ORDER_TYPE_FILLING fill = ORDER_FILLING_FOK;
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) != 0)
      fill = ORDER_FILLING_IOC;
   else if((filling & SYMBOL_FILLING_FOK) != 0)
      fill = ORDER_FILLING_FOK;
   else
      fill = ORDER_FILLING_RETURN;
   Trade.SetTypeFilling(fill);

   // ── Normalise symbol ──────────────────────────────────────────
   _digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   _point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   // For 5-digit brokers point = 0.00001; for 3-digit (JPY) = 0.001
   // Pip value per 0.01 lot in account currency
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
      _pipVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE)
                * _point / tickSize * 0.01;
   else
      _pipVal = 0.01; // fallback safe value

   // ── Indicator handles ────────────────────────────────────────
   hEMA_Fast     = iMA(_Symbol, PERIOD_M1, InpEMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   hEMA_Mid      = iMA(_Symbol, PERIOD_M1, InpEMA_Mid,   0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow     = iMA(_Symbol, PERIOD_M1, InpEMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   hEMA_HTF_Fast = iMA(_Symbol, InpHTF,    InpEMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
   hEMA_HTF_Slow = iMA(_Symbol, InpHTF,    InpEMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
   hRSI          = iRSI(_Symbol, PERIOD_M1, InpRSI_Period, PRICE_CLOSE);
   hMACD         = iMACD(_Symbol, PERIOD_M1, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   hATR          = iATR(_Symbol, PERIOD_M1, 14);

   // Guard: invalid handles
   if(hEMA_Fast == INVALID_HANDLE || hEMA_Mid == INVALID_HANDLE ||
      hEMA_Slow == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hMACD == INVALID_HANDLE     || hATR == INVALID_HANDLE)
   {
      Alert("GoldScalperPro: Failed to create indicator handles!");
      return INIT_FAILED;
   }

   // ── Dashboard init ───────────────────────────────────────────
   DB_Create();
   EventSetTimer(60); // fire OnTimer every 60 s for daily reset check
   Print("GoldScalperPro M1 Initialised. Point=", _point,
         " Digits=", _digits, " PipVal=", _pipVal);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   DB_Destroy();
   IndicatorRelease(hEMA_Fast);
   IndicatorRelease(hEMA_Mid);
   IndicatorRelease(hEMA_Slow);
   IndicatorRelease(hEMA_HTF_Fast);
   IndicatorRelease(hEMA_HTF_Slow);
   IndicatorRelease(hRSI);
   IndicatorRelease(hMACD);
   IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
//|  OnTick  — Main Loop                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // ── 0. New-bar detection (for single-open-per-bar guard) ─────
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);

   // ── 1. Daily profit accounting ───────────────────────────────
   _dailyProfit = CalcDailyProfit();

   // ── 2. Anomaly detector runs EVERY tick ──────────────────────
   MOD_B_AnomalyDetector();

   // ── 3. TP monitor — check open positions ─────────────────────
   MOD_D_TPMonitor();

   // ── 4. Recovery engine — manage losing legs ──────────────────
   MOD_E_RecoveryEngine();

   // ── 5. Daily target gate ─────────────────────────────────────
   if(_dailyProfit >= InpDailyTarget && !_dailyDone)
   {
      _dailyDone = true;
      _alertMsg  = "Daily target hit!";
   }

   // If daily done AND no open positions → full stop
   if(_dailyDone && CountMyPositions() == 0)
   {
      DB_Update();
      return;
   }
   // If daily done but positions still open → recovery only (no new entry)
   if(_dailyDone)
   {
      DB_Update();
      return;
   }

   // ── 6. Market Maker detection ────────────────────────────────
   MOD_A_MMDetector();

   // ── 7. Safety gate ───────────────────────────────────────────
   if(_dangerFlag || _mmDir == "NEUTRAL")
   {
      DB_Update();
      return;
   }

   // ── 8. Entry logic — only on new bar ─────────────────────────
   if(curBar != _lastBarTime)
   {
      _lastBarTime = curBar;
      if(CountMyPositions() == 0)
      {
         MOD_C_Entry();
      }
   }

   // ── 9. Dashboard refresh ─────────────────────────────────────
   DB_Update();
}

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE A · MARKET MAKER DETECTOR                                ║
//╚══════════════════════════════════════════════════════════════════╝
void MOD_A_MMDetector()
{
   // ── Read EMA values (index 1 = closed bar) ───────────────────
   double emaF1[], emaM1[], emaS1[];
   ArraySetAsSeries(emaF1, true); ArraySetAsSeries(emaM1, true);
   ArraySetAsSeries(emaS1, true);

   // Bug guard: check CopyBuffer returns
   if(CopyBuffer(hEMA_Fast, 0, 1, 3, emaF1) < 3) return;
   if(CopyBuffer(hEMA_Mid,  0, 1, 3, emaM1) < 3) return;
   if(CopyBuffer(hEMA_Slow, 0, 1, 3, emaS1) < 3) return;

   // Stack: Fast > Mid > Slow = BULL; Fast < Mid < Slow = BEAR
   bool stackBull = (emaF1[0] > emaM1[0]) && (emaM1[0] > emaS1[0]);
   bool stackBear = (emaF1[0] < emaM1[0]) && (emaM1[0] < emaS1[0]);

   // Slope: EMA moving in same direction
   bool slopeBull = (emaF1[0] > emaF1[1]) && (emaM1[0] > emaM1[1]);
   bool slopeBear = (emaF1[0] < emaF1[1]) && (emaM1[0] < emaM1[1]);

   // ── HTF bias filter ──────────────────────────────────────────
   double htfF[], htfS[];
   ArraySetAsSeries(htfF, true); ArraySetAsSeries(htfS, true);
   bool htfBull = false, htfBear = false;
   if(CopyBuffer(hEMA_HTF_Fast, 0, 1, 2, htfF) >= 2 &&
      CopyBuffer(hEMA_HTF_Slow, 0, 1, 2, htfS) >= 2)
   {
      htfBull = htfF[0] > htfS[0];
      htfBear = htfF[0] < htfS[0];
   }

   // ── Volume delta (tick volume proxy) ─────────────────────────
   long volCur  = iVolume(_Symbol, PERIOD_M1, 1);
   long volPrev = iVolume(_Symbol, PERIOD_M1, 2);
   bool volBull = (volCur > volPrev);
   bool volBear = (volCur < volPrev);

   // ── Combine all signals ──────────────────────────────────────
   if(stackBull && slopeBull && htfBull && volBull)
      _mmDir = "BULL";
   else if(stackBear && slopeBear && htfBear && volBear)
      _mmDir = "BEAR";
   else
      _mmDir = "NEUTRAL";
}

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE B · ANOMALY DETECTOR                                     ║
//╚══════════════════════════════════════════════════════════════════╝
void MOD_B_AnomalyDetector()
{
   _dangerFlag = false;
   _alertMsg   = "";

   // ── Spread spike check ───────────────────────────────────────
   int spreadNow = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadNow > InpMaxSpread)
   {
      _dangerFlag = true;
      _alertMsg   = "SPREAD SPIKE: " + IntegerToString(spreadNow) + " pts";
      return;
   }

   // ── ATR volatility trap ──────────────────────────────────────
   double atr[], atrPrev[];
   ArraySetAsSeries(atr, true); ArraySetAsSeries(atrPrev, true);
   if(CopyBuffer(hATR, 0, 1, 3, atr) >= 3)
   {
      double atrAvg = (atr[1] + atr[2]) / 2.0;
      if(atrAvg > 0.0 && atr[0] > atrAvg * InpATR_Mult)
      {
         _dangerFlag = true;
         _alertMsg   = "ATR SPIKE: " + DoubleToString(atr[0]/_point, 1) + " pts";
         return;
      }
   }

   // ── Candle body ratio (shadow trap) ─────────────────────────
   double o1 = iOpen(_Symbol,  PERIOD_M1, 1);
   double h1 = iHigh(_Symbol,  PERIOD_M1, 1);
   double l1 = iLow(_Symbol,   PERIOD_M1, 1);
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double range = h1 - l1;
   if(range > 0.0)
   {
      double body = MathAbs(c1 - o1);
      // Doji or huge shadow candle → danger
      if(body / range < 0.1)
      {
         _dangerFlag = true;
         _alertMsg   = "SHADOW TRAP candle";
         return;
      }
   }

   // ── News guard (time-based block) ────────────────────────────
   if(InpNewsGuard)
   {
      // Simple heuristic: block first 5 min of each hour (news risk)
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.min < InpNewsMinutes || dt.min > (60 - InpNewsMinutes))
      {
         _dangerFlag = true;
         _alertMsg   = "NEWS GUARD active";
         return;
      }
   }
}

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE C · ENTRY LOGIC                                          ║
//╚══════════════════════════════════════════════════════════════════╝
void MOD_C_Entry()
{
   // ── 1. Session filter ────────────────────────────────────────
   if(!IsSessionAllowed()) return;

   // ── 2. Momentum: RSI ─────────────────────────────────────────
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(hRSI, 0, 1, 3, rsi) < 3) return;

   // ── 3. Momentum: MACD ────────────────────────────────────────
   double macdMain[], macdSig[];
   ArraySetAsSeries(macdMain, true); ArraySetAsSeries(macdSig, true);
   if(CopyBuffer(hMACD, 0, 1, 3, macdMain) < 3) return;
   if(CopyBuffer(hMACD, 1, 1, 3, macdSig)  < 3) return;

   // ── 4. Candle close confirmation ─────────────────────────────
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double c2 = iClose(_Symbol, PERIOD_M1, 2);

   // ── Evaluate BUY ─────────────────────────────────────────────
   if(_mmDir == "BULL")
   {
      bool rsiOk   = rsi[0] > 50.0 && rsi[0] < 75.0;
      bool macdOk  = macdMain[0] > macdSig[0] && macdMain[0] > 0;
      bool closeOk = c1 > c2;   // Bullish close
      if(rsiOk && macdOk && closeOk)
         OpenTrade(ORDER_TYPE_BUY);
   }
   // ── Evaluate SELL ────────────────────────────────────────────
   else if(_mmDir == "BEAR")
   {
      bool rsiOk   = rsi[0] < 50.0 && rsi[0] > 25.0;
      bool macdOk  = macdMain[0] < macdSig[0] && macdMain[0] < 0;
      bool closeOk = c1 < c2;   // Bearish close
      if(rsiOk && macdOk && closeOk)
         OpenTrade(ORDER_TYPE_SELL);
   }
}

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE D · TP MONITOR (money-based)                             ║
//╚══════════════════════════════════════════════════════════════════╝
void MOD_D_TPMonitor()
{
   if(CountMyPositions() == 0) return;

   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic() != InpMagic) continue;
      if(PosInfo.Symbol() != _Symbol) continue;
      totalProfit += PosInfo.Profit() + PosInfo.Swap() + PosInfo.Commission();
   }

   if(totalProfit >= InpTP_USD)
   {
      CloseAllMyPositions();
      _wonToday++;
      _totalTrades++;
   }
}

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE E · RECOVERY GRID ENGINE                                 ║
//╚══════════════════════════════════════════════════════════════════╝
void MOD_E_RecoveryEngine()
{
   int legs = CountMyPositions();
   if(legs == 0) return;
   if(legs >= InpMaxLegs)
   {
      _alertMsg = "MAX LEGS reached: " + IntegerToString(legs);
      return;
   }

   // Direction of first (oldest) leg
   ENUM_ORDER_TYPE dir = GetOldestLegType();
   if(dir == (ENUM_ORDER_TYPE)WRONG_VALUE) return;

   // ── MM direction must match ───────────────────────────────────
   if(dir == ORDER_TYPE_BUY  && _mmDir != "BULL") return;
   if(dir == ORDER_TYPE_SELL && _mmDir != "BEAR") return;

   // ── Price moved GridStep away from last leg open price ────────
   double lastOpen = GetLastLegOpenPrice();
   double curPrice = (dir == ORDER_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                     : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Convert USD grid distance → price distance (broker-agnostic)
   // _pipVal = USD per point for 0.01 lot  →  priceStep = USD / _pipVal * _point
   double priceStep = (_pipVal > 0.0)
                      ? (InpGridStep / _pipVal) * _point
                      : InpGridStep * _point; // fallback

   bool gapOk = false;
   if(dir == ORDER_TYPE_BUY  && curPrice < lastOpen - priceStep) gapOk = true;
   if(dir == ORDER_TYPE_SELL && curPrice > lastOpen + priceStep) gapOk = true;
   if(!gapOk) return;

   // ── Spread must be acceptable ────────────────────────────────
   if(_dangerFlag) return;

   // ── New bar check for recovery (prevent spam) ─────────────────
   static datetime lastRecovBar = 0;
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar == lastRecovBar) return;
   lastRecovBar = curBar;

   // ── Open recovery leg ─────────────────────────────────────────
   OpenTrade(dir);
   _alertMsg = "Recovery leg " + IntegerToString(legs + 1) + " opened";
}

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE F · ANOMALY RESPONSE (mid-trade)                         ║
//╚══════════════════════════════════════════════════════════════════╝
// Called implicitly: _dangerFlag blocks recovery in MOD_E
// MM flip mid-trade is detected in MOD_A and MOD_E checks _mmDir
// Max legs enforced in MOD_E
// Alert is set via _alertMsg displayed in dashboard

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE G · DYNAMIC DASHBOARD                                    ║
//╚══════════════════════════════════════════════════════════════════╝
void DB_Create()
{
   // Build all labels at startup
   string lbls[] = {
      "title","sep1",
      "lbl_status","val_status",
      "lbl_daily", "val_daily",
      "lbl_mm",    "val_mm",
      "sep2",
      "lbl_legs",  "val_legs",
      "lbl_lots",  "val_lots",
      "lbl_dd",    "val_dd",
      "sep3",
      "lbl_dpnl",  "val_dpnl",
      "lbl_trades","val_trades",
      "lbl_winr",  "val_winr",
      "sep4",
      "lbl_alert", "val_alert",
      "lbl_spread","val_spread",
      "lbl_sess",  "val_sess"
   };
   for(int i = 0; i < ArraySize(lbls); i++)
   {
      ObjectCreate(0, LBL_PREFIX + lbls[i], OBJ_LABEL, 0, 0, 0);
   }
}

void DB_Destroy()
{
   ObjectsDeleteAll(0, LBL_PREFIX);
}

void DB_Update()
{
   // ── Pull chart background colour (dynamic blend) ──────────────
   color bgColor   = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   color panelBg   = BlendColor(bgColor, clrSlateGray, 40);
   color textColor = (color)ChartGetInteger(0, CHART_COLOR_FOREGROUND);

   int  x = 10, y = 20, dy = 18;
   int  panW = 260, panH = 510;

   // ── Background panel (semi-transparent rectangle) ────────────
   string panName = LBL_PREFIX + "bg_panel";
   if(ObjectFind(0, panName) < 0)
      ObjectCreate(0, panName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panName, OBJPROP_XDISTANCE,   x - 5);
   ObjectSetInteger(0, panName, OBJPROP_YDISTANCE,   y - 8);
   ObjectSetInteger(0, panName, OBJPROP_XSIZE,        panW);
   ObjectSetInteger(0, panName, OBJPROP_YSIZE,        panH);
   ObjectSetInteger(0, panName, OBJPROP_BGCOLOR,      panelBg);
   ObjectSetInteger(0, panName, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, panName, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panName, OBJPROP_BACK,         true);

   // ── Status colour logic ──────────────────────────────────────
   color statusCol = _eaActive    ? clrLimeGreen : clrGray;
   color mmCol     = (_mmDir == "BULL") ? clrDodgerBlue
                   : (_mmDir == "BEAR") ? clrTomato : clrGold;
   color alertCol  = _dangerFlag  ? clrOrangeRed  : clrDimGray;
   color pnlCol    = _dailyProfit >= 0 ? clrLimeGreen : clrTomato;

   // Stats
   int   legs      = CountMyPositions();
   double totalDD  = CalcDrawdown();
   int    spreadPt = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double winRate  = (_totalTrades > 0)
                     ? (double)_wonToday / _totalTrades * 100.0 : 0.0;

   // Helper lambda → use function
   DB_Label(LBL_PREFIX+"title",    "★ GoldScalperPro M1 ★",      x+5,  y,    14, textColor, true);
   y += 22;
   DB_Sep(LBL_PREFIX+"sep1", x, y, panW - 10, clrDimGray); y += 6;

   DB_Label(LBL_PREFIX+"lbl_status", "EA Status :",  x,    y, 11, textColor,  false);
   DB_Label(LBL_PREFIX+"val_status",
            _eaActive ? (_dailyDone ? "DAILY DONE" : "ACTIVE") : "OFF",
            x + 100, y, 11, statusCol, true);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_daily",  "Daily Target :", x,   y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_daily",
            "$" + DoubleToString(_dailyProfit,2) + " / $" + DoubleToString(InpDailyTarget,2),
            x + 100, y, 11, pnlCol, false);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_mm",    "MM Direction :", x,   y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_mm",    _mmDir,            x + 100, y, 11, mmCol, true);
   y += dy + 4;
   DB_Sep(LBL_PREFIX+"sep2", x, y, panW - 10, clrDimGray); y += 8;

   DB_Label(LBL_PREFIX+"lbl_legs",  "Open Legs :",   x,   y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_legs",
            IntegerToString(legs) + " / " + IntegerToString(InpMaxLegs),
            x + 110, y, 11, (legs >= InpMaxLegs) ? clrOrangeRed : textColor, false);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_lots",  "Total Lots :",  x,   y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_lots",
            DoubleToString(legs * 0.01, 2) + " lot",
            x + 110, y, 11, textColor, false);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_dd",    "Drawdown :",    x,   y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_dd",
            "$" + DoubleToString(totalDD, 2),
            x + 110, y, 11, (totalDD < -5.0) ? clrOrangeRed : textColor, false);
   y += dy + 4;
   DB_Sep(LBL_PREFIX+"sep3", x, y, panW - 10, clrDimGray); y += 8;

   DB_Label(LBL_PREFIX+"lbl_dpnl",   "Daily P&L :",    x, y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_dpnl",
            "$" + DoubleToString(_dailyProfit, 2),
            x + 110, y, 11, pnlCol, true);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_trades", "Trades Today :", x, y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_trades",
            IntegerToString(_totalTrades),
            x + 110, y, 11, textColor, false);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_winr",   "Win Rate :",     x, y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_winr",
            DoubleToString(winRate, 1) + "%",
            x + 110, y, 11,
            (winRate >= 60.0) ? clrLimeGreen : (winRate >= 40.0) ? clrGold : clrTomato,
            false);
   y += dy + 4;
   DB_Sep(LBL_PREFIX+"sep4", x, y, panW - 10, clrDimGray); y += 8;

   // Alert row
   DB_Label(LBL_PREFIX+"lbl_alert",  "Alert :",       x, y, 11, alertCol, false);
   DB_Label(LBL_PREFIX+"val_alert",
            (_alertMsg != "") ? _alertMsg : "none",
            x + 55, y, 11, alertCol, false);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_spread", "Spread :",      x, y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_spread",
            IntegerToString(spreadPt) + " pts",
            x + 70, y, 11,
            (spreadPt > InpMaxSpread) ? clrOrangeRed : clrLimeGreen,
            false);
   y += dy;

   DB_Label(LBL_PREFIX+"lbl_sess",   "Session :",     x, y, 11, textColor, false);
   DB_Label(LBL_PREFIX+"val_sess",
            IsSessionAllowed() ? "ACTIVE" : "CLOSED",
            x + 70, y, 11,
            IsSessionAllowed() ? clrLimeGreen : clrGray,
            false);
}

void DB_Label(string name, string text, int x, int y, int fs,
              color clr, bool bold)
{
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_UPPER);
   ObjectSetString(0,  name, OBJPROP_TEXT,         text);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     fs);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        clr);
   ObjectSetString(0,  name, OBJPROP_FONT,         bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
}

void DB_Sep(string name, int x, int y, int w, color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   string dashes = "";
   for(int i = 0; i < w / 6; i++) dashes += "-";
   DB_Label(name, dashes, x, y, 8, clr, false);
}

// Blend two colours with weight (0-100) toward col2
color BlendColor(color col1, color col2, int weight)
{
   int r1 = (col1 >> 16) & 0xFF, g1 = (col1 >> 8) & 0xFF, b1 = col1 & 0xFF;
   int r2 = (col2 >> 16) & 0xFF, g2 = (col2 >> 8) & 0xFF, b2 = col2 & 0xFF;
   int r  = r1 + (r2 - r1) * weight / 100;
   int g  = g1 + (g2 - g1) * weight / 100;
   int b  = b1 + (b2 - b1) * weight / 100;
   return (color)((r << 16) | (g << 8) | b);
}

//╔══════════════════════════════════════════════════════════════════╗
//║  MODULE H · BUG GUARDS & UTILITY FUNCTIONS                       ║
//╚══════════════════════════════════════════════════════════════════╝

// ── Open a trade with retry on requote/price-changed ─────────────
void OpenTrade(ENUM_ORDER_TYPE type)
{
   int    maxRetries = 3;
   int    attempt    = 0;
   bool   ok         = false;

   while(attempt < maxRetries)
   {
      attempt++;

      // Always fetch a fresh tick before each attempt
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick))
      {
         Print("OpenTrade: SymbolInfoTick failed | attempt=", attempt);
         break;
      }

      double price = (type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
      double sl    = 0.0;  // No SL — managed by recovery engine
      double tp    = 0.0;  // No broker TP — managed by money TP monitor

      if(type == ORDER_TYPE_BUY)
         ok = Trade.Buy(0.01, _Symbol, price, sl, tp, InpComment);
      else
         ok = Trade.Sell(0.01, _Symbol, price, sl, tp, InpComment);

      if(ok)
      {
         Print("OpenTrade OK | type=", EnumToString(type),
               " | price=", price,
               " | ticket=", Trade.ResultOrder(),
               " | attempt=", attempt);
         return;
      }

      // Check retcode from Trade server (not GetLastError which is client-side)
      uint rc = Trade.ResultRetcode();
      Print("OpenTrade failed | type=", EnumToString(type),
            " | price=", price,
            " | retcode=", rc,
            " | comment=", Trade.ResultRetcodeDescription(),
            " | attempt=", attempt);

      // Retry only on price-related rejections
      if(rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
         rc == TRADE_RETCODE_PRICE_OFF)
      {
         if(attempt < maxRetries)
         {
            Sleep(200); // wait 200 ms then retry with fresh price
            continue;
         }
      }

      // Any other error: stop retrying immediately
      break;
   }

   if(!ok)
   {
      Print("OpenTrade ABORTED after ", attempt, " attempt(s)");
   }
}

// ── Close all positions of this EA ───────────────────────────────
void CloseAllMyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic()  != InpMagic)  continue;
      if(PosInfo.Symbol() != _Symbol)   continue;
      if(!Trade.PositionClose(PosInfo.Ticket(), 30))
      {
         Print("ClosePosition failed | ticket=", PosInfo.Ticket(),
               " | err=", GetLastError());
      }
   }
}

// ── Count open positions of this EA ─────────────────────────────
int CountMyPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic()  != InpMagic)  continue;
      if(PosInfo.Symbol() != _Symbol)   continue;
      cnt++;
   }
   return cnt;
}

// ── Get oldest position type ─────────────────────────────────────
ENUM_ORDER_TYPE GetOldestLegType()
{
   datetime oldest  = LONG_MAX; // init to max so first real time always wins
   int      oldType = -1;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i))    continue;
      if(PosInfo.Magic()  != InpMagic) continue;
      if(PosInfo.Symbol() != _Symbol)  continue;
      if((long)PosInfo.Time() < (long)oldest)
      {
         oldest  = PosInfo.Time();
         oldType = (int)PosInfo.PositionType();
      }
   }
   if(oldType == -1) return (ENUM_ORDER_TYPE)WRONG_VALUE;
   return (ENUM_ORDER_TYPE)oldType;
}

// ── Get last leg open price ───────────────────────────────────────
double GetLastLegOpenPrice()
{
   datetime newest = 0;
   double   price  = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i))    continue;
      if(PosInfo.Magic()  != InpMagic) continue;
      if(PosInfo.Symbol() != _Symbol)  continue;
      if(PosInfo.Time() >= newest)
      {
         newest = PosInfo.Time();
         price  = PosInfo.PriceOpen();
      }
   }
   return price;
}

// ── Calc daily profit (closed + open floating) ───────────────────
double CalcDailyProfit()
{
   // Floating P&L
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic()  != InpMagic) continue;
      if(PosInfo.Symbol() != _Symbol)  continue;
      floating += PosInfo.Profit() + PosInfo.Swap() + PosInfo.Commission();
   }

   // Closed deals today
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   HistorySelect(dayStart, TimeCurrent());
   double closed = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)  continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         closed += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return floating + closed;
}

// ── Calculate current drawdown ────────────────────────────────────
double CalcDrawdown()
{
   double dd = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PosInfo.SelectByIndex(i)) continue;
      if(PosInfo.Magic()  != InpMagic) continue;
      if(PosInfo.Symbol() != _Symbol)  continue;
      double p = PosInfo.Profit() + PosInfo.Swap() + PosInfo.Commission();
      if(p < 0.0) dd += p;
   }
   return dd;
}

// ── Session check ─────────────────────────────────────────────────
bool IsSessionAllowed()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   // London: 07:00–16:00 GMT | New York: 12:00–21:00 GMT
   bool london = InpLondonSession && (h >= 7  && h < 16);
   bool newYork = InpNYSession    && (h >= 12 && h < 21);
   return (london || newYork);
}

// ── Reset daily stats at midnight ─────────────────────────────────
void OnTimer()
{
   static datetime lastDate = 0;
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today != lastDate && lastDate != 0)
   {
      _dailyDone   = false;
      _dailyProfit = 0.0;
      _totalTrades = 0;
      _wonToday    = 0;
   }
   lastDate = today;
}
//+------------------------------------------------------------------+