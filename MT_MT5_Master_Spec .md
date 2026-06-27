# snXper FX — MT5 Algorithm Master Specification
**Version:** 1.0  
**Status:** REFERENCE  
**Source:** 5 trading session transcripts + formal system spec + trading ontology  
**Language target:** MQL5 (MetaTrader 5)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Enumerations & Constants](#2-enumerations--constants)
3. [Data Structures](#3-data-structures)
4. [Core Engine Modules](#4-core-engine-modules)
5. [Structural Phase State Machine](#5-structural-phase-state-machine)
6. [Trade Lifecycle State Machine](#6-trade-lifecycle-state-machine)
7. [Daily Cycle State Machine](#7-daily-cycle-state-machine)
8. [POI Validation Engine](#8-poi-validation-engine)
9. [Order Flow Shift Detector](#9-order-flow-shift-detector)
10. [Entry Execution Logic](#10-entry-execution-logic)
11. [Exit & Position Management](#11-exit--position-management)
12. [Risk Management Module](#12-risk-management-module)
13. [Correlation & Multi-Asset Filter](#13-correlation--multi-asset-filter)
14. [Session & Timing Module](#14-session--timing-module)
15. [Liquidity Pool Tracker](#15-liquidity-pool-tracker)
16. [Audit & Logging Module](#16-audit--logging-module)
17. [Input Parameters](#17-input-parameters)
18. [Execution Flow (OnTick / OnBar)](#18-execution-flow-ontick--onbar)
19. [Invalidation & Safety Guards](#19-invalidation--safety-guards)
20. [Implementation Notes & Constraints](#20-implementation-notes--constraints)

---

## 1. Architecture Overview

The EA is a **multi-module, state-driven system**. It does not use indicator crossovers or arbitrary conditions. Every decision cascades from a top-down structural analysis and is gated by a deterministic process checklist. No trade may be placed unless all hard-rule gates pass.

```
┌─────────────────────────────────────────────────────┐
│                   OnTick / OnBar                     │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────┐  │
│  │  Session &  │  │  Structural  │  │  Correl.   │  │
│  │  Timing     │  │  Cascade     │  │  Filter    │  │
│  └──────┬──────┘  └──────┬───────┘  └─────┬──────┘  │
│         │                │                │          │
│         └────────────────┴────────────────┘          │
│                          │                           │
│              ┌───────────▼────────────┐              │
│              │   Phase State Machine  │              │
│              │  (per-TF, per-symbol)  │              │
│              └───────────┬────────────┘              │
│                          │                           │
│              ┌───────────▼────────────┐              │
│              │  POI Validation Engine │              │
│              │  (4-criterion filter)  │              │
│              └───────────┬────────────┘              │
│                          │                           │
│              ┌───────────▼────────────┐              │
│              │  Order Flow Detector   │              │
│              │  (3-shift model)       │              │
│              └───────────┬────────────┘              │
│                          │                           │
│              ┌───────────▼────────────┐              │
│              │  Process Checklist     │              │
│              │  (ALL gates must pass) │              │
│              └───────────┬────────────┘              │
│                          │                           │
│              ┌───────────▼────────────┐              │
│              │  Execution + Risk Mgmt │              │
│              └───────────┬────────────┘              │
│                          │                           │
│              ┌───────────▼────────────┐              │
│              │  Audit Logger          │              │
│              └────────────────────────┘              │
└─────────────────────────────────────────────────────┘
```

---

## 2. Enumerations & Constants

```mql5
//+------------------------------------------------------------------+
//| STRUCTURAL BIAS                                                   |
//+------------------------------------------------------------------+
enum ENUM_BIAS {
    BIAS_BULLISH  = 1,
    BIAS_BEARISH  = -1,
    BIAS_NEUTRAL  = 0
};

//+------------------------------------------------------------------+
//| 5-PHASE STRUCTURAL CYCLE                                          |
//+------------------------------------------------------------------+
enum ENUM_STRUCTURAL_PHASE {
    PHASE_1         = 1,   // Corrective pullback to external POI
    PRE_PHASE_2A    = 2,   // Arriving at POI; internal liquidity building
    PHASE_2         = 3,   // Institutional interaction; FU candle
    PHASE_3         = 4,   // 3-shift OFB complete; entry zone
    PHASE_4         = 5,   // Expansion impulse underway
    PHASE_5         = 6    // New external structural landmark created
};

//+------------------------------------------------------------------+
//| TRADE LIFECYCLE STATES                                            |
//+------------------------------------------------------------------+
enum ENUM_TRADE_STATE {
    TS_IDLE             = 0,
    TS_POI_WATCH        = 1,
    TS_PRE_PHASE_2A     = 2,
    TS_PHASE_2          = 3,
    TS_ORDER_FLOW_SHIFT = 4,
    TS_ENTRY_PENDING    = 5,
    TS_OPEN_INITIAL     = 6,
    TS_OPEN_RUNNER      = 7,
    TS_BREAK_EVEN       = 8,
    TS_SCALING          = 9,
    TS_CLOSED_WIN       = 10,
    TS_CLOSED_LOSS      = 11,
    TS_CLOSED_BREAKEVEN = 12,
    TS_INVALIDATED      = 13
};

//+------------------------------------------------------------------+
//| DAILY CYCLE STATES                                                |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| DAILY CYCLE TYPE                                                  |
//+------------------------------------------------------------------+
enum ENUM_DAILY_CYCLE_TYPE {
    DCT_BULLISH         = 1,
    DCT_BEARISH         = -1,
    DCT_UNDETERMINED    = 0
};

//+------------------------------------------------------------------+
//| SESSION MODEL                                                     |
//+------------------------------------------------------------------+
enum ENUM_SESSION_MODEL {
    SM_TWO_SIDED   = 0,   // Both Asia H and L raided in same day
    SM_ONE_SIDED   = 1    // Only one side raided; rare variant
};

//+------------------------------------------------------------------+
//| POI TYPE                                                          |
//+------------------------------------------------------------------+
enum ENUM_POI_TYPE {
    POI_DEMAND = 1,
    POI_SUPPLY = -1
};

//+------------------------------------------------------------------+
//| ENTRY TYPE                                                        |
//+------------------------------------------------------------------+
enum ENUM_ENTRY_TYPE {
    ENTRY_REFINED     = 0,   // M5/M2/M1 precision — preferred
    ENTRY_AGGRESSIVE  = 1    // HTF zone only; wider stop; smaller size
};

//+------------------------------------------------------------------+
//| LIQUIDITY POOL TYPE                                               |
//+------------------------------------------------------------------+
enum ENUM_LIQUIDITY_TYPE {
    LIQ_EQUAL_HIGHS     = 0,
    LIQ_EQUAL_LOWS      = 1,
    LIQ_TRENDLINE_HIGH  = 2,
    LIQ_TRENDLINE_LOW   = 3,
    LIQ_ASIA_HIGH       = 4,
    LIQ_ASIA_LOW        = 5,
    LIQ_SYDNEY_HIGH     = 6,
    LIQ_SYDNEY_LOW      = 7,
    LIQ_LONDON_HIGH     = 8,
    LIQ_LONDON_LOW      = 9,
    LIQ_PREV_DAY_HIGH   = 10,
    LIQ_PREV_DAY_LOW    = 11,
    LIQ_WEEK_HIGH       = 12,
    LIQ_WEEK_LOW        = 13,
    LIQ_ROUND_NUMBER    = 14
};

//+------------------------------------------------------------------+
//| ORDER FLOW BREAK TYPE                                             |
//+------------------------------------------------------------------+
enum ENUM_OFB_TYPE {
    OFB_NONE     = 0,
    OFB_EXTERNAL = 1,   // First shift
    OFB_INTERNAL = 2,   // Second shift
    OFB_FINAL    = 3    // Third shift — entry permitted
};

//+------------------------------------------------------------------+
//| BOS STRENGTH                                                      |
//+------------------------------------------------------------------+
enum ENUM_BOS_STRENGTH {
    BOS_IMPULSIVE  = 0,   // Clean body through level
    BOS_WICK_ONLY  = 1    // Wick poke; not confirmed continuation
};

//+------------------------------------------------------------------+
//| TIMEFRAME INDICES (for array-based TF cascade)                   |
//+------------------------------------------------------------------+
// Map to MT5 ENUM_TIMEFRAMES:
// TF_IDX_MONTHLY = PERIOD_MN1
// TF_IDX_WEEKLY  = PERIOD_W1
// TF_IDX_DAILY   = PERIOD_D1
// TF_IDX_H8      = PERIOD_H8  (use H4 ×2 if H8 unavailable)
// TF_IDX_H4      = PERIOD_H4
// TF_IDX_H1      = PERIOD_H1
// TF_IDX_M30     = PERIOD_M30
// TF_IDX_M15     = PERIOD_M15
// TF_IDX_M5      = PERIOD_M5
// TF_IDX_M2      = PERIOD_M2
// TF_IDX_M1      = PERIOD_M1
#define TF_COUNT 11

//+------------------------------------------------------------------+
//| CONSTANTS                                                         |
//+------------------------------------------------------------------+
// Gold / XAUUSD
#define GOLD_SESSION_OPEN_GMT    23   // Gold daily candle open hour (GMT)
#define GOLD_CLOSE_WARN_GMT      21   // Spread widening window start
#define GOLD_SPREAD_BUFFER_PIPS   4   // Add to stop during close window

// FX majors
#define FX_SESSION_OPEN_GMT      22   // FX daily rollover (GMT)

// Algorithmic windows (GMT hours)
#define ALG_SYDNEY_RAID_HOUR     0    // 00:00–01:00 GMT
#define ALG_ASIA_T_HIGH_HOUR     3    // ~03:00 GMT
#define ALG_ASIA_LOW_HOUR        5    // ~05:00 GMT
#define ALG_FRANKFURT_HOUR       7    // Frankfurt 07:00 GMT
#define ALG_NY_CROSS_HOUR        12   // London/NY cross 12:00 GMT
#define ALG_LATE_SESSION_HOUR    16   // Secondary window 16:00 GMT
#define ALG_DAILY_CLOSE_HOUR     21   // Close management 21:00 GMT

// Risk defaults (overridable via inputs)
#define DEFAULT_MAX_RISK_PCT      1.5
#define DEFAULT_MAX_TOTAL_RISK    3.0
#define DEFAULT_COUNTER_RISK_PCT  0.5
#define DEFAULT_MAX_POSITIONS     3
#define DEFAULT_MIN_RR            10.0
#define DEFAULT_HARD_TP_PIPS      40
#define DEFAULT_GOLD_STOP_MAX      6   // pips — wider = not refined enough
#define DAILY_LOSS_LIMIT_PCT       3.0
#define WEEKLY_LOSS_LIMIT_PCT      5.0
```

---

## 3. Data Structures

```mql5
//+------------------------------------------------------------------+
//| TFState — per-timeframe structural state                          |
//+------------------------------------------------------------------+
struct TFState {
    ENUM_BIAS           bias;
    double              externalHigh;
    double              externalLow;
    double              lastBOSPrice;
    datetime            lastBOSTime;
    ENUM_BOS_STRENGTH   bosStrength;
    bool                chochDetected;
    double              chochPrice;
    datetime            chochTime;
    ENUM_STRUCTURAL_PHASE currentPhase;
    string              timeframeLabel;     // e.g. "H4", "M30"
    ENUM_TIMEFRAMES     mtPeriod;
};

//+------------------------------------------------------------------+
//| LiquidityPool                                                     |
//+------------------------------------------------------------------+
struct LiquidityPool {
    double              price;
    ENUM_LIQUIDITY_TYPE type;
    datetime            createdTime;
    double              pipDisplacement;    // reaction size in pips
    double              estimatedLots;      // pipDisplacement × 100000
    bool                isGrabbed;
    datetime            raidTime;
    string              label;
};

//+------------------------------------------------------------------+
//| POI — Point of Interest                                           |
//+------------------------------------------------------------------+
struct POI {
    double              priceHigh;
    double              priceLow;
    double              precisionLevel;         // "last liquidity left of POI"
    ENUM_TIMEFRAMES     originTimeframe;
    ENUM_TIMEFRAMES     refinedTimeframe;
    ENUM_POI_TYPE       type;

    // 4 Criteria — ALL must be true for isValid = true
    bool                c1_lastSellBuyZone;     // Caused prior external BOS
    bool                c2_freeLiquidityIncoming; // Free of & incoming liquidity
    bool                c3_belowFlipZone;        // Below/above flip zone
    bool                c4_precisionLeft;         // Sub-zone identified

    bool                isValid;                // c1 && c2 && c3 && c4
    double              flipZonePrice;
    LiquidityPool       feedingPools[];         // Liquidity pulling price here
    datetime            identifiedTime;
    bool                isActive;
};

//+------------------------------------------------------------------+
//| ProcessChecklist — must be TRUE before order placement            |
//+------------------------------------------------------------------+
struct ProcessChecklist {
    bool step1_structureCascade;     // Monthly→H4 labeled with bias
    bool step1_timeframeLabelsSet;   // All TF labels written
    bool step2_phaseIdentified;      // Phase 1–5 labeled on entry TF
    bool step2_correctPhase;         // Phase = PHASE_3 for new entries
    bool step3_poiIdentified;        // POI located
    bool step3_allCriteriaPass;      // All 4 POI criteria TRUE
    bool step4_liquidityMapped;      // Session H/L, EQL, EQH marked
    bool step4_liquidityIncoming;    // Liquidity pulling toward POI
    bool step5_ofb1_external;        // External OFB confirmed
    bool step5_ofb2_internal;        // Internal OFB confirmed
    bool step5_ofb3_final;           // Final OFB confirmed (3-shift complete)
    bool step6_entryRefined;         // POI refined to M5/M2/M1
    bool step6_fuCandle;             // FU candle confirmed
    bool step7_timeOK;               // Not in dead zone (Sydney building)
    bool step7_hardTPSet;            // Hard TP set if near session end
    bool step8_correlationOK;        // DXY/US30/YenBasket/EURUSD confirm
    bool step8_noImmediateNews;      // No high-impact event <30 min

    bool allPass() {
        // Hard gates only — soft rules are advisory
        return step1_structureCascade && step2_correctPhase &&
               step3_allCriteriaPass && step5_ofb3_final &&
               step6_fuCandle && step7_timeOK && step8_correlationOK &&
               step8_noImmediateNews;
    }
};

//+------------------------------------------------------------------+
//| TradeRecord — one trade, including full audit trail               |
//+------------------------------------------------------------------+
struct TradeRecord {
    ulong               ticketId;
    string              symbol;
    int                 direction;          // 1 = LONG, -1 = SHORT
    double              entryPrice;
    double              stopLoss;
    double              stopLossPips;
    double              tp1;
    double              tp2;
    double              hardTP;
    double              lots;
    double              riskUSD;
    double              rRatio;
    ENUM_ENTRY_TYPE     entryType;
    POI                 poiUsed;
    ENUM_TRADE_STATE    state;
    ProcessChecklist    checklist;
    datetime            openTime;
    datetime            closeTime;
    double              pnlPips;
    double              pnlUSD;
    bool                stepsFollowed;
    bool                structureCorrect;
    bool                poiValid;
    bool                threeShiftComplete;
    string              notes;
    string              failureStep;        // If stepsFollowed=false: which step
};

//+------------------------------------------------------------------+
//| MarketState — top-level container                                 |
//+------------------------------------------------------------------+
struct MarketState {
    string              symbol;
    TFState             tfStack[TF_COUNT];
    ENUM_STRUCTURAL_PHASE phase;
    ENUM_DAILY_CYCLE_TYPE dailyCycleType;
    ENUM_SESSION_MODEL  sessionModel;
    ENUM_DAILY_CYCLE_STATE dailyCycleState;
    POI                 activePOI;
    bool                hasPOI;
    LiquidityPool       liquidityMap[];
    ENUM_BIAS           dxyBias;
    ENUM_BIAS           eurusdBias;
    ENUM_BIAS           yenBasketBias;
    ENUM_BIAS           us30Bias;
    double              dailyOpenPrice;
    double              sydneyHigh;
    double              sydneyLow;
    double              asiaHigh;
    double              asiaLow;
    double              londonHigh;
    double              londonLow;
    double              tHigh;              // Temporary High (bullish cycle)
    double              tLow;               // Temporary Low  (bearish cycle)
    double              trueHighOfDay;
    double              trueLowOfDay;
    bool                tldPrinted;
    bool                thdPrinted;
    ENUM_TRADE_STATE    tradeState;
    TradeRecord         activeTrades[];
};
```

---

## 4. Core Engine Modules

The EA is composed of eight independently testable modules called in sequence on each bar close (H1 or lower):

| # | Module | Responsibility |
|---|--------|---------------|
| 1 | `StructuralCascade` | Builds `TFState[TF_COUNT]` top-down; labels bias, external highs/lows, BOS events |
| 2 | `PhaseEngine` | Determines `ENUM_STRUCTURAL_PHASE` for each TF and the primary entry TF |
| 3 | `SessionModule` | Tracks `ENUM_DAILY_CYCLE_STATE`; stamps Sydney/Asia/London H/L |
| 4 | `LiquidityTracker` | Identifies and marks all `LiquidityPool` objects; flags when pools are raided |
| 5 | `POIEngine` | Validates POI against all 4 criteria; maintains `activePOI` |
| 6 | `OFBDetector` | Tracks the 3-shift order flow model; advances trade state |
| 7 | `RiskModule` | Computes lot size, validates exposure limits, enforces daily/weekly caps |
| 8 | `CorrelationFilter` | Reads DXY, EURUSD, US30, YenBasket states; returns confluence bool |

---

## 5. Structural Phase State Machine

**Critical rule:** The same asset is in different phases on different timeframes simultaneously. H4 may be in Phase 1 while M15 is in Phase 5. The entry timeframe phase governs execution; the HTF phase governs bias.

```
PHASE_5 ──► PHASE_1 ──► PRE_PHASE_2A ──► PHASE_2 ──► PHASE_3 ──► PHASE_4 ──► PHASE_5
              │                │              │             │
              │                │              │             └──► PHASE_1 (if POI blown)
              │                └──► PHASE_1   └──► PHASE_1 (if POI blown)
              │              (flip zone rejection;
              │               continue to true POI)
              └──► PRE_PHASE_2A (mid-expansion pullback; scaling opportunity)
```

### State Definitions

| State | Description | Entry Permitted? |
|-------|-------------|-----------------|
| `PHASE_1` | Corrective leg. Internal trend AGAINST external bias. Building internal liquidity. Purpose: return to POI. | ❌ No |
| `PRE_PHASE_2A` | Arriving at POI. Equal lows/highs forming. Liquidity engineering in progress. FU not yet printed. | ❌ No |
| `PHASE_2` | FU candle printed. External OFB confirmed. Institutional interaction. CHoCH from internal corrective trend. | ⚠️ Aggressive only |
| `PHASE_3` | All 3 OFB shifts confirmed. Internal + final break complete. | ✅ Full entry |
| `PHASE_4` | Expansion underway. Progressive order flow established. | ✅ Scaling entries only |
| `PHASE_5` | New external structural high or low created. Triggers Phase 1 of next cycle. | ❌ No (cycle resets) |

### Transition Logic (pseudocode)

```mql5
void PhaseEngine::Update(TFState &tf, MarketState &ms) {

    switch(tf.currentPhase) {

        case PHASE_5:
            // New external high/low just printed → start corrective leg
            if(NewExternalLandmarkPrinted(tf))
                tf.currentPhase = PHASE_1;
            break;

        case PHASE_1:
            // Price arrived at external POI zone
            if(PriceInsidePOIZone(ms.activePOI) && InternalLiquidityBuilding(ms))
                tf.currentPhase = PRE_PHASE_2A;
            // HTF landmark broken against bias → invalidate
            if(HTFLandmarkBroken(tf))
                return; // Signal full re-analysis
            break;

        case PRE_PHASE_2A:
            // FU candle + external OFB fires
            if(FUCandleDetected() && ExternalOFBConfirmed())
                tf.currentPhase = PHASE_2;
            // Price breaks through zone impulsively → go deeper
            if(PriceBlowsThroughPOI())
                tf.currentPhase = PHASE_1;
            // Flip zone rejection → return to Phase 1 for deeper POI
            if(PriceRejectsAtFlipZone())
                tf.currentPhase = PHASE_1;
            break;

        case PHASE_2:
            // All 3 OFB shifts complete
            if(ThreeShiftModelComplete())
                tf.currentPhase = PHASE_3;
            // Zone blown
            if(ZoneBlownImpulsively())
                tf.currentPhase = PHASE_1;
            break;

        case PHASE_3:
            // Entry executed; expansion beginning
            if(EntryExecuted())
                tf.currentPhase = PHASE_4;
            break;

        case PHASE_4:
            // New structural high/low created
            if(NewExternalLandmarkPrinted(tf))
                tf.currentPhase = PHASE_5;
            // Mid-expansion pullback to internal POI (scaling)
            if(PullbackToInternalPOI())
                tf.currentPhase = PRE_PHASE_2A;
            break;
    }
}
```

---

## 6. Trade Lifecycle State Machine

```
IDLE → POI_WATCH → PRE_PHASE_2A → PHASE_2 → ORDER_FLOW_SHIFT → ENTRY_PENDING
                                                                      │
                                        ┌─────────────────────────────┘
                                        ▼
                                  OPEN_INITIAL ──► CLOSED_LOSS (stop hit)
                                        │
                                        ├──► BREAK_EVEN ──► CLOSED_WIN
                                        │                └──► CLOSED_BREAKEVEN
                                        │
                                        └──► OPEN_RUNNER ──► SCALING ──► CLOSED_WIN
                                                         └──► CLOSED_WIN
                                                         └──► BREAK_EVEN

INVALIDATED ← (from POI_WATCH, PRE_PHASE_2A, PHASE_2 when zone blown or bias broken)
```

### Transition Triggers

| FROM | TO | TRIGGER |
|------|----|---------|
| `IDLE` | `POI_WATCH` | Valid POI (all 4 criteria) confirmed AND market in Phase 1 approaching zone |
| `POI_WATCH` | `IDLE` | HTF external landmark broken against bias |
| `POI_WATCH` | `PRE_PHASE_2A` | Price enters POI zone; internal liquidity (equal lows) building |
| `PRE_PHASE_2A` | `PHASE_2` | FU candle printed; external OFB confirmed |
| `PRE_PHASE_2A` | `INVALIDATED` | Price breaks through POI zone impulsively |
| `PHASE_2` | `ORDER_FLOW_SHIFT` | Internal OFB + Final OFB = 3 shifts complete |
| `PHASE_2` | `INVALIDATED` | Price continues through zone after FU without reversing |
| `ORDER_FLOW_SHIFT` | `ENTRY_PENDING` | ProcessChecklist.allPass() = TRUE; order placed |
| `ENTRY_PENDING` | `OPEN_INITIAL` | Order filled |
| `ENTRY_PENDING` | `IDLE` | Price misses precision level; re-assess |
| `OPEN_INITIAL` | `OPEN_RUNNER` | TP1 hit; partial close executed |
| `OPEN_INITIAL` | `CLOSED_LOSS` | Stop loss hit |
| `OPEN_INITIAL` | `BREAK_EVEN` | Stop manually moved to entry |
| `OPEN_RUNNER` | `SCALING` | New valid POI in same direction found during Phase 4 expansion |
| `OPEN_RUNNER` | `CLOSED_WIN` | TP2 / hard TP / manual close at external structure |
| `OPEN_RUNNER` | `BREAK_EVEN` | Stop moved to entry on runner after TP1 |
| `BREAK_EVEN` | `CLOSED_WIN` | TP2 hit |
| `BREAK_EVEN` | `CLOSED_BREAKEVEN` | Price reverses to entry |

---

## 7. Daily Cycle State Machine

**Gold resets at 23:00 GMT. FX resets at 22:00 GMT.**

```
SYDNEY_RANGE_BUILDING (23:00–00:00)
        │ 00:00 trigger
        ▼
ALGORITHM_RAID (00:00–01:00)
 → Sydney LOW raided? → DCT_BULLISH
 → Sydney HIGH raided? → DCT_BEARISH
        │ Day type confirmed
        ▼
ASIA_RANGE_FORMING (01:00–03:00)
 → Bullish: T-High forming ~03:00
 → Bearish: T-Low forming ~03:00
        │ ~03:00
        ▼
ASIA_EXPANSION (03:00–05:00)
 → Bullish: Asia Low prints ~05:00
 → Bearish: Asia High prints ~05:00
        │ ~05:00
        ▼
FRANKFURT_RAID (05:00–07:00)
 → Bullish day: raids Asia Low
 → Bearish day: raids Asia High
        │ 07:00
        ▼
LONDON_OPEN (07:00–12:00)
 → London creates own High & Low
 → Rare: TLD printed here (see ONE_SIDED model)
        │ 12:00
        ▼
NY_CROSS_RAID (12:00–13:00) ← HIGHEST PROBABILITY ENTRY WINDOW
 → Bullish: raids London Low → TLD confirmed
 → Bearish: raids London High → THD confirmed
        │ TLD/THD + 3-shift OFB at POI
        ▼
EXPANSION (13:00–17:00)
 → Primary intraday directional move
        │ 17:00
        ▼
LATE_SESSION (17:00–21:00)
 → Secondary 4–6 PM window (secondary low/high print possible)
        │ 21:00
        ▼
DAILY_CLOSE (21:00–23:00)
 → Gold spread widens; all unmanaged positions need hard TPs
        │ 23:00 Gold / 22:00 FX
        └──► SYDNEY_RANGE_BUILDING (next cycle)
```

### Daily Cycle State — MQL5 Logic

```mql5
ENUM_DAILY_CYCLE_STATE SessionModule::GetCurrentState(string symbol) {
    int gmtHour = GetGMTHour(TimeCurrent());
    bool isGold = (StringFind(symbol, "XAU") >= 0);
    int openHour = isGold ? GOLD_SESSION_OPEN_GMT : FX_SESSION_OPEN_GMT;

    // Determine relative hour from session open
    if(gmtHour == 23 && isGold)            return DC_SYDNEY_RANGE_BUILDING;
    if(gmtHour == 0)                        return DC_ALGORITHM_RAID;
    if(gmtHour >= 1 && gmtHour < 3)        return DC_ASIA_RANGE_FORMING;
    if(gmtHour >= 3 && gmtHour < 5)        return DC_ASIA_EXPANSION;
    if(gmtHour >= 5 && gmtHour < 7)        return DC_FRANKFURT_RAID;
    if(gmtHour >= 7 && gmtHour < 12)       return DC_LONDON_OPEN;
    if(gmtHour >= 12 && gmtHour < 13)      return DC_NY_CROSS_RAID;
    if(gmtHour >= 13 && gmtHour < 17)      return DC_EXPANSION;
    if(gmtHour >= 17 && gmtHour < 21)      return DC_LATE_SESSION;
    if(gmtHour >= 21)                       return DC_DAILY_CLOSE;

    return DC_SYDNEY_RANGE_BUILDING;
}
```

---

## 8. POI Validation Engine

**All 4 criteria must be TRUE. Any single failure = POI invalid. Do not enter.**

```mql5
bool POIEngine::Validate(POI &poi, MarketState &ms, TFState &entryTF) {

    // ── Criterion 1: Last sell-to-buy (or buy-to-sell) zone before BOS ──────
    // The POI candle must be the FINAL zone before the prior external BOS,
    // not an arbitrary candle cluster.
    poi.c1_lastSellBuyZone = IsLastZoneBeforeBOS(poi, entryTF);

    // ── Criterion 2: POI candle free of liquidity; incoming liquidity present ─
    // (a) The institutional candle inside the POI must NOT be sitting on
    //     equal highs or equal lows (no stop cluster beneath it).
    // (b) Between current price and the POI there must be INCOMING liquidity
    //     (equal lows, trendline lows for demand; equal highs, trendline highs
    //     for supply). This fuel is what magnetises price to the zone.
    bool freeOfLiquidity  = !IsOnEqualHighsOrLows(poi, ms.liquidityMap);
    bool incomingLiquidity = HasIncomingLiquidityToPOI(poi, ms.liquidityMap);
    poi.c2_freeLiquidityIncoming = freeOfLiquidity && incomingLiquidity;

    // ── Criterion 3: POI must be below flip zone (demand) / above (supply) ───
    // Identify the flip zone: the cluster of S/R candles most retail
    // participants are watching. True institutional zone is always deeper.
    // Any POI at or above the flip zone for buys is an INDUCEMENT zone — skip.
    poi.c3_belowFlipZone = IsBelowFlipZone(poi, ms);

    // ── Criterion 4: Precision sub-zone ("last liquidity left of POI") ────────
    // Within the valid zone, locate the specific candles that last grabbed
    // liquidity before the institutional candle fired. These stop-loss levels
    // become the magnet. This sub-zone allows 2–6 pip stop placements.
    poi.c4_precisionLeft = IdentifyPrecisionSubZone(poi, ms);

    poi.isValid = poi.c1_lastSellBuyZone &&
                  poi.c2_freeLiquidityIncoming &&
                  poi.c3_belowFlipZone &&
                  poi.c4_precisionLeft;

    return poi.isValid;
}
```

### Flip Zone Identification

```mql5
double POIEngine::FindFlipZone(string symbol, ENUM_TIMEFRAMES tf,
                                ENUM_POI_TYPE poiType) {
    // Scan left for the visible cluster of S/R turns:
    //   - resistance → support flip (demand side)
    //   - support → resistance flip (supply side)
    // The FIRST REACTION that comes into this zone is the flip zone.
    // True POI must be below (demand) or above (supply) this level.
    // ...
    // Returns flip zone price level
}
```

### Inducement Filter (Fibonacci)

```mql5
bool POIEngine::IsInducementZone(double currentPrice, double impulseHigh,
                                   double impulseLow, ENUM_POI_TYPE poiType) {
    // Reactions at 61.8%–70.5% retracement of the current impulse are
    // HIGH PROBABILITY INDUCEMENT reactions, not true POI entries.
    // True POI lies BELOW 70.5% for buys.
    double fib618 = impulseLow + (impulseHigh - impulseLow) * 0.618;
    double fib705 = impulseLow + (impulseHigh - impulseLow) * 0.705;

    if(poiType == POI_DEMAND) {
        // If price reacting between 61.8% and 70.5% → inducement, not POI
        return (currentPrice >= fib618 && currentPrice <= fib705);
    }
    // Mirror for supply
    fib618 = impulseHigh - (impulseHigh - impulseLow) * 0.618;
    fib705 = impulseHigh - (impulseHigh - impulseLow) * 0.705;
    return (currentPrice <= fib618 && currentPrice >= fib705);
}
```

---

## 9. Order Flow Shift Detector

Three sequential shifts required for full entry. Fewer shifts = aggressive entry only (smaller size, wider stop acknowledged).

```mql5
ENUM_OFB_TYPE OFBDetector::CheckShifts(MarketState &ms, ENUM_POI_TYPE poiType) {

    // ── Shift 1: External Order Flow Break ─────────────────────────────────
    // The last buy-to-sell zone (sell setup) / sell-to-buy zone (buy setup)
    // breaks. Price is no longer respecting what was the impulse structure.
    // Signal: price closes through the key zone with a body, not a wick.
    bool shift1 = DetectExternalOFB(ms, poiType);

    if(!shift1) return OFB_NONE;

    // ── Shift 2: Internal Order Flow Break ─────────────────────────────────
    // The internal trend of the corrective Phase 1 leg breaks.
    // In a bullish setup (POI_DEMAND): Phase 1 was making lower lows.
    // Internal break = price creates a HIGHER LOW for the first time.
    // This confirms the corrective leg has structurally ended.
    bool shift2 = DetectInternalOFB(ms, poiType);

    if(!shift2) return OFB_EXTERNAL;

    // ── Shift 3: Final Order Flow Break ────────────────────────────────────
    // The definitive confirmation. After shifts 1+2, price breaks through
    // the last key structural level. This IS the entry trigger zone.
    // Entry is taken here or at the mitigation of this level.
    bool shift3 = DetectFinalOFB(ms, poiType);

    if(!shift3) return OFB_INTERNAL;

    return OFB_FINAL;   // All 3 shifts confirmed — full entry permitted
}

bool OFBDetector::DetectExternalOFB(MarketState &ms, ENUM_POI_TYPE poiType) {
    // Find the most recent buy-to-sell (sell setup) or sell-to-buy (buy setup)
    // zone on the entry timeframe.
    // Check if latest close is THROUGH this zone with an impulsive candle body.
    // wick-only = BOS_WICK_ONLY → does NOT count as a true OFB.
    // ...
}
```

### Three-Shift Visual Map (Buy Setup)

```
Phase 1 corrective leg:
  HH ──► LH ──► LL (lower lows forming, building Phase 1)
                ▲
                └─ POI zone approached here
                
  At POI:
  LL ──► [FU candle grabs stops]
              │
              └─► SHIFT 1 (External OFB): last sell zone BROKEN → bullish
                        │
                        └─► SHIFT 2 (Internal OFB): Phase 1's own LH/LL breaks
                                    │
                                    └─► SHIFT 3 (Final OFB): confirms expansion
                                                │
                                                └─► ENTRY HERE (or at mitigation)
```

---

## 10. Entry Execution Logic

```mql5
void ExecutionModule::AttemptEntry(MarketState &ms, ProcessChecklist &chk,
                                    RiskParams &rp, TradeRecord &rec) {

    // Gate 1: Phase must be PHASE_3
    if(ms.phase != PHASE_3) return;

    // Gate 2: All process checklist hard rules pass
    if(!chk.allPass()) {
        LogChecklistFailure(chk, rec);
        return;
    }

    // Gate 3: Daily cycle allows entry
    if(ms.dailyCycleState == DC_SYDNEY_RANGE_BUILDING ||
       ms.dailyCycleState == DC_ALGORITHM_RAID) {
        // Dead zone — no new entries
        rec.notes += "Blocked: Sydney building zone.";
        return;
    }

    // Gate 4: No high-impact news within 30 minutes
    if(!chk.step8_noImmediateNews) return;

    // Gate 5: Gold spread buffer — 21:00–23:00 GMT
    bool nearClose = IsNearDailyClose(ms.symbol);
    if(nearClose && !rec.hardTP > 0) {
        // Mandatory hard TP; do not enter without it
        return;
    }

    // ── Compute entry parameters ────────────────────────────────────────────
    double entryPrice = ms.activePOI.precisionLevel;
    double stopPrice  = ComputeStop(ms.activePOI, rec.direction, nearClose);
    double stopPips   = MathAbs(entryPrice - stopPrice) / GetPipSize(ms.symbol);

    // Gate 6: Stop must not exceed max for refined entry
    bool isGold = StringFind(ms.symbol, "XAU") >= 0;
    if(isGold && stopPips > DEFAULT_GOLD_STOP_MAX) {
        rec.entryType = ENTRY_AGGRESSIVE;
        // Halve position size for aggressive entry
        rp.riskPct = rp.riskPct * 0.5;
    } else {
        rec.entryType = ENTRY_REFINED;
    }

    // ── Position sizing ──────────────────────────────────────────────────────
    // lots = (account × riskPct) / (stopPips × pipValue)
    double lots = RiskModule::ComputeLots(rp.accountBalance, rp.riskPct,
                                           stopPips, ms.symbol);

    // Gate 7: Total open risk check
    if(!RiskModule::TotalRiskOK(lots, stopPips, ms.symbol)) {
        rec.notes += "Blocked: total open risk >3%.";
        return;
    }

    // ── Set take profits ─────────────────────────────────────────────────────
    double tp1 = ComputeTP1(ms, rec.direction);     // Prior swing H/L
    double tp2 = ComputeTP2(ms, rec.direction);     // External structure
    double hardTP = nearClose ? ComputeHardTP(entryPrice, rec.direction,
                                               DEFAULT_HARD_TP_PIPS) : 0;

    // ── Place order ──────────────────────────────────────────────────────────
    PlaceOrder(ms.symbol, rec.direction, lots, entryPrice,
               stopPrice, tp1, tp2, hardTP);

    // ── Populate trade record ────────────────────────────────────────────────
    rec.entryPrice  = entryPrice;
    rec.stopLoss    = stopPrice;
    rec.stopLossPips = stopPips;
    rec.tp1         = tp1;
    rec.tp2         = tp2;
    rec.hardTP      = hardTP;
    rec.lots        = lots;
    rec.rRatio      = MathAbs(tp1 - entryPrice) / MathAbs(entryPrice - stopPrice);
    rec.stepsFollowed = chk.allPass();

    AuditLogger::Log(rec);
}
```

### Stop Loss Placement Rule

```mql5
double ExecutionModule::ComputeStop(POI &poi, int direction, bool nearClose) {
    // Stop goes BEYOND the FU candle wick (the exact liquidity grab point).
    // NOT beyond the entire POI zone — only the wick of the precision candle.
    double buffer = GetPipSize(poi.symbol) * 1.5; // 1–2 pip buffer
    double spreadBuffer = nearClose ? (GOLD_SPREAD_BUFFER_PIPS * GetPipSize(poi.symbol)) : 0;

    if(direction == 1)  // LONG
        return poi.precisionLevel - buffer - spreadBuffer;
    else                // SHORT
        return poi.precisionLevel + buffer + spreadBuffer;
}
```

---

## 11. Exit & Position Management

### Take Profit Hierarchy

| Level | Target | Rule |
|-------|--------|------|
| TP1 | Prior swing high (buy) / low (sell) on entry TF | **HARD** — always take partial here |
| TP2 | Next external structure on HTF | Soft — swing target |
| TP3 | Monthly/multi-week external structure | Soft — runner with fundamental confirmation only |
| Hard TP | 30–50 pips fixed | **HARD** — mandatory when sleeping / near session close |
| Flip Zone TP | Next HTF flip zone | Soft — consider partial TP before reaching structural target |
| Inducement TP | 40–80 pips max | **HARD** — counter-trend moves cannot be held beyond inducement range |

### Position Management on Runner

```mql5
void ManagementModule::OnBarClose(TradeRecord &rec, MarketState &ms) {

    if(rec.state == TS_OPEN_INITIAL) {
        // Check TP1 hit
        if(TP1Reached(rec)) {
            ClosePartial(rec, 50);  // Close 50% at TP1
            MoveStopToEntry(rec);
            rec.state = TS_OPEN_RUNNER;
        }
        // Check stop hit
        if(StopHit(rec)) {
            CloseAll(rec);
            rec.state = TS_CLOSED_LOSS;
            AuditLogger::Log(rec);
        }
    }

    if(rec.state == TS_OPEN_RUNNER || rec.state == TS_BREAK_EVEN) {
        // HARD EXIT: HTF external structure broken against trade
        if(HTFStructureBrokenAgainst(rec, ms)) {
            CloseAll(rec);
            rec.state = TS_CLOSED_WIN;
            AuditLogger::Log(rec);
            return;
        }

        // HARD EXIT: H1 creates lower low against long / higher high against short
        if(StructureShiftsAgainstTrade(rec, ms)) {
            CloseOrTighten(rec);
            return;
        }

        // Trailing stop: trail to last confirmed higher low (bullish)
        TrailStopToStructure(rec, ms);

        // Gold 21:00–23:00 close window: widen stop +3–5 pips
        if(IsNearDailyClose(rec.symbol)) {
            WidenStopForClose(rec, GOLD_SPREAD_BUFFER_PIPS);
        }
    }
}
```

### Forced Exit Conditions

| Condition | Action |
|-----------|--------|
| HTF external structure breaks against position | Close at market immediately |
| Unexpected high-impact news; no hard TP set | Close at market before event |
| 3 consecutive stopped trades at same POI | Do NOT re-enter; wait for fresh structure |
| Friday late session; weekly range exhausted (~300 pips Gold) | TP early; reduce expectations |
| Trader active 10+ hours | Set hard TPs on all open positions |

---

## 12. Risk Management Module

```mql5
double RiskModule::ComputeLots(double accountBalance, double riskPct,
                                double stopPips, string symbol) {
    // lots = (account × riskPct) / (stopPips × pipValue)
    double riskUSD   = accountBalance * (riskPct / 100.0);
    double pipValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE)
                     / SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE)
                     * GetPipSize(symbol);
    return NormalizeDouble(riskUSD / (stopPips * pipValue),
                           (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

bool RiskModule::TotalRiskOK(double newLots, double newStopPips, string symbol) {
    double existingRisk = GetTotalOpenRiskPct();
    double newRiskPct   = ComputeRiskPct(newLots, newStopPips, symbol);
    return (existingRisk + newRiskPct) <= DEFAULT_MAX_TOTAL_RISK;
}
```

### Risk Limits Table

| Parameter | Value | Rule |
|-----------|-------|------|
| Max risk per trade | 1–2% of account | **HARD** |
| Max total open risk | 3% of account | **HARD** |
| Counter-trend max risk | 0.5% | **HARD** |
| Max simultaneous positions | 3 | Soft |
| Minimum R:R at entry | 1:10 | Soft |
| Target R:R (refined) | 1:20–1:90+ | Guide |
| Hard TP (sleep/fatigue) | 30–50 pips | **HARD** |
| Gold stop max (non-Asia) | 2–6 pips | Guide |
| Gold spread buffer (close) | +3–5 pips | **HARD** |
| Weekly range cap (Gold) | ~300 pips | Context |
| Daily loss limit | −3% | **HARD** — halt session |
| Weekly loss limit | −5% | **HARD** — halve sizing |

### Equity Protection Logic

```mql5
void RiskModule::CheckEquityGuards(double dailyPnL, double weeklyPnL,
                                    int consecutiveLosses, bool &haltTrading,
                                    bool &reduceSizing) {

    // Daily loss limit
    if(dailyPnL <= -(g_AccountBalance * DAILY_LOSS_LIMIT_PCT / 100.0)) {
        haltTrading = true;
        Log("DAILY LOSS LIMIT HIT. Session halted. Review checklist.");
        return;
    }

    // 3 consecutive losses at same setup → step back
    if(consecutiveLosses >= 3) {
        haltTrading = true;
        Log("3 CONSECUTIVE STOPS at same POI. Do NOT re-enter. Re-assess structure.");
        return;
    }

    // Revenge trading guard: any trade within 10 mins of a stop
    if(TimeSinceLastStop() < 600 && !ChecklistCompleted()) {
        haltTrading = true;
        Log("REVENGE TRADE BLOCKED. Complete full ProcessChecklist first.");
        return;
    }

    // Weekly drawdown: reduce to 50% sizing
    if(weeklyPnL <= -(g_AccountBalance * WEEKLY_LOSS_LIMIT_PCT / 100.0)) {
        reduceSizing = true;
        Log("WEEKLY LOSS LIMIT. Sizing reduced to 50% until 2 profitable days.");
    }
}
```

---

## 13. Correlation & Multi-Asset Filter

All four instruments must be checked before execution on gold or major FX pairs.

```mql5
bool CorrelationFilter::Check(MarketState &ms, ENUM_POI_TYPE tradeDirection) {

    // ── DXY (Dollar Index) ─────────────────────────────────────────────────
    // DXY bullish → gold/EUR weak. DXY bearish → gold/EUR buyers.
    // If trade requires dollar weakness (gold buy, EURUSD buy):
    //   DXY must be in bearish phase or at HTF supply.
    ENUM_BIAS dxyReq = (tradeDirection == POI_DEMAND) ? BIAS_BEARISH : BIAS_BULLISH;
    if(ms.dxyBias == -dxyReq) {
        Log("CORRELATION BLOCKED: DXY contradicts trade direction.");
        return false;
    }

    // ── EURUSD (gold proxy) ────────────────────────────────────────────────
    // EURUSD must stabilise at external structure before gold rips.
    // If EURUSD is in active Phase 1 downtrend: gold buys may face headwind.
    if(StringFind(ms.symbol, "XAU") >= 0) {
        if(ms.eurusdBias == BIAS_BEARISH && tradeDirection == POI_DEMAND) {
            // EURUSD not yet at external structure → wait
            if(!EURUSDAtExternalStructure()) {
                Log("EURUSD not stabilised. Wait for EUR external structure.");
                return false;
            }
        }
    }

    // ── Yen Basket (Yen pairs only) ────────────────────────────────────────
    // Yen basket bearish (lower lows) → GJ/UJ biased long.
    // Attempting to SHORT a Yen pair when basket is bearish = fight institutional flow.
    if(StringFind(ms.symbol, "JPY") >= 0) {
        if(ms.yenBasketBias == BIAS_BEARISH && tradeDirection == POI_SUPPLY) {
            Log("YEN BASKET BEARISH. Yen shorts against institutional flow.");
            return false;
        }
    }

    // ── US30 (equity index) ────────────────────────────────────────────────
    // US30 up → USD portfolios liquidated → USD weakens → JPY pairs long.
    // US30 provides directional context for Yen and dollar pairs.
    if(ms.us30Bias == BIAS_BULLISH && tradeDirection == POI_SUPPLY &&
       StringFind(ms.symbol, "JPY") >= 0) {
        Log("US30 bullish (Yen weak). Yen pair shorts require extra caution.");
        // Not a hard block — reduce size or skip
    }

    return true;
}
```

### Cross-Market Analysis Protocol (Ordered)

1. **DXY structural phase** — establishes dollar bias (governs all pairs)
2. **US30 / equity index** — confirms capital flow (USD liquidation / accumulation)
3. **Yen Basket** — if trading any JPY pair
4. **EURUSD** — if trading Gold (XAUUSD)
5. All four must confirm OR at minimum not actively contradict — then proceed

---

## 14. Session & Timing Module

```mql5
// Records session H/L in real time
void SessionModule::OnTick(MarketState &ms, string symbol) {
    double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
    ENUM_DAILY_CYCLE_STATE s = GetCurrentState(symbol);

    // Sydney range (23:00–00:00 GMT Gold)
    if(s == DC_SYDNEY_RANGE_BUILDING) {
        if(bid > ms.sydneyHigh) ms.sydneyHigh = bid;
        if(bid < ms.sydneyLow || ms.sydneyLow == 0) ms.sydneyLow = bid;
    }

    // Asia range building
    if(s == DC_ASIA_RANGE_FORMING || s == DC_ASIA_EXPANSION) {
        if(bid > ms.asiaHigh) ms.asiaHigh = bid;
        if(bid < ms.asiaLow || ms.asiaLow == 0) ms.asiaLow = bid;

        // T-High: highest point in Asia around 03:00 GMT
        if(GetGMTHour(TimeCurrent()) == ALG_ASIA_T_HIGH_HOUR)
            ms.tHigh = MathMax(ms.tHigh, bid);
    }

    // London range
    if(s == DC_LONDON_OPEN) {
        if(bid > ms.londonHigh) ms.londonHigh = bid;
        if(bid < ms.londonLow || ms.londonLow == 0) ms.londonLow = bid;
    }

    // NY Cross: confirm TLD / THD
    if(s == DC_NY_CROSS_RAID) {
        if(ms.dailyCycleType == DCT_BULLISH && bid < ms.trueLowOfDay) {
            ms.trueLowOfDay = bid;
            ms.tldPrinted = true;
        }
        if(ms.dailyCycleType == DCT_BEARISH && bid > ms.trueHighOfDay) {
            ms.trueHighOfDay = bid;
            ms.thdPrinted = true;
        }
    }
}

// Determine day type from Sydney raid
void SessionModule::ConfirmDayType(MarketState &ms) {
    // Called at end of ALGORITHM_RAID window (01:00 GMT)
    if(ms.dailyCycleType != DCT_UNDETERMINED) return;

    if(SydneyLowRaided(ms))       ms.dailyCycleType = DCT_BULLISH;
    else if(SydneyHighRaided(ms)) ms.dailyCycleType = DCT_BEARISH;
    // else: ONE_SIDED model; confirm at London close
}
```

### Key Time Guards

```mql5
bool SessionModule::IsDeadZone(string symbol) {
    // NO new entries permitted in Sydney range building window
    bool isGold = (StringFind(symbol, "XAU") >= 0);
    int gmtHour = GetGMTHour(TimeCurrent());
    return (isGold && gmtHour == 23) ||  // Gold Sydney open
           (gmtHour == 0);               // Algorithm raid — wait for result
}

bool SessionModule::IsNearClose(string symbol) {
    int gmtHour = GetGMTHour(TimeCurrent());
    return (gmtHour >= ALG_DAILY_CLOSE_HOUR);  // 21:00+ GMT
}
```

---

## 15. Liquidity Pool Tracker

```mql5
// Built from price history scan on each higher-TF bar close
void LiquidityTracker::ScanAndUpdate(MarketState &ms, string symbol) {

    // Session highs/lows — updated by SessionModule in real-time
    UpdateSessionPool(ms, LIQ_SYDNEY_HIGH, ms.sydneyHigh);
    UpdateSessionPool(ms, LIQ_SYDNEY_LOW,  ms.sydneyLow);
    UpdateSessionPool(ms, LIQ_ASIA_HIGH,   ms.asiaHigh);
    UpdateSessionPool(ms, LIQ_ASIA_LOW,    ms.asiaLow);
    UpdateSessionPool(ms, LIQ_LONDON_HIGH, ms.londonHigh);
    UpdateSessionPool(ms, LIQ_LONDON_LOW,  ms.londonLow);

    // Equal highs / equal lows (within 1–2 pip tolerance)
    ScanEqualHighsLows(ms, symbol, PERIOD_H1);
    ScanEqualHighsLows(ms, symbol, PERIOD_M30);

    // Trendline liquidity: descending TL above price (supply) /
    //                     ascending TL below price (demand)
    ScanTrendlineLiquidity(ms, symbol);

    // Round numbers (e.g. 1800, 1820 for Gold)
    ScanRoundNumbers(ms, symbol);

    // Mark grabbed pools
    foreach(LiquidityPool &pool in ms.liquidityMap) {
        if(!pool.isGrabbed && IsPoolRaided(pool, symbol)) {
            pool.isGrabbed = true;
            pool.raidTime  = TimeCurrent();
        }
    }
}

// Quantification
void LiquidityTracker::Quantify(LiquidityPool &pool) {
    // EstimatedLots ≈ pipDisplacement × 100,000
    // A 23-pip reaction = ~2.3 million lots at that level.
    // Used to compare pool sizes; bigger pool = more likely expansion target.
    pool.pipDisplacement = MeasurePipReaction(pool);
    pool.estimatedLots   = pool.pipDisplacement * 100000.0;
}
```

---

## 16. Audit & Logging Module

Every trade must be recorded to the 100-trade audit log. The log is the primary performance review tool.

### 100-Trade Audit Log Schema

| Column | Type | Description |
|--------|------|-------------|
| `trade_id` | UUID | Unique identifier |
| `date_time` | datetime | Entry timestamp |
| `symbol` | string | Instrument |
| `direction` | LONG/SHORT | Trade direction |
| `lots` | float | Position size |
| `risk_pct` | float | % of account risked |
| `entry_price` | float | Fill price |
| `stop_price` | float | Initial stop |
| `stop_pips` | float | Stop distance |
| `tp1_price` | float | TP1 level |
| `tp2_price` | float | TP2 level |
| `hard_tp_set` | bool | Hard TP placed? |
| `exit_price` | float | Actual close price |
| `pnl_pips` | float | P&L in pips |
| `pnl_usd` | float | P&L in USD |
| `result` | WIN/LOSS/BE | Trade result |
| `entry_type` | REFINED/AGGRESSIVE | Entry quality |
| `steps_followed` | bool | All checklist steps passed? |
| `failure_step` | string | If false: which step failed |
| `structure_correct` | bool | Structural analysis correct in hindsight? |
| `poi_valid` | bool | All 4 POI criteria met? |
| `3shift_complete` | bool | All 3 OFB shifts confirmed? |
| `notes` | string | Post-trade analysis |

```mql5
void AuditLogger::Log(TradeRecord &rec) {
    string logLine = StringFormat(
        "%s,%s,%d,%.2f,%.4f,%.5f,%.5f,%.1f,%.5f,%.5f,%s,%.5f,%.1f,%.2f,%s,%s,%s,%s,%s,%s,%s,%s",
        (string)rec.ticketId,
        TimeToString(rec.openTime, TIME_DATE|TIME_MINUTES),
        rec.symbol,
        rec.direction == 1 ? "LONG" : "SHORT",
        rec.lots, rec.riskPct, rec.entryPrice, rec.stopLoss, rec.stopLossPips,
        rec.tp1, rec.tp2, rec.hardTP > 0 ? "TRUE" : "FALSE",
        rec.exitPrice, rec.pnlPips, rec.pnlUSD,
        rec.pnlUSD > 0 ? "WIN" : (rec.pnlUSD < 0 ? "LOSS" : "BE"),
        rec.entryType == ENTRY_REFINED ? "REFINED" : "AGGRESSIVE",
        rec.stepsFollowed ? "TRUE" : "FALSE",
        rec.failureStep,
        rec.structureCorrect ? "TRUE" : "FALSE",
        rec.poiValid ? "TRUE" : "FALSE",
        rec.threeShiftComplete ? "TRUE" : "FALSE",
        rec.notes
    );
    WriteToCSV("snxper_audit_log.csv", logLine);
}
```

### Performance Review Protocol

```mql5
void AuditLogger::PeriodicReview(int reviewInterval = 100) {
    // Every N trades:
    // 1. Calculate execution failure rate:
    //    executionFailures = trades where steps_followed=FALSE && result=LOSS
    //    If >60% of losses → execution discipline issue (not methodology)
    //    If <40% of losses → methodology review required

    // 2. Winning streak complacency check:
    //    If last 5 trades all WIN → force full checklist on trade N+1

    // 3. Expected value:
    //    EV = (winRate × avgWin) − (lossRate × avgLoss)
    //    This is the only meaningful performance metric (not win rate alone)

    // 4. Rolling 20-session win rate:
    //    If < 40% → full methodology review; no increase in size
}
```

---

## 17. Input Parameters

```mql5
input group "═══ Risk Management ═══"
input double  InpRiskPct          = 1.5;    // Max risk % per trade
input double  InpMaxTotalRisk     = 3.0;    // Max total open risk %
input double  InpCounterRiskPct   = 0.5;    // Counter-trend max risk %
input int     InpMaxPositions     = 3;      // Max simultaneous trades
input double  InpHardTPPips       = 40;     // Hard TP pips (fatigue/sleep)
input double  InpGoldStopMax      = 6;      // Max stop pips (Gold refined)

input group "═══ Structural Analysis ═══"
input bool    InpUseMonthly       = true;   // Include monthly in cascade
input bool    InpUseWeekly        = true;   // Include weekly in cascade
input int     InpEntryTF          = 240;    // Entry timeframe (minutes; 240=H4)
input int     InpRefinementTF     = 2;      // Refinement TF (minutes; 2=M2)

input group "═══ Session & Timing ═══"
input bool    InpIsGold           = true;   // Gold (true) or FX (false)
input bool    InpEnforceDeadZone  = true;   // Block entries in Sydney building
input bool    InpRequireNYCross   = false;  // Only enter NY Cross window
input bool    InpAutoHardTP       = true;   // Auto hard TP near close

input group "═══ POI Engine ═══"
input double  InpFlipZoneTolerance = 2.0;  // Pips tolerance for flip zone
input double  InpFib618           = 0.618; // Inducement zone start (Fib)
input double  InpFib705           = 0.705; // Inducement zone end   (Fib)
input bool    InpRequireAllCriteria = true; // Enforce all 4 POI criteria (HARD)

input group "═══ Order Flow ═══"
input bool    InpRequire3Shifts   = true;   // Require 3 OFB shifts (else aggressive)
input double  InpAggressiveSizeMult = 0.5;  // Size multiplier for aggressive entries

input group "═══ Correlation ═══"
input string  InpDXYSymbol        = "DXY";       // DXY instrument name
input string  InpEURUSDSymbol     = "EURUSD";    // EURUSD symbol
input string  InpUS30Symbol       = "US30";      // US30/DJIA symbol
input string  InpYenBasketSymbol  = "JPYBASKET"; // Yen basket symbol
input bool    InpEnableCorrelation = true;        // Require correlation check

input group "═══ Audit ═══"
input string  InpLogFile          = "snxper_audit.csv"; // Log file path
input bool    InpLogAllTrades     = true;   // Log every trade (required)
input int     InpReviewInterval   = 100;    // Periodic review interval (trades)
```

---

## 18. Execution Flow (OnTick / OnBar)

```mql5
void OnTick() {
    // Real-time monitoring: session H/L stamping, liquidity raids
    SessionModule::OnTick(g_MarketState, _Symbol);
    LiquidityTracker::ScanRaids(g_MarketState, _Symbol);
    ManagementModule::CheckOpenPositions(g_MarketState);
}

void OnBar(ENUM_TIMEFRAMES tf) {
    // Bar-close driven analysis (M1 or the entry TF)

    // ── 1. Daily cycle state update ──────────────────────────────────────────
    g_MarketState.dailyCycleState = SessionModule::GetCurrentState(_Symbol);

    // ── 2. Structural cascade (top-down): Monthly → M1 ──────────────────────
    StructuralCascade::Build(g_MarketState);

    // ── 3. Phase engine: determine phase on each relevant TF ─────────────────
    PhaseEngine::Update(g_MarketState.tfStack[ENTRY_TF_IDX], g_MarketState);

    // ── 4. Liquidity pool scan (on H1+ close) ───────────────────────────────
    if(tf >= PERIOD_H1)
        LiquidityTracker::ScanAndUpdate(g_MarketState, _Symbol);

    // ── 5. POI validation ────────────────────────────────────────────────────
    if(g_MarketState.hasPOI)
        POIEngine::Validate(g_MarketState.activePOI, g_MarketState,
                            g_MarketState.tfStack[ENTRY_TF_IDX]);

    // ── 6. Order flow shift detection ────────────────────────────────────────
    ENUM_OFB_TYPE ofbLevel = OFBDetector::CheckShifts(g_MarketState,
                                g_MarketState.activePOI.type);
    UpdateTradeState(ofbLevel);

    // ── 7. Correlation filter ────────────────────────────────────────────────
    bool corrOK = CorrelationFilter::Check(g_MarketState,
                                           g_MarketState.activePOI.type);

    // ── 8. Build process checklist ───────────────────────────────────────────
    g_Checklist = BuildChecklist(g_MarketState, ofbLevel, corrOK);

    // ── 9. Attempt entry if all gates pass ───────────────────────────────────
    if(g_MarketState.tradeState == TS_ORDER_FLOW_SHIFT) {
        ExecutionModule::AttemptEntry(g_MarketState, g_Checklist,
                                      g_RiskParams, g_ActiveTrade);
    }

    // ── 10. Equity guards ────────────────────────────────────────────────────
    bool halt, reduce;
    RiskModule::CheckEquityGuards(g_DailyPnL, g_WeeklyPnL,
                                   g_ConsecLosses, halt, reduce);
    if(halt) return;
    if(reduce) g_RiskParams.riskPct = g_RiskParams.riskPct * 0.5;
}
```

---

## 19. Invalidation & Safety Guards

These checks run at every bar close and on every tick for open positions.

| Check | Frequency | Action on Failure |
|-------|-----------|------------------|
| HTF external landmark broken against bias | Every bar | `INVALIDATED` state → cancel pending orders |
| POI blown through impulsively (no FU) | Every tick | Mark zone invalid; find next deeper POI |
| Flip zone reaction (criterion 3 fail) | At POI approach | Do not enter; classify as inducement; wait for deeper POI |
| 3 consecutive losses at same POI | Per trade close | Stop all activity at that POI; full structural re-analysis |
| Gold close window 21:00 GMT | Every tick | Widen stop 3–5 pips; set hard TP on open positions |
| High-impact news <30 min | Time check | Block new entries; set hard TP on open positions |
| Daily loss limit −3% | Per trade close | Halt all trading; session review required |
| Total open risk >3% | Pre-entry | Block new entry |
| Revenge trade (<10 min after stop, no checklist) | Timer | Force close if placed; log as procedural violation |

---

## 20. Implementation Notes & Constraints

### Timeframe Availability in MT5
- M2 (`PERIOD_M2`) is available natively in MT5 — use for precision entry.
- H8 (`PERIOD_H8`) is available natively. H12 can be synthesised from H4 × 3 bars if needed.

### BOS Detection Algorithm
The BOS detector must distinguish between:
- **Impulsive break**: candle body closes THROUGH the level. Counts as a confirmed BOS.
- **Wick-only break**: only the wick penetrates. Marks as `BOS_WICK_ONLY`. Does NOT confirm phase transition. Do not execute off a wick-only break.

### FU Candle Pattern Detection (M2/M1)
An FU candle is confirmed when, on the precision timeframe:
1. A candle wicks significantly THROUGH the `precisionLevel` (grabs stop-losses)
2. The candle **closes** in the opposing direction (body above/below the precision level)
3. The close is within or through the prior candle's body

### Phase Fractal Principle
The phase cycle operates identically on every timeframe. A transition visible on H4 contains the same pre-phase 2A → phase 2 → phase 3 pattern at M30 level, and again at M5 level. Entry is always at the lowest-timeframe phase 3 that aligns with the HTF bias.

### Multi-Timeframe Array Indexing
```
tfStack[0]  = Monthly
tfStack[1]  = Weekly
tfStack[2]  = Daily
tfStack[3]  = H8/H12
tfStack[4]  = H4  ← primary entry TF
tfStack[5]  = H1  ← confirmation TF
tfStack[6]  = M30 ← POI zone identification
tfStack[7]  = M15 ← POI refinement level 1
tfStack[8]  = M5  ← POI refinement level 2
tfStack[9]  = M2  ← POI refinement level 3 (ideal)
tfStack[10] = M1  ← precision entry candle
```

### MT5 Symbol Naming
Handle broker-specific symbol suffixes (e.g. `XAUUSD`, `XAUUSDm`, `GOLD`) via a normalise function that strips common suffixes before comparing against the `InpIsGold` flag.

### GMT Offset
All session timing must use **server time converted to GMT**. Retrieve offset with `TimeGMTOffset()`. All window checks must be offset-corrected to avoid daylight saving issues.

### Prohibited Patterns (Never Implement)
- Entry at a POI that fails criterion 3 (above flip zone) — this is an inducement trap
- Entry in the Sydney range building window
- New entries within 10 minutes of a stopped trade without completing the full checklist
- Stop placement beyond the entire POI zone (must be beyond the FU wick only)
- Holding a counter-trend inducement trade as a swing (max 40–80 pip hard TP)

---

*End of snXper FX MT5 Master Specification v1.0*
