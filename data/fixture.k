/ ============================================================================
/ data/fixture.k  -  the deterministic workspace every example in
/ data/train.jsonl is written against, and is re-verified against.
/
/ fin.k's gentq builds a realistic book from a PRNG, which is the right thing
/ for a benchmark and the wrong thing here: a training example that shows an
/ exact REPL result has to produce that result on every machine, on every run,
/ forever. So everything below is a literal.
/
/ Ten trades, twelve quotes, three symbols, inside one morning: small enough
/ that a whole table prints inside a 20-row grid without the ".." truncation,
/ wide enough for grouping, joins, bucketing, as-of joins and the attribute
/ helpers. Column names are the ones the rest of Amber already expects --
/ `time` renders as HH:MM:SS.mmm and `date` as YYYY.MM.DD (amber.k TCOLS and
/ DCOLS), and `sym`/`px`/`sz` are what fin.k's vwap, twap, bars and symstats
/ read off a table.
/
/ ONE DEFINITION PER LINE. An Amber statement is a line: a table literal split
/ across several lines is several statements, and every one of them is a
/ syntax error.
/ ============================================================================

ttime:hms'[9 9 9 10 10 10 11 11 11 11;30 45 55 10 20 40 5 15 30 50;0 0 0 0 0 0 0 0 0 0]
trades:([]sym:`AAPL`MSFT`AAPL`GOOG`MSFT`AAPL`GOOG`MSFT`AAPL`GOOG;time:ttime;px:187.5 411.0 188.25 139.75 410.5 189.0 140.5 412.25 187.75 141.0;sz:100 250 300 150 400 200 350 500 450 250)

qtime:hms'[9 9 10 11 9 10 11 11 10 11 11 11;25 50 35 25 40 15 10 55 5 0 25 45;0 0 0 0 0 0 0 0 0 0 0 0]
quotes:([]sym:`AAPL`AAPL`AAPL`AAPL`MSFT`MSFT`MSFT`MSFT`GOOG`GOOG`GOOG`GOOG;time:qtime;bid:187.48 188.2 188.95 187.7 410.9 410.4 412.15 412.6 139.7 140.45 140.95 141.3;ask:187.52 188.3 189.05 187.8 411.1 410.6 412.35 412.8 139.8 140.55 141.05 141.4;bsz:300 200 400 500 600 300 200 400 100 500 300 200;asz:200 400 300 100 400 500 600 200 300 100 400 500)

/ a plain vector, a float vector, a dictionary, a keyed table and a nested list,
/ for the idiom examples that have nothing to do with market data
v:5 3 9 1 7 2 8
w:1.0 2.0 3.0 4.0 5.0
d:`a`b`c`d!10 20 30 40
kt:([sym:`AAPL`MSFT`GOOG]name:`Apple`Microsoft`Alphabet;lot:100 50 25)
nest:(1 2 3;4 5;6 7 8 9)
