#!/usr/bin/env python3
"""Measures Reachly AI runs from Reachly's own agent audit log, not a stopwatch.

Reachly writes one audit record for every command or file action the AI asks for: the host, the command, when, what
was decided (auto-allowed, approved, edited, denied, blocked, cancelled, changes requested), the exit status and how
long it ran. This prints, for each conversation: start, end, elapsed time, the commands, the hosts touched and the
count of each decision.

It reads either of the two places the log lives:
  Reachly.store  the app's database, in its data folder. The default is ~/Library/Application Support/Reachly/
                 (or $REACHLY_DATA_DIR when set). It is read from a copy, so it is safe while Reachly runs.
  a .json file   an export: AI History > Export JSON..., or Settings > AI Integration > Export JSON...

Usage:
  measure.py                       the default store
  measure.py PATH                  a store, a data folder holding one, or an exported .json
  measure.py PATH --last           only the newest conversation
  measure.py PATH --conversation D93940FB    only conversations whose id starts with this
  measure.py PATH --json           the same numbers as JSON

Python 3.9 or later (the one macOS ships), standard library only.
"""
import argparse
import datetime as dt
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import uuid
from collections import Counter

# Every decision Reachly records (AgentAuditDecision in Sources/ReachlyCore/Models/AgentAuditEntry.swift).
DECISIONS = ["auto-allowed", "approved", "edited", "denied", "blocked", "cancelled", "changes-requested"]
RAN = {"auto-allowed", "approved", "edited"}
# SwiftData (Core Data) stores dates as seconds since 2001-01-01 UTC.
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)


def default_path():
    folder = os.environ.get("REACHLY_DATA_DIR") or os.path.expanduser("~/Library/Application Support/Reachly")
    return os.path.join(folder, "Reachly.store")


def uuid_text(blob):
    if blob is None:
        return None
    return str(uuid.UUID(bytes=bytes(blob))).upper() if len(blob) == 16 else str(blob)


def apple_date(seconds):
    return None if seconds is None else APPLE_EPOCH + dt.timedelta(seconds=seconds)


def read_store(path):
    """Audit records and conversation details from a copy of Reachly.store (and its -wal, which holds recent writes)."""
    records, conversations = [], {}
    with tempfile.TemporaryDirectory() as folder:
        copy = os.path.join(folder, "Reachly.store")
        shutil.copyfile(path, copy)
        if os.path.exists(path + "-wal"):
            shutil.copyfile(path + "-wal", copy + "-wal")
        db = sqlite3.connect(copy)
        try:
            rows = db.execute(
                "SELECT ZTIMESTAMP, ZSOURCERAW, ZHOSTNAME, ZHOSTTARGET, ZTOOL, ZCOMMAND, ZDECISIONRAW, ZEXITSTATUS,"
                " ZDURATIONMILLISECONDS, ZCONVERSATIONID FROM ZAGENTAUDITENTRY").fetchall()
        except sqlite3.DatabaseError as error:
            sys.exit(f"{path} has no agent audit log ({error}). Is it a Reachly.store?")
        for ts, source, host, target, tool, command, decision, status, ms, conversation in rows:
            records.append(dict(timestamp=apple_date(ts), source=source, hostName=host, hostTarget=target, tool=tool,
                                command=command, decision=decision, exitStatus=status, durationMilliseconds=ms,
                                conversationID=uuid_text(conversation)))
        try:
            for cid, title, created, updated in db.execute("SELECT ZUUID, ZTITLE, ZCREATEDAT, ZUPDATEDAT FROM ZAGENTCONVERSATION"):
                conversations[uuid_text(cid)] = dict(title=title, created=apple_date(created), updated=apple_date(updated))
        except sqlite3.DatabaseError:
            pass  # A store from before saved conversations: the audit records are enough.
        db.close()
    return records, conversations


def parse_time(text):
    return dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


