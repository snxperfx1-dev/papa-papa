import { useState } from "react";

const ontology = {
  "Market Structure": {
    icon: "📐",
    color: "#185FA5",
    bg: "#E6F1FB",
    items: [
      { term: "External Structure", def: "The highest-timeframe swing highs/lows that define the dominant trend. Price always ultimately returns to or breaks external structure before forming the next expansion leg. The 'true' direction is external; everything inside is internal." },
      { term: "Internal Structure", def: "The lower-timeframe highs/lows building within an external impulse leg. An H4 move is composed of M30 internal highs/lows. Internal structure creates the interim highs/lows (BOS points) but does NOT override external bias." },
      { term: "Higher High / Higher Low (HH/HL)", def: "Bullish market structure: each successive swing high is above the prior, each swing low is above the prior. The market is externally bullish while HH/HL holds." },
      { term: "Lower High / Lower Low (LH/LL)", def: "Bearish market structure: each successive swing high is below the prior, each swing low is below the prior. The market is externally bearish while LH/LL holds." },
      { term: "Break of Structure (BOS)", def: "Price clears a prior swing high (bullish BOS) or swing low (bearish BOS). The nature of the break matters: a clean impulsive break vs. a wick-through tell different stories. Only the highest-timeframe BOS shifts bias." },
      { term: "Change of Character (CHoCH)", def: "The first BOS counter to the prevailing internal trend — i.e. during a bullish internal run, price creates a lower high rather than extending. CHoCH warns that institutional intention may be shifting. Not the same as a confirmed reversal." },
      { term: "Dual Structure Point", def: "A landmark that simultaneously marks structure on two timeframes (e.g. the top of an H4 impulse is also an M30 internal high). Both timeframe labels apply; the higher one carries more weight." },
      { term: "Structural Phase Cycle", def: "The repeating 5-phase model: Ph1 = pullback to external structure | Ph2 = POI interaction / manipulation | Ph3 = shift of order flow | Ph4 = expansion impulse begins | Ph5 = new external landmark created. Price is always in one of these phases." },
      { term: "Phase 1", def: "The corrective leg back from an external high/low into the true POI. Market is in an internal downtrend (if bullish setup) creating lower highs/lows. Purpose: return to institutional demand/supply." },
      { term: "Phase 2 / Pre-Phase 2A", def: "Price arrives at the POI zone. Pre-2A = liquidity is being built around the zone (equal lows/highs, FU candles). Phase 2 = the moment of institutional interaction at the zone. Expect a change of character here." },
      { term: "Phase 5", def: "A new external structural high or low is created. This is the peak/trough of the expansion that triggers Phase 1 of the next cycle." },
      { term: "Manipulation Zone", def: "A deliberate price move engineered to trap retail participants before the true directional move. Typically appears as a consolidation block that spikes through key levels before reversing. Required before every major structural high/low." },
    ]
  },
  "Points of Interest (POI)": {
    icon: "🎯",
    color: "#0F6E56",
    bg: "#E1F5EE",
    items: [
      { term: "POI (Point of Interest)", def: "The precise price zone where institutional activity last occurred, making it the location price will return to for the next expansion. Not just any support/resistance — must meet all 4 criteria." },
      { term: "POI Criterion 1 — Last Sell/Buy Zone", def: "The POI must be the LAST sell-to-buy zone (for a buy setup) or last buy-to-sell zone (for a sell setup) that directly caused the break of the prior external structure point. Not every candle cluster — the final one before the BOS." },
      { term: "POI Criterion 2 — Free of Liquidity / Liquidity Into", def: "The institutional candle within the POI must itself be free of equal highs/lows (i.e. not sitting on a cluster of stops). Simultaneously, there must be INCOMING liquidity (equal lows/trendline lows for buy POIs) between current price and the POI — this fuel is what pulls price to the zone." },
      { term: "POI Criterion 3 — Below/Above the Flip Zone", def: "The POI must sit BELOW the flip zone for buys (above for sells). Any POI above the flip zone is invalid for longs because retail traders have already reacted there; the institutional zone must be deeper." },
      { term: "POI Criterion 4 — Precision (Last Liquidity Left of POI)", def: "Within the valid POI zone, the exact entry is the candle(s) that last grabbed liquidity BEFORE the institutional candle fired. This is the 'last point of liquidity left of POI.' Price is magnetized to this specific sub-zone, not the entire block. Produces 2-4 pip stop losses." },
      { term: "Flip Zone", def: "The price level where most market participants (retail + institutions trading support/resistance) are stepping in. Identifiable by repeated resistance turning support (or vice versa). Any POI above the flip zone is invalid. The flip zone itself can produce a first reaction, but the true trade is below/above it." },
      { term: "POI Refinement Process", def: "Top-down process: H4 identifies the broad zone → M30 narrows it → M15 narrows further → M5 zone → M2 reveals the IFC or specific candle. Execute from the most refined level. Never enter from the H4 zone directly — the stop loss would be too wide." },
      { term: "Higher Timeframe POI vs. Lower Timeframe POI", def: "H4/H1 identifies WHERE to be interested. M5/M2 identifies WHERE to enter. The H4 POI is the filter; the M2 candle is the trigger. Entering from the higher timeframe zone without refinement is an 'aggressive entry.'" },
      { term: "Institutional Candle", def: "A strong momentum candle (often large body, minimal wick) inside the POI zone that represents banks/institutions entering the market. The left-side liquidity grab and right-side structure break frame it. This candle is the core of the POI." },
    ]
  },
  "Liquidity": {
    icon: "💧",
    color: "#853C1D",
    bg: "#FAECE7",
    items: [
      { term: "Liquidity", def: "Stop-loss orders sitting above swing highs or below swing lows that institutions need to fill their large orders. Price is driven to these pools, executes against the trapped orders, then reverses. Liquidity IS the fuel for directional moves." },
      { term: "Equal Highs / Equal Lows (EQH/EQL)", def: "Two or more swing highs/lows at approximately the same level. These are obvious stop-loss clusters. They WILL be raided before price can sustain a move in the opposite direction." },
      { term: "Trendline Liquidity", def: "Stop-losses accumulate under ascending trendlines or above descending trendlines because retail traders place stops just beyond these lines. The raid of trendline liquidity is often the trigger for a POI entry." },
      { term: "Asia High / Asia Low", def: "The high and low formed during the Asian trading session (roughly 23:00–07:00 GMT). These are the first obvious liquidity pools of each day. One side is typically raided in Frankfurt/London; the other becomes a target for the expansion move." },
      { term: "Sydney High / Sydney Low", def: "The high and low formed in the Sydney session (roughly 21:00–23:00 GMT, before Asia opens). Earlier pool; often raided by the algorithm at 12:00–13:00 GMT (1 o'clock liquidity event)." },
      { term: "Temporary High (T-High)", def: "In the most common bullish daily cycle model: a high formed during Asia around 3:00 AM that gets liquidated later (around London/NY cross). It is NOT the true high of the day — it is a liquidity pool for the later expansion." },
      { term: "True Low of the Day (TLD)", def: "The definitive low of a bullish daily candle, typically confirmed at the London-US cross (12:00 noon GMT). Once TLD is printed, the expansion to the high of day can begin." },
      { term: "Liquidity Quantification", def: "Method: multiply the pip displacement of a move by 100,000 lots (roughly the lot size needed to move gold 1 pip). A 23-pip move = ~2.3 million lots. This makes liquidity visible without an order book — bigger reaction = more liquidity was at that level." },
      { term: "Internal Liquidity", def: "Liquidity built WITHIN the current phase of price action (e.g. equal lows forming inside Phase 1 as price approaches a POI). This pre-phase 2A building is confirmation institutional preparation is occurring at the zone." },
      { term: "External Liquidity", def: "Liquidity sitting at the external structural highs/lows (old swing points, Asia highs, etc.). This is the TARGET of the next expansion after a POI entry." },
      { term: "Liquidity Grab (Left of POI)", def: "The specific candle(s) immediately before the institutional candle that took out the last batch of stop-losses. This grab is the precision entry anchor — the 'last liquidity left of POI.' Price will be magnetized back to exactly this level." },
    ]
  },
  "Order Flow": {
    icon: "🌊",
    color: "#534AB7",
    bg: "#EEEDFE",
    items: [
      { term: "Order Flow", def: "The directional momentum of institutional buying/selling reflected in sequential BOS events. Order flow is bullish if it's creating higher highs on the entry timeframe, bearish if lower lows. The three-shift model identifies when flow is changing." },
      { term: "External Order Flow Break", def: "The FIRST shift: the last buy-to-sell zone (in a sell scenario) gets broken down through. This is the first sign that the institutional intention is changing direction. Price is no longer respecting what was the impulse structure." },
      { term: "Internal Order Flow Break", def: "The SECOND shift: the internal trend of the corrective leg itself breaks. If price was making lower lows inside Phase 1, the internal break is when it first makes a higher low. Stronger confirmation than external break alone." },
      { term: "Final Order Flow Break", def: "The THIRD shift: the definitive confirmation. After internal and external breaks, price breaks through the last key level, confirming the new directional bias. Entry is taken here or at the mitigation of this level." },
      { term: "Three-Shift Model", def: "For a confirmed entry, require three sequential shifts of order flow: (1) external break, (2) internal break, (3) final break. Each shift filters out false reversals. Skipping shifts = aggressive entry = larger stop loss." },
      { term: "Internal vs. External Architecture", def: "At any given moment price is either trading the INTERNAL trend (building the corrective leg) or the EXTERNAL trend (expanding in the dominant direction). Knowing which one is active determines whether you fade moves or follow them." },
      { term: "Progressive Order Flow", def: "After a confirmed shift, price makes successive higher highs (bullish) without breaking back below the last higher low. This progressive flow is confirmation the expansion is underway and valid for holding/scaling." },
      { term: "Mitigation Block", def: "After a strong break of structure, price rarely retests the deep zone. Instead it mitigates the WICKS of the breakout candle. A 'mitigation play' entry targets these wick levels rather than the full zone." },
    ]
  },
  "Entry & Execution": {
    icon: "⚡",
    color: "#993556",
    bg: "#FBEAF0",
    items: [
      { term: "FU Candle (Fake-Up / False-Up)", def: "A candle that aggressively spikes through a level (taking liquidity), then completely reverses. The wick represents the liquidity grab; the body represents rejection. On a lower timeframe this looks like an institutional candle grabbing stops then pushing the other way. The FU is the entry trigger after POI criteria are met." },
      { term: "IFC (Institutional Flow Candle)", def: "A specific candle structure within the POI where the imbalance (gap between wicks of consecutive candles) indicates institutional order flow. Originally defined as the 'true' order block. In this methodology: the IFC is a TOOL within the POI zone, not the reason for the trade. Not every trade requires an M1 IFC — sometimes price shifts from within the broader zone." },
      { term: "Aggressive Entry", def: "Entering from the higher timeframe POI without waiting for the full three-shift order flow confirmation or the precise M2 sub-zone. Higher probability of wider stop. Used when time/circumstance forces action but acknowledged as sub-optimal." },
      { term: "POI Refinement Entry", def: "The ideal entry: H4 identifies zone, refined to M15/M5/M2 for the exact sub-zone. Enter at the precision candle (last liquidity left of POI). Stop is 2-4 pips below the wick of the FU. High R:R possible because entry is maximally precise." },
      { term: "Confirmation Criteria at POI", def: "Before executing at a POI: (1) Is price building internal liquidity? (2) Has price changed character? (3) Has the order flow shifted (external break)? (4) Has internal break occurred? (5) Has the final shift confirmed? More criteria met = higher probability." },
      { term: "Stop Loss Placement", def: "Stop goes below the FU candle wick (the last grab of liquidity). In a refined entry this is 2-4 pips. Wider stops indicate the zone was not properly refined. A 4-pip stop on gold or FX is achievable when all 4 POI criteria are met." },
      { term: "Hard TP (Take Profit)", def: "A fixed pip target set before the trade executes — essential when managing positions during sleep/Asia sessions. Typical values: 30-40 pip hard TP during Asia to avoid position management while fatigued. Never rely on manual management if risk of falling asleep." },
      { term: "TP1 — Previous High/Low", def: "First take profit at the prior swing high (in buys). Professional position management: take partial profits at the obvious first target. Leaves the runner for extension targets." },
      { term: "Scaling Entry", def: "Adding to a position at subsequent POIs during the same directional move. E.g. entering a gold buy at POI 1, then adding again at the next valid POI on the pullback. Requires the same 4-criteria POI process for each addition." },
    ]
  },
  "Session & Timing": {
    icon: "🕐",
    color: "#854F0B",
    bg: "#FAEEDA",
    items: [
      { term: "Daily Cycle (Bullish)", def: "Four-point structure: Open → Low (printed first) → High → Close. In the most common variant: Open → T-High (Asia, ~3AM) → Asia Low → TLD at London/NY cross (12:00) → High of day (1-3PM) → Close. Price must visit Low before High on a bullish day." },
      { term: "Daily Cycle (Bearish)", def: "Mirror: Open → T-Low (Asia) → Asia High → True High of day at London/NY cross → Low of day expansion → Close." },
      { term: "One-Side Liquidation Model", def: "A daily candle structure where only one side of the Asia range is raided (instead of both). Rare variant. London simply retraces to the midline and pushes; no complex T-High/T-Low. Identified in hindsight by structure." },
      { term: "Sydney Session (23:00–01:00 GMT Gold)", def: "Gold opens 23:00. From 23:00–midnight: Sydney range forms. Do not trade during range formation. First important algorithmic event: 12:00–13:00 GMT liquidates one side of the Sydney range." },
      { term: "Asia Session Range (23:00–07:00)", def: "4-point structure within session: Open (23:00), T-High (~3AM), Low (~5AM), Close (7AM). The session ALWAYS creates these landmarks algorithmically. Frankfurt (7AM) then raids one side going into London." },
      { term: "1 AM Rule", def: "The algorithm liquidates one side of the Sydney/Asia range between 12:00–01:00 GMT. Do NOT enter trades before 1AM (Gold: before midnight). The raid direction confirms whether the day is bullish (Sydney low raided) or bearish (Sydney high raided). Wait for the raid before seeking entries." },
      { term: "Frankfurt Raid (5:00–7:00 GMT)", def: "Frankfurt extends in the direction needed to reach the true POI for the day. On a bullish day: Frankfurt raids the Asia low to fuel London's push to the high. On a bearish day: Frankfurt raids the Asia high." },
      { term: "London Open (7:00–12:00 GMT)", def: "London creates its own high and low. On the most common bullish model: London low is NOT the TLD — it will be raided by the NY cross. On rare occasions London prints the TLD directly." },
      { term: "London/NY Cross (12:00 GMT)", def: "Most critical intraday time. On bullish days: raids London low to form TLD. On bearish days: raids London high to form True High of Day. After this raid the dominant expansion occurs. Time window: 12:00–15:00 for the main move." },
      { term: "4–6 PM GMT Window", def: "Secondary algorithmic window. The low (or high) of day can also be printed here on certain cycle variants. If at the appropriate POI between 4–6 PM, expect the shift. Disregard advice that 'trades don't happen late in the day.'" },
      { term: "Mid-Day Close (US End of Day)", def: "End-of-day cycles around 21:00–22:00 GMT close out positions. Be cautious of fading moves that are really position-closing. During Asia closeout (early morning) do NOT initiate new directional trades without hard TPs in place." },
      { term: "Asian Range Box", def: "The price range formed during the Asia session. For gold: typically 50–70 pips wide. If taking a trade that runs into the Asia session, hard TP at 30–40 pips is safer than holding through to manual management while fatigued." },
    ]
  },
  "Risk Management": {
    icon: "🛡️",
    color: "#3B6D11",
    bg: "#EAF3DE",
    items: [
      { term: "Risk/Reward Ratio", def: "The ratio of potential profit to maximum loss. A 2-pip stop with a 40-pip target = 1:20. The methodology targets extreme R:R (1:20–1:90+) because POI precision produces tiny stops. A 1:90 trade was cited: 80-pip risk was only ~$80 on 4 lots." },
      { term: "Position Sizing", def: "Lot size determines absolute P&L. A precise 2-pip stop allows large lot sizes without large absolute risk. As understanding grows, lot sizing scales up — the framework enables 17K by 11AM with 2K floating at the right size." },
      { term: "Break-Even Management", def: "Moving stop to entry after sufficient profit protects capital. Psychologically dangerous: break-even hits create frustration that can push traders into revenge/FOMO trades. Treat break-even as a discipline checkpoint, not as a loss." },
      { term: "Asia TP Rule", def: "If entering a trade that will run during the Asia session while the trader is asleep: set a hard TP of 30–40 pips BEFORE sleeping. Do not rely on waking up to manage. Waking up to make technical decisions when groggy is 'a recipe for disaster.'" },
      { term: "Lot Sizing Ladder", def: "Current stage: 2K-17K day range at demonstrated lot sizes. Target: 20K–50K/day. Path: consistent process → improved lot sizing → same trades, bigger size. Not more trades — same setup, scaled lots." },
      { term: "Counter-Trend Trading Limits", def: "During a strongly trending higher-timeframe move (e.g. Yen tanking, US30 ripping), counter-trend cells should be limited to 40–60 pip hard TPs maximum. Do not hold counter-trend trades as swings. Take the inducement retracement for defined pips only." },
      { term: "Drawdown Psychology", def: "Even professional traders have drawdown months (cited: Lambo Rahul's documented drawdown quarter). The body cannot sustain maximum intensity year-round. Accepting drawdown as part of the process prevents compounding errors through revenge trading." },
      { term: "Equity Curve Discipline", def: "Pattern: go up → get complacent → stop following process → go down → refocus → go up. The solution is to follow the process at ALL equity levels, not only after losses. Complacency at profit peaks is where accounts get damaged." },
    ]
  },
  "MOM / CAMP / Manipulation Cycle": {
    icon: "🔄",
    color: "#185FA5",
    bg: "#E6F1FB",
    items: [
      { term: "MOM (Manipulation / Order Flow / Mitigation) Model", def: "The core repeating price cycle: (1) MANIPULATION — liquidity engineered on both sides, retail trapped. (2) ORDER FLOW — institutional direction confirmed by 3-shift model. (3) MITIGATION — price returns to the institutional candle to fill partial orders before expansion. After mitigation comes the impulse." },
      { term: "Manipulation Phase", def: "Deliberate price action designed to trap retail traders. Characteristics: spike through obvious levels (equal highs/lows, trendlines, round numbers), create false BOS, build equal high/low liquidity before the true move. Every major structural point is preceded by manipulation." },
      { term: "Liquidity Engineering", def: "The process by which market makers build the liquidity pools they need to execute large orders. They create obvious structures (equal highs, trendline tags, consolidation ranges) that retail traders cluster stops around, then raid those stops to fill institutional positions." },
      { term: "Accumulation / Re-Accumulation", def: "Consolidation phases where institutions are building positions at specific price levels before an explosive directional move. Re-accumulation (mentioned in gold context at 1720) occurs mid-trend after a partial distribution. Followed by 'explosive push.'" },
      { term: "CAMP (Consolidation / Accumulation / Manipulation / Push)", def: "Alternative framing of the same cycle: price consolidates, institutions accumulate, manipulation spike clears opposing liquidity, then the push/expansion occurs. The spike through is the signal the push is imminent." },
      { term: "Inducement", def: "A deliberate structural formation designed to make retail traders enter in the WRONG direction before the true move. Example: creating a lower high / lower low structure that makes retail sell, then driving price through their stops to the upside. The inducement IS the liquidity for the real move." },
      { term: "FU Through (Fake-Up Through)", def: "Price spikes through a key level (manipulation spike), taking stop-losses and inducing late entries in the wrong direction. Then reverses sharply. The reversal candle IS the FU. The FU through a flip zone/POI is the Phase 2→3 transition." },
      { term: "Death Signal", def: "A confluence of factors indicating the current bias is exhausted and reversal is imminent: (1) price at a major psychological level with volume reaction, (2) Change of Character on the running timeframe, (3) equal highs/lows built at the POI, (4) 3+ shifts of order flow against the prior trend. All four together = death of the current move." },
      { term: "Weekly Manipulation Model", def: "On the weekly chart, 'lower high → lower low' visible to all retail traders is often an inducement. The market engineers this structure so retail sells, then sweeps their stops to push to the monthly structural target. The weekly structure point may not hold — always check if it's inside a larger manipulation zone." },
    ]
  },
  "Psychological Framework": {
    icon: "🧠",
    color: "#533489",
    bg: "#EEEDFE",
    items: [
      { term: "Fear of Missing Out (FOMO)", def: "The primary driver of directional changes at extremes. Late buyers at the high create the liquidity for the sell-off; late sellers at the low create the fuel for the rally. FOMO IS the mechanism — understanding this makes extremes predictable." },
      { term: "Market Participant Psychology", def: "Price moves because of what market participants DO at key levels, not because of the levels themselves. Psychological round numbers (1800 gold), S/R zones, and trend lines cause reactions because PEOPLE react to them. The 'why' behind every reaction is someone entering or exiting." },
      { term: "Trading During Fatigue", def: "Tiredness degrades the ability to label structure and follow process. Trading while exhausted leads to: ignoring established bias, taking counter-trend trades, misidentifying structure. Rules: set hard TPs before sleeping; do not initiate new analysis from a fatigued state." },
      { term: "Swing Trading Psychology", def: "Pure technical framework alone cannot sustain holding a swing through drawdown. Requires fundamental underpinning (Yen weak, Dollar collapsing, US30 pushing) to psychologically justify holding through pullbacks. 'Without fundamental context, swinging is psychologically impossible.'" },
      { term: "Tracking Structure to Hold Swings", def: "Method for holding: as price progresses, track what timeframe is presenting the current structural high. As long as M15 → H1 → H4 → H8 are all bullish and not broken, there is no technical reason to exit. Label each timeframe shift live. 'When gu changed to bullish on H1 I knew I was holding.'" },
      { term: "Competency Cycle", def: "4 stages: (1) Unconsciously Incompetent — don't know what you don't know. (2) Consciously Incompetent — know the gaps, still make errors. (3) Consciously Competent — must think through each step carefully. (4) Unconscious Competence / Mastery — second nature, no deliberate thought required. Takes ~1-2 years of intensive charting to reach stage 3." },
      { term: "Ego & Innovation", def: "The willingness to refine the methodology as understanding grows is non-negotiable. Traders who believe they have 'figured it all out' get humbled. The analogy: Lewis Hamilton optimizes by fractions of a millisecond per corner even after winning championships." },
      { term: "Team Accountability Effect", def: "Verbalizing trade ideas in real time to a group forces clarity of thought and prevents the 'foggy ideas' that come from solo passive charting. The team call is partly a psychological tool — talking through analysis forces precision that silent charting doesn't." },
    ]
  },
  "Multi-Asset & Correlation": {
    icon: "🔗",
    color: "#0F6E56",
    bg: "#E1F5EE",
    items: [
      { term: "US30 / Dow Jones Correlation", def: "When US30 goes up: banks are liquidating USD portfolios and moving into equities → USD weakens → GBP/JPY strengthens (Yen weakens). Having US30 in your watchlist is mandatory for understanding intraday dollar and Yen dynamics." },
      { term: "Gold / EUR/USD Correlation", def: "Gold did not start ripping until EUR/USD reached its appropriate demand level. If EUR/USD is stabilizing at external structure → gold is stabilizing for buyers. Dollar Index declining confirms both. Use EUR/USD as a confluence filter for gold bias." },
      { term: "Dollar Index (DXY)", def: "The umbrella instrument. DXY creates higher highs/higher lows → dollar strength → gold/EUR weakness. DXY in bearish structure → dollar collapsing → gold/EUR buyers. Always establish DXY structural phase before trading gold or FX majors." },
      { term: "Yen Basket", def: "The overall Yen directional composite. If the Yen basket is creating lower lows → Yen is structurally weak → GJ/UJ are biased long. Attempting to short GJ when the Yen basket is bearish is fighting the institutional flow. Check the basket before any Yen pair trade." },
      { term: "GJ (GBP/JPY)", def: "High-volatility Yen pair. When US30 is pushing up and Yen is fundamentally weak, GJ can run 600-800 pips in a single structural cycle. Entry criteria identical to gold: 4-POI criteria, 3-shift order flow. But requires holding conviction through 50-pip pullbacks on a swing — fundamental context essential." },
      { term: "EUR/USD Pipeline to Monthly Structure", def: "EUR/USD at weekly lower-high structure doesn't mean it reverses there. If monthly analysis shows price needs to reach the monthly structural target (e.g. 1.208x), the weekly 'lower high' is just inducement. The weekly point will be swept to fuel the monthly target." },
      { term: "Cross-Market Analysis Protocol", def: "Before any trade: (1) DXY structural phase, (2) relevant equity index (US30/NQ), (3) Yen basket (if Yen pair), (4) correlated FX pair (EURUSD for gold). Confluence across all instruments before executing. Absence of confluence = wait." },
    ]
  },
  "Fundamentals Integration": {
    icon: "📰",
    color: "#BA7517",
    bg: "#FAEEDA",
    items: [
      { term: "Why Fundamentals Matter for Swings", def: "Technical structure tells WHERE and HOW; fundamentals tell WHY price will continue. Without the 'why,' a trader cannot hold a swing through adversity. Knowing 'Yen is weakening because [fundamental reason]' gives psychological permission to hold GJ long through a 50-pip pullback." },
      { term: "NFP Analysis Method", def: "Don't just accept the consensus estimate. Compare the projected NFP number against the historical empirical average (~200K). If consensus is 500K vs. avg of 200K → setup for dollar manipulation to the upside (engineered disappointment when number comes in at ~190K). Use historical empirical data to fade consensus extremes." },
      { term: "Joe Biden Dollar Statement", def: "Example cited: Biden stated he was 'not afraid of the dollar collapsing for a little bit.' This type of statement CONFIRMS what structure already showed — DXY breaking down. Fundamentals don't lead the charts; they corroborate structure." },
      { term: "Bloomberg as Macro Filter", def: "Watching Bloomberg/financial news is the planned next development. Not to trade news directly, but to build macro awareness that explains which currencies are fundamentally weaker/stronger. Filters out confused counter-trend attempts." },
      { term: "Fundamental vs. Technical Timing", def: "Fundamentals explain long-term direction. Technicals explain precise entry timing. Combining them: use fundamental to confirm swing bias, use structure/POI to find entry. Neither alone is sufficient for professional-level trading." },
      { term: "Interest Rate / Bank Portfolio Dynamics", def: "Banks liquidating USD portfolios → moving into stocks (US30 up). This macro flow is the 'why' behind GJ rising when US30 rises. Understanding the capital flow mechanism makes the correlation predictable rather than coincidental." },
    ]
  },
  "Journaling & Process": {
    icon: "📋",
    color: "#5F5E5A",
    bg: "#F1EFE8",
    items: [
      { term: "Journal Purpose", def: "A journal is NOT a trade log for social media credibility. It is a process-improvement document. For each trade: what structural story did I identify? Which POI criteria were met? What was my order flow confirmation? What could be improved? It enables the 1% refinement compounding." },
      { term: "Trading Plan Hierarchy", def: "Step 1: Structural Analysis (which timeframe is bullish/bearish externally). Step 2: Structural Phase Analysis (which phase of the 5-phase cycle are we in). Step 3: POI Selection (4-criteria process). Step 4: Liquidity Analysis (what pools are above/below). Step 5: Order Flow confirmation (3 shifts). Step 6: Entry (refinement to M2). Step 7: Time confirmation (daily cycle phase)." },
      { term: "Struggle Diagnosis Framework", def: "When stuck: identify the exact failure point. Is it: structure identification? POI selection? POI refinement? Order flow shifts? Entry execution? Stop management? Each component fails for a different reason. Diagnose the specific layer before seeking help." },
      { term: "Chart Labeling Discipline", def: "Must label: (1) which timeframe each structural point is on, (2) which structural phase currently active, (3) where liquidity pools are (Asia H/L, equal H/L, trendline liquidity), (4) which POI is the current focus. Unlabeled charts = no context = wrong decisions later in the session." },
      { term: "Review Protocol", def: "After each session: identify any trade where structure was misread. Specifically: was the external vs. internal architecture correctly identified? Was the phase cycle correctly diagnosed? Was the POI valid per all 4 criteria? Did order flow give 3 shifts before entry?" },
    ]
  }
};

