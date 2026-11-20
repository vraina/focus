"""The parent's web dashboard: sign in, then read the same logs the Mac app shows under History.

Read-only. Everything here comes from MongoDB, where the Mac uploads its records.
"""
import hashlib
import hmac
import os
import re
import secrets
from datetime import datetime, timedelta, timezone
from functools import wraps

from flask import Response, abort, redirect, render_template, request, session, url_for

MAX_FAILED_LOGINS = 8
LOCKOUT_MINUTES = 15
DECISION_LABEL = {"approve_temporary": "Approved for a while", "approve_permanent": "Approved for good", "deny": "Not approved"}
STATE_LABEL = {"productive": "Productive", "distraction": "Distraction", "allowed": "Always allowed",
               "locked": "Always a distraction", "review": "Distraction"}


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


def register(app, db, zone, signer, keep_days: int = 14):
    password = os.environ.get("PARENT_PASSWORD", "")
    parent_email = os.environ.get("PARENT_EMAIL", "").strip().lower()
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        # Only sent over HTTPS in production; plain http is allowed for a local run.
        SESSION_COOKIE_SECURE=os.environ.get("PUBLIC_URL", "").startswith("https://"),
        PERMANENT_SESSION_LIFETIME=timedelta(days=30),
    )
    starts, ends, events, media = db["sprintStarts"], db["sprintEnds"], db["events"], db["media"]
    try:
        events.create_index("sprintId")
        starts.create_index("startedAt")
    except Exception:  # an index is a speed-up, never a reason not to start
        pass

    def local(ts: str) -> datetime:
        return parse(ts).astimezone(zone)

    def clock(ts: str) -> str:
        return local(ts).strftime("%-I:%M:%S %p")

    def csrf_token() -> str:
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(24)
        return session["csrf"]

    def check_csrf():
        if not hmac.compare_digest(request.form.get("csrf", ""), session.get("csrf", "x")):
            abort(400)

    def signed_in(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if not session.get("parent"):
                return redirect(url_for("login", next=request.path))
            return view(*args, **kwargs)
        return wrapper

    app.jinja_env.globals.update(csrf_token=csrf_token, duration=duration, level=level)

    # --- Signing in ---------------------------------------------------------------------------

    def client_ip() -> str:
        return (request.headers.get("X-Forwarded-For", request.remote_addr or "").split(",")[0]).strip()[:64]

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if not password:
            return render_template("login.html", error="The dashboard is switched off. Set PARENT_PASSWORD in the service's "
                                                       "environment settings to turn it on.", disabled=True), 503
        error = None
        if request.method == "POST":
            check_csrf()
            since = datetime.now(timezone.utc) - timedelta(minutes=LOCKOUT_MINUTES)
            failures = db["logins"].count_documents({"ip": client_ip(), "at": {"$gte": since}})
            if failures >= MAX_FAILED_LOGINS:
                return render_template("login.html", error=f"Too many attempts. Try again in {LOCKOUT_MINUTES} minutes."), 429
            given_email = request.form.get("email", "").strip().lower()
            # Compare digests so the check takes the same time whatever was typed.
            ok_password = hmac.compare_digest(hashlib.sha256(request.form.get("password", "").encode()).digest(),
                                              hashlib.sha256(password.encode()).digest())
            ok_email = hmac.compare_digest(given_email.encode(), parent_email.encode()) if parent_email else True
            if ok_password and ok_email:
                session.clear()
                session["parent"] = True
                session.permanent = True
                target = request.args.get("next", "")
                return redirect(target if target.startswith("/dashboard") else url_for("overview"))
            db["logins"].insert_one({"ip": client_ip(), "at": datetime.now(timezone.utc)})
            error = "That email or password is not right."
        return render_template("login.html", error=error), (401 if error else 200)

    @app.post("/logout")
    def logout():
        check_csrf()
        session.clear()
        return redirect(url_for("login"))

    @app.get("/")
    def home():
        return redirect(url_for("overview") if session.get("parent") else url_for("login"))

    # --- Reading the records ------------------------------------------------------------------

    def day_bounds(day: str):
        try:
            start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=zone)
        except ValueError:
            abort(404)
        fmt = "%Y-%m-%dT%H:%M:%SZ"
        return start, start.astimezone(timezone.utc).strftime(fmt), (start + timedelta(days=1)).astimezone(timezone.utc).strftime(fmt)

    def scope() -> dict:
        """Which child, and optionally which computer, the page is narrowed to. Empty means everyone."""
        user = request.args.get("user", "").strip()[:60]
        device = request.args.get("device", "").strip()[:80] if user else ""
        return {k: v for k, v in (("user", user), ("device", device)) if v}

    def profiles() -> list[dict]:
        """Each child seen in the last 60 days, with the computers they used."""
        since = (datetime.now(timezone.utc) - timedelta(days=60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        found: dict[str, set] = {}
        for row in starts.aggregate([{"$match": {"startedAt": {"$gte": since}}},
                                     {"$group": {"_id": {"user": "$user", "device": "$device"}}}]):
            found.setdefault(row["_id"].get("user") or "", set()).add(row["_id"].get("device") or "")
        return [{"user": user, "devices": sorted(found[user])} for user in sorted(found) if user]

    def who_filter(q: dict) -> dict:
        """The same narrowing for requests and searches. Older records only carry the combined "who" text."""
        if not q:
            return {}
        if "device" in q:
            return {"$or": [{"user": q["user"], "device": q["device"]}, {"who": f"{q['user']} on {q['device']}"}]}
        return {"$or": [{"user": q["user"]}, {"who": {"$regex": "^" + re.escape(q["user"]) + " on "}}]}

    app.jinja_env.globals.update(scope=scope, profiles=profiles)

    def sessions_between(lo: str, hi: str, q: dict | None = None) -> list[dict]:
        """Every sprint and outside-sprint stretch that started in the window, with its switches and totals."""
        found = list(starts.find({"startedAt": {"$gte": lo, "$lt": hi}, **(q or {})}).sort("startedAt", -1))
        ids = [s["_id"] for s in found]
        end_by_id = {e["_id"]: e for e in ends.find({"_id": {"$in": ids}})}
        events_by_id: dict[str, list] = {}
        for e in events.find({"sprintId": {"$in": ids}}).sort("startedAt", -1):
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
                "who": f"{s.get('user', '')} on {s.get('device', '')}", "planned": s.get("plannedSeconds", 0),
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
        today = datetime.now(zone).replace(hour=0, minute=0, second=0, microsecond=0)
        first = today - timedelta(days=13)
        fmt = "%Y-%m-%dT%H:%M:%SZ"
        q = scope()
        sessions = sessions_between(first.astimezone(timezone.utc).strftime(fmt),
                                    (today + timedelta(days=1)).astimezone(timezone.utc).strftime(fmt), q)
        by_day: dict[str, list] = {}
        for s in sessions:
            by_day.setdefault(local(s["start"]).strftime("%Y-%m-%d"), []).append(s)
        search_counts: dict[str, int] = {}
        for x in db["searches"].find({"day": {"$gte": first.strftime("%Y-%m-%d")}, "label": "distraction", **who_filter(q)}, {"day": 1}):
            search_counts[x["day"]] = search_counts.get(x["day"], 0) + 1
        days = []
        for offset in range(14):
            d = today - timedelta(days=offset)
            key = d.strftime("%Y-%m-%d")
            mine = by_day.get(key, [])
            days.append({"key": key, "label": "Today" if offset == 0 else ("Yesterday" if offset == 1 else d.strftime("%A")),
                         "date": d.strftime("%-d %B"), "totals": totals(mine),
                         "sprints": sum(1 for s in mine if not s["ambient"]), "searches": search_counts.get(key, 0)})
        return render_template("overview.html", days=days, q=q)

    @app.get("/dashboard/day/<day>")
    @signed_in
    def day_view(day):
        start, lo, hi = day_bounds(day)
        q = scope()
        sessions = sessions_between(lo, hi, q)
        several = sum(len(p["devices"]) for p in profiles()) > 1 and "device" not in q
        # Pictures are only kept for a while; for older days the switches are listed without them.
        cutoff = (datetime.now(zone) - timedelta(days=keep_days)).strftime("%Y%m%d")
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
                    "who": s["who"] if several else "",  # only worth showing when more than one computer is in view
                    "media": [{"role": "First seconds" if m.get("role") == "start" else "Last seconds", "kind": m.get("kind", "image"),
                               "url": url_for("media_file", sprint_id=e["sprintId"], name=m["file"])}
                              for m in e.get("media", []) if not pictures_gone],
                })
        switches.sort(key=lambda x: x["sort"], reverse=True)
        day_searches = list(db["searches"].find({"day": day, **who_filter(q)}).sort([("at", -1), ("ts", -1)]))
        requests_today = list(db["requests"].find({"day": day, **who_filter(q)}).sort([("at", -1), ("ts", -1)]))
        for r in requests_today:
            r["decisionLabel"] = DECISION_LABEL.get(r.get("decision"), "")
        return render_template(
            "day.html", day=day, title=start.strftime("%A %-d %B %Y"), totals=totals(sessions), q=q, several=several,
            pictures_gone=pictures_gone, keep_days=keep_days,
            previous=(start - timedelta(days=1)).strftime("%Y-%m-%d"),
            following=(start + timedelta(days=1)).strftime("%Y-%m-%d") if start + timedelta(days=1) <= datetime.now(zone) else None,
            sprints=[dict(s, clock=local(s["start"]).strftime("%-I:%M %p")) for s in sessions if not s["ambient"]],
            switches=switches, requests=requests_today,
            search_counts={k: sum(1 for x in day_searches if x["label"] == k) for k in ("work", "distraction", "personal")},
            searches=[x for x in day_searches if x["label"] == "distraction"])

    @app.get("/dashboard/sites")
    @signed_in
    def sites_view():
        rows = [{"host": d["_id"], "state": STATE_LABEL.get(d.get("state"), d.get("state", "")), "raw": d.get("state", ""),
                 "reason": d.get("reason", ""), "source": d.get("source", ""),
                 "window": ", ".join(sorted(who for who, until in (d.get("approvedFor") or {}).items()
                                            if until > datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))),
                 "link": url_for("decide_page", t=signer.dumps(d["_id"]))}
                for d in db["sites"].find({}).sort("updatedAt", -1).limit(1000)]
        return render_template("sites.html", sites=rows)

    @app.get("/dashboard/media/<sprint_id>/<name>")
    @signed_in
    def media_file(sprint_id, name):
        doc = media.find_one({"_id": f"{sprint_id}/{name}"})
        if not doc:
            abort(404)
        kind = "video/mp4" if name.endswith(".mp4") else "image/jpeg"
        # Records never change once written, so the browser may keep its copy. Private: never a shared cache.
        return Response(bytes(doc["data"]), mimetype=kind, headers={"Cache-Control": "private, max-age=86400"})
