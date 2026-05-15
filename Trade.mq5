// =============================================================================
// Trade.mq5  —  Staged Partial-Close EA for MT5 (Hedging Account)
// =============================================================================
// PURPOSE:
//   On attach, opens ONE market position (BUY or SELL) sized proportionally to
//   account balance and the Contracts input. It draws N horizontal take-profit
//   lines (TP_Line_1 … TP_Line_N) on the chart. Each time price reaches the
//   next TP line, 1/N of the original position is closed, a "locked-in points"
//   score is updated, and the line is removed. When all stages fire, or when
//   the position is closed externally (Stop Loss / manual), the EA cleans up
//   and calls ExpertRemove() to detach itself.
//
// ACCOUNT MODEL: MT5 Hedging.
//   Partial closes are implemented as opposing TRADE_ACTION_DEAL orders with
//   req.position = posTicket. This is the correct way to reduce a position on
//   a hedging account. NETTING accounts are NOT supported — on a netting
//   account you must not set req.position; the server nets automatically.
//
// [BROKER-SPECIFIC] Configured for FXIFY / FXPIG (Prime Intermarket Group
//   Eurasia) MT5 server, symbol US500.r (S&P 500 Index CFD, raw spread).
//   Account currency: USD. Search [BROKER-SPECIFIC] to find all places that
//   must be reviewed when switching broker or traded instrument.
//
// STATE PERSISTENCE:
//   All per-position state (initial lots, current stage, locked points, TP
//   prices) is stored in MT5 Global Variables keyed by position ticket number.
//   State survives chart timeframe changes, terminal restarts, and EA
//   reinitialisation — the EA re-attaches correctly to a live trade.
//
// TP LINE DRAGGING:
//   The user may drag TP lines to custom prices at any time. OnChartEvent
//   persists the dragged price to a GV immediately. EnsureTPLines restores
//   from GV on re-attach, so dragged prices survive deinit/init cycles.
// =============================================================================
#property version   "1.00"

// ===================== Inputs =====================
// [BROKER-SPECIFIC] DistancePts semantics are symbol-dependent.
//   For US500.r on FXPIG: 1 input "point" == 1.0 index point.
//   SYMBOL_POINT = 0.01 for US500.r; GetPointsFactorForSymbol returns
//   factor=1.0, so DistancePts maps directly to price units (index points).
//   Example: DistancePts=10 → SL 10 index points from entry; each TP stage
//   is spaced 10 index points apart.
//   To add another symbol, add a case in GetPointsFactorForSymbol and verify
//   the DistancePts semantics match the instrument's quoting convention.
//
// [BROKER-SPECIFIC] FXPIG/FXIFY: Stops level = 2 (symbol spec), so minimum
//   SL distance is 2 × 0.01 = 0.02 price units. DistancePts=10 is well above
//   this. The +1 guard in SendMarketOrderGentleAdaptive is harmless.
enum TradeSideEnum { Buy = 1, Sell = -1 };
input TradeSideEnum BUY_SELL   = Buy;                  // Buy / Sell
input int           Contracts  = 2;                    // Contracts (each contract ≈ 1% initial risk, adds one TP stage)
input double        DistancePts= 10.0;                 // Initial SL distance & per-stage TP spacing (in symbol "points")

// ===================== Fixed settings =====================
#define PRINT_DEBUG           true    // Print diagnostic messages to the journal — SET FALSE before leaving trade unattended

// [BROKER-SPECIFIC] MAGIC: unique numeric identifier for this EA's orders.
//   The EA uses MAGIC to distinguish its own positions from manual trades or
//   other EAs. If running multiple EA instances on the same account, each
//   must have a DIFFERENT MAGIC number to avoid cross-contamination.
#define MAGIC                 246811

// [BROKER-SPECIFIC] Maximum slippage tolerance in broker "points" (multiples
//   of SYMBOL_POINT). For US500.r on FXPIG: 30 points = 0.30 price units
//   (index points) — equivalent real tolerance to the prior IG setup.
//   Increase if fills are frequently rejected during fast markets.
//   Maps to req.deviation in MqlTradeRequest.
#define SLIPPAGE_POINTS       30

// [BROKER-SPECIFIC] Retry configuration for transient server errors (requote,
//   price-changed, connection loss, timeout). 5 attempts × 100 ms = 500 ms.
//   FXPIG is a standard ECN gateway with lower latency than IG; 100 ms is
//   sufficient. Increase on unstable connections.
#define ENTRY_RETRY_ATTEMPTS  5
#define ENTRY_RETRY_DELAY_MS  100

const color TP_COLOR         = clrDodgerBlue;  // Colour for all TP horizontal lines on the chart

// ===================== Helpers =====================
bool ObjExists(const string name){ return (ObjectFind(0,name) != -1); }
void DeleteIfExists(const string name){ if(ObjExists(name)) ObjectDelete(0,name); }
bool ContainsNoCase(string hay, string needle){ StringToUpper(hay); StringToUpper(needle); return (StringFind(hay,needle,0)!=-1); }
// FloorToLotStep: round DOWN to the nearest lot-step multiple (used for position sizing to never exceed budget).
double FloorToLotStep(double lots,double step){ if(step<=0) return lots; return MathFloor(lots/step)*step; }
// RoundToLotStep: round to nearest lot-step multiple (used for piece calculation; ties round up).
double RoundToLotStep(double lots,double step){ if(step<=0) return lots; double s=lots/step; double rs=MathFloor(s+0.5+1e-6); return rs*step; }

// SanitizeKey: strips non-alphanumeric characters from a string, replacing them
// with underscores. Required because MT5 Global Variable names must not contain
// special characters. SPX500(€) contains '(' and '€' which are invalid in GV names.
string SanitizeKey(string s){
  for(int i=0;i<StringLen(s);++i){
    int ch = (int)StringGetCharacter(s,i);
    bool ok = ((ch>='0' && ch<='9') || (ch>='A' && ch<='Z') || (ch>='a' && ch<='z'));
    if(!ok) StringSetCharacter(s,i,'_');
  }
  return s;
}
// GV_WasActiveKey: produces the Global Variable name used to record that this
// EA successfully opened (and managed) a trade. On the next tick after an
// external close (SL or manual), GetWasActive()==true tells OnTick the position
// was previously managed here, so it shows the "closed externally" status and
// calls ExpertRemove() to detach cleanly rather than silently doing nothing.
string GV_WasActiveKey(){
  string sym = SanitizeKey(Symbol());         // sanitise symbol name for GV key
  string side = (BUY_SELL==Buy ? "BUY" : "SELL");
  return "EA_WAS_ACTIVE_" + sym + "_" + side; // e.g. "EA_WAS_ACTIVE_US500_r_BUY"
}
bool GetWasActive(){
  string k = GV_WasActiveKey();
  return (GlobalVariableCheck(k) && GlobalVariableGet(k) > 0.5);
}
void SetWasActive(){
  string k = GV_WasActiveKey();
  GlobalVariableSet(k, 1.0);
}

