//+------------------------------------------------------------------+
//| snXperFX.mq5                                                     |
//| snXper FX Trading System — Master Specification v1.0 (COMPLETE)  |
//|                                                                  |
//| Pipeline (spec section 18):                                      |
//|   Session SM -> Structural cascade -> 5-phase engine ->          |
//|   Liquidity map -> POI (4 criteria) -> 3-shift OFB -> FU candle  |
//|   -> Process checklist (all hard gates) -> Execute -> Manage     |
//|   -> Risk guards -> Audit CSV                                    |
//|                                                                  |
//| PHASE A: session SM, liquidity tracker, structural cascade       |
//| PHASE B: POI/flip-zone/inducement, 3-shift OFB, FU, 5-phase      |
//| PHASE C: checklist, lifecycle, execution, exits, risk, audit     |
//| PHASE D: correlation filter (optional)                           |
//|                                                                  |
//| MT5 HEDGING — raw MqlTradeRequest (IOC). XAUUSD-first.          |
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
   PHASE_2      = 3,   // institutional interaction; FU candle / external OFB
   PHASE_3      = 4,   // 3-shift OFB complete; entry zone
   PHASE_4      = 5,   // expansion impulse underway
   PHASE_5      = 6    // new external structural landmark created
};

enum ENUM_DAILY_CYCLE_STATE {
   DC_SYDNEY_RANGE_BUILDING = 0, DC_ALGORITHM_RAID = 1, DC_ASIA_RANGE_FORMING = 2,
   DC_ASIA_EXPANSION = 3, DC_FRANKFURT_RAID = 4, DC_LONDON_OPEN = 5,
   DC_NY_CROSS_RAID = 6, DC_EXPANSION = 7, DC_LATE_SESSION = 8, DC_DAILY_CLOSE = 9
};

enum ENUM_DAILY_CYCLE_TYPE { DCT_BEARISH = -1, DCT_UNDETERMINED = 0, DCT_BULLISH = 1 };
enum ENUM_SESSION_MODEL    { SM_TWO_SIDED = 0, SM_ONE_SIDED = 1 };
enum ENUM_BOS_STRENGTH     { BOS_NONE = -1, BOS_IMPULSIVE = 0, BOS_WICK_ONLY = 1 };
enum ENUM_POI_TYPE         { POI_DEMAND = 1, POI_SUPPLY = -1 };
enum ENUM_ENTRY_TYPE       { ENTRY_REFINED = 0, ENTRY_AGGRESSIVE = 1 };

enum ENUM_LIQUIDITY_TYPE {
   LIQ_EQUAL_HIGHS = 0, LIQ_EQUAL_LOWS = 1, LIQ_ASIA_HIGH = 4, LIQ_ASIA_LOW = 5,
   LIQ_SYDNEY_HIGH = 6, LIQ_SYDNEY_LOW = 7, LIQ_LONDON_HIGH = 8, LIQ_LONDON_LOW = 9,
   LIQ_PREV_DAY_HIGH = 10, LIQ_PREV_DAY_LOW = 11, LIQ_ROUND_NUMBER = 14
};

//==================================================================
// TIMEFRAME LADDER (0=Monthly ... 10=M1)
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
input bool   InpAutoGold        = true;
input bool   InpIsGoldManual    = true;
input double InpRoundStep       = 10.0;

input group "═══ Structure ═══"
input int    InpPivotLen        = 5;
input int    InpStructLookback  = 240;
input double InpBodyImpulseFrac = 0.5;

input group "═══ Liquidity ═══"
input double InpEqualTolPips    = 2.0;
input int    InpEqualScanPivots = 8;
input int    InpMaxLiqPools     = 64;

input group "═══ POI / Inducement ═══"
input int    InpBOSLookback     = 30;     // bars after POI to confirm BOS/OFB
input double InpFib618          = 0.618;
input double InpFib705          = 0.705;
input bool   InpRequireAllPOI   = true;   // enforce all 4 POI criteria (HARD)

input group "═══ Order Flow ═══"
input bool   InpRequire3Shifts  = true;   // require full 3-shift OFB (else aggressive)
input bool   InpRequireFU        = true;  // require FU candle trigger

input group "═══ Entry / Risk ═══"
input bool   InpEnableTrading   = true;
input double InpRiskPct         = 1.0;    // % risk per trade
input double InpCounterRiskPct  = 0.5;    // counter-trend max %
input double InpMaxTotalRiskPct = 3.0;    // max total open risk %
input int    InpMaxPositions    = 3;
input double InpGoldStopMaxPips = 6.0;    // refined-entry stop ceiling (pips)
input double InpAggrSizeMult    = 0.5;    // aggressive-entry size multiplier
input double InpMinStopPips     = 1.5;    // floor on stop distance (pips)
input int    InpMagic           = 770077;

input group "═══ Exits ═══"
input double InpTP1Partial      = 0.5;    // fraction closed at TP1
input double InpHardTPPips      = 40.0;   // hard TP (near close / unattended)
input bool   InpMoveBEAfterTP1  = true;
input bool   InpTrailStructure  = true;

input group "═══ Equity Guards ═══"
input double InpDailyLossPct    = 3.0;    // halt session at -this%
input double InpWeeklyLossPct   = 5.0;    // halve sizing at -this%
input int    InpConsecLossLock  = 3;      // lock after N consecutive losses
input int    InpRevengeSeconds  = 600;    // block re-entry within N sec of a stop

input group "═══ Session / Gold ═══"
input int    InpGoldOpenGMT     = 23;
input bool   InpEnforceDeadZone = true;
input bool   InpRequireSessionWindow = false; // only NY-cross/expansion/late
input double InpGoldSpreadBuffPips   = 4.0;   // close-window stop buffer

input group "═══ Correlation (Phase D) ═══"
input bool   InpEnableCorrelation = false;
input string InpDXYSymbol         = "DXY";
input string InpEURUSDSymbol      = "EURUSD";

input group "═══ Audit / Display ═══"
input bool   InpShowDashboard   = true;
input bool   InpAuditCSV        = true;
input string InpAuditFile       = "snxper_audit.csv";

//==================================================================
// DATA STRUCTURES
//==================================================================
struct TFState {
   ENUM_BIAS             bias;
   double                externalHigh;
   double                externalLow;
   double                lastBOSPrice;
   ENUM_BOS_STRENGTH     bosStrength;
   int                   bosDir;
   bool                  chochDetected;
   double                chochPrice;
};

struct LiquidityPool {
   double              price;
   ENUM_LIQUIDITY_TYPE type;
   double              pips;
   double              estimatedLots;
   bool                isGrabbed;
   datetime            raidTime;
   string              label;
};

struct Swing { double price; int dir; int shift; };  // dir +1 high, -1 low

struct POI {
   bool          exists;
   ENUM_POI_TYPE type;
   double        priceHigh;
   double        priceLow;
   double        precisionLevel;
   int           obShift;
   double        flipZonePrice;
   bool          c1_lastZoneBeforeBOS;
   bool          c2_freeIncomingLiquidity;
   bool          c3_belowFlipZone;
   bool          c4_precisionLeft;
   bool          isValid;
};

