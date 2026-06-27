//+------------------------------------------------------------------+
//| snXperFX.mq5                                                     |
//| snXper FX Trading System — Master Specification v1.0 build       |
//|                                                                  |
//| PHASE A — FOUNDATIONS (this file):                               |
//|   1. Daily-Cycle / Session state machine (Sydney->Asia->         |
//|      Frankfurt->London->NY cross; day-type from Sydney raid)     |
//|   2. Liquidity Pool Tracker (session H/L, EQH/EQL, round#,        |
//|      prev-day H/L; raid detection + lot quantification)          |
//|   3. Structural Cascade (Monthly->M1) with BOS strength          |
//|      (impulsive vs wick-only) + CHoCH detection                  |
//|                                                                  |
//| Phase B (POI 4-criteria + flip zone + inducement + 3-shift OFB   |
//| + FU candle), Phase C (checklist + execution + risk guards +     |
//| audit CSV) and Phase D (correlation) bolt on top of this.        |
//|                                                                  |
//| MT5 — reads only; no orders placed in Phase A.                  |
//+------------------------------------------------------------------+
#property strict

//==================================================================
// ENUMERATIONS (spec section 2)
//==================================================================
enum ENUM_BIAS { BIAS_BEARISH = -1, BIAS_NEUTRAL = 0, BIAS_BULLISH = 1 };

enum ENUM_STRUCTURAL_PHASE {
   PHASE_NONE   = 0,
   PHASE_1      = 1,   // corrective pullback to external POI
   PRE_PHASE_2A = 2,   // arriving at POI; internal liquidity building
   PHASE_2      = 3,   // institutional interaction; FU candle
   PHASE_3      = 4,   // 3-shift OFB complete; entry zone
   PHASE_4      = 5,   // expansion impulse underway
   PHASE_5      = 6    // new external structural landmark created
};

enum ENUM_DAILY_CYCLE_STATE {
   DC_SYDNEY_RANGE_BUILDING = 0,
   DC_ALGORITHM_RAID        = 1,
   DC_ASIA_RANGE_FORMING    = 2,
   DC_ASIA_EXPANSION        = 3,
   DC_FRANKFURT_RAID        = 4,
   DC_LONDON_OPEN           = 5,
   DC_NY_CROSS_RAID         = 6,
   DC_EXPANSION             = 7,
   DC_LATE_SESSION          = 8,
   DC_DAILY_CLOSE           = 9
};

enum ENUM_DAILY_CYCLE_TYPE { DCT_BEARISH = -1, DCT_UNDETERMINED = 0, DCT_BULLISH = 1 };
enum ENUM_SESSION_MODEL    { SM_TWO_SIDED = 0, SM_ONE_SIDED = 1 };
enum ENUM_BOS_STRENGTH     { BOS_NONE = -1, BOS_IMPULSIVE = 0, BOS_WICK_ONLY = 1 };

enum ENUM_LIQUIDITY_TYPE {
   LIQ_EQUAL_HIGHS = 0, LIQ_EQUAL_LOWS = 1,
   LIQ_ASIA_HIGH = 4, LIQ_ASIA_LOW = 5,
   LIQ_SYDNEY_HIGH = 6, LIQ_SYDNEY_LOW = 7,
   LIQ_LONDON_HIGH = 8, LIQ_LONDON_LOW = 9,
   LIQ_PREV_DAY_HIGH = 10, LIQ_PREV_DAY_LOW = 11,
   LIQ_ROUND_NUMBER = 14
};

//==================================================================
// TIMEFRAME LADDER (spec indexing: 0=Monthly ... 10=M1)
//==================================================================
#define TF_COUNT 11
ENUM_TIMEFRAMES g_tf[TF_COUNT] = {
   PERIOD_MN1, PERIOD_W1, PERIOD_D1, PERIOD_H8, PERIOD_H4, PERIOD_H1,
   PERIOD_M30, PERIOD_M15, PERIOD_M5, PERIOD_M2, PERIOD_M1
};
string g_tfLbl[TF_COUNT] = { "MN","W1","D1","H8","H4","H1","M30","M15","M5","M2","M1" };
#define TF_IDX_H4 4
#define TF_IDX_H1 5

