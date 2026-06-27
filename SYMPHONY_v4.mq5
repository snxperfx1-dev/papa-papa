//+------------------------------------------------------------------+
//| SYMPHONY_v4.mq5                                                  |
//| MULTI-CAMPAIGN engine (long AND short run simultaneously)        |
//|                                                                  |
//| Ported from the F16 Raptor / Master Senseei Pine engine:        |
//|   * Physics primitives (velocity/accel/convexity/eff/disp/comp)  |
//|   * Recursive Curve Tree (event-generated child curves on CHoCH) |
//|   * Compression persistence + "Is the trade alive?" life score   |
//|   * Narrative lineage / chain vitality                           |
//|   * Multi-timeframe curve map (per-TF direction + alignment)     |
//|                                                                  |
//| KEY CHANGES FROM v3.0:                                           |
//|   1. TRUE multi-campaign: long & short have independent          |
//|      structure, anchors, phase, curve tree, life and lineage.    |
//|      The single g_mode is gone — both books live at once.        |
//|   2. Counter-direction entry block REMOVED.                      |
//|   3. Per-campaign LIFE SCORE manages exits: when a campaign's     |
//|      life crosses below the dead threshold, that direction's      |
//|      book is closed (ownership has transferred).                  |
//|   4. Profit ladder / basket ceiling / BE+trail retained,          |
//|      already per-direction.                                       |
//|                                                                  |
//| MT5 HEDGING - RAW MqlTradeRequest (IOC)                         |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>

//==================================================================
// 0. SERIES BUFFERS
//==================================================================
double   gCloseSeries[];
double   gHighSeries[];
double   gLowSeries[];
datetime gTimeSeries[];

#define Close gCloseSeries
#define High  gHighSeries
#define Low   gLowSeries
#define Time  gTimeSeries

bool RefreshSeries(int barsNeeded = 5000)
{
   int need = (barsNeeded < 500) ? 500 : barsNeeded;
   ArraySetAsSeries(gCloseSeries, true);
   ArraySetAsSeries(gHighSeries,  true);
   ArraySetAsSeries(gLowSeries,   true);
   ArraySetAsSeries(gTimeSeries,  true);
   int c1 = CopyClose(_Symbol, _Period, 0, need, gCloseSeries);
   int c2 = CopyHigh (_Symbol, _Period, 0, need, gHighSeries);
   int c3 = CopyLow  (_Symbol, _Period, 0, need, gLowSeries);
   int c4 = CopyTime (_Symbol, _Period, 0, need, gTimeSeries);
   if(c1 <= 0 || c2 <= 0 || c3 <= 0 || c4 <= 0)
   { Print("RefreshSeries failed: ",c1," ",c2," ",c3," ",c4); return false; }
   return true;
}

//==================================================================
// 1A. INPUTS - CORE PHASE ENGINE
//==================================================================
input int    InpPivotLen          = 5;      // Pivot length
input int    InpATRLen            = 14;     // ATR length
input double InpImpulseAtrMult    = 1.5;    // Impulse ATR multiple
input double InpRetrMin           = 0.30;   // Min retracement
input double InpRetrMax           = 0.80;   // Max retracement
input int    InpInducLookbackBars = 80;     // Flip-zone lookback (bars)
input double InpInducZoneATRWidth = 0.25;   // Flip-zone half-width (ATR)

//==================================================================
// 1B. INPUTS - PHYSICS ENGINE (ported f_phys)
//==================================================================
input int    InpEffLen            = 10;     // Efficiency lookback
input double InpEffThresh         = 0.65;   // Efficiency threshold
input double InpDispThresh        = 1.5;    // Displacement ATR threshold
input double InpConvMult          = 0.01;   // Convexity ATR multiplier
input double InpChochBufferATR    = 0.75;   // CHoCH buffer (ATR)

//==================================================================
// 1C. INPUTS - LIFE / CURVE TREE
//==================================================================
input double InpLifeDeadExit      = 33.0;   // EXIT: life <= this (crossunder) closes that direction
input double InpLifeReviveLevel   = 60.0;   // life >= this = healthy hold (alert/dashboard only)
input bool   InpUseLifeExit       = true;   // EXIT: let the life score close positions
input double InpLifeArmLevel      = 55.0;   // life must first reach this (campaign got healthy) before a dead-cross can exit
input int    InpLifeExitGraceBars = 12;     // no life/chain exit within N bars of the last entry (per direction)
input bool   InpUseChainDecayExit = false;  // also exit on whole-chain decay (aggressive; off by default)
// --- destination-aware exit: only let life cut after expansion, at/near parent S/D ---
input bool   InpUseParentExit     = true;   // life exit ONLY after expansion + at/approaching parent supply/demand
input double InpExpandMinATR      = 2.0;    // owner curve must have travelled >= this (ATR) to count as "expanded"
input double InpParentApproachATR = 2.0;    // within this many ATR of parent S/D = "approaching"
input int    InpParentFromTFIndex = 4;      // lowest TF index treated as parent (0=M1 1=M5 2=M15 3=M30 4=H1 5=H4 6=D1 7=W1)
input bool   InpShowDashboard     = true;   // Print Comment() dashboard
input bool   InpDebugLog          = true;   // Print full engine state to the journal on every entry
// --- curve-tree entry gate + all-timeframe entries (LIFE NOT USED FOR ENTRIES) ---
input bool   InpRequireCurveOwner = true;   // Require curve-tree owner not opposed to the entry dir
input bool   InpUsePhaseInNode    = true;   // Feed phase context into curve-tree node state
input bool   InpBlockCounterProfit= true;   // Don't open one side while the OTHER book is net profitable
input bool   InpUseMTFDirection   = true;   // DIRECTION: only trade with the MTF map's net bias
input bool   InpMTFRequireRungAgree = true; // also require the entry TF's own structure to agree (not opposed)
input double InpMTFBiasDeadband   = 3.0;    // |weighted bias| <= this = balanced (one top TF can't veto aligned lower TFs)
input int    InpRotCount          = 1;      // ENTRY rotation: cascade must be >= this deep (1 = a single M1 rotation opens)
input bool   InpUseRotationExit   = true;   // EXIT: a lower-TF rotation against the open book flattens it
input int    InpRotExitCount      = 2;      // EXIT rotation depth: need this many TFs flipped against the book to flatten it
// --- zone-based entries: buys at higher-TF demand, sells at higher-TF supply, when rotation confirmed ---
input double InpZoneApproachATR   = 1.0;    // price must be within this many ATR of the higher-TF S/D zone to enter
input double InpZoneSLBufferATR   = 0.5;    // stop placed this many ATR beyond the zone
input double InpZoneSideTolATR    = 0.25;   // allowed wick THROUGH the zone (wrong side) before it's rejected
input double InpMinSLATR          = 0.8;    // minimum stop distance in ATR (prevents micro-stops -> huge lots)
input bool   InpRequireCleanRotation = false; // require a clean (bottom-led) cascade before entering
input bool   InpRequirePhaseTrigger = true; // require a P3/P4 phase (timing) in the entry direction to fire
input int    InpZoneFromTFIndex   = 0;      // lowest TF whose S/D zone can be traded (0 = M1)
input int    InpZoneOpenAhead     = 0;      // open zones this many TFs ABOVE the cascade front (0 = up to the just-rotated TF)
input bool   InpRequireMajorZoneOrigin = false; // (optional) extra: also require the cascade FLIP to occur at a fixed major TF zone
input bool   InpUseHuntCycle      = true;   // HUNT-MODE CYCLE: buy demand->flip TP->hunt sells->supply->flip TP->repeat
input int    InpFlipTFIndex       = 5;      // controlling HTF for the flip zone (5 = H4; demand below / supply above)
input double InpFlipBandATR       = 0.5;    // price within this many ATR of the flip = "reached" -> TP + auto-switch
input int    InpMajorFromTFIndex  = 4;      // lowest TF treated as a MAJOR reversal zone (4 = H1)
input double InpMajorZoneATR      = 3.0;    // the cascade flip must occur within this many ATR of the major zone
// --- direction memory + cross-timeframe phase confluence ---
input int    InpMTFConfirmBars    = 3;      // a TF's direction must confirm this many bars before it flips (anti-whipsaw)
input int    InpExtremeLookback   = 6;      // bars defining a "fresh" new high/low; rotation there bypasses the debounce
input bool   InpRequirePhaseConfluence = true; // entries must be nested under agreeing phases across timeframes
input int    InpMinPhaseConfluence = 2;     // min # of timeframes in the entry direction's phase/structure
input bool   InpTradeAllTF        = true;   // Fire P3/P4 from every timeframe curve (not just chart)
input int    InpEntryFromTFIndex  = 0;      // Lowest entry timeframe (0=M1 1=M5 2=M15 3=H1 4=H4 5=D1)

//==================================================================
// 1D. INPUTS - ARC v2
//==================================================================
input int    InpArcHorizonBars    = 80;     // Arc horizon (bars)
input double InpConvPower          = 1.5;    // Arc convexity power
input double InpArcExtMult          = 1.0;    // Arc extension multiple (1.0 = impulse height)
input double InpOuterBandAtrMult  = 0.75;   // Outer band distance (ATR)
input double InpArcToleranceAtr   = 0.20;   // Close-to-ARC exhaustion tolerance (ATR)

//==================================================================
// 1E. INPUTS - SIZING / LADDER / TIMING
//==================================================================
input double InpRiskPercent       = 0.5;    // Risk % per entry (of equity)
input double InpMaxBasketRiskPct  = 3.0;    // Max per-direction basket risk % of equity
input int    InpMagic             = 240220; // EA magic number
input double InpLadderRung1       = 0.7;    // Rung 1 trigger (PnL >= 0.7x basket risk)
input double InpLadderRung2       = 1.5;    // Rung 2 trigger
input double InpLadderRung3       = 2.5;    // Rung 3 trigger
input double InpLadderFrac1       = 0.20;   // Lot fraction to close at rung 1
input double InpLadderFrac2       = 0.25;   // Lot fraction to close at rung 2
input double InpLadderFrac3       = 0.25;   // Lot fraction to close at rung 3
input double InpTrailLockPct      = 50.0;   // % of price move to lock after rung 2
input int    InpTargetGMT         = 0;      // Session GMT offset

//==================================================================
// 2. PHYSICS ENGINE STATE (global market physics, ported f_phys)
//==================================================================
bool   g_physInit       = false;
double g_vel            = 0.0;
double g_velPrev        = 0.0;
double g_acc            = 0.0;
double g_accPrev        = 0.0;
double g_conv           = 0.0;
double g_convSmooth     = 0.0;
double g_eff            = 0.0;
double g_disp           = 0.0;
double g_compIdx        = 0.0;     // compression 0..100 (high = tight)
double g_compHist[6];              // ring for cmpTighten (compNow - compNow[5])
int    g_compHistFill   = 0;
double g_cmpTighten     = 0.0;
double g_convScore      = 0.0;
double g_velScore       = 0.0;
double g_decayScore     = 0.0;
double g_expEnergy      = 0.0;     // ede expansion energy injected (0..100)
bool   g_bullImp        = false;
bool   g_bearImp        = false;
bool   g_vd70           = false;
int    g_barCount       = 0;       // monotonic bar counter (bar_index analog)

//==================================================================
// 3. STRUCTURE STATE (pivots + swings + CHoCH) - shared by both campaigns
//==================================================================
double g_lastPivotPrice = 0.0;
int    g_lastPivotShift = -1;
int    g_lastPivotDir   = 0;
double g_prevPivotPrice = 0.0;
int    g_prevPivotShift = -1;
int    g_prevPivotDir   = 0;

double g_curSH = 0.0, g_prSH = 0.0;   // current / previous swing high
double g_curSL = 0.0, g_prSL = 0.0;   // current / previous swing low
bool   g_bullCHoCH = false, g_bearCHoCH = false;
bool   g_bullBOS   = false, g_bearBOS   = false;

datetime g_lastBarTime = 0;

//==================================================================
// 4. PER-CAMPAIGN STRUCTURE STATE (independent long & short)
//    This is the multi-campaign core: each direction owns its own
//    anchors, phase, induc-zone, cycle extreme and trade-time guard.
//==================================================================
// LONG campaign
bool     gL_active        = false;
double   gL_anchorHigh    = 0.0;
double   gL_anchorLow     = 0.0;
int      gL_anchorHighShift = -1;
int      gL_anchorLowShift  = -1;
int      gL_phase         = 0;
int      gL_prevPhase     = 0;
bool     gL_preConvSeen   = false;
double   gL_inducPrice    = 0.0;
double   gL_inducLow      = 0.0;
double   gL_inducHigh     = 0.0;
bool     gL_outerBreach   = false;
double   gL_cycleHigh     = 0.0;
double   gL_arc           = 0.0;
bool     gL_modeInvalid   = false;
int      gL_phaseAtInvalid= 0;
datetime gL_lastTradeTime = 0;

// SHORT campaign
bool     gS_active        = false;
double   gS_anchorHigh    = 0.0;
double   gS_anchorLow     = 0.0;
int      gS_anchorHighShift = -1;
int      gS_anchorLowShift  = -1;
int      gS_phase         = 0;
int      gS_prevPhase     = 0;
bool     gS_preConvSeen   = false;
double   gS_inducPrice    = 0.0;
double   gS_inducLow      = 0.0;
double   gS_inducHigh     = 0.0;
bool     gS_outerBreach   = false;
double   gS_cycleLow      = 0.0;
double   gS_arc           = 0.0;
bool     gS_modeInvalid   = false;
int      gS_phaseAtInvalid= 0;
datetime gS_lastTradeTime = 0;

//==================================================================
// 5. PROFIT LADDER + STOP PROTECTION STATE (per direction)
//==================================================================
int      g_longRungs        = 0;
int      g_shortRungs       = 0;
bool     g_longBEActive     = false;
bool     g_shortBEActive    = false;
bool     g_longTrailActive  = false;
bool     g_shortTrailActive = false;

// life-exit guards: arm-before-die + grace window after the last entry (per direction)
int      g_longLastEntryBar  = -100000;
int      g_shortLastEntryBar = -100000;
bool     g_longLifeArmed     = false;
bool     g_shortLifeArmed    = false;

//==================================================================
// 6. POSITION SORT STRUCT
//==================================================================
struct PosEntry
{
   ulong    ticket;
   datetime openTime;
   double   lots;
};


//==================================================================
// 7. BASIC HELPERS
//==================================================================
bool IsNewBar()
{
   datetime t = Time[0];
   if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
   return false;
}

double GetATR(int shift)
{
   static int hATR = INVALID_HANDLE;
   if(hATR == INVALID_HANDLE)
   {
      hATR = iATR(_Symbol, _Period, InpATRLen);
      if(hATR == INVALID_HANDLE) { Print("iATR handle failed"); return 0.0; }
   }
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hATR, 0, shift + 1, 1, buf) < 1) return 0.0;
   return buf[0];
}

bool IsPivotHigh(int c)
{
   int maxBars = (int)ArraySize(High);
   if(c <= 0 || c >= maxBars) return false;
   double h = High[c];
   for(int k = 1; k <= InpPivotLen; k++)
   {
      if(c+k >= maxBars || c-k < 0) return false;
      if(h <= High[c+k]) return false;
      if(h <= High[c-k]) return false;
   }
   return true;
}

bool IsPivotLow(int c)
{
   int maxBars = (int)ArraySize(Low);
   if(c <= 0 || c >= maxBars) return false;
   double l = Low[c];
   for(int k = 1; k <= InpPivotLen; k++)
   {
      if(c+k >= maxBars || c-k < 0) return false;
      if(l >= Low[c+k]) return false;
      if(l >= Low[c-k]) return false;
   }
   return true;
}

