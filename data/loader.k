/ ============================================================================
/ data/loader.k  -  read data/train.jsonl from inside Amber.
/ .
/ The dataset is ChatML JSONL, one JSON object per line, and Amber already has
/ a JSON reader -- sys.k's j.k, which is the `j? primitive -- so nothing here
/ needs a Python step. Load this file, then:
/ .
/     tr.load "data/train.jsonl"      / -> the number of entries read
/     tr.n[]                          / entry count
/     tr.user 0                       / the user turn of entry 0      (string)
/     tr.assistant 0                  / the assistant turn of entry 0 (string)
/     tr.verify 0                     / the expression entry 0 teaches
/     tr.cat 0                        / its category symbol
/     tr.kind 0                       / its answer shape
/     tr.pick `nl2qsql                / the indices of one category
/     tr.stats[]                      / a category -> count dictionary
/     tr.show 0                       / print one entry, both turns
/ .
/ Shape of a line:
/ .
/     {"messages":[{"role":"user","content":...},
/                  {"role":"assistant","content":...}],
/      "meta":{"id":...,"category":...,"kind":...,"verify":...}}
/ .
/ `messages` decodes to a TABLE, not a list of dictionaries: `j? builds a
/ table whenever a JSON array holds objects with identical keys, which every
/ messages array here does. So tr.role/tr.content index a column rather than
/ walking rows, and an entry with a different message count would show up as a
/ different row count rather than as a silently wrong lookup.
/ .
/ The `meta` key is an ADDITION to ChatML, not a replacement for it: a trainer
/ that reads only `messages` sees a conforming file and ignores the rest. It
/ carries `verify` so tests/verify_train.k can re-execute every shipped
/ expression without parsing it back out of English.
/ .
/ NB: a line holding nothing but "/" opens a BLOCK comment in this dialect and
/ swallows the rest of the file -- hence the "/ ." spacer lines above.
/ amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
/ ============================================================================
tr.R:()
tr.K:{[d;s]d[`$s]}                                        / dict lookup by name
tr.load:{[p]tr.R::{`j?x}'0:p;#tr.R}                       / parse every line
tr.n:{#tr.R}
tr.raw:{tr.R x}
tr.msg:{tr.K[tr.R x;"messages"]}                          / the messages TABLE
tr.meta:{tr.K[tr.R x;"meta"]}
tr.content:{[i;j](tr.K[tr.msg i;"content"])j}
tr.role:{[i;j](tr.K[tr.msg i;"role"])j}
tr.user:{tr.content[x;0]}
tr.assistant:{tr.content[x;1]}
tr.id:{`$tr.K[tr.meta x;"id"]}
tr.cat:{`$tr.K[tr.meta x;"category"]}
tr.kind:{`$tr.K[tr.meta x;"kind"]}
tr.verify:{tr.K[tr.meta x;"verify"]}
tr.cats:{tr.cat'!tr.n[]}
tr.pick:{&x=tr.cats[]}                                    / indices of one category
tr.stats:{c:tr.cats[];u:?c;u!{[c;s]+/c=s}[c]'u}
tr.show:{`0:"user      | ",tr.user x;`0:"assistant |";{`0:"  ",x}'"\n"\tr.assistant x;}