//==================================================================
// INPUTS
//==================================================================
input group "═══ Instrument ═══"
input bool   InpAutoGold        = true;    // Auto-detect Gold from symbol (XAU)
input bool   InpIsGoldManual    = true;    // If auto off: treat as Gold
input double InpRoundStep       = 10.0;    // Round-number step (Gold=10, FX uses pip grid)

input group "═══ Structure ═══"
input int    InpPivotLen        = 5;       // Swing pivot half-width
input int    InpStructLookback  = 240;     // Bars scanned per TF for swings
input double InpBodyImpulseFrac = 0.5;     // Body/range >= this on the breaking candle = impulsive BOS

input group "═══ Liquidity ═══"
input double InpEqualTolPips    = 2.0;     // EQH/EQL tolerance (pips)
input int    InpEqualScanPivots = 8;       // How many recent pivots to scan for equals
input int    InpMaxLiqPools     = 64;      // Cap on tracked pools

input group "═══ Session ═══"
input int    InpGoldOpenGMT     = 23;      // Gold daily open hour (GMT)
input int    InpFXOpenGMT       = 22;      // FX daily rollover hour (GMT)

input group "═══ Display ═══"
input bool   InpShowDashboard   = true;    // Print live state dashboard

//==================================================================
// DATA STRUCTURES
//==================================================================
struct TFState {
   ENUM_BIAS             bias;
   double                externalHigh;
   double                externalLow;
   double                lastBOSPrice;
   ENUM_BOS_STRENGTH     bosStrength;
   int                   bosDir;          // +1 bull BOS, -1 bear BOS, 0 none (this scan)
   bool                  chochDetected;
   double                chochPrice;
   ENUM_STRUCTURAL_PHASE currentPhase;    // Phase B will populate fully
};

struct LiquidityPool {
   double              price;
   ENUM_LIQUIDITY_TYPE type;
   double              pips;            // displacement / reaction size in pips
   double              estimatedLots;   // pips * 100000
   bool                isGrabbed;
   datetime            raidTime;
   string              label;
};

//==================================================================
// GLOBAL STATE
//==================================================================
TFState        g_tfState[TF_COUNT];
LiquidityPool  g_liq[];

// session / daily cycle
ENUM_DAILY_CYCLE_STATE g_cycleState     = DC_SYDNEY_RANGE_BUILDING;
ENUM_DAILY_CYCLE_STATE g_prevCycleState = DC_DAILY_CLOSE;
ENUM_DAILY_CYCLE_TYPE  g_dayType        = DCT_UNDETERMINED;
ENUM_SESSION_MODEL     g_sessionModel   = SM_TWO_SIDED;

double   g_sydneyHigh = 0.0, g_sydneyLow = 0.0;
double   g_asiaHigh   = 0.0, g_asiaLow   = 0.0;
double   g_londonHigh = 0.0, g_londonLow = 0.0;
double   g_dayHigh    = 0.0, g_dayLow    = 0.0;
double   g_prevDayHigh= 0.0, g_prevDayLow= 0.0;
bool     g_sydneyHighRaided = false, g_sydneyLowRaided = false;
bool     g_isGold     = true;

datetime g_lastBarTime = 0;

// series buffers (chart TF)
double   gClose[], gHigh[], gLow[], gOpen[];
datetime gTime[];

