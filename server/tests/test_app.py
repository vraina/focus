"""Needs a MongoDB to talk to: set TEST_MONGODB_URI (a throwaway local mongod is enough)."""
import os
import re
import sys
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from pymongo import MongoClient

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
OWNER = "owner@example.com"
os.environ.update(SECRET_KEY="test-secret", PARENT_EMAIL=OWNER, PARENT_PASSWORD="owner-password-1",
                  PUBLIC_URL="http://localhost", TIMEZONE="UTC", FAMILY_DAILY_AI_CALLS="50")
os.environ.pop("RESEND_API_KEY", None)
from app import DEFAULT_SETTINGS, create_app  # noqa: E402

DEFAULT_APPS = DEFAULT_SETTINGS["distractionApps"]


class World:
    """A running service with stand-ins for Claude and email, plus helpers that act like a parent or a Mac."""

    def __init__(self, db):
        self.db, self.labelled, self.reviews, self.emails = db, [], [], []
        self.app = self.build()

    def build(self):
        def classify(host, title=""):
            self.labelled.append(host)
            if host == "flaky.example.com":
                return None
            bad = any(w in host for w in ("tube", "gram", "tiktok", "espn"))
            return {"label": "distraction" if bad else "productive", "category": "video", "reason": f"{host} verdict."}

        def review(host, label_reason, reason, minutes, wants_permanent, history, allow_permanent):
            self.reviews.append({"host": host, "history": len(history), "allow_permanent": allow_permanent})
            if "flaky" in reason:
                return None
            if "lecture" in reason:
                return {"decision": "approve_temporary", "minutes": 999, "explanation": "A lecture is a real need."}
            if "never a distraction" in reason:
                return {"decision": "approve_permanent", "minutes": 0, "explanation": "This is a reference site."}
            return {"decision": "deny", "minutes": 0, "explanation": "Say what you need it for."}

        def label_search(query, task=""):
            if "anxiety" in query:
                return {"label": "personal", "reason": "Private topic."}
            if "nba" in query.lower():
                return {"label": "distraction", "reason": "Sports scores are not schoolwork."}
            return {"label": "work", "reason": "Fits schoolwork."}

        def send(to, subject, body):
            self.emails.append({"to": to, "subject": subject, "body": body})
            return True

        def label_app(name, bundle):
            self.app_calls = getattr(self, "app_calls", 0) + 1
            if "steam" in bundle.lower():
                return {"label": "distraction", "reason": "A game launcher."}
            if "xcode" in name.lower():
                return {"label": "work", "reason": "A developer tool."}
            if "flaky" in name.lower():
                return None
            return {"label": "neutral", "reason": "A utility."}

        return create_app(db=self.db, classify=classify, review=review, send_email=send, label_search=label_search,
                          latest_release=lambda: {"version": "0.4.0", "url": "https://example.com/YoungWonksFocus.pkg"},
                          label_app=label_app)

    def browser(self):
        return self.app.test_client()

    @staticmethod
    def csrf(client, path="/login"):
        return re.search(r'name="csrf" value="([^"]+)"', client.get(path).get_data(as_text=True)).group(1)

    def sign_in(self, email=OWNER, password="owner-password-1", client=None):
        client = client or self.browser()
        response = client.post("/login", data={"csrf": self.csrf(client), "email": email, "password": password})
        return client, response

    def invite(self):
        """A code for a brand-new household, issued by the service owner."""
        owner, _ = self.sign_in()
        owner.post("/dashboard/admin", data={"csrf": self.csrf(owner, "/dashboard/admin"), "note": "test"})
        return self.db["invites"].find_one({"usedBy": None}, sort=[("createdAt", -1)])["_id"]

    def household(self, email, password="family-password-1", name="Pat"):
        """A new household, created the way a real person would: invitation, then sign-up. Returns its admin's browser."""
        return self.join(self.invite(), email, password, name)

    def join(self, code, email, password="family-password-1", name="Sam"):
        client = self.browser()
        response = client.post("/signup", data={"csrf": self.csrf(client, "/signup"), "invite": code, "name": name,
                                                "email": email, "password": password})
        assert response.status_code == 302, response.get_data(as_text=True)
        return client

    def add_kid(self, admin, name):
        admin.post("/dashboard/people", data={"csrf": self.csrf(admin, "/dashboard/people"), "action": "kid", "name": name})
        return self.db["members"].find_one({"name": name, "kind": "kid"}, sort=[("createdAt", -1)])["_id"]

    def invite_adult(self, admin, name, role="adult"):
        """An invitation to join an existing household; returns the code."""
        admin.post("/dashboard/people", data={"csrf": self.csrf(admin, "/dashboard/people"), "action": "invite", "name": name, "role": role})
        return self.db["memberInvites"].find_one({"name": name, "usedBy": None}, sort=[("createdAt", -1)])["_id"]

    def me(self, email):
        return self.db["accounts"].find_one({"email": email})["memberId"]

    def pair(self, client, member, name="Kid's Mac", expect=200, login="kid"):
        """Links a Mac to the household with a pairing code typed in one Mac login, which becomes that
        member's; returns the headers the helper then sends for that login."""
        made = client.post("/dashboard/computers/code", data={"csrf": self.csrf(client, "/dashboard/computers"), "member": member})
        if expect != 200:
            assert made.status_code == expect
            return None
        code = re.search(r'class="code">([A-Z0-9-]+)<', client.get("/dashboard/computers").get_data(as_text=True)).group(1)
        reply = self.browser().post("/api/pair", json={"code": code, "name": name, "login": login})
        assert reply.status_code == 200, reply.get_data(as_text=True)
        return {"Authorization": "Bearer " + reply.json["token"], "X-Login": login}

    @staticmethod
    def other_login(mac, login):
        """The same computer, a different Mac login."""
        return {**mac, "X-Login": login}


@pytest.fixture
def w():
    uri = os.environ.get("TEST_MONGODB_URI")
    if not uri:
        pytest.skip("TEST_MONGODB_URI not set")
    mongo = MongoClient(uri)
    name = f"focus_test_{uuid.uuid4().hex[:8]}"
    yield World(mongo[name])
    mongo.drop_database(name)


def stamp(hour=10, minute=0, second=0, days_ago=0):
    moment = datetime.now(timezone.utc).replace(hour=hour, minute=minute, second=second, microsecond=0) - timedelta(days=days_ago)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def session_id(days_ago=0, tail="abc123"):
    return (datetime.now(timezone.utc) - timedelta(days=days_ago)).strftime("%Y%m%d") + "-100000-" + tail


def upload_sprint(client, mac, sid, site="espn.com", away=120.0, user="sam", title="Scores", days_ago=0):
    ok = lambda r: (r.status_code == 200) or pytest.fail(r.get_data(as_text=True))
    ok(client.post(f"/api/upload/{sid}/start.json", headers=mac, json={
        "_id": sid, "task": "Algebra", "user": user, "device": "ignored", "plannedSeconds": 1500, "startedAt": stamp(days_ago=days_ago)}))
    ok(client.post(f"/api/upload/{sid}/e1.json", headers=mac, json={
        "seq": 1, "startedAt": stamp(second=10, days_ago=days_ago), "endedAt": stamp(second=40, days_ago=days_ago),
        "durationSeconds": away, "appName": "Chrome", "host": site, "title": title, "category": "distraction",
        "media": [{"role": "start", "kind": "image", "file": "e1-start.jpg"}]}))
    ok(client.post(f"/api/upload/{sid}/e1-start.jpg", headers=mac, data=b"\xff\xd8picture-of-" + site.encode(),
                   content_type="image/jpeg"))
    ok(client.post(f"/api/upload/{sid}/end.json", headers=mac, json={
        "endedAt": stamp(minute=25, days_ago=days_ago), "status": "completed", "awaySeconds": away, "switchCount": 1}))


def today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


# --- Accounts -------------------------------------------------------------------------------------

def test_sign_up_needs_an_unused_invitation(w):
    client = w.browser()
    form = {"csrf": w.csrf(client, "/signup"), "name": "Pat", "email": "new@example.com", "password": "long-enough-pw"}
    assert client.post("/signup", data={**form, "invite": "NOPE"}).status_code == 400
    code = w.invite()
    assert client.post("/signup", data={**form, "invite": code, "password": "short"}).status_code == 400
    assert client.post("/signup", data={**form, "invite": code, "email": "not-an-email"}).status_code == 400
    assert client.post("/signup", data={**form, "invite": code.lower()}).status_code == 302  # typed in lower case is fine
    assert client.get("/dashboard/computers").status_code == 200  # signed in straight away
    # The same code cannot create a second account, and the email cannot be registered twice.
    other = w.browser()
    again = {"csrf": w.csrf(other, "/signup"), "name": "X", "invite": code, "email": "second@example.com", "password": "long-enough-pw"}
    assert other.post("/signup", data=again).status_code == 400
    assert other.post("/signup", data={**again, "invite": w.invite(), "email": "new@example.com"}).status_code == 400
    # The person becomes the admin of a new household, with their own profile. Passwords are stored hashed.
    account = w.db["accounts"].find_one({"email": "new@example.com"})
    assert account["role"] == "admin" and "long-enough-pw" not in str(account)
    assert w.db["members"].find_one({"_id": account["memberId"]})["kind"] == "adult"
    assert not w.db["families"].find_one({"_id": account["familyId"]}).get("serviceOwner")
    # A confirmation email went out; its link confirms the address.
    link = re.search(r'href="http://localhost(/verify\?t=[^"]+)"', w.emails[-1]["body"]).group(1).replace("&amp;", "&")
    assert account["verified"] is False and client.get(link).status_code == 200
    assert w.db["accounts"].find_one({"email": "new@example.com"})["verified"] is True


