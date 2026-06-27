import { useState } from "react";

// ─── SPEC DATA ─────────────────────────────────────────────────────────────

const spec = {
  meta: {
    title: "snXper FX Trading System",
    subtitle: "Formal System Specification v1.0",
    version: "1.0",
    status: "REFERENCE",
  },

  sections: [
    {
      id: "data-structures",
      label: "1. Data Structures",
      icon: "🗂️",
      subsections: [
        {
          id: "ds-market-state",
          title: "1.1 MarketState",
          type: "struct",
          fields: [
            { name: "symbol", type: "string", desc: "Instrument ticker (XAUUSD, GBPJPY, US30, etc.)" },
            { name: "timeframes", type: "TimeframeStack", desc: "Active structural assessment for each TF" },
            { name: "phase", type: "StructuralPhase", desc: "Current phase in the 5-phase cycle (enum)" },
            { name: "dailyCycleType", type: "DailyCycleType", desc: "BULLISH | BEARISH | UNDETERMINED" },
            { name: "sessionModel", type: "SessionModel", desc: "ONE_SIDED | TWO_SIDED" },
            { name: "activePOI", type: "POI | null", desc: "Current validated POI awaiting price" },
            { name: "liquidityMap", type: "LiquidityPool[]", desc: "All identified liquidity pools on chart" },
            { name: "correlatedAssets", type: "CorrelationContext", desc: "DXY, US30, YenBasket, EURUSD readings" },
            { name: "fundamentalBias", type: "FundamentalBias | null", desc: "Macro overlay confirming technical direction" },
          ],
        },
        {
          id: "ds-timeframe-stack",
          title: "1.2 TimeframeStack",
          type: "struct",
          note: "Must be populated from Monthly → M1 before any trade is considered. Higher TFs govern lower TFs. A lower TF cannot shift bias if a higher TF external landmark is intact.",
          fields: [
            { name: "monthly", type: "TFState", desc: "Monthly structure bias" },
            { name: "weekly", type: "TFState", desc: "Weekly structure bias" },
            { name: "daily", type: "TFState", desc: "Daily structure bias" },
            { name: "h8_h12", type: "TFState", desc: "8H/12H intermediate bias" },
            { name: "h4", type: "TFState", desc: "H4 — primary entry timeframe" },
            { name: "h1", type: "TFState", desc: "H1 — confirmation timeframe" },
            { name: "m30", type: "TFState", desc: "M30 — POI zone identification" },
            { name: "m15", type: "TFState", desc: "M15 — POI refinement level 1" },
            { name: "m5", type: "TFState", desc: "M5 — POI refinement level 2" },
            { name: "m2", type: "TFState", desc: "M2 — POI refinement level 3" },
            { name: "m1", type: "TFState", desc: "M1 — precision entry candle" },
          ],
        },
        {
          id: "ds-tfstate",
          title: "1.3 TFState",
          type: "struct",
          fields: [
            { name: "bias", type: "BULLISH | BEARISH | NEUTRAL", desc: "Current structural bias" },
            { name: "externalHigh", type: "PriceLevel", desc: "Last confirmed external structural high" },
            { name: "externalLow", type: "PriceLevel", desc: "Last confirmed external structural low" },
            { name: "lastBOS", type: "BOSEvent", desc: "Most recent break of structure event" },
            { name: "bosStrength", type: "IMPULSIVE | WICK_ONLY", desc: "Nature of the BOS — critical for continuation vs. reversal" },
            { name: "lastCHoCH", type: "CHoCHEvent | null", desc: "Change of character event if detected" },
            { name: "currentPhase", type: "StructuralPhase", desc: "Phase within this TF's own cycle" },
          ],
        },
        {
          id: "ds-poi",
          title: "1.4 POI (Point of Interest)",
          type: "struct",
          note: "ALL four criteria must be TRUE for a POI to be valid. A POI failing any single criterion is INVALID and must not be entered from.",
          fields: [
            { name: "priceHigh", type: "float", desc: "Upper bound of the POI zone" },
            { name: "priceLow", type: "float", desc: "Lower bound of the POI zone" },
            { name: "precisionLevel", type: "float", desc: "The exact 'last liquidity grabbed' sub-price within the zone" },
            { name: "originTimeframe", type: "Timeframe", desc: "Timeframe on which the POI was first identified (H4, H1, etc.)" },
            { name: "criterion1_lastSellBuyZone", type: "bool", desc: "This is the LAST sell-to-buy (or buy-to-sell) candle that directly caused the BOS of the prior external structure point" },
            { name: "criterion2_freeLiquidityIncoming", type: "bool", desc: "The institutional candle is NOT sitting on equal highs/lows AND there is incoming liquidity (equal lows, trendline lows) between current price and this POI" },
            { name: "criterion3_belowFlipZone", type: "bool", desc: "The POI price is BELOW the flip zone for buys (ABOVE for sells). Any POI at or above flip zone is invalid." },
            { name: "criterion4_precisionLiquidityLeft", type: "bool", desc: "The exact sub-zone where the institutional candle last grabbed liquidity has been identified. Entry targets this sub-zone specifically." },
            { name: "type", type: "DEMAND | SUPPLY", desc: "Direction of the POI" },
            { name: "refinedTimeframe", type: "Timeframe", desc: "Lowest TF at which POI has been refined (target M2 or M1)" },
            { name: "isValid", type: "bool", desc: "True only when ALL four criteria are TRUE" },
            { name: "flipZonePrice", type: "float", desc: "Price of the nearest flip zone above (demand) or below (supply)" },
            { name: "liquidityPools", type: "LiquidityPool[]", desc: "Liquidity pools feeding into the POI" },
          ],
        },
        {
          id: "ds-liquidity",
          title: "1.5 LiquidityPool",
          type: "struct",
          fields: [
            { name: "price", type: "float", desc: "Price level of the pool" },
            { name: "type", type: "LiquidityType", desc: "EQUAL_HIGHS | EQUAL_LOWS | TRENDLINE | ASIA_HIGH | ASIA_LOW | SYDNEY_HIGH | SYDNEY_LOW | LONDON_HIGH | LONDON_LOW | PREV_DAY_HIGH | PREV_DAY_LOW | WEEK_HIGH | WEEK_LOW | ROUND_NUMBER" },
            { name: "session", type: "Session", desc: "Session in which pool was created" },
            { name: "pips", type: "float", desc: "Pip displacement from creation level (for quantification)" },
            { name: "estimatedLots", type: "float", desc: "pips × 100,000 — approximate lot-volume sitting at this level" },
            { name: "isGrabbed", type: "bool", desc: "Whether this pool has been raided/swept" },
            { name: "raidTime", type: "datetime | null", desc: "Timestamp when the pool was raided" },
          ],
        },
        {
          id: "ds-trade",
          title: "1.6 Trade",
          type: "struct",
          fields: [
            { name: "id", type: "string", desc: "Unique trade identifier (UUID)" },
            { name: "symbol", type: "string", desc: "Instrument" },
            { name: "direction", type: "LONG | SHORT", desc: "Trade direction" },
            { name: "entryPrice", type: "float", desc: "Actual fill price" },
            { name: "stopLoss", type: "float", desc: "Stop loss price — placed beyond the FU candle wick" },
            { name: "stopLossPips", type: "float", desc: "Stop distance in pips — target 2–6 pips on Gold/FX" },
            { name: "tp1", type: "float", desc: "First take profit — prior swing high/low (partial close)" },
            { name: "tp2", type: "float | null", desc: "Second take profit — external structure target" },
            { name: "tpHard", type: "float | null", desc: "Hard TP — mandatory when entering near session close or sleeping" },
            { name: "lots", type: "float", desc: "Position size in lots" },
            { name: "riskUSD", type: "float", desc: "Absolute USD risk = stopLossPips × lotsValue" },
            { name: "rRatio", type: "float", desc: "Risk-reward ratio at TP1" },
            { name: "entryType", type: "EntryType", desc: "REFINED (M2/M1 precision) | AGGRESSIVE (HTF zone only)" },
            { name: "poiUsed", type: "POI", desc: "The validated POI that generated this entry" },
            { name: "state", type: "TradeState", desc: "Current state in the trade lifecycle state machine" },
            { name: "processChecklist", type: "ProcessChecklist", desc: "Audit record of all process steps followed" },
            { name: "session", type: "Session", desc: "Session in which the trade was opened" },
            { name: "openTime", type: "datetime", desc: "Entry timestamp" },
            { name: "closeTime", type: "datetime | null", desc: "Exit timestamp" },
            { name: "pnlPips", type: "float | null", desc: "Realised P&L in pips" },
            { name: "pnlUSD", type: "float | null", desc: "Realised P&L in USD" },
            { name: "notes", type: "string", desc: "Post-trade journal notes" },
          ],
        },
        {
          id: "ds-checklist",
          title: "1.7 ProcessChecklist (Audit Record)",
          type: "struct",
          note: "Populated in order before entry. Any FALSE after step 5 = entry not permitted.",
          fields: [
            { name: "step1_structureAnalysis", type: "bool", desc: "HTF structural bias confirmed (Monthly → H4 cascade labeled)" },
            { name: "step1_timeframeLabels", type: "string", desc: "Written record: which TF is presenting each structure point" },
            { name: "step2_phaseAnalysis", type: "bool", desc: "Structural phase (1–5) identified on the entry timeframe" },
            { name: "step2_phaseLabel", type: "StructuralPhase", desc: "Explicit phase label recorded" },
            { name: "step3_poiIdentified", type: "bool", desc: "POI located — last sell/buy zone below flip zone with incoming liquidity" },
            { name: "step3_allCriteriaPass", type: "bool", desc: "All 4 POI criteria explicitly checked" },
            { name: "step4_liquidityMap", type: "bool", desc: "All session highs/lows, equal H/L, trendline liquidity labeled on chart" },
            { name: "step4_liquidityIncoming", type: "bool", desc: "Confirmed: liquidity is pulling price toward POI" },
            { name: "step5_orderFlowShift1", type: "bool", desc: "External order flow break confirmed" },
            { name: "step5_orderFlowShift2", type: "bool", desc: "Internal order flow break confirmed" },
            { name: "step5_orderFlowShift3", type: "bool", desc: "Final order flow shift confirmed (3-shift model complete)" },
            { name: "step6_entryRefined", type: "bool", desc: "POI refined to M5/M2/M1 level. FU candle identified. Exact stop level set." },
            { name: "step6_fuCandle", type: "bool", desc: "FU candle (liquidity grab + reversal) confirmed at entry" },
            { name: "step7_timeConfirmation", type: "bool", desc: "Daily cycle phase checked. Not entering in 11:00–midnight (Gold) dead zone without managing position." },
            { name: "step7_sessionHardTP", type: "bool", desc: "Hard TP set if entering near session end or managing position unattended" },
            { name: "step8_correlationCheck", type: "bool", desc: "DXY / US30 / YenBasket / EURUSD correlation confirms direction" },
            { name: "step8_fundamentalCheck", type: "bool", desc: "No fundamental release imminent that contradicts bias (NFP, rate decision, etc.)" },
            { name: "allProcessStepsFollowed", type: "bool", desc: "Summary: TRUE only if all required steps pass. Recorded per 100-trade log." },
          ],
        },
      ],
    },

    {
      id: "state-machines",
      label: "2. State Machines",
      icon: "⚙️",
      subsections: [
        {
          id: "sm-trade-lifecycle",
          title: "2.1 Trade Lifecycle State Machine",
          type: "state-machine",
          states: [
            { name: "IDLE", desc: "No active trade. Running structural analysis and monitoring for POI approach." },
            { name: "POI_WATCH", desc: "Price is approaching a valid, identified POI. Liquidity build-up being monitored. No entry yet." },
            { name: "PRE_PHASE_2A", desc: "Price at POI zone. Internal liquidity engineering confirmed (equal lows/highs building). FU candle not yet printed." },
            { name: "PHASE_2", desc: "FU candle detected. External order flow break confirmed. Awaiting internal shift." },
            { name: "ORDER_FLOW_SHIFT", desc: "All 3 order flow shifts confirmed. Entry signal generated. Awaiting precise M2/M1 fill." },
            { name: "ENTRY_PENDING", desc: "Limit/stop entry order placed at precision level. Awaiting fill." },
            { name: "OPEN_INITIAL", desc: "Position open. Managing to TP1 (prior swing high/low). Monitoring structure." },
            { name: "OPEN_RUNNER", desc: "TP1 hit. Partial position closed. Runner targeting TP2 / external structure. Stop moved to entry." },
            { name: "BREAK_EVEN", desc: "Stop moved to entry. Zero-risk on remainder. Structure monitoring continues." },
            { name: "SCALING", desc: "Adding to position at subsequent valid POI during same directional move." },
            { name: "CLOSED_WIN", desc: "Position closed in profit. Trade logged to 100-trade spreadsheet." },
            { name: "CLOSED_LOSS", desc: "Stop hit. Trade logged. Process checklist reviewed for execution failure vs. system failure." },
            { name: "CLOSED_BREAKEVEN", desc: "Closed at entry. Psychological impact logged. Triggers review of process step 5." },
            { name: "INVALIDATED", desc: "POI or bias invalidated mid-approach. Order cancelled. Return to IDLE." },
          ],
          transitions: [
            { from: "IDLE", to: "POI_WATCH", trigger: "Valid POI identified with all 4 criteria met AND price is in Phase 1 approaching zone" },
            { from: "POI_WATCH", to: "IDLE", trigger: "HTF structure broken against bias (external landmark breached)" },
            { from: "POI_WATCH", to: "PRE_PHASE_2A", trigger: "Price enters POI zone. Internal liquidity (equal lows) building at zone." },
            { from: "PRE_PHASE_2A", to: "PHASE_2", trigger: "FU candle printed. External order flow break confirmed." },
            { from: "PRE_PHASE_2A", to: "INVALIDATED", trigger: "Price breaks through POI with momentum (not reacting) — zone blown." },
            { from: "PHASE_2", to: "ORDER_FLOW_SHIFT", trigger: "Internal OFB + Final OFB confirmed = all 3 shifts complete" },
            { from: "PHASE_2", to: "INVALIDATED", trigger: "Price continues through zone without shift after FU." },
            { from: "ORDER_FLOW_SHIFT", to: "ENTRY_PENDING", trigger: "ProcessChecklist all TRUE. Entry order placed at precision level (M2/M1 zone)." },
            { from: "ENTRY_PENDING", to: "OPEN_INITIAL", trigger: "Order filled at precision price." },
            { from: "ENTRY_PENDING", to: "IDLE", trigger: "Price misses entry level and continues without filling — re-assess." },
            { from: "OPEN_INITIAL", to: "OPEN_RUNNER", trigger: "TP1 hit (prior swing high/low). Partial position closed." },
            { from: "OPEN_INITIAL", to: "CLOSED_LOSS", trigger: "Stop hit." },
            { from: "OPEN_INITIAL", to: "BREAK_EVEN", trigger: "Moved stop to entry manually when sufficient distance achieved." },
            { from: "OPEN_RUNNER", to: "SCALING", trigger: "Subsequent valid POI identified in same direction during Phase 4 expansion." },
            { from: "OPEN_RUNNER", to: "CLOSED_WIN", trigger: "TP2 / hard TP / manual close at external structure." },
            { from: "OPEN_RUNNER", to: "BREAK_EVEN", trigger: "Stop moved to entry on runner after TP1 close." },
            { from: "BREAK_EVEN", to: "CLOSED_WIN", trigger: "TP2 hit." },
            { from: "BREAK_EVEN", to: "CLOSED_BREAKEVEN", trigger: "Price reverses to entry level." },
            { from: "SCALING", to: "CLOSED_WIN", trigger: "All positions closed at target." },
            { from: "SCALING", to: "CLOSED_LOSS", trigger: "Scaling entry stop hit (original position may be separate)." },
          ],
        },
        {
          id: "sm-structural-phase",
          title: "2.2 Structural Phase State Machine",
          type: "state-machine",
          note: "Applies to every timeframe independently. The same asset can be in Phase 1 on H4 and Phase 5 on M15 simultaneously — this is normal and expected.",
          states: [
            { name: "PHASE_1", desc: "Corrective leg. Market trending internally AGAINST the external bias. Purpose: return to external structure (the true POI). Building lower highs/lows (bullish setup). This is NOT a sell signal — it's fuel creation." },
            { name: "PRE_PHASE_2A", desc: "Price arriving at external POI. Internal liquidity engineering underway. Equal highs/lows forming. No entry yet. Manipulation is being manufactured." },
            { name: "PHASE_2", desc: "Institutional interaction. Price hits true POI sub-zone (precision level). FU candle printed. Change of character from internal corrective trend. External OFB fired." },
            { name: "PHASE_3", desc: "Order flow confirmation. Internal OFB + Final OFB = 3-shift model complete. Entry zone. The corrective trend is officially dead." },
            { name: "PHASE_4", desc: "Expansion begins. Progressive order flow in direction of bias. Price creating higher highs/lows (bullish) on the running timeframe. Scaling entries available." },
            { name: "PHASE_5", desc: "New external structural landmark created. New high (bullish) or new low (bearish) printed. This triggers Phase 1 of the NEXT cycle." },
          ],
          transitions: [
            { from: "PHASE_5", to: "PHASE_1", trigger: "New external landmark printed. Corrective leg begins." },
            { from: "PHASE_1", to: "PRE_PHASE_2A", trigger: "Price enters external POI zone. Internal liquidity being built. Equal lows/highs forming at zone." },
            { from: "PRE_PHASE_2A", to: "PHASE_2", trigger: "FU candle printed at POI. External OFB confirmed." },
            { from: "PRE_PHASE_2A", to: "PHASE_1", trigger: "Price rejects at flip zone (not true POI) and resumes Phase 1 leg to deeper zone." },
            { from: "PHASE_2", to: "PHASE_3", trigger: "Internal OFB + Final OFB confirmed = 3-shift model complete." },
            { from: "PHASE_2", to: "PHASE_1", trigger: "POI blown through — price continues to deeper zone. Restart Phase 1." },
            { from: "PHASE_3", to: "PHASE_4", trigger: "Entry executed. Progressive order flow establishing." },
            { from: "PHASE_4", to: "PHASE_5", trigger: "New external structural high (or low) printed on the timeframe." },
            { from: "PHASE_4", to: "PRE_PHASE_2A", trigger: "Mid-expansion pullback to internal POI (scaling opportunity)." },
          ],
        },
        {
          id: "sm-daily-cycle",
          title: "2.3 Daily Cycle State Machine",
          type: "state-machine",
          note: "Gold resets at 23:00 GMT. FX resets at 22:00 GMT. These states must be tracked in real-time alongside structural analysis.",
          states: [
            { name: "SYDNEY_RANGE_BUILDING", desc: "23:00–00:00 GMT (Gold). Initial range forming. No entries. Classify upcoming daily candle as bullish or bearish based on structure." },
            { name: "ALGORITHM_RAID", desc: "00:00–01:00 GMT. Algorithm liquidates ONE side of the Sydney range. The side liquidated confirms the day type: Sydney LOW raided → bullish day. Sydney HIGH raided → bearish day." },
            { name: "ASIA_RANGE_FORMING", desc: "01:00–05:00 GMT. T-High (bullish) or T-Low (bearish) printing. No aggressive entries — the Asia range is being constructed." },
            { name: "ASIA_EXPANSION", desc: "03:00–05:00 GMT. Asia low (bullish) or Asia high (bearish) formed. Range complete. Both or one side will be liquidated going into Frankfurt." },
            { name: "FRANKFURT_RAID", desc: "05:00–07:00 GMT. Frankfurt liquidates one side of Asia range to fuel London move. On bullish day: raids Asia low. On bearish day: raids Asia high." },
            { name: "LONDON_OPEN", desc: "07:00–12:00 GMT. London creates its own high and low. On rare days: prints the TLD/THD. Usually this is a trap — the TLD is printed at London/NY cross." },
            { name: "NY_CROSS_RAID", desc: "12:00–13:00 GMT. Most critical window. On bullish day: raids London low → prints True Low of Day (TLD). On bearish day: raids London high → prints True High of Day (THD). Highest-probability entry." },
            { name: "EXPANSION", desc: "13:00–17:00 GMT. After TLD/THD printed. Price expands to daily high (bullish) or daily low (bearish). Primary intraday move." },
            { name: "LATE_SESSION", desc: "17:00–22:00 GMT. 4–6 PM GMT is secondary algorithmic window. Low of day can also print here on certain variants. End-of-day position management." },
            { name: "DAILY_CLOSE", desc: "21:00–23:00 GMT. Daily candle closes. All unmanaged positions must have hard TPs set before this period. Gold spread widens on reopen." },
          ],
          transitions: [
            { from: "SYDNEY_RANGE_BUILDING", to: "ALGORITHM_RAID", trigger: "12:00 GMT clock trigger" },
            { from: "ALGORITHM_RAID", to: "ASIA_RANGE_FORMING", trigger: "One side of Sydney liquidated. Day type confirmed." },
            { from: "ASIA_RANGE_FORMING", to: "ASIA_EXPANSION", trigger: "T-High or T-Low created ~03:00 GMT" },
            { from: "ASIA_EXPANSION", to: "FRANKFURT_RAID", trigger: "Asia session end ~05:00 GMT" },
            { from: "FRANKFURT_RAID", to: "LONDON_OPEN", trigger: "07:00 GMT" },
            { from: "LONDON_OPEN", to: "NY_CROSS_RAID", trigger: "12:00 GMT London/NY overlap" },
            { from: "NY_CROSS_RAID", to: "EXPANSION", trigger: "TLD or THD printed. 3-shift OFB confirmed at POI." },
            { from: "EXPANSION", to: "LATE_SESSION", trigger: "~17:00 GMT" },
            { from: "LATE_SESSION", to: "DAILY_CLOSE", trigger: "~21:00 GMT" },
            { from: "DAILY_CLOSE", to: "SYDNEY_RANGE_BUILDING", trigger: "23:00 GMT Gold reopen / 22:00 GMT FX rollover" },
          ],
        },
      ],
    },

    {
      id: "entry-rules",
      label: "3. Entry Rules",
      icon: "📥",
      subsections: [
        {
          id: "er-mandatory",
          title: "3.1 Mandatory Pre-Entry Conditions (ALL must be TRUE)",
          type: "rules",
          rules: [
            { id: "E1", priority: "HARD", rule: "Structural cascade complete. Monthly → H4 timeframes labeled with explicit bias. Lower TF bias aligns with the next higher TF bias (not contradicting it)." },
            { id: "E2", priority: "HARD", rule: "Structural phase on the entry timeframe is Phase 3 (3-shift OFB model complete). Phases 1 and 2 do not permit entry. Phase 4 permits scaling entries with fresh POI." },
            { id: "E3", priority: "HARD", rule: "POI meets all 4 criteria: (1) last sell/buy zone → BOS, (2) free of / incoming liquidity, (3) below/above flip zone, (4) precision sub-zone identified." },
            { id: "E4", priority: "HARD", rule: "FU candle confirmed at POI. Price spiked through the precision level (took stop-losses), then closed in the opposing direction. This is the actual entry trigger." },
            { id: "E5", priority: "HARD", rule: "No entry during 23:00–00:00 GMT (Gold Sydney range building). No entry during 00:00–01:00 GMT unless already managing an open position." },
            { id: "E6", priority: "HARD", rule: "ProcessChecklist.allProcessStepsFollowed = TRUE before order is placed." },
            { id: "E7", priority: "HARD", rule: "Stop loss is placed beyond the FU candle wick (the exact liquidity grab point). For Gold/FX precision entries: max 6 pips. Wider stop = POI not refined enough = do not enter." },
            { id: "E8", priority: "HARD", rule: "Cross-market correlation check: DXY, US30, YenBasket (if Yen pair), EURUSD (if Gold) must not actively contradict the bias. If contradicting: wait or reduce to TP-only trade." },
            { id: "E9", priority: "SOFT", rule: "Daily cycle state is NY_CROSS_RAID, EXPANSION, or LATE_SESSION (12:00–21:00 GMT window). Entries outside this window require explicit daily cycle justification." },
            { id: "E10", priority: "SOFT", rule: "Five-drive exhaustion pattern visible into the POI (5–6 drives into the zone) increases probability. Not mandatory but counts as +1 confluence." },
            { id: "E11", priority: "SOFT", rule: "Volume profile confirms low volume at entry zone (dead zone). Not mandatory but provides additional confidence." },
            { id: "E12", priority: "SOFT", rule: "Wyckoff schematic aligns: Spring / Test phase for buys. Buying Climax / Secondary Test for sells. Particularly relevant for re-accumulation setups." },
          ],
        },
        {
          id: "er-invalidation",
          title: "3.2 Entry Invalidation Conditions (ANY triggers CANCEL)",
          type: "rules",
          rules: [
            { id: "I1", priority: "HARD", rule: "Price breaks through the POI zone with a strong impulsive candle (no FU structure) — zone is blown. POI no longer valid. Move to next lower POI in the impulse." },
            { id: "I2", priority: "HARD", rule: "A higher timeframe external landmark is broken AGAINST the trade direction during Phase 1. Re-assess full structure from scratch." },
            { id: "I3", priority: "HARD", rule: "The corrective leg (Phase 1) makes a lower low BELOW the external POI without any FU reaction — true support has failed." },
            { id: "I4", priority: "HARD", rule: "POI criterion 3 violated: price reacts at the flip zone (not the true POI). This is an INDUCEMENT reaction, not the institutional shift. Do not enter. Wait for the inducement to fail and price to reach the true POI below/above." },
            { id: "I5", priority: "HARD", rule: "Less than 3 order flow shifts confirmed. Only 1 or 2 shifts = aggressive entry only (wider stop, smaller size). Full entry requires 3 shifts." },
            { id: "I6", priority: "HARD", rule: "Gold spread widens at 21:00–23:00 GMT close. Any open limit order must be cancelled or stop widened to account for spread. Do not initiate new entries in this window." },
            { id: "I7", priority: "HARD", rule: "High-impact news event (NFP, rate decision) within 30 minutes. Do not initiate new entries. If already in trade: hard TP must be set." },
          ],
        },
        {
          id: "er-sizing",
          title: "3.3 Position Sizing Rules",
          type: "rules",
          rules: [
            { id: "S1", priority: "HARD", rule: "Maximum absolute risk per trade: 1–2% of total account. Calculate: lots = (account × riskPct) / (stopPips × pipValue)." },
            { id: "S2", priority: "HARD", rule: "Lot size is a function of stop loss precision. A 2-pip stop allows dramatically larger lots than a 20-pip stop for the same USD risk. Never widen stop to fit a desired lot size." },
            { id: "S3", priority: "SOFT", rule: "Counter-trend trades (trading the inducement): maximum 0.5% risk. Hard TP at 30–60 pips. Not to be swung." },
            { id: "S4", priority: "SOFT", rule: "Swing trades (holding through multiple sessions): require fundamental confirmation in addition to technical. Size conservatively until fundamental context confirmed." },
            { id: "S5", priority: "SOFT", rule: "Scaling entries (Phase 4 additions): each addition uses a fresh validated POI with its own stop. Total combined risk across all open positions must not exceed 3% of account." },
          ],
        },
      ],
    },

    {
      id: "exit-rules",
      label: "4. Exit Rules",
      icon: "📤",
      subsections: [
        {
          id: "exit-tp",
          title: "4.1 Take Profit Targets",
          type: "rules",
          rules: [
            { id: "TP1", priority: "HARD", rule: "TP1 = prior swing high (for buys) or prior swing low (for sells) on the entry timeframe. Always take partial profits here. Never skip TP1 chasing TP2 unless in a clean Phase 4 expansion with no liquidity between entry and TP2." },
            { id: "TP2", priority: "SOFT", rule: "TP2 = next external structure landmark on the higher timeframe. For intraday: the Asia high/low or daily external structure. For swing: the weekly structure target." },
            { id: "TP3", priority: "SOFT", rule: "TP3 (runner target) = monthly or multi-week external structure. Only hold runners here with fundamental confirmation and active position management." },
            { id: "TP4", priority: "HARD", rule: "Hard TP (mandatory): set at 30–50 pips when any of the following: (a) entering within 3 hours of session close, (b) fatigued / approaching sleep, (c) Asia session trade where active management is impossible." },
            { id: "TP5", priority: "SOFT", rule: "Flip zone TP: when approaching the next higher timeframe flip zone, consider TP regardless of reaching the structural target — the flip zone will produce a reaction that may temporarily reverse price." },
            { id: "TP6", priority: "SOFT", rule: "Inducement trade TP: strictly 40–80 pips. These are counter-trend moves inside a larger phase. They cannot be held beyond the inducement range." },
          ],
        },
        {
          id: "exit-stop",
          title: "4.2 Stop Loss & Stop Management",
          type: "rules",
          rules: [
            { id: "SL1", priority: "HARD", rule: "Initial stop: placed beyond the FU candle wick (the last grab of liquidity). Never above the entire POI zone — only beyond the wick of the specific precision candle." },
            { id: "SL2", priority: "HARD", rule: "After TP1 hit: move stop to entry (break-even) on the runner. Never hold a runner with a below-entry stop." },
            { id: "SL3", priority: "SOFT", rule: "Trailing stop via structure: as new higher highs form (bullish), trail stop to the most recent confirmed higher low on the running timeframe. Do not move stop below any timeframe's confirmed structure." },
            { id: "SL4", priority: "HARD", rule: "If structural phase shifts AGAINST the trade direction (e.g. H1 creates a lower low against a long), close or tighten immediately. Do not wait for the original stop to be hit." },
            { id: "SL5", priority: "HARD", rule: "Gold daily close (21:00–23:00 GMT): widen stop by 3–5 pips to account for spread widening on reopen. Alternatively, close before 21:00 and re-enter on Sydney." },
            { id: "SL6", priority: "HARD", rule: "Hedge protocol: in confirmed range conditions (between two external landmarks with no clear expansion), a hedge can be placed at the opposing structure. Both stops set at the respective structure extremes. Market decides direction — both stops result in break-even." },
          ],
        },
        {
          id: "exit-force",
          title: "4.3 Forced Exit Conditions",
          type: "rules",
          rules: [
            { id: "FE1", priority: "HARD", rule: "HTF external structure broken against position: close immediately. The structural basis for the trade no longer exists." },
            { id: "FE2", priority: "HARD", rule: "High-impact news event unexpected announcement: if in trade with no hard TP, close at market before the event." },
            { id: "FE3", priority: "HARD", rule: "Three consecutive induced losses at a single POI: step back, do NOT re-enter the same zone. The zone is either invalid or timing is off. Wait for fresh structure." },
            { id: "FE4", priority: "SOFT", rule: "Weekly range exhaustion: on Fridays, if the weekly range (Gold ~300 pips) has been largely printed, reduce expectations and TP earlier. Weekly highs/lows will not be significantly extended late in the week." },
            { id: "FE5", priority: "SOFT", rule: "Fatigue-induced review: if the trader has been active for 10+ hours, implement hard TPs on all open positions. Trading decisions made while fatigued carry elevated execution risk." },
          ],
        },
      ],
    },

    {
      id: "risk-model",
      label: "5. Risk Model",
      icon: "🛡️",
      subsections: [
        {
          id: "rm-limits",
          title: "5.1 Position & Exposure Limits",
          type: "table",
          headers: ["Parameter", "Value", "Rule"],
          rows: [
            ["Max risk per trade", "1–2% account", "HARD — never exceed regardless of conviction"],
            ["Max total open risk", "3% account", "HARD — sum of all open stops must not exceed this"],
            ["Counter-trend trade max risk", "0.5% account", "HARD — inducement trades are not primary positions"],
            ["Max simultaneous trades", "3 positions", "SOFT — managing 4+ positions degrades decision quality"],
            ["Min R:R for entry", "1:10", "SOFT — below 1:10 requires exceptional confluence"],
            ["Target R:R (precision entry)", "1:20 to 1:90+", "GUIDE — achievable with 2–6 pip stops on Gold/FX"],
            ["Hard TP threshold (fatigue/sleep)", "30–50 pips", "HARD — mandatory when managing position is impossible"],
            ["Gold stop minimum (non-asia)", "2–6 pips", "GUIDE — wider stop = entry not refined enough"],
            ["Gold spread buffer (close)", "+3–5 pips", "HARD — required during 21:00–23:00 GMT window"],
            ["Weekly range cap (Gold)", "~300 pips", "CONTEXT — do not expect extension beyond this late in week"],
          ],
        },
        {
          id: "rm-equity-protection",
          title: "5.2 Equity Protection Rules",
          type: "rules",
          rules: [
            { id: "EP1", priority: "HARD", rule: "Daily loss limit: if daily P&L exceeds −3% of account, cease trading for the session. Review process checklist before next session." },
            { id: "EP2", priority: "HARD", rule: "Consecutive losses: 3 consecutive stopped trades on the SAME setup → pause, review structural analysis from scratch. Do not re-enter the same zone a 4th time." },
            { id: "EP3", priority: "HARD", rule: "Break-even psychology: a break-even result is NOT a loss. Do not immediately re-enter to 'recover' the spread cost. This is the primary FOMO trade trigger." },
            { id: "EP4", priority: "HARD", rule: "Revenge trading prohibition: any trade initiated within 10 minutes of a stopped trade that does not complete the full ProcessChecklist is classified as a revenge trade and must be closed at market." },
            { id: "EP5", priority: "SOFT", rule: "Drawdown weeks: if weekly P&L < −5%, reduce lot sizing to 50% of normal for the remainder of that week and the following Monday. Restore to full size when two consecutive profitable days recorded." },
            { id: "EP6", priority: "SOFT", rule: "Equity curve monitoring: track the 20-session rolling win rate. If win rate drops below 40% for 20 sessions, conduct full methodology review before continuing at normal size." },
          ],
        },
        {
          id: "rm-liquidity-quant",
          title: "5.3 Liquidity Quantification Model",
          type: "description",
          content: [
            { label: "Formula", text: "EstimatedLots(zone) = pipDisplacement × 100,000" },
            { label: "Rationale", text: "Approximately 100,000 lots are required to move Gold or major FX 1 pip. Therefore, a 23-pip reaction from a level = ~2.3 million lots of stop-loss volume transacted at that level. This is the measurable liquidity sitting above/below the zone." },
            { label: "Usage", text: "Compare estimated lots on both sides of a consolidation. The side with MORE estimated lots is the more likely expansion target — institutions will hunt the larger pool first." },
            { label: "Example (from call)", text: "Gold 1800 psychological level: 23-pip reaction = 2.3M lots sold at that level. Those stop-losses now become fuel for the buy-side recovery. The 91-pip move from that zone = 9.1M lots transacted total." },
            { label: "Limitation", text: "This is a gross approximation. Actual lot requirements vary by instrument, time of day, and market depth. Use as a relative comparison tool, not an absolute measurement." },
          ],
        },
        {
          id: "rm-induction-filter",
          title: "5.4 Inducement Filter",
          type: "description",
          content: [
            { label: "Definition", text: "An inducement is a move that appears to be the real trade but is a trap. Price reacts at the flip zone (visible S/R), induces traders in the 'right' direction, then fails and continues to the true POI." },
            { label: "Fibonacci Filter", text: "Mark the 61.8% and 70.5% retracement of the current impulse. Reactions in the 61–70% zone are HIGH PROBABILITY inducement reactions, not true POI entries. The true POI lies BELOW the 70.5% (for buys) — typically at or near the external BOS candle." },
            { label: "Identification", text: "The inducement zone reaction will: (1) stop at a visible S/R level, (2) produce a CHoCH on a lower TF, (3) appear to be the legitimate entry — but lacks the full 3-shift OFB model." },
            { label: "Rule", text: "Never enter at the first reaction to a flip zone during Phase 1. Wait for price to prove it is NOT reacting and to continue to the true external POI. The exception is a specific intraday inducement trade (see Entry Rule S3) with maximum 0.5% risk and hard TP." },
            { label: "Mixing of Trends Warning", text: "When an inducement reaction creates a BOS on a lower TF, it produces 'mixing of trends' — where the micro-timeframe looks bullish but the macro timeframe is bearish. This traps both sides. The resolution is ALWAYS in the direction of the macro (higher) timeframe." },
          ],
        },
      ],
    },

    {
      id: "audit",
      label: "6. Audit Requirements",
      icon: "📋",
      subsections: [
        {
          id: "au-100trade",
          title: "6.1 The 100-Trade Audit Log",
          type: "table",
          headers: ["Column", "Type", "Description"],
          rows: [
            ["trade_id", "UUID", "Unique identifier"],
            ["date_time", "datetime", "Entry timestamp"],
            ["symbol", "string", "Instrument traded"],
            ["direction", "LONG/SHORT", "Trade direction"],
            ["lots", "float", "Position size"],
            ["risk_pct", "float", "% of account risked"],
            ["entry_price", "float", "Fill price"],
            ["stop_price", "float", "Initial stop loss price"],
            ["stop_pips", "float", "Stop distance in pips"],
            ["tp1_price", "float", "TP1 level"],
            ["tp2_price", "float | null", "TP2 level if set"],
            ["hard_tp_set", "bool", "Was a hard TP placed?"],
            ["exit_price", "float", "Actual close price"],
            ["pnl_pips", "float", "P&L in pips"],
            ["pnl_usd", "float", "P&L in USD"],
            ["result", "WIN/LOSS/BE", "Trade result"],
            ["entry_type", "REFINED/AGGRESSIVE", "Entry quality classification"],
            ["steps_followed", "bool", "Did all ProcessChecklist steps pass?"],
            ["failure_step", "string | null", "If steps_followed=FALSE: which step failed"],
            ["structure_correct", "bool", "Was the structural analysis correct in hindsight?"],
            ["poi_valid", "bool", "Did the POI meet all 4 criteria?"],
            ["3shift_complete", "bool", "Were all 3 OFB shifts confirmed before entry?"],
            ["notes", "string", "Post-trade analysis"],
          ],
        },
        {
          id: "au-chart-labeling",
          title: "6.2 Chart Labeling Standards",
          type: "rules",
          rules: [
            { id: "CL1", priority: "HARD", rule: "Every structural point on the chart must be labeled with its timeframe. e.g. 'H4 Higher High', 'M30 External Low'. Unlabeled dots are not valid for trading decisions." },
            { id: "CL2", priority: "HARD", rule: "Every session high and low must be marked: Sydney H/L, Asia H/L, London H/L. These must be updated at the START of each session." },
            { id: "CL3", priority: "HARD", rule: "Current structural phase must be written on the chart for the entry timeframe. Not implied — explicitly labeled: 'Phase 1 in progress' or 'Phase 3 — entry zone'." },
            { id: "CL4", priority: "HARD", rule: "Active POI must be boxed and labeled with all 4 criteria pass/fail marks. If any criterion is unlabeled, the POI is not approved for entry." },
            { id: "CL5", priority: "HARD", rule: "Flip zone must be drawn as a horizontal zone, not a line. The zone should span the cluster of candles that created the S/R area." },
            { id: "CL6", priority: "SOFT", rule: "Liquidity pools should be color-coded by type: equal lows (red), Asia lows (orange), trendline liquidity (yellow). Grabbed liquidity should be marked with 'X' or strikethrough." },
            { id: "CL7", priority: "SOFT", rule: "Order flow shifts should be labeled sequentially: 'OFB1 — External', 'OFB2 — Internal', 'OFB3 — Final'. This provides audit trail for why an entry was taken." },
          ],
        },
        {
          id: "au-performance-review",
          title: "6.3 Performance Review Protocol",
          type: "description",
          content: [
            { label: "Weekly review", text: "Every Friday after session close: review all trades taken that week against ProcessChecklist. For each loss: identify which step was the first failure point. Classify as: (a) system failure — all steps followed but trade lost = market randomness, acceptable; or (b) execution failure — a step was skipped = personal error requiring correction." },
            { label: "Struggle diagnosis", text: "When experiencing a losing streak: identify the EXACT component failing. Is it structure identification? POI criterion 3? The 3-shift model? Entry refinement? Each fails for a different reason and has a different remediation. Never assume 'the methodology isn't working' before completing this diagnosis." },
            { label: "Win rate context", text: "Win rate is an unreliable standalone metric. A 40% win rate with 1:20 R:R is far more profitable than 80% at 1:2. Track expected value = (winRate × avgWin) − (lossRate × avgLoss). This is the only meaningful performance metric." },
            { label: "Methodology vs. execution split", text: "At each 100-trade review, calculate: what % of losses had steps_followed=TRUE (methodology) vs. steps_followed=FALSE (execution). If >60% of losses are execution failures, the system is sound but the trader's process discipline needs work. If <40% are execution failures, conduct structural methodology review." },
            { label: "Complacency trigger", text: "After any 5-trade winning streak: explicitly run the full ProcessChecklist on the next trade. Complacency peaks after winning runs. A mandatory checklist reset prevents the equity curve degradation cycle." },
          ],
        },
      ],
    },
  ],
};