//==================================================================
// HELPERS
//==================================================================
bool RefreshSeries(int need = 600)
{
   if(need < 300) need = 300;
   ArraySetAsSeries(gClose, true); ArraySetAsSeries(gHigh, true);
   ArraySetAsSeries(gLow,   true); ArraySetAsSeries(gOpen, true);
   ArraySetAsSeries(gTime,  true);
   int c1 = CopyClose(_Symbol, _Period, 0, need, gClose);
   int c2 = CopyHigh (_Symbol, _Period, 0, need, gHigh);
   int c3 = CopyLow  (_Symbol, _Period, 0, need, gLow);
   int c4 = CopyOpen (_Symbol, _Period, 0, need, gOpen);
   int c5 = CopyTime (_Symbol, _Period, 0, need, gTime);
   return (c1 > 0 && c2 > 0 && c3 > 0 && c4 > 0 && c5 > 0);
}

bool IsNewBar()
{
   datetime t = (ArraySize(gTime) > 0) ? gTime[0] : 0;
   if(t != g_lastBarTime) { g_lastBarTime = t; return true; }
   return false;
}

double PipSize()
{
   double pt = _Point; int d = _Digits;
   if(d == 3 || d == 5) return pt * 10.0;
   if(d == 2)           return pt * 10.0;   // XAUUSD 2-digit -> 0.1 pip
   return pt;
}

bool SymbolIsGold()
{
   if(!InpAutoGold) return InpIsGoldManual;
   return (StringFind(_Symbol, "XAU") >= 0 || StringFind(_Symbol, "GOLD") >= 0);
}

int GMTHour()
{
   MqlDateTime g; TimeGMT(g);
   return g.hour;
}

// per-TF pivot tests on closed bars
bool PivotHighTF(ENUM_TIMEFRAMES tf, int c, int P)
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
bool PivotLowTF(ENUM_TIMEFRAMES tf, int c, int P)
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

//==================================================================
// MODULE 1 — DAILY CYCLE / SESSION STATE MACHINE
//==================================================================
ENUM_DAILY_CYCLE_STATE GetCycleState()
{
   int h = GMTHour();
   if(g_isGold && h == 23)      return DC_SYDNEY_RANGE_BUILDING;
   if(h == 0)                   return DC_ALGORITHM_RAID;
   if(h >= 1  && h < 3)         return DC_ASIA_RANGE_FORMING;
   if(h >= 3  && h < 5)         return DC_ASIA_EXPANSION;
   if(h >= 5  && h < 7)         return DC_FRANKFURT_RAID;
   if(h >= 7  && h < 12)        return DC_LONDON_OPEN;
   if(h >= 12 && h < 13)        return DC_NY_CROSS_RAID;
   if(h >= 13 && h < 17)        return DC_EXPANSION;
   if(h >= 17 && h < 21)        return DC_LATE_SESSION;
   if(h >= 21)                  return DC_DAILY_CLOSE;
   return DC_SYDNEY_RANGE_BUILDING;
}

string CycleStateLabel(ENUM_DAILY_CYCLE_STATE s)
{
   switch(s)
   {
      case DC_SYDNEY_RANGE_BUILDING: return "SYDNEY_RANGE_BUILDING";
      case DC_ALGORITHM_RAID:        return "ALGORITHM_RAID";
      case DC_ASIA_RANGE_FORMING:    return "ASIA_RANGE_FORMING";
      case DC_ASIA_EXPANSION:        return "ASIA_EXPANSION";
      case DC_FRANKFURT_RAID:        return "FRANKFURT_RAID";
      case DC_LONDON_OPEN:           return "LONDON_OPEN";
      case DC_NY_CROSS_RAID:         return "NY_CROSS_RAID";
      case DC_EXPANSION:             return "EXPANSION";
      case DC_LATE_SESSION:          return "LATE_SESSION";
      case DC_DAILY_CLOSE:           return "DAILY_CLOSE";
   }
   return "-";
}

void ResetDailyCycle()
{
   // carry the just-finished day's extremes into prev-day pools
   if(g_dayHigh > 0.0) g_prevDayHigh = g_dayHigh;
   if(g_dayLow  > 0.0) g_prevDayLow  = g_dayLow;
   g_sydneyHigh = 0.0; g_sydneyLow = 0.0;
   g_asiaHigh   = 0.0; g_asiaLow   = 0.0;
   g_londonHigh = 0.0; g_londonLow = 0.0;
   g_dayHigh    = 0.0; g_dayLow    = 0.0;
   g_sydneyHighRaided = false; g_sydneyLowRaided = false;
   g_dayType      = DCT_UNDETERMINED;
   g_sessionModel = SM_TWO_SIDED;
}

