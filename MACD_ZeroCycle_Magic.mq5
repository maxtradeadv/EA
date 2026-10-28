
//+------------------------------------------------------------------+
//| MACD_ZeroCycle_Magic_v1.35_3Mountain_HistogramPeak.mq5                    |
//| 3-Mountain BUY filter; per-position SELL on histogram power fade |
//+------------------------------------------------------------------+
#property strict
#property version "1.35"
#property description "MACD ZeroCycle with active 3-mountain BUY filter and per-position histogram peak SELL"

#include <Trade/Trade.mqh>
CTrade trade;

//--- General and margin sizing
input double InpLots                     = 0.01; // Maximum lot per BUY; final volume may be smaller
input double InpMaxMarginPercentBalance  = 10.0; // Account-wide margin cap as % of balance
input ulong  InpMagicNumber              = 20261021;
input int    InpDeviationPoints          = 20;

//--- MACD
input int    InpMACDFast                 = 12;
input int    InpMACDSlow                 = 26;
input int    InpMACDSignal               = 9;
input ENUM_APPLIED_PRICE InpAppliedPrice = PRICE_CLOSE;

//--- BUY
input double InpBuyMACDThreshold         = 0.000400;

//--- 3 positive MACD mountain BUY filter
input bool   InpUse3MountainFilter       = true;
input double InpReboundBufferPercent     = 0.2;
input int    InpMountainLookbackBars     = 3000;


//--- Logging
input bool   InpPrintDebug               = true;

//--- State
int      g_macdHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;
bool     g_cycleArmed = false;
bool     g_waitingForNegativeAfterSell = false;
double   g_histogramPeak = 0.0;
bool     g_histogramPeakTracking = false;

//+------------------------------------------------------------------+
void Log(const string message)
{
   if(InpPrintDebug)
      Print("[MACD ZeroCycle v1.35] ", message);
}

//+------------------------------------------------------------------+
int VolumeDigits(const double step)
{
   int digits = 0;
   double tempStep = step;

   while(digits < 8 &&
         MathAbs(tempStep - MathRound(tempStep)) > 1e-8)
   {
      tempStep *= 10.0;
      digits++;
   }

   return digits;
}

//+------------------------------------------------------------------+
//| Coordinate margin-cap checks across this EA's charts in MT5.     |
//+------------------------------------------------------------------+
string MarginLockName()
{
   return StringFormat("MZC10_%I64d", AccountInfoInteger(ACCOUNT_LOGIN));
}

bool AcquireMarginLock(double &lockToken)
{
   string lockName = MarginLockName();

   if(!GlobalVariableCheck(lockName))
      GlobalVariableTemp(lockName);

   lockToken = (double)TimeLocal()
             + (double)(ChartID() % 1000) / 1000000.0
             + (double)(GetTickCount64() % 1000) / 1000000000.0;

   for(int attempt = 0; attempt < 40; attempt++)
   {
      double currentToken = GlobalVariableGet(lockName);

      if(currentToken == 0.0 &&
         GlobalVariableSetOnCondition(lockName, lockToken, 0.0))
         return true;

      // Recover a lock left behind if an EA instance stopped unexpectedly.
      if(currentToken > 0.0 &&
         TimeLocal() - (datetime)MathFloor(currentToken) > 15)
      {
         GlobalVariableSetOnCondition(lockName, 0.0, currentToken);
         continue;
      }

      Sleep(25);
   }

   return false;
}

void ReleaseMarginLock(const double lockToken)
{
   GlobalVariableSetOnCondition(MarginLockName(), 0.0, lockToken);
}

//+------------------------------------------------------------------+
//| Round down without forcing a below-budget order up to min volume.|
//+------------------------------------------------------------------+
double NormalizeLotsDown(const double requestedLots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || minLot <= 0.0 || maxLot <= 0.0 ||
      requestedLots + 1e-10 < minLot)
      return 0.0;

   double lots = MathMin(maxLot, requestedLots);
   lots = MathFloor(lots / step + 1e-10) * step;

   if(lots + 1e-10 < minLot)
      return 0.0;

   return NormalizeDouble(lots, VolumeDigits(step));
}

