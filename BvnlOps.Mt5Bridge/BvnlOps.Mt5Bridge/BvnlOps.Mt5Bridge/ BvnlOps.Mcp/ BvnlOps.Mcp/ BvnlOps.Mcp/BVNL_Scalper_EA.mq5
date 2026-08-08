//+------------------------------------------------------------------+
//|                                              BVNL_Scalper_EA.mq5 |
//|            BVNL Solution — 1m/5m Hybrid ICT & Indicator Scalper  |
//|                                         v2.1 — Trade + Trail      |
//|                                                                   |
//| v2.1 fixes vs v2.0:                                              |
//|   • Killzone default OFF — trades any hour (was blocking trades) |
//|   • Confidence floor lowered to 65% (was 75% — too strict)      |
//|   • Signal-candle direction gate REMOVED (was blocking retests)  |
//|   • D1 gate now configurable (InpUsD1Gate)                       |
//|   • ATR trailing stop added — SL follows price as profit builds  |
//|     Trail starts after InpTrailStartR × SL-distance in profit    |
//|     Trail distance = InpTrailATR × ATR behind current price      |
//|                                                                   |
//| Weights (total 100):                                             |
//|   Trend H4+D1   20%   RSI MTF    15%   MACD       15%           |
//|   Volume        15%   Candle     10%   Structure  10%           |
//|   R:R quality   10%   Session     5%                             |
//|                                                                   |
//| Demo/cent account first. Not financial advice.                   |
//+------------------------------------------------------------------+
#property copyright "BVNL Solution"
#property version   "2.10"
#property description "BVNL Scalper v2.1: 8-factor confluence, ATR trailing stop, always-on trading."

#include <Trade\Trade.mqh>

//--- BVNL 8-Factor weights — must total 100
#define W_TREND      20.0
#define W_RSI        15.0
#define W_MACD       15.0
#define W_VOLUME     15.0
#define W_CANDLE     10.0
#define W_STRUCTURE  10.0
#define W_RR         10.0
#define W_SESSION     5.0

//==================== INPUTS ====================
input group "=== Timeframes & Bias ==="
input ENUM_TIMEFRAMES InpEntryTF        = PERIOD_M5;   // Entry timeframe (M1 or M5)
input ENUM_TIMEFRAMES InpBiasTF         = PERIOD_H4;   // H4 bias timeframe
input ENUM_TIMEFRAMES InpDailyTF        = PERIOD_D1;   // D1 trend gate
input int             InpBiasEmaFast    = 21;          // Bias fast EMA (H4 and D1)
input int             InpBiasEmaSlow    = 50;          // Bias slow EMA (H4 and D1)
input bool            InpTradeNeutral   = false;       // Trade when H4 is neutral
input bool            InpUsD1Gate       = true;        // Block trades if D1 opposes H4

input group "=== Killzones (GMT hours) ==="
input bool            InpRequireKillzone = false;      // Require killzone (OFF = trade any time)
input double          InpLondonStart    = 7.0;
input double          InpLondonEnd      = 10.0;
input double          InpNYStart        = 12.0;
input double          InpNYEnd          = 15.0;

input group "=== Indicators ==="
input int             InpEmaFast        = 8;
input int             InpEmaSlow        = 21;
input int             InpEmaFilter      = 50;
input int             InpRSIPeriod      = 14;
input double          InpRSIBuyMin      = 52.0;        // RSI floor for BUY
input double          InpRSISellMax     = 48.0;        // RSI ceiling for SELL
input int             InpMacdFast       = 12;
input int             InpMacdSlow       = 26;
input int             InpMacdSignal     = 9;
input int             InpStochK         = 14;
input int             InpStochD         = 3;
input int             InpStochSlow      = 3;
input int             InpATRPeriod      = 14;
input int             InpSwingLookback  = 20;
input double          InpMaxSpreadPts   = 30.0;        // 30 pts ≈ $0.30 XAUUSD