// GetPointsFactorForSymbol: converts between DistancePts (user input) and
// actual price units. Returns false if the symbol is unrecognised; OnInit
// returns INIT_FAILED in that case — a deliberate safety guard against
// miscalibrated distances on an unknown instrument.
//
// [BROKER-SPECIFIC] *** MUST BE UPDATED FOR EVERY NEW SYMBOL ***
//
// US500.r on FXPIG:
//   SYMBOL_POINT = 0.01 (price quoted to 2 decimal places, e.g. 5280.35).
//   User inputs DistancePts in index points (e.g. 10 = a 10-point move).
//   A 10-index-point move = 1000 SYMBOL_POINTs. Setting factor=1.0 treats
//   DistancePts as raw price units, which equals index points for this symbol
//   (10.0 / 1.0 = 10.0 price units ✓).
//
// For other symbols add a case here before attaching the EA. Examples:
//   EURUSD (5-digit broker): SYMBOL_POINT=0.00001, 1 pip = 10 SYMBOL_POINTs.
//     If DistancePts is in pips, factor = 0.0001/SYMBOL_POINT = 10.0.
//   US30/Wall Street: SYMBOL_POINT varies by broker; verify empirically.
bool GetPointsFactorForSymbol(const string sym, double &factor){
  // [BROKER-SPECIFIC] US500.r on FXPIG: 1 input point == 1.0 price unit (index point).
  // ContainsNoCase matches US500, US500.r, US500.a, etc. — suffix-agnostic.
  if(ContainsNoCase(sym, "US500")) { factor = 1.0; return true; }
  // Add further symbol mappings here as needed.
  return false;  // unknown symbol → EA refuses to start
}

// ===================== Position management =====================
// FindManagedPositionTicket: searches all open positions for one matching the
// given symbol, direction (POSITION_TYPE_BUY/SELL), and this EA's MAGIC number.
// Returns the position ticket (>0) on success, or 0 if no matching position.
// Note: PositionGetSymbol(i) also implicitly selects position i as the current
// position context, so POSITION_TYPE / POSITION_MAGIC can be read immediately.
ulong FindManagedPositionTicket(const string sym, const ENUM_POSITION_TYPE wantType){
  for(int i=PositionsTotal()-1;i>=0;--i){
    if(PositionGetSymbol(i)!=sym) continue;    // also selects position i as current context
    if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)!=wantType) continue;
    if((int)PositionGetInteger(POSITION_MAGIC)!=MAGIC) continue;
    return (ulong)PositionGetInteger(POSITION_TICKET);
  }
  return 0;
}
// AnyActiveTradeOnSymbol: returns true if ANY open position exists on this
// symbol, regardless of MAGIC or direction.
//
// [BROKER-SPECIFIC] Intentionally has NO MAGIC filter. The EA should not open
// a second position on the same symbol no matter who opened the first one
// (manual trade, another EA, etc.). This prevents doubling up.
// On multi-EA setups where several EAs share the same symbol you would need
// to add a MAGIC filter here — but then remove the cross-contamination guard.
bool AnyActiveTradeOnSymbol(){
  string sym=Symbol();
  for(int i=PositionsTotal()-1;i>=0;--i){
    if(PositionGetSymbol(i)==sym) return true;
  }
  return false;
}

// ===================== Chart objects =====================
// CreateOrMoveHLine: creates a dashed horizontal line at 'price', or updates
// its price and colour if the line already exists. All TP lines are created
// here; the EA never deletes lines mid-tick except on close/SL.
void CreateOrMoveHLine(const string name, double price, color c){
  int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
  price = NormalizeDouble(price, digits);
  if(!ObjExists(name)){
    ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
    ObjectSetDouble(0, name, OBJPROP_PRICE, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, c);
    ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, name, OBJPROP_BACK, 0);
  }else{
    ObjectSetDouble(0, name, OBJPROP_PRICE, price);
    ObjectSetInteger(0, name, OBJPROP_COLOR, c);
  }
}
double GetLinePrice(const string name){ if(!ObjExists(name)) return 0.0; return ObjectGetDouble(0,name,OBJPROP_PRICE); }
string TPLineName(const int stage){ return StringFormat("TP_Line_%d",stage); }

// DeleteAllTPLinesAggressive: iterates the full chart object list and deletes
// every object whose name begins with "TP_Line_". Used on full close, SL hit,
// and EA removal to leave the chart clean. Iterates backwards to avoid index
// invalidation when objects are deleted.
void DeleteAllTPLinesAggressive(){
  int total = ObjectsTotal(0);
  for(int i=total-1; i>=0; --i){
    string name = ObjectName(0,i);
    if(StringLen(name)>=8 && StringFind(name,"TP_Line_",0)==0)
      ObjectDelete(0,name);
  }
  ChartRedraw();
}
void DeleteAllTPLines(){ DeleteAllTPLinesAggressive(); }
// DeleteFutureTPLines: removes TP lines for stages fromStage..toStage.
// Called when ChooseClosablePiece determines that a partial close would leave
// less than minLot remaining, so remaining stages are collapsed to the current one.
void DeleteFutureTPLines(const int fromStage, const int toStage){
  for(int s=fromStage; s<=toStage; ++s) DeleteIfExists(TPLineName(s));
  ChartRedraw();
}

// ===================== Global Variables (per ticket) =====================
// All state for a live trade is stored in MT5 Global Variables keyed by
// the position ticket number. This ensures state persists across:
//   • Chart timeframe switches (cause deinit/init)
//   • Terminal restarts (GVs are written to disk)
//   • EA removal and re-attachment
//
// GV naming convention: "EA_<PURPOSE>_<TICKET>"  (ticket as int64 decimal)
//   EA_INIT_LOTS_<T>  : total lots at entry (denominator for partial-close math)
//   EA_NEXT_STAGE_<T> : which TP stage fires next (1-based)
//   EA_LOCKED_PTS_<T> : cumulative "normalised" points locked in so far
//   EA_MAX_STAGES_<T> : effective number of stages (may reduce if piece collapses)
//   EA_TP_PRICE_<T>_<S>: per-stage saved TP line price (set by drag or deinit)
//   EA_LAST_TICKET    : most recently managed ticket (for post-close panel display)
//   EA_WAS_ACTIVE_*   : flag that this EA placed a trade (set in SetWasActive)
string GV_InitLots(const ulong ticket) { return StringFormat("EA_INIT_LOTS_%lld", (long)ticket); }
string GV_NextStage(const ulong ticket){ return StringFormat("EA_NEXT_STAGE_%lld",(long)ticket); }
string GV_LockedPts(const ulong ticket){ return StringFormat("EA_LOCKED_PTS_%lld",(long)ticket); }
string GV_MaxStages(const ulong ticket){ return StringFormat("EA_MAX_STAGES_%lld",(long)ticket); }
string GV_LastTicket()                 { return "EA_LAST_TICKET"; }

