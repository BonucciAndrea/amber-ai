/ ============================================================================
/ tests/verify_memory.k  -  every shipped few-shot example must still RUN.
/ ----------------------------------------------------------------------------
/     ./amber tests/verify_memory.k     (from an Amber tree with amber-ai in it)
/ .
/ lib/amber_ai_memory.k is a corpus of Amber expressions replayed to the model
/ as few-shot examples AND offered straight back as Tab candidates. An entry
/ that no longer parses is worse than no entry at all: it teaches the model a
/ wrong idiom and completes the user into an error. So every one of them is
/ executed here, through the SAME qsql.k rewriter repl.k runs your keystrokes
/ through, against a gentq-generated trades/quotes workspace.
/ .
/ Reports "N tests run, M failures" like the other suites, so the runner gates
/ on the same "0 failures" string rather than on an exit code.
/ .
/ NB: a line holding nothing but "/" opens a BLOCK comment in this dialect and
/ swallows the rest of the file -- hence the "/ ." spacer lines above.
/ amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
/ ============================================================================
DIR:{$[#p:"/"/-1_"/"\x;p;"."]}`argv 1
AM:DIR,"/.."
LOAD:{{.[{. x^(`c$13)};,x;{}]}'0:x;}
LOAD AM,"/amber.k"
LOAD AM,"/fin.k"
LOAD AM,"/std.k"
LOAD AM,"/qsql.k"
LOAD AM,"/temporal.k"
LOAD AM,"/sys.k"
S:()
ai.seed:{[k;s;c]S::S,,(k;s;c);}
LOAD AM,"/lib/amber_ai_memory.k"
FIX:{gentq x;}
FIX 2000
/ the bucketing exemplars derive a bucket column first; give them the table
BARS:{bars::. qrw"update tb:xbar[300;time] from trades";}
BARS 0
bad:()
chk:{[r]$[`FAIL~.[{. qrw x};,r 1;`FAIL];bad::bad,,r;0];}
CHK:{chk'x;}
CHK S
SHOW:{{`0:"  FAIL  ",(x 1),"   (",(x 2),")"}'x;}
`0:""
`0:"================ AMBER AI SEED CORPUS ================"
`0:($#S)," tests run, ",($#bad)," failures"
SHOW bad
`0:$[0=#bad;"ALL SEED EXAMPLES RUN CLEANLY";"SOME SEED EXAMPLES FAILED"]
`0:"====================================================="