struct Checklist {
   bool s1_cascade;
   bool s2_phase3;
   bool s3_poiAllCriteria;
   bool s4_liquidityIncoming;
   bool s5_ofb3;
   bool s6_fu;
   bool s7_timeOK;
   bool s8_correlationOK;
};

struct TradeMeta {
   ulong  ticket;
   long   posId;
   int    dir;
   double entry;
   double sl;
   double tp1;
   double tp2;
   double hardTP;
   double precision;
   bool   partialDone;
   bool   beDone;
   ENUM_ENTRY_TYPE entryType;
};

//==================================================================
// GLOBAL STATE
//==================================================================
TFState        g_tfState[TF_COUNT];
LiquidityPool  g_liq[];
Swing          g_sw[];
POI            g_poi;
Checklist      g_chk;
TradeMeta      g_trades[];

ENUM_DAILY_CYCLE_STATE g_cycleState = DC_SYDNEY_RANGE_BUILDING;
ENUM_DAILY_CYCLE_STATE g_prevCycleState = DC_DAILY_CLOSE;
ENUM_DAILY_CYCLE_TYPE  g_dayType = DCT_UNDETERMINED;
ENUM_SESSION_MODEL     g_sessionModel = SM_TWO_SIDED;
ENUM_STRUCTURAL_PHASE  g_phase = PHASE_NONE;

double   g_sydneyHigh=0, g_sydneyLow=0, g_asiaHigh=0, g_asiaLow=0;
double   g_londonHigh=0, g_londonLow=0, g_dayHigh=0, g_dayLow=0, g_prevDayHigh=0, g_prevDayLow=0;
bool     g_sydneyHighRaided=false, g_sydneyLowRaided=false;
bool     g_isGold=true;

// risk / equity guards
double   g_dayStartEquity=0, g_weekStartEquity=0;
int      g_dayStamp=-1, g_weekStamp=-1;
int      g_consecLosses=0;
datetime g_lastStopTime=0;
bool     g_halted=false;
bool     g_reduceSizing=false;

datetime g_lastBarTime=0;
int      g_ofbShifts=0;
bool     g_fuLong=false, g_fuShort=false;

double   gClose[], gHigh[], gLow[], gOpen[];
datetime gTime[];

//==================================================================
// SERIES + BASIC HELPERS
//==================================================================
bool RefreshSeries(int need=600)
{
   if(need<300) need=300;
   ArraySetAsSeries(gClose,true); ArraySetAsSeries(gHigh,true); ArraySetAsSeries(gLow,true);
   ArraySetAsSeries(gOpen,true);  ArraySetAsSeries(gTime,true);
   int c1=CopyClose(_Symbol,_Period,0,need,gClose);
   int c2=CopyHigh (_Symbol,_Period,0,need,gHigh);
   int c3=CopyLow  (_Symbol,_Period,0,need,gLow);
   int c4=CopyOpen (_Symbol,_Period,0,need,gOpen);
   int c5=CopyTime (_Symbol,_Period,0,need,gTime);
   return (c1>0 && c2>0 && c3>0 && c4>0 && c5>0);
}

bool IsNewBar()
{
   datetime t=(ArraySize(gTime)>0)?gTime[0]:0;
   if(t!=g_lastBarTime){ g_lastBarTime=t; return true; }
   return false;
}

double PipSize()
{
   double pt=_Point; int d=_Digits;
   if(d==3 || d==5) return pt*10.0;
   if(d==2)         return pt*10.0;
   return pt;
}
double PipsToPrice(double pips){ return pips*PipSize(); }
double PriceToPips(double px){ return px/MathMax(PipSize(),1e-9); }

bool SymbolIsGold()
{
   if(!InpAutoGold) return InpIsGoldManual;
   return (StringFind(_Symbol,"XAU")>=0 || StringFind(_Symbol,"GOLD")>=0);
}

int GMTHour(){ MqlDateTime g; TimeGMT(g); return g.hour; }

bool PivotHighTF(ENUM_TIMEFRAMES tf,int c,int P)
{
   double h=iHigh(_Symbol,tf,c); if(h<=0.0) return false;
   for(int k=1;k<=P;k++){ double hu=iHigh(_Symbol,tf,c+k),hd=iHigh(_Symbol,tf,c-k);
      if(hu<=0.0||hd<=0.0) return false; if(h<=hu||h<=hd) return false; }
   return true;
}
bool PivotLowTF(ENUM_TIMEFRAMES tf,int c,int P)
{
   double l=iLow(_Symbol,tf,c); if(l<=0.0) return false;
   for(int k=1;k<=P;k++){ double lu=iLow(_Symbol,tf,c+k),ld=iLow(_Symbol,tf,c-k);
      if(lu<=0.0||ld<=0.0) return false; if(l>=lu||l>=ld) return false; }
   return true;
}

//==================================================================
// MODULE 1 — DAILY CYCLE / SESSION
//==================================================================
ENUM_DAILY_CYCLE_STATE GetCycleState()
{
   int h=GMTHour();
   if(g_isGold && h==23) return DC_SYDNEY_RANGE_BUILDING;
   if(h==0)              return DC_ALGORITHM_RAID;
   if(h>=1 && h<3)       return DC_ASIA_RANGE_FORMING;
   if(h>=3 && h<5)       return DC_ASIA_EXPANSION;
   if(h>=5 && h<7)       return DC_FRANKFURT_RAID;
   if(h>=7 && h<12)      return DC_LONDON_OPEN;
   if(h>=12 && h<13)     return DC_NY_CROSS_RAID;
   if(h>=13 && h<17)     return DC_EXPANSION;
   if(h>=17 && h<21)     return DC_LATE_SESSION;
   if(h>=21)             return DC_DAILY_CLOSE;
   return DC_SYDNEY_RANGE_BUILDING;
}