void UpdateSession()
{
   g_cycleState = GetCycleState();

   // new trading day begins when we (re)enter the Sydney building window
   if(g_cycleState == DC_SYDNEY_RANGE_BUILDING && g_prevCycleState != DC_SYDNEY_RANGE_BUILDING)
      ResetDailyCycle();
   g_prevCycleState = g_cycleState;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;

   // running day extremes
   if(g_dayHigh == 0.0 || bid > g_dayHigh) g_dayHigh = bid;
   if(g_dayLow  == 0.0 || bid < g_dayLow)  g_dayLow  = bid;

   // session H/L stamping
   if(g_cycleState == DC_SYDNEY_RANGE_BUILDING)
   {
      if(g_sydneyHigh == 0.0 || bid > g_sydneyHigh) g_sydneyHigh = bid;
      if(g_sydneyLow  == 0.0 || bid < g_sydneyLow)  g_sydneyLow  = bid;
   }
   if(g_cycleState == DC_ASIA_RANGE_FORMING || g_cycleState == DC_ASIA_EXPANSION)
   {
      if(g_asiaHigh == 0.0 || bid > g_asiaHigh) g_asiaHigh = bid;
      if(g_asiaLow  == 0.0 || bid < g_asiaLow)  g_asiaLow  = bid;
   }
   if(g_cycleState == DC_LONDON_OPEN)
   {
      if(g_londonHigh == 0.0 || bid > g_londonHigh) g_londonHigh = bid;
      if(g_londonLow  == 0.0 || bid < g_londonLow)  g_londonLow  = bid;
   }

   // DAY TYPE — algorithm raid (00:00–01:00) liquidates ONE side of Sydney range
   if(g_cycleState == DC_ALGORITHM_RAID && g_sydneyHigh > 0.0 && g_sydneyLow > 0.0)
   {
      if(bid < g_sydneyLow)  g_sydneyLowRaided  = true;
      if(bid > g_sydneyHigh) g_sydneyHighRaided = true;
      if(g_dayType == DCT_UNDETERMINED)
      {
         if(g_sydneyLowRaided)       g_dayType = DCT_BULLISH;   // low raided -> bullish day
         else if(g_sydneyHighRaided) g_dayType = DCT_BEARISH;   // high raided -> bearish day
      }
      // both sides raided -> two-sided model; only one -> one-sided (set later)
      if(g_sydneyLowRaided && g_sydneyHighRaided) g_sessionModel = SM_TWO_SIDED;
   }
}

bool IsDeadZone()      // no new entries (spec E5)
{
   return (g_cycleState == DC_SYDNEY_RANGE_BUILDING || g_cycleState == DC_ALGORITHM_RAID);
}
bool IsNearClose()     // gold spread-widening / hard-TP window (spec)
{
   return (g_cycleState == DC_DAILY_CLOSE);
}

//==================================================================
// MODULE 2 — LIQUIDITY POOL TRACKER
//==================================================================
void ClearLiq() { ArrayResize(g_liq, 0); }

void AddPool(double price, ENUM_LIQUIDITY_TYPE type, string label)
{
   if(price <= 0.0) return;
   int n = ArraySize(g_liq);
   if(n >= InpMaxLiqPools) return;
   // de-dup near-identical levels
   double tol = PipSize() * InpEqualTolPips;
   for(int i = 0; i < n; i++)
      if(g_liq[i].type == type && MathAbs(g_liq[i].price - price) <= tol) return;
   ArrayResize(g_liq, n + 1);
   g_liq[n].price         = price;
   g_liq[n].type          = type;
   g_liq[n].isGrabbed     = false;
   g_liq[n].raidTime      = 0;
   g_liq[n].label         = label;
   // quantification: reaction size proxy = distance from current price, in pips
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pipsAway = MathAbs(price - bid) / MathMax(PipSize(), 1e-9);
   g_liq[n].pips          = pipsAway;
   g_liq[n].estimatedLots = pipsAway * 100000.0;
}

