# `data/` — a fine-tuning corpus for Amber

`train.jsonl` is 1,508 ChatML pairs that teach a model to write **Amber**, not
kdb+/q and not ANSI SQL.

```jsonl
{"messages":[{"role":"user","content":"VWAP by symbol."},
             {"role":"assistant","content":"select vw:wavg[sz;px] by sym from trades"}],
 "meta":{"id":"c00123","category":"nl2qsql","kind":"code","verify":"select vw:wavg[sz;px] by sym from trades"}}
```

`messages` is the standard part; a trainer that reads only `messages` sees a
conforming ChatML file. `meta` is an addition, and it exists so the corpus can
be checked rather than trusted — `verify` holds the exact expression the entry
teaches, so `tests/verify_train.k` can re-execute all of them without trying to
parse code back out of English.

## Every line of code in here has been run

Not proofread — **executed**, against `data/fixture.k`, through the same
`qsql.k` rewriter `repl.k` puts your keystrokes through (`. qrw x`, not `. x`),
so the bare `select … from …` syntax is exercised on the path a real line takes.
`tests/verify_train.k` re-runs all 662 distinct expressions on every
`tests/run_tests.sh`, and the build refuses to emit a dataset containing an
expression that raises.

That is not ceremony. A fine-tuning corpus is not documentation: whatever is in
it is what the model learns to write, and unlike a stale doc example nobody ever
reads it again to notice it stopped parsing. Several entries here changed
because the engine disagreed with the first draft — `by` clauses that hold an
expression, `except` against a bare symbol, `Q.id` on any input at all.

## Categories

| category | n | what it teaches |
|---|---|---|
| `trace` | 474 | an input line and the **exact** grid the REPL prints back |
| `nl2qsql` | 344 | a question in English → one executable expression, no prose, no fences |
| `explain` | 215 | clause-by-clause and right-to-left breakdowns, with every intermediate executed |
| `idiom` | 182 | adverbs, grade, the primitive verbs, moving windows, strings |
| `temporal` | 88 | times, dates, timestamps and bucketing |
| `struct` | 80 | dictionaries, tables, keyed tables, joins, attributes |
| `contrast` | 49 | the kdb+/SQL reflex beside what Amber actually wants |
| `recipe` | 29 | whole small analyses — TAQ match, signed volume, bars |
| `error` | 24 | the broken line, the message it really produces, the fix |
| `gotcha` | 23 | legal, surprising, and worth knowing before it bites |

`kind` says what shape the answer takes: `code` (the bare expression — what
`\ai <question>` hands back to the REPL), `trace`, `prose`, `qsql-explain`,
`steps`, `error`.

## The contrastive entries are the point

A 7B model has seen an enormous amount of kdb+ and essentially no Amber, so a
positive example does not suppress the prior — being told what **not** to write,
beside what to write instead, does. All 49 `contrast` entries and all 24 `error`
entries carry a wrong line that was **also executed**, and each is documented as
what it actually does:

* 35 of them raise. `sym in \`AAPL\`MSFT` is `'type`, `sz>=200` is `'length`,
  `` `s#col `` is `'type`, `px within (180;200)` is `'value`.
* 6 of them **do not raise**, which is the dangerous kind, and each says so:
  * `select … by tb:xbar[1800000;time] from trades` — a `by` clause is a list of
    column *names*, so the whole expression becomes one symbol, no column has
    that name, and every row lands in one degenerate group. One row out, no
    error.
  * `select [5] from trades` — no limit clause; `[5]` is projected as a constant
    and you get one row holding the number 5.
  * `.z.t` — a leading dot is not namespace punctuation in Amber, it is the `.`
    verb, so this evaluates the function object and prints its internals.

## Fixture

`fixture.k` is ten trades, twelve quotes and three symbols, as literals.
`gentq` builds a far better book but builds it from a PRNG, and an entry that
shows an exact result has to produce that result on every machine, on every run.
One definition per line — an Amber statement is a line.

## Reading it from inside Amber

`loader.k` uses the engine's own JSON reader (`\`j?`), so there is no Python step:

```
\l data/loader.k
tr.load "data/train.jsonl"
tr.stats[]
tr.show 0
tr.verify 0
```

## Rebuilding

The corpus is generated, executed and only then written. To re-verify what is
committed:

```bash
tests/run_tests.sh /path/to/amber      # runs verify_train.k among the rest
```

`\`0:` on a **char atom** raises `'type`, `_` is the drop verb and cannot be used
as a throwaway name, and the harness namespaces every variable it owns under
`vt.` — because the lines it runs are real user lines, and several of them bind
globals called `n`, `m`, `b` and `q`.
