"""YoungWonks Focus family service.

- The Mac helper asks it to label new websites, and to review "needed for work" requests. Claude does both.
- An approved request stops the site counting as a distraction for a while, or for good. Nothing is ever blocked.
- Every request, the student's words and the decision go into `requests`, and the parent gets one summary
  email at the end of the day, with a link per site to overrule it.
- Labels and approvals live in MongoDB (`sites`), and the Mac helper syncs them down.
"""
import hmac
import html
import logging
import os
import re
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from dotenv import load_dotenv
from flask import Flask, abort, jsonify, request
from itsdangerous import BadSignature, URLSafeSerializer
from pymongo import MongoClient
from pymongo.errors import DuplicateKeyError

import classifier
import mailer

# Local development: values come from server/.env (never committed). On Render they are real environment variables.
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
logging.basicConfig(level=logging.INFO)

HOST_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
# What a parent's choice on the "overrule" page turns the site into. There is deliberately no "block":
# this tool makes the student and the parent aware of what happens, it never prevents anything.
DECISIONS = {"allow": "allowed", "distraction": "locked"}
DECISION_TEXT = {
    "allow": ("Always allow", "It will never count as a distraction."),
    "distraction": ("Always a distraction", "It counts as a distraction and \"needed for work\" requests for it are turned down."),
}
STATE_TEXT = {
    "productive": "Productive (labelled by AI)", "distraction": "Distraction",
    "allowed": "Always allowed", "locked": "Distraction (your decision)",
}


MAX_REQUESTS_PER_SITE_PER_DAY = 5


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now() -> str:
    return iso(datetime.now(timezone.utc))


def clean_host(raw) -> str | None:
    host = str(raw or "").strip().lower().rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    return host if HOST_RE.match(host) else None