// scan recent chart-TF swing pivots for equal highs / equal lows
void ScanEqualHighsLows()
{
   int P = InpPivotLen;
   double tol = PipSize() * InpEqualTolPips;
   double highs[]; double lows[];
   int fh = 0, fl = 0;
   int maxBars = ArraySize(gHigh);
   for(int c = P + 1; c < maxBars - P && (fh < InpEqualScanPivots || fl < InpEqualScanPivots); c++)
   {
      // local pivot on chart series
      bool ph = true, pl = true;
      for(int k = 1; k <= P; k++)
      {
         if(gHigh[c] <= gHigh[c+k] || gHigh[c] <= gHigh[c-k]) ph = false;
         if(gLow[c]  >= gLow[c+k]  || gLow[c]  >= gLow[c-k])  pl = false;
      }
      if(ph && fh < InpEqualScanPivots) { int n = ArraySize(highs); ArrayResize(highs, n+1); highs[n] = gHigh[c]; fh++; }
      if(pl && fl < InpEqualScanPivots) { int n = ArraySize(lows);  ArrayResize(lows,  n+1); lows[n]  = gLow[c];  fl++; }
   }
   // equal highs
   for(int i = 0; i < ArraySize(highs); i++)
      for(int j = i + 1; j < ArraySize(highs); j++)
         if(MathAbs(highs[i] - highs[j]) <= tol)
            { AddPool((highs[i] + highs[j]) * 0.5, LIQ_EQUAL_HIGHS, "EQH"); break; }
   // equal lows
   for(int i = 0; i < ArraySize(lows); i++)
      for(int j = i + 1; j < ArraySize(lows); j++)
         if(MathAbs(lows[i] - lows[j]) <= tol)
            { AddPool((lows[i] + lows[j]) * 0.5, LIQ_EQUAL_LOWS, "EQL"); break; }
}

void ScanRoundNumbers()
{
   if(InpRoundStep <= 0.0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;
   double below = MathFloor(bid / InpRoundStep) * InpRoundStep;
   double above = below + InpRoundStep;
   AddPool(below, LIQ_ROUND_NUMBER, "RN" + DoubleToString(below, 0));
   AddPool(above, LIQ_ROUND_NUMBER, "RN" + DoubleToString(above, 0));
}

void RebuildLiquidityMap()
{
   ClearLiq();
   // session pools
   AddPool(g_sydneyHigh, LIQ_SYDNEY_HIGH, "SydH");
   AddPool(g_sydneyLow,  LIQ_SYDNEY_LOW,  "SydL");
   AddPool(g_asiaHigh,   LIQ_ASIA_HIGH,   "AsiaH");
   AddPool(g_asiaLow,    LIQ_ASIA_LOW,    "AsiaL");
   AddPool(g_londonHigh, LIQ_LONDON_HIGH, "LonH");
   AddPool(g_londonLow,  LIQ_LONDON_LOW,  "LonL");
   AddPool(g_prevDayHigh,LIQ_PREV_DAY_HIGH,"PDH");
   AddPool(g_prevDayLow, LIQ_PREV_DAY_LOW, "PDL");
   ScanEqualHighsLows();
   ScanRoundNumbers();
}

// flag pools as raided when price trades beyond them (run on tick)
void UpdateLiquidityRaids()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0) return;
   double tol = PipSize() * 0.5;
   for(int i = 0; i < ArraySize(g_liq); i++)
   {
      if(g_liq[i].isGrabbed) continue;
      bool isHigh = (g_liq[i].type == LIQ_EQUAL_HIGHS || g_liq[i].type == LIQ_SYDNEY_HIGH ||
                     g_liq[i].type == LIQ_ASIA_HIGH   || g_liq[i].type == LIQ_LONDON_HIGH ||
                     g_liq[i].type == LIQ_PREV_DAY_HIGH);
      bool isLow  = (g_liq[i].type == LIQ_EQUAL_LOWS  || g_liq[i].type == LIQ_SYDNEY_LOW  ||
                     g_liq[i].type == LIQ_ASIA_LOW    || g_liq[i].type == LIQ_LONDON_LOW  ||
                     g_liq[i].type == LIQ_PREV_DAY_LOW);
      if(isHigh && bid > g_liq[i].price + tol) { g_liq[i].isGrabbed = true; g_liq[i].raidTime = TimeCurrent(); }
      if(isLow  && bid < g_liq[i].price - tol) { g_liq[i].isGrabbed = true; g_liq[i].raidTime = TimeCurrent(); }
   }
}

