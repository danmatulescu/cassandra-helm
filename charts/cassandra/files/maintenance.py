"""Scheduled nodetool maintenance, run as a sidecar in each Cassandra pod.

Runs nodetool against the local node (JMX on localhost, shared pod network),
so it needs no kubectl, no RBAC and no remote JMX.

    python3 maintenance.py            scheduler loop (the sidecar's command)
    python3 maintenance.py run TASK   run repair or snapshot once, now
    python3 maintenance.py next       print the next run times of each task

Configuration comes from the environment (set by the chart):
    POD_NAME                       ordinal = suffix after the last "-"
    REPAIR_ENABLED / SNAPSHOT_ENABLED     "true" / "false"
    REPAIR_SCHEDULE / SNAPSHOT_SCHEDULE   5-field cron, UTC
    REPAIR_TIMEOUT / SNAPSHOT_TIMEOUT     seconds
    REPAIR_OFFSET_MINUTES          node N repairs N x this after the schedule
    RETRY_ATTEMPTS / RETRY_DELAY_MINUTES  retries after a failed run, e.g. a
                                   repair refused because a replica is down
"""
import datetime as dt
import os
import socket
import subprocess
import sys
import threading
import time

UTC = dt.timezone.utc


def log(msg):
    print(f"{dt.datetime.now(UTC):%Y-%m-%dT%H:%M:%SZ} {msg}", flush=True)


# ---------------------------------------------------------------- cron

def _field_matches(expr, value, lo, hi):
    for part in expr.split(","):
        step = 1
        if "/" in part:
            part, step_s = part.split("/", 1)
            step = int(step_s)
        if part == "*":
            start, end = lo, hi
        elif "-" in part:
            a, b = part.split("-", 1)
            start, end = int(a), int(b)
        else:
            start = int(part)
            end = hi if step > 1 else start
        if start <= value <= end and (value - start) % step == 0:
            return True
    return False


def cron_matches(expr, t):
    """Standard 5-field cron. Day-of-week 0 and 7 are Sunday. When both
    day-of-month and day-of-week are restricted, either may match."""
    minute, hour, dom, month, dow = expr.split()
    cron_dow = (t.weekday() + 1) % 7  # Python: Monday=0 -> cron: Sunday=0
    dom_ok = _field_matches(dom, t.day, 1, 31)
    dow_ok = _field_matches(dow, cron_dow, 0, 7) or (cron_dow == 0 and _field_matches(dow, 7, 0, 7))
    if dom != "*" and dow != "*":
        day_ok = dom_ok or dow_ok
    else:
        day_ok = dom_ok and dow_ok
    return (_field_matches(minute, t.minute, 0, 59)
            and _field_matches(hour, t.hour, 0, 23)
            and _field_matches(month, t.month, 1, 12)
            and day_ok)


# ---------------------------------------------------------------- tasks

def ordinal():
    return int(os.environ.get("POD_NAME", "x-0").rsplit("-", 1)[-1])


def tasks():
    out = {}
    if os.environ.get("REPAIR_ENABLED") == "true":
        out["repair"] = {
            "schedule": os.environ["REPAIR_SCHEDULE"],
            "offset": dt.timedelta(minutes=ordinal() * int(os.environ.get("REPAIR_OFFSET_MINUTES", "0"))),
            "timeout": int(os.environ.get("REPAIR_TIMEOUT", "21600")),
            "commands": [(["nodetool", "repair", "-full", "-pr"], False)],
        }
    if os.environ.get("SNAPSHOT_ENABLED") == "true":
        out["snapshot"] = {
            "schedule": os.environ["SNAPSHOT_SCHEDULE"],
            "offset": dt.timedelta(0),
            "timeout": int(os.environ.get("SNAPSHOT_TIMEOUT", "3600")),
            "commands": None,  # built at run time (tag depends on the day)
        }
    return out


def commands_for(name, task):
    """List of (command, optional). A failing optional command doesn't fail
    the task."""
    if name == "snapshot":
        tag = f"daily-{dt.datetime.now(UTC):%a}"
        # Replaces last week's snapshot with the same tag; harmless if absent.
        return [(["nodetool", "clearsnapshot", "-t", tag], True),
                (["nodetool", "snapshot", "-t", tag], False)]
    return task["commands"]


JMX_WAIT_SECONDS = 1800