const categories = Object.keys(ontology);

export default function TradingOntology() {
  const [activeCategory, setActiveCategory] = useState(categories[0]);
  const [expandedItem, setExpandedItem] = useState(null);
  const [search, setSearch] = useState("");

  const filtered = search.trim().length > 1
    ? categories.flatMap(cat =>
        ontology[cat].items
          .filter(i => i.term.toLowerCase().includes(search.toLowerCase()) || i.def.toLowerCase().includes(search.toLowerCase()))
          .map(i => ({ ...i, category: cat }))
      )
    : null;

  const active = ontology[activeCategory];

  return (
    <div style={{ fontFamily: "var(--font-sans, system-ui, sans-serif)", color: "var(--text-primary)", padding: "1.25rem 0" }}>
      <h2 style={{ fontSize: 13, fontWeight: 500, color: "var(--text-muted)", letterSpacing: "0.08em", textTransform: "uppercase", margin: "0 0 0.5rem" }}>Trading Methodology</h2>
      <p style={{ fontSize: 22, fontWeight: 500, margin: "0 0 1.25rem", lineHeight: 1.3 }}>Complete ontology</p>

      <input
        type="text"
        placeholder="Search terms…"
        value={search}
        onChange={e => setSearch(e.target.value)}
        style={{ width: "100%", marginBottom: "1rem", padding: "8px 12px", fontSize: 14, borderRadius: "var(--radius)", border: "0.5px solid var(--border-strong)", background: "var(--surface-2)", color: "var(--text-primary)", boxSizing: "border-box" }}
      />

      {filtered ? (
        <div>
          <p style={{ fontSize: 13, color: "var(--text-muted)", marginBottom: "0.75rem" }}>{filtered.length} result{filtered.length !== 1 ? "s" : ""} for "{search}"</p>
          {filtered.map((item, i) => (
            <SearchResult key={i} item={item} />
          ))}
        </div>
      ) : (
        <>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: "1.25rem" }}>
            {categories.map(cat => {
              const isActive = cat === activeCategory;
              const data = ontology[cat];
              return (
                <button
                  key={cat}
                  onClick={() => { setActiveCategory(cat); setExpandedItem(null); }}
                  style={{
                    padding: "5px 12px",
                    fontSize: 13,
                    borderRadius: "var(--radius)",
                    border: isActive ? `1.5px solid ${data.color}` : "0.5px solid var(--border)",
                    background: isActive ? data.bg : "var(--surface-2)",
                    color: isActive ? data.color : "var(--text-secondary)",
                    cursor: "pointer",
                    fontWeight: isActive ? 500 : 400,
                    transition: "all 0.15s",
                    whiteSpace: "nowrap"
                  }}
                >
                  {data.icon} {cat}
                </button>
              );
            })}
          </div>

          <div style={{ background: "var(--surface-2)", border: "0.5px solid var(--border)", borderRadius: 12, overflow: "hidden" }}>
            <div style={{ padding: "1rem 1.25rem", borderBottom: "0.5px solid var(--border)", display: "flex", alignItems: "center", gap: 10 }}>
              <span style={{ fontSize: 20 }}>{active.icon}</span>
              <div>
                <p style={{ margin: 0, fontWeight: 500, fontSize: 16, color: active.color }}>{activeCategory}</p>
                <p style={{ margin: 0, fontSize: 13, color: "var(--text-muted)" }}>{active.items.length} concepts</p>
              </div>
            </div>
            {active.items.map((item, i) => (
              <TermRow
                key={i}
                item={item}
                isLast={i === active.items.length - 1}
                isExpanded={expandedItem === i}
                onToggle={() => setExpandedItem(expandedItem === i ? null : i)}
                accentColor={active.color}
                accentBg={active.bg}
              />
            ))}
          </div>
        </>
      )}
    </div>
  );
}

