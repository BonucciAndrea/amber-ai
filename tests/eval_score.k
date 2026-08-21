/ ============================================================================
/ tests/eval_score.k  -  score model answers by EXECUTION, not by string match.
/ ----------------------------------------------------------------------------
/     ./amber tests/eval_score.k        (reads data/eval_cases.txt)
/ .
/ Each input line is  id \x01 candidate \x01 reference. Both sides are evaluated
/ against data/fixture.k, through the same qsql.k rewriter repl.k puts a
/ keystroke through, and compared with `~`.
/ .
/ Comparing the TEXT would be close to worthless here: there are many correct
/ spellings of one query. "select v:sum sz by sym from trades" and
/ "select v:sum sz by sym from trades where 1" are the same answer;
/ "select sum sz by sym from trades" differs only in a column name a human would
/ not care about. What a user cares about is whether the line runs and produces
/ the right table, so that is what is scored.
/ .
/ Four outcomes per case:
/     match    it runs and returns exactly what the reference returns
/     differs  it runs and returns something else
/     error    it does not run at all
/     empty    the model returned nothing
/ .
/ NB: a line holding nothing but "/" opens a BLOCK comment in this dialect and
/ swallows the rest of the file -- hence the "/ ." spacer lines above.
/ amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
/ ============================================================================
ev.dir:{$[#p:"/"/-1_"/"\x;p;"."]}`argv 1
ev.am:ev.dir,"/.."
ev.load:{{.[{. x^(`c$13)};,x;{}]}'0:x;}
ev.load ev.am,"/amber.k"
ev.load ev.am,"/fin.k"
ev.load ev.am,"/std.k"
ev.load ev.am,"/qsql.k"
ev.load ev.am,"/temporal.k"
ev.load ev.am,"/sys.k"
COLOR:0
ev.fix:0:ev.am,"/data/fixture.k"
ev.reset:{{.[{. x^(`c$13)};,x;{}]}'ev.fix;}
ev.SEP:(`c$1)
ev.run:{ev.reset[];.[{(1b;. qrw x)};,x;{(0b;x)}]}
ev.one:{[ln]
  f:ev.SEP\ln
  id:f 0
  cand:f 1
  ref:f 2
  $[0=#cand;[`0:id,ev.SEP,"empty";:0];0]
  a:ev.run cand
  $[a 0;;[`0:id,ev.SEP,"error";:0]]
  b:ev.run ref
  $[b 0;;[`0:id,ev.SEP,"refbroken";:0]]
  `0:id,ev.SEP,$[(a 1)~b 1;"match";"differs"];}
ev.each:{[f;l]f'l;}
ev.each[ev.one;0:ev.am,"/data/eval_cases.txt"]
\\
