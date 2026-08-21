/ ============================================================================
/ tests/test_ai.k  -  amber-ai 2.0.0 agent suite.
/ GNU AGPLv3 - see LICENSE and NOTICE.
/ ----------------------------------------------------------------------------
/ Run it from anywhere:
/     ./amber tests/test_ai.k
/ Exits non-zero if any case fails.
/ ----------------------------------------------------------------------------
/ This suite NEVER needs a model backend, and never touches the network in a
/ way that can block: the endpoint is pointed at 127.0.0.1:9 (the discard port,
/ closed on any sane host) so what is measured is the transport's FAILURE path
/ -- which is the path that actually has to be bullet-proof, because a REPL
/ must stay completely usable when ollama is not running.
/x
/ Covered here:
/   1. `aio  switches, the shipped defaults (agent ON, Tab assist ON), and
/           runtime reconfiguration of url / model / budgets
/   2. `ai   graceful failure with no backend: a return code, never an exception
/   3. persistent memory: record -> file -> reload round trip, dedupe, cap,
/      and the exact on-disk line format that src/ln.c mines for Tab candidates
/   4. relevance ranking, i.e. the retrieval half of the few-shot memory
/   5. schema inspection (tables, attributes, dicts, vectors)
/   6. prompt assembly
/   7. the \ai command parser and every sub-command that needs no network
/x
/ ai.say / ai.o are rebound to collectors for the duration, so the suite stays
/ quiet AND the agent's printed output becomes assertable.
/x
/ STYLE (see the gotcha list in tests/harness.k): no bracketed [a;b] block ever
/ appears inside an argument list, and no top-level statement is left with a
/ value -- either would silently change what runs.
/ ============================================================================
DIR:{$[#p:"/"/-1_"/"\x;p;"."]}`argv 1
LOAD:{{. x^(`c$13)}'0:x;}
LOAD DIR,"/../amber.k"
LOAD DIR,"/harness.k"
/x lib/ai.k carries multi-line definitions, so it is evaluated WHOLE-FILE.
. `c$1:DIR,"/../lib/ai.k"

/x ---- sandbox: a private memory file and a guaranteed-dead endpoint --------
MEM:"/tmp/amber_ai_test_memory.k"
DEAD:"http://127.0.0.1:9/api/generate"
ai.MEMF::MEM
ai.M::()
OUT:()
ai.say::{OUT::OUT,,x;}
ai.o::{OUT::OUT,,x;}
set:{`aio x;}
st:{`aio[-1]}
on:{(st[])0}
tab:{(st[])1}
url:{(st[])2}
mdl:{(st[])3}
qms:{(st[])4}
tms:{(st[])5}
grab:{OUT::();.[x;,y;{}];r:OUT;OUT::();r}
joined:{$[0=#x;"";"\n"/x]}
say:{joined grab[x;y]}
has:{[hay;ndl]0<#ss[hay;ndl]}
set[(0;DEAD)]

/x ============================ 1. switches ================================
t[`statusShape;    #st[];            7]
t[`urlSet;         url[];            DEAD]
t[`onByDefault;    on[];             1]
t[`tabOnByDefault; tab[];            1]
set[0]
t[`switchOff;      on[];             0]
set[1]
t[`switchOn;       on[];             1]
set[2]
t[`tabOff;         tab[];            0]
set[3]
t[`tabOn;          tab[];            1]
tk[`retryIsSafe;   "`aio[4]"]
set[(1;"test-model")]
t[`modelSet;       mdl[];            "test-model"]
set[(2;1500)]
t[`qaBudgetSet;    qms[];            1500]
set[(3;60)]
t[`tabBudgetSet;   tms[];            60]
set[(0;"not a url")]
t[`badUrlRejected; url[];            DEAD]
set[(0;"https://example.com/v1")]
t[`tlsUrlRejected; url[];            DEAD]
set[(1;"")]
t[`emptyModelRejected; mdl[];        "test-model"]

/x ==================== 2. transport: no backend, no drama ==================
r:`ai[("sys";"hello";200;16)]
t[`aiPairShape;    #r;               2]
t[`aiRcIsInt;      @r 0;             `i]
t[`aiFailsCleanly; 0<r 0;            1]
t[`aiMsgIsText;    `C~@r 1;          1]
t[`aiMsgNonEmpty;  0<#r 1;           1]
tk[`aiPlainString; "`ai[\"just a prompt\"]"]
tk[`aiOddListSafe; "`ai[(1 2 3;4 5 6)]"]
te[`aiRejectsAtom; "`ai[42]"]
/x switched off, the agent answers without opening a socket at all
set[0]
t[`offSaysSo;      has[say[ai.q;"anything"];"switched off"];1]
set[1]

/x ==================== 3. persistent memory round trip =====================
ai.M::()
t[`addFirst;       ai.add["q";"select px from trades";"trades"];1]
t[`addSecond;      ai.add["q";"select sym from quotes";"quotes"];1]
t[`memCount;       #ai.M;            2]
t[`addDedupes;     ai.add["q";"select px from trades";"trades"];1]
t[`stillTwo;       #ai.M;            2]
t[`hitsBumped;     (ai.M 0)2;        2]
t[`addRejectsEmpty;ai.add["q";"";"c"];0]
t[`addRejectsType; ai.add["q";42;"c"];0]
tk[`saveRuns;      "ai.save[]"]
ai.M::()
t[`clearedBeforeLoad;#ai.M;          0]
t[`loadRoundTrip;  ai.load[];        2]
t[`loadedTextA;    (ai.M 0)3;        "select px from trades"]
t[`loadedTextB;    (ai.M 1)3;        "select sym from quotes"]
t[`loadedKind;     (ai.M 0)0;        "q"]
t[`loadedCtx;      (ai.M 0)4;        "trades"]
/x the on-disk line is exactly the shape src/ln.c mines for Tab candidates
ln:ai.line[("q";1755512345;3;"select sym,px from trades";"trades")]
t[`lineFormat;     7#ln;             "ai.rec["]
t[`lineQuotesText; has[ln;"\"select sym,px from trades\""];1]
ai.M::()
. ln
t[`lineIsEvaluable;#ai.M;            1]
/x embedded quotes and backslashes survive the file round trip
ai.M::()
esc:ai.add["q";"a\"b\\c";"ctx"]
sv:ai.save[]
ai.M::()
ld:ai.load[]
t[`escapeRoundTrip;(ai.M 0)3;        "a\"b\\c"]
/x the cap is enforced, newest first out the back
ai.M::()
fill:{ai.add["q";"line ",$x;"c"]}'!20
ai.MAX::5
cap:ai.trim[]
t[`capEnforced;    #ai.M;            5]
t[`capKeepsNewest; (*|ai.M)3;        "line 19"]
ai.MAX::400
t[`forget;         ai.forget[];      1]
t[`forgotten;      #ai.M;            0]

/x ==================== 4. relevance ranking ===============================
ai.M::()
a1:ai.add["q";"select avg px by sym from trades";"trades"]
a2:ai.add["q";"til 10";"x"]
a3:ai.add["s";"trades:table(time sym px)";"trades"]
t[`topPicksRelevant;*ai.top["avg px by sym";1;"q"];"select avg px by sym from trades"]
t[`topRespectsN;   #ai.top["trades";1;"q"];1]
t[`topFiltersKind; #ai.top["trades";9;"s"];1]
/x An empty kind set searches every kind, so it reaches the `s` record that
/x "q" filtered out. It does NOT reach `til 10`, which shares no word with the
/x query -- see topFloorRejectsIrrelevant below. This used to want 3, back when
/x a zero-overlap record was returned like any other.
t[`topAllKinds;    #ai.top["trades";9;""];2]
/x ---- the relevance floor -------------------------------------------------
/x An exemplar must share at least ai.MINS words with the question, over the
/x text AND the context. Without this every pick was a 0-overlap tie broken by
/x position, which meant whatever the user last typed. Measured on the 344
/x natural-language questions in data/train.jsonl, text-only scoring put the
/x right answer among the three exemplars 0 times.
t[`topFloorRejectsIrrelevant;#ai.top["anything at all";9;"q"];0]
t[`topScoresContextField;    #ai.top["trades";9;"q"];1]
t[`ovlCountsText;   ai.ovl[ai.words"avg px";ai.M 0];2]
t[`ovlCountsContext;ai.ovl[ai.words"trades";ai.M 0];2]
t[`ovlZeroWhenUnrelated;ai.ovl[ai.words"banana";ai.M 0];0]
ai.M::()
t[`topEmptyIsSafe; #ai.top["q";3;"q"];0]
t[`wordsSplit;     ai.words"select px, avg(px) from t";("select";"px";"avg";"px";"from";,"t")]
t[`normLowersAndSplits;ai.norm"SELECT A,B";"select a b"]

/x ==================== 5. schema inspection ===============================
trades:+`time`sym`px`sz!(`sa 1 2 3 4;`pa[`a`a`b`b];10 11 12 13.0;100 200 300 400)
dd:`a`b!(1;2)
vv:til 100
desc:ai.ndesc`trades
t[`tableDesc;      has[desc;"trades:table("];1]
t[`tableSortedCol; has[desc;"time:I`s"];1]
t[`tablePartedCol; has[desc;"sym:S`p"];1]
t[`tableFloatCol;  has[desc;"px:F"];1]
t[`tableRowCount;  has[desc;"[4 rows]"];1]
t[`vectorDesc;     ai.ndesc`vv;      "vv:I[100]"]
t[`dictDesc;       has[ai.ndesc`dd;"dd:dict("];1]
ctx:ai.ctx[]
t[`ctxHasTable;    has[ctx;"trades:table("];1]
t[`ctxHasVector;   has[ctx;"vv:I[100]"];1]
t[`ctxHidesStdlib; has[ctx;"movavg"];0]
t[`ctxNames;       has[ai.ctxnames[];"trades"];1]
t[`descNeverThrows;ai.ndesc0`nosuchname;"nosuchname:?"]
t[`attrOfSorted;   ai.attr(+trades)`time;"`s"]
t[`attrOfPlain;    ai.attr(+trades)`px;""]

/x ==================== 6. prompt assembly =================================
ai.M::()
a4:ai.add["q";"select px from trades where px>10";"trades"]
p:ai.prompt["Do the thing";"the question"]
/x A second prompt from a query that IS about data, because exemplars are now
/x gated: "the question" names no table and no db word, so it earns none.
pq:ai.prompt["Do the thing";"select px from trades where px>10"]
/x The prompt is what the model is CHARGED for, so these pin its shape.
/x The schema block is now the compact one (ai.sch), not ai.ctx: names only,
/x no types, no attributes, no row counts. ai.ctx is unchanged and still backs
/x `\ai status`, where a human wants all of that -- see promptDropsRowCounts.
t[`promptHasSchema;    has[pq;"### Schema"];1]
t[`promptSchemaCompact;has[pq;"SCHEMAS: "];1]
t[`promptHasTable;     has[pq;"trades:("];1]
t[`promptDropsRowCounts;has[pq;" rows]"];0]
t[`promptDropsColTypes;has[pq;"trades:table("];0]
t[`promptHasExamples;  has[pq;"### Examples"];1]
t[`nonDbQueryNoExamples;has[p;"### Examples"];0]
t[`nonDbQueryNoSchema;  has[p;"### Schema"];0]
/x A question that shares nothing with anything retrieves nothing -- and that
/x is now a RELEVANCE test, not a length test. There used to be an ai.MINQ:15
/x floor on the query's character count, which also blocked every short real
/x question: "vwap by symbol" is 14 characters, and 41 of the 344 questions in
/x data/train.jsonl were in that hole.
t[`shortQueryNoExamples;#ai.exs"2+2";0]
t[`relevantQueryHasExamples;0<#ai.exs"average price of trades";1]
t[`irrelevantQueryNoExamples;#ai.exs"average price by symbol";0]
t[`examplesAreCapped;   ai.NEX<#ai.exs"average price of trades";0]
/x ---- punctuation must not eat the last word ------------------------------
/x ai.norm stripped only `,();`, so a question written as a sentence lost its
/x final token: "Show all AAPL trades." tokenised to "trades." and never
/x matched the keyword `trades`, so ai.dbq called it a non-data question and it
/x got no schema and no exemplars at all.
t[`normStripsFullStop;  *|ai.words"Show all AAPL trades.";"trades"]
t[`normStripsQuestion;  *|ai.words"what is the vwap?";"vwap"]
t[`dbqSeesSentence;     ai.dbq"Show all AAPL trades.";1]
t[`dbqSeesTrailingStop; ai.dbq"Total volume per symbol.";1]
t[`normHandlesAtom;     ai.norm"a";,"a"]
t[`normHandlesEmpty;    ai.norm"";""]
/x ai.ctx keeps the detail the compact schema drops.
t[`statusCtxKeepsRows;  has[ai.ctx[];" rows]"];1]
/x ---- generation rules live in the system prompt -------------------------
t[`sysRule1;           has[ai.SYS;"RULE 1"];1]
t[`sysRule2;           has[ai.SYS;"RULE 2"];1]
t[`sysRule3;           has[ai.SYS;"RULE 3"];1]
t[`sysForbidsAnsi;     has[ai.SYS;"NEVER ANSI SQL"];1]
/x ---- a query is only a db query if it says so ---------------------------
t[`dbqRejectsMath;     ai.dbq"2+2";0]
t[`dbqAcceptsQuery;    ai.dbq"average price by symbol";1]
t[`dbqSeesWorkspace;   ai.dbq"how big is trades";1]
/x ---- time buckets force the WORKING two-step idiom ----------------------
/x "by 300 xbar time" parses and silently returns unbucketed rows, so the
/x forced exemplar derives the bucket column first.
t[`bucketForcesXbar;   has["\n"/ai.exs"average px in 5 minute buckets";"xbar["];1]
t[`bucketIdiomIsTwoStep;has["\n"/ai.exs"average px in 5 minute buckets";"update tb:xbar"];1]
t[`corpusHasNoByXbar;  has["\n"/{x 3}'ai.SEED;"xbar time"];0]
/x ---- records are sanitised on the way in ---------------------------------
t[`sanCollapsesTabs;   ai.san"a\tb   c";"a b c"]
t[`sanDropsControl;    ai.san"a",(`c$7),"b";"ab"]
t[`sanKeepsPlain;      ai.san"select px from trades";"select px from trades"]
t[`sanPassesNonString; ai.san 42;42]
/x ---- wrapping: the border must close, whatever the model sends -----------
/x A line wider than the terminal used to wrap at the EDGE, putting the right
/x border in the middle of the next row. The decisive assertion is the last one:
/x every rendered row is the SAME display width, so the frame cannot tear.
LONG:"this is a very long line that will certainly exceed any sensible wrap width and would previously have torn the right hand border clean off the box"
BLOB:"select avg px by sym from trades_with_an_absurdly_long_identifier_that_has_no_spaces_in_it_at_all"
t[`wrapKeepsShort;     ai.wrap1[20;"short"];,"short"]
t[`wrapSplitsLong;     1<#ai.wrap1[20;LONG];1]
t[`wrapRespectsWidth;  |/20<ai.dw'ai.wrap1[20;LONG];0]
t[`wrapHardBreaksBlob; |/20<ai.dw'ai.wrap1[20;BLOB];0]
t[`wrapKeepsBlankLine; ai.wrap1[20;""];,""]
t[`wrapWidthIsSane;    (24<ai.wrapw[])&ai.wrapw[]<200;1]
/x widths are display COLUMNS: a box character is 3 bytes and 1 column
t[`wrapCountsColumns;  |/10<ai.dw'ai.wrap1[10;"─────────────────────────"];0]
t[`boxRowsAreEqualWidth;1=#?ai.dw'"\n"\ai.box LONG;1]
/x The one that matters: no row may be WIDER THAN THE TERMINAL. Equal-width
/x rows only prove the box is internally consistent -- an unwrapped box is that
/x too, and still tears, because the TERMINAL folds it. Assert the fit.
t[`boxFitsTerminal;    |/(4+ai.wrapw[])<ai.dw'"\n"\ai.box LONG;0]
t[`boxFitsTerminalBlob;|/(4+ai.wrapw[])<ai.dw'"\n"\ai.box BLOB;0]
t[`boxRowsEqualUnicode; 1=#?ai.dw'"\n"\ai.box"héllo wörld ünïcode ──────────────────────────────────────────────────────────────────── done";1]
t[`boxBlobBorderCloses; 1=#?ai.dw'"\n"\ai.box BLOB;1]
/x ---- per-task generation budgets ----------------------------------------
/x One default for every command truncated \ai profile mid-identifier.
t[`profileGetsMostTokens;(ai.NP[]>ai.NW[])&ai.NW[]>ai.NQ[];1]
t[`warmSizesForLongest; ai.nmax[];ai.NP[]]
/x ---- contrastive grounding ------------------------------------------------
/x The model has seen vast amounts of kdb+ and SQL and no Amber, so it needs to
/x be told what NOT to write next to what to write. Both sides of every pair are
/x executed by tests/verify_memory.k; these assert the SELECTION.
t[`contraAlwaysSends;   1<#ai.contra"average price by symbol";1]
t[`contraIsCapped;      ai.CXMAX<#ai.contra"bucket bars attr moving within vwap top cast";0]
t[`contraTriggersXbar;  has["\n"/ai.contra"average px in 5 minute buckets";"xbar"];1]
t[`contraTriggersAttr;  has["\n"/ai.contra"make symbol lookups faster with an attribute";"sortcol"];1]
t[`contraTriggersCast;  has["\n"/ai.contra"cast sz to float";"`f$"];1]
/x English words must not trigger: "average px IN 5 minute buckets" is not a
/x membership question, and "select last px" is not a row limit.
t[`contraNoPrepositionHit;has["\n"/ai.contra"average px in 5 minute buckets";"in[sym"];0]
t[`contraNoLastHit;     has["\n"/ai.contra"select last px by sym";"10#t"];0]
/x a non-data question gets no schema, no examples and no contrasts
t[`contraOffForMath;    has[ai.prompt["T";"2+2"];"not kdb"];0]
t[`contraOnForData;     has[ai.prompt["T";"average price by symbol"];"not kdb"];1]
/x the documented speed knob must still move all of them
t[`budgetsTrackNumPredict;ai.NP[]>ai.np[];1]
/x ---- keeping the model resident -----------------------------------------
/x keep_alive only starts helping after a call the backend FINISHED, and on a
/x 7B the first call is the one that times out -- so \ai warm exists to pay the
/x load on its own budget, asking for a single token.
t[`warmIsRegistered;   0<#&ai.K=`warm;1]
t[`keepAliveDefault;   ai.ka[];"30m"]
t[`numPredictDefault;  ai.np[];128]
/x the budget is sized from a MEASURED rate, never from the model's name
t[`budgetRoundsUp;     ai.budget[16000];25000]
t[`budgetHasHeadroom;  ai.budget[1000]>1000;1]
t[`budgetIsCapped;     ai.budget[999000];120000]
/x ai.bump belongs to the memory ranker; the warm helper must not shadow it
t[`bumpNotShadowed;    ~ai.bump~ai.raisebudget;1]
t[`promptReplaysMemory;has[pq;"select px from trades where px>10"];1]
t[`promptHasTask;      has[p;"Do the thing"];1]
t[`promptHasInput;     has[p;"the question"];1]
t[`emptyBlockIsEmpty;  #ai.blk["h";""];0]
t[`shortTruncates;     #ai.short 500#"x";200]
t[`shortTakesFirstLine;ai.short"one\ntwo";"one"]

/x ==================== 7. the \ai command parser ==========================
t[`word;           ai.word"profile trades";"profile"]
t[`rest;           ai.rest"profile trades";"trades"]
t[`wordNoArg;      ai.word"status";  "status"]
t[`restNoArg;      ai.rest"status";  ""]
t[`restTrimsSpace; ai.rest"why   boom";"boom"]
t[`helpRuns;       #grab[ai.cmd;"help"];#ai.HELP]
t[`helpMentionsProfile;has[say[ai.cmd;"help"];"\\ai profile"];1]
t[`emptyIsHelp;    #grab[ai.cmd;""]; #ai.HELP]
t[`statusRuns;     0<#grab[ai.cmd;"status"];1]
t[`statusShowsModel;has[say[ai.cmd;"status"];"model"];1]
q1:grab[ai.cmd;"off"]
t[`cmdOff;         on[];             0]
q2:grab[ai.cmd;"on"]
t[`cmdOn;          on[];             1]
q3:grab[ai.cmd;"tab off"]
t[`cmdTabOff;      tab[];            0]
q4:grab[ai.cmd;"tab on"]
t[`cmdTabOn;       tab[];            1]
t[`cmdModelQuery;  has[say[ai.cmd;"model"];"test-model"];1]
q5:grab[ai.cmd;"model other-model"]
t[`cmdModelSet;    mdl[];            "other-model"]
t[`cmdUrlQuery;    has[say[ai.cmd;"url"];DEAD];1]
q6:grab[ai.cmd;"timeout 900"]
t[`cmdTimeout;     qms[];            900]
q7:grab[ai.cmd;"tabtimeout 45"]
t[`cmdTabTimeout;  tms[];            45]
tk[`cmdRetry;      "ai.cmd\"retry\""]
/x backend probing: the shell helper must strip the trailing newline every
/x command leaves behind (comparing raw output against "yes" never matched),
/x and \ai serve must be a registered sub-command. Starting a real backend is
/x deliberately NOT exercised here -- this suite never touches the network.
t[`line1Chomps;    ai.line1"yes\n";  "yes"]
/x a one-character result is a char VECTOR here, not the char atom "a"
t[`line1FirstOnly; ai.line1"a\nb\n"; ,"a"]
t[`line1Trims;     ai.line1"  a  \n";,"a"]
t[`line1Empty;     ai.line1"";       ""]
t[`serveRegistered;in[`serve;ai.K];  1]
t[`shReturnsText;  ai.sh"echo probe-ok";"probe-ok"]
t[`shSurvivesJunk; ai.sh"exit 7";     ""]
t[`ollamaIsBoolean;in[ai.ollama[];0 1];1]
t[`ollamaCached;   0<#ai.CACHE;       1]
tk[`cmdMemory;     "ai.cmd\"memory\""]
tk[`cmdLearn;      "ai.cmd\"learn\""]
ai.ERR::""
t[`whyWithNoError; has[say[ai.cmd;"why"];"no recent error"];1]
serr:ai.seterr"'type mismatch"
t[`seterrSticks;   ai.ERR;           "'type mismatch"]
spre:ai.pre"x"
t[`preKeepsLastErr;ai.ERR;           "'type mismatch"]
t[`profileNeedsArg;has[say[ai.cmd;"profile"];"usage"];1]
t[`profileRejectsNonTable;has[say[ai.cmd;"profile vv"];"not a table"];1]
t[`optimizeNeedsArg;has[say[ai.cmd;"optimize"];"usage"];1]
t[`explainNeedsArg;has[say[ai.cmd;"explain"];"usage"];1]
/x the profile REPORT needs no backend, only the advice on top of it does
rep:ai.prof[`trades;trades]
t[`profReportHeader;has[rep;"table trades"];1]
t[`profColumnCount;has[rep;"4 columns"];1]
t[`profRowCount;   has[rep;"4 rows"];1]
t[`profDistinct;   has[rep;"distinct"];1]
t[`profAttribute;  has[rep;"`p"];    1]
/x an unknown sub-command is a question; with no backend it still fails cleanly
t[`unknownIsQuestion;0<#grab[ai.cmd;"how do I bucket by minute"];1]
/x and nothing above may have left the interpreter in a bad state
tk[`stillAlive;    "1+1"]

hexpect[188]
hreport"AMBER AI AGENT"
$[FAILN;`exit 1;]