def create_app(db=None, classify=classifier.classify, review=classifier.review_request, send_email=mailer.send,
               start_scheduler=False, label_search=classifier.classify_search) -> Flask:
    app = Flask(__name__)
    secret = os.environ.get("SECRET_KEY", "")
    device_token = os.environ.get("DEVICE_TOKEN", "")
    if not secret or not device_token:
        raise RuntimeError("SECRET_KEY and DEVICE_TOKEN must be set")
    signer = URLSafeSerializer(secret, salt="site-decision")
    if db is None:
        db = MongoClient(os.environ["MONGODB_URI"])[os.environ.get("MONGODB_DB", "focussprint")]
    sites = db["sites"]
    requests_log = db["requests"]
    searches = db["searches"]
    digests = db["digests"]
    zone = ZoneInfo(os.environ.get("TIMEZONE", "America/Los_Angeles"))
    digest_hour = int(os.environ.get("DIGEST_HOUR", "21"))

    def local_day(moment: datetime | None = None) -> str:
        return (moment or datetime.now(timezone.utc)).astimezone(zone).strftime("%Y-%m-%d")

    def require_device():
        sent = request.headers.get("Authorization", "")
        if not hmac.compare_digest(sent, f"Bearer {device_token}"):
            abort(401)

    def public(doc: dict) -> dict:
        out = {"host": doc["_id"], "state": doc["state"], "reason": doc.get("reason", ""),
               "category": doc.get("category", ""), "updatedAt": doc.get("updatedAt", "")}
        if doc.get("allowedUntil"):
            out["allowedUntil"] = doc["allowedUntil"]  # approved "needed for work" window
        return out

    @app.get("/healthz")
    def healthz():
        return "ok"

    @app.post("/api/classify")
    def api_classify():
        require_device()
        body = request.get_json(silent=True) or {}
        host = clean_host(body.get("host"))
        if not host:
            return jsonify(error="invalid host"), 400
        doc = sites.find_one({"_id": host})
        if doc is None:
            verdict = classify(host, str(body.get("title") or "")[:200])
            if verdict is None:
                return jsonify(error="not classified yet"), 503  # the helper keeps the request and retries
            doc = {"_id": host, "state": verdict["label"], "category": verdict["category"],
                   "reason": verdict["reason"], "source": "ai", "createdAt": now(), "updatedAt": now()}
            sites.update_one({"_id": host}, {"$setOnInsert": doc}, upsert=True)
            doc = sites.find_one({"_id": host})
        return jsonify(public(doc))

    @app.post("/api/dispute")
    def api_dispute():
        """A "needed for work" request. Claude decides on the spot; the parent reads about it in the daily summary."""
        require_device()
        body = request.get_json(silent=True) or {}
        host = clean_host(body.get("host"))
        reason = str(body.get("reason") or "").strip()[:500]
        if not host or not reason:
            return jsonify(error="host and reason are required"), 400
        request_id = re.sub(r"[^a-z0-9-]", "", str(body.get("id") or "").lower())[:64] or uuid.uuid4().hex
        wants_permanent = bool(body.get("permanent"))
        try:
            minutes = max(5, min(int(body.get("minutes") or 30), classifier.MAX_GRANT_MINUTES))
        except (TypeError, ValueError):
            minutes = 30

        def answer(entry: dict):
            site = sites.find_one({"_id": host})
            return jsonify(site=public(site), answer={
                "id": entry["_id"], "host": host, "decision": entry["decision"], "minutes": entry.get("grantedMinutes", 0),
                "explanation": entry.get("explanation", ""), "allowedUntil": entry.get("allowedUntil", "")})

        # The helper re-sends after a dropped connection: the same request must get the same answer, once.
        earlier = requests_log.find_one({"_id": request_id})
        if earlier:
            return answer(earlier)

        doc = sites.find_one({"_id": host})
        if doc is None:
            # On the parent's own list of distractions, so it was never sent for a label.
            doc = {"_id": host, "state": "distraction", "category": "", "reason": "", "source": "list",
                   "createdAt": now(), "updatedAt": now()}
            sites.insert_one(doc)

        moment = datetime.now(timezone.utc)
        day = local_day(moment)
        entry = {"_id": request_id, "host": host, "reason": reason, "requestedMinutes": minutes,
                 "wantsPermanent": wants_permanent, "at": iso(moment), "day": day,
                 "localTime": moment.astimezone(zone).strftime("%-I:%M %p"),
                 "who": f"{str(body.get('user') or 'Your child')[:60]} on {str(body.get('device') or 'their Mac')[:80]}",
                 "grantedMinutes": 0}

        if doc["state"] == "locked":
            entry.update(decision="deny", explanation="Your parent decided this site stays a distraction, so it cannot be approved here.")
        elif doc["state"] in ("productive", "allowed"):
            entry.update(decision="approve_permanent", explanation="This site is already not counted as a distraction.")
        elif requests_log.count_documents({"host": host, "day": day}) >= MAX_REQUESTS_PER_SITE_PER_DAY:
            entry.update(decision="deny", explanation="There have been several requests for this site today already. Talk to your parent if you still need it.")
        else:
            history = list(requests_log.find({"host": host}).sort("at", -1).limit(6))[::-1]
            # A site the parent listed themselves can be approved for a while, but only the parent can clear it for good.
            allow_permanent = doc.get("source") != "list" and not body.get("onParentList")
            verdict = review(host, doc.get("reason", ""), reason, minutes, wants_permanent, history, allow_permanent)
            if verdict is None:
                return jsonify(error="not reviewed yet"), 503  # the helper keeps the request and retries
            decision = verdict["decision"]
            if decision == "approve_permanent" and not allow_permanent:
                decision = "approve_temporary"
            granted = 0
            if decision == "approve_temporary":
                # Never more than was asked for, whatever the model says.
                granted = max(5, min(verdict.get("minutes") or minutes, minutes, classifier.MAX_GRANT_MINUTES))
                until = iso(moment + timedelta(minutes=granted))
                entry["allowedUntil"] = until
                sites.update_one({"_id": host}, {"$set": {"allowedUntil": until, "updatedAt": now()}})
            elif decision == "approve_permanent":
                sites.update_one({"_id": host}, {"$set": {"state": "productive", "source": "request", "updatedAt": now()},
                                                 "$unset": {"allowedUntil": ""}})
            entry.update(decision=decision, grantedMinutes=granted, explanation=verdict["explanation"][:600])

        try:
            requests_log.insert_one(entry)
        except DuplicateKeyError:
            entry = requests_log.find_one({"_id": request_id})
        return answer(entry)

    @app.post("/api/search")
    def api_search():
        """Labels one web search as work, distraction or personal.

        The search words are stored only for distraction searches. Work searches are counted, and personal
        ones are counted without their words or any hint of the topic, so a student can still look for help.
        """
        require_device()
        body = request.get_json(silent=True) or {}
        query = " ".join(str(body.get("query") or "").split())[:300]
        if not query:
            return jsonify(error="query is required"), 400
        search_id = re.sub(r"[^a-z0-9-]", "", str(body.get("id") or "").lower())[:64] or uuid.uuid4().hex

        def reply(entry: dict):
            return jsonify(id=entry["_id"], at=entry["at"], label=entry["label"], engine=entry.get("engine", ""),
                           reason=entry.get("reason", ""), text=entry.get("text", ""))

        earlier = searches.find_one({"_id": search_id})
        if earlier:
            return reply(earlier)
        task = str(body.get("task") or "")[:200]
        verdict = label_search(query, task)
        if verdict is None:
            return jsonify(error="not labelled yet"), 503  # the helper keeps the request and retries
        moment = datetime.now(timezone.utc)
        entry = {"_id": search_id, "at": iso(moment), "day": local_day(moment),
                 "localTime": moment.astimezone(zone).strftime("%-I:%M %p"),
                 "who": f"{str(body.get('user') or 'Your child')[:60]} on {str(body.get('device') or 'their Mac')[:80]}",
                 "engine": clean_host(body.get("engine")) or "", "label": verdict["label"], "inSprint": bool(task)}
        if verdict["label"] == "distraction":
            entry.update(text=query, reason=verdict["reason"], task=task)
        elif verdict["label"] == "work":
            entry["reason"] = verdict["reason"]
        try:
            searches.insert_one(entry)
        except DuplicateKeyError:
            entry = searches.find_one({"_id": search_id})
        return reply(entry)

    # --- Daily summary for the parent ---------------------------------------------------------

    def send_digest(day: str, force: bool = False) -> str:
        """Sends the summary for one local day, at most once. Returns what happened."""
        if not force:
            try:
                digests.insert_one({"_id": day, "claimedAt": now()})  # only one worker gets past this
            except DuplicateKeyError:
                return "already handled"
        start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=zone)
        entries = list(requests_log.find({"day": day}).sort("at", 1))
        new_sites = list(sites.find({"source": "ai", "createdAt": {"$gte": iso(start), "$lt": iso(start + timedelta(days=1))}})
                         .sort("_id", 1).limit(200))
        day_searches = list(searches.find({"day": day}).sort("at", 1))
        counts = {label: sum(1 for x in day_searches if x["label"] == label) for label in ("work", "distraction", "personal")}
        off_topic = [x for x in day_searches if x["label"] == "distraction"]
        # A day of nothing but schoolwork searches is not worth an email.
        if not entries and not new_sites and not off_topic:
            digests.update_one({"_id": day}, {"$set": {"result": "nothing to report"}})
            return "nothing to report"
        base = os.environ.get("PUBLIC_URL", "").rstrip("/")
        subject, body_html = mailer.digest_email(start.strftime("%A %-d %B"), entries, new_sites,
                                                 lambda host: f"{base}/decide?t={signer.dumps(host)}",
                                                 search_counts=counts, distraction_searches=off_topic)
        if send_email(os.environ.get("PARENT_EMAIL", ""), subject, body_html):
            digests.update_one({"_id": day}, {"$set": {"result": "sent", "sentAt": now()}}, upsert=True)
            return "sent"
        if not force:
            digests.delete_one({"_id": day})  # let the next pass try again
        return "email failed"

    @app.post("/api/digest")
    def api_digest():
        """Sends a day's summary right now (used for testing, or from an external scheduler)."""
        require_device()
        day = str((request.get_json(silent=True) or {}).get("day") or local_day())
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            return jsonify(error="day must be YYYY-MM-DD"), 400
        return jsonify(day=day, result=send_digest(day, force=True))

    def scheduler():
        while True:
            try:
                local = datetime.now(timezone.utc).astimezone(zone)
                if local.hour >= digest_hour:
                    send_digest(local.strftime("%Y-%m-%d"))
                # Catches up if the service was down at the end of yesterday.
                send_digest((local - timedelta(days=1)).strftime("%Y-%m-%d"))
            except Exception:
                logging.exception("digest scheduler")
            time.sleep(300)

    if start_scheduler:
        threading.Thread(target=scheduler, daemon=True, name="digest").start()

    @app.get("/api/sites")
    def api_sites():
        require_device()
        return jsonify(sites=[public(d) for d in sites.find({}).limit(5000)])

    def page(title: str, inner: str) -> str:
        return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{html.escape(title)}</title>