double Clamp(double v, double lo, double hi)
{
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
}

// push a double into a capped FIFO array (keeps last 'cap' values)
void PushCapD(double &arr[], double v, int cap)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = v;
   int sz = ArraySize(arr);
   if(sz > cap)
   {
      for(int i = 1; i < sz; i++) arr[i-1] = arr[i];
      ArrayResize(arr, sz - 1);
   }
}
void PushCapI(int &arr[], int v, int cap)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = v;
   int sz = ArraySize(arr);
   if(sz > cap)
   {
      for(int i = 1; i < sz; i++) arr[i-1] = arr[i];
      ArrayResize(arr, sz - 1);
   }
}

//==================================================================
// 8. PHYSICS ENGINE - ported f_phys (runs once per closed bar)
//   velocity = EMA(close-close[1],3); acceleration; convexity;
//   efficiency = |move| / pathlength; displacement = range/ATR;
//   compression index (high when displacement & efficiency are low).
//==================================================================
void UpdatePhysics()
{
   int bars = (int)ArraySize(Close);
   if(bars < InpEffLen + 3) return;
   double atr = GetATR(1);
   if(atr <= 0.0) atr = 1e-6;

   double delta = Close[1] - Close[2];
   double alpha = 2.0 / (3.0 + 1.0);   // EMA(3)

   if(!g_physInit)
   {
      g_vel = delta; g_velPrev = delta;
      g_acc = 0.0;   g_accPrev = 0.0;
      g_conv = 0.0;  g_convSmooth = 0.0;
      g_physInit = true;
   }
   else
   {
      g_velPrev = g_vel;
      g_vel     = g_vel + alpha * (delta - g_vel);
      g_accPrev = g_acc;
      g_acc     = g_vel - g_velPrev;
      double convNow = g_acc - g_accPrev;
      g_conv       = convNow;
      g_convSmooth = g_convSmooth + alpha * (convNow - g_convSmooth);
   }

   // efficiency
   double mv = MathAbs(Close[1] - Close[1 + InpEffLen]);
   double ps = 0.0;
   for(int i = 1; i <= InpEffLen; i++) ps += MathAbs(Close[i] - Close[i + 1]);
   g_eff = (ps > 0.0) ? mv / ps : 0.0;

   // displacement
   g_disp = (High[1] - Low[1]) / atr;

   // compression index
   double dispTerm = (1.0 - MathMin(g_disp / MathMax(InpDispThresh, 1e-10), 1.0)) * 60.0;
   double effTerm  = (1.0 - MathMin(g_eff  / MathMax(InpEffThresh, 1e-10), 1.0)) * 40.0;
   g_compIdx = Clamp(dispTerm + effTerm, 0.0, 100.0);

   // cmpTighten = compNow - compNow[5]
   double comp5 = (g_compHistFill >= 6) ? g_compHist[0] : g_compIdx;
   g_cmpTighten = g_compIdx - comp5;
   // shift ring
   for(int i = 1; i < 6; i++) g_compHist[i-1] = g_compHist[i];
   g_compHist[5] = g_compIdx;
   if(g_compHistFill < 6) g_compHistFill++;

   // derived scores
   g_convScore = MathMin(MathAbs(g_convSmooth) / MathMax(atr * InpConvMult, 1e-10) * 25.0, 100.0);
   g_velScore  = MathMin(MathAbs(g_vel) / MathMax(atr * 0.1, 1e-10) * 50.0, 100.0);

   bool upBar   = Close[1] > Close[2];
   bool dnBar   = Close[1] < Close[2];
   g_bullImp = (g_eff > InpEffThresh && g_vel > g_velPrev && g_acc > 0.0 && upBar && g_disp > InpDispThresh);
   g_bearImp = (g_eff > InpEffThresh && g_vel < g_velPrev && g_acc < 0.0 && dnBar && g_disp > InpDispThresh);

   bool bullDecay = (MathAbs(g_acc) < MathAbs(g_accPrev) * 0.8 && g_vel > 0.0);
   bool bearDecay = (MathAbs(g_acc) < MathAbs(g_accPrev) * 0.8 && g_vel < 0.0);
   g_vd70 = (MathAbs(g_vel) < MathAbs(g_velPrev) * 0.7);

   // expansion energy (ede-lite)
   double obsExp = 0.0;
   obsExp += (g_eff > InpEffThresh) ? g_eff * 60.0 : g_eff * 30.0;
   obsExp += (g_disp > InpDispThresh) ? (g_disp / MathMax(InpDispThresh,1e-10) - 1.0) * 20.0 : 0.0;
   obsExp += ((g_vel > 0 && g_acc > 0) || (g_vel < 0 && g_acc < 0)) ? g_velScore * 0.2 : 0.0;
   obsExp  = Clamp(obsExp, 0.0, 100.0);
   g_expEnergy = Clamp(obsExp * 0.5 + ((g_bullImp || g_bearImp) ? 30.0 : 0.0) + g_eff * 20.0, 0.0, 100.0);

   // decay score (drives dissipation)
   double dec = 0.0;
   dec += (bullDecay || bearDecay) ? 40.0 : 0.0;
   dec += (g_convScore > 30.0) ? g_convScore * 0.5 : 0.0;
   dec += (g_vd70) ? 30.0 : 0.0;
   g_decayScore = Clamp(dec, 0.0, 100.0);
}

//==================================================================
// 9. STRUCTURE ENGINE - swings + CHoCH/BOS (shared) and per-direction
//    impulse/anchor activation. This replaces the single-g_mode phase
//    engine with independent long & short campaigns.
//==================================================================
void FindInducZone(int anchorShift, double aHigh, double aLow,
                   double atr, double &price, double &lo, double &hi)
{
   price = 0.0; lo = 0.0; hi = 0.0;
   double best = 0.0; int bestDist = -1;
   if(anchorShift > 0)
   {
      for(int s = anchorShift - 1; s >= 0 && s >= anchorShift - InpInducLookbackBars; s--)
      {
         if(High[s] < aHigh && Low[s] > aLow)
         {
            int d = MathAbs(anchorShift - s);
            if(bestDist < 0 || d < bestDist) { bestDist = d; best = (High[s] + Low[s]) * 0.5; }
         }
      }
   }
   if(bestDist >= 0)
   {
      price = best;
      lo    = best - atr * InpInducZoneATRWidth;
      hi    = best + atr * InpInducZoneATRWidth;
   }
}

void UpdateStructure()
{
   int barsAvail = (int)ArraySize(Close);
   if(barsAvail <= (2 * InpPivotLen + 5)) return;

   int    shiftNow = 1;
   double closeNow = Close[shiftNow];
   double atrRef   = GetATR(shiftNow);
   if(atrRef <= 0.0) atrRef = 1e-6;

   int centerShift = InpPivotLen + 1;
   int pivotDir = 0; double pivotPrice = 0.0; int pivotShift = -1;
   if(centerShift < barsAvail - InpPivotLen)
   {
      if(IsPivotHigh(centerShift)) { pivotDir = 1;  pivotPrice = High[centerShift]; pivotShift = centerShift; }
      else if(IsPivotLow(centerShift)) { pivotDir = -1; pivotPrice = Low[centerShift];  pivotShift = centerShift; }
   }

   // update swing highs / lows for CHoCH detection
   if(pivotDir == 1)  { g_prSH = (g_curSH == 0.0 ? pivotPrice : g_curSH); g_curSH = pivotPrice; }
   if(pivotDir == -1) { g_prSL = (g_curSL == 0.0 ? pivotPrice : g_curSL); g_curSL = pivotPrice; }

   // CHoCH / BOS off the previous swing (shared signal both campaigns read)
   g_bullBOS   = (g_prSH > 0.0 && closeNow > g_prSH);
   g_bearBOS   = (g_prSL > 0.0 && closeNow < g_prSL);
   g_bullCHoCH = (g_prSH > 0.0 && closeNow > g_prSH + atrRef * InpChochBufferATR);
   g_bearCHoCH = (g_prSL > 0.0 && closeNow < g_prSL - atrRef * InpChochBufferATR);

   // ---- LONG impulse: last low -> new higher high. Activates ONLY the long campaign. ----
   if(pivotDir == 1 && g_lastPivotDir == -1)
   {
      double r = pivotPrice - g_lastPivotPrice;
      if(r > atrRef * InpImpulseAtrMult)
      {
         gL_active        = true;
         gL_anchorLow     = g_lastPivotPrice; gL_anchorLowShift  = g_lastPivotShift;
         gL_anchorHigh    = pivotPrice;       gL_anchorHighShift = pivotShift;
         gL_phase         = 1;
         gL_preConvSeen   = false;
         gL_inducPrice = gL_inducLow = gL_inducHigh = 0.0;
         gL_outerBreach   = false;
         gL_cycleHigh     = High[shiftNow];
         FindInducZone(gL_anchorLowShift, gL_anchorHigh, gL_anchorLow, atrRef,
                       gL_inducPrice, gL_inducLow, gL_inducHigh);
      }
   }
   // ---- SHORT impulse: last high -> new lower low. Activates ONLY the short campaign. ----
   if(pivotDir == -1 && g_lastPivotDir == 1)
   {
      double r = g_lastPivotPrice - pivotPrice;
      if(r > atrRef * InpImpulseAtrMult)
      {
         gS_active        = true;
         gS_anchorHigh    = g_lastPivotPrice; gS_anchorHighShift = g_lastPivotShift;
         gS_anchorLow     = pivotPrice;       gS_anchorLowShift  = pivotShift;
         gS_phase         = 1;
         gS_preConvSeen   = false;
         gS_inducPrice = gS_inducLow = gS_inducHigh = 0.0;
         gS_outerBreach   = false;
         gS_cycleLow      = Low[shiftNow];
         FindInducZone(gS_anchorHighShift, gS_anchorHigh, gS_anchorLow, atrRef,
                       gS_inducPrice, gS_inducLow, gS_inducHigh);
      }
   }

   // persist pivot history
   if(pivotDir != 0)
   {
      g_prevPivotPrice = g_lastPivotPrice; g_prevPivotShift = g_lastPivotShift; g_prevPivotDir = g_lastPivotDir;
      g_lastPivotPrice = pivotPrice;       g_lastPivotShift = pivotShift;       g_lastPivotDir = pivotDir;
   }

   // extend cycle extremes while active
   if(gL_active && High[shiftNow] > gL_cycleHigh) gL_cycleHigh = High[shiftNow];
   if(gS_active && Low[shiftNow]  < gS_cycleLow)  gS_cycleLow  = Low[shiftNow];

   // ---- INVALIDATION (capture phase BEFORE zeroing — exit-gate fix, per campaign) ----
   gL_modeInvalid = false;
   gS_modeInvalid = false;
   if(gL_active && closeNow < gL_anchorLow)
   {
      gL_modeInvalid = true; gL_phaseAtInvalid = gL_phase;
      gL_active = false; gL_phase = 0;
      gL_inducPrice = gL_inducLow = gL_inducHigh = 0.0; gL_outerBreach = false;
   }
   if(gS_active && closeNow > gS_anchorHigh)
   {
      gS_modeInvalid = true; gS_phaseAtInvalid = gS_phase;
      gS_active = false; gS_phase = 0;
      gS_inducPrice = gS_inducLow = gS_inducHigh = 0.0; gS_outerBreach = false;
   }

   int oldPL = gL_phase;
   int oldPS = gS_phase;

   // ---- LONG phase ----
   if(!gL_active) gL_phase = 0;
   if(gL_active && gL_anchorHighShift >= 0 && gL_anchorLowShift >= 0)
   {
      double impL  = gL_anchorHigh - gL_anchorLow;
      double retrL = (impL > 0.0) ? (gL_anchorHigh - closeNow) / impL : 0.0;
      double dL    = Close[shiftNow] - Close[shiftNow+1];
      int p;
      if(retrL > InpRetrMax || retrL < 0.0)    p = 0;
      else if(closeNow >= gL_anchorHigh)       p = 4;
      else if(retrL >= InpRetrMin)             p = (dL < 0.0 ? 2 : 3);
      else                                     p = 1;
      bool hasZone = (gL_inducLow != 0.0 || gL_inducHigh != 0.0);
      if(p == 3 && hasZone && closeNow >= gL_inducLow) p = 2;
      else if(p == 3) gL_preConvSeen = true;
      if(p == 4 && !gL_preConvSeen) p = 2;
      gL_phase = p;
   }

   // ---- SHORT phase ----
   if(!gS_active) gS_phase = 0;
   if(gS_active && gS_anchorHighShift >= 0 && gS_anchorLowShift >= 0)
   {
      double impS  = gS_anchorHigh - gS_anchorLow;
      double retrS = (impS > 0.0) ? (closeNow - gS_anchorLow) / impS : 0.0;
      double dS    = Close[shiftNow] - Close[shiftNow+1];
      int p;
      if(retrS > InpRetrMax || retrS < 0.0)    p = 0;
      else if(closeNow <= gS_anchorLow)        p = 4;
      else if(retrS >= InpRetrMin)             p = (dS > 0.0 ? 2 : 3);
      else                                     p = 1;
      bool hasZone = (gS_inducLow != 0.0 || gS_inducHigh != 0.0);
      if(p == 3 && hasZone && closeNow <= gS_inducHigh) p = 2;
      else if(p == 3) gS_preConvSeen = true;
      if(p == 4 && !gS_preConvSeen) p = 2;
      gS_phase = p;
   }

   gL_prevPhase = oldPL;
   gS_prevPhase = oldPS;
}


//==================================================================
// 10. RECURSIVE CURVE TREE + LIFE + LINEAGE  (F72 port, per campaign)
//==================================================================
struct CurveNode
{
   int    id;
   int    parent;
   int    dir;
   double origin;
   double extreme;
   double energy;
   bool   alive;
   int    depth;
   int    state;    // node phase code (emergent)
   int    bar;
};

// node phase code -> short label (Principle 1: phase emerges from the curve)
string NodeStateLabel(int s)
{
   switch(s)
   {
      case 0:  return "P4 Origin";
      case 1:  return "Expansion";
      case 2:  return "Exp Pre-Cvx";
      case 3:  return "Exp Induction";
      case 4:  return "Exp Liquidity";
      case 5:  return "New High";
      case 6:  return "New Low";
      case 7:  return "Retr Pre-Cvx";
      case 8:  return "Retr Induction";
      case 9:  return "Retracement";
      case 10: return "Trans Exp";
      case 11: return "Trans Induct";
      case 12: return "Trans Liq";
   }
   return "-";
}

// emergent node state from PHASE CONTEXT (primary, when active) then energy /
// depth / compression / maturity. phase 1..4 = the engine's real P1-P4 read;
// phase 0 / inactive => fall back to the energy heuristic.
int NodeState(int dir, double e, int depth, double cmp, double mat, int phase)
{
   // recursive child curves always live in the Transition family
   if(depth > 0) return (e >= 70.0 ? 10 : e >= 40.0 ? 11 : 12);

   // phase-anchored state (Principle 1: phase context drives the owner node)
   if(InpUsePhaseInNode && phase >= 1)
   {
      if(phase == 4) return (dir == 1 ? 5 : 6);          // breakout / new extreme
      if(phase == 3) return (e >= 55.0 ? 3 : 8);          // induction (exp / retr)
      if(phase == 2) return 2;                             // pre-convexity
      if(phase == 1) return (mat < 35.0 ? 1 : 2);          // expansion
   }

   // energy fallback (no active phase)
   if(mat < 12.0) return 0;
   if(e >= 78.0 && mat >= 70.0) return (dir == 1 ? 5 : 6);
   if(mat < 35.0) return 1;
   if(mat < 55.0) return 2;
   if(e >= 55.0) return 3;
   if(e >= 35.0) return 4;
   if(cmp >= 60.0) return 7;
   if(e >= 18.0) return 8;
   return 9;
}