//+------------------------------------------------------------------+
//| Size a BUY under a total account margin cap.                     |
//| Existing positions and pending-order margin consume the same cap. |
//+------------------------------------------------------------------+
double CalculateMarginCappedLots(double &selectedMargin)
{
   selectedMargin = 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   double pendingMargin = AccountInfoDouble(ACCOUNT_MARGIN_INITIAL);
   double cap = balance * InpMaxMarginPercentBalance / 100.0;
   double availableBudget = cap - usedMargin - pendingMargin;

   if(balance <= 0.0 || availableBudget <= 0.0)
   {
      Log(StringFormat(
         "BUY blocked: margin budget exhausted. balance=%.2f cap=%.2f used=%.2f pending=%.2f",
         balance, cap, usedMargin, pendingMargin
      ));
      return 0.0;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0)
   {
      Log("BUY blocked: cannot read a valid Ask price for margin calculation.");
      return 0.0;
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots   = NormalizeLotsDown(InpLots);

   if(lots <= 0.0 || step <= 0.0 || minLot <= 0.0)
   {
      Log("BUY blocked: maximum lot is below the broker minimum or volume settings are invalid.");
      return 0.0;
   }

   while(lots + 1e-10 >= minLot)
   {
      double requiredMargin = 0.0;
      ResetLastError();

      if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, tick.ask, requiredMargin))
      {
         Log(StringFormat(
            "BUY blocked: OrderCalcMargin failed for %s, error=%d",
            _Symbol, GetLastError()
         ));
         return 0.0;
      }

      if(requiredMargin > 0.0 && requiredMargin <= availableBudget + 1e-8)
      {
         selectedMargin = requiredMargin;
         return lots;
      }

      double nextLots = NormalizeDouble(lots - step, VolumeDigits(step));
      if(nextLots >= lots)
         break;
      lots = nextLots;
   }

   Log(StringFormat(
      "BUY blocked: broker minimum lot %.4f needs more than remaining margin budget %.2f (cap %.2f%% of balance).",
      minLot, availableBudget, InpMaxMarginPercentBalance
   ));
   return 0.0;
}

//+------------------------------------------------------------------+
int CountOwnBuyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)
         != POSITION_TYPE_BUY)
         continue;

      count++;
   }

   return count;
}

//+------------------------------------------------------------------+
bool OpenBuy()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Log("BUY blocked: trading is not allowed.");
      return false;
   }

   double lockToken = 0.0;
   if(!AcquireMarginLock(lockToken))
   {
      Log("BUY blocked: could not acquire the shared margin-cap lock.");
      return false;
   }

   double estimatedMargin = 0.0;
   double lots = CalculateMarginCappedLots(estimatedMargin);

   if(lots <= 0.0)
   {
      ReleaseMarginLock(lockToken);
      return false;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   ResetLastError();

   bool sent = trade.Buy(
      lots, _Symbol, 0.0, 0.0, 0.0, "MACD ZeroCycle BUY"
   );

   if(!sent)
   {
      ReleaseMarginLock(lockToken);
      Log(StringFormat(
         "BUY failed retcode=%u %s error=%d",
         trade.ResultRetcode(),
         trade.ResultRetcodeDescription(),
         GetLastError()
      ));
      return false;
   }

   ReleaseMarginLock(lockToken);

   Log(StringFormat(
      "BUY submitted: lots=%.4f estimatedMargin=%.2f cap=%.2f%% of balance",
      lots,
      estimatedMargin,
      InpMaxMarginPercentBalance
   ));
   return true;
}

//+------------------------------------------------------------------+
//| Close each profitable BUY position independently at a power peak |
//+------------------------------------------------------------------+
int CloseProfitableOwnBuys()
{
   int closedCount = 0;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0)
   {
      Log("SELL skipped: cannot read a valid Bid price.");
      return 0;
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)
         != POSITION_TYPE_BUY)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(tick.bid <= openPrice)
      {
         Log(StringFormat(
            "SELL skipped ticket=%I64u: Bid %.5f is not above entry %.5f.",
            ticket, tick.bid, openPrice
         ));
         continue;
      }

      ResetLastError();

      if(!trade.PositionClose(ticket))
      {
         Log(StringFormat(
            "SELL failed ticket=%I64u retcode=%u %s error=%d",
            ticket,
            trade.ResultRetcode(),
            trade.ResultRetcodeDescription(),
            GetLastError()
         ));
      }
      else
      {
         closedCount++;
         Log(StringFormat("SELL closed ticket=%I64u", ticket));
      }
   }

   return closedCount;
}

//+------------------------------------------------------------------+
bool ReadMACD(const int shift, double &value)
{
   double buffer[1];

   if(CopyBuffer(g_macdHandle, 0, shift, 1, buffer) != 1)
      return false;

   value = buffer[0];

   return value != EMPTY_VALUE && MathIsValidNumber(value);
}

//+------------------------------------------------------------------+
//| Classic MACD histogram: Main line minus Signal line.             |
//+------------------------------------------------------------------+
bool ReadHistogram(const int shift, double &value)
{
   double mainBuffer[1];
   double signalBuffer[1];

   if(CopyBuffer(g_macdHandle, 0, shift, 1, mainBuffer) != 1 ||
      CopyBuffer(g_macdHandle, 1, shift, 1, signalBuffer) != 1)
      return false;

   value = mainBuffer[0] - signalBuffer[0];
   return MathIsValidNumber(value);
}