def test_sign_in_sign_out_and_lockout(w):
    client, response = w.sign_in()
    assert response.status_code == 302 and client.get("/dashboard").status_code == 200
    client.post("/logout", data={"csrf": w.csrf(client, "/dashboard")})
    assert client.get("/dashboard").status_code == 302
    # A sign-in form posted without the page's token is refused.
    refused = w.browser().post("/login", data={"email": OWNER, "password": "owner-password-1"})
    assert refused.status_code == 303 and "again=1" in refused.headers["Location"] and "Set-Cookie" not in refused.headers
    guesser = w.browser()
    for _ in range(8):
        assert w.sign_in(password="guess", client=guesser)[1].status_code == 401
    assert w.sign_in(client=guesser)[1].status_code == 429  # even the right password has to wait


def test_password_reset_link_works_once(w):
    w.household("mum@example.com")
    client = w.browser()
    client.post("/forgot", data={"csrf": w.csrf(client, "/forgot"), "email": "mum@example.com"})
    link = re.search(r'href="http://localhost(/reset\?t=[^"]+)"', w.emails[-1]["body"]).group(1)
    token = link.split("t=")[1]
    before = len(w.emails)  # an unknown address gets the same page and no email
    assert client.post("/forgot", data={"csrf": w.csrf(client, "/forgot"), "email": "nobody@example.com"}).status_code == 200
    assert len(w.emails) == before
    assert client.get(link).status_code == 200
    assert client.post("/reset", data={"csrf": w.csrf(client, link), "t": token, "password": "brand-new-password"}).status_code == 302
    assert w.sign_in("mum@example.com", "brand-new-password")[1].status_code == 302
    assert w.sign_in("mum@example.com", "family-password-1")[1].status_code == 401
    assert w.browser().get(link).status_code == 400  # the link died when the password changed


def test_only_the_service_owner_invites_households_and_sees_no_records(w):
    admin = w.household("dad@example.com")
    assert admin.get("/dashboard/admin").status_code == 404
    upload_sprint(w.browser(), w.pair(admin, w.add_kid(admin, "Mia")), session_id(), site="secret-site.example.com")
    owner, _ = w.sign_in()
    page = owner.get("/dashboard/admin").get_data(as_text=True)
    assert "dad@example.com" in page and "2 people" in page and "1 computer" in page and "secret-site" not in page
    assert "secret-site" not in owner.get(f"/dashboard/day/{today()}").get_data(as_text=True)


# --- Roles: admin, co-admin, kids and other adults ------------------------------------------------------

def test_an_adults_records_are_private_even_from_admins(w):
    admin = w.household("mum@example.com", name="Mum")
    kid = w.add_kid(admin, "Mia")
    grandpa = w.join(w.invite_adult(admin, "Grandpa"), "grandpa@example.com", name="Grandpa")
    coadmin = w.join(w.invite_adult(admin, "Dad", role="coadmin"), "dad@example.com", name="Dad")
    assert w.db["accounts"].find_one({"email": "grandpa@example.com"})["role"] == "adult"
    assert w.db["accounts"].find_one({"email": "dad@example.com"})["role"] == "coadmin"

    client = w.browser()
    kid_mac = w.pair(admin, kid, "Mia's MacBook")
    grandpa_mac = w.pair(grandpa, w.me("grandpa@example.com"), "Grandpa's iMac")
    kid_sid, old_sid = session_id(tail="kid111"), session_id(tail="gpa222")
    upload_sprint(client, kid_mac, kid_sid, site="kidsite.example.com")
    upload_sprint(client, grandpa_mac, old_sid, site="grandpasite.example.com")
    client.post("/api/classify", json={"host": "youtube.com"}, headers=grandpa_mac)
    client.post("/api/search", json={"query": "NBA scores"}, headers=grandpa_mac)
    client.post("/api/dispute", json={"host": "youtube.com", "reason": "Physics lecture"}, headers=grandpa_mac)

    # Admin and co-admin see the kid, and nothing at all of Grandpa's: pages, pictures, websites, computers.
    for viewer in (admin, coadmin):
        for path in ("/dashboard", f"/dashboard/day/{today()}", f"/dashboard/day/{today()}?who=me", "/dashboard/sites",
                     "/dashboard/sites?list=mine", "/dashboard/computers", f"/dashboard/day/{today()}?who={w.me('grandpa@example.com')}"):
            page = viewer.get(path).get_data(as_text=True)
            assert all(x not in page for x in ("grandpasite", "youtube.com", "NBA scores", "Physics lecture")), path
        assert "kidsite.example.com" in viewer.get(f"/dashboard/day/{today()}").get_data(as_text=True)
        assert viewer.get(f"/dashboard/media/{old_sid}/e1-start.jpg").status_code == 404
        assert viewer.get(f"/dashboard/media/{kid_sid}/e1-start.jpg").status_code == 200
    # Grandpa sees his own day, and none of the kid's.
    mine = grandpa.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    assert all(x in mine for x in ("grandpasite.example.com", "NBA scores", "Physics lecture")) and "kidsite" not in mine
    assert "kidsite" not in grandpa.get(f"/dashboard/day/{today()}?who={kid}").get_data(as_text=True)
    assert grandpa.get(f"/dashboard/media/{old_sid}/e1-start.jpg").status_code == 200
    assert grandpa.get(f"/dashboard/media/{kid_sid}/e1-start.jpg").status_code == 404
    assert "youtube.com" in grandpa.get("/dashboard/sites").get_data(as_text=True)
    # An adult member cannot manage the household or link a computer to a kid.
    assert grandpa.get("/dashboard/people").status_code == 404
    assert w.pair(grandpa, kid, expect=403) is None
    # The Mac is told which kind of member it belongs to, so it can word things properly.
    assert client.get("/api/config", headers=grandpa_mac).json["member"] == {"name": "Grandpa", "kind": "adult"}
    assert client.get("/api/config", headers=kid_mac).json["member"] == {"name": "Mia", "kind": "kid"}

    # Summaries: the kids' one goes to admin and co-admin; Grandpa's goes to Grandpa alone.
    for email in ("mum@example.com", "dad@example.com", "grandpa@example.com"):
        w.db["accounts"].update_one({"email": email}, {"$set": {"verified": True}})
    client.post("/api/search", json={"query": "NBA draft"}, headers=kid_mac)
    w.emails.clear()
    assert client.post("/api/digest", json={}, headers=kid_mac).json["result"] == "sent"
    assert sorted(e["to"] for e in w.emails) == ["dad@example.com", "mum@example.com"]
    assert "NBA draft" in w.emails[0]["body"] and "NBA scores" not in w.emails[0]["body"] and "Physics lecture" not in w.emails[0]["body"]
    w.emails.clear()
    assert client.post("/api/digest", json={}, headers=grandpa_mac).json["result"] == "sent"
    assert [e["to"] for e in w.emails] == ["grandpa@example.com"]
    assert "NBA scores" in w.emails[0]["body"] and "NBA draft" not in w.emails[0]["body"] and "About you only" in w.emails[0]["body"]


def test_co_admin_rights(w):
    admin = w.household("mum@example.com")
    coadmin = w.join(w.invite_adult(admin, "Dad", role="coadmin"), "dad@example.com")
    # A co-admin manages kids like the admin does...
    kid = w.add_kid(coadmin, "Leo")
    assert w.pair(coadmin, kid) and "Leo" in admin.get("/dashboard/people").get_data(as_text=True)
    # ...but cannot hand out co-admin rights: an invitation they make is for an ordinary adult member.
    code = w.invite_adult(coadmin, "Aunt", role="coadmin")
    assert w.db["memberInvites"].find_one({"_id": code})["role"] == "adult"
    dad = w.db["accounts"].find_one({"email": "dad@example.com"})["_id"]
    form = {"csrf": w.csrf(coadmin, "/dashboard/people"), "action": "role", "account": dad, "role": "adult"}
    coadmin.post("/dashboard/people", data=form)
    assert w.db["accounts"].find_one({"_id": dad})["role"] == "coadmin"  # only the admin changes roles
    admin.post("/dashboard/people", data={**form, "csrf": w.csrf(admin, "/dashboard/people")})
    assert w.db["accounts"].find_one({"_id": dad})["role"] == "adult" and coadmin.get("/dashboard/people").status_code == 404
    # The admin's own role cannot be taken away through this form.
    mum = w.db["accounts"].find_one({"email": "mum@example.com"})["_id"]
    admin.post("/dashboard/people", data={**form, "csrf": w.csrf(admin, "/dashboard/people"), "account": mum})
    assert w.db["accounts"].find_one({"_id": mum})["role"] == "admin"
    # A member invitation is for one household only and works once.
    assert w.browser().post("/signup", data={"csrf": "", "invite": code}).status_code == 303  # sent back to the form; nothing created