string CycleStateLabel(ENUM_DAILY_CYCLE_STATE s)
{
   switch(s){
      case DC_SYDNEY_RANGE_BUILDING: return "SYDNEY_BUILD";
      case DC_ALGORITHM_RAID:        return "ALGO_RAID";
      case DC_ASIA_RANGE_FORMING:    return "ASIA_FORMING";
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
   if(g_dayHigh>0.0) g_prevDayHigh=g_dayHigh;
   if(g_dayLow>0.0)  g_prevDayLow =g_dayLow;
   g_sydneyHigh=0; g_sydneyLow=0; g_asiaHigh=0; g_asiaLow=0;
   g_londonHigh=0; g_londonLow=0; g_dayHigh=0; g_dayLow=0;
   g_sydneyHighRaided=false; g_sydneyLowRaided=false;
   g_dayType=DCT_UNDETERMINED; g_sessionModel=SM_TWO_SIDED;
}

void UpdateSession()
{
   g_cycleState=GetCycleState();
   if(g_cycleState==DC_SYDNEY_RANGE_BUILDING && g_prevCycleState!=DC_SYDNEY_RANGE_BUILDING)
      ResetDailyCycle();
   g_prevCycleState=g_cycleState;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(bid<=0.0) return;
   if(g_dayHigh==0.0||bid>g_dayHigh) g_dayHigh=bid;
   if(g_dayLow==0.0||bid<g_dayLow)   g_dayLow=bid;

   if(g_cycleState==DC_SYDNEY_RANGE_BUILDING){
      if(g_sydneyHigh==0.0||bid>g_sydneyHigh) g_sydneyHigh=bid;
      if(g_sydneyLow==0.0||bid<g_sydneyLow)   g_sydneyLow=bid;
   }
   if(g_cycleState==DC_ASIA_RANGE_FORMING||g_cycleState==DC_ASIA_EXPANSION){
      if(g_asiaHigh==0.0||bid>g_asiaHigh) g_asiaHigh=bid;
      if(g_asiaLow==0.0||bid<g_asiaLow)   g_asiaLow=bid;
   }
   if(g_cycleState==DC_LONDON_OPEN){
      if(g_londonHigh==0.0||bid>g_londonHigh) g_londonHigh=bid;
      if(g_londonLow==0.0||bid<g_londonLow)   g_londonLow=bid;
   }
   if(g_cycleState==DC_ALGORITHM_RAID && g_sydneyHigh>0.0 && g_sydneyLow>0.0){
      if(bid<g_sydneyLow)  g_sydneyLowRaided=true;
      if(bid>g_sydneyHigh) g_sydneyHighRaided=true;
      if(g_dayType==DCT_UNDETERMINED){
         if(g_sydneyLowRaided)       g_dayType=DCT_BULLISH;
         else if(g_sydneyHighRaided) g_dayType=DCT_BEARISH;
      }
   }
}

bool IsDeadZone(){ return (g_cycleState==DC_SYDNEY_RANGE_BUILDING||g_cycleState==DC_ALGORITHM_RAID); }
bool IsNearClose(){ return (g_cycleState==DC_DAILY_CLOSE); }
bool InSessionWindow(){ return (g_cycleState==DC_NY_CROSS_RAID||g_cycleState==DC_EXPANSION||g_cycleState==DC_LATE_SESSION||g_cycleState==DC_LONDON_OPEN); }

//==================================================================
// MODULE 2 — LIQUIDITY POOL TRACKER
//==================================================================
void ClearLiq(){ ArrayResize(g_liq,0); }

void AddPool(double price,ENUM_LIQUIDITY_TYPE type,string label)
{
   if(price<=0.0) return;
   int n=ArraySize(g_liq);
   if(n>=InpMaxLiqPools) return;
   double tol=PipSize()*InpEqualTolPips;
   for(int i=0;i<n;i++) if(g_liq[i].type==type && MathAbs(g_liq[i].price-price)<=tol) return;
   ArrayResize(g_liq,n+1);
   g_liq[n].price=price; g_liq[n].type=type; g_liq[n].isGrabbed=false; g_liq[n].raidTime=0; g_liq[n].label=label;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pipsAway=MathAbs(price-bid)/MathMax(PipSize(),1e-9);
   g_liq[n].pips=pipsAway; g_liq[n].estimatedLots=pipsAway*100000.0;
}

void ScanEqualHighsLows()
{
   int P=InpPivotLen; double tol=PipSize()*InpEqualTolPips;
   double highs[]; double lows[]; int fh=0,fl=0; int maxBars=ArraySize(gHigh);
   for(int c=P+1;c<maxBars-P && (fh<InpEqualScanPivots||fl<InpEqualScanPivots);c++){
      bool ph=true,pl=true;
      for(int k=1;k<=P;k++){
         if(gHigh[c]<=gHigh[c+k]||gHigh[c]<=gHigh[c-k]) ph=false;
         if(gLow[c]>=gLow[c+k]||gLow[c]>=gLow[c-k])     pl=false;
      }
      if(ph && fh<InpEqualScanPivots){ int n=ArraySize(highs); ArrayResize(highs,n+1); highs[n]=gHigh[c]; fh++; }
      if(pl && fl<InpEqualScanPivots){ int n=ArraySize(lows);  ArrayResize(lows,n+1);  lows[n]=gLow[c];  fl++; }
   }
   for(int i=0;i<ArraySize(highs);i++) for(int j=i+1;j<ArraySize(highs);j++)
      if(MathAbs(highs[i]-highs[j])<=tol){ AddPool((highs[i]+highs[j])*0.5,LIQ_EQUAL_HIGHS,"EQH"); break; }
   for(int i=0;i<ArraySize(lows);i++) for(int j=i+1;j<ArraySize(lows);j++)
      if(MathAbs(lows[i]-lows[j])<=tol){ AddPool((lows[i]+lows[j])*0.5,LIQ_EQUAL_LOWS,"EQL"); break; }
}

void ScanRoundNumbers()
{
   if(InpRoundStep<=0.0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(bid<=0.0) return;
   double below=MathFloor(bid/InpRoundStep)*InpRoundStep;
   AddPool(below,LIQ_ROUND_NUMBER,"RN"); AddPool(below+InpRoundStep,LIQ_ROUND_NUMBER,"RN");
}

void RebuildLiquidityMap()
{
   ClearLiq();
   AddPool(g_sydneyHigh,LIQ_SYDNEY_HIGH,"SydH"); AddPool(g_sydneyLow,LIQ_SYDNEY_LOW,"SydL");
   AddPool(g_asiaHigh,LIQ_ASIA_HIGH,"AsiaH");    AddPool(g_asiaLow,LIQ_ASIA_LOW,"AsiaL");
   AddPool(g_londonHigh,LIQ_LONDON_HIGH,"LonH"); AddPool(g_londonLow,LIQ_LONDON_LOW,"LonL");
   AddPool(g_prevDayHigh,LIQ_PREV_DAY_HIGH,"PDH"); AddPool(g_prevDayLow,LIQ_PREV_DAY_LOW,"PDL");
   ScanEqualHighsLows(); ScanRoundNumbers();
}

bool PoolIsHigh(ENUM_LIQUIDITY_TYPE t)
{ return (t==LIQ_EQUAL_HIGHS||t==LIQ_SYDNEY_HIGH||t==LIQ_ASIA_HIGH||t==LIQ_LONDON_HIGH||t==LIQ_PREV_DAY_HIGH); }
bool PoolIsLow(ENUM_LIQUIDITY_TYPE t)
{ return (t==LIQ_EQUAL_LOWS||t==LIQ_SYDNEY_LOW||t==LIQ_ASIA_LOW||t==LIQ_LONDON_LOW||t==LIQ_PREV_DAY_LOW); }

void UpdateLiquidityRaids()
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(bid<=0.0) return;
   double tol=PipSize()*0.5;
   for(int i=0;i<ArraySize(g_liq);i++){
      if(g_liq[i].isGrabbed) continue;
      if(PoolIsHigh(g_liq[i].type) && bid>g_liq[i].price+tol){ g_liq[i].isGrabbed=true; g_liq[i].raidTime=TimeCurrent(); }
      if(PoolIsLow(g_liq[i].type)  && bid<g_liq[i].price-tol){ g_liq[i].isGrabbed=true; g_liq[i].raidTime=TimeCurrent(); }
   }
}
int CountUnraided(){ int n=0; for(int i=0;i<ArraySize(g_liq);i++) if(!g_liq[i].isGrabbed) n++; return n; }

// is there incoming (unraided) liquidity between price and the POI, in the pull direction?
bool HasIncomingLiquidity(int dir,double poiPrice)
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   for(int i=0;i<ArraySize(g_liq);i++){
      if(g_liq[i].isGrabbed) continue;
      double p=g_liq[i].price;
      if(dir==1  && PoolIsLow(g_liq[i].type)  && p<=bid && p>=poiPrice) return true; // buys: lows below price toward demand
      if(dir==-1 && PoolIsHigh(g_liq[i].type) && p>=bid && p<=poiPrice) return true; // sells: highs above price toward supply
   }
   return false;
}
// is the POI candle sitting ON a stop cluster (equal H/L within tol)?
bool POIOnEqualLevels(double price)
{
   double tol=PipSize()*InpEqualTolPips;
   for(int i=0;i<ArraySize(g_liq);i++)
      if((g_liq[i].type==LIQ_EQUAL_HIGHS||g_liq[i].type==LIQ_EQUAL_LOWS) && MathAbs(g_liq[i].price-price)<=tol) return true;
   return false;
}

