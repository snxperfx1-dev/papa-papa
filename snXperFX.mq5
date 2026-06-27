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
// F16 INTELLIGENCE LAYER — Invisible Network + Time + Opportunity
//   Ported from the F16 Raptor v60 indicator. This is PURE CONTEXT:
//   it scores / sizes / targets the spec entries. It NEVER changes the
//   lifecycle entry trigger or the POI-precision stop loss — those stay
//   the execution authority (entries own "when"; context owns "where /
//   how much / which target"; they touch at ONE arbitration point).
//==================================================================
input group "═══ F16 Intelligence (context only) ═══"
input bool   InpF16Enable      = true;   // master switch for the F16 context layer
input double InpF16WickFrac    = 0.30;   // FU spike: min wick / range
input int    InpF16Lookback    = 3;      // FU spike: structure lookback
input double InpF16AuthMin      = 45.0;  // min node authority to count as live
input int    InpF16NodeMax     = 250;    // max remembered nodes
input int    InpF16DormantBars = 120;    // bars until a node goes dormant
input int    InpF16HistoryBars = 600;    // bars until a node goes historical
input bool   InpF16NetTarget   = true;   // use the nearest forward node as the runner TP2
input bool   InpF16SizeByOpp   = true;   // scale risk% by the opportunity grade
input double InpF16OppSizeMin  = 0.6;    // risk multiplier at 0 opportunity
input double InpF16OppSizeMax  = 1.3;    // risk multiplier at 100 opportunity
input bool   InpF16VetoFullOpp = true;   // veto: skip when network+MTF+time ALL oppose the direction
input bool   InpF16GateReversal  = true; // veto: skip when reversal/absorption BELIEF dominates against dir
input bool   InpF16GateObjective = true; // veto: don't chase a move whose objective/energy is already resolved
input bool   InpF16GateCycle     = true; // veto: skip when the HTF time-cycle is exhausted against dir
input bool   InpF16GateGrade     = true; // veto: skip NO-TRADE opportunity grade / extreme threat
input double InpF16ReversalBlk   = 60.0; // reversal/absorption belief >= this (and > continuation) blocks entry
input double InpF16ThreatBlock   = 75.0; // threat >= this blocks entry
input bool   InpF16MgmtObjExit   = true; // EXIT: BE + partial when the objective is reached & energy resolved
input bool   InpF16FUConfirm     = true; // ENTRY: the F16 multi-TF network FU can confirm the Phase-2 FU step
input bool   InpF16Confluence    = true; // ENTRY: require F16 confluence (network/belief not opposing, grade tradeable)
input double InpF16FUNearATR     = 2.0;  // an F16 FU node must be within this many ATR of price to confirm an entry
input bool   InpF16AnchorPOI     = true; // ENTRY STRUCTURE: snap the POI precision level to an aligned network FU node (the precise wick)
input double InpF16AnchorTolATR  = 1.0;  // a network FU node within this many ATR of the POI zone qualifies as its precise anchor

// --- node object (a remembered FU / flip level on some timeframe) ---
struct F16Node {
   double price;   // the FU wick tip = the node price
   double mid;     // mid (tip<->body) = mitigation / 0.5 level
   int    dir;     // +1 bullish rejection, -1 bearish rejection
   double score;   // raw FU authority score
   int    wt;      // TF weight (9=MN 8=W 7=D 6=H4 5=H1 4=M15 3=M5)
   int    state;   // 0 active, 1 dormant, 2 consumed, 3 historical
   int    bar;     // g_barCount at birth
   int    rev;     // reaction count (times price revisited)
};
F16Node g_f16nodes[];

// scanned timeframes (MN -> M5) and their authority weights
ENUM_TIMEFRAMES g_f16tf[7] = {PERIOD_MN1,PERIOD_W1,PERIOD_D1,PERIOD_H4,PERIOD_H1,PERIOD_M15,PERIOD_M5};
int             g_f16wt[7] = {9,8,7,6,5,4,3};

// per-TF FU state (dedupe tip + confirmation latch)
double g_f16prevTip[7];
int    g_f16fuDir[7];
double g_f16fuBodyHi[7], g_f16fuBodyLo[7];
bool   g_f16fuConf[7];

// network outputs
int    g_f16netBias   = 0;
double g_f16attrPrice = 0.0, g_f16attrScore = 0.0;  int g_f16attrWt = 0;
double g_f16fezHi     = 0.0, g_f16fezLo     = 0.0;
int    g_f16eligN     = 0;   double g_f16pressure = 0.0;  int g_f16pdir = 0;

// Time Intelligence Engine outputs
int    g_f16timeDir = 0;  double g_f16timeAlign = 50.0, g_f16timeConflict = 50.0;
double g_f16h1LowProb = 50.0; string g_f16h1Timing = "-"; string g_f16tSeq = "-";

// Opportunity synthesis outputs
double g_f16alignment = 50.0, g_f16conflict = 0.0, g_f16confidence = 50.0;
double g_f16threat = 0.0, g_f16opp = 0.0, g_f16biasStrength = 50.0;
string g_f16oppGrade = "-"; int g_f16master = 0; double g_f16primProb = 50.0;
double g_f16sizeMult = 1.0;

// physics-lite (chart TF, closed bars) + observation scores
double g_f16eff=0.0,g_f16disp=0.0,g_f16vel=0.0,g_f16acc=0.0,g_f16conv=0.0,g_f16comp=0.0;
double g_f16obsExp=0.0,g_f16obsDecay=0.0,g_f16obsCurv=0.0,g_f16obsAbs=0.0,g_f16obsLiq=0.0;
bool   g_f16impBull=false,g_f16impBear=false;
// belief probabilities (EMA-smoothed 0..100) + net belief direction
double g_f16bExp=0.0,g_f16bCont=0.0,g_f16bCreate=0.0,g_f16bAbsorb=0.0,g_f16bRetr=0.0,g_f16bReturn=0.0;
int    g_f16beliefDir=0;
// energy / resolution / attractor (EDE/RE/EAE-lite)
double g_f16expEnergy=0.0,g_f16dissEnergy=0.0,g_f16residual=0.0,g_f16eaePrice=0.0;
int    g_f16resCode=0;
// liquidation-wave objective arrival
bool   g_f16objArrival=false; double g_f16objDistPct=100.0;
// liquidity heat around the target (reuses the spec liquidity pools)
double g_f16targetHeat=0.0; bool g_f16targetVacuum=false;
// HTF time-cycle exhaustion (0..100) against buying / selling
double g_f16cycExhLong=0.0, g_f16cycExhShort=0.0;
// decision resolver outputs (the single arbitration point)
double g_f16decSize=1.0, g_f16decTarget=0.0; bool g_f16decVeto=false; string g_f16decReason="";
bool   g_chkF16=true;   // F16 confluence checklist result (network/belief/grade agree with dir)
bool   g_f16poiAnchored=false; int g_f16poiNodeWt=0; double g_f16poiNodePx=0.0; // POI precision anchored to a network FU node

//==================================================================
// SYMPHONY PHASE ENGINE (ported curvature engine — native entry path)
//   Impulse/anchor detection, Phase 1-4 (long & short), inducement
//   flipzone, ARC convexity target, and the precise P3/P4 entries with
//   anchor-ATR stops. Every entry is routed through the F16 decision /
//   confluence / FU-anchor layer and snXperFX's guards / risk / order /
//   adopt / management / audit. (DRDWCT risk engine intentionally omitted
//   — snXperFX already has its own equity guards.)
//==================================================================
input group "═══ Symphony Phase Engine ═══"
input bool   InpSymEnable        = true;  // enable the ported Symphony Phase 3/4 entry path
input int    InpSymATRLen        = 14;    // ATR length for the phase engine
input double InpSymImpulseAtr    = 1.5;   // impulse = leg > this * ATR
input double InpSymRetrMin       = 0.30;  // min retracement (fraction of the impulse leg)
input double InpSymRetrMax       = 0.80;  // max retracement before the impulse is void
input int    InpSymInducLook     = 80;    // inducement / flipzone lookback (bars)
input double InpSymInducZoneATR  = 0.25;  // flipzone half-width (ATR)
input int    InpSymArcHorizon    = 80;    // ARC horizon (bars)
input double InpSymConvPower     = 1.5;   // ARC convexity power
input double InpSymArcExt        = 1.5;   // ARC extension (impulse multiple)
input double InpSymOuterBandATR  = 0.75;  // outer institutional band distance (ATR)
input double InpSymArcTolATR     = 0.20;  // how close to the ARC counts as exhausted (ATR)
input bool   InpSymUseF16        = true;  // route Symphony entries through the F16 decision / confluence / anchor layer