# --- One Mac, several logins ------------------------------------------------------------------------

def test_each_mac_login_is_assigned_to_a_person(w):
    admin = w.household("mum@example.com", name="Mum")
    mia, leo = w.add_kid(admin, "Mia"), w.add_kid(admin, "Leo")
    client = w.browser()
    # Mum links the family iMac from her own login. That login is hers, and private.
    mum_login = w.pair(admin, w.me("mum@example.com"), "Den iMac", login="mum")
    mia_login, leo_login, dad_login = (w.other_login(mum_login, x) for x in ("mia", "leo", "dad"))

    # Mia's login has not been assigned: nothing from it is accepted, and the Mac is told to hold on to it.
    sid = session_id(tail="mia111")
    assert client.post(f"/api/upload/{sid}/start.json", headers=mia_login, json={"startedAt": stamp()}).status_code == 409
    assert client.post("/api/search", headers=mia_login, json={"query": "NBA scores"}).status_code == 409
    waiting = client.get("/api/config", headers=mia_login).json
    assert waiting["member"] is None and [p["name"] for p in waiting["profiles"]] == ["Leo", "Mia"]  # kids only: no adults to hide behind
    # It shows up for Mum on the website the first time it is used, as not assigned.
    page = admin.get("/dashboard/computers").get_data(as_text=True)
    assert "<b>mia</b>" in page and "Not assigned" in page

    # Mum assigns it from the website: Mia never has to let her into the login.
    device = w.db["devices"].find_one({"name": "Den iMac"})["_id"]
    assign = lambda who, login, member: who.post(f"/dashboard/computers/{device}/assign", data={
        "csrf": w.csrf(who, "/dashboard/computers"), "login": login, "member": member})
    assert assign(admin, "mia", mia).status_code == 302
    assert client.get("/api/config", headers=mia_login).json["member"] == {"name": "Mia", "kind": "kid"}
    upload_sprint(client, mia_login, sid, site="miasite.example.com")
    assert "Mia on Den iMac · mia" in admin.get(f"/dashboard/day/{today()}?who={mia}").get_data(as_text=True)

    # Leo picks his own profile in the app. Mia's is taken on this computer, and an adult's cannot be picked.
    assert [p["name"] for p in client.get("/api/config", headers=leo_login).json["profiles"]] == ["Leo"]
    assert client.post("/api/claim", headers=leo_login, json={"member": mia}).status_code == 400
    assert client.post("/api/claim", headers=leo_login, json={"member": w.me("mum@example.com")}).status_code == 400
    assert client.post("/api/claim", headers=leo_login, json={"member": leo}).json["member"]["name"] == "Leo"
    assert client.post("/api/claim", headers=leo_login, json={"member": leo}).status_code == 409  # only the website changes it after that
    assert assign(admin, "leo", mia).status_code == 302  # Mum can correct a wrong pick
    assert client.get("/api/config", headers=leo_login).json["member"]["name"] == "Mia"
    assign(admin, "leo", leo)

    # Dad is an adult member: he claims his own login with his own code, and it stays private from Mum.
    dad = w.join(w.invite_adult(admin, "Dad"), "dad@example.com", name="Dad")
    dad.post("/dashboard/computers/code", data={"csrf": w.csrf(dad, "/dashboard/computers")})
    code = re.search(r'class="code">([A-Z0-9-]+)<', dad.get("/dashboard/computers").get_data(as_text=True)).group(1)
    assert client.post("/api/claim", headers=dad_login, json={"code": code}).json["member"] == {"name": "Dad", "kind": "adult"}
    upload_sprint(client, dad_login, session_id(tail="dad222"), site="dadsite.example.com")
    for path in (f"/dashboard/day/{today()}", f"/dashboard/day/{today()}?who=me", "/dashboard"):
        assert "dadsite" not in admin.get(path).get_data(as_text=True)
    assert "dadsite.example.com" in dad.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    page = admin.get("/dashboard/computers").get_data(as_text=True)
    assert "Belongs to an adult (private)" in page
    # Mum cannot take over Dad's login, nor hand a login to Dad; Dad cannot assign anything.
    assert assign(admin, "dad", mia).status_code == 403 and assign(admin, "leo", w.me("dad@example.com")).status_code == 403
    assert assign(dad, "leo", "").status_code == 403
    assert w.db["devices"].find_one({"_id": device})["logins"]["dad"]["memberId"] == w.me("dad@example.com")
    # Dad sees the computer he uses, with only his own login listed.
    his = dad.get("/dashboard/computers").get_data(as_text=True)
    assert "Den iMac" in his and "<b>dad</b>" in his and "<b>mia</b>" not in his

    # A code from another household does not work on this computer.
    stranger = w.household("other@example.com")
    stranger.post("/dashboard/computers/code", data={"csrf": w.csrf(stranger, "/dashboard/computers")})
    other_code = re.search(r'class="code">([A-Z0-9-]+)<', stranger.get("/dashboard/computers").get_data(as_text=True)).group(1)
    assert client.post("/api/claim", headers=w.other_login(mum_login, "guest"), json={"code": other_code}).status_code == 400
    assert client.post("/api/config", headers={"Authorization": mum_login["Authorization"]}).status_code in (400, 405)


# --- Linking a Mac --------------------------------------------------------------------------------

def test_pairing_code_links_a_mac_once(w):
    admin = w.household("mum@example.com")
    kid = w.add_kid(admin, "Mia")
    admin.post("/dashboard/computers/code", data={"csrf": w.csrf(admin, "/dashboard/computers"), "member": kid})
    page = admin.get("/dashboard/computers").get_data(as_text=True)
    code = re.search(r'class="code">([A-Z0-9-]+)<', page).group(1)
    assert "Code for <b>Mia</b>" in page
    mac = w.browser()
    assert mac.post("/api/pair", json={"code": "ZZZZ-ZZZZ"}).status_code == 400
    reply = mac.post("/api/pair", json={"code": code.lower().replace("-", " "), "name": "Mia's  MacBook", "login": "mia"})
    assert reply.status_code == 200 and reply.json["device"] == "Mia's MacBook" and reply.json["member"]["kind"] == "kid"
    assert reply.json["account"].startswith("m") and "mum@" not in reply.json["account"]  # the Mac only learns a masked address
    assert mac.post("/api/pair", json={"code": code}).status_code == 400  # a code works once
    token = reply.json["token"]
    assert token not in str(list(w.db["devices"].find({})))  # only a hash of the token is kept
    headers = {"Authorization": "Bearer " + token, "X-Login": "mia"}
    config = mac.get("/api/config", headers=headers)
    assert config.status_code == 200 and config.json["device"] == "Mia's MacBook" and config.json["settings"]["captureMode"] == "screenshot"
    assert "Mia&#39;s MacBook" in admin.get("/dashboard/computers").get_data(as_text=True)
    # Removing the computer on the website stops its token at once.
    device = w.db["devices"].find_one({"name": "Mia's MacBook"})["_id"]
    admin.post(f"/dashboard/computers/{device}/remove", data={"csrf": w.csrf(admin, "/dashboard/computers")})
    assert mac.get("/api/config", headers=headers).status_code == 401


def test_expired_code_and_guessing_are_refused(w):
    admin = w.household("mum@example.com")
    admin.post("/dashboard/computers/code", data={"csrf": w.csrf(admin, "/dashboard/computers"), "member": w.add_kid(admin, "Mia")})
    w.db["pairings"].update_many({}, {"$set": {"expiresAt": "2020-01-01T00:00:00Z"}})
    code = w.db["pairings"].find_one({})["_id"]
    mac = w.browser()
    assert mac.post("/api/pair", json={"code": code}).status_code == 400
    for _ in range(8):
        mac.post("/api/pair", json={"code": "AAAA-AAAA"})
    assert mac.post("/api/pair", json={"code": "AAAA-AAAA"}).status_code == 429
    for path in ("/api/config", "/api/sites"):
        assert mac.get(path).status_code == 401
        assert mac.get(path, headers={"Authorization": "Bearer made-up", "X-Login": "mia"}).status_code == 401


# --- A Mac's records ------------------------------------------------------------------------------