input group "=== Confluence ==="
input double          InpMinConfidence  = 65.0;        // Min confidence % (lowered from 75)

input group "=== Trailing Stop ==="
input bool            InpUseTrail       = true;        // Enable ATR trailing stop
input double          InpTrailStartR    = 0.5;         // Start trailing after X × SL-dist in profit
input double          InpTrailATR       = 1.5;         // Trail distance = X × ATR behind price

input group "=== Risk & Exits ==="
input double          InpRiskPercent    = 1.0;         // Risk per trade (% equity)
input double          InpSLBufferATR    = 0.3;         // Extra SL buffer (× ATR)
input double          InpRR_TP1         = 2.0;         // TP1 R:R
input double          InpRR_TP2         = 3.0;         // TP2 R:R (final target)
input double          InpPartialPct     = 50.0;        // % closed at TP1
input bool            InpMoveToBE       = true;        // Move SL to +0.5R at TP1
input double          InpDailyLossPct   = 3.0;         // Daily loss circuit breaker
input int             InpCooldownMin    = 5;           // Cooldown between trades (min)

input group "=== System ==="
input long            InpMagicNumber    = 20260726;
input string          InpSignalFile     = "WTDA_signal.json";
input int             InpSlippagePts    = 20;

//==================== GLOBALS ====================
CTrade   g_trade;
int      hEmaFast, hEmaSlow, hEmaFilter;
int      hRSI, hRSI_H4;
int      hMACD;
int      hStoch, hATR;
int      hBiasFast, hBiasSlow;
int      hD1Fast, hD1Slow;
datetime g_lastBar      = 0;
datetime g_lastTrade    = 0;
string   g_gvTrade      = "";
string   g_gvDayEquity  = "";
double   g_dayStartEquity = 0.0;
int      g_dayStamp     = -1;
bool     g_tp1Done      = false;
ulong    g_ticket       = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   hEmaFast   = iMA(_Symbol, InpEntryTF, InpEmaFast,   0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow   = iMA(_Symbol, InpEntryTF, InpEmaSlow,   0, MODE_EMA, PRICE_CLOSE);
   hEmaFilter = iMA(_Symbol, InpEntryTF, InpEmaFilter, 0, MODE_EMA, PRICE_CLOSE);
   hRSI       = iRSI(_Symbol, InpEntryTF, InpRSIPeriod, PRICE_CLOSE);
   hRSI_H4    = iRSI(_Symbol, InpBiasTF,  InpRSIPeriod, PRICE_CLOSE);
   hMACD      = iMACD(_Symbol, InpEntryTF, InpMacdFast, InpMacdSlow, InpMacdSignal, PRICE_CLOSE);
   hStoch     = iStochastic(_Symbol, InpEntryTF, InpStochK, InpStochD, InpStochSlow, MODE_SMA, STO_LOWHIGH);
   hATR       = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   hBiasFast  = iMA(_Symbol, InpBiasTF, InpBiasEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hBiasSlow  = iMA(_Symbol, InpBiasTF, InpBiasEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hD1Fast    = iMA(_Symbol, InpDailyTF, InpBiasEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hD1Slow    = iMA(_Symbol, InpDailyTF, InpBiasEmaSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(hEmaFast==INVALID_HANDLE || hEmaSlow==INVALID_HANDLE || hEmaFilter==INVALID_HANDLE ||
      hRSI==INVALID_HANDLE     || hRSI_H4==INVALID_HANDLE  || hMACD==INVALID_HANDLE      ||
      hStoch==INVALID_HANDLE   || hATR==INVALID_HANDLE      ||
      hBiasFast==INVALID_HANDLE || hBiasSlow==INVALID_HANDLE ||
      hD1Fast==INVALID_HANDLE   || hD1Slow==INVALID_HANDLE)
     {
      Print("BVNL Scalper v2.1: indicator handle failed, err=", GetLastError());
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_gvTrade     = "BVNLScalp_LastTrade_" + _Symbol + "_" + (string)InpMagicNumber;
   g_gvDayEquity = "BVNLScalp_DayEq_"     + _Symbol + "_" + (string)InpMagicNumber;
   if(GlobalVariableCheck(g_gvTrade))
      g_lastTrade = (datetime)GlobalVariableGet(g_gvTrade);

   ResetDailyBaseline(true);
   PrintFormat("BVNL Scalper EA v2.1 | %s | %s entry | KZ=%s | Trail=%s | conf>=%.0f%% | risk=%.1f%%",
               _Symbol, EnumToString(InpEntryTF),
               InpRequireKillzone?"ON":"OFF",
               InpUseTrail?"ON":"OFF",
               InpMinConfidence, InpRiskPercent);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(hEmaFast);   IndicatorRelease(hEmaSlow);   IndicatorRelease(hEmaFilter);
   IndicatorRelease(hRSI);       IndicatorRelease(hRSI_H4);    IndicatorRelease(hMACD);
   IndicatorRelease(hStoch);     IndicatorRelease(hATR);
   IndicatorRelease(hBiasFast);  IndicatorRelease(hBiasSlow);
   IndicatorRelease(hD1Fast);    IndicatorRelease(hD1Slow);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(HasOpenPosition())
     {
      TrailStop();      // push SL forward every tick as price moves
      ManagePosition(); // partial close + +0.5R at TP1
      return;
     }
   g_tp1Done = false;
   g_ticket  = 0;

   if(!IsNewBar()) return;

   ResetDailyBaseline(false);
   if(DailyLimitHit())
     {
      static datetime warned = 0;
      if(iTime(_Symbol, InpEntryTF, 0) != warned)
        { Print("BVNL Scalper v2.1: daily loss limit — no new trades today."); warned = iTime(_Symbol, InpEntryTF, 0); }
      return;
     }
   if(CooldownRemaining() > 0) return;

   if((double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPts)
     {
      static datetime swarn = 0;
      if(iTime(_Symbol, InpEntryTF, 0) != swarn)
        {
         PrintFormat("BVNL Scalper v2.1: spread %d pts > %.0f — skipping bar.",
                     (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), InpMaxSpreadPts);
         swarn = iTime(_Symbol, InpEntryTF, 0);
        }
      return;
     }

   EvaluateSetup();
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, InpEntryTF, 0);
   if(t == 0) return(false);
   if(g_lastBar == 0) { g_lastBar = t; return(false); }
   if(t != g_lastBar) { g_lastBar = t; return(true); }
   return(false);
  }

bool HasOpenPosition()
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        { g_ticket = (ulong)PositionGetInteger(POSITION_TICKET); return(true); }
     }
   return(false);
  }

long CooldownRemaining()
  {
   if(g_lastTrade == 0) return(0);
   long el   = (long)(TimeCurrent() - g_lastTrade);
   long need = (long)InpCooldownMin * 60;
   return(el >= need ? 0 : need - el);
  }

void ResetDailyBaseline(bool force)
  {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int stamp = dt.year * 1000 + dt.day_of_year;
   if(force || stamp != g_dayStamp)
     {
      g_dayStamp = stamp;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      GlobalVariableSet(g_gvDayEquity, g_dayStartEquity);
     }
   else if(GlobalVariableCheck(g_gvDayEquity))
      g_dayStartEquity = GlobalVariableGet(g_gvDayEquity);
  }

bool DailyLimitHit()
  {
   if(g_dayStartEquity <= 0.0) return(false);
   return(AccountInfoDouble(ACCOUNT_EQUITY) <= g_dayStartEquity * (1.0 - InpDailyLossPct/100.0));
  }

bool CopyOne(int handle, int buf, double &dst[], int count)
  {
   ArraySetAsSeries(dst, true);
   return(CopyBuffer(handle, buf, 0, count, dst) >= count);
  }

int GetBias(int hFast, int hSlow, ENUM_TIMEFRAMES tf)
  {
   double bf[], bs[];
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(!CopyOne(hFast, 0, bf, 2) || !CopyOne(hSlow, 0, bs, 2)) return(0);
   if(CopyRates(_Symbol, tf, 0, 2, r) < 2) return(0);
   double c = r[1].close;
   if(bf[1] > bs[1] && c > bf[1]) return(+1);
   if(bf[1] < bs[1] && c < bf[1]) return(-1);
   return(0);
  }

bool InKillzone()
  {
   MqlDateTime g; TimeToStruct(TimeGMT(), g);
   double h = g.hour + g.min / 60.0;
   return((h >= InpLondonStart && h < InpLondonEnd) || (h >= InpNYStart && h < InpNYEnd));
  }

double CandleScore(const MqlRates &r[], int dir)
  {
   double o1=r[1].open, c1=r[1].close, h1=r[1].high, l1=r[1].low;
   double o2=r[2].open, c2=r[2].close;
   double body1=MathAbs(c1-o1), range1=h1-l1;
   if(range1 <= 0.0) return(0.0);
   double lw = MathMin(o1,c1)-l1;
   double uw = h1-MathMax(o1,c1);
   if(dir > 0)
     {
      if(c1>MathMax(o2,c2) && o1<MathMin(o2,c2) && c1>o1)          return(1.0);
      if(c1>o1 && lw>=2.0*body1 && uw<=0.5*body1)                   return(1.0);
      if(c1>o1 && body1>=0.4*range1)                                 return(0.5);
     }
   else
     {
      if(c1<MathMin(o2,c2) && o1>MathMax(o2,c2) && c1<o1)          return(1.0);
      if(c1<o1 && uw>=2.0*body1 && lw<=0.5*body1)                   return(1.0);
      if(c1<o1 && body1>=0.4*range1)                                 return(0.5);
     }
   return(0.0);
  }

//+------------------------------------------------------------------+
//| ATR trailing stop — called every tick while position is open     |
//+------------------------------------------------------------------+
void TrailStop()
  {
   if(!InpUseTrail) return;
   if(!PositionSelectByTicket(g_ticket)) return;

   bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double open   = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL  = PositionGetDouble(POSITION_SL);
   double curTP  = PositionGetDouble(POSITION_TP);
   double slDist = MathAbs(open - curSL);
   if(slDist <= 0.0) return;

   double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profit = isBuy ? px - open : open - px;

   // Only start trailing once InpTrailStartR × SL-distance in profit
   if(profit < slDist * InpTrailStartR) return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 0, 2, atr) < 2) return;

   int    digs  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double trail = InpTrailATR * atr[1];
   double newSL = NormalizeDouble(isBuy ? px - trail : px + trail, digs);

   // Never move SL backward — only forward in profit direction
   if(isBuy  && newSL <= curSL) return;
   if(!isBuy && newSL >= curSL) return;

   // Never trail into / past TP
   if(isBuy  && curTP > 0.0 && newSL >= curTP) return;
   if(!isBuy && curTP > 0.0 && newSL <= curTP) return;

   if(!g_trade.PositionModify(g_ticket, newSL, curTP))
      PrintFormat("BVNL Scalper v2.1: trail modify failed rc=%u", g_trade.ResultRetcode());
   else
      PrintFormat("BVNL Scalper v2.1: SL trailed → %s (ATR=%.5f)", DoubleToString(newSL, digs), atr[1]);
  }

//+------------------------------------------------------------------+
//| TP1: partial close + move SL to +0.5R                           |
//+------------------------------------------------------------------+
void ManagePosition()
  {
   if(g_tp1Done) return;
   if(!PositionSelectByTicket(g_ticket)) return;

   bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double open   = PositionGetDouble(POSITION_PRICE_OPEN);
   double posSL  = PositionGetDouble(POSITION_SL);
   double vol    = PositionGetDouble(POSITION_VOLUME);
   double slDist = MathAbs(open - posSL);
   if(slDist <= 0.0) return;

   double tp1 = isBuy ? open+slDist*InpRR_TP1 : open-slDist*InpRR_TP1;
   double px  = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(isBuy ? (px < tp1) : (px > tp1)) return;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double closeV = vol * InpPartialPct / 100.0;
   if(step > 0.0) closeV = MathFloor(closeV/step)*step;
   if(closeV >= minL && (vol - closeV) >= minL)
     {
      if(!g_trade.PositionClosePartial(g_ticket, closeV))
         PrintFormat("BVNL Scalper v2.1: partial close failed rc=%u", g_trade.ResultRetcode());
      else
         Print("BVNL Scalper v2.1: TP1 hit — partial closed, runner to TP2.");
     }

   // Move SL to +0.5R so runner is guaranteed profit even if stopped
   if(InpMoveToBE && PositionSelectByTicket(g_ticket))
     {
      int    digs  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double curTP = PositionGetDouble(POSITION_TP);
      double curSL = PositionGetDouble(POSITION_SL);
      double newSL = NormalizeDouble(isBuy ? open+slDist*0.5 : open-slDist*0.5, digs);
      // Only move forward — don't override a trail that already pushed further
      bool shouldMove = (isBuy && newSL > curSL) || (!isBuy && newSL < curSL);
      if(shouldMove)
        {
         if(!g_trade.PositionModify(g_ticket, newSL, curTP))
            PrintFormat("BVNL Scalper v2.1: SL→+0.5R failed rc=%u", g_trade.ResultRetcode());
         else
            PrintFormat("BVNL Scalper v2.1: SL→+0.5R (%s) — runner protected.", DoubleToString(newSL, digs));
        }
     }
   g_tp1Done = true;
  }

//+------------------------------------------------------------------+
void EvaluateSetup()
  {
   int need = InpSwingLookback + 6;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, InpEntryTF, 0, need, r) < need)
     { Print("BVNL Scalper v2.1: not enough history."); return; }

   double emaF[], emaS[], emaFl[];
   double rsi[], rsiH4[];
   double macdMain[], macdSig[];
   double stoK[], stoD[], atr[];

   if(!CopyOne(hEmaFast,         0, emaF,    3)) return;
   if(!CopyOne(hEmaSlow,         0, emaS,    3)) return;
   if(!CopyOne(hEmaFilter,       0, emaFl,   3)) return;
   if(!CopyOne(hRSI,             0, rsi,     3)) return;
   if(!CopyOne(hRSI_H4,          0, rsiH4,   3)) return;
   if(!CopyOne(hMACD, MAIN_LINE,   macdMain, 4)) return;
   if(!CopyOne(hMACD, SIGNAL_LINE, macdSig,  4)) return;
   if(!CopyOne(hStoch, MAIN_LINE,   stoK,    4)) return;
   if(!CopyOne(hStoch, SIGNAL_LINE, stoD,    4)) return;
   if(!CopyOne(hATR,             0, atr,     3)) return;

   //--- GATE 1: H4 direction ---
   int h4Bias = GetBias(hBiasFast, hBiasSlow, InpBiasTF);
   int dir = 0;
   if(h4Bias > 0)           dir = +1;
   else if(h4Bias < 0)      dir = -1;
   else if(!InpTradeNeutral) return;
   if(dir == 0) return;

   //--- GATE 2: D1 must not oppose H4 (configurable) ---
   int d1Bias = GetBias(hD1Fast, hD1Slow, InpDailyTF);
   if(InpUsD1Gate && d1Bias != 0 && d1Bias != dir) return;

   //--- GATE 3: Killzone (OFF by default) ---
   bool kz = InKillzone();
   if(InpRequireKillzone && !kz) return;

   //--- Swing range ---
   double swingHigh = -DBL_MAX, swingLow = DBL_MAX;
   for(int i = 2; i < 2 + InpSwingLookback; i++)
     { swingHigh = MathMax(swingHigh, r[i].high); swingLow = MathMin(swingLow, r[i].low); }
   double impulse = swingHigh - swingLow;
   if(impulse <= 0.0) return;

   double buf    = InpSLBufferATR * atr[1];
   double sl     = (dir>0) ? swingLow - buf : swingHigh + buf;
   double c      = r[1].close;
   double slDist = MathAbs(c - sl);
   if(slDist <= 0.0) return;

   //====================================================
   //  BVNL 8-FACTOR CONFLUENCE SCORING
   //====================================================
   string reason = "";
   double score  = 0.0;

   //--- Factor 1: TREND 20% ---
   score += W_TREND;
   if(d1Bias == dir)
      reason += (dir>0 ? "D1+H4 bull; " : "D1+H4 bear; ");
   else
      reason += (dir>0 ? "H4 bull; " : "H4 bear; ");

   //--- Factor 2: RSI MTF 15% ---
   bool rsiEntryFit = (dir>0) ? (rsi[1]   > InpRSIBuyMin)  : (rsi[1]   < InpRSISellMax);
   bool rsiH4Fit    = (dir>0) ? (rsiH4[1] > 50.0)          : (rsiH4[1] < 50.0);
   if(rsiEntryFit && rsiH4Fit)    { score += W_RSI;      reason += "RSI MTF; "; }
   else if(rsiEntryFit || rsiH4Fit){ score += W_RSI*0.5;  reason += "RSI partial; "; }

   //--- Factor 3: MACD 15% ---
   double hist1 = macdMain[1]-macdSig[1];
   double hist2 = macdMain[2]-macdSig[2];
   double hist3 = macdMain[3]-macdSig[3];
   bool macdDir   = (dir>0) ? (hist1>0.0) : (hist1<0.0);
   bool macdGrow  = (dir>0) ? (hist1>hist2) : (hist1<hist2);
   bool macdCross = (dir>0) ? (hist3<=0.0&&hist1>0.0) : (hist3>=0.0&&hist1<0.0);
   if(macdDir&&macdGrow&&macdCross) { score += W_MACD;     reason += "MACD cross+grow; "; }
   else if(macdDir&&macdGrow)       { score += W_MACD*0.7; reason += "MACD growing; "; }
   else if(macdDir)                 { score += W_MACD*0.4; reason += "MACD aligned; "; }

   //--- Factor 4: VOLUME 15% ---
   double avgVol = 0.0;
   int    vbars  = MathMin(10, need-2);
   for(int i = 2; i < 2+vbars; i++) avgVol += (double)r[i].tick_volume;
   avgVol /= vbars;
   bool volSpike = (avgVol>0.0 && (double)r[1].tick_volume >= 1.2*avgVol);
   bool atrExp   = (atr[1] >= atr[2]);
   if(volSpike && atrExp)       { score += W_VOLUME;     reason += "vol spike+ATR; "; }
   else if(volSpike || atrExp)  { score += W_VOLUME*0.6; reason += (volSpike?"vol spike; ":"ATR exp; "); }

   //--- Factor 5: CANDLESTICK 10% ---
   double cs = CandleScore(r, dir);
   if(cs >= 1.0)      { score += W_CANDLE;     reason += "candle pattern; "; }
   else if(cs >= 0.5) { score += W_CANDLE*0.5; reason += "candle ok; "; }

   //--- Factor 6: STRUCTURE 10% ---
   double lo=r[1].low, hi=r[1].high;
   double minorHigh=-DBL_MAX, minorLow=DBL_MAX;
   for(int i=2; i<7; i++) { minorHigh=MathMax(minorHigh,r[i].high); minorLow=MathMin(minorLow,r[i].low); }
   bool mss   = (dir>0 && c>minorHigh && r[2].close<=minorHigh)
             || (dir<0 && c<minorLow  && r[2].close>=minorLow);
   bool sweep = (dir>0 && lo<swingLow  && c>swingLow)
             || (dir<0 && hi>swingHigh && c<swingHigh);
   double oteMin,oteMax;
   if(dir>0){ oteMin=swingHigh-0.79*impulse; oteMax=swingHigh-0.62*impulse; }
   else     { oteMin=swingLow+0.62*impulse;  oteMax=swingLow+0.79*impulse;  }
   bool ote=(c>=oteMin&&c<=oteMax);
   int sc=(mss?1:0)+(sweep?1:0)+(ote?1:0);
   if(sc>=2)    { score+=W_STRUCTURE;     reason+="struct 2/3; "; }
   else if(sc==1){ score+=W_STRUCTURE*0.5; reason+=(mss?"MSS; ":sweep?"liq sweep; ":"OTE; "); }

   //--- Factor 7: R:R QUALITY 10% ---
   double rrR=(atr[1]>0.0)?slDist/atr[1]:999.0;
   if(rrR<=1.5)       { score+=W_RR;     reason+="tight SL; "; }
   else if(rrR<=2.5)  { score+=W_RR*0.5; reason+="ok SL; "; }

   //--- Factor 8: SESSION 5% ---
   bool emaStack  = (dir>0&&emaF[1]>emaS[1]&&emaS[1]>emaFl[1])
                 || (dir<0&&emaF[1]<emaS[1]&&emaS[1]<emaFl[1]);
   bool stochBuy  = (stoK[1]>stoD[1]&&stoK[2]<=stoD[2]&&stoK[2]<40.0);
   bool stochSell = (stoK[1]<stoD[1]&&stoK[2]>=stoD[2]&&stoK[2]>60.0);
   bool stochFit  = (dir>0&&stochBuy)||(dir<0&&stochSell);
   if(kz&&emaStack&&stochFit)        { score+=W_SESSION;     reason+="KZ+EMA+Stoch; "; }
   else if(kz&&(emaStack||stochFit)) { score+=W_SESSION*0.6; reason+="KZ+ind; "; }
   else if(kz)                       { score+=W_SESSION*0.4; reason+="KZ; "; }
   else if(emaStack&&stochFit)       { score+=W_SESSION*0.3; reason+="EMA+Stoch; "; }
   else if(emaStack||stochFit)       { score+=W_SESSION*0.2; reason+=(emaStack?"EMA stack; ":"Stoch; "); }

   PrintFormat("BVNL Scalper v2.1 %s %s | conf=%.0f%% [%s]",
               _Symbol, (dir>0?"LONG":"SHORT"), score, reason);

   if(score < InpMinConfidence) return;

   if(StringLen(reason)>=2) reason=StringSubstr(reason,0,StringLen(reason)-2);
   PlaceTrade(dir, score, reason, sl);
  }

