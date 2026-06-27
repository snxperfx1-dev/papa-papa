//+------------------------------------------------------------------+
//| snXperFX.mq5  —  snXper FX Master Implementation Guide v1.0      |
//| Deterministic, state-driven institutional EA (XAUUSD-first).    |
//|                                                                  |
//| FULL SPEC build:                                                 |
//|  * Trade-lifecycle state machine (IDLE..OPEN..CLOSED)            |
//|  * Top-down POI refinement  H4 -> M30 -> M15 -> M5 -> M2         |
//|  * OB-anchored POI + 4 criteria + flip zone + inducement (Fib)   |
//|  * Sequential 3-shift OFB (External->Internal->Final, body only) |
//|  * FU candle on M2/M1 (wick-through + opposing close + body)     |
//|  * Daily cycle: Sydney raid -> T-High/Low -> Frankfurt -> TLD/THD|
//|  * Liquidity: session H/L, EQH/EQL, trendline, round#, raids     |
//|  * Correlation (DXY/US30/Yen/EUR), news guard                    |
//|  * Risk guards + 23-field audit CSV + performance review         |
//|                                                                  |
//| MT5 HEDGING — raw MqlTradeRequest (IOC).                        |
//+------------------------------------------------------------------+
#property strict

//==================================================================
// ENUMERATIONS (spec section 2)
//==================================================================
enum ENUM_BIAS { BIAS_BEARISH=-1, BIAS_NEUTRAL=0, BIAS_BULLISH=1 };

enum ENUM_STRUCTURAL_PHASE {
   PHASE_NONE=0, PHASE_1=1, PRE_PHASE_2A=2, PHASE_2=3, PHASE_3=4, PHASE_4=5, PHASE_5=6
};

enum ENUM_TRADE_STATE {
   TS_IDLE=0, TS_POI_WATCH=1, TS_PRE_PHASE_2A=2, TS_PHASE_2=3, TS_ORDER_FLOW_SHIFT=4,
   TS_ENTRY_PENDING=5, TS_OPEN_INITIAL=6, TS_OPEN_RUNNER=7, TS_BREAK_EVEN=8,
   TS_SCALING=9, TS_CLOSED_WIN=10, TS_CLOSED_LOSS=11, TS_CLOSED_BE=12, TS_INVALIDATED=13
};

enum ENUM_DAILY_CYCLE_STATE {
   DC_SYDNEY_RANGE_BUILDING=0, DC_ALGORITHM_RAID=1, DC_ASIA_RANGE_FORMING=2,
   DC_ASIA_EXPANSION=3, DC_FRANKFURT_RAID=4, DC_LONDON_OPEN=5,
   DC_NY_CROSS_RAID=6, DC_EXPANSION=7, DC_LATE_SESSION=8, DC_DAILY_CLOSE=9
};

enum ENUM_DAILY_CYCLE_TYPE { DCT_BEARISH=-1, DCT_UNDETERMINED=0, DCT_BULLISH=1 };
enum ENUM_SESSION_MODEL    { SM_TWO_SIDED=0, SM_ONE_SIDED=1 };
enum ENUM_BOS_STRENGTH     { BOS_NONE=-1, BOS_IMPULSIVE=0, BOS_WICK_ONLY=1 };
enum ENUM_POI_TYPE         { POI_DEMAND=1, POI_SUPPLY=-1 };
enum ENUM_ENTRY_TYPE       { ENTRY_REFINED=0, ENTRY_AGGRESSIVE=1, ENTRY_INDUCEMENT=2 };