// context handed to a campaign each bar
struct CurveCtx
{
   int    dir;          // campaign direction (+1 long, -1 short)
   bool   active;
   double origin;       // campaign invalidation/origin
   double extreme;      // campaign cycle extreme
   double close;
   double high;
   double low;
   double atr;
   double compNow;
   double cmpTighten;
   double eRes;         // residual energy 0..100
   double expEnergy;
   bool   counterCHoCH; // CHoCH against the campaign owner
   int    phaseCode;
   double maturity;     // 0..100
   bool   bullImp;
   bool   bearImp;
   int    barIndex;
};

class CCampaign
{
public:
   int       m_dir;
   CurveNode m_tree[];
   int       m_nodeSeq;

   // owner snapshot
   int       m_ownDir;
   int       m_ownDepth;
   double    m_ownEnergy;
   double    m_ownOrigin;
   double    m_ownExtreme;
   int       m_ownState;
   int       m_treeDepth;
   int       m_treeAlive;
   int       m_budgetDepth;

   // compression persistence + life
   double    m_cpForce;
   string    m_cpState;
   double    m_life;
   double    m_prevLife;
   double    m_retrX;
   bool      m_progressing;

   // narrative lineage / chain vitality
   int       m_narrDir;
   double    m_legX;
   double    m_legPBdepth;
   double    m_narrative;
   string    m_narrState;
   int       m_supVotes;
   int       m_degVotes;
   string    m_lastVote;
   double    m_seqRetr[];
   double    m_lifeSeq[];
   double    m_wholeChainLife;
   double    m_chainVitality;
   string    m_chainScope;
   bool      m_converging;

   void Init(int dir)
   {
      m_dir = dir;
      ArrayResize(m_tree, 0);
      m_nodeSeq = 0;
      m_ownDir = 0; m_ownDepth = 0; m_ownEnergy = 0.0;
      m_ownOrigin = 0.0; m_ownExtreme = 0.0; m_ownState = 9;
      m_treeDepth = 0; m_treeAlive = 0; m_budgetDepth = 1;
      m_cpForce = 0.0; m_cpState = "NEUTRAL";
      m_life = 50.0; m_prevLife = 50.0; m_retrX = 50.0; m_progressing = false;
      m_narrDir = 0; m_legX = 0.0; m_legPBdepth = 0.0;
      m_narrative = 50.0; m_narrState = "HOLDING";
      m_supVotes = 0; m_degVotes = 0; m_lastVote = "-";
      ArrayResize(m_seqRetr, 0);
      ArrayResize(m_lifeSeq, 0);
      m_wholeChainLife = 50.0; m_chainVitality = 50.0;
      m_chainScope = "healthy"; m_converging = false;
   }

   int FindOwner()
   {
      int best = -1; double bestE = -1.0; int bestDepth = 999;
      double floorE = 12.0;
      int n = ArraySize(m_tree);
      for(int i = 0; i < n; i++)
      {
         if(m_tree[i].alive && m_tree[i].energy >= floorE &&
            (m_tree[i].depth < bestDepth || (m_tree[i].depth == bestDepth && m_tree[i].energy > bestE)))
         { bestDepth = m_tree[i].depth; bestE = m_tree[i].energy; best = i; }
      }
      if(best < 0)
         for(int i = 0; i < n; i++)
            if(m_tree[i].alive && m_tree[i].energy > bestE) { bestE = m_tree[i].energy; best = i; }
      return best;
   }

   void Update(CurveCtx &c)
   {
      m_prevLife = m_life;
      m_budgetDepth = (int)MathMax(1, MathMin(4, 1 + (int)MathRound(c.compNow / 33.0)));

      // ---- resolve pre-owner (for child-spawn direction) ----
      int owner = FindOwner();

      // ---- seed / re-seed root when no living curve owns price ----
      if(owner < 0 && c.active && c.dir != 0 && c.origin != 0.0)
      {
         CurveNode root;
         m_nodeSeq++;
         root.id = m_nodeSeq; root.parent = -1; root.dir = c.dir;
         root.origin = c.origin; root.extreme = c.extreme;
         root.energy = MathMax(40.0, c.expEnergy); root.alive = true;
         root.depth = 0; root.state = 1; root.bar = c.barIndex;
         int n = ArraySize(m_tree); ArrayResize(m_tree, n + 1); m_tree[n] = root;
         owner = n;
      }

      // ---- event-generated CHILD: counter-CHoCH against the owner, budget permitting ----
      if(owner >= 0 && c.counterCHoCH && (m_tree[owner].depth + 1 <= m_budgetDepth))
      {
         CurveNode child;
         m_nodeSeq++;
         child.id = m_nodeSeq; child.parent = m_tree[owner].id; child.dir = -m_tree[owner].dir;
         child.origin = c.close; child.extreme = c.close;
         child.energy = MathMax(25.0, c.expEnergy * 0.85); child.alive = true;
         child.depth = m_tree[owner].depth + 1; child.state = 11; child.bar = c.barIndex;
         int n = ArraySize(m_tree); ArrayResize(m_tree, n + 1); m_tree[n] = child;
      }

      // ---- update living nodes ----
      int sz = ArraySize(m_tree);
      for(int i = 0; i < sz; i++)
      {
         if(!m_tree[i].alive) continue;
         bool prog;
         if(m_tree[i].depth == 0)
         {
            // root mirrors the campaign's own wave
            m_tree[i].dir = c.dir;
            prog = (c.dir == 1) ? (c.extreme > m_tree[i].extreme) : (c.extreme < m_tree[i].extreme);
            m_tree[i].origin  = c.origin;
            m_tree[i].extreme = c.extreme;
         }
         else
         {
            prog = (m_tree[i].dir == 1) ? (c.high > m_tree[i].extreme) : (c.low < m_tree[i].extreme);
            m_tree[i].extreme = (m_tree[i].dir == 1) ? MathMax(m_tree[i].extreme, c.high)
                                                     : MathMin(m_tree[i].extreme, c.low);
         }
         m_tree[i].energy = prog ? MathMin(100.0, m_tree[i].energy + 7.0)
                                 : MathMax(0.0,  m_tree[i].energy - 2.0);
         int pctx = (m_tree[i].depth == 0) ? c.phaseCode : 0;   // phase context only for the owner root
         m_tree[i].state  = NodeState(m_tree[i].dir, m_tree[i].energy, m_tree[i].depth, c.compNow, c.maturity, pctx);
         if(m_tree[i].energy <= 2.0) m_tree[i].alive = false;
      }

      // cap tree size
      while(ArraySize(m_tree) > 40)
      {
         for(int i = 1; i < ArraySize(m_tree); i++) m_tree[i-1] = m_tree[i];
         ArrayResize(m_tree, ArraySize(m_tree) - 1);
      }

      // ---- final owner snapshot ----
      int of = FindOwner();
      m_treeAlive = 0; m_treeDepth = 0;
      for(int i = 0; i < ArraySize(m_tree); i++)
         if(m_tree[i].alive) { m_treeAlive++; if(m_tree[i].depth > m_treeDepth) m_treeDepth = m_tree[i].depth; }
      if(of >= 0)
      {
         m_ownDir = m_tree[of].dir; m_ownDepth = m_tree[of].depth; m_ownEnergy = m_tree[of].energy;
         m_ownOrigin = m_tree[of].origin; m_ownExtreme = m_tree[of].extreme; m_ownState = m_tree[of].state;
      }
      else { m_ownDir = 0; m_ownEnergy = 0.0; m_ownState = 9; }

      // ---- compression persistence (Principle 10) ----
      m_cpForce = Clamp(c.compNow * 0.50 + c.eRes * 0.20 - m_treeDepth * 12.0
                        + MathMax(0.0, c.cmpTighten) * 0.8 + 8.0, 0.0, 100.0);
      m_cpState = (m_cpForce >= 60.0) ? "PERSISTING" : (m_cpForce <= 35.0) ? "LEAKING" : "NEUTRAL";

      // ---- retrace depth + progressing ----
      if(m_ownOrigin == 0.0 || m_ownExtreme == 0.0 || m_ownExtreme == m_ownOrigin) m_retrX = 50.0;
      else m_retrX = MathMin(100.0, MathAbs(m_ownExtreme - c.close) / MathAbs(m_ownExtreme - m_ownOrigin) * 100.0);
      bool attacking = (m_ownDir == 1) ? (c.high >= m_ownExtreme) : (m_ownDir == -1) ? (c.low <= m_ownExtreme) : false;
      bool trendImp  = (m_ownDir == 1 && c.bullImp) || (m_ownDir == -1 && c.bearImp);
      m_progressing  = attacking || trendImp;
      bool recursionComplete = (m_budgetDepth > 0 && m_treeDepth >= m_budgetDepth);

      // ---- LIFE SCORE ----
      double life = m_cpForce * 0.45 + c.eRes * 0.30
                    + (c.cmpTighten > 0.0 ? 12.0 : 0.0)
                    - ((recursionComplete && !m_progressing) ? 25.0 : 0.0)
                    - ((m_cpState == "LEAKING" && !m_progressing) ? 20.0 : 0.0)
                    + (m_progressing ? 28.0 : 0.0)
                    + (m_retrX < 25.0 ? 16.0 : m_retrX < 45.0 ? 6.0 : m_retrX > 75.0 ? -12.0 : 0.0)
                    + 10.0;
      m_life = Clamp(life, 0.0, 100.0);

      // ---- narrative lineage ----
      UpdateLineage(c);

      // ---- chain vitality ----
      m_wholeChainLife = m_wholeChainLife + 0.02 * (m_life - m_wholeChainLife);
      int ls = ArraySize(m_lifeSeq);
      if(ls >= 2) m_chainVitality = Clamp(50.0 + (m_lifeSeq[ls-1] - m_lifeSeq[0]), 0.0, 100.0);
      else        m_chainVitality = m_wholeChainLife;
      if(m_life >= 50.0)               m_chainScope = "healthy";
      else if(m_chainVitality >= 50.0) m_chainScope = "CURVE only - chain intact";
      else if(m_wholeChainLife >= 45.0)m_chainScope = "CHAIN weakening";
      else                             m_chainScope = "WHOLE CHAIN decaying";
   }

   void UpdateLineage(CurveCtx &c)
   {
      // a new owning direction starts a fresh lineage leg
      if(m_ownDir != m_narrDir)
      {
         m_narrDir = m_ownDir;
         m_legX = (m_ownDir == 1) ? c.high : (m_ownDir == -1) ? c.low : 0.0;
         m_legPBdepth = 0.0;
         m_narrative = 50.0;
         m_supVotes = 0; m_degVotes = 0; m_lastVote = "-";
         ArrayResize(m_seqRetr, 0);
         ArrayResize(m_lifeSeq, 0);
      }
      if(m_ownDir != 0 && m_ownOrigin != 0.0)
      {
         bool newLegX = (m_ownDir == 1) ? (c.high > m_legX) : (c.low < m_legX);
         if(newLegX)
         {
            if(m_legPBdepth > 6.0)
            {
               bool sup = (m_legPBdepth <= 50.0 && c.cmpTighten >= -1.0);
               bool deg = (m_legPBdepth >= 62.0 || c.cmpTighten < -3.0);
               int vote = sup ? 1 : deg ? -1 : 0;
               m_lastVote = (vote == 1) ? "SUPPORT" : (vote == -1) ? "DEGRADE" : "NEUTRAL";
               if(vote == 1) m_supVotes++;
               if(vote == -1) m_degVotes++;
               m_narrative = Clamp(m_narrative + vote * 12.0 + (c.cmpTighten > 0.0 ? 3.0 : -3.0), 0.0, 100.0);
               PushCapD(m_seqRetr, m_legPBdepth, 5);
               PushCapD(m_lifeSeq, m_life, 5);
            }
            m_legX = (m_ownDir == 1) ? c.high : c.low;
            m_legPBdepth = 0.0;
         }
         else
         {
            double denom = MathAbs(m_legX - m_ownOrigin);
            double pbd = (denom > 1e-9) ? MathAbs(m_legX - c.close) / denom * 100.0 : 0.0;
            if(pbd > m_legPBdepth) m_legPBdepth = pbd;
         }
      }
      m_narrState = (m_narrative >= 65.0) ? "STRENGTHENING" : (m_narrative <= 35.0) ? "WEAKENING" : "HOLDING";
      int sr = ArraySize(m_seqRetr);
      m_converging = (sr >= 2 && m_seqRetr[sr-1] < m_seqRetr[sr-2]);
   }

   bool LifeDeadCross()  { return (m_prevLife > InpLifeDeadExit && m_life <= InpLifeDeadExit); }
};

CCampaign gLong;
CCampaign gShort;


//==================================================================
// 11. MULTI-TIMEFRAME CURVE MAP (per-TF direction read + alignment)
//   Replaces the Pine request.security stack with iHigh/iLow swing
//   reads on a fixed child->parent ladder. dir per TF = strict HH+HL
//   (bull) / LH+LL (bear), origin->extreme coordinates retained.
//==================================================================
ENUM_TIMEFRAMES g_mtfTF[9]  = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1, PERIOD_MN1};
string          g_mtfLbl[9] = {"M1","M5","M15","M30","H1","H4","D1","W1","MN"};
int             g_mtfDir[9];
double          g_mtfOrigin[9];
double          g_mtfExtreme[9];
double          g_mtfSupply[9];   // per-TF supply (structural swing HIGH) — resistance
double          g_mtfDemand[9];   // per-TF demand (structural swing LOW)  — support
int             g_mtfPendDir[9];  // debounce: pending new direction per TF
int             g_mtfPendCount[9];// debounce: consecutive confirmations of the pending direction
int             g_mtfRotBar[9];   // bar_index when this TF last ROTATED (changed direction)
int             g_mtfPrevDir[9];  // previous committed direction (to detect a rotation event)

bool IsPivotHighTF(ENUM_TIMEFRAMES tf, int c, int P)
{
   double h = iHigh(_Symbol, tf, c);
   if(h <= 0.0) return false;
   for(int k = 1; k <= P; k++)
   {
      double hu = iHigh(_Symbol, tf, c + k);
      double hd = iHigh(_Symbol, tf, c - k);
      if(hu <= 0.0 || hd <= 0.0) return false;
      if(h <= hu || h <= hd) return false;
   }
   return true;
}
bool IsPivotLowTF(ENUM_TIMEFRAMES tf, int c, int P)
{
   double l = iLow(_Symbol, tf, c);
   if(l <= 0.0) return false;
   for(int k = 1; k <= P; k++)
   {
      double lu = iLow(_Symbol, tf, c + k);
      double ld = iLow(_Symbol, tf, c - k);
      if(lu <= 0.0 || ld <= 0.0) return false;
      if(l >= lu || l >= ld) return false;
   }
   return true;
}

void TF_Read(ENUM_TIMEFRAMES tf, int &dir, double &origin, double &extreme)
{
   dir = 0; origin = 0.0; extreme = 0.0;
   int P = InpPivotLen;
   int lookback = 200;
   double lastSH=0, prevSH=0, lastSL=0, prevSL=0;
   int fH=0, fL=0;
   for(int c = P + 1; c <= P + lookback && (fH < 2 || fL < 2); c++)
   {
      if(fH < 2 && IsPivotHighTF(tf, c, P))
      { if(fH == 0) lastSH = iHigh(_Symbol, tf, c); else prevSH = iHigh(_Symbol, tf, c); fH++; }
      if(fL < 2 && IsPivotLowTF(tf, c, P))
      { if(fL == 0) lastSL = iLow(_Symbol, tf, c); else prevSL = iLow(_Symbol, tf, c); fL++; }
   }
   if(fH >= 2 && fL >= 2)
   {
      bool bull = (lastSH > prevSH && lastSL > prevSL);
      bool bear = (lastSH < prevSH && lastSL < prevSL);
      if(bull) { dir = 1;  origin = lastSL; extreme = lastSH; }
      else if(bear) { dir = -1; origin = lastSH; extreme = lastSL; }
   }
}