// pivot history (chart series)
double sym_lastPivotPrice=0.0; int sym_lastPivotShift=-1; int sym_lastPivotDir=0;
double sym_prevPivotPrice=0.0; int sym_prevPivotShift=-1; int sym_prevPivotDir=0;
// impulse / mode + anchors
int    sym_mode=0; double sym_anchorHigh=0.0, sym_anchorLow=0.0; int sym_anchorHighShift=-1, sym_anchorLowShift=-1;
// phases (1-4) per direction
int    sym_phaseLong=0, sym_phaseShort=0, sym_prevPhaseLong=0, sym_prevPhaseShort=0;
// inducement / flipzone
double sym_longInducPrice=0.0, sym_longInducLow=0.0, sym_longInducHigh=0.0;
double sym_shortInducPrice=0.0, sym_shortInducLow=0.0, sym_shortInducHigh=0.0;
// pre-convexity latch + ARC + outer-band sweep flags
bool   sym_longPreConvSeen=false, sym_shortPreConvSeen=false;
double sym_arcLong=0.0, sym_arcShort=0.0;
bool   sym_longOuterBreachSeen=false, sym_shortOuterBreachSeen=false;
// one entry per direction per bar
datetime sym_lastLongTradeTime=0, sym_lastShortTradeTime=0;

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
   // the network FU detector picks WHICH precise structure the entry is taken off:
   // snap the precision level (entry/SL anchor) to an aligned, authoritative FU wick.
   prec=F16_AnchorPrecision(dir,g_poi.priceLow,g_poi.priceHigh,prec);
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
   // C4: refined to M5 or finer (or anchored to an authoritative network FU) AND valid
   double stopPips=MathAbs(bid-prec)/MathMax(PipSize(),1e-9);
   bool refinedEnough=(refIdx>=IDX_M5) || g_f16poiAnchored;
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
   g_chk.s6_fu          = (!InpRequireFU || g_fu || (InpF16FUConfirm && F16_FreshFU(dir)));
   g_chk.s7_timeOK      = (!InpEnforceDeadZone||!IsDeadZone()) && (!InpRequireSessionWindow||InSessionWindow()) && TLDConfirmed(dir);
   g_chk.s7_hardTP      = true;   // enforced at order time
   g_chk.s8_corr        = CorrelationOK(dir);
   g_chk.s8_news        = NewsClear();
   g_chkF16             = F16_Confluent(dir);   // network/belief/grade must agree with the entry
}
bool ChecklistAllPass(){
   return g_chk.s1_cascade && g_chk.s2_phase3 && g_chk.s3_poi &&
          (!InpRequire3Shifts || (g_chk.s5_ofb1 && g_chk.s5_ofb2 && g_chk.s5_ofb3)) &&
          g_chk.s6_fu && g_chk.s7_timeOK && g_chk.s8_corr && g_chk.s8_news && g_chkF16;
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
   if(!g_chkF16)         return "S9_F16confluence";
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
   // F16 DECISION — every engine feeds ONE arbitration point: size · target · take/skip.
   // It never alters the entry trigger or the SL geometry; it only decides whether this
   // spec-triggered entry is taken, how big, and which runner target it aims at.
   if(InpF16Enable){
      F16_Decision(dir);
      if(g_f16decVeto){ Print("snX F16 VETO ",(dir==1?"BUY":"SELL")," — ",g_f16decReason); return; }
   }

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
   // F16 context owns "how much": scale risk by the resolved decision size (entry & SL unchanged)
   if(InpF16Enable && InpF16SizeByOpp) riskPct=MathMax(0.05, riskPct*g_f16decSize);

   // TPs
   ENUM_TIMEFRAMES etf=g_tf[IDX_H4]; Swing sw[]; CollectSwingsTF(etf,sw,10);
   int t1=SwingRank(sw,(dir==1)?1:-1,0);
   double tp1=(t1>=0)?sw[t1].price:(dir==1?entry+PipsToPrice(InpHardTPPips):entry-PipsToPrice(InpHardTPPips));
   double tp2=(dir==1)?g_tfState[IDX_H4].externalHigh:g_tfState[IDX_H4].externalLow; if(tp2<=0.0)tp2=tp1;
   // F16 context owns "which target": extend the runner to the resolved decision target
   // (network attractor / energy magnet) when it sits farther than the structural TP2
   if(InpF16Enable && InpF16NetTarget && g_f16decTarget>0.0){
      bool ahead =(dir==1)?(g_f16decTarget>entry):(g_f16decTarget<entry);
      bool farther=(dir==1)?(g_f16decTarget>tp2)  :(g_f16decTarget<tp2);
      if(ahead && farther) tp2=g_f16decTarget;
   }
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
            " refTF ",g_tfLbl[g_poi.refinedTFidx],
            (g_f16poiAnchored?(" anchor "+F16_WtLabel(g_f16poiNodeWt)+" FU @ "+DoubleToString(g_f16poiNodePx,_Digits)):" anchor pivot"),
            "  | F16 opp ",g_f16oppGrade," conf ",DoubleToString(g_f16confidence,0),
            " sz x",DoubleToString(g_f16decSize,2)," belief ",(g_f16beliefDir==1?"+":g_f16beliefDir==-1?"-":"0"),
            " tgt ",(g_f16decTarget>0.0?DoubleToString(g_f16decTarget,_Digits):"-"));
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
      // F16 EXIT — objective reached / energy resolved in this direction: bank a partial + lock BE.
      // (Energy/attractor + liquidation-wave engines drive exits only, per the life-affects-exits rule.)
      if(InpF16Enable && InpF16MgmtObjExit && (g_f16objArrival || g_f16resCode==2)){
         bool inProfit=(dir==1)?(px>entry):(px<entry);
         bool objAhead=(g_f16eaePrice>0.0)&&((dir==1)?(g_f16eaePrice>=entry):(g_f16eaePrice<=entry));
         if(inProfit && objAhead){
            if(!g_trades[i].partialDone){ ClosePartial(tk,lots*InpTP1Partial,"snX F16 OBJ"); g_trades[i].partialDone=true; }
            if(!g_trades[i].beDone){ ModifySLTP(tk,entry,curTP); g_trades[i].beDone=true; }
         }
      }
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
         if(dir!=0 && InpF16Enable && InpF16VetoFullOpp && F16_FullOpposition(dir)) dir=0; // don't build a setup the whole stack opposes
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
         else if((g_fu || (InpF16FUConfirm && F16_FreshFU(dir))) && g_ofb1){ SetState(TS_PHASE_2); }
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
   if(InpF16Enable){
      s+="------------------------------------------------------------"+nl;
      s+="F16 NET "+(g_f16netBias==1?"^BULL":g_f16netBias==-1?"vBEAR":"-")
        +"  nodes "+IntegerToString(ArraySize(g_f16nodes))+" ("+IntegerToString(g_f16eligN)+" live)"
        +"  press "+DoubleToString(g_f16pressure,0)
        +"  attr "+(g_f16attrPrice>0.0?DoubleToString(g_f16attrPrice,2):"-")+nl;
      s+="F16 FEZ ["+(g_f16fezLo>0.0?DoubleToString(g_f16fezLo,2):"-")+" .. "+(g_f16fezHi>0.0?DoubleToString(g_f16fezHi,2):"-")+"]"
        +"  TIME "+(g_f16timeDir==1?"^":g_f16timeDir==-1?"v":"-")+" align "+DoubleToString(g_f16timeAlign,0)
        +"  H1 "+g_f16h1Timing+nl;
      s+="F16 OPP "+g_f16oppGrade+" "+DoubleToString(g_f16opp,0)+"/100"
        +"  conf "+DoubleToString(g_f16confidence,0)+"  threat "+DoubleToString(g_f16threat,0)
        +"  size x"+DoubleToString(g_f16sizeMult,2)+"  path "+DoubleToString(g_f16primProb,0)+"%"+nl;
      s+="F16 BELIEF "+(g_f16beliefDir==1?"^":g_f16beliefDir==-1?"v":"-")
        +"  cont "+DoubleToString(g_f16bCont,0)+"  retr "+DoubleToString(g_f16bRetr,0)
        +"  absorb "+DoubleToString(g_f16bAbsorb,0)+"  exp "+DoubleToString(g_f16bExp,0)+nl;
      s+="F16 ENERGY res "+DoubleToString(g_f16residual,0)+"%  "
        +(g_f16resCode==2?"RESOLVED":g_f16resCode==1?"PARTIAL":"UNRESOLVED")
        +"  obj "+(g_f16objArrival?"ARRIVED":DoubleToString(g_f16objDistPct,0)+"%")
        +"  heat "+DoubleToString(g_f16targetHeat,0)+(g_f16targetVacuum?" (vacuum)":"")+nl;
      s+="F16 CYCLE exhL "+DoubleToString(g_f16cycExhLong,0)+"%  exhS "+DoubleToString(g_f16cycExhShort,0)+"%"
        +"  H1 "+g_f16h1Timing+nl;
      s+="F16 ANCHOR "+(g_f16poiAnchored?(F16_WtLabel(g_f16poiNodeWt)+" FU @ "+DoubleToString(g_f16poiNodePx,_Digits)+" (precise)"):"spec pivot")
        +"  fresh-FU "+((g_setupDir!=0&&F16_FreshFU(g_setupDir))?"yes":"no")+nl;
   }
   if(InpSymEnable){
      int sp=(sym_mode==1?sym_phaseLong:sym_mode==-1?sym_phaseShort:0);
      s+="SYM "+(sym_mode==1?"^LONG":sym_mode==-1?"vSHORT":"-")+" PHASE "+IntegerToString(sp)
        +(sp>=3?" *ENTRY*":sp==2?" (aggr)":"")
        +"  anchor "+DoubleToString(sym_anchorLow,_Digits)+"/"+DoubleToString(sym_anchorHigh,_Digits)
        +"  ARC "+DoubleToString(sym_mode==1?sym_arcLong:sym_arcShort,_Digits)+nl;
   }
   Comment(s);
}