def test_upload_and_dashboard(w):
    admin = w.household("mum@example.com")
    mac = w.pair(admin, w.add_kid(admin, "Mia"), name="Den iMac")
    client = w.browser()
    sid = session_id()
    upload_sprint(client, mac, sid, title="<script>alert(1)</script>")
    # Sending the same file again (a retry) is accepted and stores nothing new.
    assert client.post(f"/api/upload/{sid}/end.json", headers=mac, json={"status": "tampered"}).status_code == 200
    assert w.db["sprintEnds"].find_one({"_id": sid})["status"] == "completed"
    for bad in (f"/api/upload/{sid}/notes.txt", f"/api/upload/{sid}/..%2Fx.json", "/api/upload/bad id/start.json"):
        assert client.post(bad, headers=mac, data=b"x").status_code in (400, 404)
    assert client.post(f"/api/upload/{sid}/e2.json", headers=mac, data=b"not json").status_code == 400
    assert client.post(f"/api/upload/{sid}/start.json", json={}).status_code == 401

    page = admin.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    assert "espn.com" in page and "10:00:10 AM" in page and "2m 00s" in page and "92 percent focused" in page
    assert "Mia on Den iMac · kid" in page  # who, which computer and which login come from the link, not from what the Mac claims
    assert "<script>alert(1)</script>" not in page and "&lt;script&gt;" in page
    picture = admin.get(f"/dashboard/media/{sid}/e1-start.jpg")
    assert picture.status_code == 200 and picture.data.startswith(b"\xff\xd8") and "private" in picture.headers["Cache-Control"]
    assert "8%" in admin.get("/dashboard").get_data(as_text=True)  # 120s away of 1500s


def test_households_cannot_see_or_touch_each_other(w):
    mum, dad = w.household("mum@example.com"), w.household("dad@example.com")
    mum_mac, dad_mac = w.pair(mum, w.add_kid(mum, "Mia")), w.pair(dad, w.add_kid(dad, "Leo"))
    client = w.browser()
    mum_sid, dad_sid = session_id(tail="mum111"), session_id(tail="dad222")
    upload_sprint(client, mum_mac, mum_sid, site="mumsite.example.com")
    upload_sprint(client, dad_mac, dad_sid, site="dadsite.example.com")
    client.post("/api/classify", json={"host": "youtube.com"}, headers=mum_mac)
    client.post("/api/search", json={"query": "NBA scores"}, headers=mum_mac)
    client.post("/api/dispute", json={"host": "youtube.com", "reason": "Physics lecture"}, headers=mum_mac)

    for path in ("/dashboard", f"/dashboard/day/{today()}", "/dashboard/sites", "/dashboard/people", "/dashboard/computers"):
        page = dad.get(path).get_data(as_text=True)
        assert all(x not in page for x in ("mumsite", "youtube.com", "NBA scores", "Physics lecture", "Mia")), path
    assert "dadsite.example.com" in dad.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    # Another household's picture cannot be fetched even with its exact address, nor its member selected.
    assert dad.get(f"/dashboard/media/{mum_sid}/e1-start.jpg").status_code == 404
    mia = w.db["members"].find_one({"name": "Mia"})["_id"]
    assert "mumsite" not in dad.get(f"/dashboard/day/{today()}?who={mia}").get_data(as_text=True)
    assert w.pair(dad, mia, expect=403) is None
    # Nor can a Mac write into another household's session.
    assert client.post(f"/api/upload/{mum_sid}/e1.json", headers=dad_mac, json={"durationSeconds": 0}).status_code == 409
    assert w.db["events"].find_one({"_id": f"{mum_sid}-e1"})["host"] == "mumsite.example.com"
    assert client.get("/api/sites", headers=dad_mac).json["sites"] == []
    w.db["accounts"].update_many({}, {"$set": {"verified": True}})
    assert client.post("/api/digest", json={}, headers=mum_mac).json["result"] == "sent"
    assert w.emails[-1]["to"] == "mum@example.com" and "NBA scores" in w.emails[-1]["body"]
    assert client.post("/api/digest", json={}, headers=dad_mac).json["result"] == "nothing to report"


def test_a_label_is_shared_but_decisions_are_not(w):
    mum, dad = w.household("mum@example.com"), w.household("dad@example.com")
    mum_mac, dad_mac = w.pair(mum, w.add_kid(mum, "Mia")), w.pair(dad, w.add_kid(dad, "Leo"))
    client = w.browser()
    assert client.post("/api/classify", json={"host": "WWW.YouTube.com"}, headers=mum_mac).json["state"] == "distraction"
    assert client.post("/api/classify", json={"host": "youtube.com"}, headers=dad_mac).json["state"] == "distraction"
    assert w.labelled == ["youtube.com"]  # Claude was asked once for both households
    assert client.post("/api/classify", json={"host": "flaky.example.com"}, headers=mum_mac).status_code == 503
    assert client.post("/api/classify", json={"host": "localhost"}, headers=mum_mac).status_code == 400

    # Mum decides YouTube is always a distraction for her kids: that is her household's rule, not Dad's.
    link = re.search(r'href="(/decide\?t=[^"]+)"', mum.get("/dashboard/sites").get_data(as_text=True)).group(1).replace("&amp;", "&")
    token = link.split("t=")[1]
    assert mum.get(link).status_code == 200  # opening the link changes nothing
    assert client.get("/api/sites", headers=mum_mac).json["sites"][0]["state"] == "distraction"
    assert w.browser().post("/decide", data={"t": token, "a": "block"}).status_code == 400  # there is no way to block
    assert w.browser().post("/decide", data={"t": token, "a": "distraction"}).status_code == 200
    assert client.get("/api/sites", headers=mum_mac).json["sites"][0]["state"] == "locked"
    assert client.get("/api/sites", headers=dad_mac).json["sites"][0]["state"] == "distraction"
    assert w.browser().post("/decide", data={"t": token + "x", "a": "allow"}).status_code == 403
    ask = lambda mac: client.post("/api/dispute", json={"host": "youtube.com", "reason": "Physics lecture"}, headers=mac)
    assert ask(mum_mac).json["answer"]["decision"] == "deny"
    assert ask(dad_mac).json["answer"]["decision"] == "approve_temporary"


# --- "Needed for work" and searches ------------------------------------------------------------------

def test_requests_are_reviewed_per_member(w):
    admin = w.household("mum@example.com")
    mia, leo = w.add_kid(admin, "Mia"), w.add_kid(admin, "Leo")
    mac, leo_mac = w.pair(admin, mia), w.pair(admin, leo, "Leo's Mac")
    client = w.browser()
    ask = lambda host, reason, headers=mac, **extra: client.post("/api/dispute", headers=headers, json={
        "host": host, "reason": reason, "minutes": 45, **extra})
    client.post("/api/classify", json={"host": "youtube.com"}, headers=mac)
    first = ask("youtube.com", "Physics lecture for Thursday", id="req-1")
    answer = first.json["answer"]
    assert answer["decision"] == "approve_temporary" and answer["minutes"] == 45  # capped at what was asked, not the model's 999
    # The window is Mia's: her Mac is told about it, Leo's (same household, same list) is not.
    assert first.json["site"]["allowedUntil"] == answer["allowedUntil"]
    assert client.get("/api/sites", headers=mac).json["sites"][0]["allowedUntil"] == answer["allowedUntil"]
    assert "allowedUntil" not in client.get("/api/sites", headers=leo_mac).json["sites"][0]
    assert ask("youtube.com", "Physics lecture for Thursday", id="req-1").json["answer"] == answer and len(w.reviews) == 1
    assert ask("youtube.com", "flaky").status_code == 503 and ask("youtube.com", "").status_code == 400
    # A site on the household's own list can be approved for a while but never for good.
    listed = ask("espn.com", "it is never a distraction", permanent=True, onParentList=True)
    assert listed.json["answer"]["decision"] == "approve_temporary" and w.reviews[-1]["allow_permanent"] is False
    client.post("/api/classify", json={"host": "tiktok.com"}, headers=mac)  # labelled by AI, so it can be cleared for good
    forever = ask("tiktok.com", "it is never a distraction", permanent=True)
    assert forever.json["answer"]["decision"] == "approve_permanent" and forever.json["site"]["state"] == "productive"
    # Five requests for one site in a day, per member.
    for _ in range(5):
        ask("instagram.com", "please")
    assert ask("instagram.com", "Physics lecture").json["answer"]["decision"] == "deny"
    assert ask("instagram.com", "Physics lecture", headers=leo_mac).json["answer"]["decision"] == "approve_temporary"
    assert w.reviews[-1]["history"] == 0
    assert all("Confirm" in e["subject"] for e in w.emails)  # no email per request