// Did the last closed bar print a FRESH new high / low over InpExtremeLookback bars?
bool NewHighMade()
{
   int N = (InpExtremeLookback < 2) ? 2 : InpExtremeLookback;
   if((int)ArraySize(High) < N + 2) return false;
   double h = High[1];
   for(int k = 2; k <= N; k++) if(High[k] >= h) return false;
   return true;
}
bool NewLowMade()
{
   int N = (InpExtremeLookback < 2) ? 2 : InpExtremeLookback;
   if((int)ArraySize(Low) < N + 2) return false;
   double l = Low[1];
   for(int k = 2; k <= N; k++) if(Low[k] <= l) return false;
   return true;
}

void UpdateMTFMap()
{
   for(int i = 0; i < 9; i++)
   {
      int rawDir = 0; double o = 0.0, e = 0.0;
      TF_Read(g_mtfTF[i], rawDir, o, e);

      // --- FAST-FLIP at a FRESH EXTREME: a new high with M1 rotating bearish (or a new
      //     low with M1 bullish) is a decisive reversal AT the extreme (the high/low IS
      //     a supply/demand). Commit M1 immediately, bypassing the debounce, so we never
      //     buy a rotated-bearish new high (or sell a rotated-bullish new low). ---
      bool fastFlip = (i == 0) && rawDir != 0 && rawDir != g_mtfDir[i] &&
                      ((rawDir == -1 && NewHighMade()) || (rawDir == 1 && NewLowMade()));
      if(fastFlip)
      {
         g_mtfPrevDir[i] = g_mtfDir[i];
         g_mtfDir[i]     = rawDir;
         g_mtfRotBar[i]  = g_barCount;
         g_mtfPendCount[i] = 0; g_mtfPendDir[i] = 0;
      }
      // --- DIRECTION MEMORY / debounce (normal flips) ---
      else if(rawDir != 0 && rawDir != g_mtfDir[i])
      {
         if(rawDir == g_mtfPendDir[i]) g_mtfPendCount[i]++;
         else { g_mtfPendDir[i] = rawDir; g_mtfPendCount[i] = 1; }
         if(g_mtfPendCount[i] >= InpMTFConfirmBars)
         {
            g_mtfPrevDir[i] = g_mtfDir[i];
            g_mtfDir[i]     = rawDir;
            g_mtfRotBar[i]  = g_barCount;   // timestamp WHEN this timeframe rotated
            g_mtfPendCount[i] = 0; g_mtfPendDir[i] = 0;
         }
      }
      else { g_mtfPendCount[i] = 0; g_mtfPendDir[i] = 0; }

      // remember the last REAL structure coordinates (don't wipe them on a neutral read)
      if(rawDir != 0) { g_mtfOrigin[i] = o; g_mtfExtreme[i] = e; }

      if(g_mtfOrigin[i] != 0.0 && g_mtfExtreme[i] != 0.0)
      {
         g_mtfSupply[i] = MathMax(g_mtfOrigin[i], g_mtfExtreme[i]);
         g_mtfDemand[i] = MathMin(g_mtfOrigin[i], g_mtfExtreme[i]);
      }

      // --- STRUCTURE-DERIVED PHASE: same leg drives dir, zones AND phase, so a rung's
      //     P3/P4 can never contradict its own structure. retrace of price between the
      //     leg's extreme and origin, in the structural direction. ---
      int pL = 0, pS = 0;
      double cl  = iClose(_Symbol, g_mtfTF[i], 1);
      double clp = iClose(_Symbol, g_mtfTF[i], 2);
      double dmom = cl - clp;
      if(g_mtfDir[i] == 1 && g_mtfExtreme[i] > 0.0 && g_mtfOrigin[i] > 0.0)
      {
         double E = g_mtfExtreme[i], O = g_mtfOrigin[i];   // bull: E=swing high, O=swing low
         double imp = E - O;
         double retr = (imp > 0.0) ? (E - cl) / imp : 0.0;
         if(retr > InpRetrMax || retr < 0.0)  pL = 0;
         else if(cl >= E)                     pL = 4;       // new high / breakout
         else if(retr >= InpRetrMin)          pL = (dmom < 0.0 ? 2 : 3);
         else                                 pL = 1;       // expansion near the high
      }
      else if(g_mtfDir[i] == -1 && g_mtfExtreme[i] > 0.0 && g_mtfOrigin[i] > 0.0)
      {
         double E = g_mtfExtreme[i], O = g_mtfOrigin[i];   // bear: E=swing low, O=swing high
         double imp = O - E;
         double retr = (imp > 0.0) ? (cl - E) / imp : 0.0;
         if(retr > InpRetrMax || retr < 0.0)  pS = 0;
         else if(cl <= E)                     pS = 4;       // new low / breakdown
         else if(retr >= InpRetrMin)          pS = (dmom > 0.0 ? 2 : 3);
         else                                 pS = 1;       // expansion near the low
      }
      g_mtfPhaseL[i] = pL;
      g_mtfPhaseS[i] = pS;
   }
}

// Which timeframe's supply/demand is price currently sitting in/at (nearest, in ATR)?
int NearestZoneTF(double px, double atr, bool wantSupply, double &roomATR)
{
   roomATR = 1e9; int best = -1;
   for(int i = 0; i < 9; i++)
   {
      double lvl = wantSupply ? g_mtfSupply[i] : g_mtfDemand[i];
      if(lvl <= 0.0) continue;
      double r = MathAbs(lvl - px) / MathMax(atr, 1e-9);
      if(r < roomATR) { roomATR = r; best = i; }
   }
   return best;
}

int MTF_Align(int campDir)
{
   if(campDir == 0) return 0;
   int n = 0;
   for(int i = 0; i < 9; i++) if(g_mtfDir[i] == campDir) n++;
   return n;
}

string MTF_StoryLine()
{
   string s = "";
   for(int i = 0; i < 9; i++)
   {
      string a = (g_mtfDir[i] == 1) ? "^" : (g_mtfDir[i] == -1) ? "v" : "-";
      s += g_mtfLbl[i] + a + " ";
   }
   return s;
}

// ===== Owner-Driven Destination Engine (ODDE) =====
// owner = the HIGHEST timeframe currently holding the given direction (hierarchical
// ownership). The destination inherits from the owner curve and auto-escalates: once
// price breaks the owner's zone, the next higher timeframe's zone becomes the target.
int OwnerTF(int dir)
{
   int idx = -1;
   for(int i = 0; i < 9; i++) if(g_mtfDir[i] == dir) idx = i;   // highest index matching dir
   return idx;
}
// LONG destination: nearest SUPPLY above price at/above the bull owner (escalates up).
double DestinationSupply(double px, double atr, int &tfOut, double &roomATR)
{
   tfOut = -1; roomATR = 1e9; double best = 0.0;
   int owner = OwnerTF(1);
   int lo = (owner >= 0) ? owner : ((InpParentFromTFIndex < 0) ? 0 : InpParentFromTFIndex);
   for(int i = lo; i < 9; i++)
   {
      double v = g_mtfSupply[i];
      if(v > px && (best == 0.0 || v < best)) { best = v; tfOut = i; }
   }
   if(best > 0.0) roomATR = (best - px) / MathMax(atr, 1e-9);
   return best;
}
// SHORT destination: nearest DEMAND below price at/above the bear owner (escalates up).
double DestinationDemand(double px, double atr, int &tfOut, double &roomATR)
{
   tfOut = -1; roomATR = 1e9; double best = 0.0;
   int owner = OwnerTF(-1);
   int lo = (owner >= 0) ? owner : ((InpParentFromTFIndex < 0) ? 0 : InpParentFromTFIndex);
   for(int i = lo; i < 9; i++)
   {
      double v = g_mtfDemand[i];
      if(v > 0.0 && v < px && v > best) { best = v; tfOut = i; }
   }
   if(best > 0.0) roomATR = (px - best) / MathMax(atr, 1e-9);
   return best;
}

// Net MTF DIRECTION authority: higher timeframes weigh more (owner = higher TF).
// Returns +1 bullish bias, -1 bearish bias, 0 balanced. This is the direction the
// algo is ALLOWED to trade — entries against it are blocked.
double MTFBiasScore()
{
   double sum = 0.0;
   for(int i = 0; i < 9; i++) sum += (double)(i + 1) * (double)g_mtfDir[i];
   return sum;   // range -21..+21
}
int MTFBias()
{
   double sum = MTFBiasScore();
   if(MathAbs(sum) <= InpMTFBiasDeadband) return 0;   // balanced: one top TF can't veto aligned lower TFs
   return (sum > 0.0) ? 1 : -1;
}
// ===== ROTATION CASCADE ENGINE =====
// Rotation propagates UP the ladder: M1 -> M5 -> M15 -> M30 -> H1 -> H4 -> D1 -> W1.
// We track WHEN each timeframe rotated (g_mtfRotBar) and measure how far the current
// rotation has climbed from the bottom (depth), whether it climbed in order (clean =
// each higher TF turned at/after the lower one, i.e. the lower LED it), and which
// timeframe it is now pressuring next.
int  g_cascadeDir    = 0;
int  g_cascadeDepth  = 0;
bool g_cascadeClean  = false;
int  g_cascadeNextTF = -1;
// major-zone CONTEXT latch: a SELL campaign is born at a major SUPPLY, a BUY campaign
// at a major DEMAND (the reversal zone). Set when the cascade flips direction AT a
// major zone; the cascade then propagates and entries cascade along the leg.
int  g_prevCascadeDir = 0;
bool g_sellContext    = false;
bool g_buyContext     = false;
int  g_sellCtxTF      = -1;
int  g_buyCtxTF       = -1;
// ----- HUNT-MODE CYCLE -----  buy demand below flip -> TP at flip -> hunt sells above
// flip -> TP at flip -> hunt buys below ... The HTF flip zone is the natural TP and the
// auto-switch pivot. g_huntMode = +1 hunt BUYS (below flip), -1 hunt SELLS (above flip).
int    g_huntMode    = 0;
double g_flip        = 0.0;   // HTF flip level (TP + buy/sell divider)
double g_flipSupply  = 0.0;   // controlling-HTF supply (above flip)
double g_flipDemand  = 0.0;   // controlling-HTF demand (below flip)

void ComputeCascade()
{
   g_cascadeDir   = g_mtfDir[0];
   g_cascadeDepth = 0;
   g_cascadeClean = (g_cascadeDir != 0);
   if(g_cascadeDir != 0)
   {
      g_cascadeDepth = 1;
      for(int i = 1; i < 9; i++)
      {
         if(g_mtfDir[i] != g_cascadeDir) break;                        // contiguous block from M1 up
         if(g_mtfRotBar[i] < g_mtfRotBar[i-1]) g_cascadeClean = false; // higher turned BEFORE lower -> not lower-led
         g_cascadeDepth++;
      }
   }
   g_cascadeNextTF = (g_cascadeDepth > 0 && g_cascadeDepth < 9) ? g_cascadeDepth : -1;
}

// nearest MAJOR (higher-TF) zone to price: dir=-1 -> supply, dir=+1 -> demand.
double NearestMajorZone(int dir, double px, double atr, int &tfOut, double &roomATR)
{
   tfOut = -1; roomATR = 1e9; double best = 0.0;
   int lo = (InpMajorFromTFIndex < 0) ? 0 : (InpMajorFromTFIndex > 8 ? 8 : InpMajorFromTFIndex);
   for(int i = lo; i < 9; i++)
   {
      double z = (dir == -1) ? g_mtfSupply[i] : g_mtfDemand[i];
      if(z <= 0.0) continue;
      double d = MathAbs(px - z) / MathMax(atr, 1e-9);
      if(d < roomATR) { roomATR = d; tfOut = i; best = z; }
   }
   return best;
}

// Latch the campaign context on a cascade direction flip: bearish flip AT a major
// supply -> sell context; bullish flip AT a major demand -> buy context.
void UpdateZoneContext()
{
   if(g_cascadeDir == g_prevCascadeDir) return;     // only re-evaluate on a direction change
   double px = Close[1], atr = GetATR(1); if(atr <= 0.0) atr = 1e-6;
   int tf = -1; double room = 1e9;
   if(g_cascadeDir == -1)
   {
      double z = NearestMajorZone(-1, px, atr, tf, room);
      g_sellContext = (z > 0.0 && room <= InpMajorZoneATR);
      g_sellCtxTF   = g_sellContext ? tf : -1;
      g_buyContext  = false; g_buyCtxTF = -1;
      g_prevCascadeDir = g_cascadeDir;
   }
   else if(g_cascadeDir == 1)
   {
      double z = NearestMajorZone(1, px, atr, tf, room);
      g_buyContext = (z > 0.0 && room <= InpMajorZoneATR);
      g_buyCtxTF   = g_buyContext ? tf : -1;
      g_sellContext = false; g_sellCtxTF = -1;
      g_prevCascadeDir = g_cascadeDir;
   }
   // g_cascadeDir == 0 -> keep the existing context until a real flip
}

// ===== FLIP ZONE + HUNT-MODE CYCLE =====
// The controlling HTF (InpFlipTFIndex) defines a flip level = midpoint of its
// supply/demand. Demand sits below the flip, supply above. The flip is the natural
// TP for BOTH directions and the auto-switch pivot of the hunt cycle.
void ComputeFlip()
{
   int tf = (InpFlipTFIndex < 0) ? 0 : (InpFlipTFIndex > 8 ? 8 : InpFlipTFIndex);
   double sup = g_mtfSupply[tf], dem = g_mtfDemand[tf];
   if(sup > 0.0 && dem > 0.0 && sup > dem)
   {
      g_flipSupply = sup; g_flipDemand = dem;
      g_flip = (sup + dem) * 0.5;
   }
}

// Ride pullback-legs to the PARENT TARGET, then TP + AUTO-SWITCH. The controlling-HTF
// SUPPLY is the up-cycle target, its DEMAND the down-cycle target. Within the leg the
// rotations are pullbacks (re-buys at lower-TF demands), NOT reversals — the reversal
// is only when price reaches the opposite parent pole. When flat, hunt aligns to which
// half of the HTF range price sits in.
void UpdateHuntCycle()
{
   if(!InpUseHuntCycle) return;
   if(g_flipSupply <= 0.0 || g_flipDemand <= 0.0 || g_flipSupply <= g_flipDemand) return;
   double px   = Close[1];
   double band = InpFlipBandATR * GetATR(1);
   int longPos  = CountDirectionPositions(1);
   int shortPos = CountDirectionPositions(-1);

   // up-cycle expanded into the PARENT SUPPLY -> take profit, switch to hunting sells
   if(g_huntMode == 1 && px >= g_flipSupply - band)
   { if(longPos > 0) CloseDirection(1, "SYM TP PARENT supply"); g_huntMode = -1; return; }
   // down-cycle expanded into the PARENT DEMAND -> take profit, switch to hunting buys
   if(g_huntMode == -1 && px <= g_flipDemand + band)
   { if(shortPos > 0) CloseDirection(-1, "SYM TP PARENT demand"); g_huntMode = 1; return; }

   // init / realign when flat: lower half of the HTF range -> expand UP; upper half -> expand DOWN
   if(g_huntMode == 0 || (longPos == 0 && shortPos == 0))
      g_huntMode = (px < g_flip) ? 1 : -1;
}

