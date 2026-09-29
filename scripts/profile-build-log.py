#!/usr/bin/env python3
"""Where did a la-docker-compose-tests build spend its playbook time?

Reads a Jenkins console log (plain or .gz, with the timestamper's [ISO-8601Z] prefix) and
prints, for the deploy run and, when TEST_REDEPLOY ran, for the redeploy run separately,
the tasks that took longest. A task's time is from its header to the next header, so with
the default linear strategy it is the wall time every host waited for the slowest one.

    ssh jjenkins 'gzip -c /var/lib/jenkins/jobs/la-docker-compose-tests/builds/427/log' > b427.gz
    scripts/profile-build-log.py b427.gz --top 20

Diff two builds by running it on both. No dependencies.
"""
import argparse
import datetime as dt
import gzip
import re
from collections import defaultdict

TS = re.compile(r"^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?)Z\]\s?")
ANSI = re.compile(r"\x1b\[8m.*?\x1b\[0m|\x1b\[[0-9;]*m")
TASK = re.compile(r"^(?:TASK|RUNNING HANDLER) \[(.+?)\]")
REDEPLOY_MARK = "[redeploy-test] Re-running"
PLAYBOOK_START = "Running playbook against docker_compose"


def parse(path):
    opener = gzip.open if path.endswith(".gz") else open
    phase, last, cur = "deploy", None, None
    tasks, spans = [], defaultdict(lambda: [None, None])
    with opener(path, "rt", errors="replace") as fh:
        for raw in fh:
            line = ANSI.sub("", raw.rstrip("\n"))
            m = TS.match(line)
            if m:
                last = dt.datetime.fromisoformat(m.group(1))
                line = line[m.end():]
            body = line.strip()
            if REDEPLOY_MARK in body and not body.startswith("+"):
                phase = "redeploy"
                spans[phase][0] = last
            if PLAYBOOK_START in body and not body.startswith("+"):
                spans[phase][0] = last
            if last is None:
                continue
            t = TASK.match(body)
            if t:
                if cur:
                    cur[2] = last
                cur = [t.group(1), last, None, phase]
                tasks.append(cur)
            elif body.startswith("PLAY RECAP") and cur:
                cur[2] = last
                spans[cur[3]][1] = last
                cur = None
    return tasks, spans


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("log")
    ap.add_argument("--top", type=int, default=15)
    args = ap.parse_args()
    tasks, spans = parse(args.log)
    for phase in ("deploy", "redeploy"):
        rows = [t for t in tasks if t[3] == phase and t[2]]
        if not rows:
            continue
        agg = defaultdict(float)
        for name, start, end, _ in rows:
            agg[name] += (end - start).total_seconds()
        start, end = spans[phase]
        wall = f"{(end - start).total_seconds() / 60:.1f} min" if start and end else "?"
        print(f"== {phase}: playbook {wall}, {len(rows)} task headers")
        for name, secs in sorted(agg.items(), key=lambda x: -x[1])[: args.top]:
            print(f"{secs / 60:7.1f}  {name}")


if __name__ == "__main__":
    main()
