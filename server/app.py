"""YoungWonks Focus service, for many households.

- A household has an admin, optional co-admins, and members who are kids or other adults. Admins and adults sign
  in on the website (accounts are by invitation); kids do not have a sign-in.
- Each computer is linked to one member with a one-time pairing code. The Mac gets its own token; it never sees a
  database address or anyone's password.
- Everything a Mac sends is stored under that member. Admins and co-admins can see kids' records. An adult's
  records are private to that adult: nobody else in the household, and no other household, can read them.
- Claude labels websites and searches and reviews "needed for work" requests. Nothing is ever blocked.
- Admins get one summary email a day about the kids; each adult gets their own.
"""
import hashlib
import json
import logging
import os
import re
import secrets
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from bson.binary import Binary
from dotenv import load_dotenv
from flask import Flask, abort, g, jsonify, request
from itsdangerous import URLSafeSerializer, URLSafeTimedSerializer
from pymongo import MongoClient
from pymongo.errors import DuplicateKeyError

import accounts
import classifier
import dashboard
import mailer
import releases

# Local development: values come from server/.env (never committed). On Render they are real environment variables.
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
logging.basicConfig(level=logging.INFO)

HOST_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{0,63}\.(json|jpg|mp4)$")
MAX_UPLOAD_BYTES = 12 * 1024 * 1024
MAX_REQUESTS_PER_SITE_PER_DAY = 5
DEFAULT_SETTINGS = {
    "captureMode": "screenshot", "clipSeconds": 5, "trackAllDay": True,
    "distractionDomains": ["instagram.com", "youtube.com", "youtu.be", "tiktok.com", "espn.com", "nba.com", "nfl.com",
                           "bleacherreport.com", "twitch.tv", "netflix.com", "reddit.com", "x.com", "twitter.com",
                           "facebook.com", "snapchat.com", "discord.com", "hotstar.com", "cricbuzz.com", "espncricinfo.com"],
    "distractionApps": ["Instagram", "TikTok", "Discord", "Steam", "Messages", "TV", "Music", "Spotify"],
}


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now() -> str:
    return iso(datetime.now(timezone.utc))


def child_key(user: str) -> str:
    """A child is identified by their Mac login name. As a field name it cannot hold dots or dollar signs."""
    return re.sub(r"[.$\x00]", "_", user.strip())[:60] or "unknown"


def clean_host(raw) -> str | None:
    host = str(raw or "").strip().lower().rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    return host if HOST_RE.match(host) else None


def token_hash(token: str) -> str:
    """Device tokens are stored only as a hash, so a copy of the database cannot be used to act as a Mac."""
    return hashlib.sha256(token.encode()).hexdigest()


def mask_email(email: str) -> str:
    name, _, domain = email.partition("@")
    return f"{name[:1]}{'•' * max(1, min(6, len(name) - 1))}@{domain}"


