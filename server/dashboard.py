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
        """The people offered at the top of a page. The page always shows one person: each kid an admin can
        see, then the signed-in adult's own records. The first is the default, so an admin with kids lands on
        a kid, and anyone else on themselves. (There used to be an "All kids" choice; a link that still asks
        for it simply gets the default.)"""
        mine = request.account["memberId"]
        kids = sorted((m for m in request.visible if m.get("kind") == "kid"), key=lambda m: m.get("name", "").lower())
        out = [{"key": k["_id"], "label": k.get("name", "Kid"), "ids": [k["_id"]], "title": f"{k.get('name', 'Kid')}'s day"} for k in kids]
        if any(m["_id"] == mine for m in request.visible):
            out.append({"key": "me", "label": "Me", "ids": [mine], "title": "My day"})
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
                "partial": len(days) < 28, "calendar": calendar(today, {d["key"]: d for d in days}, selected)}

    def calendar(today: datetime, known: dict, selected: str) -> dict:
        """A month grid for the Calendar button. Only the last 14 days can be chosen; each has a dot coloured
        by how distracted the day was. Older days are reached from the four-week graph."""
        oldest = today - timedelta(days=13)
        first = oldest - timedelta(days=oldest.weekday())         # the Monday on or before the oldest day
        last = today + timedelta(days=6 - today.weekday())        # the Sunday on or after today
        cells = []
        d = first
        while d <= last:
            key = d.strftime("%Y-%m-%d")
            info = known.get(key)
            open_day = oldest <= d <= today
            cells.append({"key": key, "n": d.day, "label": d.strftime("%A %-d %B") + (": " + info["summary"] if info else ""),
                          "open": open_day, "selected": key == selected,
                          "dot": (info["level"] if info and info["tracked"] else "") if open_day else ""})
            d += timedelta(days=1)
        title = today.strftime("%B %Y") if oldest.month == today.month else f"{oldest.strftime('%b')} – {today.strftime('%b %Y')}"
        return {"title": title, "cells": cells}

    def day_timeline(sessions: list[dict], start: datetime) -> dict | None:
        """The day as ONE continuous bar, cut into consecutive segments of four kinds: on task, distraction,
        off task during a sprint, and Mac not in use. Sprints are not drawn; they only decide whether a
        switch away counts as off task."""
        if not sessions:
            return None
        spans = [(local(x["start"]), local(x["until"])) for x in sessions]
        lo = min(a for a, _ in spans).replace(minute=0, second=0, microsecond=0)
        hi = max(b for _, b in spans)
        if hi > hi.replace(minute=0, second=0, microsecond=0):
            hi = hi.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)
        lo, hi = max(lo, start), min(max(hi, lo + timedelta(hours=1)), start + timedelta(days=1))
        if hi - lo < timedelta(hours=4):  # a short day still gets a readable bar
            hi = min(lo + timedelta(hours=4), start + timedelta(days=1))
            lo = min(lo, hi - timedelta(hours=4))
        # Paint the kinds over each other, most telling last: in use, then off task, then distraction.
        layers = [("on", a, b, None) for a, b in spans]
        for x in sessions:
            for e in x["events"]:
                kind = "bad" if e.get("category") == "distraction" else "off"
                layers.append((kind, local(e["startedAt"]), local(e["endedAt"]), e))
        rank = {"idle": 0, "on": 1, "off": 2, "bad": 3}
        cuts = sorted({lo, hi} | {min(max(t, lo), hi) for _, a, b, _ in layers for t in (a, b)})
        segments = []
        for a, b in zip(cuts, cuts[1:]):
            if b <= a:
                continue
            middle = a + (b - a) / 2
            kind, event = "idle", None
            for k, s0, s1, e in layers:
                if s0 <= middle < s1 and rank[k] > rank[kind]:
                    kind, event = k, e
            seconds = (b - a).total_seconds()
            if segments and segments[-1]["kind"] == kind and segments[-1]["id"] == (event or {}).get("_id"):
                segments[-1]["seconds"] += seconds
                segments[-1]["until"] = b
                continue
            segments.append({"kind": kind, "seconds": seconds, "from": a, "until": b, "id": (event or {}).get("_id"),
                             "site": (event or {}).get("host") or (event or {}).get("appName", "")})
        words = {"on": "On task", "bad": "Distraction", "off": "Off task during a sprint", "idle": "Mac not in use"}
        for g in segments:
            span = f"{g['from'].strftime('%-I:%M %p').lower()} to {g['until'].strftime('%-I:%M %p').lower()}"
            g["label"] = (f"{g['site']} · " if g["site"] else "") + f"{words[g['kind']]} · {span} · {duration(g['seconds'])}"
            g["weight"] = round(g["seconds"], 1)
        count = lambda k: sum(1 for g in segments if g["kind"] == k)
        total = (hi - lo).total_seconds()
        hours = int(total // 3600)
        step = 1 if hours <= 10 else (2 if hours <= 18 else 3)
        ticks = []
        for h in range(0, hours + 1, step):
            at = lo + timedelta(hours=h)
            edge = h == 0 or h + step > hours
            ticks.append({"left": round(h / hours * 100, 3),
                          "label": at.strftime("%-I:%M %p").lower() if edge else at.strftime("%-I %p" if at.hour in (0, 12) else "%-I").lower()})
        return {"segments": segments, "ticks": ticks,
                "summary": f"The day as one line: {count('bad')} distraction{'s' if count('bad') != 1 else ''}, "
                           f"{count('off')} off task during a sprint, and the rest on task or with the Mac not in use"}

    def switch_totals(switches: list[dict]) -> list[dict]:
        """Every switch away added up per app or website, most time first."""
        by_site: dict[str, dict] = {}
        for e in sorted(switches, key=lambda x: x["sort"]):
            t = by_site.setdefault(e["site"], {"site": e["site"], "visits": 0, "bad": 0.0, "off": 0.0, "times": [], "in_sprint": 0})
            t["visits"] += 1
            t["bad" if e["category"] == "distraction" else "off"] += e["seconds"]
            t["times"].append(e["started_short"])
            t["in_sprint"] += 1 if e["during"] else 0
        rows = sorted(by_site.values(), key=lambda t: t["bad"] + t["off"], reverse=True)
        longest = max((t["bad"] + t["off"] for t in rows), default=0) or 1
        for t in rows:
            total = t["bad"] + t["off"]
            t["total"], t["total_text"] = total, duration(total)
            t["bad_width"], t["off_width"] = round(t["bad"] / longest * 100, 1), round(t["off"] / longest * 100, 1)
            when = t["times"][0] if t["visits"] == 1 else (" and ".join(t["times"]) if t["visits"] == 2 else f"first at {t['times'][0]}")
            sprint = "" if not t["in_sprint"] else (" · during a sprint" if t["in_sprint"] == t["visits"] else f" · {t['in_sprint']} during a sprint")
            t["meta"] = f"{t['visits']} visit{'s' if t['visits'] != 1 else ''} · {when}{sprint}"
            parts = [f"{duration(t['bad'])} distraction"] if t["bad"] else []
            parts += [f"{duration(t['off'])} off task"] if t["off"] else []
            t["label"] = f"{t['site']}: {t['total_text']} in all, " + " and ".join(parts)
        return rows

    @app.get("/dashboard/day/<day>")
    @signed_in
    def day_page(day):
        return day_view(day)

    def day_view(day):
        return render_template("day.html", **day_context(day))

    def day_context(day) -> dict:
        """Everything the activity page and its four details pages show for one person's day."""
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
                    "started_short": local(e["startedAt"]).strftime("%-I:%M %p").lower(), "ended_short": local(e["endedAt"]).strftime("%-I:%M %p").lower(),
                    "seconds": float(e.get("durationSeconds", 0)),
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
        sums = totals(sessions)
        sums["word"] = {"good": "Hardly at all", "warn": "A little", "bad": "A lot"}[sums["level"]] if sums["tracked"] else "Nothing tracked"
        sums["ticks"] = round(min(1.0, sums["away"] / sums["tracked"]) * 40) if sums["tracked"] else 0  # of 40 marks
        show = "summary" if request.args.get("view") == "summary" else "detailed"
        return dict(
            day=day, title=start.strftime("%A %-d %B %Y"), date_label=start.strftime("%A %-d %B"),
            date_short=start.strftime("%a %-d %B"), totals=sums, view=view, several=several, show=show,
            switch_totals=switch_totals(switches),
            is_today=is_today, weeks=four_weeks(view, day), timeline=day_timeline(sessions, start),
            pictures_gone=pictures_gone, keep_days=keep_days,
            previous=(start - timedelta(days=1)).strftime("%Y-%m-%d"),
            following=(start + timedelta(days=1)).strftime("%Y-%m-%d") if start + timedelta(days=1) <= datetime.now(zone()) else None,
            sprints=[dict(s, clock=local(s["start"]).strftime("%-I:%M %p"),
                          span=f"{local(s['start']).strftime('%-I:%M')} – {local(s['until']).strftime('%-I:%M %p').lower()}",
                          **sprint_detail(s))
                     for s in sessions if not s["ambient"]],
            switches=switches, requests=requests_today,
            search_counts={k: sum(1 for x in day_searches if x["label"] == k) for k in ("work", "distraction", "personal")},
            searches=[x for x in day_searches if x["label"] == "distraction"])

    def sprint_detail(s: dict) -> dict:
        """What the Sprints details page adds: the sprint as a bar of consecutive on-task and away stretches,
        how long it lasted, and each switch away in words."""
        begin, until = parse(s["start"]), parse(s["until"])
        bar, at, lines = [], begin, []
        for e in sorted(s["events"], key=lambda e: e["startedAt"]):
            e0, e1 = max(parse(e["startedAt"]), at), min(parse(e["endedAt"]), until)
            if e1 <= e0:
                continue
            if e0 > at:
                bar.append({"kind": "on", "weight": (e0 - at).total_seconds()})
            bad = e.get("category") == "distraction"
            bar.append({"kind": "bad" if bad else "off", "weight": (e1 - e0).total_seconds()})
            lines.append(f"{'Distraction' if bad else 'Off task'}: {e.get('host') or e.get('appName', '')} at "
                         f"{local(e['startedAt']).strftime('%-I:%M %p').lower()} for {duration(e.get('durationSeconds', 0))}.")
            at = e1
        if until > at or not bar:
            bar.append({"kind": "on", "weight": max(1.0, (until - at).total_seconds())})
        return {"bar": bar, "lasted": duration(s["elapsed"]), "lines": lines,
                "when": f"{local(s['start']).strftime('%-I:%M %p').lower()} to {local(s['until']).strftime('%-I:%M %p').lower()}"}

    DETAILS = {"sprints": "Sprints", "searches": "Web searches", "requests": '"Needed for work" requests', "switches": "Every switch away"}

    @app.get("/dashboard/day/<day>/<any(sprints, searches, requests, switches):page>")
    @signed_in
    def day_details(day, page):
        """One card of the activity page, larger: the same day, the same person, the same data."""
        ctx = day_context(day)
        t, sprints, counts = ctx["totals"], ctx["sprints"], ctx["search_counts"]
        today = "today" if ctx["is_today"] else "this day"
        if page == "sprints":
            spent, away = sum(x["elapsed"] for x in sprints), sum(x["away"] for x in sprints)
            focus = int(round(max(0.0, spent - away) / spent * 100)) if spent else 0
            tiles = [(str(len(sprints)), f"Sprint{'s' if len(sprints) != 1 else ''} {today}", ""), (duration(spent), "Time in sprints", ""),
                     (f"{focus}%" if sprints else "–", "Focused across all sprints", level(1 - focus / 100) if sprints else "")]
        elif page == "searches":
            total = counts["work"] + counts["distraction"] + counts["personal"]
            tiles = [(str(total), f"Search{'es' if total != 1 else ''} {today}", ""), (str(counts["work"]), "For work", "good"),
                     (str(counts["distraction"]), "Distraction", "bad" if counts["distraction"] else "")]
        elif page == "requests":
            asked = ctx["requests"]
            approved = [r for r in asked if r.get("decision") != "deny"]
            granted = sum(int(r.get("grantedMinutes") or 0) for r in asked if r.get("decision") == "approve_temporary")
            tiles = [(str(len(asked)), f"Request{'s' if len(asked) != 1 else ''} {today}", ""), (str(len(approved)), "Approved", "good" if approved else ""),
                     (f"{granted} min", "Time granted", "")]
        else:
            tiles = [(str(len(ctx["switches"])), f"Switch{'es' if len(ctx['switches']) != 1 else ''} away", ""),
                     (duration(t["away"]), "Time away", t["level"] if t["tracked"] else ""),
                     (f"{t['percent']}%", "Of tracked time", t["level"] if t["tracked"] else "")]
        return render_template("details.html", page=page, heading=DETAILS[page], tiles=tiles, **ctx)

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