//+------------------------------------------------------------------+
void PlaceTrade(int dir, double confidence, string reason, double sl)
  {
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double entry  = (dir>0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entry<=0.0) { Print("BVNL Scalper v2.1: no price."); return; }

   double slDist  = MathAbs(entry-sl);
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(slDist<minDist) { slDist=minDist; sl=(dir>0)?entry-slDist:entry+slDist; }
   if(slDist<=0.0) return;

   double tp1 = (dir>0) ? entry+slDist*InpRR_TP1 : entry-slDist*InpRR_TP1;
   double tp2 = NormalizeDouble((dir>0)?entry+slDist*InpRR_TP2:entry-slDist*InpRR_TP2, digits);
   sl         = NormalizeDouble(sl, digits);

   double lots = CalcLot(slDist);
   if(lots<=0.0) { Print("BVNL Scalper v2.1: lot calc failed."); return; }

   string id = StringFormat("%s-%s-%I64d", _Symbol, (dir>0?"BUY":"SELL"), (long)TimeCurrent());
   WriteSignal(id, (dir>0?"BUY":"SELL"), entry, sl, tp2, tp1, confidence, reason);

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)||!MQLInfoInteger(MQL_TRADE_ALLOWED))
     { Print("BVNL Scalper v2.1: algo trading disabled — signal written only."); return; }

   double fill=0.0;
   if(SendOrder(dir>0, lots, sl, tp2, StringFormat("BVNL %.0f%%", confidence), fill))
     {
      g_lastTrade=TimeCurrent();
      GlobalVariableSet(g_gvTrade,(double)g_lastTrade);
      g_tp1Done=false;
      PrintFormat("BVNL Scalper v2.1: %s %.2f lots @ %s | SL %s | TP2 %s | conf=%.0f%% | %s",
                  (dir>0?"BUY":"SELL"), lots, DoubleToString(fill,digits),
                  DoubleToString(sl,digits), DoubleToString(tp2,digits), confidence, reason);
     }
   else
      Print("BVNL Scalper v2.1: order failed — EA continues watching.");
  }