//+------------------------------------------------------------------+
//| Read the last 3 COMPLETED positive MACD mountains.               |
//| One mountain: contiguous MACD Main > 0, bounded by MACD <= 0.   |
//| Price = candle CLOSE at maximum MACD Main in that mountain.      |
//| Returns prices in chronological order: P1 oldest, P3 newest.    |
//| Current positive mountain is skipped (not yet completed).       |
//+------------------------------------------------------------------+
bool GetThreeMountainPrices(double &p1, double &p2, double &p3)
{
   int available = BarsCalculated(g_macdHandle);
   int total = MathMin(InpMountainLookbackBars, available - 2);
   if(total < 20) return false;

   double macd[];
   double closes[];
   ArraySetAsSeries(macd, true);
   ArraySetAsSeries(closes, true);

   int gotM = CopyBuffer(g_macdHandle, 0, 1, total, macd);
   int gotC = CopyClose(_Symbol, _Period, 1, total, closes);
   if(gotM != total || gotC != total) return false;

   // Index 0 = most recent CLOSED candle. Skip current mountain.
   int i = 0;
   while(i < total && macd[i] > 0.0) i++;
   if(i == total) return false;

   double prices[3];
   int found = 0;
   while(i < total && found < 3)
   {
      // Find the next completed positive mountain going backward.
      while(i < total && macd[i] <= 0.0) i++;
      if(i >= total) break;

      double peak = -DBL_MAX;
      double priceAtPeak = 0.0;
      while(i < total && macd[i] > 0.0)
      {
         if(!MathIsValidNumber(macd[i]) || !MathIsValidNumber(closes[i]))
            return false;
         if(macd[i] > peak)
         {
            peak = macd[i];
            priceAtPeak = closes[i];
         }
         i++;
      }

      // Reject an incomplete mountain cut off by the lookback limit.
      if(i >= total) break;
      prices[found++] = priceAtPeak; // newest first
   }

   if(found < 3) return false;
   p1 = prices[2];
   p2 = prices[1];
   p3 = prices[0];
   return true;
}

//+------------------------------------------------------------------+
//| Option B: block BUY during 3 descending peak prices until       |
//| the current closed-bar price exceeds P3 plus a breakout buffer. |
//+------------------------------------------------------------------+
bool MountainFilterAllowsBuy()
{
   if(!InpUse3MountainFilter) return true;

   double p1, p2, p3;
   if(!GetThreeMountainPrices(p1, p2, p3))
   {
      Log("BUY blocked: fewer than 3 completed positive MACD mountains in lookback.");
      return false;
   }

   double currentClose = iClose(_Symbol, _Period, 1);
   if(currentClose <= 0.0) return false;

   bool downtrend = (p1 > p2 && p2 > p3);
   double breakoutLevel = p3 * (1.0 + InpReboundBufferPercent / 100.0);
   bool allowed = (!downtrend || currentClose > breakoutLevel);

   Log(StringFormat(
      "3M FILTER P1=%.5f P2=%.5f P3=%.5f Close=%.5f Down=%s Breakout=%.5f BUY=%s",
      p1, p2, p3, currentClose,
      downtrend ? "YES" : "NO", breakoutLevel,
      allowed ? "ALLOW" : "BLOCK"));
   return allowed;
}