// Lower-timeframe ROTATION (cascade-based): the rotation has climbed at least
// InpRotCount timeframes from the bottom in 'dir'. Lower timeframes LEAD, so this
// direction is permitted and the opposite blocked, even against a higher-TF bias.
bool LowerTFRotation(int dir)
{
   return (g_cascadeDir == dir && g_cascadeDepth >= InpRotCount);
}

// ===== CROSS-TIMEFRAME PHASE COMMUNICATION =====
// How many timeframes are telling the same story for 'dir' — an active campaign in
// that direction (any phase) OR a structural bias in that direction. Used so an
// entry only fires where the phases across timeframes AGREE (not a random single TF).
int PhaseConfluence(int dir)
{
   int n = 0;
   for(int i = 0; i < 9; i++)
      if(g_mtfDir[i] == dir) n++;                       // structurally aligned timeframes
   return n;
}
// Is the entry nested under a HIGHER timeframe whose structure supports the direction?
bool HigherTFSupports(int idx, int dir)
{
   for(int j = idx + 1; j < 9; j++)
      if(g_mtfDir[j] == dir) return true;
   return false;
}

// PHASE TRIGGER (the TIMING): a timeframe in P3/P4 in 'dir', derived from the SAME
// structural leg as its direction — P3 = retracement complete (resume), P4 = breakout.
bool PhaseTrigger(int dir)
{
   for(int i = 0; i < 9; i++)
   {
      int ph = (dir == 1) ? g_mtfPhaseL[i] : g_mtfPhaseS[i];
      if(g_mtfDir[i] == dir && (ph == 3 || ph == 4)) return true;
   }
   return false;
}
// Any timeframe currently in a P3/P4 firing window in 'dir'.
bool PhaseJustTransitioned(int dir)
{
   for(int i = 0; i < 9; i++)
   {
      int ph = (dir == 1) ? g_mtfPhaseL[i] : g_mtfPhaseS[i];
      if(g_mtfDir[i] == dir && ph >= 3) return true;
   }
   return false;
}

//==================================================================
// 11B. PER-TIMEFRAME STRUCTURE ENGINE  (P3/P4 on ALL curves)
//   The same impulse -> phase 1-4 -> induc-zone machine the chart
//   uses, instantiated on every ladder timeframe for BOTH directions.
//   This is what lets P3/P4 trade off all curves, all timeframes.
//   Each rung steps once per its own closed bar.
//==================================================================
int g_mtfATR[9];        // per-TF ATR handles
int g_mtfPhaseL[9];     // per-TF long phase  (0 if inactive)
int g_mtfPhaseS[9];     // per-TF short phase (0 if inactive)

struct TFEngine
{
   datetime barTime;
   // shared pivot history
   double lastPivotPrice; int lastPivotDir; int lastPivotShift;
   double prevPivotPrice; int prevPivotDir;
   // long
   bool   Lactive; double LanchorHigh, LanchorLow; int LanchorHighShift, LanchorLowShift;
   int    Lphase, LprevPhase; bool LpreConv; double LinducPrice, LinducLow, LinducHigh; double LcycleHigh;
   datetime LlastTrade;
   // short
   bool   Sactive; double SanchorHigh, SanchorLow; int SanchorHighShift, SanchorLowShift;
   int    Sphase, SprevPhase; bool SpreConv; double SinducPrice, SinducLow, SinducHigh; double ScycleLow;
   datetime SlastTrade;
};
TFEngine gTFEng[9];

double TFATR(int idx)
{
   if(g_mtfATR[idx] == INVALID_HANDLE) return 0.0;
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_mtfATR[idx], 0, 1, 1, buf) < 1) return 0.0;
   return buf[0];
}

void FindInducZoneTF(ENUM_TIMEFRAMES tf, int anchorShift, double aHigh, double aLow, double atr,
                     double &price, double &lo, double &hi)
{
   price = 0.0; lo = 0.0; hi = 0.0;
   double best = 0.0; int bestDist = -1;
   if(anchorShift > 0)
      for(int s = anchorShift - 1; s >= 0 && s >= anchorShift - InpInducLookbackBars; s--)
      {
         double hs = iHigh(_Symbol, tf, s);
         double ls = iLow (_Symbol, tf, s);
         if(hs < aHigh && ls > aLow)
         { int d = MathAbs(anchorShift - s); if(bestDist < 0 || d < bestDist) { bestDist = d; best = (hs + ls) * 0.5; } }
      }
   if(bestDist >= 0) { price = best; lo = best - atr * InpInducZoneATRWidth; hi = best + atr * InpInducZoneATRWidth; }
}

void UpdateTFEngine(int idx)
{
   ENUM_TIMEFRAMES tf = g_mtfTF[idx];
   if(iBars(_Symbol, tf) < 2 * InpPivotLen + 6) return;
   datetime t0 = iTime(_Symbol, tf, 0);
   if(t0 == 0) return;
   if(t0 == gTFEng[idx].barTime) return;   // step once per NEW closed TF bar
   gTFEng[idx].barTime = t0;

   double closeNow = iClose(_Symbol, tf, 1);
   double atr = TFATR(idx);
   if(atr <= 0.0) atr = 1e-6;

   int center = InpPivotLen + 1;
   int pivotDir = 0; double pivotPrice = 0.0; int pivotShift = -1;
   if(IsPivotHighTF(tf, center, InpPivotLen))      { pivotDir = 1;  pivotPrice = iHigh(_Symbol, tf, center); pivotShift = center; }
   else if(IsPivotLowTF(tf, center, InpPivotLen))  { pivotDir = -1; pivotPrice = iLow (_Symbol, tf, center); pivotShift = center; }

   // LONG impulse: prior low -> higher high
   if(pivotDir == 1 && gTFEng[idx].lastPivotDir == -1 && (pivotPrice - gTFEng[idx].lastPivotPrice) > atr * InpImpulseAtrMult)
   {
      gTFEng[idx].Lactive = true;
      gTFEng[idx].LanchorLow  = gTFEng[idx].lastPivotPrice; gTFEng[idx].LanchorLowShift  = gTFEng[idx].lastPivotShift;
      gTFEng[idx].LanchorHigh = pivotPrice;                 gTFEng[idx].LanchorHighShift = pivotShift;
      gTFEng[idx].Lphase = 1; gTFEng[idx].LpreConv = false;
      gTFEng[idx].LinducPrice = gTFEng[idx].LinducLow = gTFEng[idx].LinducHigh = 0.0;
      gTFEng[idx].LcycleHigh = iHigh(_Symbol, tf, 1);
      FindInducZoneTF(tf, gTFEng[idx].LanchorLowShift, gTFEng[idx].LanchorHigh, gTFEng[idx].LanchorLow, atr,
                      gTFEng[idx].LinducPrice, gTFEng[idx].LinducLow, gTFEng[idx].LinducHigh);
   }
   // SHORT impulse: prior high -> lower low
   if(pivotDir == -1 && gTFEng[idx].lastPivotDir == 1 && (gTFEng[idx].lastPivotPrice - pivotPrice) > atr * InpImpulseAtrMult)
   {
      gTFEng[idx].Sactive = true;
      gTFEng[idx].SanchorHigh = gTFEng[idx].lastPivotPrice; gTFEng[idx].SanchorHighShift = gTFEng[idx].lastPivotShift;
      gTFEng[idx].SanchorLow  = pivotPrice;                 gTFEng[idx].SanchorLowShift  = pivotShift;
      gTFEng[idx].Sphase = 1; gTFEng[idx].SpreConv = false;
      gTFEng[idx].SinducPrice = gTFEng[idx].SinducLow = gTFEng[idx].SinducHigh = 0.0;
      gTFEng[idx].ScycleLow = iLow(_Symbol, tf, 1);
      FindInducZoneTF(tf, gTFEng[idx].SanchorHighShift, gTFEng[idx].SanchorHigh, gTFEng[idx].SanchorLow, atr,
                      gTFEng[idx].SinducPrice, gTFEng[idx].SinducLow, gTFEng[idx].SinducHigh);
   }

   // pivot history
   if(pivotDir != 0)
   {
      gTFEng[idx].prevPivotPrice = gTFEng[idx].lastPivotPrice; gTFEng[idx].prevPivotDir = gTFEng[idx].lastPivotDir;
      gTFEng[idx].lastPivotPrice = pivotPrice; gTFEng[idx].lastPivotDir = pivotDir; gTFEng[idx].lastPivotShift = pivotShift;
   }

   // cycle extremes
   if(gTFEng[idx].Lactive && iHigh(_Symbol, tf, 1) > gTFEng[idx].LcycleHigh) gTFEng[idx].LcycleHigh = iHigh(_Symbol, tf, 1);
   if(gTFEng[idx].Sactive && iLow (_Symbol, tf, 1) < gTFEng[idx].ScycleLow)  gTFEng[idx].ScycleLow  = iLow (_Symbol, tf, 1);

   // invalidation
   if(gTFEng[idx].Lactive && closeNow < gTFEng[idx].LanchorLow)  { gTFEng[idx].Lactive = false; gTFEng[idx].Lphase = 0; }
   if(gTFEng[idx].Sactive && closeNow > gTFEng[idx].SanchorHigh) { gTFEng[idx].Sactive = false; gTFEng[idx].Sphase = 0; }

   int oldL = gTFEng[idx].Lphase, oldS = gTFEng[idx].Sphase;

   // LONG phase
   if(!gTFEng[idx].Lactive) gTFEng[idx].Lphase = 0;
   if(gTFEng[idx].Lactive && gTFEng[idx].LanchorHighShift >= 0 && gTFEng[idx].LanchorLowShift >= 0)
   {
      double impL  = gTFEng[idx].LanchorHigh - gTFEng[idx].LanchorLow;
      double retrL = (impL > 0.0) ? (gTFEng[idx].LanchorHigh - closeNow) / impL : 0.0;
      double dL    = iClose(_Symbol, tf, 1) - iClose(_Symbol, tf, 2);
      int p;
      if(retrL > InpRetrMax || retrL < 0.0)        p = 0;
      else if(closeNow >= gTFEng[idx].LanchorHigh) p = 4;
      else if(retrL >= InpRetrMin)                 p = (dL < 0.0 ? 2 : 3);
      else                                         p = 1;
      bool hz = (gTFEng[idx].LinducLow != 0.0 || gTFEng[idx].LinducHigh != 0.0);
      if(p == 3 && hz && closeNow >= gTFEng[idx].LinducLow) p = 2;
      else if(p == 3) gTFEng[idx].LpreConv = true;
      if(p == 4 && !gTFEng[idx].LpreConv) p = 2;
      gTFEng[idx].Lphase = p;
   }
   // SHORT phase
   if(!gTFEng[idx].Sactive) gTFEng[idx].Sphase = 0;
   if(gTFEng[idx].Sactive && gTFEng[idx].SanchorHighShift >= 0 && gTFEng[idx].SanchorLowShift >= 0)
   {
      double impS  = gTFEng[idx].SanchorHigh - gTFEng[idx].SanchorLow;
      double retrS = (impS > 0.0) ? (closeNow - gTFEng[idx].SanchorLow) / impS : 0.0;
      double dS    = iClose(_Symbol, tf, 1) - iClose(_Symbol, tf, 2);
      int p;
      if(retrS > InpRetrMax || retrS < 0.0)       p = 0;
      else if(closeNow <= gTFEng[idx].SanchorLow) p = 4;
      else if(retrS >= InpRetrMin)                p = (dS > 0.0 ? 2 : 3);
      else                                        p = 1;
      bool hz = (gTFEng[idx].SinducLow != 0.0 || gTFEng[idx].SinducHigh != 0.0);
      if(p == 3 && hz && closeNow <= gTFEng[idx].SinducHigh) p = 2;
      else if(p == 3) gTFEng[idx].SpreConv = true;
      if(p == 4 && !gTFEng[idx].SpreConv) p = 2;
      gTFEng[idx].Sphase = p;
   }

   gTFEng[idx].LprevPhase = oldL; gTFEng[idx].SprevPhase = oldS;
}

void UpdateMTFEngines()
{
   for(int i = 0; i < 9; i++)
   {
      UpdateTFEngine(i);
      g_mtfPhaseL[i] = gTFEng[i].Lactive ? gTFEng[i].Lphase : 0;
      g_mtfPhaseS[i] = gTFEng[i].Sactive ? gTFEng[i].Sphase : 0;
   }
}

//==================================================================
// 12. ARC v2 - per direction
//==================================================================
void UpdateARC()
{
   gL_arc = 0.0; gS_arc = 0.0;
   int bars = ArraySize(Close);
   if(bars < 10) return;
   int shift = 1;

   if(gL_active && gL_anchorLowShift >= 0 && gL_anchorHighShift >= 0)
   {
      double impL = gL_anchorHigh - gL_anchorLow;
      if(impL > 0)
      {
         double targetL = gL_anchorLow + impL * InpArcExtMult;
         double tL = (double)(gL_anchorLowShift - shift) / (double)InpArcHorizonBars;
         tL = Clamp(tL, 0.0, 1.0);
         gL_arc = gL_anchorLow + (targetL - gL_anchorLow) * MathPow(tL, InpConvPower);
      }
   }
   if(gS_active && gS_anchorLowShift >= 0 && gS_anchorHighShift >= 0)
   {
      double impS = gS_anchorHigh - gS_anchorLow;
      if(impS > 0)
      {
         double targetS = gS_anchorHigh - impS * InpArcExtMult;
         double tS = (double)(gS_anchorHighShift - shift) / (double)InpArcHorizonBars;
         tS = Clamp(tS, 0.0, 1.0);
         gS_arc = gS_anchorHigh + (targetS - gS_anchorHigh) * MathPow(tS, InpConvPower);
      }
   }
}

//==================================================================
// 13. LOT ENGINE + BASKET CEILING (per direction, unchanged from v3.0)
//==================================================================
double ComputeLots(double riskCash, double entry, double sl)
{
   double dist = MathAbs(entry - sl);
   if(dist <= 0.0) return 0.0;
   double distancePips  = dist * 10.0;
   double pipValuePerLot= 10.0;
   double riskPerLot    = distancePips * pipValuePerLot;
   if(riskPerLot <= 0.0) return 0.0;
   double lots    = riskCash / riskPerLot;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   return NormalizeDouble(lots, 2);
}

double GetBasketDollarRisk(int direction)
{
   double totalRisk = 0.0;
   double atrFallback = GetATR(1);
   if(atrFallback <= 0.0) atrFallback = 10.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      int  dir  = (type == POSITION_TYPE_BUY) ? 1 : -1;
      if(dir != direction) continue;
      double lots  = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double distSL = (sl > 0.0) ? MathAbs(entry - sl) : (2.0 * atrFallback);
      totalRisk += lots * distSL * 100.0;
   }
   return totalRisk;
}

double AdjustLotsForBasketCeiling(int direction, double entry, double sl, double computedLots)
{
   if(computedLots <= 0.0) return 0.0;
   double equity        = AccountInfoDouble(ACCOUNT_EQUITY);
   double maxBasketRisk = equity * InpMaxBasketRiskPct / 100.0;
   double currentRisk   = GetBasketDollarRisk(direction);
   double available     = maxBasketRisk - currentRisk;
   if(available <= 0.0) return 0.0;
   double distSL = MathAbs(entry - sl);
   if(distSL <= 0.0) return 0.0;
   if(computedLots * distSL * 100.0 <= available) return computedLots;
   double maxLots = available / (distSL * 100.0);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   maxLots = MathFloor(maxLots / lotStep) * lotStep;
   if(maxLots < minLot) return 0.0;
   return NormalizeDouble(maxLots, 2);
}