//+------------------------------------------------------------------+
double CalcLot(double slDist)
  {
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk= eq*InpRiskPercent/100.0;
   double tv  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(slDist<=0.0||tv<=0.0||ts<=0.0) return(0.0);
   double lpl = slDist/ts*tv;
   if(lpl<=0.0) return(0.0);
   double lots= risk/lpl;
   double step= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step>0.0) lots=MathFloor(lots/step)*step;
   if(lots<minL){ PrintFormat("BVNL v2.1: lot %.2f<min %.2f — using min.",lots,minL); lots=minL; }
   if(lots>maxL) lots=maxL;
   return(NormalizeDouble(lots,2));
  }

//+------------------------------------------------------------------+
bool SendOrder(bool isBuy, double lots, double sl, double tp, string comment, double &fill)
  {
   for(int a=1;a<=3;a++)
     {
      ResetLastError();
      bool ok=isBuy?g_trade.Buy(lots,_Symbol,0.0,sl,tp,comment)
                   :g_trade.Sell(lots,_Symbol,0.0,sl,tp,comment);
      uint rc=g_trade.ResultRetcode();
      if(ok&&(rc==TRADE_RETCODE_DONE||rc==TRADE_RETCODE_DONE_PARTIAL||rc==TRADE_RETCODE_PLACED))
        { fill=g_trade.ResultPrice(); return(true); }
      PrintFormat("BVNL v2.1: OrderSend %d/3 failed rc=%u err=%d",a,rc,GetLastError());
      if(rc==TRADE_RETCODE_TRADE_DISABLED||rc==TRADE_RETCODE_MARKET_CLOSED||rc==TRADE_RETCODE_NO_MONEY) break;
      Sleep(400);
     }
   return(false);
  }