def test_searches_keep_words_only_for_distractions(w):
    admin = w.household("mum@example.com")
    mac = w.pair(admin, w.add_kid(admin, "Mia"))
    w.db["accounts"].update_many({}, {"$set": {"verified": True}})
    client = w.browser()
    search = lambda query, **extra: client.post("/api/search", headers=mac, json={"query": query, "engine": "google.com", **extra})
    assert search("   ").status_code == 400
    assert search("quadratic formula", id="s1").json["text"] == ""
    fun = search("NBA scores <tonight>", id="s2", task="Algebra homework")
    assert fun.json["label"] == "distraction" and fun.json["text"] == "NBA scores <tonight>"
    private = search("how to deal with anxiety", id="s3")
    assert private.json["label"] == "personal" and private.json["text"] == "" and private.json["reason"] == ""
    assert "anxiety" not in str(list(w.db["searches"].find({})))
    assert search("NBA scores <tonight>", id="s2").json["at"] == fun.json["at"] and w.db["searches"].count_documents({}) == 3

    page = admin.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    assert "NBA scores &lt;tonight&gt;" in page and "1 private" in page and "anxiety" not in page and "quadratic" not in page
    assert client.post("/api/digest", json={}, headers=mac).json["result"] == "sent"
    body = w.emails[-1]["body"]
    assert "NBA scores &lt;tonight&gt;" in body and "<b>1</b> private" in body and "anxiety" not in body
    assert "http://localhost/dashboard/day/" in body and "About the kids" in body


def test_daily_ai_allowance_per_household(w):
    mum, dad = w.household("mum@example.com"), w.household("dad@example.com")
    mac, other_mac = w.pair(mum, w.add_kid(mum, "Mia")), w.pair(dad, w.add_kid(dad, "Leo"))
    client = w.browser()
    replies = [client.post("/api/search", headers=mac, json={"query": f"topic {i}"}).status_code for i in range(52)]
    assert replies[:50] == [200] * 50 and replies[50:] == [429, 429]
    assert client.post("/api/search", headers=other_mac, json={"query": "topic"}).status_code == 200  # another household is unaffected


# --- Settings, filters, clean-up, earlier data -------------------------------------------------------

def test_settings_reach_the_right_macs(w):
    admin = w.household("mum@example.com")
    kid_mac = w.pair(admin, w.add_kid(admin, "Mia"))
    own_mac = w.pair(admin, w.me("mum@example.com"), "Mum's Mac")
    form = {"csrf": w.csrf(admin, "/dashboard/settings"), "action": "household", "timezone": "Europe/London", "digestHour": "20",
            "captureMode": "video", "clipSeconds": "99", "domains": "https://www.Roblox.com/games\nnot a site\nroblox.com", "apps": "Steam\n\nMinecraft"}
    assert admin.post("/dashboard/settings", data=form).status_code == 200
    client = w.browser()
    household = {"captureMode": "video", "clipSeconds": 15, "trackAllDay": False,
                 "distractionDomains": ["roblox.com"], "distractionApps": DEFAULT_APPS}  # apps now have their own page
    assert client.get("/api/config", headers=kid_mac).json["settings"] == household
    # The admin's own Mac follows the admin's own choices, not the kids' settings.
    assert client.get("/api/config", headers=own_mac).json["settings"]["captureMode"] == "screenshot"
    admin.post("/dashboard/settings", data={"csrf": form["csrf"], "action": "mine", "name": "Mum", "captureMode": "screenshot",
                                            "trackAllDay": "on", "domains": "x.com", "apps": ""})
    assert client.get("/api/config", headers=own_mac).json["settings"]["distractionDomains"] == ["x.com"]
    assert client.get("/api/config", headers=kid_mac).json["settings"] == household
    family = w.db["families"].find_one({"_id": w.db["accounts"].find_one({"email": "mum@example.com"})["familyId"]})
    assert family["timezone"] == "Europe/London" and family["digestHour"] == 20
    assert admin.post("/dashboard/settings", data={**form, "timezone": "Mars/Olympus"}).status_code == 400
    wrong = {"csrf": form["csrf"], "action": "password", "current": "nope", "password": "another-long-pw"}
    assert admin.post("/dashboard/settings", data=wrong).status_code == 400
    assert admin.post("/dashboard/settings", data={**wrong, "current": "family-password-1"}).status_code == 200
    assert w.sign_in("mum@example.com", "another-long-pw")[1].status_code == 302
    # An adult member cannot change the kids' settings.
    grandpa = w.join(w.invite_adult(admin, "Grandpa"), "grandpa@example.com")
    grandpa.post("/dashboard/settings", data={**form, "csrf": w.csrf(grandpa, "/dashboard/settings"), "captureMode": "screenshot"})
    assert client.get("/api/config", headers=kid_mac).json["settings"] == household


def test_filter_by_kid_and_computer(w):
    admin = w.household("mum@example.com")
    mia, leo = w.add_kid(admin, "Mia"), w.add_kid(admin, "Leo")
    air, den, pro = w.pair(admin, mia, "Mia Air"), w.pair(admin, mia, "Den iMac"), w.pair(admin, leo, "Leo Pro")
    client = w.browser()
    upload_sprint(client, air, session_id(tail="aaa111"), site="tiktok.com", away=60.0)
    upload_sprint(client, den, session_id(tail="bbb222"), site="espn.com", away=120.0)
    upload_sprint(client, pro, session_id(tail="ccc333"), site="roblox.com", away=300.0)
    client.post("/api/search", json={"query": "NBA scores"}, headers=pro)
    day = f"/dashboard/day/{today()}"
    # The page always shows one person. With nobody chosen an admin lands on the first kid by name (Leo);
    # an old link that asks for everyone ("kids") gets the same page, not an error.
    default = admin.get(day).get_data(as_text=True)
    assert "Leo&#39;s day" in default and "roblox.com" in default and "tiktok.com" not in default and "All kids" not in default
    old_link = admin.get(day + "?who=kids")
    assert old_link.status_code == 200 and "Leo&#39;s day" in old_link.get_data(as_text=True)
    assert "Mia on Den iMac · kid" in admin.get(day + f"?who={mia}").get_data(as_text=True)
    only_mia = admin.get(day + f"?who={mia}").get_data(as_text=True)
    assert "tiktok.com" in only_mia and "espn.com" in only_mia and "roblox.com" not in only_mia and "NBA scores" not in only_mia and "3m 00s" in only_mia
    assert "Mia&#39;s day" in only_mia and "All computers" in only_mia  # two computers for one person: a choice of computer
    den_only = admin.get(day + f"?who={mia}&device=Den%20iMac%20%C2%B7%20kid").get_data(as_text=True)
    assert "espn.com" in den_only and "tiktok.com" not in den_only
    only_leo = admin.get(f"/dashboard?who={leo}").get_data(as_text=True)
    assert "20%" in only_leo and "1 distraction" in only_leo and f"who={leo}" in only_leo  # 300s away of 1500s
    assert "roblox.com" in only_leo and "tiktok.com" not in only_leo  # the front page is today's activity for the person chosen
    assert "Nothing recorded" in admin.get(day + "?who=me").get_data(as_text=True) or "No switches" in admin.get(day + "?who=me").get_data(as_text=True)


def test_old_pictures_are_removed_but_records_stay(w):
    admin = w.household("mum@example.com")
    mac = w.pair(admin, w.add_kid(admin, "Mia"))
    client = w.browser()
    old, recent = session_id(days_ago=20, tail="old111"), session_id(tail="new222")
    upload_sprint(client, mac, old, days_ago=20)
    upload_sprint(client, mac, recent)
    assert w.app.media_keep_days == 14 and w.app.cleanup_media() == 1 and w.app.cleanup_media() == 0
    assert w.db["media"].find_one({"_id": f"{old}/e1-start.jpg"}) is None and w.db["media"].find_one({"_id": f"{recent}/e1-start.jpg"})
    assert w.db["events"].count_documents({}) == 2
    old_day = (datetime.now(timezone.utc) - timedelta(days=20)).strftime("%Y-%m-%d")
    page = admin.get(f"/dashboard/day/{old_day}").get_data(as_text=True)
    assert "espn.com" in page and "Pictures are kept for 14 days" in page and "/dashboard/media/" not in page


def test_earlier_data_becomes_the_owners_own(w):
    # Records written before accounts existed carry no member.
    w.db["sprintStarts"].insert_one({"_id": "20260101-100000-legacy", "task": "Old sprint", "user": "sam", "device": "Mac",
                                     "plannedSeconds": 600, "startedAt": "2026-01-01T10:00:00Z"})
    w.db["media"].insert_one({"_id": "20260101-100000-legacy/e1-start.jpg", "data": b"x"})
    w.db["sites"].insert_one({"_id": "youtube.com", "state": "distraction", "source": "ai", "reason": "Video.", "allowedUntil": "x"})
    w.db["sites"].insert_one({"_id": "espn.com", "state": "locked", "source": "parent"})
    w.db["meta"].delete_many({})  # as on a service holding records from before accounts existed: the move has not run yet
    w.build()  # the service starting again
    w.build()  # and again: the move runs once, and a later start changes nothing
    owner = w.db["accounts"].find_one({"email": OWNER})
    assert owner["role"] == "admin" and owner["verified"] and w.db["families"].find_one({"_id": owner["familyId"]})["serviceOwner"]
    assert w.db["sprintStarts"].find_one({"_id": "20260101-100000-legacy"})["memberId"] == owner["memberId"]
    assert w.db["media"].find_one({})["memberId"] == owner["memberId"]
    mine = {s["host"]: s for s in w.db["sites"].find({"scope": f"m:{owner['memberId']}"})}
    assert mine["youtube.com"]["state"] == "distraction" and mine["espn.com"]["state"] == "locked" and "allowedUntil" not in mine["youtube.com"]
    assert w.db["labels"].find_one({"_id": "youtube.com"})["label"] == "distraction" and w.db["labels"].find_one({"_id": "espn.com"}) is None
    assert w.db["sites"].count_documents({"scope": {"$exists": False}}) == 0
    assert "Old sprint" in w.sign_in()[0].get("/dashboard/day/2026-01-01").get_data(as_text=True)
    w.build()  # and again: nothing is duplicated
    assert w.db["accounts"].count_documents({"email": OWNER}) == 1 and w.db["sites"].count_documents({}) == 2


