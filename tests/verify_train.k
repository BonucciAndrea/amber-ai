/ ============================================================================
/ tests/verify_train.k  -  every expression data/train.jsonl teaches must RUN.
/ ----------------------------------------------------------------------------
/     ./amber tests/verify_train.k     (from an Amber tree with data/ beside it)
/ .
/ A fine-tuning corpus is not documentation: whatever is in it is what the model
/ learns to write. One entry whose code no longer parses teaches a wrong idiom
/ to every future answer, and unlike a broken doc example nothing ever reads it
/ again to notice. So every distinct expression in the dataset is executed here,
/ against data/fixture.k, through the SAME qsql.k rewriter repl.k runs the
/ user's keystrokes through -- `. qrw x`, not `. x` -- so the bare
/ "select ... from ..." syntax is exercised on the path a real line takes.
/ .
/ The fixture is restored before every case, so an entry that assigns to a
/ global (`b:update ... from trades`) cannot leak into the next one.
/ .
/ Also checked: the ChatML shape itself. Two messages, `user` then `assistant`,
/ both non-empty. A trainer will happily ingest a malformed pair and learn from
/ it, so the file's structure is worth an assertion of its own.
/ .
/ Reports "N tests run, M failures" like the other suites, so the runner gates
/ on the same "0 failures" string rather than on an exit code.
/ .
/ NB: a line holding nothing but "/" opens a BLOCK comment in this dialect and
/ swallows the rest of the file -- hence the "/ ." spacer lines above.
/ amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
/ ============================================================================
vt.dir:{$[#p:"/"/-1_"/"\x;p;"."]}`argv 1
vt.am:vt.dir,"/.."
vt.load:{{.[{. x^(`c$13)};,x;{}]}'0:x;}
vt.load vt.am,"/amber.k"
vt.load vt.am,"/fin.k"
vt.load vt.am,"/std.k"
vt.load vt.am,"/qsql.k"
vt.load vt.am,"/temporal.k"
vt.load vt.am,"/sys.k"
COLOR:0
vt.load vt.am,"/data/loader.k"
/ EVERY name this harness owns is under `vt.`, because the expressions it is
/ about to run are real user lines and several of them bind globals -- `b:`,
/ `m:`, `q:`, and `n:$'trades`sym` among them. A counter called `n` does not
/ survive that, and it does not fail loudly either: it comes back as whatever
/ the last case assigned.
vt.fix:0:vt.am,"/data/fixture.k"
vt.reset:{{.[{. x^(`c$13)};,x;{}]}'vt.fix;}
vt.reset[]
vt.N:tr.load vt.am,"/data/train.jsonl"
`0:"data/train.jsonl: ",($vt.N)," entries"
vt.n:0
vt.bad:()
vt.note:{[msg;c]vt.bad::vt.bad,,msg," <- ",c;}
/ `_` is the drop/floor verb, so it cannot be used as a throwaway name. Wrap
/ each in a lambda whose body ends in `;`, which discards the result instead.
vt.each:{[f;l]f'l;}

/ ---- 1. ChatML shape -------------------------------------------------------
vt.shape:{[i]vt.n::vt.n+1;$[2=#tr.msg i;0;vt.note["not a 2-message pair";tr.verify i]];$[(tr.role[i;0]~"user")&tr.role[i;1]~"assistant";0;vt.note["roles are not user,assistant";tr.verify i]];$[(0<#tr.user i)&0<#tr.assistant i;0;vt.note["an empty turn";tr.verify i]];}
vt.each[vt.shape;!vt.N]

/ ---- 2. every distinct taught expression -----------------------------------
/ Distinct, because the same expression is reached from many phrasings and
/ running it 1500 times would only make the suite slow.
vt.C:?tr.verify'!vt.N
`0:"distinct expressions: ",$#vt.C
vt.run1:{[c]vt.reset[];vt.n::vt.n+1;$[`FAIL~.[{. qrw x};,c;`FAIL];vt.note["does not run";c];0];}
vt.each[vt.run1;vt.C]
vt.reset[]

/ ---- 3. a bare-code answer must BE the expression it is verified against ----
/ For kind `code` the assistant turn is the executable line itself, with no
/ prose and no fences -- that is the shape \ai <question> hands back to the
/ REPL. If the two ever drift apart, the dataset is verifying something the
/ model is not being taught to write.
vt.tight:{[i]vt.n::vt.n+1;$[(tr.kind i)~`code;$[(tr.assistant i)~tr.verify i;0;vt.note["answer differs from the verified expression";tr.verify i]];0];}
vt.each[vt.tight;!vt.N]

`0:($vt.n)," tests run, ",($#vt.bad)," failures"
vt.each[{`0:"  FAIL: ",x};vt.bad]
\\