def read_export(path):
    """Audit records from AI History's Export JSON: an array of records, newest first, with ISO 8601 dates."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        sys.exit(f"{path} is not a Reachly audit export (expected a JSON array of records).")
    records = []
    for item in data:
        record = {key: item.get(key) for key in ("source", "hostName", "hostTarget", "tool", "command", "decision",
                                                 "exitStatus", "durationMilliseconds", "conversationID")}
        record["timestamp"] = parse_time(item["timestamp"])
        records.append(record)
    return records, {}


def read(path):
    if os.path.isdir(path):
        path = os.path.join(path, "Reachly.store")
    if not os.path.exists(path):
        sys.exit(f"No audit log at {path}. Pass the path of a Reachly.store or an exported .json.")
    with open(path, "rb") as f:
        head = f.read(16)
    if head.startswith(b"SQLite format 3"):
        return path, "Reachly store", read_store(path)
    return path, "JSON export", read_export(path)


def duration(seconds):
    seconds = int(round(seconds))
    hours, rest = divmod(seconds, 3600)
    minutes, seconds = divmod(rest, 60)
    return f"{hours}h {minutes:02d}m {seconds:02d}s" if hours else f"{minutes}m {seconds:02d}s"


def summarize(cid, records, conversation):
    """The numbers for one conversation. A record is written when its command ends, so a command started at its
    timestamp minus its run time: the run starts when the first command starts and ends when the last one ends."""
    records = sorted(records, key=lambda r: r["timestamp"])
    starts = [r["timestamp"] - dt.timedelta(milliseconds=r["durationMilliseconds"] or 0) for r in records]
    start, end = min(starts), records[-1]["timestamp"]
    gaps = [(b["timestamp"] - a["timestamp"], a["timestamp"], b["timestamp"]) for a, b in zip(records, records[1:])]
    pause = max(gaps) if gaps else None
    decisions = Counter(r["decision"] for r in records)
    ran = [r for r in records if r["decision"] in RAN]
    summary = {
        "conversation": cid,
        "title": (conversation or {}).get("title"),
        "sources": sorted(Counter(r["source"] for r in records)),
        "start": start.isoformat(),
        "end": end.isoformat(),
        "elapsedSeconds": round((end - start).total_seconds(), 1),
        "longestPause": None if pause is None else {"seconds": round(pause[0].total_seconds(), 1),
                                                    "from": pause[1].isoformat(), "to": pause[2].isoformat()},
        "commands": len(records),
        "ran": len(ran),
        "notRun": len(records) - len(ran),
        "nonZeroExit": sum(1 for r in ran if r["exitStatus"] not in (None, 0)),
        "tools": dict(Counter(r["tool"] for r in records).most_common()),
        "hosts": dict(sorted(Counter(r["hostName"] for r in records).items(), key=lambda kv: (-kv[1], kv[0]))),
        "decisions": {d: decisions.get(d, 0) for d in DECISIONS},
    }
    extra = sorted(set(decisions) - set(DECISIONS))  # from a newer Reachly
    for d in extra:
        summary["decisions"][d] = decisions[d]
    if conversation and conversation.get("created") and conversation.get("updated"):
        summary["chat"] = {"firstMessage": conversation["created"].isoformat(), "lastSaved": conversation["updated"].isoformat(),
                           "seconds": round((conversation["updated"] - conversation["created"]).total_seconds(), 1)}
    return summary


def local(text):
    return dt.datetime.fromisoformat(text).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def clock(text):
    return dt.datetime.fromisoformat(text).astimezone().strftime("%H:%M:%S")


def show(s):
    print(f"Conversation {s['conversation'] or '(none: commands from an MCP client that gave no conversation)'}")
    if s["title"]:
        print(f"  {s['title']}")
    print(f"  start       {local(s['start'])}   (first command starts)")
    print(f"  end         {local(s['end'])}   (last command ends)")
    line = f"  elapsed     {duration(s['elapsedSeconds'])}"
    if s["longestPause"]:
        p = s["longestPause"]
        line += f"   (longest gap between commands: {duration(p['seconds'])}, {clock(p['from'])} to {clock(p['to'])})"
    print(line)
    if "chat" in s:
        c = s["chat"]
        print(f"  chat        first message {clock(c['firstMessage'])}, last saved {clock(c['lastSaved'])} ({duration(c['seconds'])})")
    tools = ", ".join(f"{t} {n}" for t, n in s["tools"].items())
    print(f"  commands    {s['commands']} asked for: {s['ran']} ran, {s['notRun']} not run   ({tools})")
    if s["nonZeroExit"]:
        print(f"              {s['nonZeroExit']} of those that ran exited non-zero")
    hosts = ", ".join(f"{h} {n}" for h, n in s["hosts"].items())
    print(f"  hosts       {len(s['hosts'])}: {hosts}")
    print("  decisions   " + ", ".join(f"{d} {n}" for d, n in s["decisions"].items()))
    if s["sources"] != ["agent"]:
        print(f"  from        {', '.join(s['sources'])} (agent: Reachly's chat panel; mcp: an MCP client)")
    print()


def main():
    parser = argparse.ArgumentParser(description="Measure Reachly AI runs from the agent audit log.",
                                     epilog=f"Default log: {default_path()}")
    parser.add_argument("path", nargs="?", default=default_path(), help="Reachly.store, its data folder, or an exported .json")
    parser.add_argument("--last", action="store_true", help="only the newest conversation")
    parser.add_argument("--conversation", metavar="ID", help="only conversations whose id starts with ID")
    parser.add_argument("--json", action="store_true", help="print JSON instead of text")
    args = parser.parse_args()

    path, kind, (records, conversations) = read(os.path.expanduser(args.path))
    groups = {}
    for record in records:
        groups.setdefault(record["conversationID"], []).append(record)
    summaries = [summarize(cid, rs, conversations.get(cid)) for cid, rs in groups.items()]
    summaries.sort(key=lambda s: s["start"])
    if args.conversation:
        wanted = args.conversation.upper()
        summaries = [s for s in summaries if (s["conversation"] or "").startswith(wanted)]
    if args.last:
        summaries = summaries[-1:]

    if args.json:
        print(json.dumps({"log": path, "kind": kind, "records": len(records), "conversations": summaries}, indent=2))
        return
    print(f"Reachly audit log: {path} ({kind}, {len(records)} records, "
          f"{len(groups)} conversation{'' if len(groups) == 1 else 's'})\n")
    if not summaries:
        print("No matching audit records.")
        return
    for s in summaries:
        show(s)
    if len(summaries) > 1:
        total = Counter()
        for s in summaries:
            total.update(s["decisions"])
        hosts = sorted({h for s in summaries for h in s["hosts"]})
        print(f"All {len(summaries)} conversations: {sum(s['commands'] for s in summaries)} commands on {len(hosts)} hosts; "
              + ", ".join(f"{d} {total[d]}" for d in DECISIONS) + "\n")
    print("auto-allowed: the host's mode let it run without asking. approved / edited: a person said yes (edited: after\n"
          "changing it). denied / changes-requested: a person said no. blocked: refused by the host's mode, nobody asked.")


if __name__ == "__main__":
    main()