double GetDirectionFloatingPnL(int direction)
{
   double total = 0.0;
   int cnt = PositionsTotal();
   for(int i = 0; i < cnt; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY ? 1 : -1) != direction) continue;
      total += PositionGetDouble(POSITION_PROFIT)
             + PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

int CountDirectionPositions(int direction)
{
   int c = 0;
   int cnt = PositionsTotal();
   for(int i = 0; i < cnt; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY ? 1 : -1) != direction) continue;
      c++;
   }
   return c;
}

//==================================================================
// 14. TIME HELPER
//==================================================================
bool IsTradeTime()
{
   MqlDateTime g; TimeGMT(g);
   int h = g.hour + InpTargetGMT;
   int m = g.min;
   if(h <  0)  h += 24;
   if(h >= 24) h -= 24;
   int cur = h * 60 + m;
   bool w1 = (cur >= 480  && cur <= 705);
   bool w2 = (cur >= 705  && cur <= 735);
   bool w3 = (cur >= 795  && cur <= 825);
   bool w4 = (cur >= 870  && cur <= 1080);
   bool k1 = (cur >= 480  && cur <= 540);
   bool k2 = (cur >= 495  && cur <= 525);
   bool k3 = (cur >= 885  && cur <= 915);
   bool k4 = (cur >= 1005 && cur <= 1035);
   return (w1 || w2 || w3 || w4 || k1 || k2 || k3 || k4);
}


//==================================================================
// 15. ORDER EXECUTION HELPERS (RAW IOC)
//==================================================================
bool SendMarketOrder(int direction, double lots, double sl, const string comment)
{
   if(lots <= 0.0) return false;
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = InpMagic;
   req.volume       = lots;
   req.sl           = sl;
   req.tp           = 0.0;
   req.deviation    = 20;
   req.type_filling = ORDER_FILLING_IOC;
   req.type_time    = ORDER_TIME_GTC;
   req.comment      = comment;
   if(direction > 0) { req.type = ORDER_TYPE_BUY;  req.price = ask; }
   else              { req.type = ORDER_TYPE_SELL; req.price = bid; }
   if(!OrderSend(req, res))
   { Print("OrderSend failed dir=",direction," lots=",lots," retcode=",res.retcode); return false; }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
   { Print("OrderSend not DONE, retcode=",res.retcode); return false; }
   return true;
}

bool ClosePositionPartial(ulong ticket, double lotsToClose, const string tag = "SYM CLOSE")
{
   if(lotsToClose <= 0.0) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if(PositionGetInteger(POSITION_MAGIC) != InpMagic) return false;
   long   type    = PositionGetInteger(POSITION_TYPE);
   double posLots = PositionGetDouble(POSITION_VOLUME);
   lotsToClose = NormalizeDouble(lotsToClose, 2);
   if(lotsToClose > posLots) lotsToClose = posLots;
   if(lotsToClose <= 0.0) return false;
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = InpMagic;
   req.position     = ticket;
   req.volume       = lotsToClose;
   req.deviation    = 20;
   req.type_filling = ORDER_FILLING_IOC;
   req.type_time    = ORDER_TIME_GTC;
   req.comment      = tag;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(type == POSITION_TYPE_BUY)  { req.type = ORDER_TYPE_SELL; req.price = bid; }
   else                           { req.type = ORDER_TYPE_BUY;  req.price = ask; }
   if(!OrderSend(req, res))
   { Print("ClosePartial failed ticket=",ticket," retcode=",res.retcode); return false; }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
   { Print("ClosePartial not DONE ticket=",ticket," retcode=",res.retcode); return false; }
   return true;
}

bool ClosePositionFull(ulong ticket, const string tag = "SYM CLOSE")
{
   if(!PositionSelectByTicket(ticket)) return false;
   double lots = PositionGetDouble(POSITION_VOLUME);
   return ClosePositionPartial(ticket, lots, tag);
}

// close the entire book for one direction
void CloseDirection(int direction, const string tag)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY ? 1 : -1) != direction) continue;
      ClosePositionFull(ticket, tag);
   }
}

//==================================================================
// 16. STOP PROTECTION (per direction)
//==================================================================
void MoveStopsToBreakeven(int direction)
{
   int cnt = PositionsTotal();
   for(int i = 0; i < cnt; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY ? 1 : -1) != direction) continue;
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      bool   needsMove = false;
      if(direction > 0 && currentSL < entry)  needsMove = true;
      if(direction < 0 && (currentSL == 0.0 || currentSL > entry)) needsMove = true;
      if(needsMove)
      {
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = _Symbol;
         req.position = ticket;
         req.sl       = entry;
         req.tp       = currentTP;
         if(!OrderSend(req, res))
            Print("SYM BE move failed ticket=",ticket," err=",GetLastError());
      }
   }
}

void TrailStops(int direction)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int cnt = PositionsTotal();
   for(int i = 0; i < cnt; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY ? 1 : -1) != direction) continue;
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double newSL     = currentSL;
      bool   needsMove = false;
      if(direction > 0)
      {
         double locked = entry + (bid - entry) * InpTrailLockPct / 100.0;
         if(locked > currentSL && locked > entry) { newSL = locked; needsMove = true; }
      }
      else
      {
         double locked = entry - (entry - ask) * InpTrailLockPct / 100.0;
         if((currentSL == 0.0 || locked < currentSL) && locked < entry) { newSL = locked; needsMove = true; }
      }
      if(needsMove)
      {
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);
         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = _Symbol;
         req.position = ticket;
         req.sl       = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         req.tp       = currentTP;
         if(!OrderSend(req, res)) Print("SYM trail SLTP failed ticket=",ticket," err=",GetLastError());
      }
   }
}

void RunStopProtection()
{
   if(g_longBEActive  && !g_longTrailActive)  MoveStopsToBreakeven(1);
   if(g_shortBEActive && !g_shortTrailActive) MoveStopsToBreakeven(-1);
   if(g_longTrailActive)  TrailStops(1);
   if(g_shortTrailActive) TrailStops(-1);
}

//==================================================================
// 17. PROFIT LADDER (per direction)
//==================================================================
void CloseProportionalAllPositions(int direction, double fractionPerPos, const string tag)
{
   if(fractionPerPos <= 0.0) return;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY ? 1 : -1) != direction) continue;
      double lots      = PositionGetDouble(POSITION_VOLUME);
      double closeThis = MathFloor((lots * fractionPerPos) / lotStep) * lotStep;
      if(closeThis < minLot) continue;
      ClosePositionPartial(ticket, closeThis, tag);
   }
}

void RunProfitLadderDirection(int direction, int &rungs)
{
   double totalLots = 0.0, totalRisk = 0.0, totalPnL = 0.0;
   int    posCount  = 0;
   double atrFB     = GetATR(1); if(atrFB <= 0.0) atrFB = 10.0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY ? 1 : -1) != direction) continue;
      double lots  = PositionGetDouble(POSITION_VOLUME);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double pnl   = PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
      double distSL = (sl > 0.0) ? MathAbs(entry - sl) : 0.0;
      if(distSL < 1.0) distSL = atrFB;
      totalLots += lots;
      totalRisk += lots * distSL * 100.0;
      totalPnL  += pnl;
      posCount++;
   }
   if(posCount == 0)
   {
      rungs = 0;
      if(direction > 0) { g_longBEActive = false;  g_longTrailActive  = false; }
      else              { g_shortBEActive = false; g_shortTrailActive = false; }
      return;
   }
   if(totalRisk <= 0.0) return;
   double ratio  = totalPnL / totalRisk;
   string dirStr = (direction > 0) ? "LONG" : "SHORT";
   if(rungs == 0 && ratio >= InpLadderRung1)
   {
      Print("SYM LADDER Rung1 ",dirStr," ratio=",DoubleToString(ratio,2));
      CloseProportionalAllPositions(direction, InpLadderFrac1, "SYM LADDER R1");
      rungs = 1;
      if(direction > 0) g_longBEActive  = true; else g_shortBEActive = true;
      MoveStopsToBreakeven(direction);
   }
   else if(rungs == 1 && ratio >= InpLadderRung2)
   {
      Print("SYM LADDER Rung2 ",dirStr," ratio=",DoubleToString(ratio,2));
      CloseProportionalAllPositions(direction, InpLadderFrac2, "SYM LADDER R2");
      rungs = 2;
      if(direction > 0) { g_longBEActive = false;  g_longTrailActive  = true; }
      else              { g_shortBEActive = false; g_shortTrailActive = true; }
   }
   else if(rungs == 2 && ratio >= InpLadderRung3)
   {
      Print("SYM LADDER Rung3 ",dirStr," ratio=",DoubleToString(ratio,2));
      CloseProportionalAllPositions(direction, InpLadderFrac3, "SYM LADDER R3");
      rungs = 3;
   }
}

void RunProfitLadder()
{
   RunProfitLadderDirection( 1, g_longRungs);
   RunProfitLadderDirection(-1, g_shortRungs);
}


//==================================================================
// 18. EXITS - LIFE SCORE (primary) + ARC/phase + invalidation-at-peak
//   Each campaign is managed on its OWN life, ARC and phase. Life
//   crossing below the dead threshold = ownership transferred =>
//   close that direction's book ("DEAD - FLIP").
//==================================================================
// nearest higher-timeframe SUPPLY above price (resistance a long is travelling into),
// drawn from the per-TF supply coordinates so all timeframes are considered.
double ParentSupplyAbove(double px, double atr, double &roomATR)
{
   roomATR = 1e9; double best = 0.0;
   int lo = (InpParentFromTFIndex < 0) ? 0 : (InpParentFromTFIndex > 8 ? 8 : InpParentFromTFIndex);
   for(int i = lo; i < 9; i++)
   {
      double v = g_mtfSupply[i];
      if(v > px && (best == 0.0 || v < best)) best = v;   // nearest above
   }
   if(best > 0.0) roomATR = (best - px) / MathMax(atr, 1e-9);
   return best;
}
// nearest higher-timeframe DEMAND below price (support a short is travelling into).
double ParentDemandBelow(double px, double atr, double &roomATR)
{
   roomATR = 1e9; double best = 0.0;
   int lo = (InpParentFromTFIndex < 0) ? 0 : (InpParentFromTFIndex > 8 ? 8 : InpParentFromTFIndex);
   for(int i = lo; i < 9; i++)
   {
      double v = g_mtfDemand[i];
      if(v > 0.0 && v < px && v > best) best = v;   // nearest below
   }
   if(best > 0.0) roomATR = (px - best) / MathMax(atr, 1e-9);
   return best;
}

void ManageExits()
{
   int barsAvail = (int)ArraySize(Close);
   if(barsAvail <= (2*InpPivotLen + 5)) return;

   int    shiftNow = 1;
   double closeNow = Close[shiftNow];
   double atrNow   = GetATR(shiftNow);

   bool exitLong  = false;
   bool exitShort = false;
   string reasonL = "", reasonS = "";

   int longPos  = CountDirectionPositions(1);
   int shortPos = CountDirectionPositions(-1);

   // ---------- ROTATION-REVERSAL EXIT ----------
   // A lower-timeframe rotation that turns AGAINST the open book closes it. This is why
   // a "ROT^ (no shorts)" state must also flatten existing shorts, not just stop new ones.
   if(InpUseRotationExit)
   {
      if(shortPos > 0 && g_cascadeDir == 1  && g_cascadeDepth >= InpRotExitCount) { exitShort = true; reasonS = "ROT FLIP ^"; }
      if(longPos  > 0 && g_cascadeDir == -1 && g_cascadeDepth >= InpRotExitCount) { exitLong  = true; reasonL = "ROT FLIP v"; }
   }

   // ---- arm-before-die: a campaign must first get HEALTHY before life can kill it,
   //      and reset the arm/last-entry when the book is flat ----
   if(longPos == 0)  { g_longLifeArmed  = false; }
   else if(gLong.m_life  >= InpLifeArmLevel) g_longLifeArmed  = true;
   if(shortPos == 0) { g_shortLifeArmed = false; }
   else if(gShort.m_life >= InpLifeArmLevel) g_shortLifeArmed = true;

   // ---- grace window: never let life/chain cut within N bars of the last entry ----
   bool longGraceOK  = (g_barCount - g_longLastEntryBar)  >= InpLifeExitGraceBars;
   bool shortGraceOK = (g_barCount - g_shortLastEntryBar) >= InpLifeExitGraceBars;

   // ---- DESTINATION gate: only allow a life cut once the owner curve has EXPANDED
   //      and price is AT/APPROACHING the parent HTF supply/demand (owner-driven
   //      destination). Stops the early noise-cuts; the cut now lands at the target. ----
   double atrG    = (atrNow > 0.0 ? atrNow : GetATR(1));
   double travelL = (gLong.m_ownExtreme  > 0.0 && gLong.m_ownOrigin  > 0.0) ? (gLong.m_ownExtreme  - gLong.m_ownOrigin)  : 0.0;
   double travelS = (gShort.m_ownExtreme > 0.0 && gShort.m_ownOrigin > 0.0) ? (gShort.m_ownOrigin  - gShort.m_ownExtreme) : 0.0;
   bool   expandedLong  = (travelL >= InpExpandMinATR * atrG);
   bool   expandedShort = (travelS >= InpExpandMinATR * atrG);
   double roomL = 1e9, roomS = 1e9;
   int    destTFL = -1, destTFS = -1;
   double parSupL = DestinationSupply(closeNow, atrG, destTFL, roomL);   // owner-driven (escalates)
   double parDemS = DestinationDemand(closeNow, atrG, destTFS, roomS);
   bool   nearParentL = (parSupL > 0.0 && roomL <= InpParentApproachATR);
   bool   nearParentS = (parDemS > 0.0 && roomS <= InpParentApproachATR);
   bool   destLong  = (!InpUseParentExit) || (expandedLong  && nearParentL);
   bool   destShort = (!InpUseParentExit) || (expandedShort && nearParentS);

   // at the destination we exit on weakness (dead-cross OR life already below dead);
   // away from it we never let life cut — the stop / ARC / ladder manage instead.
   bool lifeWeakL = InpUseParentExit ? (gLong.LifeDeadCross()  || gLong.m_life  < InpLifeDeadExit) : gLong.LifeDeadCross();
   bool lifeWeakS = InpUseParentExit ? (gShort.LifeDeadCross() || gShort.m_life < InpLifeDeadExit) : gShort.LifeDeadCross();

   // ---------- LIFE-SCORE EXIT (armed + grace + expanded + at OWNER destination) ----------
   if(InpUseLifeExit && longPos > 0 && g_longLifeArmed && longGraceOK && destLong && lifeWeakL)
   { exitLong = true; reasonL = (InpUseParentExit ? ("LIFE@"+(destTFL>=0?g_mtfLbl[destTFL]:"DEST")) : "LIFE DEAD"); }
   if(InpUseLifeExit && shortPos > 0 && g_shortLifeArmed && shortGraceOK && destShort && lifeWeakS)
   { exitShort = true; reasonS = (InpUseParentExit ? ("LIFE@"+(destTFS>=0?g_mtfLbl[destTFS]:"DEST")) : "LIFE DEAD"); }

   // whole-chain collapse (optional, same gating)
   if(InpUseChainDecayExit && !exitLong  && longPos  > 0 && g_longLifeArmed  && longGraceOK && destLong
      && gLong.m_chainScope  == "WHOLE CHAIN decaying" && gLong.m_life  < InpLifeDeadExit)
   { exitLong = true;  reasonL = "CHAIN DECAY"; }
   if(InpUseChainDecayExit && !exitShort && shortPos > 0 && g_shortLifeArmed && shortGraceOK && destShort
      && gShort.m_chainScope == "WHOLE CHAIN decaying" && gShort.m_life < InpLifeDeadExit)
   { exitShort = true; reasonS = "CHAIN DECAY"; }

   // ---------- ARC EXHAUSTION + PHASE COLLAPSE + INSTITUTIONAL ----------
   bool arcExhaustLong  = (gL_active && gL_arc > 0.0 && closeNow >= (gL_arc - InpArcToleranceAtr * atrNow));
   bool arcExhaustShort = (gS_active && gS_arc > 0.0 && closeNow <= (gS_arc + InpArcToleranceAtr * atrNow));

   double instLevelL = (gL_inducPrice != 0.0 ? gL_inducPrice : gL_anchorHigh);
   double innerTopL  = (gL_inducHigh  > 0.0  ? gL_inducHigh  : instLevelL);
   double outerTopL  = innerTopL + InpOuterBandAtrMult * atrNow;
   double instLevelS = (gS_inducPrice != 0.0 ? gS_inducPrice : gS_anchorLow);
   double innerBotS  = (gS_inducLow   > 0.0  ? gS_inducLow   : instLevelS);
   double outerBotS  = innerBotS - InpOuterBandAtrMult * atrNow;

   if(gL_active && instLevelL > 0.0 && closeNow > outerTopL) gL_outerBreach = true;
   if(gS_active && instLevelS > 0.0 && closeNow < outerBotS) gS_outerBreach = true;

   bool phaseEndLong  = (gL_active && (gL_prevPhase == 3 || gL_prevPhase == 4) && gL_phase <= 1);
   bool phaseEndShort = (gS_active && (gS_prevPhase == 3 || gS_prevPhase == 4) && gS_phase <= 1);

   if(!exitLong && gL_active && arcExhaustLong && phaseEndLong)
   {
      bool hasInstL = (instLevelL > 0.0);
      if(!hasInstL || (gL_outerBreach && closeNow < innerTopL)) { exitLong = true; reasonL = "ARC/PHASE"; }
   }
   if(!exitShort && gS_active && arcExhaustShort && phaseEndShort)
   {
      bool hasInstS = (instLevelS > 0.0);
      if(!hasInstS || (gS_outerBreach && closeNow > innerBotS)) { exitShort = true; reasonS = "ARC/PHASE"; }
   }

   // ---------- MODE-INVALIDATION-AT-PEAK ----------
   if(!exitLong  && gL_modeInvalid && (gL_phaseAtInvalid == 3 || gL_phaseAtInvalid == 4))
   { exitLong = true;  reasonL = "INVALID@PEAK"; }
   if(!exitShort && gS_modeInvalid && (gS_phaseAtInvalid == 3 || gS_phaseAtInvalid == 4))
   { exitShort = true; reasonS = "INVALID@PEAK"; }

   if(exitLong)  { Print("SYM EXIT LONG  reason=",reasonL," life=",DoubleToString(gLong.m_life,0));  if(InpDebugLog){ Print("   MTF: ",DbgMTFMap()); Print("   CASCADE: ",DbgCascade()); } CloseDirection(1,  "SYM EXIT "+reasonL); }
   if(exitShort) { Print("SYM EXIT SHORT reason=",reasonS," life=",DoubleToString(gShort.m_life,0)); if(InpDebugLog){ Print("   MTF: ",DbgMTFMap()); Print("   CASCADE: ",DbgCascade()); } CloseDirection(-1, "SYM EXIT "+reasonS); }

   gL_modeInvalid = false;
   gS_modeInvalid = false;
}