<style>
body{{font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;background:#f6f7f9;color:#1a1a1a;margin:0;padding:24px 16px}}
main{{max-width:520px;margin:0 auto;background:#fff;border-radius:12px;padding:24px;box-shadow:0 1px 3px rgba(0,0,0,.08)}}
h1{{font-size:20px;margin:0 0 4px}} .muted{{color:#666;font-size:14px}} blockquote{{margin:6px 0 16px;padding:10px 12px;background:#f3f4f6;border-radius:6px}}
button{{display:block;width:100%;margin:10px 0 0;padding:12px;border:0;border-radius:8px;font-size:16px;font-weight:600;color:#fff;cursor:pointer}}
.allow{{background:#15803d}} .distraction{{background:#b45309}} .pick{{outline:3px solid #1a1a1a;outline-offset:2px}}
small{{display:block;font-weight:400;font-size:13px;opacity:.9;margin-top:2px}}
</style></head><body><main>{inner}</main></body></html>"""

    def host_from_token(token) -> str:
        try:
            return signer.loads(token or "")
        except BadSignature:
            abort(403)

    @app.get("/decide")
    def decide_page():
        # Reading this page changes nothing, so link scanners in mail apps cannot make a decision by opening it.
        token = request.args.get("t", "")
        host = host_from_token(token)
        doc = sites.find_one({"_id": host}) or abort(404)
        picked = request.args.get("a", "")
        e = html.escape
        recent = list(requests_log.find({"host": host}).sort("at", -1).limit(3))
        history = "".join(
            f'<p class="muted">{e(r.get("day", ""))} {e(r.get("localTime", ""))} · {e(mailer.DECISION_LABEL.get(r["decision"], ""))}</p>'
            f'<blockquote>{e(r.get("reason", ""))}</blockquote>' for r in recent)
        window = f'<p class="muted">Approved until {e(doc["allowedUntil"])} (UTC)</p>' if doc.get("allowedUntil", "") > now() else ""
        buttons = "".join(
            f'<button class="{a}{" pick" if a == picked else ""}" name="a" value="{a}">{e(label)}<small>{e(detail)}</small></button>'
            for a, (label, detail) in DECISION_TEXT.items())
        inner = f"""<h1>{e(host)}</h1><p class="muted">Currently: {e(STATE_TEXT.get(doc["state"], doc["state"]))}</p>
{window}{f'<p class="muted">Why it was labelled</p><p>{e(doc.get("reason", ""))}</p>' if doc.get("reason") else ''}
{history}
<form method="post" action="/decide"><input type="hidden" name="t" value="{e(token)}">{buttons}</form>"""
        return page(f"Decide: {host}", inner)

    @app.post("/decide")
    def decide():
        host = host_from_token(request.form.get("t", ""))
        action = request.form.get("a", "")
        if action not in DECISIONS:
            abort(400)
        # The parent's word is final, so it also ends any approval window the reviewer granted.
        result = sites.update_one({"_id": host}, {"$set": {
            "state": DECISIONS[action], "source": "parent", "decidedAt": now(), "updatedAt": now()},
            "$unset": {"allowedUntil": ""}})
        if result.matched_count == 0:
            abort(404)
        label, detail = DECISION_TEXT[action]
        e = html.escape
        return page("Saved", f"""<h1>Saved: {e(label)}</h1><p><b>{e(host)}</b>. {e(detail)}</p>
<p class="muted">The Mac picks this up within a minute or two. To change it, open the link in the summary email again.</p>""")

    return app