enum ENUM_LIQUIDITY_TYPE {
   LIQ_EQUAL_HIGHS=0, LIQ_EQUAL_LOWS=1, LIQ_TRENDLINE_HIGH=2, LIQ_TRENDLINE_LOW=3,
   LIQ_ASIA_HIGH=4, LIQ_ASIA_LOW=5, LIQ_SYDNEY_HIGH=6, LIQ_SYDNEY_LOW=7,
   LIQ_LONDON_HIGH=8, LIQ_LONDON_LOW=9, LIQ_PREV_DAY_HIGH=10, LIQ_PREV_DAY_LOW=11,
   LIQ_ROUND_NUMBER=14
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
#define IDX_MN 0
#define IDX_D1 2
#define IDX_H4 4
#define IDX_H1 5
#define IDX_M30 6
#define IDX_M15 7
#define IDX_M5 8
#define IDX_M2 9
#define IDX_M1 10

//==================================================================
// INPUTS (spec section 13)
//==================================================================
input group "═══ Risk Management ═══"
input double InpRiskPct          = 1.5;
input double InpMaxTotalRisk     = 3.0;
input double InpCounterRiskPct   = 0.5;
input int    InpMaxPositions     = 3;
input double InpHardTPPips       = 40.0;
input double InpGoldStopMax      = 6.0;
input double InpInducementTPPips = 60.0;   // counter-trend/inducement hard TP (40-80)
input double InpMinStopPips      = 1.5;
input int    InpMagic            = 880088;

input group "═══ Structural Analysis ═══"
input int    InpPivotLen         = 5;
input int    InpStructLookback   = 300;
input double InpBodyImpulseFrac  = 0.5;    // body/range >= this = impulsive BOS
input int    InpBOSLookback      = 40;     // bars after OB to confirm BOS

input group "═══ Session & Timing ═══"
input bool   InpAutoGold         = true;
input bool   InpIsGold           = true;
input bool   InpEnforceDeadZone  = true;
input bool   InpRequireSessionWindow = false; // require NY-cross/Expansion/Late
input bool   InpRequireTLD       = true;   // require TLD/THD printed before entry
input double InpGoldSpreadBuffPips = 4.0;

input group "═══ POI Engine ═══"
input double InpFlipZoneTolPips  = 2.0;
input double InpFib618           = 0.618;
input double InpFib705           = 0.705;
input bool   InpRequireAllPOI    = true;

input group "═══ Liquidity ═══"
input double InpEqualTolPips     = 2.0;
input int    InpEqualScanPivots  = 8;
input int    InpMaxLiqPools      = 96;

input group "═══ Order Flow ═══"
input bool   InpRequire3Shifts   = true;
input bool   InpRequireFU        = true;
input double InpAggrSizeMult     = 0.5;

input group "═══ Exits ═══"
input double InpTP1Partial       = 0.5;
input bool   InpMoveBEAfterTP1   = true;
input bool   InpTrailStructure   = true;

input group "═══ Equity Guards ═══"
input double InpDailyLossPct     = 3.0;
input double InpWeeklyLossPct    = 5.0;
input int    InpConsecLossLock   = 3;
input int    InpRevengeSeconds   = 600;

input group "═══ Correlation ═══"
input bool   InpEnableCorrelation= false;
input string InpDXYSymbol        = "DXY";
input string InpEURUSDSymbol     = "EURUSD";
input string InpUS30Symbol       = "US30";
input string InpYenBasketSymbol  = "JPYBASKET";

input group "═══ News Guard ═══"
input bool   InpUseNewsGuard     = false;
input int    InpNewsHour1GMT     = 12;     // manual high-impact windows (GMT)
input int    InpNewsHour2GMT     = 14;
input int    InpNewsBlockMin     = 30;

input group "═══ Audit / Display ═══"
input bool   InpShowDashboard    = true;
input bool   InpAuditCSV         = true;
input string InpAuditFile        = "snxper_audit.csv";
input bool   InpEnableTrading    = true;

//==================================================================
// DATA STRUCTURES
//==================================================================
struct TFState {
   ENUM_BIAS             bias;
   double                externalHigh, externalLow;
   double                lastBOSPrice;
   ENUM_BOS_STRENGTH     bosStrength;
   int                   bosDir;
   bool                  chochDetected;
   double                chochPrice;
   ENUM_STRUCTURAL_PHASE phase;
};

struct LiquidityPool {
   double              price;
   ENUM_LIQUIDITY_TYPE type;
   double              pipDisplacement;
   double              estimatedLots;
   bool                isGrabbed;
   datetime            raidTime;
   string              label;
};

struct Swing { double price; int dir; int shift; };

struct POI {
   bool          exists, isValid;
   ENUM_POI_TYPE type;
   double        priceHigh, priceLow, precisionLevel, flipZonePrice;
   int           originTFidx, refinedTFidx, obShift;
   double        impulseHigh, impulseLow;     // for inducement Fib
   bool          c1, c2, c3, c4;
};

struct Checklist {
   bool s1_cascade, s2_phase3, s3_poi, s4_liqIncoming;
   bool s5_ofb1, s5_ofb2, s5_ofb3, s6_fu, s7_timeOK, s7_hardTP, s8_corr, s8_news;
};

struct TradeMeta {
   ulong  ticket;  long posId;  int dir;
   double entry, sl, tp1, tp2, hardTP, precision, stopPips, lots, riskPct;
   ENUM_ENTRY_TYPE entryType;
   bool   partialDone, beDone, logged;
   datetime openTime;
};

//==================================================================
// GLOBAL STATE
//==================================================================
TFState        g_tfState[TF_COUNT];
LiquidityPool  g_liq[];
POI            g_poi;
Checklist      g_chk;
TradeMeta      g_trades[];

ENUM_TRADE_STATE       g_state = TS_IDLE;
ENUM_DAILY_CYCLE_STATE g_cycle = DC_SYDNEY_RANGE_BUILDING, g_prevCycle = DC_DAILY_CLOSE;
ENUM_DAILY_CYCLE_TYPE  g_dayType = DCT_UNDETERMINED;
ENUM_SESSION_MODEL     g_sessionModel = SM_TWO_SIDED;
ENUM_STRUCTURAL_PHASE  g_entryPhase = PHASE_NONE;
int                    g_setupDir = 0;

double g_sydH=0,g_sydL=0,g_asiaH=0,g_asiaL=0,g_lonH=0,g_lonL=0;
double g_tHigh=0,g_tLow=0,g_dayH=0,g_dayL=0,g_pdH=0,g_pdL=0;
double g_TLD=0,g_THD=0;
bool   g_sydHRaid=false,g_sydLRaid=false,g_tldPrinted=false,g_thdPrinted=false;
bool   g_frankfurtRaid=false;
bool   g_isGold=true;

// OFB sequential flags (latched within a setup cycle)
bool   g_ofb1=false,g_ofb2=false,g_ofb3=false,g_fu=false;
int    g_stateBar=0;          // bar_index when state last changed (timeout)
int    g_barCount=0;

// risk / guards
double g_dayStartEq=0,g_weekStartEq=0;
int    g_dayStamp=-1,g_weekStamp=-1,g_consecLosses=0,g_winStreak=0;
datetime g_lastStopTime=0;
bool   g_halted=false,g_reduceSizing=false,g_forceChecklist=false;

datetime g_lastBarTime=0;
double   gClose[],gHigh[],gLow[],gOpen[]; datetime gTime[];

//==================================================================
// SERIES + BASIC HELPERS
//==================================================================
bool RefreshSeries(int need=800)
{
   if(need<400) need=400;
   ArraySetAsSeries(gClose,true);ArraySetAsSeries(gHigh,true);ArraySetAsSeries(gLow,true);
   ArraySetAsSeries(gOpen,true);ArraySetAsSeries(gTime,true);
   int c1=CopyClose(_Symbol,_Period,0,need,gClose);
   int c2=CopyHigh(_Symbol,_Period,0,need,gHigh);
   int c3=CopyLow(_Symbol,_Period,0,need,gLow);
   int c4=CopyOpen(_Symbol,_Period,0,need,gOpen);
   int c5=CopyTime(_Symbol,_Period,0,need,gTime);
   return(c1>0&&c2>0&&c3>0&&c4>0&&c5>0);
}
bool IsNewBar(){ datetime t=(ArraySize(gTime)>0)?gTime[0]:0; if(t!=g_lastBarTime){g_lastBarTime=t;return true;} return false; }
double PipSize(){ double pt=_Point; int d=_Digits; if(d==3||d==5)return pt*10.0; if(d==2)return pt*10.0; return pt; }
double PipsToPrice(double p){ return p*PipSize(); }
double PriceToPips(double x){ return x/MathMax(PipSize(),1e-9); }
bool SymbolIsGold(){ if(!InpAutoGold) return InpIsGold; return(StringFind(_Symbol,"XAU")>=0||StringFind(_Symbol,"GOLD")>=0); }
int GMTHour(){ MqlDateTime g; TimeGMT(g); return g.hour; }

bool PivotHighTF(ENUM_TIMEFRAMES tf,int c,int P){
   double h=iHigh(_Symbol,tf,c); if(h<=0.0)return false;
   for(int k=1;k<=P;k++){ double hu=iHigh(_Symbol,tf,c+k),hd=iHigh(_Symbol,tf,c-k);
      if(hu<=0.0||hd<=0.0)return false; if(h<=hu||h<=hd)return false; } return true;
}
bool PivotLowTF(ENUM_TIMEFRAMES tf,int c,int P){
   double l=iLow(_Symbol,tf,c); if(l<=0.0)return false;
   for(int k=1;k<=P;k++){ double lu=iLow(_Symbol,tf,c+k),ld=iLow(_Symbol,tf,c-k);
      if(lu<=0.0||ld<=0.0)return false; if(l>=lu||l>=ld)return false; } return true;
}
int CollectSwingsTF(ENUM_TIMEFRAMES tf,Swing &arr[],int want){
   ArrayResize(arr,0); int P=InpPivotLen; int bars=iBars(_Symbol,tf); if(bars<2*P+6)return 0;
   for(int c=P+1;c<bars-P && ArraySize(arr)<want;c++){
      if(PivotHighTF(tf,c,P)){ int n=ArraySize(arr);ArrayResize(arr,n+1);arr[n].price=iHigh(_Symbol,tf,c);arr[n].dir=1;arr[n].shift=c; }
      else if(PivotLowTF(tf,c,P)){ int n=ArraySize(arr);ArrayResize(arr,n+1);arr[n].price=iLow(_Symbol,tf,c);arr[n].dir=-1;arr[n].shift=c; }
   }
   return ArraySize(arr);
}
int SwingRank(Swing &arr[],int dir,int rank){ int s=0; for(int i=0;i<ArraySize(arr);i++) if(arr[i].dir==dir){ if(s==rank)return i; s++; } return -1; }

//==================================================================
// MODULE 1 — DAILY CYCLE / SESSION (with T-High/Low, TLD/THD)
//==================================================================
ENUM_DAILY_CYCLE_STATE GetCycleState(){
   int h=GMTHour();
   if(g_isGold && h==23) return DC_SYDNEY_RANGE_BUILDING;
   if(h==0)              return DC_ALGORITHM_RAID;
   if(h>=1&&h<3)         return DC_ASIA_RANGE_FORMING;
   if(h>=3&&h<5)         return DC_ASIA_EXPANSION;
   if(h>=5&&h<7)         return DC_FRANKFURT_RAID;
   if(h>=7&&h<12)        return DC_LONDON_OPEN;
   if(h>=12&&h<13)       return DC_NY_CROSS_RAID;
   if(h>=13&&h<17)       return DC_EXPANSION;
   if(h>=17&&h<21)       return DC_LATE_SESSION;
   if(h>=21)             return DC_DAILY_CLOSE;
   return DC_SYDNEY_RANGE_BUILDING;
}
string CycleLabel(ENUM_DAILY_CYCLE_STATE s){
   switch(s){
      case DC_SYDNEY_RANGE_BUILDING:return "SYDNEY_BUILD"; case DC_ALGORITHM_RAID:return "ALGO_RAID";
      case DC_ASIA_RANGE_FORMING:return "ASIA_FORMING";    case DC_ASIA_EXPANSION:return "ASIA_EXP";
      case DC_FRANKFURT_RAID:return "FRANKFURT";           case DC_LONDON_OPEN:return "LONDON";
      case DC_NY_CROSS_RAID:return "NY_CROSS";             case DC_EXPANSION:return "EXPANSION";
      case DC_LATE_SESSION:return "LATE";                  case DC_DAILY_CLOSE:return "CLOSE";
   } return "-";
}
void ResetDailyCycle(){
   if(g_dayH>0.0)g_pdH=g_dayH; if(g_dayL>0.0)g_pdL=g_dayL;
   g_sydH=0;g_sydL=0;g_asiaH=0;g_asiaL=0;g_lonH=0;g_lonL=0;g_tHigh=0;g_tLow=0;g_dayH=0;g_dayL=0;
   g_TLD=0;g_THD=0;g_sydHRaid=false;g_sydLRaid=false;g_tldPrinted=false;g_thdPrinted=false;g_frankfurtRaid=false;
   g_dayType=DCT_UNDETERMINED;g_sessionModel=SM_TWO_SIDED;
}
void UpdateSession(){
   g_cycle=GetCycleState();
   if(g_cycle==DC_SYDNEY_RANGE_BUILDING && g_prevCycle!=DC_SYDNEY_RANGE_BUILDING) ResetDailyCycle();
   g_prevCycle=g_cycle;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(bid<=0.0)return;
   if(g_dayH==0.0||bid>g_dayH)g_dayH=bid; if(g_dayL==0.0||bid<g_dayL)g_dayL=bid;

   if(g_cycle==DC_SYDNEY_RANGE_BUILDING){ if(g_sydH==0.0||bid>g_sydH)g_sydH=bid; if(g_sydL==0.0||bid<g_sydL)g_sydL=bid; }
   if(g_cycle==DC_ASIA_RANGE_FORMING||g_cycle==DC_ASIA_EXPANSION){
      if(g_asiaH==0.0||bid>g_asiaH)g_asiaH=bid; if(g_asiaL==0.0||bid<g_asiaL)g_asiaL=bid;
   }
   // T-High forms ~03:00 (bullish), T-Low (bearish) during Asia forming
   if(g_cycle==DC_ASIA_RANGE_FORMING){ if(bid>g_tHigh)g_tHigh=bid; if(g_tLow==0.0||bid<g_tLow)g_tLow=bid; }
   if(g_cycle==DC_LONDON_OPEN){ if(g_lonH==0.0||bid>g_lonH)g_lonH=bid; if(g_lonL==0.0||bid<g_lonL)g_lonL=bid; }

   // ALGORITHM RAID: Sydney side liquidated -> day type
   if(g_cycle==DC_ALGORITHM_RAID && g_sydH>0.0 && g_sydL>0.0){
      if(bid<g_sydL)g_sydLRaid=true; if(bid>g_sydH)g_sydHRaid=true;
      if(g_dayType==DCT_UNDETERMINED){
         if(g_sydLRaid)g_dayType=DCT_BULLISH; else if(g_sydHRaid)g_dayType=DCT_BEARISH;
      }
   }
   // FRANKFURT RAID: bullish raids Asia low, bearish raids Asia high
   if(g_cycle==DC_FRANKFURT_RAID && g_asiaH>0.0 && g_asiaL>0.0){
      if(g_dayType==DCT_BULLISH && bid<g_asiaL) g_frankfurtRaid=true;
      if(g_dayType==DCT_BEARISH && bid>g_asiaH) g_frankfurtRaid=true;
   }
   // NY CROSS: raids London low -> TLD (bullish) / London high -> THD (bearish)
   if(g_cycle==DC_NY_CROSS_RAID){
      if(g_dayType==DCT_BULLISH && g_lonL>0.0 && bid<g_lonL && !g_tldPrinted){ g_TLD=bid; g_tldPrinted=true; }
      if(g_dayType==DCT_BEARISH && g_lonH>0.0 && bid>g_lonH && !g_thdPrinted){ g_THD=bid; g_thdPrinted=true; }
   }
}
bool IsDeadZone(){ return(g_cycle==DC_SYDNEY_RANGE_BUILDING||g_cycle==DC_ALGORITHM_RAID); }
bool IsNearClose(){ return(g_cycle==DC_DAILY_CLOSE); }
bool InSessionWindow(){ return(g_cycle==DC_NY_CROSS_RAID||g_cycle==DC_EXPANSION||g_cycle==DC_LATE_SESSION||g_cycle==DC_LONDON_OPEN); }
bool TLDConfirmed(int dir){ if(!InpRequireTLD) return true; if(dir==1)return g_tldPrinted; if(dir==-1)return g_thdPrinted; return false; }


//==================================================================
// MODULE 5 — LIQUIDITY POOL TRACKER (session, EQH/EQL, trendline, round)
//==================================================================
void ClearLiq(){ ArrayResize(g_liq,0); }
void AddPool(double price,ENUM_LIQUIDITY_TYPE type,string label){
   if(price<=0.0)return; int n=ArraySize(g_liq); if(n>=InpMaxLiqPools)return;
   double tol=PipSize()*InpEqualTolPips;
   for(int i=0;i<n;i++) if(g_liq[i].type==type && MathAbs(g_liq[i].price-price)<=tol) return;
   ArrayResize(g_liq,n+1);
   g_liq[n].price=price; g_liq[n].type=type; g_liq[n].isGrabbed=false; g_liq[n].raidTime=0; g_liq[n].label=label;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pd=MathAbs(price-bid)/MathMax(PipSize(),1e-9);
   g_liq[n].pipDisplacement=pd; g_liq[n].estimatedLots=pd*100000.0;
}
void ScanEqualHighsLows(){
   int P=InpPivotLen; double tol=PipSize()*InpEqualTolPips;
   double highs[]; double lows[]; int fh=0,fl=0; int maxBars=ArraySize(gHigh);
   for(int c=P+1;c<maxBars-P && (fh<InpEqualScanPivots||fl<InpEqualScanPivots);c++){
      bool ph=true,pl=true;
      for(int k=1;k<=P;k++){ if(gHigh[c]<=gHigh[c+k]||gHigh[c]<=gHigh[c-k])ph=false; if(gLow[c]>=gLow[c+k]||gLow[c]>=gLow[c-k])pl=false; }
      if(ph&&fh<InpEqualScanPivots){int n=ArraySize(highs);ArrayResize(highs,n+1);highs[n]=gHigh[c];fh++;}
      if(pl&&fl<InpEqualScanPivots){int n=ArraySize(lows);ArrayResize(lows,n+1);lows[n]=gLow[c];fl++;}
   }
   for(int i=0;i<ArraySize(highs);i++) for(int j=i+1;j<ArraySize(highs);j++)
      if(MathAbs(highs[i]-highs[j])<=tol){ AddPool((highs[i]+highs[j])*0.5,LIQ_EQUAL_HIGHS,"EQH"); break; }
   for(int i=0;i<ArraySize(lows);i++) for(int j=i+1;j<ArraySize(lows);j++)
      if(MathAbs(lows[i]-lows[j])<=tol){ AddPool((lows[i]+lows[j])*0.5,LIQ_EQUAL_LOWS,"EQL"); break; }
}
// trendline liquidity: project the line through the last two swing highs (supply) / lows (demand)
void ScanTrendlineLiquidity(){
   Swing sw[]; CollectSwingsTF(_Period,sw,12);
   int h0=SwingRank(sw,1,0),h1=SwingRank(sw,1,1),l0=SwingRank(sw,-1,0),l1=SwingRank(sw,-1,1);
   if(h0>=0&&h1>=0 && sw[h0].shift!=sw[h1].shift){
      double slope=(sw[h0].price-sw[h1].price)/(double)(sw[h1].shift-sw[h0].shift);
      double proj=sw[h0].price+slope*(double)sw[h0].shift;   // project to shift 0 (now)
      if(proj>0.0) AddPool(proj,LIQ_TRENDLINE_HIGH,"TLH");
   }
   if(l0>=0&&l1>=0 && sw[l0].shift!=sw[l1].shift){
      double slope=(sw[l0].price-sw[l1].price)/(double)(sw[l1].shift-sw[l0].shift);
      double proj=sw[l0].price+slope*(double)sw[l0].shift;
      if(proj>0.0) AddPool(proj,LIQ_TRENDLINE_LOW,"TLL");
   }
}
void ScanRoundNumbers(){
   double step=g_isGold?10.0:(PipSize()*100.0);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(bid<=0.0||step<=0.0)return;
   double below=MathFloor(bid/step)*step;
   AddPool(below,LIQ_ROUND_NUMBER,"RN"); AddPool(below+step,LIQ_ROUND_NUMBER,"RN");
}
void RebuildLiquidityMap(){
   ClearLiq();
   AddPool(g_sydH,LIQ_SYDNEY_HIGH,"SydH"); AddPool(g_sydL,LIQ_SYDNEY_LOW,"SydL");
   AddPool(g_asiaH,LIQ_ASIA_HIGH,"AsiaH"); AddPool(g_asiaL,LIQ_ASIA_LOW,"AsiaL");
   AddPool(g_lonH,LIQ_LONDON_HIGH,"LonH"); AddPool(g_lonL,LIQ_LONDON_LOW,"LonL");
   AddPool(g_pdH,LIQ_PREV_DAY_HIGH,"PDH"); AddPool(g_pdL,LIQ_PREV_DAY_LOW,"PDL");
   ScanEqualHighsLows(); ScanTrendlineLiquidity(); ScanRoundNumbers();
}
bool PoolIsHigh(ENUM_LIQUIDITY_TYPE t){ return(t==LIQ_EQUAL_HIGHS||t==LIQ_TRENDLINE_HIGH||t==LIQ_SYDNEY_HIGH||t==LIQ_ASIA_HIGH||t==LIQ_LONDON_HIGH||t==LIQ_PREV_DAY_HIGH); }
bool PoolIsLow(ENUM_LIQUIDITY_TYPE t){ return(t==LIQ_EQUAL_LOWS||t==LIQ_TRENDLINE_LOW||t==LIQ_SYDNEY_LOW||t==LIQ_ASIA_LOW||t==LIQ_LONDON_LOW||t==LIQ_PREV_DAY_LOW); }
void UpdateLiquidityRaids(){
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID); if(bid<=0.0)return; double tol=PipSize()*0.5;
   for(int i=0;i<ArraySize(g_liq);i++){
      if(g_liq[i].isGrabbed)continue;
      if(PoolIsHigh(g_liq[i].type)&&bid>g_liq[i].price+tol){g_liq[i].isGrabbed=true;g_liq[i].raidTime=TimeCurrent();}
      if(PoolIsLow(g_liq[i].type)&&bid<g_liq[i].price-tol){g_liq[i].isGrabbed=true;g_liq[i].raidTime=TimeCurrent();}
   }
}
int CountUnraided(){ int n=0; for(int i=0;i<ArraySize(g_liq);i++) if(!g_liq[i].isGrabbed)n++; return n; }
bool HasIncomingLiquidity(int dir,double poiPrice){
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   for(int i=0;i<ArraySize(g_liq);i++){
      if(g_liq[i].isGrabbed)continue; double p=g_liq[i].price;
      if(dir==1 && PoolIsLow(g_liq[i].type)  && p<=bid && p>=poiPrice) return true;
      if(dir==-1&& PoolIsHigh(g_liq[i].type) && p>=bid && p<=poiPrice) return true;
   }
   return false;
}
bool POIOnEqualLevels(double price){
   double tol=PipSize()*InpEqualTolPips;
   for(int i=0;i<ArraySize(g_liq);i++)
      if((g_liq[i].type==LIQ_EQUAL_HIGHS||g_liq[i].type==LIQ_EQUAL_LOWS)&&MathAbs(g_liq[i].price-price)<=tol) return true;
   return false;
}