def test_versions_and_the_installer_link(w):
    admin = w.household("mum@example.com")
    kid = w.add_kid(admin, "Mia")
    mac = w.pair(admin, kid, name="Mia's Mac")
    anyone = w.browser()
    assert anyone.get("/api/version").json == {"version": "0.4.0", "url": "https://example.com/YoungWonksFocus.pkg"}
    page = admin.get("/dashboard/computers").get_data(as_text=True)
    assert 'href="https://example.com/YoungWonksFocus.pkg"' in page and "pending" not in page  # version not known yet
    # The helper says which version it runs; an older one is shown as waiting for its update.
    assert anyone.get("/api/config", headers={**mac, "X-App-Version": "0.3.9"}).status_code == 200
    page = admin.get("/dashboard/computers").get_data(as_text=True)
    assert "version 0.3.9" in page and "Update to 0.4.0 pending" in page
    assert anyone.get("/api/config", headers={**mac, "X-App-Version": "0.10.0"}).status_code == 200  # 0.10 is newer than 0.4
    page = admin.get("/dashboard/computers").get_data(as_text=True)
    assert "version 0.10.0" in page and "pending" not in page
    anyone.get("/api/config", headers={**mac, "X-App-Version": "<b>1</b>"})  # nonsense is ignored
    assert w.db["devices"].find_one({"name": "Mia's Mac"})["appVersion"] == "0.10.0"


def test_a_form_without_its_cookie_comes_back_with_an_explanation(w):
    code = w.invite()
    first = w.browser()
    token = w.csrf(first, "/signup")
    # Another browser (or the same one having lost its cookie) submits the form: no bare error page.
    stranger = w.browser()
    reply = stranger.post(f"/signup?invite={code}", data={"csrf": token, "invite": code, "name": "Pat", "email": "pat@example.com",
                                                          "password": "family-password-1"})
    assert reply.status_code == 303 and f"invite={code}" in reply.headers["Location"] and "again=1" in reply.headers["Location"]
    page = stranger.get(reply.headers["Location"]).get_data(as_text=True)
    assert "Nothing was saved" in page and f'value="{code}"' in page
    assert w.db["accounts"].find_one({"email": "pat@example.com"}) is None and w.db["invites"].find_one({"_id": code})["usedBy"] is None
    # With no cookie at all, no value passes, whatever is sent.
    for guess in ("x", "", "None"):
        assert w.browser().post("/signup", data={"csrf": guess, "invite": code}).status_code == 303
        assert w.browser().post("/login", data={"csrf": guess, "email": OWNER, "password": "owner-password-1"}).status_code == 303
    # Trying again from the page they were sent back to works.
    again = stranger.post("/signup", data={"csrf": w.csrf(stranger, "/signup"), "invite": code, "name": "Pat",
                                           "email": "pat@example.com", "password": "family-password-1"})
    assert again.status_code == 302 and w.db["accounts"].find_one({"email": "pat@example.com"})
    # A signed-in action with a bad token is refused too, and lands back on the website.
    admin, _ = w.sign_in()
    refused = admin.post("/dashboard/computers/code", data={"csrf": "wrong", "member": "x"})
    assert refused.status_code == 303 and refused.headers["Location"].endswith("/dashboard?again=1")


def test_apps_are_labelled_once_and_a_person_can_overrule(w):
    admin = w.household("mum@example.com")
    kid = w.add_kid(admin, "Mia")
    mac = w.pair(admin, kid, name="Mia's Mac")
    c = w.browser()
    seen = lambda b, n: c.post("/api/app", json={"bundleId": b, "name": n}, headers=mac)
    assert seen("com.example.steamish", "Heroic").json["state"] == "distraction"
    assert seen("com.apple.dt.Xcode", "Xcode").json["state"] == "work"
    assert seen("com.apple.Preview", "Preview").json["state"] == "neutral"
    assert seen("com.spotify.client", "Spotify").json["state"] == "distraction"  # on the household's own list: no AI needed
    calls = w.app_calls
    assert seen("com.apple.dt.Xcode", "Xcode").json["state"] == "work" and w.app_calls == calls  # asked once
    assert seen("com.example.flaky", "Flaky").status_code == 503  # no answer yet: the Mac tries again later
    assert seen("../etc", "x").status_code == 400 and seen("com.ok.app", "").status_code == 400
    assert {a["bundleId"]: a["state"] for a in c.get("/api/apps", headers=mac).json["apps"]} == {
        "com.example.steamish": "distraction", "com.apple.dt.Xcode": "work", "com.apple.Preview": "neutral",
        "com.spotify.client": "distraction"}
    # The admin sees the kids' list and changes a label; the Mac is told.
    page = admin.get("/dashboard/apps").get_data(as_text=True)
    assert "Heroic" in page and "A game launcher." in page and "Preview" in page
    admin.post("/dashboard/apps", data={"csrf": w.csrf(admin, "/dashboard/apps"), "list": "kids", "bundle": "com.apple.Preview", "state": "work"})
    assert {a["bundleId"]: a["state"] for a in c.get("/api/apps", headers=mac).json["apps"]}["com.apple.Preview"] == "work"
    assert "Set by a person" in admin.get("/dashboard/apps").get_data(as_text=True)
    # The three-way switch is three radio buttons in the same form: same "state" field, and a Save button without JavaScript.
    page = admin.get("/dashboard/apps").get_data(as_text=True)
    assert page.count('type="radio" name="state" value="distraction"') == page.count('name="bundle"') >= 4
    assert 'type="radio" name="state" value="work" checked' in page and "<noscript><button" in page and "<select " not in page
    admin.post("/dashboard/apps", data={"csrf": w.csrf(admin, "/dashboard/apps"), "list": "kids", "bundle": "com.apple.Preview", "state": "nonsense"})
    assert w.db["apps"].find_one({"bundleId": "com.apple.Preview"})["state"] == "work"
    # Another household gets the shared label without a second AI call, and cannot see or change this household's list.
    other = w.household("dad@example.com")
    other_mac = w.pair(other, w.add_kid(other, "Leo"), name="Leo's Mac")
    calls = w.app_calls
    assert c.post("/api/app", json={"bundleId": "com.example.steamish", "name": "Heroic"}, headers=other_mac).json["state"] == "distraction"
    assert w.app_calls == calls
    other.post("/dashboard/apps", data={"csrf": w.csrf(other, "/dashboard/apps"), "list": "kids", "bundle": "com.apple.dt.Xcode", "state": "distraction"})
    assert {a["bundleId"]: a["state"] for a in c.get("/api/apps", headers=mac).json["apps"]}["com.apple.dt.Xcode"] == "work"
    assert "Xcode" not in other.get("/dashboard/apps").get_data(as_text=True)
    # An adult's own list is private: the admin's page for "mine" is the admin's own, and an adult's Mac has its own labels.
    assert "Heroic" not in admin.get("/dashboard/apps?list=mine").get_data(as_text=True)


def test_a_sprint_record_shows_apps_changed_from_the_defaults(w):
    admin = w.household("mum@example.com")
    kid = w.add_kid(admin, "Mia")
    mac = w.pair(admin, kid, name="Mia's Mac")
    c = w.browser()
    sid = session_id()
    start = {"_id": sid, "task": "Essay", "plannedSeconds": 1500, "startedAt": stamp(), "allowedApps": ["Pages", "Discord"],
             "allowedBundleIds": [], "allowedDomains": [], "captureMode": "screenshot", "addedApps": ["Discord"], "removedApps": ["Xcode"]}
    assert c.post(f"/api/upload/{sid}/start.json", json=start, headers=mac).status_code == 200
    page = admin.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    assert "Apps changed for this sprint" in page and "<b>Discord</b>" in page and "<b>Xcode</b>" in page