//+------------------------------------------------------------------+
//| Process the last closed candle                                   |
//+------------------------------------------------------------------+
void ProcessClosedBar()
{
   double macd1, macd2, histogram1, histogram2;

   if(!ReadMACD(1, macd1) || !ReadMACD(2, macd2) ||
      !ReadHistogram(1, histogram1) || !ReadHistogram(2, histogram2))
   {
      Log("Waiting for MACD or histogram data.");
      return;
   }

   int positions = CountOwnBuyPositions();

   Log(StringFormat(
      "MACD1=%.6f MACD2=%.6f Hist1=%.6f Hist2=%.6f HistPeak=%.6f positions=%d armed=%s waitReset=%s",
      macd1,
      macd2,
      histogram1,
      histogram2,
      g_histogramPeak,
      positions,
      g_cycleArmed ? "YES" : "NO",
      g_waitingForNegativeAfterSell ? "YES" : "NO"
   ));

   // MACD at or below zero is a strict no-BUY/no-SELL zone.
   if(macd1 < 0.0)
   {
      g_histogramPeak = 0.0;
      g_histogramPeakTracking = false;

      if(positions > 0)
      {
         g_cycleArmed = true;
         Log("MACD negative but EA positions remain: HOLD; no SELL below zero.");
      }
      else
      {
         g_cycleArmed = true;
         g_waitingForNegativeAfterSell = false;

         Log("Negative MACD: new BUY cycle armed.");
      }

      return;
   }

   if(macd1 == 0.0)
   {
      Log("MACD is exactly zero: no BUY or SELL action.");
      return;
   }

   // Repeated BUYs: each new upward crossing of the BUY threshold
   // can open another position while the cycle remains armed. The
   // 3-Mountain filter is applied before sending every BUY.
   bool buyCross =
      (macd2 < InpBuyMACDThreshold &&
       macd1 >= InpBuyMACDThreshold);

   if(g_cycleArmed &&
      !g_waitingForNegativeAfterSell &&
      buyCross &&
      MountainFilterAllowsBuy())
   {
      if(OpenBuy())
      {
         if(!g_histogramPeakTracking)
         {
            g_histogramPeakTracking = true;
            g_histogramPeak = histogram1;
         }

         Log("BUY accepted. Further valid BUY crossings are allowed.");
      }
   }

   // Refresh count after possible BUY or manual close.
   positions = CountOwnBuyPositions();

   // No EA BUY positions remain: do not attempt to close missing tickets.
   if(positions == 0)
   {
      if(g_histogramPeakTracking)
      {
         g_histogramPeakTracking = false;
         g_histogramPeak = 0.0;
         Log("No EA BUY positions remain. Histogram peak tracking cleared.");
      }

      return;
   }

   // Track positive-mountain power with the classic histogram.
   if(!g_histogramPeakTracking)
   {
      g_histogramPeakTracking = true;
      g_histogramPeak = histogram1;
   }

   if(histogram1 > g_histogramPeak)
      g_histogramPeak = histogram1;

   // A falling histogram is the early power-weakening signal.
   // MACD Main is still strictly positive because of the gate above.
   bool powerFading =
      (histogram1 < histogram2 && histogram1 < g_histogramPeak);

   Log(StringFormat(
      "SELL CHECK histogram=%.6f previous=%.6f peak=%.6f powerFading=%s MACDpositive=YES",
      histogram1,
      histogram2,
      g_histogramPeak,
      powerFading ? "YES" : "NO"
   ));

   if(powerFading)
   {
      Log("SELL SIGNAL: histogram power is fading; close profitable tickets individually.");
      CloseProfitableOwnBuys();

      if(CountOwnBuyPositions() == 0)
      {
         g_waitingForNegativeAfterSell = true;
         g_cycleArmed = false;
         g_histogramPeakTracking = false;
         g_histogramPeak = 0.0;

         Log("All profitable tickets closed. Waiting for MACD below zero before next cycle.");
      }
      else
      {
         Log("Some tickets remain because their Bid is not above entry; no basket close was made.");
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLots <= 0.0 ||
      InpMACDFast <= 0 ||
      InpMACDSlow <= 0 ||
      InpMACDSignal <= 0 ||
      InpMACDFast >= InpMACDSlow ||
      InpBuyMACDThreshold <= 0.0 ||
      InpMaxMarginPercentBalance <= 0.0 ||
      InpMaxMarginPercentBalance > 10.0)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_macdHandle = iMACD(
      _Symbol,
      _Period,
      InpMACDFast,
      InpMACDSlow,
      InpMACDSignal,
      InpAppliedPrice
   );

   if(g_macdHandle == INVALID_HANDLE)
   {
      Print("Failed to create MACD handle. Error=", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   double macd1;

   if(ReadMACD(1, macd1) && macd1 < 0.0)
      g_cycleArmed = true;

   // Resume management if EA positions already exist on initialization.
   if(CountOwnBuyPositions() > 0)
   {
      g_cycleArmed = true;
      g_histogramPeakTracking = false;
      g_histogramPeak = 0.0;

      Log("Existing EA BUY positions detected.");
   }

   g_lastBarTime = iTime(_Symbol, _Period, 0);

   Log(StringFormat(
      "Initialized %s %s Magic=%I64u BUY=%.6f MaxMargin=%.2f%% Balance HistogramPeakSELL=ON",
      _Symbol,
      EnumToString(_Period),
      InpMagicNumber,
      InpBuyMACDThreshold,
      InpMaxMarginPercentBalance
   ));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_macdHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_macdHandle);
      g_macdHandle = INVALID_HANDLE;
   }

   Log(StringFormat("Deinitialized. Reason=%d", reason));
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(g_macdHandle == INVALID_HANDLE)
      return;

   datetime currentBarTime = iTime(_Symbol, _Period, 0);

   if(currentBarTime <= 0)
      return;

   // Signals are evaluated once per new candle using closed bars.
   if(currentBarTime != g_lastBarTime)
   {
      g_lastBarTime = currentBarTime;
      ProcessClosedBar();
   }
}
//+------------------------------------------------------------------+