class Service:
    """What the route modules share: the database, the AI and email functions, and per-family helpers."""

    def __init__(self, db, classify, review, label_search, send_email):
        self.db = db
        self.classify, self.review, self.label_search, self.send_email = classify, review, label_search, send_email
        secret = os.environ["SECRET_KEY"]
        self.signer = URLSafeSerializer(secret, salt="site-decision")
        self.timed = URLSafeTimedSerializer(secret, salt="account-link")
        self.public_url = os.environ.get("PUBLIC_URL", "").rstrip("/")
        self.default_zone = os.environ.get("TIMEZONE", "America/Los_Angeles")
        self.daily_ai_limit = int(os.environ.get("FAMILY_DAILY_AI_CALLS", "600"))

    def zone(self, family: dict) -> ZoneInfo:
        try:
            return ZoneInfo(family.get("timezone") or self.default_zone)
        except ZoneInfoNotFoundError:
            return ZoneInfo(self.default_zone)

    def local_day(self, family: dict, moment: datetime | None = None) -> str:
        return (moment or datetime.now(timezone.utc)).astimezone(self.zone(family)).strftime("%Y-%m-%d")

    def scope(self, member: dict) -> str:
        """Whose website list a member uses. Kids in a household share one, which the admins manage.
        Every adult has their own, which only they can see."""
        return f"k:{member['familyId']}" if member.get("kind") == "kid" else f"m:{member['_id']}"

    def site_id(self, scope: str, host: str) -> str:
        return f"{scope}|{host}"

    def site_public(self, doc: dict, member_id: str | None = None) -> dict:
        out = {"host": doc["host"], "state": doc["state"], "reason": doc.get("reason", ""),
               "category": doc.get("category", ""), "updatedAt": doc.get("updatedAt", "")}
        # An approved "needed for work" window belongs to the member who asked, so only their Mac is told about it.
        until = (doc.get("approvedFor") or {}).get(member_id or "")
        if until:
            out["allowedUntil"] = until
        return out

    def settings_for(self, family: dict, member: dict) -> dict:
        """Kids follow the household's settings, set by the admins. An adult follows their own."""
        chosen = family.get("settings") if member.get("kind") == "kid" else member.get("settings")
        return {**DEFAULT_SETTINGS, **(chosen or {})}

    def may_use_ai(self, fid: str) -> bool:
        """Each family has a daily allowance of AI calls, so one family cannot run up the bill for everyone."""
        key = f"{fid}|{datetime.now(timezone.utc).strftime('%Y-%m-%d')}"
        doc = self.db["usage"].find_one_and_update({"_id": key}, {"$inc": {"calls": 1}, "$setOnInsert": {"familyId": fid}},
                                                   upsert=True, return_document=True)
        return doc["calls"] <= self.daily_ai_limit