def test_labels_can_be_changed_from_an_admins_or_adults_own_mac(w):
    admin = w.household("mum@example.com")
    kid = w.add_kid(admin, "Mia")
    kid_mac = w.pair(admin, kid, name="Family Mac", login="mia")
    mum_mac = w.pair(admin, w.me("mum@example.com"), name="Mum's Mac", login="mum")
    dad = w.join(w.invite_adult(admin, "Dad"), "dad@example.com", name="Dad")  # an adult member, not an admin
    dad_mac = w.pair(dad, w.me("dad@example.com"), name="Dad's Mac", login="dad")
    c = w.browser()
    c.post("/api/app", json={"bundleId": "com.apple.Preview", "name": "Preview"}, headers=kid_mac)  # on the kids' list
    c.post("/api/app", json={"bundleId": "com.apple.Preview", "name": "Preview"}, headers=dad_mac)  # and on Dad's own
    change = lambda mac, which, state, bundle="com.apple.Preview": c.post(
        "/api/applabel", json={"bundleId": bundle, "state": state, "list": which}, headers=mac)
    # What each Mac is told: a kid cannot edit; an admin also gets the kids' list; another adult only their own.
    assert c.get("/api/apps", headers=kid_mac).json == {"apps": [{"bundleId": "com.apple.Preview", "name": "Preview", "state": "neutral", "reason": "A utility."}], "canEdit": False}
    mums = c.get("/api/apps", headers=mum_mac).json
    assert mums["canEdit"] and mums["apps"] == [] and [a["name"] for a in mums["kids"]] == ["Preview"]
    dads = c.get("/api/apps", headers=dad_mac).json
    assert dads["canEdit"] and "kids" not in dads and len(dads["apps"]) == 1
    # A kid's login cannot change anything; a non-admin adult cannot touch the kids' list.
    assert change(kid_mac, "mine", "work").status_code == 403 and change(kid_mac, "kids", "work").status_code == 403
    assert change(dad_mac, "kids", "work").status_code == 403
    assert c.get("/api/apps", headers=kid_mac).json["apps"][0]["state"] == "neutral"
    # The admin changes the kids' list from her own Mac: the kid's Mac is told, Dad's own list is untouched.
    reply = change(mum_mac, "kids", "distraction")
    assert reply.status_code == 200 and reply.json["kids"][0]["state"] == "distraction"
    assert c.get("/api/apps", headers=kid_mac).json["apps"][0]["state"] == "distraction"
    assert c.get("/api/apps", headers=dad_mac).json["apps"][0]["state"] == "neutral"
    # An adult changes their own list; nobody else's moves.
    assert change(dad_mac, "mine", "work").json["apps"][0]["state"] == "work"
    assert c.get("/api/apps", headers=kid_mac).json["apps"][0]["state"] == "distraction"
    assert change(mum_mac, "kids", "banana").status_code == 400 and change(mum_mac, "kids", "work", "com.not.seen").status_code == 404
    assert change(mum_mac, "mine", "work").status_code == 404  # her own list has no such app
    assert "Set in the app." in admin.get("/dashboard/apps").get_data(as_text=True)


def test_a_sprint_with_no_timer_is_shown_as_until_stopped(w):
    admin = w.household("mum@example.com")
    mac = w.pair(admin, w.add_kid(admin, "Mia"), name="Mia's Mac")
    c = w.browser()
    sid = session_id()
    start = {"_id": sid, "task": "Chemistry homework", "plannedSeconds": 0, "startedAt": stamp(), "allowedApps": [],
             "allowedBundleIds": [], "allowedDomains": [], "captureMode": "screenshot"}
    assert c.post(f"/api/upload/{sid}/start.json", json=start, headers=mac).status_code == 200
    page = admin.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    assert "Chemistry homework" in page and "until stopped" in page and "0 min planned" not in page
    end = {"_id": sid, "endedAt": stamp(hour=12), "status": "completed", "focusedSeconds": 6600.0, "awaySeconds": 600.0, "switchCount": 3}
    assert c.post(f"/api/upload/{sid}/end.json", json=end, headers=mac).status_code == 200
    page = admin.get(f"/dashboard/day/{today()}").get_data(as_text=True)
    assert "Completed" in page and "until stopped" in page


def test_the_front_page_is_todays_activity_with_a_graph_since_the_first_record(w):
    admin = w.household("mum@example.com")
    mac = w.pair(admin, w.add_kid(admin, "Mia"), name="Mia's Mac")
    c = w.browser()
    bars = lambda page: page.count('class="d ')
    page = admin.get("/dashboard").get_data(as_text=True)
    assert "Mia&#39;s day" in page and "Nothing recorded yet" in page and bars(page) == 0 and "Timeline" not in page
    assert page.count("Last 14 days") == 1 and page.count('class="c ') >= 14  # the calendar: a fortnight of days to choose
    assert ">Activity<" in page and ">Days<" not in page
    upload_sprint(c, mac, session_id(days_ago=2), days_ago=2)
    upload_sprint(c, mac, session_id(tail="tod111"), site="espn.com", away=300.0)
    page = admin.get("/dashboard").get_data(as_text=True)
    # Two days ago, yesterday and today: nothing from before the first record. Today is open, with its timeline.
    assert bars(page) == 3 and "Since " in page and "Timeline" in page and "espn.com" in page
    assert "20% distracted" in page and "Nothing recorded" in page  # today's bar, and yesterday's empty one
    assert 'href="#sw-' in page and 'id="sw-' in page  # a mark on the timeline jumps to its switch
    older = admin.get(f"/dashboard/day/{(datetime.now(timezone.utc) - timedelta(days=2)).strftime('%Y-%m-%d')}").get_data(as_text=True)
    assert bars(older) == 3 and 'aria-label="Later day"' in older  # an earlier day has the same graph and the way forward
    upload_sprint(c, mac, session_id(days_ago=40, tail="old111"), days_ago=40)
    page = admin.get("/dashboard").get_data(as_text=True)
    assert bars(page) == 28 and "Four weeks, day by day" in page and "Since " not in page


def test_an_unexpected_failure_gets_a_plain_page_with_a_reference(w):
    admin = w.household("mum@example.com")
    w.app.config["PROPAGATE_EXCEPTIONS"] = False
    w.db["sprintStarts"].insert_one({"_id": "broken", "familyId": w.db["accounts"].find_one({"email": "mum@example.com"})["familyId"],
                                     "memberId": w.me("mum@example.com"), "startedAt": "not a date"})
    reply = admin.get("/dashboard?who=me")
    assert reply.status_code == 500 and "Something went wrong on our side" in reply.get_data(as_text=True)