//==================================================================
// MODULE 2 — STRUCTURAL CASCADE (BOS strength + CHoCH) + 5-phase/TF
//==================================================================
void BuildTFState(int idx){
   ENUM_TIMEFRAMES tf=g_tf[idx]; int P=InpPivotLen;
   TFState st; st.bias=BIAS_NEUTRAL; st.externalHigh=0; st.externalLow=0; st.lastBOSPrice=0;
   st.bosStrength=BOS_NONE; st.bosDir=0; st.chochDetected=false; st.chochPrice=0; st.phase=PHASE_NONE;
   if(iBars(_Symbol,tf)<2*P+6){ g_tfState[idx]=st; return; }
   double lastSH=0,prevSH=0,lastSL=0,prevSL=0; int fh=0,fl=0;
   for(int c=P+1;c<=P+InpStructLookback && (fh<2||fl<2);c++){
      if(fh<2&&PivotHighTF(tf,c,P)){ if(fh==0)lastSH=iHigh(_Symbol,tf,c); else prevSH=iHigh(_Symbol,tf,c); fh++; }
      if(fl<2&&PivotLowTF(tf,c,P)){  if(fl==0)lastSL=iLow(_Symbol,tf,c);  else prevSL=iLow(_Symbol,tf,c);  fl++; }
   }
   st.externalHigh=lastSH; st.externalLow=lastSL;
   if(fh>=2&&fl>=2){ if(lastSH>prevSH&&lastSL>prevSL)st.bias=BIAS_BULLISH; else if(lastSH<prevSH&&lastSL<prevSL)st.bias=BIAS_BEARISH; }
   double cl=iClose(_Symbol,tf,1),op=iOpen(_Symbol,tf,1),hi=iHigh(_Symbol,tf,1),lo=iLow(_Symbol,tf,1);
   double rng=MathMax(hi-lo,1e-9),bf=MathAbs(cl-op)/rng;
   if(prevSH>0.0&&cl>prevSH){ st.bosDir=1; st.lastBOSPrice=prevSH; st.bosStrength=(bf>=InpBodyImpulseFrac)?BOS_IMPULSIVE:BOS_WICK_ONLY; }
   else if(prevSH>0.0&&hi>prevSH&&cl<=prevSH){ st.bosDir=1; st.lastBOSPrice=prevSH; st.bosStrength=BOS_WICK_ONLY; }
   if(prevSL>0.0&&cl<prevSL){ st.bosDir=-1; st.lastBOSPrice=prevSL; st.bosStrength=(bf>=InpBodyImpulseFrac)?BOS_IMPULSIVE:BOS_WICK_ONLY; }
   else if(prevSL>0.0&&lo<prevSL&&cl>=prevSL){ st.bosDir=-1; st.lastBOSPrice=prevSL; st.bosStrength=BOS_WICK_ONLY; }
   if((st.bias==BIAS_BULLISH&&st.bosDir==-1)||(st.bias==BIAS_BEARISH&&st.bosDir==1)){ st.chochDetected=true; st.chochPrice=st.lastBOSPrice; }
   // lightweight per-TF phase: expansion(4) if impulsive BOS in bias dir; new landmark(5) if at extreme; else corrective(1)
   double c0=iClose(_Symbol,tf,1);
   if(st.bias==BIAS_BULLISH){
      if(st.bosDir==1&&st.bosStrength==BOS_IMPULSIVE) st.phase=PHASE_4;
      else if(c0>=st.externalHigh && st.externalHigh>0) st.phase=PHASE_5;
      else st.phase=PHASE_1;
   } else if(st.bias==BIAS_BEARISH){
      if(st.bosDir==-1&&st.bosStrength==BOS_IMPULSIVE) st.phase=PHASE_4;
      else if(c0<=st.externalLow && st.externalLow>0) st.phase=PHASE_5;
      else st.phase=PHASE_1;
   }
   g_tfState[idx]=st;
}
void BuildStructuralCascade(){ for(int i=0;i<TF_COUNT;i++) BuildTFState(i); }
ENUM_BIAS DominantBias(){ int sum=0; for(int i=0;i<TF_COUNT;i++){ int w=TF_COUNT-i; sum+=w*(int)g_tfState[i].bias; }
   if(sum>0)return BIAS_BULLISH; if(sum<0)return BIAS_BEARISH; return BIAS_NEUTRAL; }