// Getters and setters use double-check: create with 0 if missing, then set.
// This prevents potential race conditions on first access (MT5 GVs are process-wide).
double GetInitLotsGV(const ulong ticket){ string k=GV_InitLots(ticket); return GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0.0; }
void   SetInitLotsGV(const ulong ticket,double v){ string k=GV_InitLots(ticket); if(!GlobalVariableCheck(k)) GlobalVariableSet(k,0.0); GlobalVariableSet(k,v); }
int    GetNextStageGV(const ulong ticket){ string k=GV_NextStage(ticket); return GlobalVariableCheck(k) ? (int)GlobalVariableGet(k) : 1; }
void   SetNextStageGV(const ulong ticket,int stage){ string k=GV_NextStage(ticket); if(!GlobalVariableCheck(k)) GlobalVariableSet(k,0); GlobalVariableSet(k,stage); }
double GetLockedPtsGV(const ulong ticket){ string k=GV_LockedPts(ticket); return GlobalVariableCheck(k) ? GlobalVariableGet(k) : 0.0; }
void   SetLockedPtsGV(const ulong ticket,double v){ string k=GV_LockedPts(ticket); if(!GlobalVariableCheck(k)) GlobalVariableSet(k,0.0); GlobalVariableSet(k,v); }
void   AddLockedPtsGV(const ulong ticket,double delta){ SetLockedPtsGV(ticket, GetLockedPtsGV(ticket)+delta); }
int    GetMaxStagesGV(const ulong ticket){ string k=GV_MaxStages(ticket); return GlobalVariableCheck(k) ? (int)GlobalVariableGet(k) : (int)Contracts; }
void   SetMaxStagesGV(const ulong ticket,int v){ string k=GV_MaxStages(ticket); if(!GlobalVariableCheck(k)) GlobalVariableSet(k,0); GlobalVariableSet(k,v); }
ulong  GetLastTicket(){ return GlobalVariableCheck(GV_LastTicket()) ? (ulong)GlobalVariableGet(GV_LastTicket()) : 0; }
void   SetLastTicket(const ulong ticket){ GlobalVariableSet(GV_LastTicket(), (double)ticket); }

// CleanupTicketGVs: deletes per-ticket GVs after a full position close.
// EA_LOCKED_PTS and EA_LAST_TICKET are intentionally kept so the panel can
// still show the final "locked in" total after the position is gone.
void CleanupTicketGVs(const ulong ticket){
  GlobalVariableDel(GV_InitLots(ticket));
  GlobalVariableDel(GV_NextStage(ticket));
  GlobalVariableDel(GV_MaxStages(ticket));
  for(int s=1; s<=Contracts; s++)
    GlobalVariableDel(StringFormat("EA_TP_PRICE_%lld_%d", (long)ticket, s));
}

// ===================== Trade utilities =====================
// IsTransientRetcode: returns true if the server error is likely temporary
// and the request should be retried. A "hard" error (invalid volume, invalid
// symbol, market closed, etc.) returns false and the caller aborts immediately.
//
// [BROKER-SPECIFIC] FXPIG is a standard MT5 ECN broker. TRADE_RETCODE_REJECT
// (10006) is a hard server refusal here — NOT transient — so it is excluded.
// (On IG's custom gateway it was transient, mapping to MT4 error 146.)
bool IsTransientRetcode(const int retcode){
  return (retcode==TRADE_RETCODE_REQUOTE      ||
          retcode==TRADE_RETCODE_PRICE_CHANGED ||
          retcode==10021                        ||  // TRADE_RETCODE_PRICE_OFF (not in all MT5 builds)
          retcode==10031                        ||  // TRADE_RETCODE_CONNECTION (not in all MT5 builds)
          retcode==TRADE_RETCODE_TIMEOUT);
}