def test_the_timeline_is_one_bar_of_consecutive_segments_and_the_summary_adds_up(w):
    admin = w.household("mum@example.com")
    mac = w.pair(admin, w.add_kid(admin, "Mia"), name="Mia's Mac")
    c = w.browser()
    base = datetime.now(timezone.utc).replace(hour=18, minute=0, second=0, microsecond=0)
    at = lambda minutes: (base + timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
    def event(sid, n, start, minutes, host, category):
        return c.post(f"/api/upload/{sid}/e{n}.json", headers=mac, json={
            "_id": f"{sid}-e{n}", "sprintId": sid, "startedAt": at(start), "endedAt": at(start + minutes), "durationSeconds": minutes * 60.0,
            "category": category, "appName": "Safari", "bundleId": "com.apple.Safari", "title": "", "host": host, "url": f"https://{host}", "media": []})
    # A sprint from 0 to 60 minutes with one off-task visit, then time outside sprints with two distractions.
    sprint = base.strftime("%Y%m%d-%H%M%S-") + "spr111"
    c.post(f"/api/upload/{sprint}/start.json", headers=mac, json={"_id": sprint, "task": "Essay", "plannedSeconds": 3600, "startedAt": at(0),
           "allowedApps": [], "allowedBundleIds": [], "allowedDomains": [], "captureMode": "screenshot"})
    assert event(sprint, 1, 10, 5, "youtube.com", "offTask").status_code == 200
    c.post(f"/api/upload/{sprint}/end.json", headers=mac, json={"_id": sprint, "endedAt": at(60), "status": "completed",
           "focusedSeconds": 3300.0, "awaySeconds": 300.0, "switchCount": 1})
    later = (base + timedelta(minutes=90)).strftime("%Y%m%d-%H%M%S-") + "amb222"
    c.post(f"/api/upload/{later}/start.json", headers=mac, json={"_id": later, "task": "All day", "plannedSeconds": 43200, "startedAt": at(90),
           "allowedApps": [], "allowedBundleIds": [], "allowedDomains": [], "captureMode": "screenshot", "kind": "ambient"})
    assert event(later, 1, 100, 20, "youtube.com", "distraction").status_code == 200
    assert event(later, 2, 130, 10, "espn.com", "distraction").status_code == 200
    c.post(f"/api/upload/{later}/end.json", headers=mac, json={"_id": later, "endedAt": at(150), "status": "completed",
           "focusedSeconds": 1800.0, "awaySeconds": 1800.0, "switchCount": 2, "activeSeconds": 3600.0})
    day = (base.astimezone(ZoneInfo("America/Los_Angeles"))).strftime("%Y-%m-%d")
    page = admin.get(f"/dashboard/day/{day}?view=summary").get_data(as_text=True)
    # The bar: on task, off task, on task, not in use, on task, distraction, on task, distraction, on task (then padding).
    kinds = re.findall(r'<(?:a|span) class="(on|off|bad|idle)"', page[page.index('class="line"'):page.index('class="hours"')])
    assert kinds[:9] == ["on", "off", "on", "idle", "on", "bad", "on", "bad", "on"]
    weights = [float(x) for x in re.findall(r'style="flex:([0-9.]+) 0 0"', page[page.index('class="line"'):page.index('class="hours"')])]
    assert weights[:9] == [600.0, 300.0, 2700.0, 1800.0, 600.0, 1200.0, 600.0, 600.0, 600.0]  # seconds, consecutive, nothing overlapping
    assert sum(weights) % 3600 == 0  # the bar runs from one whole hour to another
    # Summary: one row per site, visits added up, most time first; youtube is 20 min distraction plus 5 min off task.
    summary = page[page.index('id="sw-summary"'):page.index('id="sw-detailed"')]
    assert summary.index("youtube.com") < summary.index("espn.com") and "25m 00s" in summary and "10m 00s" in summary
    assert "2 visits" in summary and "1 during a sprint" in summary and "20m 00s distraction and 5m 00s off task" in summary
    assert 'id="sw-summary" style="padding:26px 26px 12px" >' in page and 'id="sw-detailed" class="page" hidden' in page
    detailed = admin.get(f"/dashboard/day/{day}").get_data(as_text=True)  # opens on Detailed
    assert 'id="sw-detailed" class="page" >' in detailed and "Off task during a sprint" in detailed
    # The one summary card: 35 minutes away of 2 hours tracked.
    assert "35m 00s away" in detailed and "of 2h 00m tracked" in detailed and "29<small>%</small>" in detailed


def test_the_four_details_pages_show_the_same_day_and_person(w):
    admin = w.household("mum@example.com")
    mia, leo = w.add_kid(admin, "Mia"), w.add_kid(admin, "Leo")
    mac, leo_mac = w.pair(admin, mia, name="Mia's Mac"), w.pair(admin, leo, name="Leo's Mac", login="leo")
    c = w.browser()
    upload_sprint(c, mac, session_id(tail="mia111"), site="espn.com", away=120.0, title="Scores")
    upload_sprint(c, leo_mac, session_id(tail="leo222"), site="roblox.com", away=300.0)
    c.post("/api/search", json={"query": "NBA scores"}, headers=mac)
    c.post("/api/search", json={"query": "photosynthesis"}, headers=mac)
    c.post("/api/dispute", json={"host": "youtube.com", "reason": "physics lecture for class", "minutes": 30, "id": "r1"}, headers=mac)
    day = today()
    get = lambda page, who=mia: admin.get(f"/dashboard/day/{day}/{page}?who={who}")
    # Each card on the activity page links to its details page, for the same day and person.
    front = admin.get(f"/dashboard/day/{day}?who={mia}").get_data(as_text=True)
    for page in ("sprints", "searches", "requests", "switches"):
        assert f'/dashboard/day/{day}/{page}?who={mia}' in front
        reply = get(page)
        assert reply.status_code == 200
        text = reply.get_data(as_text=True)
        assert "Mia&#39;s day" in text and f'href="/dashboard/day/{day}?who={mia}"' in text  # the back button
        assert "roblox.com" not in text  # never the other kid's records
    sprints = get("sprints").get_data(as_text=True)
    assert "Sprints" in sprints and "92%" in sprints and "Focused across all sprints" in sprints and "25 min" in sprints
    assert "espn.com at" in sprints and "for 2m 00s." in sprints  # the switch away, in words
    assert re.findall(r'<i class="(on|off|bad)"', sprints)[:3] in (["on", "bad", "on"], ["on", "off", "on"])  # the sprint as one bar
    searches = get("searches").get_data(as_text=True)
    assert "NBA scores" in searches and "photosynthesis" not in searches and "private topics are never recorded" in searches
    assert ">2</div><div class=\"k\">Searches" in searches and ">1</div><div class=\"k\">For work" in searches
    requests = get("requests").get_data(as_text=True)
    assert "youtube.com" in requests and "physics lecture for class" in requests and "Approved" in requests and "30 min" in requests
    switches = get("switches").get_data(as_text=True)
    assert "espn.com" in switches and "2m 00s" in switches and 'id="viewer"' in switches and "Of tracked time" in switches
    # Leo's pages are Leo's; an unknown page or a bad day is not found; a signed-out visitor is sent to sign in.
    assert "roblox.com" in get("switches", leo).get_data(as_text=True) and "espn.com" not in get("switches", leo).get_data(as_text=True)
    assert admin.get(f"/dashboard/day/{day}/everything").status_code == 404
    assert admin.get("/dashboard/day/not-a-day/sprints").status_code == 404
    assert w.browser().get(f"/dashboard/day/{day}/switches").status_code == 302
    # Another household, asking for Mia by her id, gets its own (empty) page, never hers.
    other = w.household("dad@example.com")
    w.add_kid(other, "Zed")
    theirs = other.get(f"/dashboard/day/{day}/switches?who={mia}").get_data(as_text=True)
    assert "espn.com" not in theirs and "Zed&#39;s day" in theirs


def test_setup_reminders_follow_the_real_records(w):
    admin = w.household("mum@example.com")
    card, button = "Continue setup", "Finish setup"
    page = lambda who=admin, path="/dashboard": who.get(path).get_data(as_text=True)
    # A brand-new household: nothing done, both reminders on every page, and placeholders where records will be.
    first = page()
    assert "Setup · 0 of 3 steps done" in first and "Start setup" in first and "Finish setup · 0 of 3" in first
    assert "Three steps left" in first and "Next: add your kids" in first and "Distraction for the day" in first
    for path in ("/dashboard/apps", "/dashboard/sites", "/dashboard/people", "/dashboard/computers", "/dashboard/settings"):
        assert "Finish setup · 0 of 3" in page(path=path)
    assert admin.get("/setup").headers["Location"].endswith("/dashboard/people")  # opens at the first unfinished step
    # A kid exists: step 1 is done, the next step is installing.
    kid = w.add_kid(admin, "Mia")
    after_kid = page()
    assert "Setup · 1 of 3 steps done" in after_kid and "Two steps left" in after_kid and "Next: install the app on the Mac" in after_kid
    assert "Finish setup · 1 of 3" in after_kid and card in after_kid and "Mia" in after_kid
    assert admin.get("/setup").headers["Location"].endswith("/dashboard/computers")
    # A computer is linked: with a kid and a computer, setup is complete and both reminders are gone.
    mac = w.pair(admin, kid, name="Mia's Mac")
    done = page()
    assert card not in done and button not in done and "Setup ·" not in done
    assert admin.get("/setup").headers["Location"].endswith("/dashboard")
    # Removing the only computer brings the reminders back, with the install step still counted as done.
    device = w.db["devices"].find_one({"name": "Mia's Mac"})["_id"]
    admin.post(f"/dashboard/computers/{device}/remove", data={"csrf": w.csrf(admin, "/dashboard/computers")})
    again = page()
    assert card in again and "Finish setup · 1 of 3" in again and "Next: install the app on the Mac" in again
    # A computer but no kid (an admin who linked only their own Mac): still not complete, and the next step is kids.
    w.db["members"].delete_many({"kind": "kid"})
    w.pair(admin, w.me("mum@example.com"), name="Mum's Mac", login="mum")
    own_only = page()
    assert "Finish setup · 2 of 3" in own_only and "Next: add your kids" in own_only and "no kid has been added yet" in own_only


def test_only_the_household_admin_sees_setup(w):
    admin = w.household("mum@example.com")
    assert "Finish setup" in admin.get("/dashboard").get_data(as_text=True)
    # A co-admin and an invited adult join a household that already exists: no reminders, and /setup just goes home.
    co = w.join(w.invite_adult(admin, "Dad", role="coadmin"), "dad@example.com", name="Dad")
    adult = w.join(w.invite_adult(admin, "Gran"), "gran@example.com", name="Gran")
    for person in (co, adult):
        for path in ("/dashboard", "/dashboard/apps", "/dashboard/computers"):
            text = person.get(path).get_data(as_text=True)
            assert "Finish setup" not in text and "Continue setup" not in text and "Start setup" not in text
        assert person.get("/setup").headers["Location"].endswith("/dashboard")
    assert w.browser().get("/setup").status_code == 302 and "/login" in w.browser().get("/setup").headers["Location"]
    # A household set up the old way (a kid and a computer already there) never sees any of it.
    other = w.household("pat@example.com")
    w.pair(other, w.add_kid(other, "Zed"), name="Zed's Mac")
    old_way = other.get("/dashboard").get_data(as_text=True)
    assert all(x not in old_way for x in ("Finish setup", "Continue setup", "Start setup", "Setup ·", 'class="card remind"'))