// ─── COMPONENTS ────────────────────────────────────────────────────────────

function Badge({ priority }) {
  const colors = {
    HARD: { bg: "#FCEBEB", color: "#A32D2D", border: "#F7C1C1" },
    SOFT: { bg: "#EAF3DE", color: "#3B6D11", border: "#C0DD97" },
  };
  const c = colors[priority] || colors.SOFT;
  return (
    <span style={{ fontSize: 11, fontWeight: 500, padding: "2px 7px", borderRadius: "var(--radius)", background: c.bg, color: c.color, border: `0.5px solid ${c.border}`, whiteSpace: "nowrap" }}>
      {priority}
    </span>
  );
}

function StructStruct({ sub }) {
  return (
    <div>
      {sub.note && (
        <div style={{ background: "#FAEEDA", border: "0.5px solid #FAC775", borderRadius: "var(--radius)", padding: "0.6rem 0.9rem", marginBottom: "1rem", fontSize: 13, color: "#633806" }}>
          ⚠️ {sub.note}
        </div>
      )}
      <div style={{ overflowX: "auto" }}>
        <table style={{ width: "100%", fontSize: 13, borderCollapse: "collapse", tableLayout: "fixed" }}>
          <colgroup>
            <col style={{ width: "22%" }} />
            <col style={{ width: "22%" }} />
            <col style={{ width: "56%" }} />
          </colgroup>
          <thead>
            <tr style={{ background: "var(--surface-1)" }}>
              {["Field", "Type", "Description"].map(h => (
                <th key={h} style={{ padding: "8px 12px", textAlign: "left", fontWeight: 500, fontSize: 12, color: "var(--text-secondary)", borderBottom: "0.5px solid var(--border)" }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {sub.fields.map((f, i) => (
              <tr key={i} style={{ background: i % 2 === 0 ? "transparent" : "var(--surface-1)" }}>
                <td style={{ padding: "7px 12px", borderBottom: "0.5px solid var(--border)", fontFamily: "var(--font-mono)", fontSize: 12, color: "#185FA5", wordBreak: "break-all" }}>{f.name}</td>
                <td style={{ padding: "7px 12px", borderBottom: "0.5px solid var(--border)", fontFamily: "var(--font-mono)", fontSize: 11, color: "#854F0B", wordBreak: "break-all" }}>{f.type}</td>
                <td style={{ padding: "7px 12px", borderBottom: "0.5px solid var(--border)", color: "var(--text-primary)", lineHeight: 1.5 }}>{f.desc}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function StateMachineView({ sub }) {
  const [tab, setTab] = useState("states");
  return (
    <div>
      {sub.note && (
        <div style={{ background: "#E6F1FB", border: "0.5px solid #B5D4F4", borderRadius: "var(--radius)", padding: "0.6rem 0.9rem", marginBottom: "1rem", fontSize: 13, color: "#0C447C" }}>
          ℹ️ {sub.note}
        </div>
      )}
      <div style={{ display: "flex", gap: 6, marginBottom: "1rem" }}>
        {["states", "transitions"].map(t => (
          <button key={t} onClick={() => setTab(t)} style={{ padding: "4px 14px", fontSize: 13, borderRadius: "var(--radius)", border: tab === t ? "1.5px solid #185FA5" : "0.5px solid var(--border)", background: tab === t ? "#E6F1FB" : "var(--surface-2)", color: tab === t ? "#185FA5" : "var(--text-secondary)", cursor: "pointer", fontWeight: tab === t ? 500 : 400 }}>
            {t === "states" ? `States (${sub.states.length})` : `Transitions (${sub.transitions.length})`}
          </button>
        ))}
      </div>
      {tab === "states" && (
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          {sub.states.map((s, i) => (
            <div key={i} style={{ background: "var(--surface-2)", border: "0.5px solid var(--border)", borderRadius: "var(--radius)", padding: "0.7rem 1rem", display: "flex", gap: 12, alignItems: "flex-start" }}>
              <span style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "#185FA5", fontWeight: 500, whiteSpace: "nowrap", minWidth: 160 }}>{s.name}</span>
              <span style={{ fontSize: 13, color: "var(--text-primary)", lineHeight: 1.6 }}>{s.desc}</span>
            </div>
          ))}
        </div>
      )}
      {tab === "transitions" && (
        <div style={{ overflowX: "auto" }}>
          <table style={{ width: "100%", fontSize: 13, borderCollapse: "collapse" }}>
            <thead>
              <tr style={{ background: "var(--surface-1)" }}>
                {["FROM", "TO", "TRIGGER"].map(h => (
                  <th key={h} style={{ padding: "8px 10px", textAlign: "left", fontWeight: 500, fontSize: 12, color: "var(--text-secondary)", borderBottom: "0.5px solid var(--border)", whiteSpace: "nowrap" }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {sub.transitions.map((t, i) => (
                <tr key={i} style={{ background: i % 2 === 0 ? "transparent" : "var(--surface-1)" }}>
                  <td style={{ padding: "7px 10px", borderBottom: "0.5px solid var(--border)", fontFamily: "var(--font-mono)", fontSize: 11, color: "#854F0B", whiteSpace: "nowrap" }}>{t.from}</td>
                  <td style={{ padding: "7px 10px", borderBottom: "0.5px solid var(--border)", fontFamily: "var(--font-mono)", fontSize: 11, color: "#0F6E56", whiteSpace: "nowrap" }}>{t.to}</td>
                  <td style={{ padding: "7px 10px", borderBottom: "0.5px solid var(--border)", lineHeight: 1.5, color: "var(--text-primary)" }}>{t.trigger}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function RulesView({ sub }) {
  return (
    <div>
      {sub.note && (
        <div style={{ background: "#FAEEDA", border: "0.5px solid #FAC775", borderRadius: "var(--radius)", padding: "0.6rem 0.9rem", marginBottom: "1rem", fontSize: 13, color: "#633806" }}>
          ⚠️ {sub.note}
        </div>
      )}
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        {sub.rules.map((r, i) => (
          <div key={i} style={{ background: "var(--surface-2)", border: "0.5px solid var(--border)", borderRadius: "var(--radius)", padding: "0.7rem 1rem", display: "flex", gap: 12, alignItems: "flex-start" }}>
            <span style={{ fontFamily: "var(--font-mono)", fontSize: 11, fontWeight: 500, color: "var(--text-muted)", whiteSpace: "nowrap", minWidth: 36 }}>{r.id}</span>
            <Badge priority={r.priority} />
            <span style={{ fontSize: 13, color: "var(--text-primary)", lineHeight: 1.6, flex: 1 }}>{r.rule}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function TableView({ sub }) {
  return (
    <div style={{ overflowX: "auto" }}>
      <table style={{ width: "100%", fontSize: 13, borderCollapse: "collapse" }}>
        <thead>
          <tr style={{ background: "var(--surface-1)" }}>
            {sub.headers.map((h, i) => (
              <th key={i} style={{ padding: "8px 12px", textAlign: "left", fontWeight: 500, fontSize: 12, color: "var(--text-secondary)", borderBottom: "0.5px solid var(--border)" }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sub.rows.map((row, i) => (
            <tr key={i} style={{ background: i % 2 === 0 ? "transparent" : "var(--surface-1)" }}>
              {row.map((cell, j) => (
                <td key={j} style={{ padding: "7px 12px", borderBottom: "0.5px solid var(--border)", color: j === 0 ? "#185FA5" : "var(--text-primary)", fontFamily: j === 0 ? "var(--font-mono)" : "inherit", fontSize: j === 0 ? 12 : 13, lineHeight: 1.5 }}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function DescriptionView({ sub }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
      {sub.content.map((item, i) => (
        <div key={i} style={{ background: "var(--surface-2)", border: "0.5px solid var(--border)", borderRadius: "var(--radius)", padding: "0.75rem 1rem" }}>
          <p style={{ margin: "0 0 4px", fontWeight: 500, fontSize: 13, color: "var(--text-secondary)" }}>{item.label}</p>
          <p style={{ margin: 0, fontSize: 13, color: "var(--text-primary)", lineHeight: 1.65 }}>{item.text}</p>
        </div>
      ))}
    </div>
  );
}

function Subsection({ sub }) {
  const [open, setOpen] = useState(true);
  const renderBody = () => {
    switch (sub.type) {
      case "struct": return <StructStruct sub={sub} />;
      case "state-machine": return <StateMachineView sub={sub} />;
      case "rules": return <RulesView sub={sub} />;
      case "table": return <TableView sub={sub} />;
      case "description": return <DescriptionView sub={sub} />;
      default: return null;
    }
  };
  return (
    <div style={{ marginBottom: "1.25rem", background: "var(--surface-2)", border: "0.5px solid var(--border)", borderRadius: 12, overflow: "hidden" }}>
      <button onClick={() => setOpen(!open)} style={{ width: "100%", textAlign: "left", background: "transparent", border: "none", cursor: "pointer", padding: "0.85rem 1.1rem", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <span style={{ fontWeight: 500, fontSize: 15 }}>{sub.title}</span>
        <span style={{ color: "var(--text-muted)", fontSize: 18, transition: "transform 0.15s", transform: open ? "rotate(90deg)" : "rotate(0)" }}>›</span>
      </button>
      {open && (
        <div style={{ padding: "0 1.1rem 1.1rem" }}>
          {renderBody()}
        </div>
      )}
    </div>
  );
}

// ─── MAIN ───────────────────────────────────────────────────────────────────

export default function FormalSpec() {
  const [activeSection, setActiveSection] = useState(spec.sections[0].id);
  const section = spec.sections.find(s => s.id === activeSection);

  return (
    <div style={{ fontFamily: "var(--font-sans, system-ui, sans-serif)", color: "var(--text-primary)", padding: "1.25rem 0" }}>
      <div style={{ marginBottom: "1.5rem" }}>
        <p style={{ margin: "0 0 4px", fontSize: 12, fontWeight: 500, color: "var(--text-muted)", letterSpacing: "0.08em", textTransform: "uppercase" }}>Formal System Specification</p>
        <h2 style={{ margin: "0 0 4px", fontSize: 22, fontWeight: 500 }}>{spec.meta.title}</h2>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <span style={{ fontSize: 12, padding: "2px 8px", borderRadius: "var(--radius)", background: "#E6F1FB", color: "#185FA5", border: "0.5px solid #B5D4F4", fontWeight: 500 }}>v{spec.meta.version}</span>
          <span style={{ fontSize: 12, padding: "2px 8px", borderRadius: "var(--radius)", background: "#EAF3DE", color: "#3B6D11", border: "0.5px solid #C0DD97", fontWeight: 500 }}>{spec.meta.status}</span>
          <span style={{ fontSize: 12, color: "var(--text-muted)" }}>Built from 5 trading session transcripts</span>
        </div>
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: "1.5rem" }}>
        {spec.sections.map(s => {
          const isActive = s.id === activeSection;
          return (
            <button key={s.id} onClick={() => setActiveSection(s.id)} style={{ padding: "5px 12px", fontSize: 13, borderRadius: "var(--radius)", border: isActive ? "1.5px solid #185FA5" : "0.5px solid var(--border)", background: isActive ? "#E6F1FB" : "var(--surface-2)", color: isActive ? "#185FA5" : "var(--text-secondary)", cursor: "pointer", fontWeight: isActive ? 500 : 400 }}>
              {s.icon} {s.label}
            </button>
          );
        })}
      </div>

      <div>
        {section.subsections.map(sub => (
          <Subsection key={sub.id} sub={sub} />
        ))}
      </div>
    </div>
  );
}