// GetFillMode: queries the symbol for its supported order-filling modes and
// returns the best available one (FOK > IOC > RETURN).
//
// [BROKER-SPECIFIC] FXPIG/US500.r advertises both FOK and IOC in the symbol
// spec. GetFillMode will auto-select FOK (preferred). The RETURN fallback is
// kept for safety on any future symbol that reports filling mode = 0.
ENUM_ORDER_TYPE_FILLING GetFillMode(const string sym){
  int filling = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
  if((filling & (int)SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
  if((filling & (int)SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
  return ORDER_FILLING_RETURN;  // fallback for symbols with filling mode = 0
}

// CloseGentle: closes 'lots' of position posTicket via an opposing market order.
// Returns true and sets execPrice on success; returns false on failure.
//
// Parameters:
//   sym          – symbol (e.g. "SPX500(€)")
//   posTicket    – ticket of the position being partially closed
//   lots         – volume to close (must be <= position volume)
//   useBidPrice  – true for BUY position (close at Bid), false for SELL (close at Ask)
//   triggerPrice – the TP line price; closing is refused if price has reverted
//                  back through this level between TP detection and order send
//   baseSlippage – req.deviation in broker points (see SLIPPAGE_POINTS)
//   execPrice    – output: actual fill price (res.price if available, else bid/ask used)
//   attemptsPerTick – how many times to retry transient errors within this call
//
// [BROKER-SPECIFIC — ACCOUNT MODEL: HEDGING ONLY]
//   Partial closes are implemented as TRADE_ACTION_DEAL with req.position set.
//   This is the correct MT5 hedging-account mechanism for reducing a position:
//     BUY  position → close with ORDER_TYPE_SELL at current Bid
//     SELL position → close with ORDER_TYPE_BUY  at current Ask
//   On a NETTING account you must NOT set req.position (or use a different
//   action); the server nets opposing deals automatically.
//
//   req.sl and req.tp are left zero (zero-init). For TRADE_ACTION_DEAL with
//   req.position set, these are ignored — the broker keeps the original
//   position's SL/TP intact through all partial closes.
//
// [BROKER-SPECIFIC] Sleep(100): retry delay for FXPIG's standard ECN gateway.
bool CloseGentle(const string sym, ulong posTicket, double lots,
                 bool useBidPrice, double triggerPrice,
                 int baseSlippage, double &execPrice, int attemptsPerTick=2)
{
  ENUM_ORDER_TYPE_FILLING fillMode = GetFillMode(sym);
  for(int a=1; a<=attemptsPerTick; a++){
    MqlTradeRequest req = {};
    MqlTradeResult  res = {};
    double price = useBidPrice ? SymbolInfoDouble(sym,SYMBOL_BID) : SymbolInfoDouble(sym,SYMBOL_ASK);
    bool okPrice = useBidPrice ? (price>=triggerPrice) : (price<=triggerPrice);
    if(!okPrice) return false;
    req.action       = TRADE_ACTION_DEAL;
    req.position     = posTicket;
    req.symbol       = sym;
    req.volume       = lots;
    req.type         = useBidPrice ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
    req.price        = price;
    req.deviation    = (ulong)baseSlippage;
    req.magic        = (ulong)MAGIC;
    req.type_filling = fillMode;
    if(OrderSend(req,res) && res.retcode==TRADE_RETCODE_DONE){
      // Use the actual fill price if reported; fall back to the bid/ask we sent.
      // res.price is occasionally zero on IG even for successful fills.
      execPrice = (res.price > 0.0) ? res.price : price;
      return true;
    }
    if(!IsTransientRetcode((int)res.retcode)) return false;
    Sleep(100);  // [BROKER-SPECIFIC] 100 ms retry delay for FXPIG gateway
  }
  return false;
}

// SendMarketOrderGentleAdaptive: places a market entry order with SL.
// Retries transient errors up to 'attempts' times; recomputes entry/SL price
// from live bid/ask on each attempt to stay current during fast markets.
// Returns the resulting position ticket on success, or 0 on failure.
//
// Parameters:
//   sym          – symbol to trade
//   type         – ORDER_TYPE_BUY or ORDER_TYPE_SELL
//   lots         – position size (already sized and capped by OnInit)
//   distPts      – user's DistancePts input
//   factor       – from GetPointsFactorForSymbol (price-units-per-point)
//   slippagePts  – max slippage in broker points (SLIPPAGE_POINTS)
//   comment      – order comment string (e.g. "SPX")
//   magic        – EA magic number
//   attempts     – maximum retry count (ENTRY_RETRY_ATTEMPTS)
//   sleepMs      – delay between retries in ms (ENTRY_RETRY_DELAY_MS)
//
// SL enforcement:
//   stopDelta = distPts / factor (price units)
//   SL must be >= stopLevel + 1 points from entry.
//   [BROKER-SPECIFIC] The +1 guard is an IG quirk: the effective broker minimum
//   stop distance can exceed SYMBOL_TRADE_STOPS_LEVEL at larger sizes. The extra
//   point prevents the SL landing exactly at the minimum and being invalidated
//   by tick movement between calculation and order dispatch.
//   On brokers with predictable STOPLEVEL reporting, the +1 is still safe.
ulong SendMarketOrderGentleAdaptive(const string sym, ENUM_ORDER_TYPE type, double lots,
                                    double distPts, double factor,
                                    int slippagePts,
                                    const string comment, int magic,
                                    int attempts, int sleepMs)
{
  int    digits    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
  double point     = SymbolInfoDouble(sym, SYMBOL_POINT);
  int    stopLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
  ENUM_ORDER_TYPE_FILLING fillMode = GetFillMode(sym);

  for(int a=1; a<=attempts; ++a){
    MqlTradeRequest req = {};
    MqlTradeResult  res = {};
    double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
    double bid = SymbolInfoDouble(sym, SYMBOL_BID);
    if(ask<=0 || bid<=0){ Sleep(sleepMs); continue; }

    double entry = (type==ORDER_TYPE_BUY ? ask : bid);
    entry = NormalizeDouble(entry, digits);

    double stopDelta = distPts / factor;
    double sl = (type==ORDER_TYPE_BUY ? entry - stopDelta : entry + stopDelta);
    sl = NormalizeDouble(sl, digits);

    if(PRINT_DEBUG) Print("Entry attempt ",a,"/",attempts,
                          ": ",(type==ORDER_TYPE_BUY?"BUY":"SELL"),
                          " lots=",DoubleToString(lots,4),
                          " entry=",DoubleToString(entry,digits),
                          " sl=",DoubleToString(sl,digits),
                          " stopDistBrokerPts=",DoubleToString(MathAbs(stopDelta/SymbolInfoDouble(sym,SYMBOL_POINT)),1),
                          " stopLevel=",stopLevel);

    // Require >= stopLevel+1 broker-points of SL distance (see function comment above).
    // For US500.r on FXPIG: stopLevel=2, so this requires >=3 broker points (0.03 price
    // units). Harmless: any practical DistancePts value places the SL far above this.
    double stopDistPts = MathAbs(stopDelta / point);
    if(stopDistPts < stopLevel + 1){
      if(PRINT_DEBUG) Print("Entry retry ",a,": SL too close for broker. Need >=",stopLevel+1," pts, have ",DoubleToString(stopDistPts,1));
      Sleep(sleepMs);
      continue;
    }

    req.action       = TRADE_ACTION_DEAL;
    req.symbol       = sym;
    req.volume       = lots;
    req.type         = type;
    req.price        = entry;
    req.sl           = sl;
    req.deviation    = (ulong)slippagePts;
    req.magic        = (ulong)magic;
    req.comment      = comment;
    req.type_filling = fillMode;
    if(OrderSend(req,res) && res.retcode==TRADE_RETCODE_DONE){
      // Search for the resulting position by symbol/direction/MAGIC.
      // This handles both standard brokers and IG's gateway, which sometimes
      // does not populate res.position even on a successful fill.
      ENUM_POSITION_TYPE wantPos = (type==ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
      ulong recovered = FindManagedPositionTicket(sym, wantPos);
      if(recovered > 0) return recovered;
      if(PRINT_DEBUG) Print("Entry: TRADE_RETCODE_DONE but position search failed.");
      return 0;
    }
    if(!IsTransientRetcode((int)res.retcode)){
      if(PRINT_DEBUG) Print("Entry failed. retcode=",res.retcode);
      return 0;
    }
    if(PRINT_DEBUG) Print("Entry transient retcode=",res.retcode,"; retry ",a,"/",attempts);
    Sleep(sleepMs);
  }
  return 0;
}

// ===================== TP utilities =====================
// StagePriceFromEntry: computes the price level of TP stage 'stage' using the
// arithmetic formula: entry ± (intervalPts * stage) / factor.
// For a BUY, TP levels step up above entry; for a SELL, they step down.
// All stages are equally spaced by intervalPts price units.
double StagePriceFromEntry(const bool isBuy, const double entry, const int stage,
                           const double intervalPts, const double factor)
{
  double delta = (intervalPts * stage) / factor;
  return isBuy ? entry + delta : entry - delta;
}

// EnsureTPLines: creates or restores TP lines for stages nextStage..totalStages.
// Does not touch stages before nextStage (those have already fired and been deleted).
//
// Price resolution order:
//   1. If a saved GV price exists for this stage (set by OnChartEvent drag or
//      OnDeinit save), that price is used — preserving the user's custom placement.
//   2. Otherwise the formula StagePriceFromEntry is used.
//
// This function is called:
//   • In OnInit (initial draw + re-attach restore)
//   • After each partial close (to redraw remaining lines)
//   • In OnTick at the start of each tick (idempotent: noop if lines already exist)
void EnsureTPLines(const bool isBuy, const double entry,
                   const int totalStages, const int nextStage,
                   const double intervalPts, const double factor,
                   const ulong ticket=0)
{
  for(int s=nextStage; s<=totalStages; ++s){
    string name = TPLineName(s);
    if(!ObjExists(name)){
      double p = 0.0;
      if(ticket > 0){
        string savedKey = StringFormat("EA_TP_PRICE_%lld_%d", (long)ticket, s);
        if(GlobalVariableCheck(savedKey)) p = GlobalVariableGet(savedKey);
      }
      if(p <= 0.0) p = StagePriceFromEntry(isBuy, entry, s, intervalPts, factor);
      CreateOrMoveHLine(name, p, TP_COLOR);
    }
  }
  for(int s=1; s<nextStage; ++s)
    DeleteIfExists(TPLineName(s));
}

// ====== ChooseClosablePiece: staged partial-close volume calculator ======
//
// Determines how many lots to close at stage 'stage' of 'totalStages'.
// The target is initLots / totalStages per stage (equal N-way split), rounded
// to lot-step. A "look-ahead" guard ensures the leftover after this close is
// always >= minLot; if not, the current close absorbs the would-be orphan.
//
// Parameters:
//   initLots    – original position volume at entry (from GV_InitLots)
//   stage       – current stage number (1-based)
//   totalStages – total number of TP stages (== GetMaxStagesGV)
//   lotStep     – SYMBOL_VOLUME_STEP (broker lot granularity)
//   minLot      – SYMBOL_VOLUME_MIN  (broker minimum tradeable volume)
//   remaining   – current open position volume (from POSITION_VOLUME)
//
// Return value: volume to close, or 0.0 if remaining is already 0.
//
// Final-stage logic (stage >= totalStages):
//   Close exactly what the broker reports as remaining.
//   NormalizeDouble first scrubs floating-point dust accumulated across partial
//   closes (e.g. 0.2999999… → 0.30). Then FloorToLotStep (not Round) to keep
//   the volume <= remaining by definition — sending a volume above remaining
//   returns TRADE_RETCODE_INVALID_VOLUME on strict servers.
double ChooseClosablePiece(const double initLots, const int stage, const int totalStages,
                           const double lotStep, const double minLot, const double remaining)
{
  if(remaining <= 0.0) return 0.0;
  if(stage >= totalStages){
    // Final stage: close exactly what the broker says remains.
    // NormalizeDouble first to scrub any floating-point dust accumulated across
    // multiple partial closes (e.g. 0.29999999999997 → 0.30).
    // Then FloorToLotStep (not Round) so vol ≤ remaining by definition — sending
    // a volume above remaining would cause TRADE_RETCODE_INVALID_VOLUME on strict servers.
    int    lotDigits = (int)MathRound(-MathLog10(lotStep > 0 ? lotStep : 1.0));
    double cleanRem  = (lotStep > 0) ? NormalizeDouble(remaining, lotDigits) : remaining;
    double vol       = FloorToLotStep(cleanRem, lotStep);
    if(vol <= 0.0)   vol = cleanRem;   // remaining < lotStep: send as-is (broker will validate)
    return vol;
  }

  double ideal = initLots / totalStages;
  double piece = RoundToLotStep(ideal, lotStep);

  if(piece < minLot){
    if(remaining >= 2.0 * minLot) piece = minLot;
    else return remaining;
  }

  double leftover = remaining - piece;
  if(leftover < minLot && remaining >= 2.0 * minLot){
    piece = RoundToLotStep(remaining - minLot, lotStep);
    if(piece < minLot) return remaining;
  }else if(leftover < minLot){
    return remaining;
  }

  piece = RoundToLotStep(piece, lotStep);
  if(piece > remaining){
    // Cap to remaining, but keep it a clean lot-step multiple so the broker never
    // receives a volume like 0.30000000000000004 (which some servers reject).
    piece = RoundToLotStep(remaining, lotStep);
    if(piece <= 0.0) piece = remaining; // last resort: send raw if rounding collapses to 0
  }
  if(piece < minLot){
    if(remaining >= minLot) return RoundToLotStep(remaining, lotStep);
    return remaining;
  }
  return piece;
}

// ===================== Panel =====================
// The panel is a set of OBJ_LABEL objects drawn in the top-left corner of the
// chart (CORNER_LEFT_UPPER). Labels are created once and updated each tick.
// DeletePanel() removes all panel labels cleanly on EA removal or full close.
//
// Panel rows (row 0 = top):
//   Row 0: Remaining size    – current % of initial lots still open
//   Row 1: Locked in         – cumulative normalised points locked across all closes
//   Row 2: Stop Loss         – distance to current SL; estimated points if hit now
//   Row 3: Next TP           – distance to next TP; lots closed; locked-in contribution
//   Row 4: (continuation)    – second line of Next TP detail
//   Row 5: Outcome if closed now – estimated final score at current price
#define PANEL_CORNER             0
#define PANEL_XDIST              15
#define PANEL_YDIST              30
#define PANEL_SPACING            40
#define PANEL_FONTSIZE           9
#define PANEL_COLOR              clrBlack
#define PANEL_FONT               "Arial"
#define HEADER_COL_WIDTH         170
#define NEXTTP_SECONDLINE_INDENT 0

#define LEGACY_LABEL_NAME  "EA_InfoPanel_Text"
#define L_REM_HDR   "EA_RemHdr"
#define L_REM_VAL   "EA_RemVal"
#define L_LOCK_HDR  "EA_LockHdr"
#define L_LOCK_VAL  "EA_LockVal"
#define L_STOP_HDR  "EA_StopHdr"
#define L_STOP_VAL  "EA_StopVal"
#define L_NEXT_HDR  "EA_NextHdr"
#define L_NEXT_VAL1 "EA_NextVal1"
#define L_NEXT_VAL2 "EA_NextVal2"
#define L_NOW_HDR   "EA_NowHdr"
#define L_NOW_VAL   "EA_NowVal"

// LotsPrecisionFromStep: computes the number of decimal places needed to
// represent SYMBOL_VOLUME_STEP exactly (e.g. 0.01 → 2, 0.001 → 3).
// Used to format lot sizes in the panel without unnecessary trailing zeros.
int LotsPrecisionFromStep(double step){
  if(step <= 0) return 2;
  int prec = 0; double s = step;
  while(prec < 6 && MathAbs(MathRound(s) - s) > 1e-12){ s *= 10.0; prec++; }
  return MathMax(0, MathMin(6, prec));
}
void DeletePanel(){
  string ids[] = {L_REM_HDR,L_REM_VAL,L_LOCK_HDR,L_LOCK_VAL,L_STOP_HDR,L_STOP_VAL,
                  L_NEXT_HDR,L_NEXT_VAL1,L_NEXT_VAL2,L_NOW_HDR,L_NOW_VAL,LEGACY_LABEL_NAME};
  for(int i=0;i<ArraySize(ids);++i) DeleteIfExists(ids[i]);
}
void CreateOrUpdateLabelRaw(const string name, const string text, int corner, int x, int y,
                             const string font, int size, color c){
  if(!ObjExists(name)){
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_CORNER,    corner);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_BACK,      0);
  }
  ObjectSetString(0, name, OBJPROP_TEXT, text);
  ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
  ObjectSetString(0, name, OBJPROP_FONT, font);
  ObjectSetInteger(0, name, OBJPROP_COLOR, c);
}
void CreateOrUpdateHeader(const string name, const string text, int row){
  int y = PANEL_YDIST + row*PANEL_SPACING;
  CreateOrUpdateLabelRaw(name, text, PANEL_CORNER, PANEL_XDIST, y, PANEL_FONT, PANEL_FONTSIZE, PANEL_COLOR);
}
void CreateOrUpdateValue(const string name, const string text, int row, int xExtra){
  int y = PANEL_YDIST + row*PANEL_SPACING;
  int x = PANEL_XDIST + HEADER_COL_WIDTH + xExtra;
  CreateOrUpdateLabelRaw(name, text, PANEL_CORNER, x, y, PANEL_FONT, PANEL_FONTSIZE, PANEL_COLOR);
}
string FormatSigned(double v, int digits){
  string s = DoubleToString(v, digits);
  if(v>0) s = "+" + s;
  return s;
}
void ShowExternalCloseStatus(){
  DeletePanel();
  CreateOrUpdateHeader(L_REM_HDR, "Status:", 0);
  CreateOrUpdateValue(L_REM_VAL, "Trade closed externally (manual/SL).", 0, 0);
}

// ===================== Update Panel =====================
// UpdatePanel: redraws all panel labels with current position state.
// Called on every tick (tradeActive=true) and after a close event (tradeActive=false).
//
// When tradeActive=true:
//   Selects the managed position, reads current lots/entry/SL/price, computes
//   all panel values, and calls EnsureTPLines to keep lines in sync.
//
// When tradeActive=false:
//   Reads the last-known ticket from GV_LastTicket to display the final
//   locked-in total; all other live fields show "(trade closed)".
//
// "Normalised points" (locked in / stop-loss outcome):
//   Rather than raw points for the total position, the EA tracks contribution
//   per-close as:  points × (closeVol / initLots)
//   This gives a per-unit-of-initial-exposure score that adds up consistently
//   across stages regardless of the varying close volumes.
void UpdatePanel(const bool tradeActive){
  DeleteIfExists(LEGACY_LABEL_NAME);

  string sym    = Symbol();
  double lotStep= SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
  double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
  int    lotPrec= LotsPrecisionFromStep(lotStep);
  double factor = 1.0; GetPointsFactorForSymbol(sym,factor);

  double curLots=0, initLots=0, pct=0, distPts=0, lockedPts=0;
  string stopSuffix = "(trade closed)";
  string nextLineA  = "(trade closed)";
  string nextLineB  = "";
  string nowLine    = "";

  if(tradeActive){
    ENUM_POSITION_TYPE wantType = (BUY_SELL==Buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
    ulong posTicket = FindManagedPositionTicket(sym, wantType);
    if(posTicket>0 && PositionSelectByTicket(posTicket)){
      ulong ticket = posTicket;
      SetLastTicket(ticket);
      SetWasActive();

      curLots   = PositionGetDouble(POSITION_VOLUME);
      initLots  = GetInitLotsGV(ticket); if(initLots<=0.0) initLots=curLots;
      lockedPts = GetLockedPtsGV(ticket);
      pct       = (initLots>0.0) ? (100.0 * (curLots/initLots)) : 0.0;

      bool   isBuy   = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
      double stop    = PositionGetDouble(POSITION_SL);
      double bid     = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);
      double trigger = isBuy ? bid : ask;

      double pointsNow   = (isBuy ? (trigger - entry) : (entry - trigger)) / factor;
      double ifClosedNow = lockedPts + (initLots>0.0 ? pointsNow * (curLots / initLots) : 0.0);
      nowLine = StringFormat("%s pts", FormatSigned(ifClosedNow, 2));

      if(stop>0.0){
        distPts = (isBuy ? (trigger - stop) : (stop - trigger)) * factor;
        double pointsAtStop        = (isBuy ? (stop - entry) : (entry - stop)) / factor;
        double normalizedRemaining = (initLots>0.0 ? pointsAtStop * (curLots / initLots) : 0.0);
        double ifStoppedNow        = lockedPts + normalizedRemaining;
        stopSuffix = StringFormat("(for %s pts (normalized) if hit now)", FormatSigned(ifStoppedNow, 1));
      }else{
        distPts    = 0.0;
        stopSuffix = "(no SL)";
      }

      int nextStage = GetNextStageGV(ticket);
      int maxStages = GetMaxStagesGV(ticket);
      if(nextStage > maxStages){
        nextLineA = "(none left)";
        nextLineB = "";
      }else{
        string tpName = TPLineName(nextStage);
        double tpPx   = GetLinePrice(tpName);
        if(tpPx <= 0.0){
          nextLineA = "(none left)";
          nextLineB = "";
        }else{
          double distToTP    = (isBuy ? (tpPx - trigger) : (trigger - tpPx)) / factor;
          double closeVolPrev= ChooseClosablePiece(initLots, nextStage, maxStages, lotStep, minLot, curLots);
          bool forcedFullClose = (closeVolPrev >= curLots - 1e-8) && (nextStage < maxStages);
          double tpPtsRaw    = (isBuy ? (tpPx - entry) : (entry - tpPx)) / factor;
          double contribNorm = (initLots>0.0 ? tpPtsRaw * (closeVolPrev / initLots) : 0.0);
          double newLocked   = lockedPts + contribNorm;
          int    pctInitial  = (int)MathRound((closeVolPrev / initLots) * 100.0);

          if(!forcedFullClose){
            nextLineA = StringFormat("%.2f pts away (closes %d%% of initial, locks %s pts",
                                     distToTP, pctInitial, FormatSigned(contribNorm, 2));
          }else{
            nextLineA = StringFormat("%.2f pts away (closes 100%% of initial (required to avoid leaving < %.2f lot), locks %s pts",
                                     distToTP, minLot, FormatSigned(contribNorm, 2));
          }
          nextLineB = StringFormat("(normalized), for a new \"Locked In\" of %s)", FormatSigned(newLocked, 2));
        }
      }
    }
  }else{
    ulong lastTicket = GetLastTicket();
    if(lastTicket > 0)
      lockedPts = GetLockedPtsGV(lastTicket);
    curLots = 0; initLots = 0; pct = 0; distPts = 0;
    stopSuffix = "(trade closed)";
    nextLineA  = "(trade closed)";
    nextLineB  = "";
  }

  CreateOrUpdateHeader(L_REM_HDR, "Remaining size:", 0);
  string remText = StringFormat("%.1f%% (%s / %s lots)",
                    pct,
                    DoubleToString(NormalizeDouble(curLots,  lotPrec), lotPrec),
                    DoubleToString(NormalizeDouble(initLots, lotPrec), lotPrec));
  CreateOrUpdateValue(L_REM_VAL, remText, 0, 0);

  CreateOrUpdateHeader(L_LOCK_HDR, "Locked in:", 1);
  CreateOrUpdateValue(L_LOCK_VAL, StringFormat("%s pts (normalized)", FormatSigned(lockedPts, 1)), 1, 0);

  CreateOrUpdateHeader(L_STOP_HDR, "Stop Loss:", 2);
  CreateOrUpdateValue(L_STOP_VAL, StringFormat("%.1f pts %s", distPts, stopSuffix), 2, 0);

  CreateOrUpdateHeader(L_NEXT_HDR, "Next TP:", 3);
  CreateOrUpdateValue(L_NEXT_VAL1, nextLineA, 3, 0);
  CreateOrUpdateValue(L_NEXT_VAL2, (StringLen(nextLineB)>0 ? nextLineB : ""), 4, NEXTTP_SECONDLINE_INDENT);

  CreateOrUpdateHeader(L_NOW_HDR, "Outcome if closed now:", 5);
  CreateOrUpdateValue(L_NOW_VAL, nowLine, 5, 0);
}

// ===================== OnInit =====================
// Entry point called by MT5 when the EA is first attached or reinitialised.
// Responsibilities:
//   1. Validate inputs and symbol support (returns INIT_FAILED on any error).
//   2. Guard against conflict: refuse to start if another position is open on
//      this symbol and it is NOT managed by this EA (no double-up).
//   3. Open a new position if none exists: size it, place the entry order,
//      create TP lines, and initialise all GVs.
//   4. Re-attach to an existing position: restore TP lines from GVs (preserving
//      dragged positions), validate GV state.
//   5. Draw the panel for the initial state.
//
// [BROKER-SPECIFIC] Lot sizing formula (US500.r on FXPIG, USD account):
//   riskAmt  = balance × (Contracts / 100.0)   ← 1% of balance per contract
//   valPerPt = SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE
//            ≈ $100 USD per lot per index point (contract size 100, tick size 0.01)
//   lots     = FloorToLotStep(riskAmt / (valPerPt × distPts))
//
//   Example: balance=$10,000, Contracts=2, DistancePts=10:
//     riskAmt=$200; lots = 200 / (100 × 10) = 0.20 lots
//     0.20 lots × 10 pts × $100/lot/pt = $200 risk ✓
//
//   Using SYMBOL_TRADE_TICK_VALUE keeps this self-calibrating — MT5 computes
//   the per-lot USD value dynamically, so no hardcoded contract size is needed.
int OnInit(){
  string sym     = Symbol();
  double point   = SymbolInfoDouble(sym, SYMBOL_POINT);
  double bid     = SymbolInfoDouble(sym, SYMBOL_BID);
  double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);
  double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
  double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

  DeleteIfExists(LEGACY_LABEL_NAME);

  if(Contracts<1)             { Print("Init: Contracts must be >= 1");       return(INIT_FAILED); }
  if(ask<=0||bid<=0||point<=0){ Print("Init: price/point unavailable.");     return(INIT_FAILED); }

  double factor=0.0;
  if(!GetPointsFactorForSymbol(sym,factor)){ Print("Init: unsupported symbol: ",sym); return(INIT_FAILED); }

  double distPts = MathAbs(DistancePts);
  if(distPts<=0.0){ Print("Init: DistancePts must be > 0"); return(INIT_FAILED); }

  ENUM_POSITION_TYPE wantType = (BUY_SELL==Buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);

  if(AnyActiveTradeOnSymbol() && FindManagedPositionTicket(sym,wantType)==0){
    DeleteAllTPLinesAggressive();
    UpdatePanel(false);
    ExpertRemove(); return(INIT_FAILED);
  }

  ulong posTicket = FindManagedPositionTicket(sym, wantType);
  if(posTicket==0){
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmt  = balance * (Contracts / 100.0);
    // [BROKER-SPECIFIC] Tick-value-based sizing for US500.r (contract size 100).
    // SYMBOL_TRADE_TICK_VALUE / SYMBOL_TRADE_TICK_SIZE = USD value per lot per 1 index point.
    // MT5 computes this from the symbol spec; no hardcoded multiplier needed.
    double tickVal  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double valPerPt = (tickSize > 0.0 && tickVal > 0.0) ? (tickVal / tickSize) : 0.0;
    double lots;
    if(valPerPt > 0.0){
      lots = FloorToLotStep(riskAmt / (valPerPt * distPts), (lotStep>0 ? lotStep : 0.01));
    }else{
      Print("Init: SYMBOL_TRADE_TICK_VALUE unavailable; defaulting to minLot. Check symbol is subscribed.");
      lots = minLot;
    }
    if(PRINT_DEBUG) Print("Init sizing: balance=",DoubleToString(balance,2),
                          " riskAmt=",DoubleToString(riskAmt,2),
                          " tickVal=",DoubleToString(tickVal,5),
                          " tickSize=",DoubleToString(tickSize,5),
                          " valPerPt=",DoubleToString(valPerPt,4),
                          " distPts=",DoubleToString(distPts,2),
                          " raw lots=",DoubleToString(lots,4));
    if(lots < minLot) lots = minLot;

    // Cap lots to broker maximum volume. Without this, oversized lots cause an
    // immediate TRADE_RETCODE_INVALID_VOLUME rejection and the EA returns INIT_FAILED.
    double maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
    if(maxLot > 0.0 && lots > maxLot){
      Print("Init: lots ",DoubleToString(lots,2)," capped to SYMBOL_VOLUME_MAX ",DoubleToString(maxLot,2));
      lots = maxLot;
    }
    if(PRINT_DEBUG) Print("Init: final lots=",DoubleToString(lots,4),
                          " (min=",DoubleToString(minLot,4),
                          " max=",DoubleToString(maxLot,4),
                          " step=",DoubleToString(lotStep,4),")");

  // Open new position — size, cap, and send.
  // [BROKER-SPECIFIC] "US500" is the order comment visible in FXPIG's trade
  // history. FXIFY prop accounts accept short alphanumeric comment strings.
    ENUM_ORDER_TYPE type = (BUY_SELL==Buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
    posTicket = SendMarketOrderGentleAdaptive(sym, type, lots, distPts, factor,
                                             SLIPPAGE_POINTS, "US500", MAGIC,
                                             ENTRY_RETRY_ATTEMPTS, ENTRY_RETRY_DELAY_MS);
    if(posTicket==0){
      Print("Init: ",(type==ORDER_TYPE_BUY?"BUY":"SELL")," failed after retries.");
      return(INIT_FAILED);
    }
    if(!PositionSelectByTicket(posTicket)){
      Print("Init: couldn't select ticket ",posTicket); return(INIT_FAILED);
    }
    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    bool   isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);

    for(int s=1; s<=Contracts; ++s){
      double p = StagePriceFromEntry(isBuy, entry, s, distPts, factor);
      CreateOrMoveHLine(TPLineName(s), p, TP_COLOR);
    }
    SetInitLotsGV(posTicket, PositionGetDouble(POSITION_VOLUME));
    SetNextStageGV(posTicket, 1);
    SetLockedPtsGV(posTicket, 0.0);
    SetMaxStagesGV(posTicket, (int)Contracts);
    SetLastTicket(posTicket);
    SetWasActive();
  }

  // Re-attach block: runs whether we just opened or are reinitialising onto existing trade.
  posTicket = FindManagedPositionTicket(sym, wantType);
  if(posTicket>0 && PositionSelectByTicket(posTicket)){
    bool  isBuy  = (BUY_SELL==Buy);
    ulong ticket = posTicket;
    int   nextSt = GetNextStageGV(ticket);
    double entry = PositionGetDouble(POSITION_PRICE_OPEN);
    SetMaxStagesGV(ticket, (int)Contracts);
    EnsureTPLines(isBuy, entry, GetMaxStagesGV(ticket), nextSt, distPts, factor, ticket);
    if(GetInitLotsGV(ticket)<=0.0) SetInitLotsGV(ticket, PositionGetDouble(POSITION_VOLUME));
    if(!GlobalVariableCheck(GV_LockedPts(ticket))) SetLockedPtsGV(ticket, 0.0);
    SetLastTicket(ticket);
    SetWasActive();
  }

  UpdatePanel(true);
  return(INIT_SUCCEEDED);
}

// ===================== OnDeinit =====================
// Called by MT5 before the EA is removed (chart close, timeframe change, manual
// removal, init failure, etc.). The 'reason' code is available but not used here
// because the same save-and-clean logic is correct for all removal reasons.
//
// What this does:
//   1. Saves the current screen position of every TP line to a GV
//      ("EA_TP_PRICE_<ticket>_<stage>"). If the user dragged a line, the
//      dragged price is already in the GV from OnChartEvent; this call
//      ensures even un-dragged lines survive the deinit/init round-trip.
//   2. Deletes all TP lines from the chart (they will be redrawn by OnInit).
//   3. Panel labels are intentionally NOT deleted so the user can read the
//      final values during the reinitialisation gap.
void OnDeinit(const int reason){
  ulong lastTicket = GetLastTicket();
  if(lastTicket > 0){
    for(int s=1; s<=Contracts; s++){
      string name = TPLineName(s);
      if(ObjExists(name)){
        string savedKey = StringFormat("EA_TP_PRICE_%lld_%d", (long)lastTicket, s);
        GlobalVariableSet(savedKey, GetLinePrice(name));
      }
    }
  }
  DeleteAllTPLinesAggressive();
}

// ===================== OnTick =====================
// Main tick handler. Called on every new price quote.
//
// Execution flow:
//   1. Find the managed position. If gone and we were active → external close
//      (SL or manual): show status, clean up, ExpertRemove.
//   2. If position exists, select it and read state.
//   3. Determine next-stage TP line price and check if price has hit it.
//   4. If not hit: call UpdatePanel(true) and return. (Fast path, most ticks.)
//   5. If hit: run ChooseClosablePiece with look-ahead collapse detection,
//      call CloseGentle, update GV_LockedPts, advance stage.
//   6. If all stages done or position now fully closed: clean up GVs, remove
//      TP lines, UpdatePanel(false), ExpertRemove.
void OnTick(){
  string sym = Symbol();
  ENUM_POSITION_TYPE wantType = (BUY_SELL==Buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
  ulong posTicket  = FindManagedPositionTicket(sym, wantType);
  bool  tradeActive = (posTicket > 0);

  if(!tradeActive){
    if(GetWasActive()){
      if(PRINT_DEBUG) Print("Trade closed externally (manual close or Stop Loss). EA is detaching.");
      ShowExternalCloseStatus();
      DeleteAllTPLinesAggressive();
      ExpertRemove();
      return;
    }
    UpdatePanel(false);
    return;
  }

  if(!PositionSelectByTicket(posTicket)){ UpdatePanel(false); return; }

  bool   isBuy   = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
  double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
  double minLot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
  double factor  = 1.0; GetPointsFactorForSymbol(sym, factor);
  double distPts = MathAbs(DistancePts);
  double entry   = PositionGetDouble(POSITION_PRICE_OPEN);
  ulong  ticket  = posTicket;
  SetWasActive();

  int    nextStage = GetNextStageGV(ticket);
  if(nextStage<1) nextStage=1;

  int    effectiveStages = GetMaxStagesGV(ticket);
  double remaining       = PositionGetDouble(POSITION_VOLUME);
  double closeVolPrev    = ChooseClosablePiece(GetInitLotsGV(ticket)>0 ? GetInitLotsGV(ticket) : remaining,
                                               nextStage, effectiveStages, lotStep, minLot, remaining);
  bool forcedFullClosePreview = (closeVolPrev >= remaining - 1e-8) && (nextStage < effectiveStages);
  if(forcedFullClosePreview){
    SetMaxStagesGV(ticket, nextStage);
    DeleteFutureTPLines(nextStage+1, (int)Contracts);
    effectiveStages = nextStage;
  }

  EnsureTPLines(isBuy, entry, effectiveStages, nextStage, distPts, factor, ticket);
  SetLastTicket(ticket);
  UpdatePanel(true);

  string tpName = TPLineName(nextStage);
  double tpPx   = GetLinePrice(tpName);
  if(tpPx<=0.0) return;

  double bidNow = SymbolInfoDouble(sym, SYMBOL_BID);
  double askNow = SymbolInfoDouble(sym, SYMBOL_ASK);
  bool   hit    = isBuy ? (bidNow>=tpPx) : (askNow<=tpPx);
  if(!hit) return;

  // Re-select position after UpdatePanel: UpdatePanel iterates positions by
  // index, which changes the implicit position context. Re-select here so all
  // reads below (POSITION_VOLUME, POSITION_PRICE_OPEN) reference our position.
  if(!PositionSelectByTicket(posTicket)){ UpdatePanel(false); return; }

  double initLots    = GetInitLotsGV(ticket);
  if(initLots<=0.0)  initLots = PositionGetDouble(POSITION_VOLUME);
  double remainingNow = PositionGetDouble(POSITION_VOLUME);

  double closeVol = ChooseClosablePiece(initLots, nextStage, effectiveStages, lotStep, minLot, remainingNow);

  if(closeVol > 0.0){
    bool   useBid = isBuy;
    double execPx = 0.0;
    bool ok = CloseGentle(sym, ticket, closeVol, useBid, tpPx, SLIPPAGE_POINTS, execPx, 2);
    if(ok){
      double points  = (isBuy ? (execPx - entry) : (entry - execPx)) / factor;
      double contrib = points * (closeVol / initLots);
      AddLockedPtsGV(ticket, contrib);

      if(PRINT_DEBUG){
        double after = remainingNow - closeVol;
        Print("TP",nextStage," ",(isBuy?"BUY":"SELL"),
              ": closed ",DoubleToString(closeVol,2),
              " at ",DoubleToString(execPx,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS)),
              " points=",DoubleToString(points,1),
              " contrib=",DoubleToString(contrib,1),
              " left ",DoubleToString(after,2));
      }

      bool closedAllThisTick = (remainingNow - closeVol) <= 1e-8;
      if(closedAllThisTick){
        DeleteIfExists(tpName);
        ChartRedraw();
        SetNextStageGV(ticket, nextStage + 1);
        SetMaxStagesGV(ticket, nextStage);
        DeleteAllTPLinesAggressive();
        CleanupTicketGVs(ticket);
        UpdatePanel(false);
        ExpertRemove();
        return;
      }
    }else{
      return;
    }
  }

  DeleteIfExists(tpName);
  ChartRedraw();

  int newStage = nextStage + 1;
  SetNextStageGV(ticket, newStage);

  if(newStage > GetMaxStagesGV(ticket)){
    if(!PositionSelectByTicket(posTicket)){ UpdatePanel(true); return; }
    double rem = PositionGetDouble(POSITION_VOLUME);
    if(rem > 0.0){
      rem = RoundToLotStep(rem, (lotStep>0 ? lotStep : 0.01));
      if(rem > 0.0){
        double execPx2 = 0.0;
        bool   useBid2 = isBuy;
        if(CloseGentle(sym, ticket, rem, useBid2, tpPx, SLIPPAGE_POINTS, execPx2, 2)){
          double points2  = (isBuy ? (execPx2 - entry) : (entry - execPx2)) / factor;
          double contrib2 = points2 * (rem / initLots);
          AddLockedPtsGV(ticket, contrib2);
          if(PRINT_DEBUG) Print("Final close rem=",DoubleToString(rem,2),
                                " execPx=",DoubleToString(execPx2,(int)SymbolInfoInteger(sym,SYMBOL_DIGITS)),
                                " points=",DoubleToString(points2,1),
                                " contrib=",DoubleToString(contrib2,1));
        }
      }
    }
    DeleteAllTPLinesAggressive();
    CleanupTicketGVs(ticket);
    UpdatePanel(false);
    ExpertRemove();
    return;
  }

  EnsureTPLines(isBuy, entry, GetMaxStagesGV(ticket), newStage, distPts, factor, ticket);
}

// ===================== OnChartEvent =====================
// Called by MT5 on user interactions with chart objects. We handle only the
// CHARTEVENT_OBJECT_DRAG event for TP_Line_* objects (user drags a TP line).
//
// When a TP line is dragged:
//   1. The new price is read from the object's OBJPROP_PRICE.
//   2. The price is immediately saved to the per-stage GV
//      ("EA_TP_PRICE_<ticket>_<stage>"). This ensures the dragged position
//      survives a subsequent deinit/init cycle (timeframe change etc.),
//      since EnsureTPLines checks this GV before using the formula.
//
// Note: the stage number is extracted by stripping the "TP_Line_" prefix (8 chars)
// from the object name and converting the remainder to an integer.
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam){
  // lparam and dparam are not used for CHARTEVENT_OBJECT_DRAG (sparam carries the object name)
  if(id==CHARTEVENT_OBJECT_DRAG && StringFind(sparam,"TP_Line_",0)==0){
    if(PRINT_DEBUG)
      Print(sparam," moved to ",
            DoubleToString(ObjectGetDouble(0,sparam,OBJPROP_PRICE),
                           (int)SymbolInfoInteger(Symbol(),SYMBOL_DIGITS)));
    // Persist the dragged position immediately so it survives a deinit/init cycle.
    ulong lastTicket = GetLastTicket();
    if(lastTicket > 0){
      int stage = (int)StringToInteger(StringSubstr(sparam, 8)); // strip "TP_Line_"
      if(stage > 0){
        string savedKey = StringFormat("EA_TP_PRICE_%lld_%d", (long)lastTicket, stage);
        GlobalVariableSet(savedKey, ObjectGetDouble(0, sparam, OBJPROP_PRICE));
      }
    }
  }
}
