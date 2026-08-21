#!/usr/bin/env python3
"""tests/eval_model.py -- does the model actually answer in Amber?

    tests/eval_model.py /path/to/amber [options]

Takes a held-out slice of data/train.jsonl, asks each question through the REAL
`\\ai` path -- so the real prompt assembly, the real retrieval, the real
sanitiser -- and scores every answer BY EXECUTION: it runs the answer and the
dataset's reference expression against data/fixture.k and compares the values.

String comparison would be close to worthless. There are many correct spellings
of one query, and a model that writes `select v:sum sz by sym from trades` when
the reference says `select tot:sum sz by sym from trades` has not made a
mistake worth counting. What matters is whether the line runs and returns the
right table.

Reported per category:
    match     ran, and returned exactly what the reference returns
    differs   ran, returned something else
    error     did not run
    empty     the model said nothing
plus a KDB+ LEAK RATE: the fraction of answers containing an idiom that belongs
to kdb+ or ANSI SQL and does not work here. That number is the one worth
watching -- accuracy can look fine while the model quietly writes `sym in
\\`AAPL\\`MSFT` and `300 xbar time`, which is what the contrastive half of the
corpus exists to stop.

The split is stratified by category and deterministic in --seed, so two runs of
two different models are scored on exactly the same questions.

amber-ai - GNU AGPLv3 - see LICENSE and NOTICE.
"""
import argparse
import collections
import json
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Each pattern is a kdb+ / ANSI-SQL idiom that is NOT valid Amber. Every one of
# them is in data/train.jsonl as a contrastive entry, with the error it really
# raises -- or, for the last three, with the wrong answer it silently returns.
LEAKS = [
    (r"\bin\s+`",                 "infix `in` (Amber: in[x;y])"),
    (r">=|<=",                    "`>=` / `<=` do not exist (Amber: ~x<y)"),
    (r"\bwithin\b",               "`within` does not exist"),
    (r"`[spg]#",                  "`s# / `p# attribute syntax (Amber: sortcol/partcol)"),
    (r"\d+\s+xbar\b",             "infix xbar (Amber: xbar[w;x])"),
    (r"\d+\s+m(avg|sum|dev|min|max)\b", "infix moving window (Amber: mavg[w;x])"),
    (r"\bgroup\s+by\b",           "GROUP BY (Amber: by, before from)"),
    (r"\bas\s+\w+\s*(,|from)",    "SQL `AS` alias (Amber: name:expr)"),
    (r"\border\s+by\b",           "ORDER BY (Amber: xasc / xdesc)"),
    (r"\bhaving\b",               "HAVING"),
    (r"select\s*\[",              "select [n] limit clause"),
    (r"\bwhere\b[^\n]*\bi\s*<",   "the virtual `i` column"),
    (r"\bcount\s+i\b",            "count i"),
    (r"\.[zQjh]\.",               "`.z.` / `.Q.` namespace dots (Amber: z. / Q.)"),
    (r"\bfby\b",                  "fby inside a where clause"),
    (r"\b0N!",                    "0N! print-and-return"),
    (r"`[A-Z]\$",                 "upper-case cast token (Amber: `f$ `i$ `c$)"),
]

SEP = "\x01"


def split(rows, frac, seed, categories):
    """Stratified by category, deterministic in `seed`."""
    by = collections.defaultdict(list)
    for r in rows:
        m = r["meta"]
        if m["kind"] != "code":
            continue
        if categories and m["category"] not in categories:
            continue
        by[m["category"]].append(r)
    held = []
    for cat in sorted(by):
        v = sorted(by[cat], key=lambda r: r["meta"]["id"])
        random.Random("%s/%d" % (cat, seed)).shuffle(v)
        n = max(1, int(round(len(v) * frac)))
        held.extend(v[:n])
    # one question per distinct reference, so an easy expression asked five
    # different ways cannot dominate the score
    seen, out = set(), []
    for r in held:
        c = r["meta"]["verify"]
        if c in seen:
            continue
        seen.add(c)
        out.append(r)
    return out