//==================================================================
// 19. TRADING EXECUTION - MULTI-CAMPAIGN, ALL-TIMEFRAME, CURVE-GATED
//   P3/P4 fire from EVERY timeframe curve (per-TF structure engine).
//   Each entry must pass the CURVE-TREE gate: the curve tree's OWNER
//   node must not be opposed to the entry direction. Phases trigger;
//   the curve tree (ownership) confirms. LIFE IS NOT USED FOR ENTRIES
//   — life only manages exits. Counter-direction block: a side is held
//   back while the OPPOSITE book is net profitable (InpBlockCounterProfit).
//==================================================================
bool CurveAllowsLong()
{
   // ownership-only gate (no life): block longs only when a bearish curve owns the tree
   if(InpRequireCurveOwner && gLong.m_ownDir == -1) return false;
   return true;
}
bool CurveAllowsShort()
{
   if(InpRequireCurveOwner && gShort.m_ownDir == 1) return false;       // a bullish curve owns the short tree
   return true;
}

// FRACTAL entry zone. The rotated group reacts against the NEXT TF up (parent =
// g_cascadeDepth), but we accept the NEAREST in-direction zone from a low floor
// (InpZoneFromTFIndex) up to that parent. So at a reversal it takes the parent
// demand/supply, and inside a running trend it takes the shallow lower-TF pullback
// the price actually reaches — instead of starving while price runs from the far zone.
bool AtHigherTFZone(int dir, double px, double atr, int &tfOut, double &zoneOut)
{
   tfOut = -1; zoneOut = 0.0;
   int loZ = (InpZoneFromTFIndex < 0) ? 0 : (InpZoneFromTFIndex > 8 ? 8 : InpZoneFromTFIndex);
   int hiZ = g_cascadeDepth + InpZoneOpenAhead;   // up to the parent (next-up) zone
   if(hiZ > 8) hiZ = 8;
   if(hiZ < loZ) hiZ = loZ;
   double bestD = 1e9;
   for(int i = loZ; i <= hiZ; i++)
   {
      double z = (dir == 1) ? g_mtfDemand[i] : g_mtfSupply[i];
      if(z <= 0.0) continue;
      // SIDE-CORRECT: buy only a demand AT/BELOW price (support); sell only a supply
      // AT/ABOVE price (resistance). A small tolerance allows a shallow wick through.
      double sgn = (dir == 1) ? (px - z) : (z - px);   // >0 = correct side
      double sATR = sgn / MathMax(atr, 1e-9);
      if(sATR < -InpZoneSideTolATR) continue;          // zone is on the wrong side (broken)
      if(sATR > InpZoneApproachATR) continue;          // too far to be "at" the zone
      double prox = MathAbs(sATR);
      if(prox < bestD) { bestD = prox; tfOut = i; zoneOut = z; }
   }
   return (tfOut >= 0);
}

// ===== JOURNAL DEBUG (full engine state on each entry) =====
string DbgMTFMap()
{
   string s = "";
   for(int i = 0; i < 9; i++) s += g_mtfLbl[i] + (g_mtfDir[i]==1?"^":g_mtfDir[i]==-1?"v":"-") + " ";
   int b = MTFBias();
   s += " BIAS " + (b==1?"^":b==-1?"v":"-") + "(" + DoubleToString(MTFBiasScore(),0) + ")";
   return s;
}
string DbgCascade()
{
   string blk = "";
   for(int i = 0; i < g_cascadeDepth && i < 9; i++) blk += g_mtfLbl[i] + (i < g_cascadeDepth-1 ? ">" : "");
   return (g_cascadeDir==1?"^":g_cascadeDir==-1?"v":"-") + " depth " + IntegerToString(g_cascadeDepth) + "/9 ["
        + (blk==""?"-":blk) + "] next " + (g_cascadeNextTF>=0?g_mtfLbl[g_cascadeNextTF]:"full")
        + (g_cascadeClean?" clean":" mixed");
}
string DbgContext()
{
   return g_buyContext  ? ("BUY from "+(g_buyCtxTF>=0?g_mtfLbl[g_buyCtxTF]:"?")+" demand")
        : g_sellContext ? ("SELL from "+(g_sellCtxTF>=0?g_mtfLbl[g_sellCtxTF]:"?")+" supply")
        : "none";
}
string DbgTFPhase()
{
   string s = "";
   for(int i = 0; i < 9; i++)
   {
      int pl = g_mtfPhaseL[i], ps = g_mtfPhaseS[i];
      string c = g_mtfLbl[i] + ":";
      if(pl >= 3)      c += "L"+IntegerToString(pl);
      else if(ps >= 3) c += "S"+IntegerToString(ps);
      else if(pl > 0)  c += "l"+IntegerToString(pl);
      else if(ps > 0)  c += "s"+IntegerToString(ps);
      else             c += "-";
      s += c + " ";
   }
   return s;
}
string DbgRotAge()
{
   string s = "";
   for(int i = 0; i < 9; i++) s += g_mtfLbl[i] + " " + (g_mtfRotBar[i]>0?IntegerToString(g_barCount-g_mtfRotBar[i]):"-") + " ";
   return s;
}
string DbgDest(int dir)
{
   double atr = GetATR(1); int tf = -1; double room = 1e9;
   double z = (dir==1) ? DestinationSupply(Close[1], atr, tf, room) : DestinationDemand(Close[1], atr, tf, room);
   int own = OwnerTF(dir);
   return "owner " + (own>=0?g_mtfLbl[own]:"-") + " -> " + (tf>=0?g_mtfLbl[tf]:"-") + " "
        + (z>0.0?DoubleToString(z,2)+" ("+DoubleToString(room,1)+" ATR)":"-");
}
void LogEntry(int dir, int tf, double entry, double sl, double lots, double zone)
{
   if(!InpDebugLog) return;
   string side = (dir==1)?"BUY":"SELL";
   string zl   = (dir==1)?"demand":"supply";
   Print("=== SYM ENTRY ",side," ",g_mtfLbl[tf]," ",zl," @ ",DoubleToString(entry,2),
         "  SL ",DoubleToString(sl,2),"  lots ",DoubleToString(lots,2)," ===");
   Print("   MTF MAP : ",DbgMTFMap());
   Print("   CASCADE : ",DbgCascade());
   Print("   CONTEXT : ",DbgContext());
   Print("   ENTRYZN : [M1..",(g_cascadeDepth>=1?g_mtfLbl[g_cascadeDepth-1]:"-"),"] -> ",g_mtfLbl[tf]," ",zl," ",DoubleToString(zone,2));
   Print("   TF PHASE: ",DbgTFPhase());
   Print("   DEST    : ",DbgDest(dir));
   Print("   ROT age : ",DbgRotAge());
   Print("   PHYS    : comp ",DoubleToString(g_compIdx,0)," tighten ",DoubleToString(g_cmpTighten,0),
         " eff ",DoubleToString(g_eff,2)," disp ",DoubleToString(g_disp,2));
   Print("   CURVE   : Llife ",DoubleToString(gLong.m_life,0)," ownDir ",IntegerToString(gLong.m_ownDir),
         " | Slife ",DoubleToString(gShort.m_life,0)," ownDir ",IntegerToString(gShort.m_ownDir),
         " | conf L",IntegerToString(PhaseConfluence(1)),"/S",IntegerToString(PhaseConfluence(-1)));
   Print("   HUNT    : ",(g_huntMode==1?"BUY -> PARENT supply":g_huntMode==-1?"SELL -> PARENT demand":"-"),
         "  range [dem ",DoubleToString(g_flipDemand,2)," / sup ",DoubleToString(g_flipSupply,2),"]");
}

void ExecuteTrading()
{
   if((int)ArraySize(Close) < 3) return;
   if(!IsTradeTime()) return;
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * InpRiskPercent * 0.01;
   double close    = Close[1];
   double atr      = GetATR(1); if(atr <= 0.0) atr = 1e-6;

   // ONLY trade a CONFIRMED rotation, and ONLY in the rotation's direction.
   // (cascade bullish -> buys only; cascade bearish -> sells only.) This is why it
   // can no longer sell into a confirmed bullish rotation.
   int  cdir      = g_cascadeDir;
   bool confirmed = (g_cascadeDepth >= InpRotCount) && (!InpRequireCleanRotation || g_cascadeClean);
   if(cdir == 0 || !confirmed) return;

   bool blockLong  = InpBlockCounterProfit && (GetDirectionFloatingPnL(-1) > 0.0);
   bool blockShort = InpBlockCounterProfit && (GetDirectionFloatingPnL(1)  > 0.0);

   int tf = -1; double zone = 0.0;

   // BUY: confirmed bullish rotation + price AT a higher-TF DEMAND zone + P3/P4 timing
   if(cdir == 1 && !blockLong && g_longLastEntryBar != g_barCount && CurveAllowsLong()
      && (!InpUseHuntCycle || g_flipSupply <= 0.0 || (g_huntMode == 1 && close < g_flipSupply))  // buy cycle: room up to the PARENT supply
      && (!InpRequireMajorZoneOrigin || g_buyContext)
      && AtHigherTFZone(1, close, atr, tf, zone)
      && (!InpRequirePhaseTrigger || PhaseTrigger(1))
      && (!InpRequirePhaseConfluence || PhaseConfluence(1) >= InpMinPhaseConfluence))
   {
      double entry = close;
      double sl    = zone - InpZoneSLBufferATR * atr;   // structural stop below the demand
      double minD  = InpMinSLATR * atr;
      if(entry - sl < minD) sl = entry - minD;           // floor the stop distance
      if(sl > 0.0 && entry > sl)
      {
         double lots = ComputeLots(riskCash, entry, sl);
         lots = AdjustLotsForBasketCeiling(1, entry, sl, lots);
         if(lots > 0.0 && SendMarketOrder(+1, lots, sl, "SYM BUY "+g_mtfLbl[tf]+" demand"))
         { g_longLastEntryBar = g_barCount; LogEntry(1, tf, entry, sl, lots, zone); }
      }
   }

   // SELL: confirmed bearish rotation + price AT a higher-TF SUPPLY zone + P3/P4 timing
   if(cdir == -1 && !blockShort && g_shortLastEntryBar != g_barCount && CurveAllowsShort()
      && (!InpUseHuntCycle || g_flipDemand <= 0.0 || (g_huntMode == -1 && close > g_flipDemand)) // sell cycle: room down to the PARENT demand
      && (!InpRequireMajorZoneOrigin || g_sellContext)
      && AtHigherTFZone(-1, close, atr, tf, zone)
      && (!InpRequirePhaseTrigger || PhaseTrigger(-1))
      && (!InpRequirePhaseConfluence || PhaseConfluence(-1) >= InpMinPhaseConfluence))
   {
      double entry = close;
      double sl    = zone + InpZoneSLBufferATR * atr;   // structural stop above the supply
      double minD  = InpMinSLATR * atr;
      if(sl - entry < minD) sl = entry + minD;           // floor the stop distance
      if(sl > 0.0 && sl > entry)
      {
         double lots = ComputeLots(riskCash, entry, sl);
         lots = AdjustLotsForBasketCeiling(-1, entry, sl, lots);
         if(lots > 0.0 && SendMarketOrder(-1, lots, sl, "SYM SELL "+g_mtfLbl[tf]+" supply"))
         { g_shortLastEntryBar = g_barCount; LogEntry(-1, tf, entry, sl, lots, zone); }
      }
   }
}


//==================================================================
// 20. CAMPAIGN DRIVER - build per-direction context and update trees
//==================================================================
double CampaignMaturity(int phase)
{
   switch(phase)
   {
      case 1: return 20.0;
      case 2: return 45.0;
      case 3: return 70.0;
      case 4: return 92.0;
   }
   return 5.0;
}

double CampaignResidual(int phase)
{
   double mat   = CampaignMaturity(phase);
   double eDiss = Clamp(mat * 0.6 + g_decayScore * 0.4, 0.0, 100.0);
   return MathMax(0.0, g_expEnergy - eDiss);
}