//==================================================================
// PIPELINE (spec section 10) — bar-close analysis & entry
//==================================================================
void RunPipeline(){
   g_barCount++;
   BuildStructuralCascade();
   RebuildLiquidityMap();
   F16_Update();          // F16 context layer: network / time / opportunity (scores+sizes+targets only)
   if(InpSymEnable){ Sym_UpdatePhaseEngine(); Sym_UpdateARC(); Sym_ManageExits(); } // Symphony phase engine + composite exits
   RunLifecycle();        // spec ICT lifecycle entry path
   if(InpSymEnable) Sym_ExecuteEntries();   // Symphony Phase 3/4 entry path (F16-gated)
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



//==================================================================
// F16 INTELLIGENCE ENGINE  (ported logic — no Pine UI)
//   Invisible Network (multi-TF FU detector -> nodes -> authority ->
//   FEZ -> attractor), Time Intelligence (cycle completion), and the
//   Senseei Opportunity synthesis. Reads OHLC only; touches no orders.
//==================================================================

// manual ATR (avoids MQL5 indicator handles for 7 timeframes)
double F16_ATR(ENUM_TIMEFRAMES tf,int period,int shift){
   double sum=0.0; int n=0;
   for(int i=shift;i<shift+period;i++){
      double h=iHigh(_Symbol,tf,i),l=iLow(_Symbol,tf,i),pc=iClose(_Symbol,tf,i+1);
      if(h<=0.0||l<=0.0||pc<=0.0) continue;
      double tr=MathMax(h-l,MathMax(MathAbs(h-pc),MathAbs(l-pc)));
      sum+=tr; n++;
   }
   return (n>0)?sum/(double)n:0.0;
}

double F16_Auth(int i){ return g_f16nodes[i].score + g_f16nodes[i].wt*4.0 + g_f16nodes[i].rev*3.0; }

void F16_AddNode(double tip,double mid,int dir,double score,int wt){
   int n=ArraySize(g_f16nodes); ArrayResize(g_f16nodes,n+1);
   g_f16nodes[n].price=tip; g_f16nodes[n].mid=mid; g_f16nodes[n].dir=dir;
   g_f16nodes[n].score=score; g_f16nodes[n].wt=wt; g_f16nodes[n].state=0;
   g_f16nodes[n].bar=g_barCount; g_f16nodes[n].rev=0;
   // cap (drop oldest)
   while(ArraySize(g_f16nodes)>InpF16NodeMax){
      for(int i=1;i<ArraySize(g_f16nodes);i++) g_f16nodes[i-1]=g_f16nodes[i];
      ArrayResize(g_f16nodes,ArraySize(g_f16nodes)-1);
   }
}

// f_fuPool port — dominant rejection wick at a local extreme (swept or not)
void F16_FU(int ti,ENUM_TIMEFRAMES tf,int wt){
   int s=1;
   double o=iOpen(_Symbol,tf,s),h=iHigh(_Symbol,tf,s),l=iLow(_Symbol,tf,s),c=iClose(_Symbol,tf,s);
   if(h<=0.0||l<=0.0) return;
   double rng=MathMax(h-l,1e-10);
   int lb=InpF16Lookback;
   double pHi=iHigh(_Symbol,tf,iHighest(_Symbol,tf,MODE_HIGH,lb,s+1));
   double pLo=iLow (_Symbol,tf,iLowest (_Symbol,tf,MODE_LOW, lb,s+1));
   double uw=(h-MathMax(o,c))/rng, lw=(MathMin(o,c)-l)/rng;
   bool localTop=(h>=iHigh(_Symbol,tf,iHighest(_Symbol,tf,MODE_HIGH,lb,s)));
   bool localBot=(l<=iLow (_Symbol,tf,iLowest (_Symbol,tf,MODE_LOW, lb,s)));
   bool bear=(uw>=InpF16WickFrac)&&((pHi>0.0&&h>=pHi&&c<pHi)||(localTop&&c<o));
   bool bull=(lw>=InpF16WickFrac)&&((pLo>0.0&&l<=pLo&&c>pLo)||(localBot&&c>o));
   double atr=F16_ATR(tf,14,s); if(atr<=0.0) atr=rng;
   int    dir=0; double tip=0.0, mid=0.0, bH=MathMax(o,c), bL=MathMin(o,c);
   if(bear){ dir=-1; tip=h; mid=bH+(tip-bH)*0.5;
             g_f16fuDir[ti]=-1; g_f16fuBodyHi[ti]=bH; g_f16fuBodyLo[ti]=bL; g_f16fuConf[ti]=false; }
   else if(bull){ dir=1; tip=l; mid=tip+(bL-tip)*0.5;
             g_f16fuDir[ti]=1; g_f16fuBodyHi[ti]=bH; g_f16fuBodyLo[ti]=bL; g_f16fuConf[ti]=false; }
   // confirmation latch (rejection followed through)
   if(g_f16fuDir[ti]==-1 && !g_f16fuConf[ti] && c<g_f16fuBodyLo[ti]) g_f16fuConf[ti]=true;
   if(g_f16fuDir[ti]== 1 && !g_f16fuConf[ti] && c>g_f16fuBodyHi[ti]) g_f16fuConf[ti]=true;
   if(dir==0) return;                                  // no fresh FU on this bar
   if(g_f16prevTip[ti]!=0.0 && MathAbs(tip-g_f16prevTip[ti])<1e-9) return; // dedupe same tip
   g_f16prevTip[ti]=tip;
   double wk=(dir==-1)?(tip-bH)/MathMax(atr,1e-10):(bL-tip)/MathMax(atr,1e-10);
   double score=20.0+MathMin(25.0,wk*15.0)+(g_f16fuConf[ti]?30.0:0.0)+(wk>1.0?15.0:0.0)+(wk>1.5?10.0:0.0);
   F16_AddNode(tip,mid,dir,score,wt);
}

void F16_ScanFU(){ for(int ti=0;ti<7;ti++) F16_FU(ti,g_f16tf[ti],g_f16wt[ti]); }

// node lifecycle: consumed when price closes through it; else age -> dormant/historical;
// reaction counter rises when price hovers near the level (memory of respect)
void F16_UpdateNodes(){
   double cl=gClose[1]; double natr=F16_ATR(_Period,14,1); if(natr<=0.0) natr=PipsToPrice(10.0);
   for(int i=0;i<ArraySize(g_f16nodes);i++){
      if(g_f16nodes[i].state==2) continue;
      double np=g_f16nodes[i].price; int nd=g_f16nodes[i].dir;
      int    age=g_barCount-g_f16nodes[i].bar;
      bool consumed=(nd==-1)?(cl>np):(cl<np);
      if(consumed){ g_f16nodes[i].state=2; continue; }
      if(MathAbs(cl-np)<natr*0.25) g_f16nodes[i].rev++;
      int wtn=g_f16nodes[i].wt;
      g_f16nodes[i].state=(age>InpF16HistoryBars*wtn)?3:(age>InpF16DormantBars*wtn)?1:0;
   }
}

// network scan: bias (MN-first), eligible count, directional authority, pressure,
// the dominant forward attractor (TF-weight then authority), and the FEZ corridor
void F16_NetworkScan(){
   double cl=gClose[1];
   g_f16netBias=0;
   for(int ti=0;ti<7;ti++){ if(g_f16fuDir[ti]!=0){ g_f16netBias=g_f16fuDir[ti]; break; } }
   if(g_f16netBias==0) g_f16netBias=(int)DominantBias();

   g_f16eligN=0; double bullA=0.0, bearA=0.0;
   double attrRank=-1.0; int attrIdx=-1;
   double fezHiA=0.0, fezLoA=0.0; g_f16fezHi=0.0; g_f16fezLo=0.0;
   for(int i=0;i<ArraySize(g_f16nodes);i++){
      if(g_f16nodes[i].state==2) continue;
      double a=F16_Auth(i);
      if(a<InpF16AuthMin) continue;
      double np=g_f16nodes[i].price; int nd=g_f16nodes[i].dir; int wt=g_f16nodes[i].wt;
      g_f16eligN++;
      if(nd==1) bullA+=a; else if(nd==-1) bearA+=a;
      bool onBias=(g_f16netBias==-1)?(np<cl):(np>cl);
      if(onBias){ double rk=wt*1000.0+a; if(rk>attrRank){ attrRank=rk; attrIdx=i; } }
      if(np>cl && a>fezHiA){ g_f16fezHi=np; fezHiA=a; }
      if(np<cl && a>fezLoA){ g_f16fezLo=np; fezLoA=a; }
   }
   if(attrIdx>=0){ g_f16attrPrice=g_f16nodes[attrIdx].price; g_f16attrScore=F16_Auth(attrIdx); g_f16attrWt=g_f16nodes[attrIdx].wt; }
   else          { g_f16attrPrice=0.0; g_f16attrScore=0.0; g_f16attrWt=0; }
   g_f16pressure=((bullA+bearA)>0.0)?(bullA-bearA)/(bullA+bearA)*100.0:0.0;
   g_f16pdir=(g_f16pressure>12.0)?1:(g_f16pressure<-12.0)?-1:0;
}

// Time Intelligence Engine — cycle completion across MN/W/D/H4/H1 + HTF cycle exhaustion
void F16_Time(){
   ENUM_TIMEFRAMES tf[5]={PERIOD_MN1,PERIOD_W1,PERIOD_D1,PERIOD_H4,PERIOD_H1};
   double cl=gClose[1]; int bull=0,bear=0; bool h1Ht=false,h1Lt=false;
   double h1H=0,h1L=0; int hiTaken=0,loTaken=0;
   for(int i=0;i<5;i++){
      double o=iOpen(_Symbol,tf[i],0), h=iHigh(_Symbol,tf[i],0), l=iLow(_Symbol,tf[i],0);
      double ph=iHigh(_Symbol,tf[i],1), pl=iLow(_Symbol,tf[i],1);
      if(o<=0.0) continue;
      if(cl>o) bull++; else if(cl<o) bear++;
      bool ht=(h>ph), lt=(l<pl);
      if(i>=2){ if(ht)hiTaken++; if(lt)loTaken++; }   // D, H4, H1 cycles
      if(i==4){ h1H=h; h1L=l; h1Ht=ht; h1Lt=lt; }
   }
   g_f16timeDir=(bull>bear)?1:(bear>bull)?-1:0;
   g_f16timeAlign=((bull+bear)>0)?MathMax(bull,bear)/(double)(bull+bear)*100.0:50.0;
   g_f16timeConflict=100.0-g_f16timeAlign;
   double pos=(h1H>h1L)?(cl-h1L)/MathMax(h1H-h1L,1e-9):0.5;
   g_f16h1LowProb=(h1Lt&&!h1Ht)?30.0:(h1Ht&&!h1Lt)?70.0:MathRound(pos*100.0);
   g_f16h1Timing=(h1Ht&&h1Lt)?"COMPLETION":(g_f16h1LowProb>=55.0)?"LOW FIRST":(g_f16h1LowProb<=45.0)?"HIGH FIRST":"BALANCED";
   g_f16tSeq=(!h1Lt?"take H1 low":!h1Ht?"take H1 high":"H1 done");
   // upside liquidity already taken across D/H4/H1 -> the cycle is exhausted for NEW longs (mirror for shorts)
   g_f16cycExhLong =hiTaken/3.0*100.0;
   g_f16cycExhShort=loTaken/3.0*100.0;
}

// Opportunity synthesis — alignment / conflict / threat / confidence / grade
// over the voters {network bias, MTF dominant bias, time dir, setup dir}
void F16_Opportunity(){
   int mtf=(int)DominantBias();
   // bias strength = share of TFs agreeing with the dominant bias
   int agree=0,tot=0;
   for(int i=0;i<TF_COUNT;i++){ if(g_tfState[i].bias!=BIAS_NEUTRAL){ tot++; if((int)g_tfState[i].bias==mtf) agree++; } }
   g_f16biasStrength=(tot>0)?agree/(double)tot*100.0:50.0;

   int v1=g_f16netBias, v2=mtf, v3=g_f16timeDir, v4=g_setupDir;
   int sum=v1+v2+v3+v4;
   g_f16master=(sum>0)?1:(sum<0)?-1:0;
   int cast=(v1!=0?1:0)+(v2!=0?1:0)+(v3!=0?1:0)+(v4!=0?1:0);
   int forV=((v1==g_f16master&&v1!=0)?1:0)+((v2==g_f16master&&v2!=0)?1:0)
           +((v3==g_f16master&&v3!=0)?1:0)+((v4==g_f16master&&v4!=0)?1:0);
   g_f16alignment=(cast>0)?forV/(double)cast*100.0:50.0;
   g_f16conflict =(cast>0)?(cast-forV)/(double)cast*100.0:0.0;
   g_f16threat=MathMax(0.0,MathMin(100.0,g_f16conflict*0.45+g_f16timeConflict*0.20
              +((g_f16pdir!=0&&g_f16pdir!=g_f16master)?18.0:0.0)));
   double attrN=MathMin(g_f16attrScore,100.0);
   g_f16confidence=MathMax(0.0,MathMin(100.0,g_f16alignment*0.40+g_f16timeAlign*0.12
              +g_f16biasStrength*0.18+attrN*0.15+MathMin(15.0,g_f16eligN*1.2)-g_f16threat*0.20));
   g_f16opp=MathMax(0.0,MathMin(100.0,g_f16alignment*0.40+attrN*0.30+g_f16biasStrength*0.30-g_f16threat*0.35));
   g_f16oppGrade=(g_f16opp>=88.0)?"A+":(g_f16opp>=78.0)?"A":(g_f16opp>=65.0)?"B":(g_f16opp>=50.0)?"C":"NO-TRADE";

   // flight-plan probability: the forward attractor's share of total forward authority
   double fwdTot=0.0, fwdTop=0.0; double cl=gClose[1];
   for(int i=0;i<ArraySize(g_f16nodes);i++){
      if(g_f16nodes[i].state==2) continue; double a=F16_Auth(i); if(a<InpF16AuthMin) continue;
      bool ahead=(g_f16master==-1)?(g_f16nodes[i].price<cl):(g_f16nodes[i].price>cl);
      if(ahead){ fwdTot+=a; if(a>fwdTop) fwdTop=a; }
   }
   g_f16primProb=(fwdTot>0.0)?MathMin(92.0,40.0+fwdTop/fwdTot*52.0):(g_f16master!=0?60.0:50.0);

   // size multiplier from confidence (context owns "how much")
   double f=MathMax(0.0,MathMin(1.0,g_f16confidence/100.0));
   g_f16sizeMult=InpF16OppSizeMin+(InpF16OppSizeMax-InpF16OppSizeMin)*f;
}

// full structural opposition (used only by the optional, off-by-default veto)
bool F16_FullOpposition(int dir){
   int mtf=(int)DominantBias();
   return(g_f16netBias==-dir && mtf==-dir && g_f16timeDir==-dir);
}

void F16_Update(){
   if(!InpF16Enable) return;
   F16_ScanFU();
   F16_UpdateNodes();
   F16_NetworkScan();
   F16_Time();
   F16_Physics();
   F16_Belief();
   F16_Energy();
   F16_TargetHeat();
   F16_Opportunity();
}



//==================================================================
// F16 DEEP ENGINES — physics · belief · energy/attractor · liq-wave
//   Each one does the SPECIFIC job it was designed for and feeds the
//   single decision resolver below. Reads OHLC + the spec liquidity
//   pools only; never sends or modifies an order itself.
//==================================================================

// f_phys port (chart TF, closed bars) -> velocity / accel / convexity /
// efficiency / displacement / compression + the 5 observation scores
void F16_Physics(){
   int effLen=10; double atr=F16_ATR(_Period,14,1); if(atr<=0.0) atr=PipsToPrice(10.0);
   if(ArraySize(gClose)<effLen+6) return;
   double mv=MathAbs(gClose[1]-gClose[1+effLen]);
   double ps=0.0; for(int i=1;i<=effLen;i++) ps+=MathAbs(gClose[i]-gClose[i+1]);
   g_f16eff=(ps>0.0)?mv/ps:0.0;
   g_f16disp=(gHigh[1]-gLow[1])/MathMax(atr,1e-10);
   double vel=gClose[1]-gClose[2], velP=gClose[2]-gClose[3], velPP=gClose[3]-gClose[4];
   g_f16vel=vel; g_f16acc=vel-velP; double accP=velP-velPP; g_f16conv=g_f16acc-accP;
   double effT=0.65, dispT=1.5;
   g_f16comp=MathMin(100.0,MathMax(0.0,(1.0-MathMin(g_f16disp/dispT,1.0))*60.0+(1.0-MathMin(g_f16eff/effT,1.0))*40.0));
   double convScore=MathMin(MathAbs(g_f16conv)/MathMax(atr*0.01,1e-10)*25.0,100.0);
   bool bDec=(MathAbs(g_f16acc)<MathAbs(accP)*0.8)&&vel>0;
   bool rDec=(MathAbs(g_f16acc)<MathAbs(accP)*0.8)&&vel<0;
   bool vd70=MathAbs(vel)<MathAbs(velP)*0.7, vd50=MathAbs(vel)<MathAbs(velP)*0.5;
   g_f16impBull=(g_f16eff>effT&&vel>velP&&g_f16acc>0&&gClose[1]>gOpen[1]&&g_f16disp>dispT);
   g_f16impBear=(g_f16eff>effT&&vel<velP&&g_f16acc<0&&gClose[1]<gOpen[1]&&g_f16disp>dispT);
   g_f16obsExp=MathMin((g_f16eff>effT?g_f16eff*60.0:g_f16eff*30.0)+(g_f16disp>dispT?(g_f16disp/dispT-1.0)*20.0:0.0)+(((vel>0&&g_f16acc>0)||(vel<0&&g_f16acc<0))?20.0:0.0),100.0);
   g_f16obsDecay=MathMin(((bDec||rDec)?40.0:0.0)+(convScore>30.0?convScore*0.5:0.0)+(vd70?30.0:0.0),100.0);
   g_f16obsCurv=convScore;
   g_f16obsAbs=MathMin((g_f16eff<effT*0.7?(1.0-g_f16eff/effT)*50.0:0.0)+(vd50?30.0:0.0)+(g_f16disp<dispT*0.5?20.0:0.0),100.0);
   g_f16obsLiq=MathMin(g_f16obsDecay*0.4+g_f16obsCurv*0.4+((g_f16disp>dispT*1.2&&(bDec||rDec))?20.0:0.0),100.0);
}

// f_idealSim port — Euclidean fingerprint match (0..100)
double F16_Sim(double e,double d,double v,double c,double ei,double di,double vi,double ci){
   double diff=(e-ei)*(e-ei)+(d-di)*(d-di)+(v-vi)*(v-vi)+(c-ci)*(c-ci);
   return MathMax(0.0,100.0*(1.0-diff/4.0));
}

// Belief engine — similarity fingerprints -> EMA-smoothed phase probabilities ->
// a net belief DIRECTION (trend beliefs hold the prevailing dir, reversal flips it)
void F16_Belief(){
   double effT=0.65,dispT=1.5,atr=F16_ATR(_Period,14,1); if(atr<=0.0) atr=PipsToPrice(10.0);
   double eN=MathMin(g_f16eff,1.0);
   double dN=MathMin(g_f16disp/MathMax(dispT*2.0,1e-10),1.0);
   double vN=MathMin(MathAbs(g_f16vel)/MathMax(atr*0.15,1e-10),1.0);
   double cN=MathMin(MathAbs(g_f16conv)/MathMax(atr*0.02,1e-10),1.0);
   double sExp   =F16_Sim(eN,dN,vN,cN,0.85,0.80,0.80,0.10);
   double sPre   =F16_Sim(eN,dN,vN,cN,0.60,0.55,0.40,0.50);
   double sAbs   =F16_Sim(eN,dN,vN,cN,0.20,0.25,0.10,0.40);
   double sRetr  =F16_Sim(eN,dN,vN,cN,0.70,0.65,0.65,0.25);
   double sCreate=F16_Sim(eN,dN,vN,cN,0.30,0.70,0.05,0.90);
   double sReturn=F16_Sim(eN,dN,vN,cN,0.50,0.40,0.35,0.20);
   int wd=g_f16netBias;
   bool opposing=(wd==1&&g_f16impBear)||(wd==-1&&g_f16impBull);
   double rExp   =MathMin(g_f16obsExp*0.45+((g_f16impBull||g_f16impBear)?30.0:0.0)+(g_f16eff>effT*1.1?15.0:0.0)+sExp*0.10,100.0);
   double rCont  =MathMin(g_f16obsDecay*0.30+g_f16obsCurv*0.25+((g_f16impBull||g_f16impBear)?10.0:0.0)+sPre*0.10,100.0);
   double rAbs   =MathMin(g_f16obsAbs*0.50+(g_f16eff<effT*0.6?25.0:0.0)+(g_f16disp<dispT*0.5?15.0:0.0)+sAbs*0.10,100.0);
   double rRetr  =MathMin((opposing?45.0:0.0)+(rAbs>50.0?rAbs*0.30:0.0)+(g_f16obsCurv>40.0?15.0:0.0)+sRetr*0.10,100.0);
   double rCreate=MathMin((g_f16obsDecay>60.0?g_f16obsDecay*0.20:0.0)+(g_f16obsLiq>50.0?g_f16obsLiq*0.20:0.0)+(g_f16obsAbs>20.0?g_f16obsAbs*0.15:0.0)+sCreate*0.10,100.0);
   double rReturn=MathMin((rRetr>60.0?rRetr*0.30:0.0)+sReturn*0.10,100.0);
   double a=2.0/(3.0+1.0);
   g_f16bExp   +=a*(rExp-g_f16bExp);     g_f16bCont +=a*(rCont-g_f16bCont);
   g_f16bAbsorb+=a*(rAbs-g_f16bAbsorb);  g_f16bRetr +=a*(rRetr-g_f16bRetr);
   g_f16bCreate+=a*(rCreate-g_f16bCreate); g_f16bReturn+=a*(rReturn-g_f16bReturn);
   double trend  =g_f16bExp+g_f16bCont+g_f16bCreate;
   double against=g_f16bRetr+g_f16bAbsorb+g_f16bReturn;
   g_f16beliefDir=(trend>against)?wd:(against>trend)?-wd:0;
}

// Energy / Resolution / Attractor (EDE/RE/EAE-lite) — expansion energy injected
// vs dissipated -> residual; the attractor price + whether the objective is reached
void F16_Energy(){
   double effT=0.65,atr=F16_ATR(_Period,14,1); if(atr<=0.0) atr=PipsToPrice(10.0);
   g_f16expEnergy =MathMin(g_f16obsExp*0.5+((g_f16impBull||g_f16impBear)?30.0:0.0)+g_f16eff*20.0,100.0);
   g_f16dissEnergy=MathMin(g_f16obsDecay*0.4+g_f16obsCurv*0.3+g_f16obsLiq*0.3,100.0);
   g_f16residual  =MathMax(0.0,g_f16expEnergy-g_f16dissEnergy);
   g_f16eaePrice  =(g_f16attrPrice>0.0)?g_f16attrPrice:(g_f16netBias>=0?g_f16fezHi:g_f16fezLo);
   double cl=gClose[1];
   if(g_f16eaePrice>0.0){
      double dist=MathAbs(g_f16eaePrice-cl);
      g_f16objDistPct=MathMin(100.0,dist/MathMax(atr*3.0,1e-10)*100.0);
      g_f16objArrival=(dist<atr*0.75)&&(g_f16eff<effT*0.7);
   } else { g_f16objArrival=false; g_f16objDistPct=100.0; }
   g_f16resCode=((g_f16residual<25.0)&&g_f16objArrival)?2:((g_f16objDistPct<40.0)&&(g_f16dissEnergy>=50.0))?1:0;
}

// Liquidity heat at the target — reuses the spec liquidity pools (the right tool).
// High heat = a firm magnet (good TP); a vacuum = open runway (let the runner breathe)
void F16_TargetHeat(){
   double tgt=(g_f16eaePrice>0.0)?g_f16eaePrice:gClose[1];
   double atr=F16_ATR(_Period,14,1); if(atr<=0.0) atr=PipsToPrice(10.0);
   double radius=atr*1.0, dens=0.0;
   for(int i=0;i<ArraySize(g_liq);i++){
      double d=MathAbs(g_liq[i].price-tgt);
      if(d<radius) dens+=(g_liq[i].isGrabbed?0.3:1.0)*(1.0-d/radius);
   }
   g_f16targetHeat=MathMin(100.0,dens*40.0);
   g_f16targetVacuum=(g_f16targetHeat<20.0);
}

// DECISION RESOLVER — the single arbitration point every engine feeds.
// It sets size (opportunity+belief+heat), the runner target (network+heat), and
// the take/skip verdict (each veto owned by the engine designed to forbid it).
// It NEVER changes the entry trigger or the SL geometry.
void F16_Decision(int dir){
   g_f16decVeto=false; g_f16decReason="";
   // SIZE — opportunity owns "how much"; belief tilts it; a vacuum to target lets it breathe
   double f=MathMax(0.0,MathMin(1.0,g_f16confidence/100.0));
   double sz=InpF16OppSizeMin+(InpF16OppSizeMax-InpF16OppSizeMin)*f;
   if(g_f16beliefDir==dir) sz*=1.10; else if(g_f16beliefDir==-dir) sz*=0.80;
   if(g_f16targetVacuum) sz*=1.05;
   g_f16decSize=MathMax(0.4,MathMin(InpF16OppSizeMax,sz));
   // TARGET — network + heat own "which target"
   g_f16decTarget=(g_f16eaePrice>0.0)?g_f16eaePrice:0.0;
   // VETOES — each engine forbids only the trade IT is designed to forbid
   if(InpF16VetoFullOpp && F16_FullOpposition(dir)){ g_f16decVeto=true; g_f16decReason="network+MTF+time oppose"; return; }
   if(InpF16GateReversal && g_f16beliefDir==-dir && (g_f16bRetr>=InpF16ReversalBlk||g_f16bAbsorb>=InpF16ReversalBlk) && g_f16bRetr>g_f16bCont){
      g_f16decVeto=true; g_f16decReason="reversal/absorption belief dominant"; return; }
   if(InpF16GateObjective && g_f16resCode==2){ g_f16decVeto=true; g_f16decReason="objective reached / energy resolved"; return; }
   if(InpF16GateCycle){
      double ex=(dir==1)?g_f16cycExhLong:g_f16cycExhShort;
      if(ex>=100.0){ g_f16decVeto=true; g_f16decReason="HTF time-cycle exhausted vs dir"; return; }
   }
   if(InpF16GateGrade && (g_f16oppGrade=="NO-TRADE" || g_f16threat>=InpF16ThreatBlock)){
      g_f16decVeto=true; g_f16decReason="grade NO-TRADE / threat high"; return; }
}



// ── F16 ENTRY PARTICIPATION — the FU detector + node network help TAKE entries ──
// A fresh, active, authoritative network FU node rejecting in the trade direction,
// sitting near price = the multi-TF FU detector confirming the rejection. The spec
// lifecycle can use this to satisfy the Phase-2 FU step (alongside the M2/M1 FU candle).
bool F16_FreshFU(int dir){
   if(!InpF16Enable) return false;
   double cl=gClose[1]; double atr=F16_ATR(_Period,14,1); if(atr<=0.0) atr=PipsToPrice(10.0);
   double near=atr*InpF16FUNearATR;
   for(int i=0;i<ArraySize(g_f16nodes);i++){
      if(g_f16nodes[i].state==2) continue;          // consumed
      if(g_f16nodes[i].dir!=dir) continue;          // must reject in the trade direction
      if(F16_Auth(i)<InpF16AuthMin) continue;       // must carry authority
      if(MathAbs(g_f16nodes[i].price-cl)<=near) return true;
   }
   return false;
}
// The engine stack agrees with taking `dir`: network bias not opposed, belief not
// opposed, opportunity grade tradeable. Lets the network CONFIRM (not just veto).
bool F16_Confluent(int dir){
   if(!InpF16Enable || !InpF16Confluence) return true;
   if(g_f16netBias==-dir) return false;
   if(g_f16beliefDir==-dir) return false;
   if(g_f16oppGrade=="NO-TRADE") return false;
   return true;
}



// ── F16 STRUCTURE ANCHOR — the FU detector picks WHICH precise structure the entry
//    is taken off. If an authoritative network FU node (the precise wick) in `dir`
//    sits in/near the refined POI zone, the entry's precision level (its SL/FU
//    anchor) snaps to that FU node — so the entry is taken off the precise FU, not a
//    looser pivot. Prefers the higher-timeframe, higher-authority FU. Returns the
//    spec precision unchanged when no aligned FU node exists.
string F16_WtLabel(int wt){ return wt==9?"MN":wt==8?"W1":wt==7?"D1":wt==6?"H4":wt==5?"H1":wt==4?"M15":wt==3?"M5":"?"; }
double F16_AnchorPrecision(int dir,double zoneLo,double zoneHi,double curPrec){
   g_f16poiAnchored=false; g_f16poiNodeWt=0; g_f16poiNodePx=0.0;
   if(!InpF16Enable || !InpF16AnchorPOI) return curPrec;
   double atr=F16_ATR(_Period,14,1); if(atr<=0.0) atr=PipsToPrice(10.0);
   double tol=atr*InpF16AnchorTolATR;
   double bestRank=-1.0, bestPx=0.0; int bestWt=0;
   for(int i=0;i<ArraySize(g_f16nodes);i++){
      if(g_f16nodes[i].state==2) continue;            // not consumed
      if(g_f16nodes[i].dir!=dir) continue;            // bull FU anchors demand, bear FU anchors supply
      double a=F16_Auth(i); if(a<InpF16AuthMin) continue;
      double px=g_f16nodes[i].price;
      if(px<zoneLo-tol || px>zoneHi+tol) continue;    // must align with this POI structure
      double rank=g_f16nodes[i].wt*1000.0+a;          // prefer higher-TF, higher-authority FU
      if(rank>bestRank){ bestRank=rank; bestPx=px; bestWt=g_f16nodes[i].wt; }
   }
   if(bestRank<0.0) return curPrec;                   // no aligned FU -> keep the spec precision
   g_f16poiAnchored=true; g_f16poiNodeWt=bestWt; g_f16poiNodePx=bestPx;
   return bestPx;                                     // entry taken off the precise FU wick
}



//==================================================================
// SYMPHONY PHASE ENGINE — ported logic (uses gClose/gHigh/gLow series)
//==================================================================
double Sym_ATR(int shift){ double a=F16_ATR(_Period,InpSymATRLen,shift); return (a>0.0?a:PipsToPrice(10.0)); }

bool Sym_PivotHigh(int c){
   int n=ArraySize(gHigh); if(c<=0||c>=n) return false;
   double h=gHigh[c];
   for(int k=1;k<=InpPivotLen;k++){
      if(c+k>=n||c-k<0) return false;
      if(h<=gHigh[c+k]||h<=gHigh[c-k]) return false;
   }
   return true;
}
bool Sym_PivotLow(int c){
   int n=ArraySize(gLow); if(c<=0||c>=n) return false;
   double l=gLow[c];
   for(int k=1;k<=InpPivotLen;k++){
      if(c+k>=n||c-k<0) return false;
      if(l>=gLow[c+k]||l>=gLow[c-k]) return false;
   }
   return true;
}

// inducement / flipzone finder inside the anchor box (mid of the deepest inside bar)
double Sym_FindInduc(int anchorShift,double aHigh,double aLow){
   double best=0.0; int bestDist=-1;
   if(anchorShift>0){
      for(int s=anchorShift-1; s>=0 && s>=anchorShift-InpSymInducLook; s--){
         if(gHigh[s]<aHigh && gLow[s]>aLow){
            int d=MathAbs(anchorShift-s);
            if(bestDist<0||d<bestDist){ bestDist=d; best=(gHigh[s]+gLow[s])*0.5; }
         }
      }
   }
   return (bestDist>=0?best:0.0);
}

void Sym_ResetZones(){
   sym_longInducPrice=0.0; sym_longInducLow=0.0; sym_longInducHigh=0.0;
   sym_shortInducPrice=0.0; sym_shortInducLow=0.0; sym_shortInducHigh=0.0;
   sym_longPreConvSeen=false; sym_shortPreConvSeen=false;
   sym_longOuterBreachSeen=false; sym_shortOuterBreachSeen=false;
}

void Sym_UpdatePhaseEngine(){
   int bars=ArraySize(gClose); if(bars<=(2*InpPivotLen+5)) return;
   int s=1; double closeNow=gClose[s]; double atrRef=Sym_ATR(s);
   int center=InpPivotLen+1; int pivotDir=0; double pivotPrice=0.0; int pivotShift=-1;
   if(center<bars-InpPivotLen){
      if(Sym_PivotHigh(center)){ pivotDir=1; pivotPrice=gHigh[center]; pivotShift=center; }
      else if(Sym_PivotLow(center)){ pivotDir=-1; pivotPrice=gLow[center]; pivotShift=center; }
   }
   // SHORT impulse: last high -> new low
   if(pivotDir==-1 && sym_lastPivotDir==1){
      double r=sym_lastPivotPrice-pivotPrice;
      if(r>atrRef*InpSymImpulseAtr){
         sym_mode=-1; sym_anchorHigh=sym_lastPivotPrice; sym_anchorHighShift=sym_lastPivotShift;
         sym_anchorLow=pivotPrice; sym_anchorLowShift=pivotShift;
         sym_phaseShort=1; sym_phaseLong=0; Sym_ResetZones();
         double lvl=Sym_FindInduc(sym_anchorHighShift,sym_anchorHigh,sym_anchorLow);
         if(lvl>0.0){ sym_shortInducPrice=lvl; sym_shortInducLow=lvl-atrRef*InpSymInducZoneATR; sym_shortInducHigh=lvl+atrRef*InpSymInducZoneATR; }
      }
   }
   // LONG impulse: last low -> new high
   else if(pivotDir==1 && sym_lastPivotDir==-1){
      double r=pivotPrice-sym_lastPivotPrice;
      if(r>atrRef*InpSymImpulseAtr){
         sym_mode=1; sym_anchorLow=sym_lastPivotPrice; sym_anchorLowShift=sym_lastPivotShift;
         sym_anchorHigh=pivotPrice; sym_anchorHighShift=pivotShift;
         sym_phaseLong=1; sym_phaseShort=0; Sym_ResetZones();
         double lvl=Sym_FindInduc(sym_anchorLowShift,sym_anchorHigh,sym_anchorLow);
         if(lvl>0.0){ sym_longInducPrice=lvl; sym_longInducLow=lvl-atrRef*InpSymInducZoneATR; sym_longInducHigh=lvl+atrRef*InpSymInducZoneATR; }
      }
   }
   // persist pivot history
   if(pivotDir!=0){
      sym_prevPivotPrice=sym_lastPivotPrice; sym_prevPivotShift=sym_lastPivotShift; sym_prevPivotDir=sym_lastPivotDir;
      sym_lastPivotPrice=pivotPrice; sym_lastPivotShift=pivotShift; sym_lastPivotDir=pivotDir;
   }
   // impulse invalidation
   if(sym_mode==-1 && closeNow>sym_anchorHigh){ sym_mode=0; sym_phaseShort=0; Sym_ResetZones(); }
   if(sym_mode==1  && closeNow<sym_anchorLow ){ sym_mode=0; sym_phaseLong=0;  Sym_ResetZones(); }

   int oldL=sym_phaseLong, oldS=sym_phaseShort;
   // SHORT side phases
   if(sym_mode!=-1) sym_phaseShort=0;
   if(sym_mode==-1 && sym_anchorHighShift>=0 && sym_anchorLowShift>=0){
      double imp=sym_anchorHigh-sym_anchorLow;
      double retr=(imp>0.0)?(closeNow-sym_anchorLow)/imp:0.0;
      double d=gClose[s]-gClose[s+1];
      int ph;
      if(retr>InpSymRetrMax||retr<0.0) ph=0;
      else if(closeNow<=sym_anchorLow) ph=4;
      else if(retr>=InpSymRetrMin) ph=(d>0.0?2:3);
      else ph=1;
      bool hasZone=(sym_shortInducLow!=0.0||sym_shortInducHigh!=0.0);
      if(ph==3 && hasZone && closeNow<=sym_shortInducHigh) ph=2;
      else if(ph==3) sym_shortPreConvSeen=true;
      if(ph==4 && !sym_shortPreConvSeen) ph=2;
      sym_phaseShort=ph;
   }
   // LONG side phases
   if(sym_mode!=1) sym_phaseLong=0;
   if(sym_mode==1 && sym_anchorHighShift>=0 && sym_anchorLowShift>=0){
      double imp=sym_anchorHigh-sym_anchorLow;
      double retr=(imp>0.0)?(sym_anchorHigh-closeNow)/imp:0.0;
      double d=gClose[s]-gClose[s+1];
      int ph;
      if(retr>InpSymRetrMax||retr<0.0) ph=0;
      else if(closeNow>=sym_anchorHigh) ph=4;
      else if(retr>=InpSymRetrMin) ph=(d<0.0?2:3);
      else ph=1;
      bool hasZone=(sym_longInducLow!=0.0||sym_longInducHigh!=0.0);
      if(ph==3 && hasZone && closeNow>=sym_longInducLow) ph=2;
      else if(ph==3) sym_longPreConvSeen=true;
      if(ph==4 && !sym_longPreConvSeen) ph=2;
      sym_phaseLong=ph;
   }
   sym_prevPhaseLong=oldL; sym_prevPhaseShort=oldS;
}

void Sym_UpdateARC(){
   sym_arcLong=0.0; sym_arcShort=0.0;
   int bars=ArraySize(gClose); if(bars<10) return; int s=1;
   if(sym_mode==1 && sym_anchorLowShift>=0 && sym_anchorHighShift>=0){
      double imp=sym_anchorHigh-sym_anchorLow;
      if(imp>0.0){ double tgt=sym_anchorLow+imp*InpSymArcExt;
         double t=(double)(sym_anchorLowShift-s)/(double)InpSymArcHorizon; if(t<0.0)t=0.0; if(t>1.0)t=1.0;
         sym_arcLong=sym_anchorLow+(tgt-sym_anchorLow)*MathPow(t,InpSymConvPower); }
   }
   if(sym_mode==-1 && sym_anchorLowShift>=0 && sym_anchorHighShift>=0){
      double imp=sym_anchorHigh-sym_anchorLow;
      if(imp>0.0){ double tgt=sym_anchorHigh-imp*InpSymArcExt;
         double t=(double)(sym_anchorHighShift-s)/(double)InpSymArcHorizon; if(t<0.0)t=0.0; if(t>1.0)t=1.0;
         sym_arcShort=sym_anchorHigh+(tgt-sym_anchorHigh)*MathPow(t,InpSymConvPower); }
   }
}



//==================================================================
// SYMPHONY ENTRIES — Phase 3 (full) + Phase 4 (breakout), routed through
// the F16 decision/confluence/FU-anchor layer + snXperFX guards/risk/audit
//==================================================================
void Sym_TryEntry(int dir,string tag){
   if(!TradingAllowed()) return;
   if(CountPositions()>=InpMaxPositions) return;
   if(IsDeadZone()) return;
   if(InpEnforceDeadZone && !InSessionWindow() && InpRequireSessionWindow) return;
   datetime bt=gTime[0];
   if(dir==1  && sym_lastLongTradeTime==bt)  return;
   if(dir==-1 && sym_lastShortTradeTime==bt) return;

   double atr=Sym_ATR(1);
   double entry=(dir==1)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   // PRECISE Symphony stop = anchor +/- ATR*0.25
   double anchor=(dir==1)?sym_anchorLow:sym_anchorHigh;
   // F16 FU detector picks WHICH precise structure the stop is anchored to
   if(InpSymUseF16 && InpF16Enable && InpF16AnchorPOI){
      double aLo=MathMin(sym_anchorLow,sym_anchorHigh), aHi=MathMax(sym_anchorLow,sym_anchorHigh);
      anchor=F16_AnchorPrecision(dir,aLo,aHi,anchor);
   }
   double sl=(dir==1)?(anchor-atr*0.25):(anchor+atr*0.25);
   if(!((dir==1 && entry>sl)||(dir==-1 && sl>entry))) return;

   double riskPct=InpRiskPct;
   // CONNECT to the F16 layer: confluence gate + decision veto/size/target
   if(InpSymUseF16 && InpF16Enable){
      if(InpF16Confluence && !F16_Confluent(dir)) return;
      F16_Decision(dir);
      if(g_f16decVeto){ Print("SYM F16 VETO ",tag," — ",g_f16decReason); return; }
      if(InpF16SizeByOpp) riskPct=MathMax(0.05,riskPct*g_f16decSize);
   }
   if(g_reduceSizing) riskPct*=0.5;

   double stopPips=MathAbs(entry-sl)/MathMax(PipSize(),1e-9);
   if(stopPips<InpMinStopPips){ stopPips=InpMinStopPips; sl=(dir==1)?(entry-PipsToPrice(stopPips)):(entry+PipsToPrice(stopPips)); }
   double eq=AccountInfoDouble(ACCOUNT_EQUITY); double riskUSD=eq*riskPct/100.0;
   double lots=ComputeLots(riskUSD,stopPips); if(lots<=0.0) return;
   double newRisk=stopPips*PipValuePerLot()*lots; double maxTotal=eq*InpMaxTotalRisk/100.0;
   if(OpenRiskUSD()+newRisk>maxTotal){ double avail=maxTotal-OpenRiskUSD(); if(avail<=0.0)return; lots=ComputeLots(avail,stopPips); if(lots<=0.0)return; }

   // TARGETS — ARC (Symphony) primary, F16 attractor as the extended runner
   double arc=(dir==1)?sym_arcLong:sym_arcShort;
   double tp1=(arc>0.0)?arc:(dir==1?entry+PipsToPrice(InpHardTPPips):entry-PipsToPrice(InpHardTPPips));
   double tp2=tp1;
   if(InpSymUseF16 && InpF16Enable && g_f16decTarget>0.0){
      bool ahead=(dir==1)?(g_f16decTarget>entry):(g_f16decTarget<entry);
      if(ahead) tp2=g_f16decTarget;
   }
   string cmt="SYM "+tag;
   if(SendOrder(dir,lots,sl,0.0,cmt)){
      AdoptPosition(dir,sl,tp1,tp2,0.0,anchor,stopPips,lots,riskPct,ENTRY_REFINED);
      if(dir==1) sym_lastLongTradeTime=bt; else sym_lastShortTradeTime=bt;
      Print("SYM ENTRY ",tag," @",DoubleToString(entry,_Digits)," SL ",DoubleToString(sl,_Digits),
            " (",DoubleToString(stopPips,1),"p) lots ",DoubleToString(lots,2),
            " phase ",(dir==1?sym_phaseLong:sym_phaseShort),
            (g_f16poiAnchored?(" anchor "+F16_WtLabel(g_f16poiNodeWt)+" FU"):" anchor pivot"),
            "  | F16 ",g_f16oppGrade," sz x",DoubleToString(g_f16decSize,2),
            " arc ",DoubleToString(tp1,_Digits)," tgt ",DoubleToString(tp2,_Digits));
   }
}

void Sym_ExecuteEntries(){
   if(!InpSymEnable) return;
   double atr=Sym_ATR(1); double cl=gClose[1];
   bool L3=(sym_mode==1  && sym_phaseLong ==3);
   bool L4=(sym_mode==1  && sym_phaseLong ==4);
   bool S3=(sym_mode==-1 && sym_phaseShort==3);
   bool S4=(sym_mode==-1 && sym_phaseShort==4);
   if(L3) Sym_TryEntry(1,"P3 Long");
   if(L4){ bool bo=(cl>sym_anchorHigh || cl>gHigh[2]+0.20*atr); if(bo) Sym_TryEntry(1,"P4 Long"); }
   if(S3) Sym_TryEntry(-1,"P3 Short");
   if(S4){ bool bo=(cl<sym_anchorLow  || cl<gLow[2]-0.20*atr);  if(bo) Sym_TryEntry(-1,"P4 Short"); }
}



//==================================================================
// SYMPHONY EXITS — ARC exhaustion + institutional outer-band sweep +
// phase-change-at-extreme composite (closes only SYM-tagged positions)
//==================================================================
void Sym_ManageExits(){
   if(!InpSymEnable) return;
   int bars=ArraySize(gClose); if(bars<=(2*InpPivotLen+5)) return;
   double closeNow=gClose[1]; double atr=Sym_ATR(1);

   bool arcExhaustLong  = (sym_mode==1  && sym_arcLong >0.0 && closeNow>=(sym_arcLong -InpSymArcTolATR*atr));
   bool arcExhaustShort = (sym_mode==-1 && sym_arcShort>0.0 && closeNow<=(sym_arcShort+InpSymArcTolATR*atr));

   double instLevelL=(sym_longInducPrice!=0.0?sym_longInducPrice:(sym_anchorHigh>0.0?sym_anchorHigh:0.0));
   double innerTopL =(sym_longInducHigh>0.0?sym_longInducHigh:instLevelL);
   double outerTopL =innerTopL+InpSymOuterBandATR*atr;
   double instLevelS=(sym_shortInducPrice!=0.0?sym_shortInducPrice:(sym_anchorLow>0.0?sym_anchorLow:0.0));
   double innerBotS =(sym_shortInducLow>0.0?sym_shortInducLow:instLevelS);
   double outerBotS =innerBotS-InpSymOuterBandATR*atr;

   if(sym_mode==1  && instLevelL>0.0 && closeNow>outerTopL) sym_longOuterBreachSeen=true;
   if(sym_mode==-1 && instLevelS>0.0 && closeNow<outerBotS) sym_shortOuterBreachSeen=true;

   bool phaseEndLong  = (sym_mode==1  && (sym_prevPhaseLong ==3||sym_prevPhaseLong ==4) && sym_phaseLong <=1);
   bool phaseEndShort = (sym_mode==-1 && (sym_prevPhaseShort==3||sym_prevPhaseShort==4) && sym_phaseShort<=1);

   bool exitLong=false, exitShort=false;
   if(sym_mode==1 && arcExhaustLong && phaseEndLong){
      bool ok=(instLevelL<=0.0) || (sym_longOuterBreachSeen && closeNow<innerTopL);
      if(ok) exitLong=true;
   }
   if(sym_mode==-1 && arcExhaustShort && phaseEndShort){
      bool ok=(instLevelS<=0.0) || (sym_shortOuterBreachSeen && closeNow>innerBotS);
      if(ok) exitShort=true;
   }
   if(!exitLong && !exitShort) return;

   int total=PositionsTotal();
   for(int i=total-1;i>=0;i--){
      ulong tk=PositionGetTicket(i); if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol||PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT),"SYM")<0) continue;   // only Symphony-opened positions
      long type=PositionGetInteger(POSITION_TYPE);
      if(exitLong  && type==POSITION_TYPE_BUY)  ClosePositionFull(tk,"SYM ARC/PHASE EXIT");
      if(exitShort && type==POSITION_TYPE_SELL) ClosePositionFull(tk,"SYM ARC/PHASE EXIT");
   }
}