int CountUnraidedPools()
{
   int n = 0;
   for(int i = 0; i < ArraySize(g_liq); i++) if(!g_liq[i].isGrabbed) n++;
   return n;
}

//==================================================================
// MODULE 3 — STRUCTURAL CASCADE (per TF: bias + BOS strength + CHoCH)
//==================================================================
void BuildTFState(int idx)
{
   ENUM_TIMEFRAMES tf = g_tf[idx];
   int P = InpPivotLen;
   if(iBars(_Symbol, tf) < 2 * P + 6) { g_tfState[idx].bias = BIAS_NEUTRAL; return; }

   double lastSH = 0, prevSH = 0, lastSL = 0, prevSL = 0;
   int fh = 0, fl = 0;
   for(int c = P + 1; c <= P + InpStructLookback && (fh < 2 || fl < 2); c++)
   {
      if(fh < 2 && PivotHighTF(tf, c, P))
      { if(fh == 0) lastSH = iHigh(_Symbol, tf, c); else prevSH = iHigh(_Symbol, tf, c); fh++; }
      if(fl < 2 && PivotLowTF(tf, c, P))
      { if(fl == 0) lastSL = iLow(_Symbol, tf, c); else prevSL = iLow(_Symbol, tf, c); fl++; }
   }

   TFState st;
   st.bias          = BIAS_NEUTRAL;
   st.externalHigh  = lastSH;
   st.externalLow   = lastSL;
   st.lastBOSPrice  = 0.0;
   st.bosStrength   = BOS_NONE;
   st.bosDir        = 0;
   st.chochDetected = false;
   st.chochPrice    = 0.0;
   st.currentPhase  = PHASE_NONE;

   if(fh >= 2 && fl >= 2)
   {
      bool bull = (lastSH > prevSH && lastSL > prevSL);
      bool bear = (lastSH < prevSH && lastSL < prevSL);
      if(bull) st.bias = BIAS_BULLISH;
      else if(bear) st.bias = BIAS_BEARISH;
   }

   // BOS off the prior swing, with strength (impulsive body vs wick-only)
   double cl = iClose(_Symbol, tf, 1);
   double op = iOpen (_Symbol, tf, 1);
   double hi = iHigh (_Symbol, tf, 1);
   double lo = iLow  (_Symbol, tf, 1);
   double rng = MathMax(hi - lo, 1e-9);
   double bodyFrac = MathAbs(cl - op) / rng;

   if(prevSH > 0.0 && cl > prevSH)
   {
      st.bosDir       = 1;
      st.lastBOSPrice = prevSH;
      st.bosStrength  = (bodyFrac >= InpBodyImpulseFrac) ? BOS_IMPULSIVE : BOS_WICK_ONLY;
   }
   else if(prevSH > 0.0 && hi > prevSH && cl <= prevSH)
   {
      st.bosDir       = 1;
      st.lastBOSPrice = prevSH;
      st.bosStrength  = BOS_WICK_ONLY;
   }
   if(prevSL > 0.0 && cl < prevSL)
   {
      st.bosDir       = -1;
      st.lastBOSPrice = prevSL;
      st.bosStrength  = (bodyFrac >= InpBodyImpulseFrac) ? BOS_IMPULSIVE : BOS_WICK_ONLY;
   }
   else if(prevSL > 0.0 && lo < prevSL && cl >= prevSL)
   {
      st.bosDir       = -1;
      st.lastBOSPrice = prevSL;
      st.bosStrength  = BOS_WICK_ONLY;
   }

   // CHoCH: a BOS counter to the prevailing bias = first sign of intent shift
   if((st.bias == BIAS_BULLISH && st.bosDir == -1) ||
      (st.bias == BIAS_BEARISH && st.bosDir == 1))
   { st.chochDetected = true; st.chochPrice = st.lastBOSPrice; }

   g_tfState[idx] = st;
}

