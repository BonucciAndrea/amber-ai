/ ============================================================================
/ lib/ai.k  -  amber-ai 2.0.0: the in-REPL AI agent, written in Amber.
/ .
/ Everything the agent DECIDES lives here, in Amber:
/   * schema inspection      what tables / vectors / attributes this session holds
/   * prompt construction    system prompt + schema + few-shot memory + task
/   * live diagnostics       \ai why, read against the actual table definitions
/   * data profiling         \ai profile, \ai optimize
/   * persistent learning    ~/.amber_ai_memory.k, read AND written here
/ .
/ Everything the agent TRANSPORTS lives in C99:
/   * src/net.c    non-blocking POSIX HTTP POST under a hard millisecond budget
/   * src/ai_ext.c the glue: it registers everything below through Amber
/                  1.9.5's extension seam (src/ext.h). No engine file is
/                  patched; deleting <amber>/ext/ removes the agent entirely.
/                    `ai[(system;prompt;timeoutMs;maxTokens)] -> (rc;text)
/                    `aio[...]                                -> switches+status
/                  The line editor (src/ln.c, `rdl) belongs to Amber itself and
/                  is there with or without this package.
/ .
/ Nothing here can throw into the REPL: every entry point is wrapped in .[;;]
/ and an absent or asleep model backend is reported as one friendly sentence.
/ .
/ Loaded whole-file (multi-line definitions are fine), not line-by-line.
/ ============================================================================

ai.VER:"2.0.0"

/ ---- primitives -----------------------------------------------------------
ai.st:{`aio[-1]}
ai.url:{(ai.st[])2}
ai.model:{(ai.st[])3}
ai.ison:{0<(ai.st[])0}
ai.istab:{0<(ai.st[])1}
ai.qams:{(ai.st[])4}
ai.tabms:{(ai.st[])5}
ai.lastms:{(ai.st[])6}
ai.accepted:{`aio[5]}
ai.o:{`1:x;}
ai.say:{`1:x,"\n";}

/ ---- environment ----------------------------------------------------------
/ Trapped call with the rich stderr diagnostic suppressed: the agent probes
/ things that are ALLOWED to be absent (an env var, a memory file that does not
/ exist yet, a global whose attribute cannot be read), and a caught probe must
/ not paint an error report across the user's screen. `diag returns the
/ previous setting, so nesting is safe.
ai.try:{[f;a;d]p:`diag 0;r:.[f;,a;d];`diag p;r}

ai.envd:{`env(::)}
ai.env:{[k;d]e:ai.envd[];$[in[k;!e];e k;d]}
ai.home:{ai.env[`$"HOME";"."]}
/ ai.MEMF, when non-empty, overrides both the env var and the default path.
/ tests/test_ai.k uses it so a test run never touches the developer's own
/ ~/.amber_ai_memory.k, and it is equally handy for per-project memories.
ai.MEMF:""
ai.memf:{$[0<#ai.MEMF;ai.MEMF;ai.env[`$"AMBER_AI_MEMORY";ai.home[],"/.amber_ai_memory.k"]]}
ai.now:{_`t[]%1000000}

/ ============================================================================
/ 1. PERSISTENT MEMORY   ("in-session and cross-session RAG")
/ ============================================================================
/ A local model cannot be fine-tuned while you type, so "learning" here means
/ PERSISTENT FEW-SHOT CONTEXT. Every line that ran cleanly, every schema this
/ workspace has held and every accepted Tab suggestion is appended to
/     ~/.amber_ai_memory.k
/ as one self-describing K expression per line:
/     ai.rec["q";1755512345;3;"select sym,px from trades";"trades quotes"]
/             kind  epoch-s  hits  text                    context
/ kinds:  q a line that ran cleanly       s a schema seen in this workspace
/         a an accepted Tab completion    p a question asked through \ai
/ Loading the file is simply evaluating it, so it stays human-readable and
/ hand-editable. src/ln.c reads the same lines to offer them straight back as
/ instant, network-free Tab candidates -- which is what makes the REPL feel
/ like it has learned this user's table names and query habits.

ai.M:()
ai.DIRTY:0
ai.MAX:400

ai.rec:{[k;t;h;s;c]ai.M::ai.M,,(k;t;h;s;c);}

ai.readf:{{.[{. x};,x;{}]}'0:ai.memf[]}
ai.load:{ai.M::();ai.try[ai.readf;0;0];#ai.M}

ai.line:{"ai.rec[",(`k[x 0]),";",($x 1),";",($x 2),";",(`k[x 3]),";",(`k[x 4]),"]"}
ai.head:("/ Amber AI persistent memory -- written by lib/ai.k. Safe to delete.";"/ ai.rec[kind;epochSeconds;hits;text;context]")
ai.dump:{("\n"/ai.head,ai.line'ai.M),"\n"}
ai.writef:{(ai.memf[])1:ai.dump[]}
ai.save:{$[0=#ai.M;:0;0];ai.try[ai.writef;0;0];ai.DIRTY::0;#ai.M}
ai.flush:{$[ai.DIRTY;ai.save[];0]}

ai.same:{[k;s;r]$[(r 0)~k;(r 3)~s;0]}
ai.hit:{[k;s]$[0=#ai.M;();&ai.same[k;s]'ai.M]}
ai.bump:{[j;c]r:ai.M j;ai.M::(j#ai.M),(,(r 0;ai.now[];1+r 2;r 3;c)),(j+1)_ai.M;}
ai.trim:{$[ai.MAX<#ai.M;ai.M::(-ai.MAX)#ai.M;0]}
ai.add:{[k;s;c]
  $[0=#s;:0;]
  $[~`C~@s;:0;]
  i:ai.hit[k;s]
  $[#i;ai.bump[i 0;c];ai.M::ai.M,,(k;ai.now[];1;s;c)]
  ai.trim[]
  ai.DIRTY::1
  1}

ai.clearf:{(ai.memf[])1:"/ Amber AI persistent memory -- cleared\n"}
ai.forget:{ai.M::();ai.try[ai.clearf;0;0];ai.DIRTY::0;1}

/ ---- the shipped seed corpus (read-only) ----------------------------------
/ lib/amber_ai_memory.k holds a few hundred verified Amber expressions so that a
/ FIRST session already has good few-shot examples. It is loaded into ai.SEED,
/ NOT into ai.M, and the separation is the whole point: \ai forget clears what
/ you taught it and leaves the corpus; ai.save never writes the corpus back into
/ your personal memory file; and ai.MAX trimming can only ever evict your own
/ records. repl.k's `dir` is the Amber root, which is where install.sh puts it.
ai.SEED:()
ai.SEEDF:""
ai.seed:{[k;s;c]ai.SEED::ai.SEED,,(k;0;1;s;c);}
ai.seedf:{$[0<#ai.SEEDF;ai.SEEDF;ai.env[`$"AMBER_AI_SEED";ai.try[{dir,"/lib/amber_ai_memory.k"};0;""]]]}
ai.loadseed:{ai.SEED::()
  $[0=#f:ai.seedf[];:0;0]
  ai.try[{{.[{. x};,x;{}]}'0:x};f;0]
  #ai.SEED}

/ ---- relevance ranking (the retrieval half of the loop) -------------------
ai.norm:{lower ssr[ssr[ssr[ssr[x;",";" "];"(";" "];")";" "];";";" "]}
ai.words:{w@&0<#'w:" "\ai.norm x}
/ Retrieval matches a SET of kinds (a char vector such as "qap"), because what
/ makes a good few-shot example is anything the user actually ran or accepted --
/ not only records of the same command that is being run now.
/x "q" is a char ATOM in this dialect, not a one-element vector, so a kind set
/x has to be normalised before it can be searched.
ai.cv:{$[`c~@x;,x;x]}
ai.kmatch:{[ks;r]k:ai.cv ks;$[0=#k;1;in[*ai.cv r 0;k]]}
ai.score:{[qw;r](+/in[ai.words[r 3];qw])+0.5*r 2}
ai.top:{[q;n;k]
  a:ai.M,ai.SEED
  $[0=#a;:();0]
  m:a@&ai.kmatch[k]'a
  $[0=#m;:();0]
  s:ai.score[ai.words q]'m
  {x 3}'m@(n&#m)#idesc s}

/ ============================================================================
/ 2. SCHEMA INSPECTION
/ ============================================================================
/ Which globals belong to the USER? Everything that was not already defined
/ when lib/ai.k finished loading. That is exact, needs no denylist, and keeps
/ working as amber.k / fin.k / std.k grow.
ai.BASE:()
ai.globals:{!. 0#`}
ai.user:{n@&~in[n:ai.globals[];ai.BASE,`x`dir]}

ai.attr:{a:ai.try[{`at x};x;`];$[`~a;"";"`",$a]}
ai.cdesc:{[u;c]v:u c;($c),":",($@v),ai.attr v}
ai.tdesc:{[n;t]u:+unkey t;($n),":table(",(" "/ai.cdesc[u]'!u),")[",($#unkey t)," rows]"}
ai.ddesc:{[n;v]($n),":dict(",(" "/$'!v),")"}
ai.vdesc:{[n;v]($n),":",($@v),$[in[@v;`A`B`G`H`I`L`F`C`S`E];"[",($#v),"]";""]}
ai.ndesc:{[n]v:. n;$[in[@v;`M`m];$[istable v;ai.tdesc[n;v];ai.ddesc[n;v]];ai.vdesc[n;v]]}
ai.ndesc0:{ai.try[ai.ndesc;x;($x),":?"]}
ai.ctx:{u:ai.user[];$[0=#u;"(no user data in this session yet)";" "/ai.ndesc0'u]}
ai.ctxnames:{u:ai.user[];$[0=#u;"";" "/$'u]}

/ Remember the SHAPE of the workspace across sessions, so a brand-new REPL
/ still knows what this user's `trades` normally looks like.
ai.learnschema:{{ai.add["s";ai.ndesc0 x;$x]}'ai.user[];#ai.M}

/ ============================================================================
/ 3. PROMPTING
/ ============================================================================
ai.SYS:"You are the assistant built into Amber, a zero-dependency columnar time-series engine whose language is a K/q dialect very close to kdb+/q. Answer for THIS session using the schema you are given. Prefer vector and columnar idioms (select ... from ... where ..., aj, wj, sums, msum, movavg, peach) over loops. Attributes are `s sorted, `u unique, `p parted, `g grouped. Be concise: code first, then at most three short lines of explanation. Never invent table or column names that are not in the schema."

/ Kinds worth replaying as few-shot examples: q lines that ran cleanly,
/ a accepted Tab suggestions, p questions previously asked.
ai.RK:"qap"
ai.blk:{[h;b]$[0=#b;();(,"### ",h),$[`C~@b;,b;b]]}
ai.parts:{[task;q](ai.blk["Session schema";ai.ctx[]];ai.blk["Recent lines and examples from this user";ai.top[q;4;ai.RK]];ai.blk["Task";task];ai.blk["Input";q])}
ai.prompt:{[task;q]"\n"/,/ai.parts[task;q]}

/ Records stay one short line: they are replayed as few-shot examples AND
/ offered as Tab candidates, so a whole profile report has no business in one.
ai.short:{s:*"\n"\x;$[200<#s;200#s;s]}
ai.nl:{$[0=#x;"\n";$["\n"~*|x;"";"\n"]]}

/ ============================================================================
/ 3b. RESPONSE SANITISER  +  BOXED RENDERING
/ ============================================================================
/ A local instruct model has been trained on chat markdown, so it wraps code in
/ ```fences``` and hangs a prose comment off the end of the line no matter how
/ firmly the system prompt asks for bare code. Both are noise here: the whole
/ point of this agent is that the answer can be retyped -- or Tab-accepted --
/ straight into the REPL. So the reply is cleaned first and framed second.
/ .
/ What is deliberately NOT stripped: a lone backtick. In this dialect a backtick
/ OPENS A SYMBOL LITERAL -- `sym, `trades, `s# -- so removing backticks would
/ quietly corrupt the very code this is meant to hand back. Only ``` fences go.

/ display width, not byte count. A UTF-8 continuation byte (10xxxxxx) is part of
/ the previous character and occupies no column; with -fsigned-char those bytes
/ are exactly the ints below -64. Without this every box containing a non-ASCII
/ character comes out ragged, because #"─" is 3, not 1.
ai.dw:{+/~(`i$x)<-64}
ai.rep:{[s;n]$[0<n;`c$,/n#,s;""]}

/ ---- sanitiser -------------------------------------------------------------
ai.isfence:{$[3>#t:trim x;0;"```"~3#t]}
ai.defence:{$[0=#x;x;x@&~ai.isfence'x]}

/ Strip a trailing ` / comment`, but only where the language itself would treat
/ it as one: after whitespace and OUTSIDE a string literal. Tracking quote parity
/ is what stops `select from t where s like "a / b"` losing half its predicate.
ai.uncomment:{[l]
  $[2>#l;:l;0]
  c:"\""=l
  b:(2!+\c)-c                       / quote parity BEFORE each position
  n:1_l,," "                        / the next character, aligned
  i:&(0=b)&(" "=l)&"/"=n
  $[0=#i;l;rtrim(*i)#l]}

ai.clean:{[t]
  ls:ai.defence("\n"\(ai.cv t))
  ls:ai.uncomment'ls
  ls:$[0=#ls;ls;ls@&|\0<#'ls]       / drop LEADING blank lines only
  $[0=#ls;"";"\n"/ls]}

/ ---- boxed rendering -------------------------------------------------------
/ ai.BOX 0 turns this off for anyone piping the REPL into another program; the
/ frame is for humans, and \ai box off is one command away.
ai.BOX:1
ai.BX:("┌";"┐";"└";"┘";"─";"│")
ai.trail:{$[0=#x;x;$[|/0<#'x;x@!1+|/&0<#'x;0#x]]}
ai.bxrow:{[w;l](ai.BX 5)," ",l,(ai.rep[" ";w-ai.dw l])," ",ai.BX 5}
ai.box:{[t]
  ls:ai.trail("\n"\(ai.cv t))
  $[0=#ls;:t;0]
  w:|/ai.dw'ls
  h:ai.rep[ai.BX 4;w+2]
  "\n"/((,(ai.BX 0),h,ai.BX 1),ai.bxrow[w]'ls),,(ai.BX 2),h,ai.BX 3}

/ Every model-generated response funnels through here: \ai, \ai why, \ai explain,
/ \ai profile and \ai optimize all end in ai.emit.
ai.emit:{t:ai.clean x;$[ai.BOX;t:ai.box t;0];ai.o[t,ai.nl t];}

ai.ask:{[task;q;k;tmo;mx]
  $[ai.ison[];;[ai.say"ai: the agent is switched off. Turn it back on with:  \\ai on";:0]]
  r:`ai[(ai.SYS;ai.prompt[task;q];tmo;mx)]
  $[0=r 0;;:ai.diag r]
  ai.emit r 1
  ai.add[k;ai.short q;ai.ctxnames[]]
  ai.flush[]
  1}

/x ---- backend probing ------------------------------------------------------
/x Only ever reached on the FAILURE path, and the "is ollama installed" answer
/x is cached for the session, so the common case costs nothing. Knowing which
/x of the two situations you are in -- not installed at all, versus installed
/x but not listening -- is the whole difference between a useful message and a
/x shrug, and it is one fork to find out.
ai.CACHE:""
/x First line of the command's output, trimmed. amber.k's rtrim strips spaces
/x but NOT the trailing newline every shell leaves behind, so comparing the raw
/x result against "yes" silently never matched.
ai.line1:{$[0=#x;"";trim(*"\n"\x)]}
ai.sh:{ai.line1 ai.try[{`c$`x(("/bin/sh";"-c";x);"")};x;""]}
ai.ollama:{$[#ai.CACHE;;ai.CACHE::ai.sh"command -v ollama >/dev/null 2>&1 && echo yes || echo no"];"yes"~ai.CACHE}
ai.svc:{ai.sh"systemctl is-active ollama 2>/dev/null || echo none"}

ai.hintMissing:{ai.say"    ollama does not look installed. One-time setup, from the amber-ai folder:"
  ai.say"      bash setup-ollama.sh      installs ollama, pulls the model, verifies"
  ai.say"    or by hand:  curl -fsSL https://ollama.com/install.sh | sh   (macOS: brew install ollama)"
  ai.say"    see amber-ai/INSTALL.md for WSL2 / macOS / Linux step-by-step"
  0}
ai.hintService:{ai.say"    ollama IS installed, but nothing is answering on that endpoint."
  $[(ai.svc[])~"active";ai.say"    the ollama service reports active -- check the port in AMBER_AI_URL.";ai.hintStart[]]
  0}
ai.hintStart:{ai.say"    start it with EITHER of:"
  ai.say"      sudo systemctl enable --now ollama    once, and it starts at boot from then on"
  ai.say"      \\ai serve                             just for this session"
  0}
ai.hintConn:{$[ai.ollama[];ai.hintService[];ai.hintMissing[]];ai.say"    then:  \\ai retry";0}

/x \ai serve : start the backend from inside the REPL. For hosts without
/x systemd (WSL without it, containers, macOS) where nothing starts it for you.
ai.doserve:{$[ai.ollama[];;[ai.say"ai: ollama is not installed -- run  bash setup-ollama.sh  (amber-ai) first";:0]]
  ai.say"ai: starting ollama in the background ..."
  ai.sh"(command -v setsid >/dev/null 2>&1 && setsid ollama serve || ollama serve) >/dev/null 2>&1 </dev/null & sleep 2"
  `aio[4]
  r:`ai[("";"ping";1500;1)]
  $[0=r 0;ai.say"ai: backend is up.";ai.say"ai: still not answering -- try  ollama serve  in another terminal to see why."]
  1}

ai.diag:{s:ai.st[]
  ai.say"ai: ",x 1
  ai.say"    endpoint : ",s 2
  ai.say"    model    : ",s 3
  $[3=x 0;ai.hintConn[];0]
  $[4=x 0;ai.say"    raise the budget with:  \\ai timeout 30000";0]
  0}

/ ============================================================================
/ 4. THE \ai COMMANDS
/ ============================================================================
ai.T.q:"Write Amber (K/q) code that answers the question. Give the expression first, then at most three short lines of explanation."
ai.T.e:"Explain this Amber/K expression step by step, innermost first, in plain English. Say what each verb and adverb does and what the result looks like. Do not rewrite it unless it is wrong."
ai.T.w:"Diagnose this Amber error against the session schema above. State the most likely cause in one sentence, then give the corrected expression. Watch for type mismatches, `s and `p attribute assumptions, join-key mismatches, rank errors, and list/atom confusion."
ai.T.f:"Given this profile of one table, recommend concrete vector-performance changes: which columns want `s `u `p or `g, which lookups then become O(1) or O(log n), what is worth pre-aggregating, and what to avoid. Be specific and short."
ai.T.o:"Rewrite this Amber/K query to run faster on the schema above. Give the rewritten query first. Then list, in at most four bullets, the vector reasons: attribute flags that turn a scan into a binary search or an O(1) slice, redundant passes that fuse, joins that should be as-of (aj) or window (wj), and aggregations worth precomputing."

ai.q:{ai.ask[ai.T.q;x;"p";ai.qams[];0]}
ai.explain:{$[0=#x;[ai.say"usage: \\ai explain <expression>";:0];0];ai.ask[ai.T.e;x;"e";ai.qams[];0]}

ai.why:{e:$[0<#x;x;ai.ERR]
  $[0=#e;[ai.say"ai: no recent error to explain. Run the failing expression first, or use  \\ai why <error text>";:0];0]
  ai.ask[ai.T.w;e;"w";ai.qams[];0]}

ai.pcol:{[u;rows;c]w:u c
  a:ai.attr w
  "  ",(14$$c),(5$$@w),(12$$rows)," distinct ",(10$$#?w),"  attr ",$[0=#a;"-";a]}
ai.prof:{[n;v]u:+unkey v
  h:"table ",($n),"   ",($#!u)," columns   ",($#unkey v)," rows\n"
  h,("\n"/ai.pcol[u;#unkey v]'!u),"\n"}
ai.profile:{$[0=#x;[ai.say"usage: \\ai profile <table>";:0];0]
  n:`$trim x
  v:ai.try[{. x};n;()]
  $[in[@v;`M`m];;[ai.say"ai: ",($n)," is not a table or dict in this session.";:0]]
  rep:ai.try[ai.prof[n];v;"(could not profile this value)\n"]
  ai.o rep
  ai.ask[ai.T.f;rep;"f";ai.qams[];0]}

ai.optimize:{$[0=#x;[ai.say"usage: \\ai optimize <query>";:0];0];ai.ask[ai.T.o;x;"o";ai.qams[];0]}

/ ---- session hooks (called from repl.k) -----------------------------------
/ ai.ERR is STICKY -- it survives until the next failing line, so \ai why can
/ still see it on the line after the failure. ai.LERR is the per-line flag that
/ decides whether the line just typed is worth remembering.
ai.ERR:""
ai.LERR:0
/ .[f;a;h] hands the handler the WHOLE rendered error -- tag, offending source
/ line and caret -- as a char vector, which is exactly what makes \ai why able
/ to say something specific rather than just repeating "'type".
ai.seterr:{ai.ERR::$[`C~@x;x;$x];ai.LERR::1;}
ai.pre:{ai.LERR::0;}
ai.post:{
  $[(0=ai.LERR)&(0<#x)&~"\\"~*x;ai.add["q";ai.short trim x;ai.ctxnames[]];0]
  a:ai.try[ai.accepted;0;""]
  $[0<#a;ai.add["a";a;ai.ctxnames[]];0]
  ai.flush[];}

/ ---- status / switches ----------------------------------------------------
ai.onoff:{$[0<x;"on";"off"]}
ai.plural:{[n;w]$[1=n;w;w,"s"]}
ai.status:{s:ai.st[]
  ai.say"Amber AI agent v",ai.VER
  ai.say"  agent      : ",ai.onoff s 0
  ai.say"  tab assist : ",ai.onoff s 1
  ai.say"  endpoint   : ",s 2
  ai.say"  model      : ",s 3
  ai.say"  budgets    : ",($s 4),"ms answer, ",($s 5),"ms tab   (last call ",($s 6),"ms)"
  ai.say"  boxed out  : ",$[ai.BOX;"on";"off"]
  ai.say"  memory     : ",($#ai.M),ai.plural[#ai.M;" record"]," in ",ai.memf[]
  ai.say"  seed corpus: ",($#ai.SEED),ai.plural[#ai.SEED;" example"],$[0=#ai.SEED;" (lib/amber_ai_memory.k not found)";" shipped"]
  ai.say"  workspace  : ",ai.ctx[]
  1}

ai.mrow:{ai.say"  ",(2$x 0)," hits ",(4$$x 2),"  ",70$ssr[x 3;"\n";" "]}
ai.memshow:{ai.say"memory: ",($#ai.M),ai.plural[#ai.M;" record"]," in ",ai.memf[],"  +",($#ai.SEED)," shipped example",$[1=#ai.SEED;"";"s"]
  $[0=#ai.M;:1;0]
  ai.mrow'(10&#ai.M)#|ai.M
  1}

/ Help is accumulated one short line at a time: a parenthesised list may not
/ span newlines in this dialect, and a single string literal long enough to
/ hold the whole page would run past the lexer's literal limit.
ai.HELP:()
ai.hl:{ai.HELP::ai.HELP,,x;}
ai.hl"Amber AI agent -- \\ai commands"
ai.hl""
ai.hl"  \\ai <question>        schema-aware code generation for THIS session"
ai.hl"  \\ai explain <expr>    translate a terse K expression into plain steps"
ai.hl"  \\ai why [error]       diagnose the last (or a given) error"
ai.hl"  \\ai profile <table>   rows, column types, attributes, distinct + advice"
ai.hl"  \\ai optimize <query>  faster vector paths for a query"
ai.hl""
ai.hl"  \\ai on | off          master switch (default ON)"
ai.hl"  \\ai tab on | tab off  inline Tab suggestions (default ON)"
ai.hl"  \\ai status            endpoint, model, budgets, memory, workspace"
ai.hl"  \\ai box [on|off]      frame answers in a box (off when piping output)"
ai.hl"  \\ai memory            what the agent has learned so far"
ai.hl"  \\ai learn             record the current schema into memory"
ai.hl"  \\ai forget            erase the persistent memory file"
ai.hl"  \\ai model <name>      switch model for this session"
ai.hl"  \\ai url <endpoint>    switch endpoint for this session"
ai.hl"  \\ai timeout <ms>      answer budget   (\\ai tabtimeout <ms> for Tab)"
ai.hl"  \\ai retry             forget a dead endpoint and try it again now"
ai.hl"  \\ai serve             start a local ollama in the background (no systemd)"
ai.hl""
ai.hl"  Tab completes globals, table columns, REPL commands and your own past"
ai.hl"  lines instantly. Only when nothing matches does it ask the model, inside"
ai.hl"  a hard millisecond budget, and it shows the idea as dim ghost text that a"
ai.hl"  second Tab (or the Right arrow) accepts. Nothing is inserted for you."
ai.hl""
ai.hl"  Backend:  ollama serve   &   ollama run qwen2.5-coder:0.5b"
ai.hl"  Env:      AMBER_AI AMBER_AI_TAB AMBER_AI_URL AMBER_AI_MODEL"
ai.hl"            AMBER_AI_TIMEOUT_MS AMBER_AI_TAB_MS AMBER_AI_MEMORY"
ai.help:{ai.say'ai.HELP;1}

ai.word:{$[#i:&x=" ";(*i)#x;x]}
ai.rest:{$[#i:&x=" ";ltrim(1+*i)_x;""]}

ai.tab:{$[x~"on";[`aio[3];ai.say"ai: tab assist on";1];x~"off";[`aio[2];ai.say"ai: tab assist off";1];[ai.say"ai: tab assist is ",ai.onoff (ai.st[])1;1]]}
ai.setmodel:{$[0=#x;[ai.say"model: ",ai.model[];1];[`aio[(1;x)];ai.say"ai: model -> ",ai.model[];1]]}
ai.seturl:{$[0=#x;[ai.say"url: ",ai.url[];1];[`aio[(0;x)];ai.say"ai: endpoint -> ",ai.url[];1]]}
ai.settmo:{$[0=#x;[ai.say"timeout: ",($ai.qams[]),"ms";1];[`aio[(2;`i$. x)];ai.say"ai: answer budget -> ",($ai.qams[]),"ms";1]]}
ai.settab:{$[0=#x;[ai.say"tab timeout: ",($ai.tabms[]),"ms";1];[`aio[(3;`i$. x)];ai.say"ai: tab budget -> ",($ai.tabms[]),"ms";1]]}
ai.dolearn:{ai.learnschema[];ai.save[];ai.say"ai: learned ",($#ai.user[])," workspace names";1}

/ Sub-commands dispatch through a symbol->function dictionary rather than a
/ long $[...] chain: a bracketed conditional may not span newlines in this
/ dialect, and a single-line chain of seventeen branches is unreadable.
/ Every handler takes the rest of the line as its one argument.
ai.c.help:{x;ai.help[]}
ai.c.status:{x;ai.status[]}
ai.c.on:{x;`aio[1];ai.say"ai: agent on";1}
ai.c.off:{x;`aio[0];ai.say"ai: agent off";1}
ai.c.retry:{x;`aio[4];ai.say"ai: the endpoint will be retried on the next call";1}
ai.c.box:{a:trim x
  $[0=#a;;ai.BOX::~"off"~lower a]
  ai.say"ai: boxed output ",$[ai.BOX;"on";"off"]
  1}
ai.c.memory:{x;ai.memshow[]}
ai.c.forget:{x;ai.forget[];ai.say"ai: memory cleared";1}
ai.c.learn:{x;ai.dolearn[]}
ai.c.serve:{x;ai.doserve[]}

ai.K:`help`status`on`off`retry`serve`tab`box`memory`forget`learn`model`url`timeout`tabtimeout`explain`why`profile`optimize
ai.V:(ai.c.help;ai.c.status;ai.c.on;ai.c.off;ai.c.retry;ai.c.serve;ai.tab;ai.c.box;ai.c.memory;ai.c.forget;ai.c.learn;ai.setmodel;ai.seturl;ai.settmo;ai.settab;ai.explain;ai.why;ai.profile;ai.optimize)
ai.D:ai.K!ai.V

/ \ai <rest of line>.  Anything that is not a known sub-command is a question.
ai.cmd:{[s0]s:trim s0;$[0=#s;:ai.help[];0];w:`$ai.word s;$[in[w;ai.K];(ai.D w)ai.rest s;ai.q s]}

/ ============================================================================
/ EXTENSION HOOKS  (Amber 1.9.5: src/ext.h + repl.k)
/ ============================================================================
/ repl.k calls these through `exthook`, which traps them and suppresses the
/ rich diagnostic, so every one is optional and none can break the REPL. They
/ are thin aliases on purpose: all behaviour stays above, and a future Amber
/ that renames a hook needs a change only in this block.
/   ext.pre   before each line runs -- clears the "an error happened" flag
/   ext.post  after each line runs  -- records a clean line into memory
/   ext.err   on a REPL error       -- captures it so \ai why can diagnose it
/   ext.raw   1 = hand this line to the command verbatim, WITHOUT the qSQL
/             rewrite, so  \ai optimize select px from t  reaches the agent as
/             the user typed it rather than as already-rewritten K
/   ext.tag   a short suffix for the banner; the "[amber-ai x.y.z]" part comes
/             from C (am_ext_banner), so this only reports live state
ext.pre:{ai.pre x}
ext.post:{ai.post x}
ext.err:{ai.seterr x}
ext.raw:{(2<#x)&"\\ai"~3#x}
ext.tag:{x;$[ai.ison[];"";" (agent off)"]}

/ ---- boot -----------------------------------------------------------------
ai.BASE::ai.globals[]
ai.try[ai.load;0;0];
ai.try[ai.loadseed;0;0];
/ ai.BASE is the "everything that was already here" snapshot that ai.ctx[]
/ subtracts, so it MUST be taken after the ext.* hooks above are defined --
/ otherwise the agent would describe its own plumbing to the model as if it
/ were the user's data.