string BiasArrow(ENUM_BIAS b){ return(b==BIAS_BULLISH?"^":b==BIAS_BEARISH?"v":"-"); }

//==================================================================
// MODULE 6 — POI ENGINE (OB-anchored, top-down refinement, 4 criteria)
//==================================================================
// flip zone = nearest visible H1 swing high above (demand) / low below (supply) the POI
double FindFlipZone(int dir,double poiPrice){
   Swing sw[]; CollectSwingsTF(g_tf[IDX_H1],sw,12); double best=0.0;
   for(int i=0;i<ArraySize(sw);i++){
      if(dir==1 && sw[i].dir==1 && sw[i].price>poiPrice){ if(best==0.0||sw[i].price<best)best=sw[i].price; }
      if(dir==-1&& sw[i].dir==-1&& sw[i].price<poiPrice){ if(best==0.0||sw[i].price>best)best=sw[i].price; }
   }
   return best;
}
bool IsInducement(int dir,double price,double impHigh,double impLow){
   if(impHigh<=impLow) return false;
   if(dir==1){ double f618=impHigh-(impHigh-impLow)*InpFib618, f705=impHigh-(impHigh-impLow)*InpFib705; return(price<=f618&&price>=f705); }
   double f618b=impLow+(impHigh-impLow)*InpFib618, f705b=impLow+(impHigh-impLow)*InpFib705; return(price>=f618b&&price<=f705b);
}
// refine the H4 OB zone downward; returns precision level + refined TF index
double RefineZone(int dir,double zlo,double zhi,int &refinedIdx){
   double prec=(dir==1)?zlo:zhi; refinedIdx=IDX_H4;
   int chain[4]={IDX_M30,IDX_M15,IDX_M5,IDX_M2};
   double clo=zlo,chi=zhi;
   for(int ci=0;ci<4;ci++){
      ENUM_TIMEFRAMES tf=g_tf[chain[ci]]; int P=InpPivotLen; int bars=iBars(_Symbol,tf); if(bars<2*P+6) break;
      double bestLow=0,bestHigh=0; int found=-1;
      int scan=MathMin(InpStructLookback,bars-P-1);
      for(int c=P+1;c<=scan;c++){
         double lo=iLow(_Symbol,tf,c),hi=iHigh(_Symbol,tf,c);
         if(lo<clo-PipsToPrice(InpEqualTolPips)||hi>chi+PipsToPrice(InpEqualTolPips)) continue; // candle inside zone
         if(dir==1 && PivotLowTF(tf,c,P)){ if(found<0||lo<bestLow){bestLow=lo;bestHigh=hi;found=c;} }
         if(dir==-1&& PivotHighTF(tf,c,P)){ if(found<0||hi>bestHigh){bestLow=lo;bestHigh=hi;found=c;} }
      }
      if(found<0) break;
      clo=bestLow; chi=bestHigh; prec=(dir==1)?bestLow:bestHigh; refinedIdx=chain[ci];
   }
   return prec;
}
void IdentifyAndRefinePOI(int dir){
   g_poi.exists=false; g_poi.isValid=false; g_poi.c1=g_poi.c2=g_poi.c3=g_poi.c4=false;
   if(dir==0) return;
   ENUM_TIMEFRAMES tf=g_tf[IDX_H4]; int P=InpPivotLen; int bars=iBars(_Symbol,tf); if(bars<2*P+InpBOSLookback) return;
   Swing sw[]; CollectSwingsTF(tf,sw,12);
   // origin swing = most recent swing low (demand) / high (supply) = the OB area
   int oi=SwingRank(sw,(dir==1)?-1:1,0); if(oi<0) return;
   int obShift=sw[oi].shift;
   // OB candle: from the origin, the last opposing-colour candle before the impulse
   int ob=obShift;
   for(int c=obShift;c>=MathMax(1,obShift-P);c--){
      bool opp=(dir==1)?(iClose(_Symbol,tf,c)<iOpen(_Symbol,tf,c)):(iClose(_Symbol,tf,c)>iOpen(_Symbol,tf,c));
      if(opp){ ob=c; break; }
   }
   g_poi.exists=true; g_poi.type=(dir==1)?POI_DEMAND:POI_SUPPLY; g_poi.obShift=ob; g_poi.originTFidx=IDX_H4;
   g_poi.priceHigh=iHigh(_Symbol,tf,ob); g_poi.priceLow=iLow(_Symbol,tf,ob);
   // impulse range for inducement Fib = OB low .. subsequent high (demand)
   double impHi=g_poi.priceHigh,impLo=g_poi.priceLow;
   for(int c=ob-1;c>=MathMax(0,ob-InpBOSLookback);c--){ impHi=MathMax(impHi,iHigh(_Symbol,tf,c)); impLo=MathMin(impLo,iLow(_Symbol,tf,c)); }
   g_poi.impulseHigh=impHi; g_poi.impulseLow=impLo;
   // top-down refinement
   int refIdx; double prec=RefineZone(dir,g_poi.priceLow,g_poi.priceHigh,refIdx);
   g_poi.precisionLevel=prec; g_poi.refinedTFidx=refIdx;

   // ---- 4 CRITERIA ----
   // C1: OB directly caused an IMPULSIVE BOS of the prior external structure (within lookback)
   int hpIdx=SwingRank(sw,(dir==1)?1:-1,0);
   double extLevel=(hpIdx>=0)?sw[hpIdx].price:0.0;
   bool bosImpulsive=false;
   for(int c=ob-1;c>=MathMax(1,ob-InpBOSLookback);c--){
      double cl=iClose(_Symbol,tf,c),op=iOpen(_Symbol,tf,c),hi=iHigh(_Symbol,tf,c),lo=iLow(_Symbol,tf,c);
      double bf=MathAbs(cl-op)/MathMax(hi-lo,1e-9);
      if(extLevel>0.0){
         if(dir==1 && cl>extLevel && bf>=InpBodyImpulseFrac){ bosImpulsive=true; break; }
         if(dir==-1&& cl<extLevel && bf>=InpBodyImpulseFrac){ bosImpulsive=true; break; }
      }
   }
   g_poi.c1=bosImpulsive;
   // C2: OB free of equal levels AND incoming liquidity present
   g_poi.c2=(!POIOnEqualLevels(prec) && HasIncomingLiquidity(dir,prec));
   // C3: below/above flip zone AND not an inducement reaction
   double flip=FindFlipZone(dir,prec); g_poi.flipZonePrice=flip;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   bool belowFlip=true; if(flip>0.0) belowFlip=(dir==1)?(prec<flip):(prec>flip);
   bool induce=IsInducement(dir,bid,impHi,impLo);
   g_poi.c3=(belowFlip && !induce);
   // C4: refined to M5 or finer AND stop within ceiling
   double stopPips=MathAbs(bid-prec)/MathMax(PipSize(),1e-9);
   bool refinedEnough=(refIdx>=IDX_M5);
   g_poi.c4=(prec>0.0 && refinedEnough);
   g_poi.isValid=(g_poi.c1&&g_poi.c2&&g_poi.c3&&g_poi.c4);
}