//+------------------------------------------------------------------+
void WriteSignal(string id, string dir, double entry, double sl, double tp,
                 double tp1, double conf, string reason)
  {
   int fh=FileOpen(InpSignalFile,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(fh==INVALID_HANDLE)
     { PrintFormat("BVNL v2.1: cannot open %s err=%d",InpSignalFile,GetLastError()); return; }
   int d=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   FileWriteString(fh,
      "{\n"
      "  \"id\": \""         +id                        +"\",\n"
      "  \"symbol\": \""     +_Symbol                   +"\",\n"
      "  \"direction\": \""  +dir                       +"\",\n"
      "  \"entry\": "        +DoubleToString(entry,d)   +",\n"
      "  \"stopLoss\": "     +DoubleToString(sl,d)      +",\n"
      "  \"takeProfit\": "   +DoubleToString(tp,d)      +",\n"
      "  \"tp1\": "          +DoubleToString(tp1,d)     +",\n"
      "  \"confidence\": "   +DoubleToString(conf,0)    +",\n"
      "  \"reason\": \""     +reason                    +"\",\n"
      "  \"strategy\": \"BVNL 1m/5m ICT Scalper v2.1\",\n"
      "  \"time\": \""       +TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+"\"\n"
      "}\n");
   FileClose(fh);
   Print("BVNL v2.1: signal written → ",InpSignalFile);
  }
//+------------------------------------------------------------------+