//==================================================================
// MODULE 3 — STRUCTURAL CASCADE
//==================================================================
void BuildTFState(int idx)
{
   ENUM_TIMEFRAMES tf=g_tf[idx]; int P=InpPivotLen;
   TFState st; st.bias=BIAS_NEUTRAL; st.externalHigh=0; st.externalLow=0; st.lastBOSPrice=0;
   st.bosStrength=BOS_NONE; st.bosDir=0; st.chochDetected=false; st.chochPrice=0;
   if(iBars(_Symbol,tf)<2*P+6){ g_tfState[idx]=st; return; }

   double lastSH=0,prevSH=0,lastSL=0,prevSL=0; int fh=0,fl=0;
   for(int c=P+1;c<=P+InpStructLookback && (fh<2||fl<2);c++){
      if(fh<2 && PivotHighTF(tf,c,P)){ if(fh==0) lastSH=iHigh(_Symbol,tf,c); else prevSH=iHigh(_Symbol,tf,c); fh++; }
      if(fl<2 && PivotLowTF(tf,c,P)){  if(fl==0) lastSL=iLow(_Symbol,tf,c);  else prevSL=iLow(_Symbol,tf,c);  fl++; }
   }
   st.externalHigh=lastSH; st.externalLow=lastSL;
   if(fh>=2 && fl>=2){
      if(lastSH>prevSH && lastSL>prevSL) st.bias=BIAS_BULLISH;
      else if(lastSH<prevSH && lastSL<prevSL) st.bias=BIAS_BEARISH;
   }
   double cl=iClose(_Symbol,tf,1),op=iOpen(_Symbol,tf,1),hi=iHigh(_Symbol,tf,1),lo=iLow(_Symbol,tf,1);
   double rng=MathMax(hi-lo,1e-9); double bodyFrac=MathAbs(cl-op)/rng;
   if(prevSH>0.0 && cl>prevSH){ st.bosDir=1; st.lastBOSPrice=prevSH; st.bosStrength=(bodyFrac>=InpBodyImpulseFrac)?BOS_IMPULSIVE:BOS_WICK_ONLY; }
   else if(prevSH>0.0 && hi>prevSH && cl<=prevSH){ st.bosDir=1; st.lastBOSPrice=prevSH; st.bosStrength=BOS_WICK_ONLY; }
   if(prevSL>0.0 && cl<prevSL){ st.bosDir=-1; st.lastBOSPrice=prevSL; st.bosStrength=(bodyFrac>=InpBodyImpulseFrac)?BOS_IMPULSIVE:BOS_WICK_ONLY; }
   else if(prevSL>0.0 && lo<prevSL && cl>=prevSL){ st.bosDir=-1; st.lastBOSPrice=prevSL; st.bosStrength=BOS_WICK_ONLY; }
   if((st.bias==BIAS_BULLISH && st.bosDir==-1)||(st.bias==BIAS_BEARISH && st.bosDir==1))
   { st.chochDetected=true; st.chochPrice=st.lastBOSPrice; }
   g_tfState[idx]=st;
}
void BuildStructuralCascade(){ for(int i=0;i<TF_COUNT;i++) BuildTFState(i); }

ENUM_BIAS DominantBias()
{
   int sum=0;
   for(int i=0;i<TF_COUNT;i++){ int w=TF_COUNT-i; sum+=w*(int)g_tfState[i].bias; }
   if(sum>0) return BIAS_BULLISH; if(sum<0) return BIAS_BEARISH; return BIAS_NEUTRAL;
}
string BiasArrow(ENUM_BIAS b){ return (b==BIAS_BULLISH?"^":b==BIAS_BEARISH?"v":"-"); }

//==================================================================
// CHART-SERIES SWINGS (entry-TF structure for POI / OFB / phase)
//==================================================================
void CollectSwings(int want=14)
{
   ArrayResize(g_sw,0);
   int P=InpPivotLen; int maxBars=ArraySize(gHigh);
   for(int c=P+1;c<maxBars-P && ArraySize(g_sw)<want;c++){
      bool ph=true,pl=true;
      for(int k=1;k<=P;k++){
         if(gHigh[c]<=gHigh[c+k]||gHigh[c]<=gHigh[c-k]) ph=false;
         if(gLow[c]>=gLow[c+k]||gLow[c]>=gLow[c-k])     pl=false;
      }
      if(ph){ int n=ArraySize(g_sw); ArrayResize(g_sw,n+1); g_sw[n].price=gHigh[c]; g_sw[n].dir=1;  g_sw[n].shift=c; }
      else if(pl){ int n=ArraySize(g_sw); ArrayResize(g_sw,n+1); g_sw[n].price=gLow[c]; g_sw[n].dir=-1; g_sw[n].shift=c; }
   }
}
// rank-th most recent swing of a given dir; returns index in g_sw or -1
int SwingIdx(int dir,int rank)
{
   int seen=0;
   for(int i=0;i<ArraySize(g_sw);i++){ if(g_sw[i].dir==dir){ if(seen==rank) return i; seen++; } }
   return -1;
}

//==================================================================
// MODULE 4 — POI ENGINE (4 criteria + flip zone + inducement)
//==================================================================
double FindFlipZone(int dir)
{
   // flip zone = the prior opposing swing that retail watches as S/R.
   // demand(buy): nearest swing HIGH above current price; supply(sell): nearest swing LOW below.
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID); double best=0.0;
   for(int i=0;i<ArraySize(g_sw);i++){
      if(dir==1 && g_sw[i].dir==1 && g_sw[i].price>bid){ if(best==0.0||g_sw[i].price<best) best=g_sw[i].price; }
      if(dir==-1&& g_sw[i].dir==-1&& g_sw[i].price<bid){ if(best==0.0||g_sw[i].price>best) best=g_sw[i].price; }
   }
   return best;
}

bool IsInducement(int dir,double price)
{
   // 0.618–0.705 retracement of the most recent impulse = inducement band.
   int hi=SwingIdx(1,0), lo=SwingIdx(-1,0);
   if(hi<0||lo<0) return false;
   double H=g_sw[hi].price, L=g_sw[lo].price;
   if(H<=L) return false;
   if(dir==1){ double f618=H-(H-L)*InpFib618, f705=H-(H-L)*InpFib705; return (price<=f618 && price>=f705); }
   double f618=L+(H-L)*InpFib618, f705=L+(H-L)*InpFib705; return (price>=f618 && price<=f705);
}

