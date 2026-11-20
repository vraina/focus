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
        names = sorted({d.get("name", "Mac") for d in db["devices"].find({"memberId": {"$in": picked["ids"]}})})
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

    def sessions_between(lo: str, hi: str, view: dict) -> list[dict]:
        """Every sprint and outside-sprint stretch that started in the window, with its switches and totals."""
        names = {m["_id"]: m.get("name", "") for m in request.visible}
        found = list(starts.find({"startedAt": {"$gte": lo, "$lt": hi}, **narrowed(view)}).sort("startedAt", -1))
        ids = [s["_id"] for s in found]
        own = {"memberId": {"$in": view["ids"]}}
        end_by_id = {e["_id"]: e for e in ends.find({"_id": {"$in": ids}, **own})}
        events_by_id: dict[str, list] = {}
        for e in events.find({"sprintId": {"$in": ids}, **own}).sort("startedAt", -1):
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
            planned_end = parse(s["startedAt"]) + timedelta(seconds=s.get("plannedSeconds", 0))
            out.append({
                "id": s["_id"], "task": s.get("task", ""), "ambient": ambient, "start": s["startedAt"],
                "who": f"{names.get(s.get('memberId'), 'Member')} on {s.get('device', 'Mac')}", "planned": s.get("plannedSeconds", 0),
                "elapsed": elapsed, "away": float(away), "events": mine,
                "focus": int(round(max(0.0, elapsed - away) / elapsed * 100)),
                "status": ("Completed" if end["status"] == "completed" else "Ended early") if end
                          else ("Interrupted" if not ambient and datetime.now(timezone.utc) > planned_end else "In progress"),
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
        view = chosen()
        today = datetime.now(zone()).replace(hour=0, minute=0, second=0, microsecond=0)
        first = today - timedelta(days=13)
        sessions = sessions_between(first.astimezone(timezone.utc).strftime(FMT),
                                    (today + timedelta(days=1)).astimezone(timezone.utc).strftime(FMT), view)
        by_day: dict[str, list] = {}
        for s in sessions:
            by_day.setdefault(local(s["start"]).strftime("%Y-%m-%d"), []).append(s)
        search_counts: dict[str, int] = {}
        for x in db["searches"].find({"day": {"$gte": first.strftime("%Y-%m-%d")}, "label": "distraction", **narrowed(view)}, {"day": 1}):
            search_counts[x["day"]] = search_counts.get(x["day"], 0) + 1
        days = []
        for offset in range(14):
            d = today - timedelta(days=offset)
            key = d.strftime("%Y-%m-%d")
            mine = by_day.get(key, [])
            days.append({"key": key, "label": "Today" if offset == 0 else ("Yesterday" if offset == 1 else d.strftime("%A")),
                         "date": d.strftime("%-d %B"), "totals": totals(mine),
                         "sprints": sum(1 for s in mine if not s["ambient"]), "searches": search_counts.get(key, 0)})
        return render_template("overview.html", days=days, view=view)

    @app.get("/dashboard/day/<day>")
    @signed_in
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
        return render_template(
            "day.html", day=day, title=start.strftime("%A %-d %B %Y"), totals=totals(sessions), view=view, several=several,
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