void BuildStructuralCascade()
{
   for(int i = 0; i < TF_COUNT; i++) BuildTFState(i);
}

// net HTF bias (Monthly..H4 weigh most) — the "true" external direction
ENUM_BIAS DominantBias()
{
   int sum = 0;
   for(int i = 0; i < TF_COUNT; i++)
   {
      int w = TF_COUNT - i;   // MN heaviest
      sum += w * (int)g_tfState[i].bias;
   }
   if(sum > 0) return BIAS_BULLISH;
   if(sum < 0) return BIAS_BEARISH;
   return BIAS_NEUTRAL;
}

string BiasArrow(ENUM_BIAS b) { return (b == BIAS_BULLISH ? "^" : b == BIAS_BEARISH ? "v" : "-"); }
string BosTag(int idx)
{
   ENUM_BOS_STRENGTH s = g_tfState[idx].bosStrength;
   int d = g_tfState[idx].bosDir;
   if(s == BOS_NONE) return "-";
   string dir = (d == 1 ? "^" : d == -1 ? "v" : "");
   return dir + (s == BOS_IMPULSIVE ? "IMP" : "wick") + (g_tfState[idx].chochDetected ? "/CHoCH" : "");
}

//==================================================================
// DASHBOARD
//==================================================================
void UpdateDashboard()
{
   string nl = "\n";
   string s = "snXper FX  —  PHASE A (foundations)  " + _Symbol + (g_isGold ? "  [GOLD]" : "  [FX]") + nl;
   s += "GMT " + IntegerToString(GMTHour()) + ":00   ";
   s += "CYCLE: " + CycleStateLabel(g_cycleState);
   s += "   DAY: " + (g_dayType == DCT_BULLISH ? "BULLISH" : g_dayType == DCT_BEARISH ? "BEARISH" : "undetermined");
   s += "   MODEL: " + (g_sessionModel == SM_TWO_SIDED ? "two-sided" : "one-sided") + nl;
   s += (IsDeadZone() ? "  >> DEAD ZONE — no entries" : IsNearClose() ? "  >> NEAR CLOSE — hard TP / spread buffer" : "  >> tradeable window") + nl;
   s += "------------------------------------------------------------" + nl;

   s += "SESSIONS:  Syd " + DoubleToString(g_sydneyLow,2) + "/" + DoubleToString(g_sydneyHigh,2)
      + (g_sydneyLowRaided?" [L raided]":"") + (g_sydneyHighRaided?" [H raided]":"") + nl;
   s += "           Asia " + DoubleToString(g_asiaLow,2) + "/" + DoubleToString(g_asiaHigh,2)
      + "   Lon " + DoubleToString(g_londonLow,2) + "/" + DoubleToString(g_londonHigh,2) + nl;
   s += "           PrevDay " + DoubleToString(g_prevDayLow,2) + "/" + DoubleToString(g_prevDayHigh,2) + nl;
   s += "------------------------------------------------------------" + nl;

   // structural cascade
   s += "STRUCTURE (MN->M1):" + nl;
   string row1 = "  ";
   for(int i = 0; i < TF_COUNT; i++) row1 += g_tfLbl[i] + BiasArrow(g_tfState[i].bias) + " ";
   s += row1 + nl;
   s += "  DOMINANT BIAS: " + (DominantBias()==BIAS_BULLISH?"BULLISH":DominantBias()==BIAS_BEARISH?"BEARISH":"NEUTRAL") + nl;
   s += "  H4 " + BiasArrow(g_tfState[TF_IDX_H4].bias) + " BOS:" + BosTag(TF_IDX_H4)
      + "   H1 " + BiasArrow(g_tfState[TF_IDX_H1].bias) + " BOS:" + BosTag(TF_IDX_H1) + nl;
   s += "------------------------------------------------------------" + nl;

   // liquidity map
   int total = ArraySize(g_liq);
   s += "LIQUIDITY POOLS: " + IntegerToString(total) + " (" + IntegerToString(CountUnraidedPools()) + " unraided)" + nl;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // nearest unraided pool above and below
   int upIdx = -1, dnIdx = -1; double upD = 1e18, dnD = 1e18;
   for(int i = 0; i < total; i++)
   {
      if(g_liq[i].isGrabbed) continue;
      double d = g_liq[i].price - bid;
      if(d > 0 && d < upD) { upD = d; upIdx = i; }
      if(d < 0 && -d < dnD) { dnD = -d; dnIdx = i; }
   }
   if(upIdx >= 0)
      s += "  nearest ABOVE: " + g_liq[upIdx].label + " " + DoubleToString(g_liq[upIdx].price,2)
         + " (" + DoubleToString(upD / MathMax(PipSize(),1e-9),0) + " pips, ~" + DoubleToString(g_liq[upIdx].estimatedLots,0) + " lots)" + nl;
   if(dnIdx >= 0)
      s += "  nearest BELOW: " + g_liq[dnIdx].label + " " + DoubleToString(g_liq[dnIdx].price,2)
         + " (" + DoubleToString(dnD / MathMax(PipSize(),1e-9),0) + " pips, ~" + DoubleToString(g_liq[dnIdx].estimatedLots,0) + " lots)" + nl;
   s += "------------------------------------------------------------" + nl;
   s += "PHASE A foundations live. Phase B (POI/OFB/FU) builds on this.";

   Comment(s);
}

