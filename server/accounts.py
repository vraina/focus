"""Households and the people in them: sign-up by invitation, sign-in, roles, members, linking computers, settings.

A household has one admin, optional co-admins, and members who are kids or other adults.
- Admins and co-admins manage the household and can see the kids' records.
- An adult member signs in to see their own records. Nobody else can see an adult's records, admins included.
- Kids have no sign-in; their computers are linked by an admin.

Also the service owner's tools (inviting new households) and the one-time move of data recorded before
accounts existed.
"""
import hmac
import logging
import os
import re
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from functools import wraps
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from flask import abort, g, redirect, render_template, request, session, url_for
from itsdangerous import BadSignature, SignatureExpired
from werkzeug.security import check_password_hash, generate_password_hash

from pymongo.errors import DuplicateKeyError

import mailer
import releases

log = logging.getLogger(__name__)

MAX_FAILED_ATTEMPTS = 8
LOCKOUT_MINUTES = 15
MIN_PASSWORD = 10
PAIRING_MINUTES = 15
PAIRING_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # no 0/O or 1/I/L, so a code can be read aloud
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")
DECISIONS = {"allow": "allowed", "distraction": "locked"}  # deliberately no "block": nothing is ever blocked
DECISION_TEXT = {
    "allow": ("Always allow", "It will never count as a distraction."),
    "distraction": ("Always a distraction", "It counts as a distraction and \"needed for work\" requests for it are turned down."),
}
STATE_TEXT = {"productive": "Productive (labelled by AI)", "distraction": "Distraction", "allowed": "Always allowed",
              "locked": "Distraction (your decision)"}


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def client_ip() -> str:
    return (request.headers.get("X-Forwarded-For", request.remote_addr or "").split(",")[0]).strip()[:64]


def too_many_attempts(db, kind: str) -> bool:
    since = datetime.now(timezone.utc) - timedelta(minutes=LOCKOUT_MINUTES)
    return db["attempts"].count_documents({"ip": client_ip(), "kind": kind, "at": {"$gte": since}}) >= MAX_FAILED_ATTEMPTS


def note_attempt(db, kind: str):
    db["attempts"].insert_one({"ip": client_ip(), "kind": kind, "at": datetime.now(timezone.utc)})


def mask_email(email: str) -> str:
    name, _, domain = email.partition("@")
    return f"{name[:1]}{'•' * max(1, min(6, len(name) - 1))}@{domain}"


def link_label(db, member: dict) -> str:
    """What a linked Mac shows as its account: the adult's own address, or for a kid the household admin's.
    Always masked, so a child's Mac never displays a full sign-in email."""
    account = db["accounts"].find_one({"memberId": member["_id"]}) if member.get("kind") != "kid" else None
    account = account or db["accounts"].find_one({"familyId": member["familyId"], "role": "admin"})
    return mask_email(account["email"]) if account else "your household"


def clean_name(raw: str, fallback: str) -> str:
    return " ".join(str(raw or "").split())[:40] or fallback


def new_member(db, fid: str, name: str, kind: str) -> dict:
    member = {"_id": uuid.uuid4().hex, "familyId": fid, "name": name, "kind": kind, "createdAt": utcnow(), "settings": {}}
    db["members"].insert_one(member)
    return member


def new_account(db, fid: str, email: str, password: str, role: str, name: str, verified: bool) -> dict:
    """A sign-in, with the person's own (adult) member profile so they can link their own computers."""
    member = new_member(db, fid, name, "adult")
    account = {"_id": uuid.uuid4().hex, "familyId": fid, "memberId": member["_id"], "email": email, "role": role,
               "passwordHash": generate_password_hash(password), "verified": verified, "createdAt": utcnow()}
    db["accounts"].insert_one(account)
    return account


def new_household(db, default_zone: str, email: str, password: str, name: str, verified: bool, owner: bool = False) -> dict:
    family = {"_id": uuid.uuid4().hex, "createdAt": utcnow(), "timezone": default_zone,
              "digestHour": int(os.environ.get("DIGEST_HOUR", "21")), "settings": {}, "serviceOwner": owner}
    db["families"].insert_one(family)
    return new_account(db, family["_id"], email, password, "admin", name, verified)


def bootstrap_owner(svc):
    """Creates the service owner's household from PARENT_EMAIL / PARENT_PASSWORD the first time, and gives the
    owner's own profile everything recorded before accounts existed. Safe to run on every start."""
    db = svc.db
    email, password = os.environ.get("PARENT_EMAIL", "").strip().lower(), os.environ.get("PARENT_PASSWORD", "")
    if not email or not password:
        return
    account = db["accounts"].find_one({"email": email})
    if account is None:
        try:
            account = new_household(db, svc.default_zone, email, password, "Me", verified=True, owner=True)
            log.info("created the owner's household")
        except DuplicateKeyError:
            # The service runs as several worker processes that start together; another one got there first.
            account = db["accounts"].find_one({"email": email})
            if account is None:
                raise
    else:
        db["families"].update_one({"_id": account["familyId"]}, {"$set": {"serviceOwner": True}})
    fid, mid = account["familyId"], account["memberId"]
    # The move below is a one-time job. It reads through every stored record and picture to find ones from
    # before accounts existed, which is slow once there are many pictures; doing it on every start made each
    # restart of the service slower for no benefit.
    if db["meta"].find_one({"_id": "legacyMoved"}):
        return
    moved = 0
    # Earlier records came from the owner's own Mac, so they become the owner's own, private, records.
    for name in ("sprintStarts", "sprintEnds", "events", "media", "requests", "searches"):
        moved += db[name].update_many({"memberId": {"$exists": False}}, {"$set": {"familyId": fid, "memberId": mid}}).modified_count
    # Website entries used to be one shared list keyed by host. Each becomes an entry on the owner's own list,
    # and an AI label is also kept as the shared label everyone starts from.
    scope = f"m:{mid}"
    for old in list(db["sites"].find({"scope": {"$exists": False}})):
        host = old.get("host") or old["_id"]
        if old.get("source") == "ai" and old.get("state") in ("productive", "distraction"):
            db["labels"].update_one({"_id": host}, {"$setOnInsert": {
                "_id": host, "label": old["state"], "category": old.get("category", ""),
                "reason": old.get("reason", ""), "createdAt": old.get("createdAt", utcnow())}}, upsert=True)
        entry = {k: v for k, v in old.items() if k not in ("_id", "allowedUntil", "dispute", "approvedFor")}
        entry.update(_id=svc.site_id(scope, host), familyId=fid, scope=scope, host=host)
        db["sites"].update_one({"_id": entry["_id"]}, {"$setOnInsert": entry}, upsert=True)
        db["sites"].delete_one({"_id": old["_id"]})
        moved += 1
    if moved:
        log.info("moved %d earlier record(s) into the owner's own profile", moved)
    db["meta"].update_one({"_id": "legacyMoved"}, {"$set": {"at": utcnow(), "moved": moved}}, upsert=True)