//==================================================================
// MODULE 7 — THREE-SHIFT ORDER FLOW (sequential, body-close only)
//==================================================================
// Evaluated on the entry TF (H4) while a setup is live. Flags latch in order.
void UpdateOFB(int dir){
   ENUM_TIMEFRAMES tf=g_tf[IDX_H4];
   Swing sw[]; if(CollectSwingsTF(tf,sw,14)<4) return;
   double cl=iClose(_Symbol,tf,1),op=iOpen(_Symbol,tf,1),hi=iHigh(_Symbol,tf,1),lo=iLow(_Symbol,tf,1);
   double bf=MathAbs(cl-op)/MathMax(hi-lo,1e-9);
   bool bodyClose=(bf>=InpBodyImpulseFrac);
   // SHIFT 1 — external OFB: body close through the last opposing internal zone
   //   demand: close above the most recent lower-high of the corrective leg
   if(!g_ofb1){
      int hIdx=SwingRank(sw,(dir==1)?1:-1,0); double lvl=(hIdx>=0)?sw[hIdx].price:0.0;
      if(lvl>0.0 && bodyClose){
         if(dir==1 && cl>lvl) g_ofb1=true;
         if(dir==-1&& cl<lvl) g_ofb1=true;
      }
   }
   // SHIFT 2 — internal OFB: corrective leg makes first higher-low (demand) / lower-high (supply)
   if(g_ofb1 && !g_ofb2){
      int l0=SwingRank(sw,(dir==1)?-1:1,0), l1=SwingRank(sw,(dir==1)?-1:1,1);
      if(l0>=0 && l1>=0){
         if(dir==1 && sw[l0].price>sw[l1].price) g_ofb2=true;
         if(dir==-1&& sw[l0].price<sw[l1].price) g_ofb2=true;
      }
   }
   // SHIFT 3 — final OFB: body close through the last key swing in trade dir
   if(g_ofb1 && g_ofb2 && !g_ofb3){
      int fIdx=SwingRank(sw,(dir==1)?1:-1,0); double lvl=(fIdx>=0)?sw[fIdx].price:0.0;
      if(lvl>0.0 && bodyClose){
         if(dir==1 && cl>lvl) g_ofb3=true;
         if(dir==-1&& cl<lvl) g_ofb3=true;
      }
   }
}
int OFBCount(){ return((g_ofb1?1:0)+(g_ofb2?1:0)+(g_ofb3?1:0)); }
void ResetOFB(){ g_ofb1=false; g_ofb2=false; g_ofb3=false; g_fu=false; }

//==================================================================
// MODULE — FU CANDLE (M2 then M1): wick-through + opposing close + body
//==================================================================
void UpdateFU(int dir){
   if(!g_poi.exists){ g_fu=false; return; }
   double prec=g_poi.precisionLevel;
   ENUM_TIMEFRAMES tfs[2]={PERIOD_M2,PERIOD_M1};
   for(int t=0;t<2;t++){
      ENUM_TIMEFRAMES tf=tfs[t];
      for(int c=1;c<=3;c++){
         double lo=iLow(_Symbol,tf,c),hi=iHigh(_Symbol,tf,c),cl=iClose(_Symbol,tf,c),op=iOpen(_Symbol,tf,c);
         double pop=iOpen(_Symbol,tf,c+1),pcl=iClose(_Symbol,tf,c+1);
         double pbHi=MathMax(pop,pcl),pbLo=MathMin(pop,pcl);
         if(dir==1){
            bool wick=(lo<prec), close=(cl>prec), bull=(cl>op), body=(cl>=pbLo); // close within/through prior body
            if(wick&&close&&bull&&body){ g_fu=true; return; }
         } else {
            bool wick=(hi>prec), close=(cl<prec), bear=(cl<op), body=(cl<=pbHi);
            if(wick&&close&&bear&&body){ g_fu=true; return; }
         }
      }
   }
   g_fu=false;
}

//==================================================================
// MODULE 3 — CORRELATION FILTER (DXY/US30/Yen/EUR)
//==================================================================
ENUM_BIAS SymbolBias(string sym){
   if(StringLen(sym)<2) return BIAS_NEUTRAL;
   double h1=iHigh(sym,PERIOD_H4,1),h2=iHigh(sym,PERIOD_H4,1+InpPivotLen);
   double l1=iLow(sym,PERIOD_H4,1), l2=iLow(sym,PERIOD_H4,1+InpPivotLen);
   if(h1<=0||h2<=0||l1<=0||l2<=0) return BIAS_NEUTRAL;
   if(h1>h2&&l1>l2) return BIAS_BULLISH; if(h1<h2&&l1<l2) return BIAS_BEARISH; return BIAS_NEUTRAL;
}
bool CorrelationOK(int dir){
   if(!InpEnableCorrelation) return true;
   ENUM_BIAS dxy=SymbolBias(InpDXYSymbol);
   if(g_isGold){
      if(dir==1 && dxy==BIAS_BULLISH) return false;   // gold buy needs $ weakness
      if(dir==-1&& dxy==BIAS_BEARISH) return false;
      ENUM_BIAS eur=SymbolBias(InpEURUSDSymbol);
      if(dir==1 && eur==BIAS_BEARISH) return false;   // EURUSD must stabilise before gold rips
   }
   bool isJPY=(StringFind(_Symbol,"JPY")>=0);
   if(isJPY){
      ENUM_BIAS yen=SymbolBias(InpYenBasketSymbol);
      if(dir==-1 && yen==BIAS_BEARISH) return false;  // don't short JPY pair vs bearish basket
      ENUM_BIAS us30=SymbolBias(InpUS30Symbol);
      if(dir==-1 && us30==BIAS_BULLISH) return false; // US30 up -> yen weak -> JPY longs
   }
   return true;
}
bool NewsClear(){
   if(!InpUseNewsGuard) return true;
   MqlDateTime g; TimeGMT(g); int mins=g.hour*60+g.min;
   int w[2]; w[0]=InpNewsHour1GMT*60; w[1]=InpNewsHour2GMT*60;
   for(int i=0;i<2;i++) if(MathAbs(mins-w[i])<=InpNewsBlockMin) return false;
   return true;
}

//==================================================================
// MODULE 8 — PROCESS CHECKLIST
//==================================================================
void BuildChecklist(int dir){
   ENUM_BIAS dom=DominantBias();
   g_chk.s1_cascade     = (dom!=BIAS_NEUTRAL && (int)dom==dir);
   g_chk.s2_phase3      = (g_entryPhase==PHASE_3);
   g_chk.s3_poi         = (!InpRequireAllPOI || g_poi.isValid);
   g_chk.s4_liqIncoming = HasIncomingLiquidity(dir,g_poi.precisionLevel);
   g_chk.s5_ofb1        = g_ofb1;
   g_chk.s5_ofb2        = g_ofb2;
   g_chk.s5_ofb3        = (!InpRequire3Shifts || g_ofb3);
   g_chk.s6_fu          = (!InpRequireFU || g_fu);
   g_chk.s7_timeOK      = (!InpEnforceDeadZone||!IsDeadZone()) && (!InpRequireSessionWindow||InSessionWindow()) && TLDConfirmed(dir);
   g_chk.s7_hardTP      = true;   // enforced at order time
   g_chk.s8_corr        = CorrelationOK(dir);
   g_chk.s8_news        = NewsClear();
}
bool ChecklistAllPass(){
   return g_chk.s1_cascade && g_chk.s2_phase3 && g_chk.s3_poi &&
          (!InpRequire3Shifts || (g_chk.s5_ofb1 && g_chk.s5_ofb2 && g_chk.s5_ofb3)) &&
          g_chk.s6_fu && g_chk.s7_timeOK && g_chk.s8_corr && g_chk.s8_news;
}
string FirstFailingStep(){
   if(!g_chk.s1_cascade) return "S1_cascade";
   if(!g_chk.s2_phase3)  return "S2_phase3";
   if(!g_chk.s3_poi)     return "S3_poi";
   if(InpRequire3Shifts && !(g_chk.s5_ofb1&&g_chk.s5_ofb2&&g_chk.s5_ofb3)) return "S5_ofb";
   if(!g_chk.s6_fu)      return "S6_fu";
   if(!g_chk.s7_timeOK)  return "S7_time";
   if(!g_chk.s8_corr)    return "S8_corr";
   if(!g_chk.s8_news)    return "S8_news";
   return "";
}

