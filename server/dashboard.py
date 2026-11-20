"""The website's read-only pages: the same logs the Mac app shows under History.

Who can read what is decided in one place, `chosen()`: admins and co-admins see the kids (and themselves);
an adult member sees only themselves. Every query below is narrowed to those members.
"""
from datetime import datetime, timedelta, timezone

from flask import Response, abort, render_template, request, url_for

DECISION_LABEL = {"approve_temporary": "Approved for a while", "approve_permanent": "Approved for good", "deny": "Not approved"}
STATE_LABEL = {"productive": "Productive", "distraction": "Distraction", "allowed": "Always allowed",
               "locked": "Always a distraction", "review": "Distraction"}
FMT = "%Y-%m-%dT%H:%M:%SZ"


def parse(ts: str) -> datetime:
    return datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)


def duration(seconds: float) -> str:
    s = int(round(seconds or 0))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m {s % 60:02d}s"
    return f"{s // 3600}h {(s % 3600) // 60:02d}m"


def level(fraction: float) -> str:
    return "good" if fraction < 0.05 else ("warn" if fraction < 0.15 else "bad")


def register(app, svc, keep_days: int = 14):
    db, signed_in = svc.db, svc.signed_in
    starts, ends, events, media = db["sprintStarts"], db["sprintEnds"], db["events"], db["media"]

    def zone():
        return svc.zone(request.family)

    def local(ts: str) -> datetime:
        return parse(ts).astimezone(zone())

    def clock(ts: str) -> str:
        return local(ts).strftime("%-I:%M:%S %p")

    # --- Whose records are on the page --------------------------------------------------------

    def groups() -> list[dict]:
        """The choices offered at the top of a page. Kids are grouped (admins usually want the household's
        kids together); an adult's own records are always a separate choice, never mixed in with the kids."""
        mine = request.account["memberId"]
        kids = [m for m in request.visible if m.get("kind") == "kid"]
        out = []
        if len(kids) > 1:
            out.append({"key": "kids", "label": "All kids", "ids": [k["_id"] for k in kids]})
        out += [{"key": k["_id"], "label": k.get("name", "Kid"), "ids": [k["_id"]]} for k in kids]
        if any(m["_id"] == mine for m in request.visible):
            out.append({"key": "me", "label": "Me", "ids": [mine]})
        return out

    def chosen() -> dict:
        """The selected choice, with an optional computer. An unknown or forbidden choice falls back to the first."""
        options = groups()
        picked = next((o for o in options if o["key"] == request.args.get("who", "")), options[0] if options else None)
        if picked is None:
            abort(404)
        # A "computer" here is one Mac login on one Mac, e.g. "Den iMac · mia".
        names = sorted({f"{d.get('name', 'Mac')} · {e.get('login', '')}" for d in db["devices"].find({"familyId": request.family["_id"]})
                        for e in (d.get("logins") or {}).values() if e.get("memberId") in picked["ids"]})
        device = request.args.get("device", "")
        return {**picked, "device": device if device in names else "", "devices": names if len(names) > 1 else [],
                "args": {k: v for k, v in (("who", picked["key"]), ("device", device if device in names else "")) if v}}

    def narrowed(view: dict) -> dict:
        """The database filter for the selection. `memberId` is what keeps other people's records out."""
        query = {"memberId": {"$in": view["ids"]}}
        if view["device"]:
            query["device"] = view["device"]
        return query

    app.jinja_env.globals.update(duration=duration, level=level, groups=groups)

    # --- Reading the records ------------------------------------------------------------------

    def day_bounds(day: str):
        try:
            start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=zone())
        except ValueError:
            abort(404)
        return start, start.astimezone(timezone.utc).strftime(FMT), (start + timedelta(days=1)).astimezone(timezone.utc).strftime(FMT)

    def sessions_between(lo: str, hi: str, view: dict, light: bool = False) -> list[dict]:
        """Every sprint and outside-sprint stretch that started in the window, with its switches and totals.
        `light` reads only what totals need (for the four-week graph), not titles, addresses or pictures."""
        names = {m["_id"]: m.get("name", "") for m in request.visible}
        found = list(starts.find({"startedAt": {"$gte": lo, "$lt": hi}, **narrowed(view)}).sort("startedAt", -1))
        ids = [s["_id"] for s in found]
        own = {"memberId": {"$in": view["ids"]}}
        end_by_id = {e["_id"]: e for e in ends.find({"_id": {"$in": ids}, **own})}
        events_by_id: dict[str, list] = {}
        fields = {"sprintId": 1, "startedAt": 1, "endedAt": 1, "durationSeconds": 1} if light else None
        for e in events.find({"sprintId": {"$in": ids}, **own}, fields).sort("startedAt", -1):
            events_by_id.setdefault(e["sprintId"], []).append(e)
        out = []
        for s in found:
            mine, end = events_by_id.get(s["_id"], []), end_by_id.get(s["_id"])
            ambient = s.get("kind") == "ambient"
            away = end["awaySeconds"] if end else sum(e.get("durationSeconds", 0) for e in mine)
            last = max((parse(e["endedAt"]) for e in mine), default=parse(s["startedAt"]))
            if ambient:
                elapsed = (end or {}).get("activeSeconds") or max((last - parse(s["startedAt"])).total_seconds(), away)
            elif end:
                elapsed = (parse(end["endedAt"]) - parse(s["startedAt"])).total_seconds()
            else:
                elapsed = (last - parse(s["startedAt"])).total_seconds()
            elapsed = max(1.0, float(elapsed))
            # A sprint started with "Until I stop" has no planned end. Without an end record it is taken to be
            # still going while the Mac keeps sending switches, and to have been cut short once it has gone quiet.
            planned_end = (parse(s["startedAt"]) + timedelta(seconds=s["plannedSeconds"]) if s.get("plannedSeconds")
                           else max(last, parse(s["startedAt"])) + timedelta(hours=2))
            out.append({
                "id": s["_id"], "task": s.get("task", ""), "ambient": ambient, "start": s["startedAt"],
                "added": [str(x)[:80] for x in (s.get("addedApps") or [])][:30], "removed": [str(x)[:80] for x in (s.get("removedApps") or [])][:30],
                "who": f"{names.get(s.get('memberId'), 'Member')} on {s.get('device', 'Mac')}", "planned": s.get("plannedSeconds", 0),
                "elapsed": elapsed, "away": float(away), "events": mine,
                "focus": int(round(max(0.0, elapsed - away) / elapsed * 100)),
                "status": ("Completed" if end["status"] == "completed" else "Ended early") if end
                          else ("Interrupted" if not ambient and datetime.now(timezone.utc) > planned_end else "In progress"),
                "open": not ambient and not s.get("plannedSeconds", 0),
                # When it stopped on the clock, for the day's timeline.
                "until": max(parse(end["endedAt"]) if end else last, parse(s["startedAt"])).strftime(FMT),
            })
        return out

    def totals(sessions: list[dict]) -> dict:
        tracked = sum(s["elapsed"] for s in sessions)
        away = sum(s["away"] for s in sessions)
        share = min(1.0, away / tracked) if tracked else 0.0
        return {"tracked": tracked, "away": away, "switches": sum(len(s["events"]) for s in sessions),
                "percent": int(round(share * 100)), "level": level(share)}

    @app.get("/dashboard")
    @signed_in
    def overview():
        """The front page: today's activity. (There used to be a separate list of days here.)"""
        return day_view(datetime.now(zone()).strftime("%Y-%m-%d"))

    def four_weeks(view: dict, selected: str) -> dict:
        """Distraction day by day for the last four weeks, for the graph at the top of the activity page.
        Days before anything was recorded are left out: the app was not installed then."""
        today = datetime.now(zone()).replace(hour=0, minute=0, second=0, microsecond=0)
        first = today - timedelta(days=27)
        earliest = starts.find_one(narrowed(view), {"startedAt": 1}, sort=[("startedAt", 1)])
        began = local(earliest["startedAt"]).replace(hour=0, minute=0, second=0, microsecond=0) if earliest else today
        by_day: dict[str, list] = {}
        for x in sessions_between(first.astimezone(timezone.utc).strftime(FMT),
                                  (today + timedelta(days=1)).astimezone(timezone.utc).strftime(FMT), view, light=True):
            by_day.setdefault(local(x["start"]).strftime("%Y-%m-%d"), []).append(x)
        days = []
        for offset in range(27, -1, -1):
            d = today - timedelta(days=offset)
            if d < began:
                continue
            key = d.strftime("%Y-%m-%d")
            t = totals(by_day.get(key, []))
            days.append({"key": key, "day": d.strftime("%-d"), "weekday": d.strftime("%a"), "month": d.strftime("%b"),
                         "first_of_month": d.day == 1, "monday": d.weekday() == 0, "today": offset == 0,
                         "selected": key == selected, "tracked": t["tracked"], "percent": t["percent"], "level": t["level"],
                         "label": d.strftime("%A %-d %B"),
                         "summary": (f"{t['percent']}% distracted · {duration(t['away'])} away of {duration(t['tracked'])}"
                                     if t["tracked"] else "Nothing recorded")})
        top = max([d["percent"] for d in days] + [10])
        top = min(100, ((top + 9) // 10) * 10)  # the scale ends on a round number just above the worst day
        for d in days:
            d["height"] = round(d["percent"] / top * 100, 1) if d["tracked"] else 0
        return {"days": days, "top": top, "recorded": earliest is not None, "since": began.strftime("%-d %B"),
                "partial": len(days) < 28}

    def day_timeline(sessions: list[dict], start: datetime) -> dict | None:
        """The day as one strip: when the Mac was in use, where the sprints were, and every switch away."""
        if not sessions:
            return None
        spans = [(local(x["start"]), local(x["until"]), x) for x in sessions]
        lo = min(a for a, _, _ in spans).replace(minute=0, second=0, microsecond=0)
        hi = max(b for _, b, _ in spans)
        hi = (hi.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)) if hi > hi.replace(minute=0, second=0, microsecond=0) else hi
        lo, hi = max(lo, start), min(max(hi, lo + timedelta(hours=1)), start + timedelta(days=1))
        if hi - lo < timedelta(hours=4):  # a short day still gets a readable strip
            hi = min(lo + timedelta(hours=4), start + timedelta(days=1))
            lo = min(lo, hi - timedelta(hours=4))
        total = (hi - lo).total_seconds()
        place = lambda a, b, least=0.0: (round(max(0.0, (a - lo).total_seconds()) / total * 100, 3),
                                         round(max(least, (min(b, hi) - max(a, lo)).total_seconds() / total * 100), 3))
        bands, marks = [], []
        for a, b, x in sorted(spans, key=lambda item: item[0]):
            left, width = place(a, b, 0.3)
            bands.append({"left": left, "width": width, "sprint": not x["ambient"],
                          "label": (f"Sprint: {x['task']}" if not x["ambient"] else "Mac in use, outside sprints")
                                   + f" · {a.strftime('%-I:%M %p')} to {b.strftime('%-I:%M %p')}"})
            for e in x["events"]:
                left, width = place(local(e["startedAt"]), local(e["endedAt"]), 0.35)
                marks.append({"left": left, "width": width, "bad": e.get("category") == "distraction", "id": e["_id"],
                              "label": f"{e.get('host') or e.get('appName', '')} · {clock(e['startedAt'])} · away {duration(e.get('durationSeconds', 0))}"})
        hours = int(total // 3600)
        step = 1 if hours <= 8 else (2 if hours <= 16 else 3)
        ticks = [{"left": round(h / hours * 100, 3), "label": (lo + timedelta(hours=h)).strftime("%-I %p").lower()}
                 for h in range(0, hours + 1, step)]
        return {"bands": bands, "marks": marks, "ticks": ticks}

    @app.get("/dashboard/day/<day>")
    @signed_in
    def day_page(day):
        return day_view(day)

    def day_view(day):
        start, lo, hi = day_bounds(day)
        view = chosen()
        sessions = sessions_between(lo, hi, view)
        several = len(view["ids"]) > 1 or (bool(view["devices"]) and not view["device"])
        # Pictures are only kept for a while; for older days the switches are listed without them.
        cutoff = (datetime.now(zone()) - timedelta(days=keep_days)).strftime("%Y%m%d")
        pictures_gone = start.strftime("%Y%m%d") < cutoff
        switches = []
        for s in sessions:
            for e in s["events"]:
                switches.append({
                    "id": e["_id"], "site": e.get("host") or e.get("appName", ""), "is_site": bool(e.get("host")),
                    "detail": " · ".join(x for x in ((e.get("appName") if e.get("host") else ""), e.get("title", "")) if x),
                    "category": e.get("category", "offTask"), "started": clock(e["startedAt"]), "ended": clock(e["endedAt"]),
                    "away": duration(e.get("durationSeconds", 0)), "sort": e["startedAt"],
                    "during": "" if s["ambient"] else s["task"],
                    "who": s["who"] if several else "",  # only worth showing when more than one person or computer is in view
                    "media": [{"role": "First seconds" if m.get("role") == "start" else "Last seconds", "kind": m.get("kind", "image"),
                               "url": url_for("media_file", sprint_id=e["sprintId"], name=m["file"])}
                              for m in e.get("media", []) if not pictures_gone],
                })
        switches.sort(key=lambda x: x["sort"], reverse=True)
        day_searches = list(db["searches"].find({"day": day, **narrowed(view)}).sort([("at", -1), ("ts", -1)]))
        requests_today = list(db["requests"].find({"day": day, **narrowed(view)}).sort([("at", -1), ("ts", -1)]))
        for r in requests_today:
            r["decisionLabel"] = DECISION_LABEL.get(r.get("decision"), "")
        is_today = day == datetime.now(zone()).strftime("%Y-%m-%d")
        return render_template(
            "day.html", day=day, title=start.strftime("%A %-d %B %Y"), totals=totals(sessions), view=view, several=several,
            is_today=is_today, weeks=four_weeks(view, day), timeline=day_timeline(sessions, start),
            pictures_gone=pictures_gone, keep_days=keep_days,
            previous=(start - timedelta(days=1)).strftime("%Y-%m-%d"),
            following=(start + timedelta(days=1)).strftime("%Y-%m-%d") if start + timedelta(days=1) <= datetime.now(zone()) else None,
            sprints=[dict(s, clock=local(s["start"]).strftime("%-I:%M %p")) for s in sessions if not s["ambient"]],
            switches=switches, requests=requests_today,
            search_counts={k: sum(1 for x in day_searches if x["label"] == k) for k in ("work", "distraction", "personal")},
            searches=[x for x in day_searches if x["label"] == "distraction"])

    @app.get("/dashboard/sites")
    @signed_in
    def sites_view():
        """One website list for the household's kids (admins manage it) and a private one for each adult."""
        mine = f"m:{request.account['memberId']}"
        lists = ([{"key": "kids", "label": "The kids' list", "scope": f"k:{request.family['_id']}"}] if svc.is_admin(request.account) else [])
        lists.append({"key": "mine", "label": "My own list", "scope": mine})
        picked = next((x for x in lists if x["key"] == request.args.get("list", "")), lists[0])
        names = {m["_id"]: m.get("name", "") for m in request.visible}
        current = datetime.now(timezone.utc).strftime(FMT)
        rows = [{"host": d["host"], "state": STATE_LABEL.get(d.get("state"), d.get("state", "")), "raw": d.get("state", ""),
                 "reason": d.get("reason", ""), "source": d.get("source", ""),
                 "window": ", ".join(sorted(names.get(who, "someone") for who, until in (d.get("approvedFor") or {}).items() if until > current)),
                 "link": url_for("decide_page", t=svc.signer.dumps([picked["scope"], d["host"]]))}
                for d in db["sites"].find({"scope": picked["scope"]}).sort("updatedAt", -1).limit(1000)]
        return render_template("sites.html", sites=rows, lists=lists, picked=picked["key"])

    @app.get("/dashboard/media/<sprint_id>/<name>")
    @signed_in
    def media_file(sprint_id, name):
        # The member check is what stops anyone opening someone else's picture by guessing its address:
        # another household's, or an adult's in their own household.
        doc = media.find_one({"_id": f"{sprint_id}/{name}", "memberId": {"$in": [m["_id"] for m in request.visible]}})
        if not doc:
            abort(404)
        kind = "video/mp4" if name.endswith(".mp4") else "image/jpeg"
        # Records never change once written, so the browser may keep its copy. Private: never a shared cache.
        return Response(bytes(doc["data"]), mimetype=kind, headers={"Cache-Control": "private, max-age=86400"})