void IdentifyPOI(int dir)
{
   g_poi.exists=false; g_poi.isValid=false;
   g_poi.c1_lastZoneBeforeBOS=false; g_poi.c2_freeIncomingLiquidity=false;
   g_poi.c3_belowFlipZone=false; g_poi.c4_precisionLeft=false;
   if(dir==0) return;

   // POI candle = the swing that launched the impulse: demand=most recent swing low, supply=most recent swing high
   int si=SwingIdx(dir==1?-1:1,0);
   if(si<0) return;
   int sh=g_sw[si].shift;
   if(sh<1 || sh>=ArraySize(gHigh)) return;

   g_poi.exists=true;
   g_poi.type=(dir==1)?POI_DEMAND:POI_SUPPLY;
   g_poi.priceHigh=gHigh[sh];
   g_poi.priceLow =gLow[sh];
   g_poi.obShift  =sh;
   g_poi.precisionLevel=(dir==1)?gLow[sh]:gHigh[sh];

   // C1: last zone before BOS — did price break the prior opposing swing AFTER this POI? (BOS within lookback)
   int oppIdx=SwingIdx(dir==1?1:-1,0);
   double oppLevel=(oppIdx>=0)?g_sw[oppIdx].price:0.0;
   double cl=gClose[1];
   if(oppLevel>0.0){
      if(dir==1)  g_poi.c1_lastZoneBeforeBOS=(cl>oppLevel || g_dayHigh>oppLevel);
      else        g_poi.c1_lastZoneBeforeBOS=(cl<oppLevel || g_dayLow <oppLevel);
   }

   // C2: free of equal-level stops AND incoming liquidity present
   bool freeOf   = !POIOnEqualLevels(g_poi.precisionLevel);
   bool incoming = HasIncomingLiquidity(dir,g_poi.precisionLevel);
   g_poi.c2_freeIncomingLiquidity=(freeOf && incoming);

   // C3: below/above flip zone AND not an inducement reaction
   double flip=FindFlipZone(dir); g_poi.flipZonePrice=flip;
   bool belowFlip=true;
   if(flip>0.0) belowFlip=(dir==1)?(g_poi.precisionLevel<flip):(g_poi.precisionLevel>flip);
   bool induce=IsInducement(dir,SymbolInfoDouble(_Symbol,SYMBOL_BID));
   g_poi.c3_belowFlipZone=(belowFlip && !induce);

   // C4: precision sub-zone identified + refined enough (stop within ceiling)
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double stopPips=MathAbs(bid-g_poi.precisionLevel)/MathMax(PipSize(),1e-9);
   g_poi.c4_precisionLeft=(g_poi.precisionLevel>0.0 && stopPips>0.0);

   g_poi.isValid=(g_poi.c1_lastZoneBeforeBOS && g_poi.c2_freeIncomingLiquidity &&
                  g_poi.c3_belowFlipZone && g_poi.c4_precisionLeft);
}

//==================================================================
// MODULE 5 — 3-SHIFT ORDER FLOW BREAK
//==================================================================
int Detect3ShiftOFB(int dir)
{
   // shift1 external: broke the opposing external swing (the high before the dip for buys)
   // shift2 internal: a counter swing formed in the trade dir after the POI (HL for buys)
   // shift3 final   : broke the most recent swing in trade dir after shift2
   int shifts=0;
   double cl=gClose[1];
   int extIdx=SwingIdx(dir==1?1:-1,1);   // the swing before the impulse origin
   if(extIdx<0) extIdx=SwingIdx(dir==1?1:-1,0);
   double extLevel=(extIdx>=0)?g_sw[extIdx].price:0.0;
   bool s1=false,s2=false,s3=false;
   if(extLevel>0.0) s1=(dir==1)?(cl>extLevel):(cl<extLevel);
   // internal: most recent same-as-origin swing exists newer than impulse (a HL for buys)
   int intIdx=SwingIdx(dir==1?-1:1,0);   // most recent low(buy)/high(sell)
   int origIdx=SwingIdx(dir==1?-1:1,1);
   if(intIdx>=0 && origIdx>=0)
      s2=(dir==1)?(g_sw[intIdx].price>g_sw[origIdx].price):(g_sw[intIdx].price<g_sw[origIdx].price);
   // final: broke the most recent trade-dir swing
   int finIdx=SwingIdx(dir==1?1:-1,0);
   double finLevel=(finIdx>=0)?g_sw[finIdx].price:0.0;
   if(finLevel>0.0) s3=(dir==1)?(cl>finLevel):(cl<finLevel);
   if(s1) shifts++; if(s2) shifts++; if(s3) shifts++;
   return shifts;
}

//==================================================================
// MODULE 6 — FU CANDLE + 5-PHASE
//==================================================================
void DetectFU()
{
   g_fuLong=false; g_fuShort=false;
   if(!g_poi.exists) return;
   double prec=g_poi.precisionLevel;
   // demand FU: wicked below precision then closed back above, bullish body
   if(g_poi.type==POI_DEMAND)
      g_fuLong=(gLow[1]<prec && gClose[1]>prec && gClose[1]>gOpen[1]);
   if(g_poi.type==POI_SUPPLY)
      g_fuShort=(gHigh[1]>prec && gClose[1]<prec && gClose[1]<gOpen[1]);
}

ENUM_STRUCTURAL_PHASE Determine5Phase(int dir)
{
   if(dir==0 || !g_poi.exists) return PHASE_NONE;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool atPOI=(bid>=g_poi.priceLow-PipsToPrice(InpEqualTolPips) && bid<=g_poi.priceHigh+PipsToPrice(InpEqualTolPips));
   int shifts=g_ofbShifts;
   bool fu=(dir==1)?g_fuLong:g_fuShort;
   if(shifts>=3) return PHASE_3;
   if(atPOI && fu) return PHASE_2;
   if(atPOI)       return PRE_PHASE_2A;
   return PHASE_1;
}

//==================================================================
// CORRELATION (Phase D, optional)
//==================================================================
ENUM_BIAS SymbolBias(string sym)
{
   if(StringLen(sym)<2) return BIAS_NEUTRAL;
   double h1=iHigh(sym,PERIOD_H4,1), h2=iHigh(sym,PERIOD_H4,1+InpPivotLen);
   double l1=iLow(sym,PERIOD_H4,1),  l2=iLow(sym,PERIOD_H4,1+InpPivotLen);
   if(h1<=0||h2<=0||l1<=0||l2<=0) return BIAS_NEUTRAL;
   if(h1>h2 && l1>l2) return BIAS_BULLISH;
   if(h1<h2 && l1<l2) return BIAS_BEARISH;
   return BIAS_NEUTRAL;
}
bool CorrelationOK(int dir)
{
   if(!InpEnableCorrelation) return true;
   // Gold buy needs dollar weakness: DXY not bullish; EURUSD not actively bearish.
   ENUM_BIAS dxy=SymbolBias(InpDXYSymbol);
   if(g_isGold){
      if(dir==1 && dxy==BIAS_BULLISH) return false;
      if(dir==-1&& dxy==BIAS_BEARISH) return false;
   }
   return true;
}