def wait_for_jmx(name):
    """Wait until the local node's JMX port accepts connections, so a task
    that falls due while Cassandra is (re)starting runs late instead of being
    lost."""
    deadline = time.monotonic() + JMX_WAIT_SECONDS
    waited = False
    while True:
        try:
            socket.create_connection(("127.0.0.1", 7199), timeout=5).close()
            if waited:
                log(f"{name}: Cassandra is up")
            return True
        except OSError:
            if time.monotonic() > deadline:
                log(f"{name}: FAILED (Cassandra JMX not reachable for {JMX_WAIT_SECONDS}s)")
                return False
            if not waited:
                log(f"{name}: waiting for Cassandra (JMX on localhost:7199) to come up")
                waited = True
            time.sleep(10)


def run_task(name, task):
    started = time.monotonic()
    log(f"{name}: starting")
    if not wait_for_jmx(name):
        return False
    ok = True
    for cmd, optional in commands_for(name, task):
        remaining = task["timeout"] - (time.monotonic() - started)
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=max(remaining, 1))
        except subprocess.TimeoutExpired:
            log(f"{name}: '{' '.join(cmd)}' still running after {task['timeout']}s; stopped waiting "
                f"(a repair keeps running on the server)")
            return False
        output = (proc.stdout + proc.stderr).strip()
        for line in output.splitlines()[-20:]:
            log(f"{name}:   {line}")
        if proc.returncode != 0 and not optional:
            log(f"{name}: FAILED ('{' '.join(cmd)}' exit {proc.returncode})")
            ok = False
            break
    if ok:
        log(f"{name}: done in {time.monotonic() - started:.0f}s")
    return ok


def run_with_retries(name, task):
    attempts = 1 + int(os.environ.get("RETRY_ATTEMPTS", "0"))
    delay = 60 * int(os.environ.get("RETRY_DELAY_MINUTES", "10"))
    for attempt in range(1, attempts + 1):
        if run_task(name, task):
            return True
        if attempt < attempts:
            log(f"{name}: retry {attempt}/{attempts - 1} in {delay // 60} min")
            time.sleep(delay)
    log(f"{name}: giving up until the next scheduled run")
    return False


def next_runs(task, now, count=3):
    t = now.replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
    found = []
    for _ in range(60 * 24 * 366):  # search up to a year ahead
        if cron_matches(task["schedule"], t - task["offset"]):
            found.append(t)
            if len(found) == count:
                break
        t += dt.timedelta(minutes=1)
    return found


# ---------------------------------------------------------------- main

def scheduler():
    all_tasks = tasks()
    if not all_tasks:
        log("no maintenance tasks enabled; idling")
    now = dt.datetime.now(UTC)
    for name, task in all_tasks.items():
        nxt = next_runs(task, now, 1)
        log(f"{name}: schedule '{task['schedule']}' UTC, offset {task['offset']}, "
            f"next run {nxt[0]:%Y-%m-%d %H:%M} UTC" if nxt else f"{name}: schedule never matches")
    running = {}
    # Don't fire for the minute the sidecar starts in: we may be seconds into
    # it, and the "next run" printed above starts from the next minute.
    last_minute = dt.datetime.now(UTC).replace(second=0, microsecond=0)
    while True:
        now = dt.datetime.now(UTC).replace(second=0, microsecond=0)
        if now != last_minute:
            last_minute = now
            for name, task in all_tasks.items():
                if not cron_matches(task["schedule"], now - task["offset"]):
                    continue
                if name in running and running[name].is_alive():
                    log(f"{name}: due, but the previous run is still going; skipping")
                    continue
                th = threading.Thread(target=run_with_retries, args=(name, task), daemon=True)
                running[name] = th
                th.start()
        time.sleep(60 - dt.datetime.now(UTC).second + 0.5)


def main(argv):
    if len(argv) >= 2 and argv[1] == "next":
        now = dt.datetime.now(UTC)
        for name, task in tasks().items():
            runs = ", ".join(f"{t:%a %Y-%m-%d %H:%M}" for t in next_runs(task, now))
            print(f"{name}: {runs} UTC (offset {task['offset']})")
        return 0
    if len(argv) >= 3 and argv[1] == "run":
        all_tasks = tasks()
        if argv[2] not in all_tasks:
            print(f"unknown or disabled task: {argv[2]} (enabled: {', '.join(all_tasks) or 'none'})")
            return 2
        return 0 if run_task(argv[2], all_tasks[argv[2]]) else 1
    if len(argv) == 1:
        scheduler()
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