//==================================================================
// CALLBACKS
//==================================================================
int OnInit()
{
   g_isGold = SymbolIsGold();
   g_prevCycleState = DC_DAILY_CLOSE;
   g_dayType = DCT_UNDETERMINED;
   g_sessionModel = SM_TWO_SIDED;
   g_sydneyHigh = g_sydneyLow = g_asiaHigh = g_asiaLow = 0.0;
   g_londonHigh = g_londonLow = g_dayHigh = g_dayLow = 0.0;
   g_prevDayHigh = g_prevDayLow = 0.0;
   g_sydneyHighRaided = g_sydneyLowRaided = false;
   g_lastBarTime = 0;
   ClearLiq();
   for(int i = 0; i < TF_COUNT; i++)
   {
      g_tfState[i].bias = BIAS_NEUTRAL; g_tfState[i].bosStrength = BOS_NONE;
      g_tfState[i].bosDir = 0; g_tfState[i].chochDetected = false;
      g_tfState[i].currentPhase = PHASE_NONE;
   }
   if(!RefreshSeries()) return INIT_FAILED;
   Print("snXperFX Phase A loaded. Symbol=", _Symbol, " gold=", g_isGold,
         " pip=", DoubleToString(PipSize(), _Digits));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
{
   if(!RefreshSeries()) return;

   // real-time: session H/L stamping, day-type, liquidity raids
   UpdateSession();
   UpdateLiquidityRaids();

   // bar-close: structural cascade + rebuild liquidity map
   if(IsNewBar())
   {
      BuildStructuralCascade();
      RebuildLiquidityMap();
   }

   if(InpShowDashboard) UpdateDashboard();
}
//+------------------------------------------------------------------+