//==================================================================
// MODULE 8 — PROCESS CHECKLIST
//==================================================================
void BuildChecklist(int dir)
{
   ENUM_BIAS dom=DominantBias();
   g_chk.s1_cascade        = (dom!=BIAS_NEUTRAL && (int)dom==dir);
   g_chk.s2_phase3         = (g_phase==PHASE_3);
   g_chk.s3_poiAllCriteria = (!InpRequireAllPOI || g_poi.isValid);
   g_chk.s4_liquidityIncoming = HasIncomingLiquidity(dir,g_poi.precisionLevel);
   g_chk.s5_ofb3           = (!InpRequire3Shifts || g_ofbShifts>=3);
   g_chk.s6_fu             = (!InpRequireFU || (dir==1?g_fuLong:g_fuShort));
   g_chk.s7_timeOK         = (!InpEnforceDeadZone || !IsDeadZone()) && (!InpRequireSessionWindow || InSessionWindow());
   g_chk.s8_correlationOK  = CorrelationOK(dir);
}
bool ChecklistAllPass()
{
   return g_chk.s1_cascade && g_chk.s2_phase3 && g_chk.s3_poiAllCriteria &&
          g_chk.s5_ofb3 && g_chk.s6_fu && g_chk.s7_timeOK && g_chk.s8_correlationOK;
}

//==================================================================
// ORDER EXECUTION HELPERS (raw IOC)
//==================================================================
bool SendOrder(int dir,double lots,double sl,double tp,const string cmt)
{
   if(lots<=0.0) return false;
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.magic=InpMagic; req.volume=lots;
   req.sl=sl; req.tp=tp; req.deviation=20; req.type_filling=ORDER_FILLING_IOC; req.type_time=ORDER_TIME_GTC; req.comment=cmt;
   if(dir>0){ req.type=ORDER_TYPE_BUY; req.price=ask; } else { req.type=ORDER_TYPE_SELL; req.price=bid; }
   if(!OrderSend(req,res)){ Print("SendOrder fail dir=",dir," ret=",res.retcode); return false; }
   if(res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_DONE_PARTIAL){ Print("SendOrder not DONE ret=",res.retcode); return false; }
   return true;
}
bool ClosePartial(ulong ticket,double lots,const string tag)
{
   if(lots<=0.0) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   long type=PositionGetInteger(POSITION_TYPE); double posLots=PositionGetDouble(POSITION_VOLUME);
   lots=NormalizeDouble(lots,2); if(lots>posLots) lots=posLots; if(lots<=0.0) return false;
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.magic=InpMagic; req.position=ticket; req.volume=lots;
   req.deviation=20; req.type_filling=ORDER_FILLING_IOC; req.type_time=ORDER_TIME_GTC; req.comment=tag;
   if(type==POSITION_TYPE_BUY){ req.type=ORDER_TYPE_SELL; req.price=bid; } else { req.type=ORDER_TYPE_BUY; req.price=ask; }
   if(!OrderSend(req,res)){ Print("ClosePartial fail ",ticket," ret=",res.retcode); return false; }
   return (res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_DONE_PARTIAL);
}
bool ClosePositionFull(ulong ticket,const string tag)
{
   if(!PositionSelectByTicket(ticket)) return false;
   return ClosePartial(ticket,PositionGetDouble(POSITION_VOLUME),tag);
}
bool ModifySLTP(ulong ticket,double sl,double tp)
{
   if(!PositionSelectByTicket(ticket)) return false;
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action=TRADE_ACTION_SLTP; req.symbol=_Symbol; req.position=ticket;
   req.sl=NormalizeDouble(sl,_Digits); req.tp=NormalizeDouble(tp,_Digits);
   if(!OrderSend(req,res)) return false;
   return true;
}

//==================================================================
// MODULE 12 — RISK
//==================================================================
double ComputeLots(double riskUSD,double stopPips)
{
   if(stopPips<=0.0) return 0.0;
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSz =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double pipVal=(tickSz>0.0)?(tickVal/tickSz)*PipSize():10.0;   // $/pip per lot
   if(pipVal<=0.0) pipVal=10.0;
   double lots=riskUSD/(stopPips*pipVal);
   double minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step  =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots=MathFloor(lots/step)*step;
   if(lots<minLot) lots=minLot;
   if(lots>maxLot) lots=maxLot;
   return NormalizeDouble(lots,2);
}
double OpenRiskUSD()
{
   double total=0.0; int n=PositionsTotal();
   for(int i=0;i<n;i++){
      ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      double entry=PositionGetDouble(POSITION_PRICE_OPEN), sl=PositionGetDouble(POSITION_SL), lots=PositionGetDouble(POSITION_VOLUME);
      if(sl<=0.0) continue;
      double stopPips=MathAbs(entry-sl)/MathMax(PipSize(),1e-9);
      double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), tickSz=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      double pipVal=(tickSz>0.0)?(tickVal/tickSz)*PipSize():10.0;
      total+=stopPips*pipVal*lots;
   }
   return total;
}
int CountPositions()
{
   int c=0,n=PositionsTotal();
   for(int i=0;i<n;i++){ ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic) c++; }
   return c;
}

void UpdateEquityGuards()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(t.day_of_year!=g_dayStamp){ g_dayStamp=t.day_of_year; g_dayStartEquity=eq; g_halted=false; }
   int wk=t.day_of_year/7;
   if(wk!=g_weekStamp){ g_weekStamp=wk; g_weekStartEquity=eq; g_reduceSizing=false; }
   if(g_dayStartEquity>0.0 && eq<=g_dayStartEquity*(1.0-InpDailyLossPct/100.0)) g_halted=true;
   if(g_weekStartEquity>0.0 && eq<=g_weekStartEquity*(1.0-InpWeeklyLossPct/100.0)) g_reduceSizing=true;
   if(g_consecLosses>=InpConsecLossLock) g_halted=true;
}
bool TradingAllowed()
{
   if(!InpEnableTrading) return false;
   if(g_halted) return false;
   if(TimeCurrent()-g_lastStopTime < InpRevengeSeconds && g_lastStopTime>0) return false;  // revenge guard
   return true;
}

//==================================================================
// TRADE META TRACKING + AUDIT
//==================================================================
int FindMeta(ulong ticket){ for(int i=0;i<ArraySize(g_trades);i++) if(g_trades[i].ticket==ticket) return i; return -1; }