function TermRow({ item, isLast, isExpanded, onToggle, accentColor, accentBg }) {
  return (
    <div style={{ borderBottom: isLast ? "none" : "0.5px solid var(--border)" }}>
      <button
        onClick={onToggle}
        style={{
          width: "100%", textAlign: "left", background: isExpanded ? accentBg : "transparent",
          border: "none", cursor: "pointer", padding: "0.85rem 1.25rem",
          display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12
        }}
      >
        <span style={{ fontSize: 14, fontWeight: 500, color: isExpanded ? accentColor : "var(--text-primary)", lineHeight: 1.4 }}>{item.term}</span>
        <span style={{ fontSize: 16, color: "var(--text-muted)", flexShrink: 0, marginTop: 1, transition: "transform 0.15s", display: "inline-block", transform: isExpanded ? "rotate(90deg)" : "rotate(0)" }}>›</span>
      </button>
      {isExpanded && (
        <div style={{ padding: "0 1.25rem 1rem 1.25rem", background: accentBg }}>
          <p style={{ margin: 0, fontSize: 14, color: "var(--text-primary)", lineHeight: 1.7 }}>{item.def}</p>
        </div>
      )}
    </div>
  );
}

function SearchResult({ item }) {
  const [open, setOpen] = useState(false);
  const data = ontology[item.category];
  return (
    <div style={{ background: "var(--surface-2)", border: "0.5px solid var(--border)", borderRadius: "var(--radius)", marginBottom: 8, overflow: "hidden" }}>
      <button onClick={() => setOpen(!open)} style={{ width: "100%", textAlign: "left", background: open ? data.bg : "transparent", border: "none", cursor: "pointer", padding: "0.75rem 1rem", display: "flex", justifyContent: "space-between", alignItems: "flex-start", gap: 12 }}>
        <div>
          <span style={{ fontSize: 11, color: data.color, fontWeight: 500, display: "block", marginBottom: 2 }}>{data.icon} {item.category}</span>
          <span style={{ fontSize: 14, fontWeight: 500 }}>{item.term}</span>
        </div>
        <span style={{ fontSize: 16, color: "var(--text-muted)", flexShrink: 0 }}>›</span>
      </button>
      {open && (
        <div style={{ padding: "0 1rem 0.75rem", background: data.bg }}>
          <p style={{ margin: 0, fontSize: 14, lineHeight: 1.7 }}>{item.def}</p>
        </div>
      )}
    </div>
  );
}