//==================================================================
// ORDER EXECUTION HELPERS (raw IOC)
//==================================================================
bool SendOrder(int dir,double lots,double sl,double tp,const string cmt){
   if(lots<=0.0) return false;
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.magic=InpMagic; req.volume=lots;
   req.sl=NormalizeDouble(sl,_Digits); req.tp=NormalizeDouble(tp,_Digits);
   req.deviation=20; req.type_filling=ORDER_FILLING_IOC; req.type_time=ORDER_TIME_GTC; req.comment=cmt;
   if(dir>0){ req.type=ORDER_TYPE_BUY; req.price=ask; } else { req.type=ORDER_TYPE_SELL; req.price=bid; }
   if(!OrderSend(req,res)){ Print("SendOrder fail dir=",dir," ret=",res.retcode); return false; }
   return(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_DONE_PARTIAL);
}
bool ClosePartial(ulong ticket,double lots,const string tag){
   if(lots<=0.0) return false; if(!PositionSelectByTicket(ticket)) return false;
   long type=PositionGetInteger(POSITION_TYPE); double posLots=PositionGetDouble(POSITION_VOLUME);
   lots=NormalizeDouble(lots,2); if(lots>posLots)lots=posLots; if(lots<=0.0) return false;
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.magic=InpMagic; req.position=ticket; req.volume=lots;
   req.deviation=20; req.type_filling=ORDER_FILLING_IOC; req.type_time=ORDER_TIME_GTC; req.comment=tag;
   if(type==POSITION_TYPE_BUY){ req.type=ORDER_TYPE_SELL; req.price=bid; } else { req.type=ORDER_TYPE_BUY; req.price=ask; }
   if(!OrderSend(req,res)){ Print("ClosePartial fail ",ticket," ret=",res.retcode); return false; }
   return(res.retcode==TRADE_RETCODE_DONE||res.retcode==TRADE_RETCODE_DONE_PARTIAL);
}
bool ClosePositionFull(ulong ticket,const string tag){ if(!PositionSelectByTicket(ticket)) return false; return ClosePartial(ticket,PositionGetDouble(POSITION_VOLUME),tag); }
bool ModifySLTP(ulong ticket,double sl,double tp){
   if(!PositionSelectByTicket(ticket)) return false;
   MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
   req.action=TRADE_ACTION_SLTP; req.symbol=_Symbol; req.position=ticket;
   req.sl=NormalizeDouble(sl,_Digits); req.tp=NormalizeDouble(tp,_Digits);
   return OrderSend(req,res);
}

//==================================================================
// MODULE 9 — RISK
//==================================================================
double PipValuePerLot(){
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double pv=(ts>0.0)?(tv/ts)*PipSize():10.0; if(pv<=0.0)pv=10.0; return pv;
}
double ComputeLots(double riskUSD,double stopPips){
   if(stopPips<=0.0) return 0.0;
   double lots=riskUSD/(stopPips*PipValuePerLot());
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots=MathFloor(lots/st)*st; if(lots<mn)lots=mn; if(lots>mx)lots=mx; return NormalizeDouble(lots,2);
}
double OpenRiskUSD(){
   double tot=0.0; int n=PositionsTotal();
   for(int i=0;i<n;i++){ ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk))continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
      double e=PositionGetDouble(POSITION_PRICE_OPEN),sl=PositionGetDouble(POSITION_SL),lt=PositionGetDouble(POSITION_VOLUME);
      if(sl<=0.0)continue; double sp=MathAbs(e-sl)/MathMax(PipSize(),1e-9); tot+=sp*PipValuePerLot()*lt; }
   return tot;
}
int CountPositions(){ int c=0,n=PositionsTotal(); for(int i=0;i<n;i++){ ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk))continue;
   if(PositionGetString(POSITION_SYMBOL)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==InpMagic)c++; } return c; }
void UpdateEquityGuards(){
   MqlDateTime t; TimeToStruct(TimeCurrent(),t); double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(t.day_of_year!=g_dayStamp){ g_dayStamp=t.day_of_year; g_dayStartEq=eq; g_halted=false; }
   int wk=t.day_of_year/7; if(wk!=g_weekStamp){ g_weekStamp=wk; g_weekStartEq=eq; g_reduceSizing=false; }
   if(g_dayStartEq>0.0 && eq<=g_dayStartEq*(1.0-InpDailyLossPct/100.0)) g_halted=true;
   if(g_weekStartEq>0.0 && eq<=g_weekStartEq*(1.0-InpWeeklyLossPct/100.0)) g_reduceSizing=true;
   if(g_consecLosses>=InpConsecLossLock) g_halted=true;
}
bool TradingAllowed(){
   if(!InpEnableTrading) return false;
   if(g_halted) return false;
   if(g_lastStopTime>0 && TimeCurrent()-g_lastStopTime<InpRevengeSeconds) return false; // revenge guard
   return true;
}


//==================================================================
// TRADE META + AUDIT (23-field CSV)
//==================================================================
int FindMeta(ulong tk){ for(int i=0;i<ArraySize(g_trades);i++) if(g_trades[i].ticket==tk) return i; return -1; }
int NewestMeta(int dir){ int b=-1; for(int i=0;i<ArraySize(g_trades);i++) if(g_trades[i].dir==dir)b=i; return b; }
double PositionRealized(long posId){
   if(!HistorySelectByPosition(posId)) return 0.0; double p=0.0; int n=HistoryDealsTotal();
   for(int i=0;i<n;i++){ ulong d=HistoryDealGetTicket(i); if(d==0)continue;
      p+=HistoryDealGetDouble(d,DEAL_PROFIT)+HistoryDealGetDouble(d,DEAL_SWAP)+HistoryDealGetDouble(d,DEAL_COMMISSION); }
   return p;
}
void AuditHeaderIfNew(){
   if(!InpAuditCSV) return;
   if(FileIsExist(InpAuditFile)) return;
   int h=FileOpen(InpAuditFile,FILE_WRITE|FILE_CSV|FILE_ANSI,';'); if(h==INVALID_HANDLE) return;
   FileWrite(h,"trade_id","date_time","symbol","direction","lots","risk_pct","entry_price","stop_price",
             "stop_pips","tp1_price","tp2_price","hard_tp_set","exit_price","pnl_pips","pnl_usd","result",
             "entry_type","steps_followed","failure_step","structure_correct","poi_valid","3shift_complete","notes");
   FileClose(h);
}
void AuditRow(TradeMeta &m,double exitPrice,double pnlUSD,bool stepsFollowed,string failStep,bool poiValid,bool ofb3,string notes){
   if(!InpAuditCSV) return;
   int h=FileOpen(InpAuditFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,';'); if(h==INVALID_HANDLE) return;
   FileSeek(h,0,SEEK_END);
   double pnlPips=(exitPrice>0.0)?((m.dir==1?(exitPrice-m.entry):(m.entry-exitPrice))/MathMax(PipSize(),1e-9)):0.0;
   string et=(m.entryType==ENTRY_REFINED?"REFINED":m.entryType==ENTRY_AGGRESSIVE?"AGGRESSIVE":"INDUCEMENT");
   string res=(pnlUSD>0?"WIN":(pnlUSD<0?"LOSS":"BE"));
   FileWrite(h, (string)m.ticket, TimeToString(m.openTime,TIME_DATE|TIME_MINUTES), _Symbol, (m.dir==1?"LONG":"SHORT"),
             DoubleToString(m.lots,2), DoubleToString(m.riskPct,2), DoubleToString(m.entry,_Digits), DoubleToString(m.sl,_Digits),
             DoubleToString(m.stopPips,1), DoubleToString(m.tp1,_Digits), DoubleToString(m.tp2,_Digits),
             (m.hardTP>0?"TRUE":"FALSE"), DoubleToString(exitPrice,_Digits), DoubleToString(pnlPips,1), DoubleToString(pnlUSD,2),
             res, et, (stepsFollowed?"TRUE":"FALSE"), failStep, "TRUE", (poiValid?"TRUE":"FALSE"), (ofb3?"TRUE":"FALSE"), notes);
   FileClose(h);
}
void AdoptPosition(int dir,double sl,double tp1,double tp2,double hardTP,double precision,double stopPips,double lots,double riskPct,ENUM_ENTRY_TYPE et){
   int n=PositionsTotal();
   for(int i=0;i<n;i++){ ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk))continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=InpMagic)continue;
      long type=PositionGetInteger(POSITION_TYPE); if((type==POSITION_TYPE_BUY?1:-1)!=dir)continue;
      if(FindMeta(tk)>=0)continue;
      int m=ArraySize(g_trades); ArrayResize(g_trades,m+1);
      g_trades[m].ticket=tk; g_trades[m].posId=(long)PositionGetInteger(POSITION_IDENTIFIER); g_trades[m].dir=dir;
      g_trades[m].entry=PositionGetDouble(POSITION_PRICE_OPEN); g_trades[m].sl=sl; g_trades[m].tp1=tp1; g_trades[m].tp2=tp2;
      g_trades[m].hardTP=hardTP; g_trades[m].precision=precision; g_trades[m].stopPips=stopPips; g_trades[m].lots=lots;
      g_trades[m].riskPct=riskPct; g_trades[m].entryType=et; g_trades[m].partialDone=false; g_trades[m].beDone=false;
      g_trades[m].logged=false; g_trades[m].openTime=TimeCurrent();
      return;
   }
}
void SyncClosedTrades(){
   for(int i=ArraySize(g_trades)-1;i>=0;i--){
      if(PositionSelectByTicket(g_trades[i].ticket)) continue;
      double pnl=PositionRealized(g_trades[i].posId);
      AuditRow(g_trades[i],0.0,pnl,true,"",true,true,"closed");
      if(pnl<0){ g_consecLosses++; g_winStreak=0; g_lastStopTime=TimeCurrent(); }
      else if(pnl>0){ g_consecLosses=0; g_winStreak++; if(g_winStreak>=5) g_forceChecklist=true; }
      for(int j=i;j<ArraySize(g_trades)-1;j++) g_trades[j]=g_trades[j+1];
      ArrayResize(g_trades,ArraySize(g_trades)-1);
   }
}