void AdoptPosition(int dir,double sl,double tp1,double tp2,double hardTP,double precision,ENUM_ENTRY_TYPE et)
{
   int n=PositionsTotal();
   for(int i=0;i<n;i++){
      ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      if((type==POSITION_TYPE_BUY?1:-1)!=dir) continue;
      if(FindMeta(tk)>=0) continue;
      int m=ArraySize(g_trades); ArrayResize(g_trades,m+1);
      g_trades[m].ticket=tk; g_trades[m].posId=(long)PositionGetInteger(POSITION_IDENTIFIER);
      g_trades[m].dir=dir; g_trades[m].entry=PositionGetDouble(POSITION_PRICE_OPEN);
      g_trades[m].sl=sl; g_trades[m].tp1=tp1; g_trades[m].tp2=tp2; g_trades[m].hardTP=hardTP;
      g_trades[m].precision=precision; g_trades[m].partialDone=false; g_trades[m].beDone=false; g_trades[m].entryType=et;
      return;
   }
}
double PositionRealized(long posId)
{
   if(!HistorySelectByPosition(posId)) return 0.0;
   double p=0.0; int total=HistoryDealsTotal();
   for(int i=0;i<total;i++){ ulong d=HistoryDealGetTicket(i); if(d==0) continue;
      p+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION); }
   return p;
}
void AuditAppend(string line)
{
   if(!InpAuditCSV) return;
   int h=FileOpen(InpAuditFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(h==INVALID_HANDLE) return;
   FileSeek(h,0,SEEK_END);
   FileWrite(h,line);
   FileClose(h);
}
void LogEntryAudit(TradeMeta &m)
{
   string line=StringFormat("%s;%s;%s;%.5f;%.5f;%.1f;%.5f;%.5f;%s;%s",
      TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES), _Symbol, (m.dir==1?"LONG":"SHORT"),
      m.entry, m.sl, MathAbs(m.entry-m.sl)/MathMax(PipSize(),1e-9), m.tp1, m.tp2,
      (m.entryType==ENTRY_REFINED?"REFINED":"AGGRESSIVE"), "OPEN");
   AuditAppend(line);
}
void LogExitAudit(TradeMeta &m,double pnl)
{
   string res=(pnl>0?"WIN":(pnl<0?"LOSS":"BE"));
   string line=StringFormat("%s;%s;%s;EXIT;%.2f;%s",
      TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES), _Symbol, (m.dir==1?"LONG":"SHORT"), pnl, res);
   AuditAppend(line);
}

void SyncClosedTrades()
{
   for(int i=ArraySize(g_trades)-1;i>=0;i--){
      if(PositionSelectByTicket(g_trades[i].ticket)) continue;   // still open
      double pnl=PositionRealized(g_trades[i].posId);
      LogExitAudit(g_trades[i],pnl);
      if(pnl<0){ g_consecLosses++; g_lastStopTime=TimeCurrent(); }
      else if(pnl>0){ g_consecLosses=0; }
      // remove
      for(int j=i;j<ArraySize(g_trades)-1;j++) g_trades[j]=g_trades[j+1];
      ArrayResize(g_trades,ArraySize(g_trades)-1);
   }
}

//==================================================================
// MODULE 10 — ENTRY EXECUTION
//==================================================================
void AttemptEntry(int dir)
{
   if(!TradingAllowed()) return;
   if(CountPositions()>=InpMaxPositions) return;
   if(!ChecklistAllPass()) return;
   if(IsDeadZone()) return;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double entry=(dir==1)?ask:bid;
   double prec=g_poi.precisionLevel;
   double buffer=MathMax(PipsToPrice(InpMinStopPips), PipsToPrice(1.5));
   if(IsNearClose()) buffer+=PipsToPrice(InpGoldSpreadBuffPips);
   double sl=(dir==1)?(prec-buffer):(prec+buffer);
   double stopPips=MathAbs(entry-sl)/MathMax(PipSize(),1e-9);
   if(stopPips<InpMinStopPips){ stopPips=InpMinStopPips; sl=(dir==1)?(entry-PipsToPrice(stopPips)):(entry+PipsToPrice(stopPips)); }

   // refined vs aggressive
   ENUM_ENTRY_TYPE et=ENTRY_REFINED;
   double riskPct=InpRiskPct;
   ENUM_BIAS dom=DominantBias();
   bool counter=((int)dom!=dir);
   if(counter) riskPct=MathMin(riskPct,InpCounterRiskPct);
   if(stopPips>InpGoldStopMaxPips){ et=ENTRY_AGGRESSIVE; riskPct*=InpAggrSizeMult; }
   if(g_reduceSizing) riskPct*=0.5;

   // TP1 = prior swing high/low ; TP2 = next external structure (dominant TF extreme)
   int t1Idx=SwingIdx(dir==1?1:-1,0);
   double tp1=(t1Idx>=0)?g_sw[t1Idx].price:(dir==1?entry+PipsToPrice(InpHardTPPips):entry-PipsToPrice(InpHardTPPips));
   double tp2=(dir==1)?g_tfState[TF_IDX_H4].externalHigh:g_tfState[TF_IDX_H4].externalLow;
   if(tp2<=0.0) tp2=tp1;
   double hardTP=0.0;
   if(IsNearClose()) hardTP=(dir==1)?entry+PipsToPrice(InpHardTPPips):entry-PipsToPrice(InpHardTPPips);

   // risk sizing + total-risk ceiling
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskUSD=eq*riskPct/100.0;
   double lots=ComputeLots(riskUSD,stopPips);
   // total open risk cap
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE), tickSz=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double pipVal=(tickSz>0.0)?(tickVal/tickSz)*PipSize():10.0;
   double newRisk=stopPips*pipVal*lots;
   double maxTotal=eq*InpMaxTotalRiskPct/100.0;
   if(OpenRiskUSD()+newRisk>maxTotal){
      double avail=maxTotal-OpenRiskUSD();
      if(avail<=0.0) return;
      lots=ComputeLots(avail,stopPips);
   }
   if(lots<=0.0) return;

   double tpOrder=(hardTP>0.0)?hardTP:0.0;   // broker TP only for hard-TP cases; else managed
   string cmt=StringFormat("snX %s %s P3", (dir==1?"BUY":"SELL"), (et==ENTRY_REFINED?"REF":"AGG"));
   if(SendOrder(dir,lots,sl,tpOrder,cmt)){
      AdoptPosition(dir,sl,tp1,tp2,hardTP,prec,et);
      int m=FindMetaByDirNewest(dir);
      if(m>=0) LogEntryAudit(g_trades[m]);
      Print("snX ENTRY ",(dir==1?"BUY":"SELL")," @",DoubleToString(entry,_Digits)," SL ",DoubleToString(sl,_Digits),
            " (",DoubleToString(stopPips,1)," pips) lots ",DoubleToString(lots,2)," ",(et==ENTRY_REFINED?"REFINED":"AGGR"),
            " TP1 ",DoubleToString(tp1,_Digits));
   }
}
int FindMetaByDirNewest(int dir)
{
   int best=-1;
   for(int i=0;i<ArraySize(g_trades);i++) if(g_trades[i].dir==dir) best=i;
   return best;
}

//==================================================================
// MODULE 11 — EXIT / POSITION MANAGEMENT
//==================================================================
void ManagePositions()
{
   ENUM_BIAS dom=DominantBias();
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=0;i<ArraySize(g_trades);i++){
      ulong tk=g_trades[i].ticket;
      if(!PositionSelectByTicket(tk)) continue;
      int dir=g_trades[i].dir;
      double entry=g_trades[i].entry;
      double px=(dir==1)?bid:ask;
      double lots=PositionGetDouble(POSITION_VOLUME);
      double curSL=PositionGetDouble(POSITION_SL), curTP=PositionGetDouble(POSITION_TP);

      // FE1: HTF external structure broken against position -> close
      if((dir==1 && dom==BIAS_BEARISH)||(dir==-1 && dom==BIAS_BULLISH)){
         ClosePositionFull(tk,"snX FE HTF-break"); continue;
      }
      // near close: ensure a hard TP exists
      if(IsNearClose() && curTP<=0.0 && g_trades[i].hardTP>0.0)
         ModifySLTP(tk,curSL,g_trades[i].hardTP);

      // TP1 partial + BE
      if(!g_trades[i].partialDone){
         bool tp1Hit=(dir==1)?(px>=g_trades[i].tp1):(px<=g_trades[i].tp1);
         if(tp1Hit && g_trades[i].tp1>0.0){
            ClosePartial(tk,lots*InpTP1Partial,"snX TP1");
            g_trades[i].partialDone=true;
            if(InpMoveBEAfterTP1){ ModifySLTP(tk,entry,curTP); g_trades[i].beDone=true; }
         }
      }
      // structure trail: trail to most recent HL (buy) / LH (sell)
      if(InpTrailStructure && g_trades[i].partialDone){
         int idx=SwingIdx(dir==1?-1:1,0);
         if(idx>=0){
            double lvl=g_sw[idx].price;
            if(dir==1 && lvl>curSL && lvl<px) ModifySLTP(tk,lvl,curTP);
            if(dir==-1&& (curSL==0.0||lvl<curSL) && lvl>px) ModifySLTP(tk,lvl,curTP);
         }
      }
   }
}