def ask(amber, cases, url, model, timeout_ms, batch, verbose):
    """Drive the real REPL. One session per batch; a marker line before each
    question, so an answer can be paired with its question without depending on
    the model's output being one line."""
    answers = {}
    env = dict(os.environ)
    env["AMBER_AI_URL"] = url
    if model:
        env["AMBER_AI_MODEL"] = model
    env["AMBER_AI_TIMEOUT_MS"] = str(timeout_ms)
    env.setdefault("HOME", "/tmp")
    env["AMBER_AI_MEMORY"] = "/tmp/.amber_ai_eval_memory.k"
    for f in ("/tmp/.amber_ai_eval_memory.k",):
        if os.path.exists(f):
            os.remove(f)
    for i in range(0, len(cases), batch):
        chunk = cases[i:i + batch]
        src = ["\\ai box off"]
        for r in chunk:
            q = r["messages"][0]["content"].replace("\n", " ")
            src.append('`0:"@@%s@@"' % r["meta"]["id"])
            src.append("\\ai " + q)
        src.append('`0:"@@END@@"')
        src.append("\\\\")
        p = subprocess.run([os.path.join(amber, "a")],
                           input=("\n".join(src) + "\n").encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           env=env, cwd=amber,
                           timeout=max(120, (timeout_ms // 1000 + 5) * len(chunk)))
        out = p.stdout.decode("utf-8", "replace")
        cur, buf = None, []
        for ln in out.split("\n"):
            ln = ln.split("\r")[-1]
            ln = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", ln)
            ln = ln.replace("amber> ", "").strip()
            m = re.match(r"^@@(\w+)@@$", ln)
            if m or ln == "@@END@@":
                if cur:
                    answers[cur] = [x for x in buf if x]
                cur, buf = (m.group(1) if m else None), []
                continue
            if cur is not None:
                buf.append(ln)
        if verbose:
            print("  asked %d/%d" % (min(i + batch, len(cases)), len(cases)),
                  file=sys.stderr)
    return answers


def first_line(lines):
    for l in lines:
        if l and not l.startswith("ai:"):
            return l
    return ""



def selftest(amber):
    """Check the SCORER, which is the part CI can check without a model.

    Four synthetic cases, one per verdict, plus the leak patterns run against
    the wrong-answer lines the corpus itself carries. Without this the harness
    could report 100% on everything and nobody would know.
    """
    cases = [
        ("t_match",   "select v:sum sz by sym from trades",
                      "select v:sum sz by sym from trades", "match"),
        ("t_match2",  "select tot:sum sz by sym from trades",
                      "select tot:sum sz  by sym from trades", "match"),
        ("t_differs", "select v:sum px by sym from trades",
                      "select v:sum sz by sym from trades", "differs"),
        ("t_error",   "select from trades where sym in `AAPL",
                      "select from trades where sym=`AAPL", "error"),
        ("t_empty",   "", "select from trades", "empty"),
        ("t_refbroken", "select from trades", "this is not amber at all $$", "refbroken"),
    ]
    open(os.path.join(amber, "data", "eval_cases.txt"), "w").write(
        "\n".join(SEP.join(c[:3]) for c in cases) + "\n")
    p = subprocess.run([os.path.join(amber, "amber"),
                        os.path.join(amber, "tests", "eval_score.k")],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       cwd=amber, timeout=300)
    got = {}
    for ln in p.stdout.decode("utf-8", "replace").split("\n"):
        if SEP in ln:
            k, v = ln.split(SEP, 1)
            got[k.strip()] = v.strip()
    bad = 0
    for cid, cand, ref, want in cases:
        g = got.get(cid, "missing")
        ok = g == want
        bad += not ok
        print("  %-12s %-10s %s" % (cid, g, "PASS" if ok else "FAIL (want %s)" % want))

    # the leak detector, against lines the corpus documents as wrong
    probes = [
        ("select from trades where sym in `AAPL`MSFT", True),
        ("select from trades where sz>=200",           True),
        ("select from trades where px within (1;2)",   True),
        ("`s#trades`time",                             True),
        ("select sum sz by 300 xbar time from trades", True),
        ("3 mavg trades`px",                           True),
        ("select sum(sz) from trades group by sym",    True),
        ("select [5] from trades",                     True),
        (".z.t",                                       True),
        ("`F$trades`sz",                               True),
        ("select v:sum sz by sym from trades",         False),
        ("select from trades where in[sym;`AAPL`MSFT]", False),
        ("mavg[3;0.0+trades`px]",                      False),
        ("b:update tb:xbar[1800000;time] from trades", False),
        ("select from trades where ~sz<200",           False),
        ("z.t[]",                                      False),
    ]
    for line, want in probes:
        hit = any(re.search(pat, line) for pat, _ in LEAKS)
        ok = hit == want
        bad += not ok
        print("  %-46s %-9s %s" % (line[:46], "leak" if hit else "clean",
                                   "PASS" if ok else "FAIL"))
    print()
    print("%d failures" % bad)
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("amber", nargs="?", default=os.path.join(REPO, "..", "amber"))
    ap.add_argument("--split", type=float, default=0.15)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--url", default=os.environ.get(
        "AMBER_AI_URL", "http://127.0.0.1:11434/api/generate"))
    ap.add_argument("--model", default=os.environ.get("AMBER_AI_MODEL", ""))
    ap.add_argument("--timeout-ms", type=int, default=30000)
    ap.add_argument("--batch", type=int, default=25)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--categories", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--selftest", action="store_true",
                    help="check the scorer and the leak patterns; needs no model")
    a = ap.parse_args()
    amber = os.path.abspath(a.amber)
    if not os.path.isfile(os.path.join(amber, "a")):
        print("error: %s is not a built Amber installation" % amber)
        return 2

    if a.selftest:
        return selftest(amber)

    rows = [json.loads(l) for l in open(os.path.join(REPO, "data", "train.jsonl"))]
    cats = [c for c in a.categories.split(",") if c]
    cases = split(rows, a.split, a.seed, cats)
    if a.limit:
        cases = cases[:a.limit]
    print("held out %d questions (split=%.2f seed=%d) from %d entries"
          % (len(cases), a.split, a.seed, len(rows)))
    print("endpoint %s%s" % (a.url, (" model " + a.model) if a.model else ""))

    answers = ask(amber, cases, a.url, a.model, a.timeout_ms, a.batch, a.verbose)

    # ---- score by execution, in the engine -------------------------------
    lines = []
    for r in cases:
        cand = first_line(answers.get(r["meta"]["id"], []))
        lines.append(SEP.join([r["meta"]["id"], cand, r["meta"]["verify"]]))
    open(os.path.join(amber, "data", "eval_cases.txt"), "w").write(
        "\n".join(lines) + "\n")
    p = subprocess.run([os.path.join(amber, "amber"),
                        os.path.join(amber, "tests", "eval_score.k")],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                       cwd=amber, timeout=1800)
    verdict = {}
    for ln in p.stdout.decode("utf-8", "replace").split("\n"):
        if SEP in ln:
            k, v = ln.split(SEP, 1)
            verdict[k.strip()] = v.strip()

    # ---- report -----------------------------------------------------------
    per = collections.defaultdict(collections.Counter)
    leaks = collections.Counter()
    leaked = []
    for r in cases:
        i, cat = r["meta"]["id"], r["meta"]["category"]
        cand = first_line(answers.get(i, []))
        per[cat][verdict.get(i, "missing")] += 1
        for pat, why in LEAKS:
            if re.search(pat, cand):
                leaks[why] += 1
                leaked.append((i, cand, why))
                break

    tot = collections.Counter()
    for c in per.values():
        tot.update(c)
    n = sum(tot.values())
    print()
    print("%-12s %6s %8s %7s %7s %7s" % ("category", "n", "match", "differs", "error", "empty"))
    for cat in sorted(per):
        c = per[cat]
        m = sum(c.values())
        print("%-12s %6d %7d%% %6d%% %6d%% %6d%%"
              % (cat, m, round(100 * c["match"] / m), round(100 * c["differs"] / m),
                 round(100 * c["error"] / m), round(100 * c["empty"] / m)))
    print("%-12s %6d %7d%% %6d%% %6d%% %6d%%"
          % ("ALL", n, round(100 * tot["match"] / max(1, n)),
             round(100 * tot["differs"] / max(1, n)),
             round(100 * tot["error"] / max(1, n)),
             round(100 * tot["empty"] / max(1, n))))
    runs = tot["match"] + tot["differs"]
    print()
    print("runs at all      : %d/%d (%d%%)" % (runs, n, round(100 * runs / max(1, n))))
    print("kdb+/SQL leak    : %d/%d (%d%%)"
          % (sum(leaks.values()), n, round(100 * sum(leaks.values()) / max(1, n))))
    for why, k in leaks.most_common():
        print("    %-52s %d" % (why, k))
    if a.verbose:
        for i, cand, why in leaked[:20]:
            print("    %s  %-44s  [%s]" % (i, cand[:44], why))
    if tot["refbroken"]:
        print("WARNING: %d reference expressions did not run -- the dataset is "
              "stale for this engine" % tot["refbroken"])

    if a.out:
        json.dump(dict(
            n=n, split=a.split, seed=a.seed, url=a.url, model=a.model,
            totals=dict(tot), per_category={k: dict(v) for k, v in per.items()},
            leaks=dict(leaks),
            cases=[dict(id=r["meta"]["id"], category=r["meta"]["category"],
                        question=r["messages"][0]["content"],
                        reference=r["meta"]["verify"],
                        answer=first_line(answers.get(r["meta"]["id"], [])),
                        verdict=verdict.get(r["meta"]["id"], "missing"))
                   for r in cases]),
            open(a.out, "w"), indent=1)
        print("\nwrote %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