void UpdateCampaigns()
{
   double atr = GetATR(1);

   CurveCtx cl;
   cl.dir          = 1;
   cl.active       = gL_active;
   cl.origin       = gL_anchorLow;
   cl.extreme      = (gL_cycleHigh != 0.0 ? gL_cycleHigh : High[1]);
   cl.close        = Close[1];
   cl.high         = High[1];
   cl.low          = Low[1];
   cl.atr          = atr;
   cl.compNow      = g_compIdx;
   cl.cmpTighten   = g_cmpTighten;
   cl.eRes         = CampaignResidual(gL_phase);
   cl.expEnergy    = g_expEnergy;
   cl.counterCHoCH = g_bearCHoCH;   // counter to a long owner
   cl.phaseCode    = gL_phase;
   cl.maturity     = CampaignMaturity(gL_phase);
   cl.bullImp      = g_bullImp;
   cl.bearImp      = g_bearImp;
   cl.barIndex     = g_barCount;
   gLong.Update(cl);

   CurveCtx cs;
   cs.dir          = -1;
   cs.active       = gS_active;
   cs.origin       = gS_anchorHigh;
   cs.extreme      = (gS_cycleLow != 0.0 ? gS_cycleLow : Low[1]);
   cs.close        = Close[1];
   cs.high         = High[1];
   cs.low          = Low[1];
   cs.atr          = atr;
   cs.compNow      = g_compIdx;
   cs.cmpTighten   = g_cmpTighten;
   cs.eRes         = CampaignResidual(gS_phase);
   cs.expEnergy    = g_expEnergy;
   cs.counterCHoCH = g_bullCHoCH;   // counter to a short owner
   cs.phaseCode    = gS_phase;
   cs.maturity     = CampaignMaturity(gS_phase);
   cs.bullImp      = g_bullImp;
   cs.bearImp      = g_bearImp;
   cs.barIndex     = g_barCount;
   gShort.Update(cs);
}

//==================================================================
// 21. DASHBOARD (Comment) - the user has no chart panels otherwise
//==================================================================
string AliveVerdict(CCampaign &c, int dir)
{
   string counter = (dir == 1) ? "v SHORT" : "^ LONG";
   if(c.m_progressing && c.m_life >= 45.0) return "ALIVE - attacking";
   if(c.m_life >= InpLifeReviveLevel)      return "ALIVE - hold";
   if(c.m_life <= InpLifeDeadExit)         return "DEAD - flip " + counter;
   return "WEAKENING - manage";
}

void UpdateDashboard()
{
   string nl = "\n";
   string s = "SYMPHONY v4  -  MULTI-CAMPAIGN" + nl;
   s += "------------------------------------------" + nl;

   int lpos = CountDirectionPositions(1);
   int spos = CountDirectionPositions(-1);
   double lpnl = GetDirectionFloatingPnL(1);
   double spnl = GetDirectionFloatingPnL(-1);

   s += "LONG   " + (gL_active ? "act" : "off")
      + "  life " + DoubleToString(gLong.m_life,0)
      + "  cp:" + gLong.m_cpState
      + "  own:" + NodeStateLabel(gLong.m_ownState)
      + "  tree d" + IntegerToString(gLong.m_treeDepth) + "/" + IntegerToString(gLong.m_budgetDepth)
      + "  pos " + IntegerToString(lpos) + " (" + DoubleToString(lpnl,0) + ")" + nl;
   s += "       narr:" + gLong.m_narrState + "(" + DoubleToString(gLong.m_narrative,0) + ")"
      + "  chain:" + gLong.m_chainScope
      + "  align " + IntegerToString(MTF_Align(1)) + "/6"
      + "  -> " + AliveVerdict(gLong, 1) + nl;

   s += "SHORT  " + (gS_active ? "act" : "off")
      + "  life " + DoubleToString(gShort.m_life,0)
      + "  cp:" + gShort.m_cpState
      + "  own:" + NodeStateLabel(gShort.m_ownState)
      + "  tree d" + IntegerToString(gShort.m_treeDepth) + "/" + IntegerToString(gShort.m_budgetDepth)
      + "  pos " + IntegerToString(spos) + " (" + DoubleToString(spnl,0) + ")" + nl;
   s += "       narr:" + gShort.m_narrState + "(" + DoubleToString(gShort.m_narrative,0) + ")"
      + "  chain:" + gShort.m_chainScope
      + "  align " + IntegerToString(MTF_Align(-1)) + "/6"
      + "  -> " + AliveVerdict(gShort, -1) + nl;

   s += "------------------------------------------" + nl;
   int dbias = MTFBias();
   s += "MTF MAP:  " + MTF_StoryLine()
      + "  BIAS " + (dbias == 1 ? "^LONG-only" : dbias == -1 ? "vSHORT-only" : "-flat")
      + " (" + DoubleToString(MTFBiasScore(),0) + ")"
      + (LowerTFRotation(1) ? "  ROT^ (no shorts)" : LowerTFRotation(-1) ? "  ROTv (no longs)" : "")
      + "  conf L" + IntegerToString(PhaseConfluence(1)) + "/S" + IntegerToString(PhaseConfluence(-1))
      + nl;
   // rotation cascade: how far the rotation has climbed from the bottom + what it pressures next
   string cblk = "";
   for(int ci = 0; ci < g_cascadeDepth && ci < 9; ci++) cblk += g_mtfLbl[ci] + (ci < g_cascadeDepth-1 ? ">" : "");
   s += "CASCADE: " + (g_cascadeDir==1?"^":g_cascadeDir==-1?"v":"-")
      + " depth " + IntegerToString(g_cascadeDepth) + "/8 ["
      + (cblk=="" ? "-" : cblk) + "] next "
      + (g_cascadeNextTF>=0 ? g_mtfLbl[g_cascadeNextTF] : "full")
      + (g_cascadeClean ? " clean" : " mixed") + nl;
   s += "CONTEXT: " + (g_buyContext ? ("BUY from "+(g_buyCtxTF>=0?g_mtfLbl[g_buyCtxTF]:"?")+" demand")
                     : g_sellContext ? ("SELL from "+(g_sellCtxTF>=0?g_mtfLbl[g_sellCtxTF]:"?")+" supply")
                     : "none (await major-zone reversal)") + nl;
   s += "HUNT: " + (g_huntMode==1?"BUY -> PARENT supply":g_huntMode==-1?"SELL -> PARENT demand":"-")
      + "  range [dem " + DoubleToString(g_flipDemand,2) + " / sup " + DoubleToString(g_flipSupply,2) + "]" + nl;
   // fractal entry target: the rotated group reacts against this NEXT-up TF zone
   int pTF = g_cascadeDepth; if(pTF < 1) pTF = 1; if(pTF > 8) pTF = 8;
   double pzt = (g_cascadeDir==1) ? g_mtfDemand[pTF] : (g_cascadeDir==-1) ? g_mtfSupply[pTF] : 0.0;
   double prm = (pzt>0.0) ? MathAbs(Close[1]-pzt)/MathMax(GetATR(1),1e-9) : 0.0;
   s += "ENTRY ZONE: [M1.." + (g_cascadeDepth>=1?g_mtfLbl[g_cascadeDepth-1]:"-") + "] -> " + g_mtfLbl[pTF] + " "
      + (g_cascadeDir==1?"demand":g_cascadeDir==-1?"supply":"-") + " "
      + (pzt>0.0? DoubleToString(pzt,2)+" ("+DoubleToString(prm,1)+" ATR)":"-") + nl;
   string rage = "ROT age: ";
   for(int ri = 0; ri < 9; ri++)
      rage += g_mtfLbl[ri] + " " + (g_mtfRotBar[ri] > 0 ? IntegerToString(g_barCount - g_mtfRotBar[ri]) : "-") + "  ";
   s += rage + nl;
   string tfp = "";
   for(int i = 0; i < 9; i++)
   {
      int pl = g_mtfPhaseL[i], ps = g_mtfPhaseS[i];
      string cell = g_mtfLbl[i] + ":";
      if(pl >= 3)      cell += "L" + IntegerToString(pl);   // tradeable long  (P3/P4)
      else if(ps >= 3) cell += "S" + IntegerToString(ps);   // tradeable short (P3/P4)
      else if(pl > 0)  cell += "l" + IntegerToString(pl);   // forming long
      else if(ps > 0)  cell += "s" + IntegerToString(ps);   // forming short
      else             cell += "-";
      tfp += cell + " ";
   }
   s += "TF PHASE: " + tfp + nl;
   s += "GATE: Lcurve " + (CurveAllowsLong()? "OPEN":"shut")
      + "  Scurve " + (CurveAllowsShort()? "OPEN":"shut") + nl;
   double dRoomL = 1e9, dRoomS = 1e9, dAtr = GetATR(1);
   int    dTFL = -1, dTFS = -1;
   double dSupL = DestinationSupply(Close[1], dAtr, dTFL, dRoomL);
   double dDemS = DestinationDemand(Close[1], dAtr, dTFS, dRoomS);
   int    ownL = OwnerTF(1), ownS = OwnerTF(-1);
   double dTravL = (gLong.m_ownExtreme  > 0.0 && gLong.m_ownOrigin  > 0.0) ? (gLong.m_ownExtreme - gLong.m_ownOrigin)  / MathMax(dAtr,1e-9) : 0.0;
   double dTravS = (gShort.m_ownExtreme > 0.0 && gShort.m_ownOrigin > 0.0) ? (gShort.m_ownOrigin - gShort.m_ownExtreme) / MathMax(dAtr,1e-9) : 0.0;
   s += "DEST(owner): L own " + (ownL>=0?g_mtfLbl[ownL]:"-")
      + " -> " + (dTFL>=0?g_mtfLbl[dTFL]:"-") + " " + (dSupL>0.0? DoubleToString(dSupL,2)+" ("+DoubleToString(dRoomL,1)+" ATR)":"-")
      + " exp " + DoubleToString(dTravL,1) + nl;
   s += "DEST(owner): S own " + (ownS>=0?g_mtfLbl[ownS]:"-")
      + " -> " + (dTFS>=0?g_mtfLbl[dTFS]:"-") + " " + (dDemS>0.0? DoubleToString(dDemS,2)+" ("+DoubleToString(dRoomS,1)+" ATR)":"-")
      + " exp " + DoubleToString(dTravS,1) + nl;
   // per-TF supply/demand distance in ATR (up = +, down = -) so the interaction is visible
   double pz = Close[1];
   string zs = "ZONES(ATR): ";
   for(int zi = 0; zi < 9; zi++)
   {
      string su = (g_mtfSupply[zi] > 0.0) ? DoubleToString((g_mtfSupply[zi]-pz)/MathMax(dAtr,1e-9),1) : "-";
      string de = (g_mtfDemand[zi] > 0.0) ? DoubleToString((g_mtfDemand[zi]-pz)/MathMax(dAtr,1e-9),1) : "-";
      zs += g_mtfLbl[zi] + " S" + su + "/D" + de + "  ";
   }
   s += zs + nl;
   s += "PHYS: comp " + DoubleToString(g_compIdx,0)
      + " (tighten " + DoubleToString(g_cmpTighten,0) + ")"
      + "  eff " + DoubleToString(g_eff,2)
      + "  disp " + DoubleToString(g_disp,2)
      + "  expE " + DoubleToString(g_expEnergy,0) + nl;

   Comment(s);
}

//==================================================================
// 22. STANDARD CALLBACKS
//==================================================================
int OnInit()
{
   // structure / pivots
   g_lastPivotPrice = 0.0; g_lastPivotShift = -1; g_lastPivotDir = 0;
   g_prevPivotPrice = 0.0; g_prevPivotShift = -1; g_prevPivotDir = 0;
   g_curSH = g_prSH = g_curSL = g_prSL = 0.0;
   g_bullCHoCH = g_bearCHoCH = g_bullBOS = g_bearBOS = false;
   g_lastBarTime = 0;

   // physics
   g_physInit = false;
   g_vel = g_velPrev = g_acc = g_accPrev = g_conv = g_convSmooth = 0.0;
   g_eff = g_disp = g_compIdx = 0.0;
   ArrayInitialize(g_compHist, 0.0); g_compHistFill = 0; g_cmpTighten = 0.0;
   g_convScore = g_velScore = g_decayScore = g_expEnergy = 0.0;
   g_bullImp = g_bearImp = g_vd70 = false;
   g_barCount = 0;

   // long campaign
   gL_active = false; gL_anchorHigh = gL_anchorLow = 0.0;
   gL_anchorHighShift = gL_anchorLowShift = -1;
   gL_phase = gL_prevPhase = 0; gL_preConvSeen = false;
   gL_inducPrice = gL_inducLow = gL_inducHigh = 0.0;
   gL_outerBreach = false; gL_cycleHigh = 0.0; gL_arc = 0.0;
   gL_modeInvalid = false; gL_phaseAtInvalid = 0; gL_lastTradeTime = 0;

   // short campaign
   gS_active = false; gS_anchorHigh = gS_anchorLow = 0.0;
   gS_anchorHighShift = gS_anchorLowShift = -1;
   gS_phase = gS_prevPhase = 0; gS_preConvSeen = false;
   gS_inducPrice = gS_inducLow = gS_inducHigh = 0.0;
   gS_outerBreach = false; gS_cycleLow = 0.0; gS_arc = 0.0;
   gS_modeInvalid = false; gS_phaseAtInvalid = 0; gS_lastTradeTime = 0;

   // ladder / stops
   g_longRungs = g_shortRungs = 0;
   g_longBEActive = g_shortBEActive = false;
   g_longTrailActive = g_shortTrailActive = false;
   g_longLastEntryBar = g_shortLastEntryBar = -100000;
   g_longLifeArmed = g_shortLifeArmed = false;

   // curve campaigns
   gLong.Init(1);
   gShort.Init(-1);
   g_prevCascadeDir = 0; g_sellContext = false; g_buyContext = false; g_sellCtxTF = -1; g_buyCtxTF = -1;
   g_huntMode = 0; g_flip = 0.0; g_flipSupply = 0.0; g_flipDemand = 0.0;

   // per-timeframe structure engines + ATR handles
   for(int i = 0; i < 9; i++)
   {
      g_mtfATR[i]    = iATR(_Symbol, g_mtfTF[i], InpATRLen);
      g_mtfDir[i]    = 0; g_mtfOrigin[i] = 0.0; g_mtfExtreme[i] = 0.0;
      g_mtfSupply[i] = 0.0; g_mtfDemand[i] = 0.0;
      g_mtfPendDir[i] = 0; g_mtfPendCount[i] = 0;
      g_mtfRotBar[i] = 0; g_mtfPrevDir[i] = 0;
      g_mtfPhaseL[i] = 0; g_mtfPhaseS[i] = 0;
      ZeroMemory(gTFEng[i]);
      gTFEng[i].lastPivotDir = 0; gTFEng[i].prevPivotDir = 0;
   }

   if(!RefreshSeries()) return INIT_FAILED;

   Print("SYMPHONY v4 multi-campaign loaded. LifeDeadExit=", InpLifeDeadExit,
         " MaxBasketRiskPct=", InpMaxBasketRiskPct);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
{
   if(!RefreshSeries()) return;
   if(!IsNewBar())      return;

   g_barCount++;

   // 1. physics foundation
   UpdatePhysics();

   // 2. structure + per-direction phase (multi-campaign)
   UpdateStructure();

   // 3. multi-timeframe curve map (structural direction) + per-TF P3/P4 engines
   // 3. multi-timeframe curve map (structure: dir + zones + phase, one coherent read) + cascade
   UpdateMTFMap();
   ComputeCascade();
   UpdateZoneContext();
   ComputeFlip();
   UpdateHuntCycle();

   // 4. recursive curve trees + life + lineage + chain (per campaign)
   UpdateCampaigns();

   // 5. ARC targets (per direction)
   UpdateARC();

   // 6. stop protection + profit ladder
   RunStopProtection();
   RunProfitLadder();

   // 7. exits managed by life score (+ ARC/phase + invalidation)
   ManageExits();

   // 8. open new entries - both campaigns independent, no counter block
   ExecuteTrading();

   // 9. dashboard
   if(InpShowDashboard) UpdateDashboard();
}
//+------------------------------------------------------------------+