//==================================================================
// DASHBOARD
//==================================================================
void UpdateDashboard()
{
   string nl="\n";
   ENUM_BIAS dom=DominantBias();
   int tradeDir=(dom==BIAS_BULLISH?1:dom==BIAS_BEARISH?-1:0);
   string s="snXper FX  —  "+_Symbol+(g_isGold?" [GOLD]":" [FX]")+(g_halted?"  *** HALTED ***":"")+nl;
   s+="GMT "+IntegerToString(GMTHour())+":00  CYCLE "+CycleStateLabel(g_cycleState)
     +"  DAY "+(g_dayType==DCT_BULLISH?"BULL":g_dayType==DCT_BEARISH?"BEAR":"undet")+nl;
   s+=(IsDeadZone()?">> DEAD ZONE":IsNearClose()?">> NEAR CLOSE (hard TP)":">> tradeable")+nl;
   s+="------------------------------------------------------------"+nl;
   string row=""; for(int i=0;i<TF_COUNT;i++) row+=g_tfLbl[i]+BiasArrow(g_tfState[i].bias)+" ";
   s+="STRUCT "+row+nl;
   s+="DOMINANT "+(dom==BIAS_BULLISH?"BULLISH":dom==BIAS_BEARISH?"BEARISH":"NEUTRAL")
     +"   PHASE "+IntegerToString((int)g_phase)+"/6   OFB "+IntegerToString(g_ofbShifts)+"/3"
     +"   FU "+((tradeDir==1&&g_fuLong)||(tradeDir==-1&&g_fuShort)?"YES":"no")+nl;
   s+="------------------------------------------------------------"+nl;
   if(g_poi.exists){
      s+="POI "+(g_poi.type==POI_DEMAND?"DEMAND":"SUPPLY")+" prec "+DoubleToString(g_poi.precisionLevel,2)
        +(g_poi.isValid?"  VALID":"  invalid")+nl;
      s+="  C1 "+(g_poi.c1_lastZoneBeforeBOS?"Y":"n")+" C2 "+(g_poi.c2_freeIncomingLiquidity?"Y":"n")
        +" C3 "+(g_poi.c3_belowFlipZone?"Y":"n")+" C4 "+(g_poi.c4_precisionLeft?"Y":"n")
        +"  flip "+DoubleToString(g_poi.flipZonePrice,2)+nl;
   } else s+="POI none"+nl;
   s+="CHK c1:"+(g_chk.s1_cascade?"Y":"n")+" ph3:"+(g_chk.s2_phase3?"Y":"n")+" poi:"+(g_chk.s3_poiAllCriteria?"Y":"n")
     +" ofb:"+(g_chk.s5_ofb3?"Y":"n")+" fu:"+(g_chk.s6_fu?"Y":"n")+" time:"+(g_chk.s7_timeOK?"Y":"n")
     +" corr:"+(g_chk.s8_correlationOK?"Y":"n")+"  => "+(ChecklistAllPass()?"ALL PASS":"blocked")+nl;
   s+="------------------------------------------------------------"+nl;
   s+="LIQ "+IntegerToString(ArraySize(g_liq))+" ("+IntegerToString(CountUnraided())+" unraided)"
     +"   POS "+IntegerToString(CountPositions())+"/"+IntegerToString(InpMaxPositions)
     +"   openRisk $"+DoubleToString(OpenRiskUSD(),0)+"   consecL "+IntegerToString(g_consecLosses)+nl;
   s+="SESS Syd "+DoubleToString(g_sydneyLow,2)+"/"+DoubleToString(g_sydneyHigh,2)
     +(g_sydneyLowRaided?"[L]":"")+(g_sydneyHighRaided?"[H]":"")
     +"  Asia "+DoubleToString(g_asiaLow,2)+"/"+DoubleToString(g_asiaHigh,2)
     +"  Lon "+DoubleToString(g_londonLow,2)+"/"+DoubleToString(g_londonHigh,2)+nl;
   Comment(s);
}

//==================================================================
// PIPELINE (spec section 18) — runs on bar close
//==================================================================
void RunPipeline()
{
   BuildStructuralCascade();
   CollectSwings();
   RebuildLiquidityMap();

   ENUM_BIAS dom=DominantBias();
   int dir=(dom==BIAS_BULLISH?1:dom==BIAS_BEARISH?-1:0);

   IdentifyPOI(dir);
   g_ofbShifts=(dir!=0)?Detect3ShiftOFB(dir):0;
   DetectFU();
   g_phase=Determine5Phase(dir);
   BuildChecklist(dir);

   if(dir!=0) AttemptEntry(dir);
}

//==================================================================
// CALLBACKS
//==================================================================
int OnInit()
{
   g_isGold=SymbolIsGold();
   g_prevCycleState=DC_DAILY_CLOSE; g_dayType=DCT_UNDETERMINED; g_sessionModel=SM_TWO_SIDED;
   g_sydneyHigh=g_sydneyLow=g_asiaHigh=g_asiaLow=0; g_londonHigh=g_londonLow=g_dayHigh=g_dayLow=0;
   g_prevDayHigh=g_prevDayLow=0; g_sydneyHighRaided=g_sydneyLowRaided=false;
   g_lastBarTime=0; g_consecLosses=0; g_lastStopTime=0; g_halted=false; g_reduceSizing=false;
   g_dayStamp=-1; g_weekStamp=-1; g_poi.exists=false; g_phase=PHASE_NONE; g_ofbShifts=0;
   ClearLiq(); ArrayResize(g_trades,0);
   for(int i=0;i<TF_COUNT;i++){ g_tfState[i].bias=BIAS_NEUTRAL; g_tfState[i].bosStrength=BOS_NONE;
      g_tfState[i].bosDir=0; g_tfState[i].chochDetected=false; }
   if(!RefreshSeries()) return INIT_FAILED;
   Print("snXperFX COMPLETE loaded. ",_Symbol," gold=",g_isGold," pip=",DoubleToString(PipSize(),_Digits));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason){ Comment(""); }

void OnTick()
{
   if(!RefreshSeries()) return;
   UpdateSession();
   UpdateLiquidityRaids();
   UpdateEquityGuards();
   SyncClosedTrades();
   ManagePositions();
   if(IsNewBar()) RunPipeline();
   if(InpShowDashboard) UpdateDashboard();
}
//+------------------------------------------------------------------+