def parse_settings(form) -> dict:
    """What gets captured and what counts as a distraction, from a settings form."""
    def number(name: str, low: int, high: int, fallback: int) -> int:
        try:
            return max(low, min(high, int(form.get(name, fallback))))
        except ValueError:
            return fallback

    def lines(name: str, limit: int) -> list[str]:
        return [x.strip()[:80] for x in form.get(name, "").splitlines() if x.strip()][:limit]

    domains = []
    for raw in lines("domains", 300):
        host = re.sub(r"^https?://", "", raw.lower()).split("/")[0].removeprefix("www.")
        if re.fullmatch(r"([a-z0-9-]+\.)+[a-z]{2,63}", host) and host not in domains:
            domains.append(host)
    return {"captureMode": "video" if form.get("captureMode") == "video" else "screenshot",
            "clipSeconds": number("clipSeconds", 2, 15, 5), "trackAllDay": form.get("trackAllDay") == "on",
            "distractionDomains": domains}


class StaleForm(Exception):
    """A form was submitted without the matching token."""


def register(app, svc):
    db = svc.db
    families, devices, accounts, members = db["families"], db["devices"], db["accounts"], db["members"]
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        # Only sent over HTTPS in production; plain http is allowed for a local run.
        SESSION_COOKIE_SECURE=svc.public_url.startswith("https://"),
        PERMANENT_SESSION_LIFETIME=timedelta(days=30),
    )

    def csrf_token() -> str:
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(24)
        return session["csrf"]

    def check_csrf():
        """Every form carries a token that must match the one in the visitor's cookie. When it does not (the page
        sat open past the cookie's life, or the browser did not keep the cookie) the person gets the form back
        with an explanation, not a bare error page. Nothing they submitted is acted on."""
        expected = session.get("csrf", "")
        if not expected or not hmac.compare_digest(request.form.get("csrf", ""), expected):
            raise StaleForm()

    @app.errorhandler(500)
    def went_wrong(error):
        """An unexpected failure: say so plainly, with a reference that is also in the service's log."""
        ref = secrets.token_hex(4)
        log.error("unexpected error %s on %s %s: %r", ref, request.method, request.path, getattr(error, "original_exception", error))
        if request.path.startswith("/api/"):
            return {"error": "unexpected error", "ref": ref}, 500
        return render_template("error.html", ref=ref), 500

    @app.errorhandler(StaleForm)
    def stale_form(_error):
        rule = app.url_map._rules_by_endpoint.get(request.endpoint or "", [None])[0]
        if rule is None or "GET" not in (rule.methods or ()):
            return redirect("/dashboard?again=1", code=303)
        keep = {k: v for k, v in request.args.items() if k in ("invite", "t")}
        if request.form.get("invite"):
            keep["invite"] = re.sub(r"[^A-Za-z0-9]", "", request.form["invite"])[:20]
        return redirect(url_for(request.endpoint, **(request.view_args or {}), **keep, again=1), code=303)

    def current_account() -> dict | None:
        aid = session.get("aid")
        return accounts.find_one({"_id": aid}) if aid else None

    def is_admin(account: dict) -> bool:
        return account.get("role") in ("admin", "coadmin")

    def visible_members(account: dict) -> list[dict]:
        """Whose records this person may read: admins see the kids and themselves; an adult sees only themselves."""
        own = members.find_one({"_id": account["memberId"]})
        kids = list(members.find({"familyId": account["familyId"], "kind": "kid"}).sort("name", 1)) if is_admin(account) else []
        return kids + ([own] if own else [])

    def signed_in(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            account = current_account()
            family = families.find_one({"_id": account["familyId"]}) if account else None
            if family is None:
                session.pop("aid", None)
                return redirect(url_for("login", next=request.path))
            request.account, request.family = account, family
            request.visible = visible_members(account)
            return view(*args, **kwargs)
        return wrapper

    def admins_only(view):
        @wraps(view)
        @signed_in
        def wrapper(*args, **kwargs):
            if not is_admin(request.account):
                abort(404)
            return view(*args, **kwargs)
        return wrapper

    # --- First-time setup: what is done, worked out from the real records ---------------------

    def setup_state() -> dict | None:
        """Where a household stands on first-time setup, for the reminders and the wizard. None for anyone
        who is not the household's admin: co-admins and invited adults join a household that already exists.

        Nothing here is a stored "finished" flag. Setup is complete when the household has at least one kid
        and at least one linked computer, so a household set up the old way never sees a reminder, and
        removing the only computer brings it back. The one thing that cannot be seen in the records is
        whether the app has been installed, so the parent's own "The app is installed" answer is kept."""
        account = current_account()
        if not account or account.get("role") != "admin":
            return None
        if getattr(g, "setup_state", None) is not None:
            return g.setup_state
        fid = account["familyId"]
        family = families.find_one({"_id": fid}) or {}
        kids = [m.get("name", "Kid") for m in members.find({"familyId": fid, "kind": "kid"}).sort("name", 1)]
        computers = [d.get("name", "Mac") for d in devices.find({"familyId": fid, "revoked": {"$ne": True}}).sort("pairedAt", 1)]
        installed = bool(computers) or bool((family.get("setup") or {}).get("installed"))
        steps = [
            {"key": "kids", "n": 1, "title": "Add your kids", "done": bool(kids), "next": "add your kids",
             "detail": ", ".join(kids) if kids else "First names only"},
            {"key": "install", "n": 2, "title": "Install the app on the Mac", "done": installed, "next": "install the app on the Mac",
             "detail": "Installed on the Mac" if installed else "On the Mac your kid uses"},
            {"key": "link", "n": 3, "title": "Link the Mac with a code", "done": bool(computers), "next": "link the Mac with a code",
             "detail": ", ".join(computers) if computers else "With a one-time code"}]
        upcoming = next((x for x in steps if not x["done"]), None)
        for x in steps:
            x["state"] = "done" if x["done"] else ("next" if x is upcoming else "todo")
        done = sum(1 for x in steps if x["done"])
        g.setup_state = {"steps": steps, "done": done, "left": 3 - done, "complete": bool(kids) and bool(computers),
                         "next": upcoming, "kids": kids, "computers": computers, "installed": installed}
        return g.setup_state

    WIZARD_STEPS = ("welcome", "kids", "install", "link", "done")
    INSTALL_EMAILS_PER_HOUR = 3
    CODE_EMAILS_PER_HOUR = 5

    def installer_url() -> str:
        """The same download the Computers page links to; empty when no installer has been published."""
        return os.environ.get("DOWNLOAD_URL", "") or (svc.latest_release() or {}).get("url", "")

    def first_open_step(state: dict) -> str:
        if not state["kids"]:
            return "kids" if (request.family.get("setup") or {}).get("started") else "welcome"
        return state["next"]["key"] if state["next"] else "done"

    @app.get("/setup")
    @signed_in
    def setup():
        """Opens setup at the first unfinished step."""
        state = setup_state()
        if state is None or state["complete"]:
            return redirect(url_for("overview"))
        return redirect(url_for("setup_step", step=first_open_step(state)))

    def kid_rows() -> list[dict]:
        """The household's kids, with whether each has a computer and whether it is still safe to remove them
        here (only a kid added by mistake: no computer linked and nothing recorded)."""
        fid = request.family["_id"]
        linked = {e.get("memberId") for d in devices.find({"familyId": fid, "revoked": {"$ne": True}}) for e in (d.get("logins") or {}).values()}
        rows = []
        for m in members.find({"familyId": fid, "kind": "kid"}).sort("name", 1):
            used = m["_id"] in linked or db["sprintStarts"].find_one({"memberId": m["_id"]}, {"_id": 1}) is not None
            rows.append({"id": m["_id"], "name": m.get("name", "Kid"), "linked": m["_id"] in linked, "removable": not used})
        return rows

    @app.route("/setup/<any(welcome, kids, install, link, done):step>", methods=["GET", "POST"])
    @signed_in
    def setup_step(step):
        """The first-time setup wizard. It adds nothing the site could not already do: each step uses the same
        actions as the People and Computers pages. Only the household admin gets it."""
        state = setup_state()
        if state is None:
            return redirect(url_for("overview"))
        account, family, fid = request.account, request.family, request.family["_id"]
        families.update_one({"_id": fid}, {"$set": {"setup.seen": True}})
        message = error = None
        code_sent = False

        if request.method == "POST":
            check_csrf()
            action = request.form.get("action", "")
            if step == "welcome":
                families.update_one({"_id": fid}, {"$set": {"setup.started": True}})
                return redirect(url_for("setup_step", step="kids"))
            if step == "kids":
                families.update_one({"_id": fid}, {"$set": {"setup.started": True}})
                if action == "add":
                    name = clean_name(request.form.get("name"), "")
                    if name:
                        new_member(db, fid, name, "kid")  # exactly what "Add a kid" on the People page does
                        return redirect(url_for("setup_step", step="kids"))
                    error = "Enter a first name."
                elif action == "remove":
                    kid = next((k for k in kid_rows() if k["id"] == request.form.get("member")), None)
                    if kid and kid["removable"]:
                        members.delete_one({"_id": kid["id"], "familyId": fid, "kind": "kid"})
                        return redirect(url_for("setup_step", step="kids"))
                    error = "That kid already has a computer or records, so they cannot be removed here. You can rename them on the People page."
                elif action == "next":
                    if members.count_documents({"familyId": fid, "kind": "kid"}):
                        return redirect(url_for("setup_step", step="install"))
                    error = "Add at least one kid to carry on."
            elif step == "install":
                if action == "installed":
                    families.update_one({"_id": fid}, {"$set": {"setup.installed": True}})
                    return redirect(url_for("setup_step", step="link"))
                if action == "email":
                    link = installer_url()
                    hour_ago = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
                    recent = [t for t in (family.get("setup") or {}).get("emails", []) if t > hour_ago]
                    if not link:
                        error = "The installer isn't available yet, so there is no link to send."
                    elif len(recent) >= INSTALL_EMAILS_PER_HOUR:
                        error = "That link has been emailed a few times already. Check your inbox, or try again in an hour."
                    else:
                        # Only ever to the signed-in parent's own address: there is no field for another one.
                        sent = svc.send_email(account["email"], *mailer.installer_email(link))
                        families.update_one({"_id": fid}, {"$set": {"setup.emails": recent + [utcnow()]}})
                        if sent:
                            message = f"Sent to {account['email']}. Open it on the Mac."
                        else:
                            error = "The email could not be sent just now. Use Copy link instead."
            elif step == "link":
                if action == "code":
                    make_pairing_code(request.form.get("member", ""))  # the Computers page's own code maker
                    return redirect(url_for("setup_step", step="link", member=request.form.get("member", "")))
                if action == "emailcode":
                    # Sends the code that is already on the screen. It is not remade or extended: still single use,
                    # still its normal expiry. Only ever to the signed-in parent's own address.
                    own = request.form.get("member", "") == account["memberId"]  # the admin's own Mac login
                    kid = members.find_one({"_id": request.form.get("member", ""), "familyId": fid,
                                            **({} if own else {"kind": "kid"})})
                    live = kid and db["pairings"].find_one({"createdBy": account["_id"], "memberId": kid["_id"], "used": False,
                                                            "expiresAt": {"$gt": utcnow()}})
                    hour_ago = (datetime.now(timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
                    recent = [t for t in (family.get("setup") or {}).get("codeEmails", []) if t > hour_ago]
                    if not live:
                        error = "That code has been used or has expired. Get a new one, then email it."
                    elif len(recent) >= CODE_EMAILS_PER_HOUR:
                        error = "Codes have been emailed a few times already. Check your inbox, or try again in an hour."
                    else:
                        until = datetime.strptime(live["expiresAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).astimezone(svc.zone(family))
                        sent = svc.send_email(account["email"], *mailer.code_email(
                            f"{live['_id'][:4]}-{live['_id'][4:]}", None if own else kid.get("name", "your kid"),
                            until.strftime("%-I:%M %p").lower()))
                        families.update_one({"_id": fid}, {"$set": {"setup.codeEmails": recent + [utcnow()]}})
                        if sent:
                            code_sent = True
                            message = f"Sent to {account['email']}."
                        else:
                            error = "The email could not be sent just now. Use Copy code instead."
                    request.picked_member = request.form.get("member", "")
                if action == "typed":
                    return redirect(url_for("setup_step", step="done" if setup_devices() else "link", member=request.form.get("member", ""), waiting=1))
            g.setup_state = None
            state = setup_state()

        # A step cannot be opened before the ones it depends on.
        if step in ("install", "link") and not state["kids"]:
            return redirect(url_for("setup_step", step="kids"))
        if step == "done" and not state["computers"]:
            return redirect(url_for("setup_step", step="link"))

        kids = kid_rows() if step in ("kids", "link", "done") else []
        ctx: dict = {}
        if step == "link":
            asked = request.args.get("member") or getattr(request, "picked_member", "")
            # The Mac being linked may be the parent's own, so "Me" is offered beside the kids. A code makes the
            # login it is typed into that person's: choosing a kid on the parent's own Mac would record the
            # parent as the kid.
            people = kids + [{"id": account["memberId"], "name": "Me", "me": True, "linked": False}]
            picked = next((k for k in people if k["id"] == asked), None) \
                or next((k for k in kids if not k["linked"]), kids[0])
            pairing = db["pairings"].find_one({"createdBy": account["_id"], "memberId": picked["id"], "used": False, "expiresAt": {"$gt": utcnow()}})
            if pairing is None and request.method == "GET" and not request.args.get("waiting"):
                pairing = make_pairing_code(picked["id"])  # opening the step shows a code straight away
            ctx = {"picked": picked, "people": people, "minutes": PAIRING_MINUTES, "still_waiting": bool(request.args.get("waiting")), "code_sent": code_sent,
                   "code": f"{pairing['_id'][:4]}-{pairing['_id'][4:]}" if pairing else "", "raw_code": pairing["_id"] if pairing else "",
                   "expires": pairing["expiresAt"] if pairing else ""}
        elif step == "done":
            newest = devices.find_one({"familyId": fid, "revoked": {"$ne": True}}, sort=[("pairedAt", -1)])
            names = {m["_id"]: m.get("name", "") for m in members.find({"familyId": fid})}
            first_login = next(iter((newest.get("logins") or {}).values()), {})
            ctx = {"computer": newest.get("name", "Mac"), "whose": names.get(first_login.get("memberId"), ""),
                   "unlinked": [k for k in kids if not k["linked"]]}
        rail = [{"n": x["n"], "done": x["done"],
                 "title": {"kids": "Add your kids", "install": "Install the app", "link": "Link the Mac"}[x["key"]],
                 "detail": x["detail"], "key": x["key"]} for x in state["steps"]]
        index = WIZARD_STEPS.index(step)
        return render_template("wizard.html", step=step, index=index, rail=rail, state=state, kids=kids, message=message, error=error,
                               download_url=installer_url(), my_email=account["email"], **ctx), (400 if error else 200)

    def setup_devices() -> bool:
        return devices.count_documents({"familyId": request.family["_id"], "revoked": {"$ne": True}}) > 0

    @app.get("/setup/code-status")
    @signed_in
    def setup_code_status():
        """Has this code been typed into the app yet? The link step asks every few seconds so it can move on by
        itself. Only the person who made the code can ask about it."""
        code = re.sub(r"[^A-Z0-9]", "", request.args.get("code", "").upper())
        pairing = db["pairings"].find_one({"_id": code, "createdBy": request.account["_id"]}) if code else None
        if pairing is None:
            return {"state": "none"}
        if pairing.get("used"):
            return {"state": "used", "device": pairing.get("deviceName", "")}
        return {"state": "expired" if pairing["expiresAt"] <= utcnow() else "waiting"}

    svc.signed_in, svc.check_csrf, svc.is_admin = signed_in, check_csrf, is_admin
    svc.setup_state = setup_state
    app.jinja_env.globals.update(setup_state=setup_state)
    app.jinja_env.globals.update(csrf_token=csrf_token, current_account=current_account, is_admin=is_admin,
                                 service_owner=lambda a: bool((families.find_one({"_id": a["familyId"]}) or {}).get("serviceOwner")))

    def start_session(account: dict):
        session.clear()
        session["aid"] = account["_id"]
        session.permanent = True

    def send_verification(account: dict) -> bool:
        link = f"{svc.public_url}{url_for('verify')}?t={svc.timed.dumps(['verify', account['_id']])}"
        return svc.send_email(account["email"], *mailer.verification_email(link))

    # --- Creating an account and signing in ---------------------------------------------------

    @app.route("/signup", methods=["GET", "POST"])
    def signup():
        """Creates a sign-in from an invitation: either for a brand-new household (the person becomes its admin)
        or to join an existing one as a co-admin or an adult member."""
        error = None
        values = {"invite": request.args.get("invite", ""), "email": "", "name": ""}
        if request.method == "GET" and values["invite"]:
            # Someone following an emailed invitation finds their address already filled in. It can be changed.
            invited = db["invites"].find_one({"_id": re.sub(r"[^A-Z0-9]", "", values["invite"].upper()), "usedBy": None})
            values["email"] = (invited or {}).get("email", "")
        if request.method == "POST":
            check_csrf()
            code = re.sub(r"[^A-Z0-9]", "", request.form.get("invite", "").upper())
            email = request.form.get("email", "").strip().lower()
            password = request.form.get("password", "")
            values = {"invite": code, "email": email, "name": request.form.get("name", "")}
            if too_many_attempts(db, "signup"):
                return render_template("signup.html", error=f"Too many attempts. Try again in {LOCKOUT_MINUTES} minutes.", values=values), 429
            if not EMAIL_RE.match(email):
                error = "Enter a valid email address."
            elif len(password) < MIN_PASSWORD:
                error = f"Choose a password of at least {MIN_PASSWORD} characters."
            elif accounts.find_one({"email": email}):
                error = "There is already an account for that email. Sign in instead."
            else:
                # Claiming the invitation and creating the account must not both succeed twice.
                claim = {"$set": {"usedBy": email, "usedAt": utcnow()}}
                joining = db["memberInvites"].find_one_and_update({"_id": code, "usedBy": None}, claim)
                founding = None if joining else db["invites"].find_one_and_update({"_id": code, "usedBy": None}, claim)
                if joining:
                    account = new_account(db, joining["familyId"], email, password, joining["role"],
                                          clean_name(request.form.get("name"), joining.get("name") or "Member"), verified=False)
                elif founding:
                    account = new_household(db, svc.default_zone, email, password, clean_name(request.form.get("name"), "Me"), verified=False)
                else:
                    note_attempt(db, "signup")
                    error = "That invitation code is not valid, or it has already been used."
                if not error:
                    # The confirmation email is sent without holding up the page. If email is not working (or
                    # not set up), do not strand the person behind a link that never arrives.
                    link = f"{svc.public_url}{url_for('verify')}?t={svc.timed.dumps(['verify', account['_id']])}"
                    aid = account["_id"]
                    svc.send_later(account["email"], *mailer.verification_email(link),
                                   then=lambda ok: None if ok else accounts.update_one({"_id": aid}, {"$set": {"verified": True}}))
                    start_session(account)
                    # Someone starting a household goes straight into setup; someone joining one has only
                    # their own computer to link.
                    return redirect(url_for("setup") if founding else url_for("computers"))
        return render_template("signup.html", error=error, values=values), (400 if error else 200)

    @app.get("/verify")
    def verify():
        try:
            kind, aid = svc.timed.loads(request.args.get("t", ""), max_age=3 * 86400)
            assert kind == "verify"
        except (BadSignature, SignatureExpired, ValueError, AssertionError):
            return render_template("notice.html", title="That link has expired",
                                   text="Sign in and ask for a new confirmation email from the Settings page."), 400
        accounts.update_one({"_id": aid}, {"$set": {"verified": True}})
        return render_template("notice.html", title="Email confirmed", text="Your daily summary will be sent to this address.",
                               link=url_for("overview"), link_text="Open the dashboard")

    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
            check_csrf()
            if too_many_attempts(db, "login"):
                return render_template("login.html", error=f"Too many attempts. Try again in {LOCKOUT_MINUTES} minutes."), 429
            account = accounts.find_one({"email": request.form.get("email", "").strip().lower()})
            # Check a hash even when the email is unknown, so the response takes the same time either way.
            stored = account["passwordHash"] if account else generate_password_hash("no such account")
            if check_password_hash(stored, request.form.get("password", "")) and account:
                start_session(account)
                target = request.args.get("next", "")
                return redirect(target if target.startswith("/dashboard") else url_for("overview"))
            note_attempt(db, "login")
            error = "That email or password is not right."
        return render_template("login.html", error=error), (401 if error else 200)

    @app.post("/logout")
    def logout():
        check_csrf()
        session.clear()
        return redirect(url_for("login"))

    @app.get("/")
    def home():
        return redirect(url_for("overview") if current_account() else url_for("login"))

    @app.route("/forgot", methods=["GET", "POST"])
    def forgot():
        if request.method == "POST":
            check_csrf()
            if not too_many_attempts(db, "forgot"):
                note_attempt(db, "forgot")
                account = accounts.find_one({"email": request.form.get("email", "").strip().lower()})
                if account:
                    # The token stops working once the password changes, so a reset link cannot be used twice.
                    token = svc.timed.dumps(["reset", account["_id"], account["passwordHash"][-12:]])
                    svc.send_email(account["email"], *mailer.reset_email(f"{svc.public_url}{url_for('reset')}?t={token}"))
            # The same answer whether or not the account exists.
            return render_template("notice.html", title="Check your email",
                                   text="If there is an account for that address, a link to choose a new password is on its way. It works for one hour.")
        return render_template("forgot.html")

    @app.route("/reset", methods=["GET", "POST"])
    def reset():
        token = request.values.get("t", "")
        try:
            kind, aid, mark = svc.timed.loads(token, max_age=3600)
            account = accounts.find_one({"_id": aid})
            assert kind == "reset" and account and account["passwordHash"][-12:] == mark
        except (BadSignature, SignatureExpired, ValueError, AssertionError):
            return render_template("notice.html", title="That link has expired", text="Ask for a new one.",
                                   link=url_for("forgot"), link_text="Reset my password"), 400
        error = None
        if request.method == "POST":
            check_csrf()
            password = request.form.get("password", "")
            if len(password) < MIN_PASSWORD:
                error = f"Choose a password of at least {MIN_PASSWORD} characters."
            else:
                accounts.update_one({"_id": aid}, {"$set": {"passwordHash": generate_password_hash(password), "verified": True}})
                start_session(account)
                return redirect(url_for("overview"))
        return render_template("reset.html", token=token, error=error), (400 if error else 200)

    # --- People: who is in the household ----------------------------------------------------------

    @app.route("/dashboard/people", methods=["GET", "POST"])
    @admins_only
    def people():
        fid, message, error = request.family["_id"], None, None
        if request.method == "POST":
            check_csrf()
            action, name = request.form.get("action"), clean_name(request.form.get("name"), "")
            if action == "kid":
                if name:
                    new_member(db, fid, name, "kid")
                    message = f"{name} was added. Link their computer under Computers."
                else:
                    error = "Enter a name."
            elif action == "invite":
                # Only the admin can hand out co-admin rights.
                role = "coadmin" if request.form.get("role") == "coadmin" and request.account["role"] == "admin" else "adult"
                code = "".join(secrets.choice(PAIRING_ALPHABET) for _ in range(10))
                db["memberInvites"].insert_one({"_id": code, "familyId": fid, "role": role, "name": name, "usedBy": None, "createdAt": utcnow()})
                message = "Invitation created. Send them the link below."
            elif action == "role" and request.account["role"] == "admin":
                role = "coadmin" if request.form.get("role") == "coadmin" else "adult"
                accounts.update_one({"_id": request.form.get("account"), "familyId": fid, "role": {"$ne": "admin"}}, {"$set": {"role": role}})
            elif action == "rename":
                # A kid's name; an adult's name is theirs to change.
                if name:
                    members.update_one({"_id": request.form.get("member"), "familyId": fid, "kind": "kid"}, {"$set": {"name": name}})
        logins = {a["memberId"]: a for a in accounts.find({"familyId": fid})}
        counts: dict = {}
        for d in devices.find({"familyId": fid, "revoked": {"$ne": True}}):
            for entry in (d.get("logins") or {}).values():
                if entry.get("memberId"):
                    counts[entry["memberId"]] = counts.get(entry["memberId"], 0) + 1
        role_text = {"admin": "Admin", "coadmin": "Co-admin", "adult": "Adult"}
        rows = [{"id": m["_id"], "name": m.get("name", ""), "kind": m.get("kind", "kid"), "computers": counts.get(m["_id"], 0),
                 "account": logins.get(m["_id"], {}).get("_id"), "email": logins.get(m["_id"], {}).get("email", ""),
                 "role": logins.get(m["_id"], {}).get("role", ""), "role_text": role_text.get(logins.get(m["_id"], {}).get("role"), "Kid")}
                for m in members.find({"familyId": fid}).sort([("kind", -1), ("name", 1)])]
        return render_template("people.html", people=rows, message=message, error=error,
                               invites=list(db["memberInvites"].find({"familyId": fid, "usedBy": None}).sort("createdAt", -1)),
                               signup_url=f"{svc.public_url}{url_for('signup')}", i_am_admin=request.account["role"] == "admin"), (400 if error else 200)

    # --- Computers: linking a Mac to a member -------------------------------------------------

    def assignable() -> list[dict]:
        """Who the signed-in person may assign a Mac login to: an admin to any kid or to themself; an adult
        only to themself. Nobody can assign a login to another adult, since that adult's records are private."""
        mine = request.account["memberId"]
        return [{"id": m["_id"], "label": "Me" if m["_id"] == mine else m.get("name", "")} for m in request.visible]

    @app.get("/dashboard/computers")
    @signed_in
    def computers():
        fid, zone = request.family["_id"], svc.zone(request.family)
        mine, admin_view = request.account["memberId"], is_admin(request.account)
        names = {m["_id"]: m for m in members.find({"familyId": fid})}
        choices = assignable()
        allowed = {c["id"] for c in choices}
        stale = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")

        def when(moment_text: str) -> str:
            if not moment_text:
                return "never"
            moment = datetime.strptime(moment_text[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).astimezone(zone)
            return moment.strftime("%-d %b, %-I:%M %p")

        release = svc.latest_release() or {}
        rows = []
        for d in devices.find({"familyId": fid, "revoked": {"$ne": True}}).sort("pairedAt", -1):
            logins = []
            for key, entry in sorted((d.get("logins") or {}).items()):
                member = names.get(entry.get("memberId"))
                private = bool(member) and member["_id"] not in allowed  # another adult's login
                logins.append({"key": key, "login": entry.get("login", key), "member": entry.get("memberId") or "",
                               "name": "an adult (private)" if private else ("Me" if member and member["_id"] == mine else (member or {}).get("name", "")),
                               "private": private, "waiting": member is None})
            # An adult member only sees a computer they use; admins see every computer in the household.
            if admin_view or any(l["member"] == mine for l in logins):
                rows.append({"id": d["_id"], "name": d.get("name", "Mac"), "logins": logins if admin_view else [l for l in logins if l["member"] == mine],
                             "paired": when(d.get("pairedAt", "")), "seen": when(d.get("lastSeenAt", "")), "quiet": d.get("lastSeenAt", "") < stale,
                             "version": d.get("appVersion", ""), "behind": releases.newer(release.get("version", ""), d.get("appVersion", "")) and bool(d.get("appVersion"))})
        code = db["pairings"].find_one({"createdBy": request.account["_id"], "used": False, "expiresAt": {"$gt": utcnow()}},
                                       sort=[("expiresAt", -1)])
        return render_template("computers.html", computers=rows, minutes=PAIRING_MINUTES, choices=choices, admin_view=admin_view,
                               code=f"{code['_id'][:4]}-{code['_id'][4:]}" if code else None,
                               code_for=next((c["label"] for c in choices if code and c["id"] == code["memberId"]), ""),
                               download_url=os.environ.get("DOWNLOAD_URL", "") or release.get("url", ""), latest=release.get("version", ""))

    def make_pairing_code(member_id: str) -> dict:
        """A new one-time code for one person's Mac login. The Computers page and the setup wizard both use this."""
        if member_id not in {c["id"] for c in assignable()}:
            abort(403)  # nobody can link a computer or a login to someone they are not responsible for
        db["pairings"].delete_many({"createdBy": request.account["_id"], "used": False})  # one live code at a time
        code = "".join(secrets.choice(PAIRING_ALPHABET) for _ in range(8))
        expires = (datetime.now(timezone.utc) + timedelta(minutes=PAIRING_MINUTES)).strftime("%Y-%m-%dT%H:%M:%SZ")
        pairing = {"_id": code, "familyId": request.family["_id"], "memberId": member_id, "createdBy": request.account["_id"],
                   "used": False, "expiresAt": expires, "createdAt": utcnow()}
        db["pairings"].insert_one(pairing)
        return pairing

    @app.post("/dashboard/computers/code")
    @signed_in
    def new_pairing_code():
        check_csrf()
        make_pairing_code(request.form.get("member") or request.account["memberId"])
        return redirect(url_for("computers"))

    @app.post("/dashboard/computers/<device_id>/assign")
    @signed_in
    def assign_login(device_id):
        """Says whose a Mac login is, from the website. This is how a parent sets up a child's login
        without ever being let into it."""
        check_csrf()
        device = devices.find_one({"_id": device_id, "familyId": request.family["_id"], "revoked": {"$ne": True}}) or abort(404)
        key = request.form.get("login", "")
        entry = (device.get("logins") or {}).get(key) or abort(404)
        allowed = {c["id"] for c in assignable()}
        target = request.form.get("member") or None
        # Only an admin reassigns, and never a login that belongs to another adult, nor to another adult.
        if not is_admin(request.account) or (entry.get("memberId") and entry["memberId"] not in allowed) or (target and target not in allowed):
            abort(403)
        svc.assign_login(device, key, entry.get("login", key), target, request.account["_id"])
        return redirect(url_for("computers"))

    @app.post("/dashboard/computers/<device_id>/remove")
    @signed_in
    def remove_computer(device_id):
        check_csrf()
        if not is_admin(request.account):
            abort(403)
        # Its token stops working at once. What it already uploaded stays.
        devices.update_one({"_id": device_id, "familyId": request.family["_id"]}, {"$set": {"revoked": True, "revokedAt": utcnow()}})
        return redirect(url_for("computers"))

    # --- Apps: how each app counts, per person ----------------------------------------------------

    APP_STATES = {"distraction": "Distraction", "work": "Work", "neutral": "Other"}

    def app_lists(account: dict, family: dict) -> list[dict]:
        """The kids of a household share one list, which admins manage. Every adult has their own, private one."""
        lists = [{"key": "kids", "label": "The kids' apps", "scope": f"k:{family['_id']}"}] if is_admin(account) else []
        lists.append({"key": "mine", "label": "My own apps", "scope": f"m:{account['memberId']}"})
        return lists

    @app.route("/dashboard/apps", methods=["GET", "POST"])
    @signed_in
    def apps_view():
        lists = app_lists(request.account, request.family)
        picked = next((x for x in lists if x["key"] == (request.form if request.method == "POST" else request.args).get("list", "")), lists[0])
        if request.method == "POST":
            check_csrf()
            state = request.form.get("state", "")
            doc_id = f"{picked['scope']}|{request.form.get('bundle', '').lower()}"
            if state in APP_STATES:
                # The scope comes from who is signed in, never from the form, so nobody can touch another list.
                db["apps"].update_one({"_id": doc_id, "scope": picked["scope"]}, {"$set": {
                    "state": state, "source": "parent", "reason": "Set on the website.", "updatedAt": utcnow()}})
            return redirect(url_for("apps_view", list=picked["key"]))
        rows = [{"bundle": d["bundleId"], "name": d.get("name", d["bundleId"]), "state": d["state"], "reason": d.get("reason", ""),
                 "by_person": d.get("source") == "parent"}
                for d in db["apps"].find({"scope": picked["scope"]}).sort("name", 1).limit(3000)]
        rows.sort(key=lambda r: r["name"].lower())
        groups = [
            {"key": "distraction", "short": "time here counts as away", "title": "Distractions", "pill": "bad", "empty": "No apps are marked as a distraction yet.",
             "detail": "Time in these apps counts as distraction, all day and during a sprint."},
            {"key": "work", "short": "never a distraction · ticked for sprints", "title": "Work apps", "pill": "good", "empty": "No apps are marked as work yet.",
             "detail": "Never a distraction. These are ticked automatically when a sprint is set up."},
            {"key": "neutral", "short": "never a distraction · not ticked for sprints", "title": "Other apps", "pill": "brand", "empty": "No other apps yet.",
             "detail": "Never a distraction. Utilities and everyday tools that are neither work nor play. They are not ticked for a sprint, "
                       "so switching to one during a sprint shows as a switch away unless it is ticked for that sprint."}]
        for group in groups:
            group["apps"] = [r for r in rows if r["state"] == group["key"]]
        hints = {"distraction": "Counts as distraction, all day", "work": "Not a distraction · ticked for sprints",
                 "neutral": "Not a distraction · not ticked for sprints"}
        return render_template("apps.html", groups=groups, any_apps=bool(rows), lists=lists, picked=picked["key"], states=APP_STATES, hints=hints)

    # --- Settings ------------------------------------------------------------------------------

    @app.route("/dashboard/settings", methods=["GET", "POST"])
    @signed_in
    def settings():
        account, family, message, error = request.account, request.family, None, None
        if request.method == "POST":
            check_csrf()
            form = request.form
            action = form.get("action")
            if action == "password":
                if not check_password_hash(account["passwordHash"], form.get("current", "")):
                    error = "The current password is not right."
                elif len(form.get("password", "")) < MIN_PASSWORD:
                    error = f"Choose a password of at least {MIN_PASSWORD} characters."
                else:
                    accounts.update_one({"_id": account["_id"]}, {"$set": {"passwordHash": generate_password_hash(form["password"])}})
                    message = "Password changed."
            elif action == "verify":
                message = "Confirmation email sent." if send_verification(account) else "The email could not be sent just now."
            elif action == "mine":
                # A person's own computers follow their own choices, whatever the household's settings for kids are.
                name = clean_name(form.get("name"), "")
                members.update_one({"_id": account["memberId"]}, {"$set": {"settings": parse_settings(form), **({"name": name} if name else {})}})
                message = "Saved. Your computers pick this up within a minute or two."
            elif action == "household" and is_admin(account):
                try:
                    ZoneInfo(form.get("timezone", ""))
                    zone_name = form["timezone"]
                except (ZoneInfoNotFoundError, ValueError, KeyError):
                    zone_name, error = family.get("timezone", svc.default_zone), "That time zone was not recognised, so it was left unchanged."
                try:
                    hour = max(0, min(23, int(form.get("digestHour", 21))))
                except ValueError:
                    hour = 21
                families.update_one({"_id": family["_id"]}, {"$set": {"timezone": zone_name, "digestHour": hour, "settings": parse_settings(form)}})
                message = None if error else "Saved. The kids' computers pick this up within a minute or two."
            account, family = accounts.find_one({"_id": account["_id"]}), families.find_one({"_id": family["_id"]})
        from app import DEFAULT_SETTINGS
        me = members.find_one({"_id": account["memberId"]}) or {}
        return render_template("settings.html", account=account, family=family, me=me,
                               kids={**DEFAULT_SETTINGS, **(family.get("settings") or {})},
                               mine={**DEFAULT_SETTINGS, **(me.get("settings") or {})},
                               message=message, error=error), (400 if error else 200)

    # --- The service owner: inviting new households -----------------------------------------------

    #: Everything a household owns, by collection. Cancelling a household removes all of it.
    HOUSEHOLD_COLLECTIONS = ("accounts", "members", "devices", "memberInvites", "pairings", "apps", "sites", "events", "media",
                             "requests", "searches", "sprintStarts", "sprintEnds", "usage", "digests")

    INVITE_EMAILS_PER_HOUR = 5

    def send_invitation(invite: dict) -> bool:
        """Emails an invitation to the address it was made for. At most a few an hour for one invitation."""
        cutoff = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
        if len([t for t in invite.get("sends") or [] if t > cutoff]) >= INVITE_EMAILS_PER_HOUR:
            return False
        link = f"{svc.public_url}{url_for('signup')}?invite={invite['_id']}"
        if not svc.send_email(invite["email"], *mailer.invitation_email(link, invite["_id"])):
            return False
        db["invites"].update_one({"_id": invite["_id"]}, {"$push": {"sends": utcnow()}})
        return True

    def owner_only():
        if not request.family.get("serviceOwner") or request.account["role"] != "admin":
            abort(404)

    @app.route("/dashboard/admin", methods=["GET", "POST"])
    @signed_in
    def admin():
        owner_only()
        if request.method == "POST":
            check_csrf()
            if request.form.get("action") == "revoke":
                # Only an invitation nobody has used can be revoked. A used one has a household behind it,
                # which is cancelled as a whole further down the page.
                code = re.sub(r"[^A-Z0-9]", "", request.form.get("code", "").upper())
                gone = db["invites"].delete_one({"_id": code, "usedBy": None}).deleted_count
                return redirect(url_for("admin", done="revoked" if gone else "kept"))
            if request.form.get("action") == "resend":
                code = re.sub(r"[^A-Z0-9]", "", request.form.get("code", "").upper())
                invite = db["invites"].find_one({"_id": code, "usedBy": None})
                if not invite or not invite.get("email"):
                    return redirect(url_for("admin", done="kept"))
                return redirect(url_for("admin", done="sent" if send_invitation(invite) else "unsent"))
            email = request.form.get("email", "").strip().lower()
            if not EMAIL_RE.match(email):
                return redirect(url_for("admin", done="bademail"))
            code = "".join(secrets.choice(PAIRING_ALPHABET) for _ in range(10))
            invite = {"_id": code, "usedBy": None, "createdAt": utcnow(), "email": email, "sends": []}
            db["invites"].insert_one(invite)
            return redirect(url_for("admin", done="sent" if send_invitation(invite) else "unsent"))
        computers_by = {row["_id"]: row["n"] for row in devices.aggregate([{"$match": {"revoked": {"$ne": True}}},
                                                                           {"$group": {"_id": "$familyId", "n": {"$sum": 1}}}])}
        people_by = {row["_id"]: row["n"] for row in members.aggregate([{"$group": {"_id": "$familyId", "n": {"$sum": 1}}}])}
        notes = {"sent": "The invitation was emailed.",
                 "unsent": "The invitation was created, but the email could not be sent. Send the sign-up link yourself, or try Send again.",
                 "bademail": "Enter the email address of the person you are inviting.",
                 "revoked": "The invitation was revoked. Its code no longer works.",
                 "kept": "That invitation has already been used, so it was not revoked. Cancel the household instead.",
                 "cancelled": "The household was cancelled and everything it had stored was deleted."}
        # The owner can see that a household exists and how big it is. Never what anyone in it recorded.
        return render_template("admin.html",
                               invites=list(db["invites"].find({}).sort("createdAt", -1).limit(200)),
                               households=[{"id": a["familyId"], "email": a["email"], "created": a.get("createdAt", "")[:10],
                                            "verified": a.get("verified"), "mine": a["familyId"] == request.family["_id"],
                                            "people": people_by.get(a["familyId"], 0), "computers": computers_by.get(a["familyId"], 0)}
                                           for a in accounts.find({"role": "admin"}).sort("createdAt", -1).limit(500)],
                               signup_url=f"{svc.public_url}{url_for('signup')}", message=notes.get(request.args.get("done", "")))

    @app.route("/dashboard/admin/cancel/<fid>", methods=["GET", "POST"])
    @signed_in
    def cancel_household(fid):
        """Deletes a household and everything stored for it. The owner confirms by typing its admin's email."""
        owner_only()
        family = families.find_one({"_id": fid})
        head = accounts.find_one({"familyId": fid, "role": "admin"})
        if not family or not head or family.get("serviceOwner") or fid == request.family["_id"]:
            abort(404)  # the owner's own household cannot be cancelled from here
        error = None
        if request.method == "POST":
            check_csrf()
            if request.form.get("confirm", "").strip().lower() != head["email"]:
                error = "That does not match the household's email, so nothing was deleted."
            else:
                emails = [a["email"] for a in accounts.find({"familyId": fid})]
                people = [m["_id"] for m in members.find({"familyId": fid})]
                for name in HOUSEHOLD_COLLECTIONS:
                    db[name].delete_many({"$or": [{"familyId": fid}, {"memberId": {"$in": people}}]})
                for scope in [f"k:{fid}"] + [f"m:{mid}" for mid in people]:
                    db["apps"].delete_many({"scope": scope})
                    db["sites"].delete_many({"scope": scope})
                # The invitation that started it goes too, so the list shows only what is live.
                db["invites"].delete_many({"usedBy": {"$in": emails}})
                families.delete_one({"_id": fid})
                return redirect(url_for("admin", done="cancelled"))
        return render_template("cancel.html", email=head["email"], error=error,
                               people=members.count_documents({"familyId": fid}),
                               computers=devices.count_documents({"familyId": fid, "revoked": {"$ne": True}}),
                               sign_ins=accounts.count_documents({"familyId": fid})), (400 if error else 200)

    # --- Overruling a website's label (linked from the summary email and the Websites page) --------

    def site_from_token(token: str) -> dict:
        try:
            scope, host = svc.signer.loads(token or "")
        except (BadSignature, ValueError, TypeError):
            abort(403)
        return db["sites"].find_one({"_id": svc.site_id(scope, host)}) or abort(404)

    @app.get("/decide")
    def decide_page():
        # Reading this page changes nothing, so link scanners in mail apps cannot make a decision by opening it.
        token = request.args.get("t", "")
        site = site_from_token(token)
        current = utcnow()
        asked_by = [m["_id"] for m in members.find({"familyId": site["familyId"]}) if svc.scope(m) == site["scope"]]
        names = {m["_id"]: m.get("name", "") for m in members.find({"_id": {"$in": asked_by}})}
        recent = list(db["requests"].find({"memberId": {"$in": asked_by}, "host": site["host"]}).sort("at", -1).limit(3))
        for r in recent:
            r["decisionLabel"] = mailer.DECISION_LABEL.get(r.get("decision"), "")
        return render_template("decide.html", site=site, token=token, picked=request.args.get("a", ""), choices=DECISION_TEXT,
                               state=STATE_TEXT.get(site["state"], site["state"]), recent=recent,
                               active=sorted(names.get(who, "someone") for who, until in (site.get("approvedFor") or {}).items() if until > current))

    @app.post("/decide")
    def decide():
        site = site_from_token(request.form.get("t", ""))
        action = request.form.get("a", "")
        if action not in DECISIONS:
            abort(400)
        # A person's word is final, so it also ends any approval window the reviewer granted.
        db["sites"].update_one({"_id": site["_id"]}, {"$set": {
            "state": DECISIONS[action], "source": "parent", "decidedAt": utcnow(), "updatedAt": utcnow()},
            "$unset": {"approvedFor": ""}})
        label, detail = DECISION_TEXT[action]
        return render_template("notice.html", title=f"Saved: {label}", text=f"{site['host']}. {detail} The Mac picks this up within a minute or two.")