def create_app(db=None, classify=classifier.classify, review=classifier.review_request, send_email=mailer.send,
               start_scheduler=False, label_search=classifier.classify_search, latest_release=releases.latest,
               label_app=classifier.classify_app) -> Flask:
    app = Flask(__name__)
    secret = os.environ.get("SECRET_KEY", "")
    if not secret:
        raise RuntimeError("SECRET_KEY must be set")
    app.secret_key = secret  # signs the website's sign-in cookie
    app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_BYTES + 1024 * 1024
    if db is None:
        db = MongoClient(os.environ["MONGODB_URI"])[os.environ.get("MONGODB_DB", "focussprint")]
    svc = Service(db, classify, review, label_search, send_email)
    svc.latest_release = latest_release
    families, devices, sites, labels = db["families"], db["devices"], db["sites"], db["labels"]
    members = db["members"]
    requests_log, searches, digests = db["requests"], db["searches"], db["digests"]
    for collection, keys in ((devices, "tokenHash"), (db["sprintStarts"], [("memberId", 1), ("startedAt", -1)]),
                             (db["events"], "sprintId"), (sites, "scope"), (requests_log, [("memberId", 1), ("day", 1)]),
                             (searches, [("memberId", 1), ("day", 1)]), (members, "familyId")):
        try:
            collection.create_index(keys)
        except Exception:  # an index is a speed-up, never a reason not to start
            pass
    try:
        db["accounts"].create_index("email", unique=True)
    except Exception:
        pass

    # --- Which Mac is calling ---------------------------------------------------------------

    def require_device(need_member: bool = True):
        """Works out which computer is calling, which Mac login on it, and who that login belongs to.

        The computer is linked to a household once and has its own token. Each Mac login on it is then
        assigned to one member. The helper (which runs as root) names the login from who owns the files
        it is sending, so an app cannot claim to be someone else's login.
        """
        sent = request.headers.get("Authorization", "")
        device = devices.find_one({"tokenHash": token_hash(sent[7:]), "revoked": {"$ne": True}}) if sent.startswith("Bearer ") else None
        family = families.find_one({"_id": device["familyId"]}) if device else None
        if family is None:
            abort(401)
        login = " ".join(request.headers.get("X-Login", "").split())[:60]
        if not login:
            abort(400)
        key = child_key(login)
        entry = (device.get("logins") or {}).get(key)
        if entry is None:
            # A login the service has not heard of: note it, so an admin can assign it on the website.
            entry = {"login": login, "memberId": None, "firstSeen": now()}
            devices.update_one({"_id": device["_id"]}, {"$set": {f"logins.{key}": entry}})
        member = members.find_one({"_id": entry.get("memberId"), "familyId": family["_id"]}) if entry.get("memberId") else None
        g.fid, g.device, g.family, g.login, g.login_key, g.member = family["_id"], device, family, login, key, member
        g.label = f"{device.get('name') or 'Mac'} · {login}"
        version = request.headers.get("X-App-Version", "")
        version = version if re.fullmatch(r"\d+(\.\d+){0,3}", version) else ""
        if device.get("lastSeenAt", "") < iso(datetime.now(timezone.utc) - timedelta(minutes=1)) or (version and version != device.get("appVersion")):
            devices.update_one({"_id": device["_id"]}, {"$set": {"lastSeenAt": now(), **({"appVersion": version} if version else {})}})
        if member is None:
            if need_member:
                # Nothing from this login is accepted until someone says whose it is. The Mac keeps it queued.
                abort(409)
            return
        g.mid, g.scope = member["_id"], svc.scope(member)

    def who() -> tuple[str, str, str]:
        """The Mac login name, the computer, and a label for who a request comes from. All of it is what was
        set when the computer was linked and the login assigned, not anything the Mac claims."""
        return g.login, g.label, f"{g.member.get('name', 'Member')} on {g.label}"

    @app.get("/healthz")
    def healthz():
        return "ok"

    @app.get("/api/version")
    def api_version():
        """The newest published installer. Public: it says nothing about anyone, and a Mac checks the file itself."""
        return jsonify(latest_release() or {"version": "", "url": ""})

    def assign(device: dict, key: str, login: str, member_id: str | None, by: str):
        devices.update_one({"_id": device["_id"]}, {"$set": {f"logins.{key}": {
            "login": login, "memberId": member_id, "assignedAt": now(), "assignedBy": by,
            "firstSeen": ((device.get("logins") or {}).get(key) or {}).get("firstSeen", now())}}})

    svc.assign_login = assign

    def use_code(raw) -> dict | None:
        """Claims a pairing code. Each works once, for a few minutes."""
        code = re.sub(r"[^A-Z0-9]", "", str(raw or "").upper())
        if not code:
            return None
        return db["pairings"].find_one_and_update({"_id": code, "used": False, "expiresAt": {"$gt": now()}},
                                                  {"$set": {"used": True, "usedAt": now()}})

    @app.post("/api/pair")
    def api_pair():
        """Links a computer to a household with a code from the website, and assigns the login it was typed
        in to the person the code was made for."""
        body = request.get_json(silent=True) or {}
        if accounts.too_many_attempts(db, "pair"):
            return jsonify(error="Too many attempts. Try again in a few minutes."), 429
        pairing = use_code(body.get("code"))
        if pairing is None:
            accounts.note_attempt(db, "pair")
            return jsonify(error="That code is not valid, or it has expired. Get a new one on the website."), 400
        member = members.find_one({"_id": pairing["memberId"], "familyId": pairing["familyId"]}) or abort(400)
        token = secrets.token_urlsafe(32)
        name = " ".join(str(body.get("name") or "").split())[:80] or "Mac"
        login = " ".join(str(body.get("login") or "").split())[:60] or "user"
        devices.insert_one({"_id": uuid.uuid4().hex, "familyId": member["familyId"], "name": name, "tokenHash": token_hash(token),
                            "pairedAt": now(), "lastSeenAt": now(), "revoked": False,
                            "logins": {child_key(login): {"login": login, "memberId": member["_id"], "firstSeen": now(),
                                                          "assignedAt": now(), "assignedBy": "code"}}})
        return jsonify(token=token, account=accounts.link_label(db, member), device=name,
                       member={"name": member.get("name", ""), "kind": member.get("kind", "kid")})

    @app.post("/api/claim")
    def api_claim():
        """Says whose a Mac login is, on a computer that is already linked. Two ways:
        - a code from the website (the way an adult claims their own login), or
        - a kid's profile picked in the app, as long as no other login on this computer has taken it.
        A login that already belongs to someone can only be changed from the website."""
        require_device(need_member=False)
        if g.member is not None:
            return jsonify(error="This login is already assigned. A household admin can change it on the website."), 409
        body = request.get_json(silent=True) or {}
        if body.get("code"):
            if accounts.too_many_attempts(db, "pair"):
                return jsonify(error="Too many attempts. Try again in a few minutes."), 429
            pairing = use_code(body.get("code"))
            member = members.find_one({"_id": pairing["memberId"], "familyId": g.fid}) if pairing else None
            if member is None:  # no such code, or a code from a different household
                accounts.note_attempt(db, "pair")
                return jsonify(error="That code is not valid for this computer, or it has expired."), 400
        else:
            member = members.find_one({"_id": str(body.get("member") or ""), "familyId": g.fid, "kind": "kid"})
            taken = {e.get("memberId") for e in (g.device.get("logins") or {}).values()}
            if member is None or member["_id"] in taken:
                return jsonify(error="That profile is not available on this computer."), 400
        assign(g.device, g.login_key, g.login, member["_id"], "code" if body.get("code") else "picked")
        return jsonify(member={"name": member.get("name", ""), "kind": member.get("kind", "kid")})

    @app.get("/api/config")
    def api_config():
        """What the Mac needs to know for one login: who it belongs to and the settings that apply. For a
        login nobody has been assigned to yet, the kid profiles it may pick from."""
        require_device(need_member=False)
        if g.member is None:
            taken = {e.get("memberId") for e in (g.device.get("logins") or {}).values()}
            return jsonify(device=g.device.get("name", ""), member=None,
                           profiles=[{"id": m["_id"], "name": m.get("name", "")}
                                     for m in members.find({"familyId": g.fid, "kind": "kid"}).sort("name", 1) if m["_id"] not in taken])
        return jsonify(account=accounts.link_label(db, g.member), device=g.device.get("name", ""),
                       member={"name": g.member.get("name", ""), "kind": g.member.get("kind", "kid")},
                       settings=svc.settings_for(g.family, g.member))

    @app.post("/api/upload/<session_id>/<name>")
    def api_upload(session_id, name):
        """Stores one record or picture from a Mac. Records are append-only: an existing one is never replaced."""
        require_device()
        if not SESSION_ID_RE.match(session_id) or not FILE_RE.match(name):
            return jsonify(error="invalid name"), 400
        data = request.get_data(cache=False)
        if not data or len(data) > MAX_UPLOAD_BYTES:
            return jsonify(error="empty or too large"), 400
        if name.endswith(".json"):
            try:
                doc = json.loads(data)
                assert isinstance(doc, dict)
            except (ValueError, AssertionError):
                return jsonify(error="not a JSON object"), 400
            if name in ("start.json", "end.json"):
                collection, doc["_id"] = db["sprintStarts" if name == "start.json" else "sprintEnds"], session_id
                if name == "start.json":
                    doc["device"], doc["user"] = g.label, g.login
            else:
                collection, doc["_id"], doc["sprintId"] = db["events"], f"{session_id}-{name[:-5]}", session_id
        else:
            collection = db["media"]
            doc = {"_id": f"{session_id}/{name}", "sprintId": session_id, "file": name, "size": len(data),
                   "contentType": "video/mp4" if name.endswith(".mp4") else "image/jpeg", "data": Binary(data)}
        doc["familyId"], doc["memberId"] = g.fid, g.mid
        try:
            collection.insert_one(doc)
        except DuplicateKeyError:
            # Already stored (a retry after a dropped connection) is fine; the same name under anyone else is not.
            existing = collection.find_one({"_id": doc["_id"]}, {"memberId": 1})
            if not existing or existing.get("memberId") != g.mid:
                return jsonify(error="conflict"), 409
        return jsonify(stored=True)

    # --- Website labels -----------------------------------------------------------------------

    def scoped_site(host: str, create_listed: bool = False) -> dict | None:
        """The calling member's entry for a site. A label Claude gave once is shared by everyone; decisions are not."""
        doc = sites.find_one({"_id": svc.site_id(g.scope, host)})
        if doc is None and create_listed:
            # On the member's own list of distractions, so it was never sent for a label.
            doc = {"_id": svc.site_id(g.scope, host), "familyId": g.fid, "scope": g.scope, "host": host, "state": "distraction",
                   "category": "", "reason": "", "source": "list", "createdAt": now(), "updatedAt": now()}
            sites.update_one({"_id": doc["_id"]}, {"$setOnInsert": doc}, upsert=True)
            doc = sites.find_one({"_id": doc["_id"]})
        return doc

    @app.post("/api/classify")
    def api_classify():
        require_device()
        host = clean_host((request.get_json(silent=True) or {}).get("host"))
        if not host:
            return jsonify(error="invalid host"), 400
        doc = scoped_site(host)
        if doc is None:
            label = labels.find_one({"_id": host})
            if label is None:
                if not svc.may_use_ai(g.fid):
                    return jsonify(error="daily limit reached"), 429
                verdict = classify(host, "")
                if verdict is None:
                    return jsonify(error="not classified yet"), 503  # the helper keeps the request and retries
                label = {"_id": host, "label": verdict["label"], "category": verdict["category"],
                         "reason": verdict["reason"], "createdAt": now()}
                labels.update_one({"_id": host}, {"$setOnInsert": label}, upsert=True)
                label = labels.find_one({"_id": host})
            doc = {"_id": svc.site_id(g.scope, host), "familyId": g.fid, "scope": g.scope, "host": host, "state": label["label"],
                   "category": label.get("category", ""), "reason": label.get("reason", ""), "source": "ai",
                   "createdAt": now(), "updatedAt": now()}
            sites.update_one({"_id": doc["_id"]}, {"$setOnInsert": doc}, upsert=True)
            doc = sites.find_one({"_id": doc["_id"]})
        return jsonify(svc.site_public(doc, g.mid))

    # --- Apps: one list per person (the kids of a household share theirs), like websites ---------

    BUNDLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,150}$")

    @app.post("/api/app")
    def api_app():
        """A Mac has seen an app in use for the first time. It gets a label: work, distraction or neutral
        (does not count). Claude decides from the app's name; a person can overrule it on the website."""
        require_device()
        body = request.get_json(silent=True) or {}
        bundle = str(body.get("bundleId") or "").strip()
        name = " ".join(str(body.get("name") or "").split())[:80]
        if not BUNDLE_RE.match(bundle) or not name:
            return jsonify(error="invalid app"), 400
        key = bundle.lower()
        doc_id = f"{g.scope}|{key}"
        doc = db["apps"].find_one({"_id": doc_id})
        if doc is None:
            listed = {a.lower() for a in svc.settings_for(g.family, g.member).get("distractionApps", [])}
            shared = db["appLabels"].find_one({"_id": key})
            if name.lower() in listed:
                label = {"label": "distraction", "reason": "On the list of distraction apps.", "source": "list"}
            elif shared is not None:
                label = {"label": shared["label"], "reason": shared.get("reason", ""), "source": "ai"}
            else:
                if not svc.may_use_ai(g.fid):
                    return jsonify(error="daily limit reached"), 429
                verdict = label_app(name, bundle)
                if verdict is None:
                    return jsonify(error="not labelled yet"), 503  # the helper keeps the request and retries
                db["appLabels"].update_one({"_id": key}, {"$setOnInsert": {"_id": key, "name": name, "label": verdict["label"],
                                                                           "reason": verdict["reason"], "createdAt": now()}}, upsert=True)
                label = {**verdict, "source": "ai"}
            doc = {"_id": doc_id, "familyId": g.fid, "scope": g.scope, "bundleId": bundle, "name": name, "state": label["label"],
                   "reason": label["reason"], "source": label["source"], "createdAt": now(), "updatedAt": now()}
            db["apps"].update_one({"_id": doc_id}, {"$setOnInsert": doc}, upsert=True)
            doc = db["apps"].find_one({"_id": doc_id})
        return jsonify(app_public(doc))

    def app_public(doc: dict) -> dict:
        return {"bundleId": doc["bundleId"], "name": doc.get("name", ""), "state": doc["state"], "reason": doc.get("reason", "")}

    def manages_kids() -> bool:
        """True when this Mac login belongs to a household admin or co-admin, who manage the kids' lists."""
        return db["accounts"].find_one({"memberId": g.mid, "familyId": g.fid, "role": {"$in": ["admin", "coadmin"]}}) is not None

    def app_lists() -> dict:
        """The login's own list. An adult may change theirs in the app; an admin also gets the kids' list to manage."""
        out = {"apps": [app_public(d) for d in db["apps"].find({"scope": g.scope}).limit(3000)],
               "canEdit": g.member.get("kind") != "kid"}
        if manages_kids():
            out["kids"] = [app_public(d) for d in db["apps"].find({"scope": f"k:{g.fid}"}).limit(3000)]
        return out

    @app.get("/api/apps")
    def api_apps():
        require_device()
        return jsonify(app_lists())

    @app.post("/api/applabel")
    def api_app_label():
        """A label changed in the desktop app. Which login is asking is established by the helper, not the app:
        an adult may change their own list, a household admin or co-admin also the kids' list. A kid's login cannot."""
        require_device()
        body = request.get_json(silent=True) or {}
        state, which = body.get("state"), body.get("list")
        if state not in ("work", "distraction", "neutral") or which not in ("mine", "kids"):
            return jsonify(error="invalid change"), 400
        if g.member.get("kind") == "kid" or (which == "kids" and not manages_kids()):
            return jsonify(error="This login cannot change that list."), 403
        scope = f"k:{g.fid}" if which == "kids" else g.scope
        changed = db["apps"].update_one({"_id": f"{scope}|{str(body.get('bundleId') or '').lower()}", "scope": scope}, {"$set": {
            "state": state, "source": "parent", "reason": "Set in the app.", "updatedAt": now()}})
        if changed.matched_count == 0:
            return jsonify(error="unknown app"), 404
        return jsonify(app_lists())

    @app.get("/api/sites")
    def api_sites():
        require_device()
        return jsonify(sites=[svc.site_public(d, g.mid) for d in sites.find({"scope": g.scope}).limit(5000)])

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
        stored_id = f"{g.fid}|{request_id}"
        wants_permanent = bool(body.get("permanent"))
        try:
            minutes = max(5, min(int(body.get("minutes") or 30), classifier.MAX_GRANT_MINUTES))
        except (TypeError, ValueError):
            minutes = 30

        def answer(entry: dict):
            site = sites.find_one({"_id": svc.site_id(g.scope, host)})
            return jsonify(site=svc.site_public(site, g.mid), answer={
                "id": request_id, "host": host, "decision": entry["decision"], "minutes": entry.get("grantedMinutes", 0),
                "explanation": entry.get("explanation", ""), "allowedUntil": entry.get("allowedUntil", "")})

        # The helper re-sends after a dropped connection: the same request must get the same answer, once.
        earlier = requests_log.find_one({"_id": stored_id})
        if earlier:
            return answer(earlier)

        doc = scoped_site(host, create_listed=True)
        user, device, label = who()
        moment = datetime.now(timezone.utc)
        day = svc.local_day(g.family, moment)
        entry = {"_id": stored_id, "familyId": g.fid, "memberId": g.mid, "member": g.member.get("name", ""),
                 "host": host, "reason": reason, "requestedMinutes": minutes,
                 "wantsPermanent": wants_permanent, "at": iso(moment), "ts": moment.timestamp(), "day": day,
                 "localTime": moment.astimezone(svc.zone(g.family)).strftime("%-I:%M %p"),
                 "user": user, "device": device, "who": label, "grantedMinutes": 0}

        if doc["state"] == "locked":
            entry.update(decision="deny", explanation=(
                "A household admin decided this site stays a distraction, so it cannot be approved here." if g.member.get("kind") == "kid"
                else "You set this site to always count as a distraction. Change that on the website if you want to."))
        elif doc["state"] in ("productive", "allowed"):
            entry.update(decision="approve_permanent", explanation="This site is already not counted as a distraction.")
        elif requests_log.count_documents({"memberId": g.mid, "host": host, "day": day}) >= MAX_REQUESTS_PER_SITE_PER_DAY:
            entry.update(decision="deny", explanation="There have been several requests for this site today already.")
        elif not svc.may_use_ai(g.fid):
            return jsonify(error="daily limit reached"), 429
        else:
            # Each member's request is judged on their own history with the site.
            history = list(requests_log.find({"memberId": g.mid, "host": host}).sort("at", -1).limit(6))[::-1]
            # A site on the household's own list can be approved for a while, but only a person can clear it for good.
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
                # The window belongs to the member who asked; it does not open the site for anyone else.
                sites.update_one({"_id": doc["_id"]}, {"$set": {f"approvedFor.{g.mid}": until, "updatedAt": now()}})
            elif decision == "approve_permanent":
                # For this list only: everyone else's label for the same site is untouched.
                sites.update_one({"_id": doc["_id"]}, {"$set": {"state": "productive", "source": "request", "updatedAt": now()},
                                                     "$unset": {"approvedFor": ""}})
            entry.update(decision=decision, grantedMinutes=granted, explanation=verdict["explanation"][:600])

        try:
            requests_log.insert_one(entry)
        except DuplicateKeyError:
            entry = requests_log.find_one({"_id": stored_id})
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
        stored_id = f"{g.fid}|{search_id}"

        def reply(entry: dict):
            return jsonify(id=search_id, at=entry["at"], label=entry["label"], engine=entry.get("engine", ""),
                           reason=entry.get("reason", ""), text=entry.get("text", ""))

        earlier = searches.find_one({"_id": stored_id})
        if earlier:
            return reply(earlier)
        if not svc.may_use_ai(g.fid):
            return jsonify(error="daily limit reached"), 429
        task = str(body.get("task") or "")[:200]
        user, device, label = who()
        verdict = label_search(query, task)
        if verdict is None:
            return jsonify(error="not labelled yet"), 503  # the helper keeps the request and retries
        moment = datetime.now(timezone.utc)
        entry = {"_id": stored_id, "familyId": g.fid, "memberId": g.mid, "member": g.member.get("name", ""),
                 "at": iso(moment), "ts": moment.timestamp(),
                 "day": svc.local_day(g.family, moment),
                 "localTime": moment.astimezone(svc.zone(g.family)).strftime("%-I:%M %p"),
                 "user": user, "device": device, "who": label,
                 "engine": clean_host(body.get("engine")) or "", "label": verdict["label"], "inSprint": bool(task)}
        if verdict["label"] == "distraction":
            entry.update(text=query, reason=verdict["reason"], task=task)
        elif verdict["label"] == "work":
            entry["reason"] = verdict["reason"]
        try:
            searches.insert_one(entry)
        except DuplicateKeyError:
            entry = searches.find_one({"_id": stored_id})
        return reply(entry)

    # --- Daily summary for each parent --------------------------------------------------------

    def send_digest(family: dict, day: str, force: bool = False, only_member: str | None = None) -> dict:
        """Sends a household's summaries for one of its local days, each at most once.

        The admins and co-admins get one email covering the kids. Every adult member gets their own, about
        themselves only. Returns what happened per summary.
        """
        fid = family["_id"]
        start = datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=svc.zone(family))
        everyone = list(members.find({"familyId": fid}))
        kids = [m for m in everyone if m.get("kind") == "kid"]
        plans = []
        if kids:
            admins = [a["email"] for a in db["accounts"].find({"familyId": fid, "role": {"$in": ["admin", "coadmin"]}, "verified": True})]
            plans.append(("kids", kids, f"k:{fid}", admins, True))
        for adult in (m for m in everyone if m.get("kind") != "kid"):
            account = db["accounts"].find_one({"memberId": adult["_id"], "verified": True})
            if account:
                plans.append((adult["_id"], [adult], f"m:{adult['_id']}", [account["email"]], False))
        results = {}
        for name, people, scope, recipients, about_kids in plans:
            if only_member and only_member not in [p["_id"] for p in people]:
                continue
            key = f"{fid}|{name}|{day}"
            if not force:
                try:
                    digests.insert_one({"_id": key, "familyId": fid, "claimedAt": now()})  # only one worker gets past this
                except DuplicateKeyError:
                    results[name] = "already handled"
                    continue
            ids = [p["_id"] for p in people]
            # Everything in the summary is listed newest first.
            entries = list(requests_log.find({"memberId": {"$in": ids}, "day": day}).sort([("at", -1), ("ts", -1)]))
            day_searches = list(searches.find({"memberId": {"$in": ids}, "day": day}).sort([("at", -1), ("ts", -1)]))
            new_sites = list(sites.find({"scope": scope, "source": "ai",
                                         "createdAt": {"$gte": iso(start), "$lt": iso(start + timedelta(days=1))}})
                             .sort("createdAt", -1).limit(200))
            sections = []
            for person in sorted(people, key=lambda p: p.get("name", "")):
                mine = [x for x in day_searches if x.get("memberId") == person["_id"]]
                section = {"name": person.get("name", "Member"), "requests": [r for r in entries if r.get("memberId") == person["_id"]],
                           "counts": {k: sum(1 for x in mine if x["label"] == k) for k in ("work", "distraction", "personal")},
                           "searches": [x for x in mine if x["label"] == "distraction"]}
                if section["requests"] or sum(section["counts"].values()):
                    sections.append(section)
            # A day of nothing but schoolwork or work searches is not worth an email.
            if not recipients or (not entries and not new_sites and not any(x["label"] == "distraction" for x in day_searches)):
                digests.update_one({"_id": key}, {"$set": {"result": "nothing to report"}})
                results[name] = "nothing to report"
                continue
            subject, body_html = mailer.digest_email(
                start.strftime("%A %-d %B"), entries, new_sites,
                lambda host, scope=scope: f"{svc.public_url}/decide?t={svc.signer.dumps([scope, host])}",
                children=sections, dashboard_url=f"{svc.public_url}/dashboard/day/{day}", about_kids=about_kids)
            sent = [send_email(to, subject, body_html) for to in recipients]
            if any(sent):
                digests.update_one({"_id": key}, {"$set": {"familyId": fid, "result": "sent", "sentAt": now()}}, upsert=True)
                results[name] = "sent"
            else:
                if not force:
                    digests.delete_one({"_id": key})  # let the next pass try again
                results[name] = "email failed"
        return results

    @app.post("/api/digest")
    def api_digest():
        """Sends the summary that covers the calling Mac's member for a day, right now (used for testing)."""
        require_device()
        day = str((request.get_json(silent=True) or {}).get("day") or svc.local_day(g.family))
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            return jsonify(error="day must be YYYY-MM-DD"), 400
        results = send_digest(g.family, day, force=True, only_member=g.mid)
        return jsonify(day=day, result=next(iter(results.values()), "nothing to report"))

    keep_days = max(1, int(os.environ.get("MEDIA_KEEP_DAYS", "14")))

    def cleanup_media() -> int:
        """Deletes pictures and clips older than MEDIA_KEEP_DAYS, for every family. Returns how many were removed.

        Only the picture files go. The record of every switch (site, times, how long) is kept, so the
        numbers for older days stay complete. A file's id starts with its session's date (yyyyMMdd).
        """
        cutoff = (datetime.now(ZoneInfo(svc.default_zone)) - timedelta(days=keep_days)).strftime("%Y%m%d")
        return db["media"].delete_many({"_id": {"$regex": r"^\d{8}-", "$lt": cutoff}}).deleted_count

    app.cleanup_media = cleanup_media
    app.media_keep_days = keep_days
    app.send_digest = send_digest

    def scheduler():
        last_cleanup = None
        while True:
            try:
                hour = datetime.now(timezone.utc).strftime("%Y-%m-%d %H")
                if hour != last_cleanup:  # once an hour is plenty
                    removed = cleanup_media()
                    last_cleanup = hour
                    if removed:
                        logging.info("removed %d picture(s) older than %d days", removed, keep_days)
            except Exception:
                logging.exception("media cleanup")
            for family in list(families.find({})):
                try:
                    local = datetime.now(timezone.utc).astimezone(svc.zone(family))
                    if local.hour >= int(family.get("digestHour", 21)):
                        send_digest(family, local.strftime("%Y-%m-%d"))
                    # Catches up if the service was down at the end of yesterday.
                    send_digest(family, (local - timedelta(days=1)).strftime("%Y-%m-%d"))
                except Exception:
                    logging.exception("digest for family %s", family["_id"])
            time.sleep(300)

    accounts.register(app, svc)
    dashboard.register(app, svc, keep_days)
    accounts.bootstrap_owner(svc)

    if start_scheduler:
        threading.Thread(target=scheduler, daemon=True, name="digest").start()
    return app