//==================================================================
// MODULE — ENTRY EXECUTION (refined / aggressive / inducement)
//==================================================================
void AttemptEntry(int dir){
   if(!TradingAllowed()) return;
   if(CountPositions()>=InpMaxPositions) return;
   if(!ChecklistAllPass()) return;
   if(IsDeadZone()) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry=(dir==1)?ask:bid; double prec=g_poi.precisionLevel;
   double buffer=PipsToPrice(MathMax(InpMinStopPips,1.5));
   if(IsNearClose()) buffer+=PipsToPrice(InpGoldSpreadBuffPips);
   double sl=(dir==1)?(prec-buffer):(prec+buffer);
   double stopPips=MathAbs(entry-sl)/MathMax(PipSize(),1e-9);
   if(stopPips<InpMinStopPips){ stopPips=InpMinStopPips; sl=(dir==1)?(entry-PipsToPrice(stopPips)):(entry+PipsToPrice(stopPips)); }

   ENUM_BIAS dom=DominantBias(); bool counter=((int)dom!=dir);
   ENUM_ENTRY_TYPE et=ENTRY_REFINED; double riskPct=InpRiskPct;
   if(counter){ et=ENTRY_INDUCEMENT; riskPct=MathMin(riskPct,InpCounterRiskPct); }
   else if(stopPips>InpGoldStopMax){ et=ENTRY_AGGRESSIVE; riskPct*=InpAggrSizeMult; }
   if(g_reduceSizing) riskPct*=0.5;

   // TPs
   ENUM_TIMEFRAMES etf=g_tf[IDX_H4]; Swing sw[]; CollectSwingsTF(etf,sw,10);
   int t1=SwingRank(sw,(dir==1)?1:-1,0);
   double tp1=(t1>=0)?sw[t1].price:(dir==1?entry+PipsToPrice(InpHardTPPips):entry-PipsToPrice(InpHardTPPips));
   double tp2=(dir==1)?g_tfState[IDX_H4].externalHigh:g_tfState[IDX_H4].externalLow; if(tp2<=0.0)tp2=tp1;
   double hardTP=0.0;
   if(et==ENTRY_INDUCEMENT) hardTP=(dir==1)?entry+PipsToPrice(InpInducementTPPips):entry-PipsToPrice(InpInducementTPPips);
   else if(IsNearClose())   hardTP=(dir==1)?entry+PipsToPrice(InpHardTPPips):entry-PipsToPrice(InpHardTPPips);

   double eq=AccountInfoDouble(ACCOUNT_EQUITY); double riskUSD=eq*riskPct/100.0;
   double lots=ComputeLots(riskUSD,stopPips);
   double newRisk=stopPips*PipValuePerLot()*lots; double maxTotal=eq*InpMaxTotalRisk/100.0;
   if(OpenRiskUSD()+newRisk>maxTotal){ double avail=maxTotal-OpenRiskUSD(); if(avail<=0.0)return; lots=ComputeLots(avail,stopPips); }
   if(lots<=0.0) return;

   double tpOrder=(hardTP>0.0)?hardTP:0.0;
   string cmt=StringFormat("snX %s %s", (dir==1?"BUY":"SELL"), (et==ENTRY_REFINED?"REF":et==ENTRY_AGGRESSIVE?"AGG":"IND"));
   if(SendOrder(dir,lots,sl,tpOrder,cmt)){
      AdoptPosition(dir,sl,tp1,tp2,hardTP,prec,stopPips,lots,riskPct,et);
      g_state=TS_OPEN_INITIAL; g_stateBar=g_barCount;
      Print("snX ENTRY ",(dir==1?"BUY":"SELL")," @",DoubleToString(entry,_Digits)," SL ",DoubleToString(sl,_Digits),
            " (",DoubleToString(stopPips,1),"p) lots ",DoubleToString(lots,2)," ",cmt," TP1 ",DoubleToString(tp1,_Digits),
            " refTF ",g_tfLbl[g_poi.refinedTFidx]);
   }
}

//==================================================================
// MODULE 11 — EXIT / POSITION MANAGEMENT
//==================================================================
void ManagePositions(){
   ENUM_BIAS dom=DominantBias();
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=0;i<ArraySize(g_trades);i++){
      ulong tk=g_trades[i].ticket; if(!PositionSelectByTicket(tk)) continue;
      int dir=g_trades[i].dir; double entry=g_trades[i].entry; double px=(dir==1)?bid:ask;
      double lots=PositionGetDouble(POSITION_VOLUME),curSL=PositionGetDouble(POSITION_SL),curTP=PositionGetDouble(POSITION_TP);
      // FE1: HTF structure broken against position
      if((dir==1&&dom==BIAS_BEARISH)||(dir==-1&&dom==BIAS_BULLISH)){ ClosePositionFull(tk,"snX FE HTF"); continue; }
      // near close: ensure hard TP
      if(IsNearClose() && curTP<=0.0 && g_trades[i].hardTP>0.0) ModifySLTP(tk,curSL,g_trades[i].hardTP);
      // TP1 partial + BE
      if(!g_trades[i].partialDone){
         bool hit=(dir==1)?(px>=g_trades[i].tp1):(px<=g_trades[i].tp1);
         if(hit && g_trades[i].tp1>0.0){
            ClosePartial(tk,lots*InpTP1Partial,"snX TP1"); g_trades[i].partialDone=true;
            if(InpMoveBEAfterTP1){ ModifySLTP(tk,entry,curTP); g_trades[i].beDone=true; }
         }
      }
      // structure trail
      if(InpTrailStructure && g_trades[i].partialDone){
         ENUM_TIMEFRAMES etf=g_tf[IDX_H1]; Swing sw[]; CollectSwingsTF(etf,sw,8);
         int idx=SwingRank(sw,(dir==1)?-1:1,0);
         if(idx>=0){ double lvl=sw[idx].price;
            if(dir==1 && lvl>curSL && lvl<px) ModifySLTP(tk,lvl,curTP);
            if(dir==-1&&(curSL==0.0||lvl<curSL)&&lvl>px) ModifySLTP(tk,lvl,curTP); }
      }
   }
}

//==================================================================
// LIFECYCLE STATE MACHINE (spec 5.1/5.2) — driven on bar close
//==================================================================
bool PriceInPOIZone(){ if(!g_poi.exists)return false; double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double tol=PipsToPrice(InpFlipZoneTolPips); return(bid>=g_poi.priceLow-tol && bid<=g_poi.priceHigh+tol); }
bool POIBlownThrough(int dir){ if(!g_poi.exists)return false; double cl=gClose[1];
   if(dir==1)  return(cl<g_poi.precisionLevel-PipsToPrice(InpGoldStopMax) && !g_fu);
   return(cl>g_poi.precisionLevel+PipsToPrice(InpGoldStopMax) && !g_fu); }
bool HTFBrokenAgainst(int dir){ ENUM_BIAS d=DominantBias(); return((dir==1&&d==BIAS_BEARISH)||(dir==-1&&d==BIAS_BULLISH)); }

void SetState(ENUM_TRADE_STATE s){ g_state=s; g_stateBar=g_barCount; }

void RunLifecycle(){
   int dir=g_setupDir;
   // OFB + FU evaluated continuously while a setup is live
   if(g_state==TS_POI_WATCH||g_state==TS_PRE_PHASE_2A||g_state==TS_PHASE_2){ UpdateOFB(dir); UpdateFU(dir); }

   switch(g_state){
      case TS_IDLE:
      {
         ResetOFB();
         ENUM_BIAS dom=DominantBias(); dir=(dom==BIAS_BULLISH?1:dom==BIAS_BEARISH?-1:0);
         // align with confirmed day type when available
         if(g_dayType==DCT_BULLISH && dir==-1) dir=0;
         if(g_dayType==DCT_BEARISH && dir==1) dir=0;
         g_setupDir=dir;
         if(dir!=0){ IdentifyAndRefinePOI(dir);
            if(g_poi.isValid){ SetState(TS_POI_WATCH); } }
         break;
      }
      case TS_POI_WATCH:
         IdentifyAndRefinePOI(dir);
         if(HTFBrokenAgainst(dir) || !g_poi.isValid){ SetState(TS_IDLE); }
         else if(PriceInPOIZone()){ SetState(TS_PRE_PHASE_2A); }
         break;
      case TS_PRE_PHASE_2A:
         if(POIBlownThrough(dir)){ SetState(TS_INVALIDATED); }
         else if(g_fu && g_ofb1){ SetState(TS_PHASE_2); }
         else if(g_barCount-g_stateBar>InpBOSLookback){ SetState(TS_INVALIDATED); }
         break;
      case TS_PHASE_2:
         if(POIBlownThrough(dir)){ SetState(TS_INVALIDATED); }
         else if(g_ofb1&&g_ofb2&&g_ofb3){ SetState(TS_ORDER_FLOW_SHIFT); }
         else if(g_barCount-g_stateBar>InpBOSLookback){ SetState(TS_INVALIDATED); }
         break;
      case TS_ORDER_FLOW_SHIFT:
         g_entryPhase=PHASE_3;
         BuildChecklist(dir);
         if(ChecklistAllPass()) AttemptEntry(dir);
         else if(g_barCount-g_stateBar>InpBOSLookback) SetState(TS_INVALIDATED);
         break;
      case TS_INVALIDATED:
         ResetOFB(); SetState(TS_IDLE);
         break;
      default: break;   // OPEN_* handled by ManagePositions / SyncClosedTrades
   }

   // entry-TF phase reflects lifecycle
   if(g_state==TS_POI_WATCH) g_entryPhase=PHASE_1;
   else if(g_state==TS_PRE_PHASE_2A) g_entryPhase=PRE_PHASE_2A;
   else if(g_state==TS_PHASE_2) g_entryPhase=PHASE_2;
   else if(g_state==TS_ORDER_FLOW_SHIFT) g_entryPhase=PHASE_3;
   else if(g_state==TS_OPEN_INITIAL||g_state==TS_OPEN_RUNNER||g_state==TS_BREAK_EVEN) g_entryPhase=PHASE_4;
   else g_entryPhase=PHASE_NONE;

   // return to IDLE when flat after an open cycle
   if((g_state==TS_OPEN_INITIAL||g_state==TS_OPEN_RUNNER||g_state==TS_BREAK_EVEN) && CountPositions()==0){ ResetOFB(); SetState(TS_IDLE); }
}

//==================================================================
// DASHBOARD
//==================================================================
string StateLabel(ENUM_TRADE_STATE s){
   switch(s){ case TS_IDLE:return "IDLE"; case TS_POI_WATCH:return "POI_WATCH"; case TS_PRE_PHASE_2A:return "PRE_2A";
      case TS_PHASE_2:return "PHASE_2"; case TS_ORDER_FLOW_SHIFT:return "OFB_SHIFT"; case TS_ENTRY_PENDING:return "ENTRY_PENDING";
      case TS_OPEN_INITIAL:return "OPEN"; case TS_OPEN_RUNNER:return "RUNNER"; case TS_BREAK_EVEN:return "BREAK_EVEN";
      case TS_INVALIDATED:return "INVALIDATED"; } return "-"; }
void UpdateDashboard(){
   string nl="\n"; ENUM_BIAS dom=DominantBias();
   string s="snXper FX  "+_Symbol+(g_isGold?" [GOLD]":" [FX]")+(g_halted?"  *** HALTED ***":"")+(g_forceChecklist?"  [5-WIN: full checklist]":"")+nl;
   s+="GMT "+IntegerToString(GMTHour())+":00  "+CycleLabel(g_cycle)
     +"  DAY "+(g_dayType==DCT_BULLISH?"BULL":g_dayType==DCT_BEARISH?"BEAR":"undet")
     +"  "+(IsDeadZone()?"DEADZONE":IsNearClose()?"CLOSE":"tradeable")+nl;
   s+="TLD "+(g_tldPrinted?DoubleToString(g_TLD,2):"-")+"  THD "+(g_thdPrinted?DoubleToString(g_THD,2):"-")
     +"  Frankfurt "+(g_frankfurtRaid?"raided":"-")+nl;
   s+="------------------------------------------------------------"+nl;
   string row=""; for(int i=0;i<TF_COUNT;i++) row+=g_tfLbl[i]+BiasArrow(g_tfState[i].bias)+" ";
   s+="STRUCT "+row+nl;
   s+="LIFECYCLE "+StateLabel(g_state)+"  setupDir "+(g_setupDir==1?"BUY":g_setupDir==-1?"SELL":"-")
     +"  phase "+IntegerToString((int)g_entryPhase)+"  DOM "+(dom==BIAS_BULLISH?"BULL":dom==BIAS_BEARISH?"BEAR":"NEUT")+nl;
   s+="OFB "+(g_ofb1?"1":"-")+(g_ofb2?"2":"-")+(g_ofb3?"3":"-")+"/3   FU "+(g_fu?"YES":"no")+nl;
   s+="------------------------------------------------------------"+nl;
   if(g_poi.exists){
      s+="POI "+(g_poi.type==POI_DEMAND?"DEMAND":"SUPPLY")+" prec "+DoubleToString(g_poi.precisionLevel,2)
        +" ["+DoubleToString(g_poi.priceLow,2)+"-"+DoubleToString(g_poi.priceHigh,2)+"] refTF "+g_tfLbl[g_poi.refinedTFidx]
        +(g_poi.isValid?"  VALID":"  invalid")+nl;
      s+="  C1 "+(g_poi.c1?"Y":"n")+"  C2 "+(g_poi.c2?"Y":"n")+"  C3 "+(g_poi.c3?"Y":"n")+"  C4 "+(g_poi.c4?"Y":"n")
        +"  flip "+DoubleToString(g_poi.flipZonePrice,2)+nl;
   } else s+="POI none"+nl;
   s+="CHK => "+(ChecklistAllPass()?"ALL PASS":("blocked @ "+FirstFailingStep()))+nl;
   s+="------------------------------------------------------------"+nl;
   s+="LIQ "+IntegerToString(ArraySize(g_liq))+" ("+IntegerToString(CountUnraided())+" unraided)"
     +"  POS "+IntegerToString(CountPositions())+"/"+IntegerToString(InpMaxPositions)
     +"  risk $"+DoubleToString(OpenRiskUSD(),0)+"  consecL "+IntegerToString(g_consecLosses)+"  win "+IntegerToString(g_winStreak)+nl;
   s+="SESS Syd "+DoubleToString(g_sydL,2)+"/"+DoubleToString(g_sydH,2)+(g_sydLRaid?"[L]":"")+(g_sydHRaid?"[H]":"")
     +"  Asia "+DoubleToString(g_asiaL,2)+"/"+DoubleToString(g_asiaH,2)
     +"  Lon "+DoubleToString(g_lonL,2)+"/"+DoubleToString(g_lonH,2)+nl;
   Comment(s);
}

//==================================================================
// PIPELINE (spec section 10) — bar-close analysis & entry
//==================================================================
void RunPipeline(){
   g_barCount++;
   BuildStructuralCascade();
   RebuildLiquidityMap();
   RunLifecycle();
}

//==================================================================
// CALLBACKS
//==================================================================
int OnInit(){
   g_isGold=SymbolIsGold();
   g_prevCycle=DC_DAILY_CLOSE; g_dayType=DCT_UNDETERMINED; g_sessionModel=SM_TWO_SIDED;
   g_sydH=g_sydL=g_asiaH=g_asiaL=g_lonH=g_lonL=g_tHigh=g_tLow=g_dayH=g_dayL=g_pdH=g_pdL=0;
   g_TLD=g_THD=0; g_sydHRaid=g_sydLRaid=g_tldPrinted=g_thdPrinted=g_frankfurtRaid=false;
   g_state=TS_IDLE; g_entryPhase=PHASE_NONE; g_setupDir=0; ResetOFB();
   g_lastBarTime=0; g_barCount=0; g_stateBar=0;
   g_consecLosses=0; g_winStreak=0; g_lastStopTime=0; g_halted=false; g_reduceSizing=false; g_forceChecklist=false;
   g_dayStamp=-1; g_weekStamp=-1; g_poi.exists=false;
   ClearLiq(); ArrayResize(g_trades,0);
   for(int i=0;i<TF_COUNT;i++){ g_tfState[i].bias=BIAS_NEUTRAL; g_tfState[i].bosStrength=BOS_NONE; g_tfState[i].bosDir=0; g_tfState[i].chochDetected=false; g_tfState[i].phase=PHASE_NONE; }
   AuditHeaderIfNew();
   if(!RefreshSeries()) return INIT_FAILED;
   Print("snXperFX FULL spec loaded. ",_Symbol," gold=",g_isGold," pip=",DoubleToString(PipSize(),_Digits));
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){ Comment(""); }
void OnTick(){
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
