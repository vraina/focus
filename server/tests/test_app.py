"""Needs a MongoDB to talk to: set TEST_MONGODB_URI (a throwaway local mongod is enough)."""
import os
import sys
import uuid

import pytest
from pymongo import MongoClient

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
os.environ.update(SECRET_KEY="test-secret", DEVICE_TOKEN="test-device", PARENT_EMAIL="parent@example.com",
                  PUBLIC_URL="http://localhost", PARENT_PASSWORD="test-pass", TIMEZONE="UTC")
from app import create_app  # noqa: E402

AUTH = {"Authorization": "Bearer test-device"}


@pytest.fixture
def ctx():
    uri = os.environ.get("TEST_MONGODB_URI")
    if not uri:
        pytest.skip("TEST_MONGODB_URI not set")
    mongo = MongoClient(uri)
    name = f"focus_test_{uuid.uuid4().hex[:8]}"
    calls, emails, reviews = [], [], []

    def fake_classify(host, title=""):
        calls.append(host)
        if host == "flaky.example.com":
            return None
        label = "distraction" if "tube" in host or "gram" in host else "productive"
        return {"label": label, "category": "video", "reason": f"{host} is mostly {label}."}

    def fake_review(host, label_reason, reason, minutes, wants_permanent, history, allow_permanent):
        reviews.append({"host": host, "reason": reason, "history": len(history), "allow_permanent": allow_permanent})
        if "flaky" in reason:
            return None
        if "lecture" in reason:
            return {"decision": "approve_temporary", "minutes": 999, "explanation": "A lecture is a real need."}
        if "never a distraction" in reason:
            return {"decision": "approve_permanent", "minutes": 0, "explanation": "This is a reference site."}
        return {"decision": "deny", "minutes": 0, "explanation": "Say what you need it for."}

    def fake_search(query, task=""):
        if "flaky" in query:
            return None
        if "anxiety" in query:
            return {"label": "personal", "reason": "Private topic."}
        if "nba" in query.lower():
            return {"label": "distraction", "reason": "Sports scores are not part of the task."}
        return {"label": "work", "reason": "Fits schoolwork."}

    def fake_send(to, subject, body):
        emails.append({"to": to, "subject": subject, "body": body})
        return True

    app = create_app(db=mongo[name], classify=fake_classify, review=fake_review, send_email=fake_send, label_search=fake_search)
    yield app.test_client(), mongo[name], calls, emails, reviews
    mongo.drop_database(name)


def test_requires_device_token(ctx):
    client, *_ = ctx
    assert client.post("/api/classify", json={"host": "youtube.com"}).status_code == 401
    assert client.get("/api/sites").status_code == 401
    assert client.post("/api/dispute", json={"host": "a.com", "reason": "x"},
                       headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_classify_once_then_cached(ctx):
    client, db, calls, *_ = ctx
    first = client.post("/api/classify", json={"host": "WWW.YouTube.com", "title": "Highlights"}, headers=AUTH)
    assert first.status_code == 200 and first.json["state"] == "distraction" and first.json["host"] == "youtube.com"
    again = client.post("/api/classify", json={"host": "youtube.com"}, headers=AUTH)
    assert again.json["state"] == "distraction"
    assert calls == ["youtube.com"]  # Claude was asked exactly once
    assert client.post("/api/classify", json={"host": "khanacademy.org"}, headers=AUTH).json["state"] == "productive"
    assert client.post("/api/classify", json={"host": "not a host"}, headers=AUTH).status_code == 400
    assert client.post("/api/classify", json={"host": "localhost"}, headers=AUTH).status_code == 400


def test_unclassified_is_not_stored(ctx):
    client, db, *_ = ctx
    assert client.post("/api/classify", json={"host": "flaky.example.com"}, headers=AUTH).status_code == 503
    assert db["sites"].count_documents({}) == 0


def ask(client, host, reason, minutes=60, **extra):
    return client.post("/api/dispute", json={"host": host, "reason": reason, "minutes": minutes, "user": "sam",
                                             "device": "Sam's MacBook", **extra}, headers=AUTH)


def test_request_approved_for_a_while_without_emailing(ctx):
    client, db, _, emails, reviews = ctx
    client.post("/api/classify", json={"host": "youtube.com"}, headers=AUTH)
    r = ask(client, "youtube.com", "Physics lecture for Thursday", minutes=45, id="req-1")
    assert r.status_code == 200
    a = r.json["answer"]
    assert a["decision"] == "approve_temporary" and a["minutes"] == 45  # capped at what was asked, not the model's 999
    # The window belongs to the child who asked ("sam"), not to everyone.
    assert r.json["site"]["state"] == "distraction" and r.json["site"]["approvedFor"] == {"sam": a["allowedUntil"]}
    assert a["allowedUntil"] > "2026" and "allowedUntil" not in r.json["site"]
    assert emails == []  # no email per request any more
    # The helper retrying the same request gets the same answer and the model is not asked twice.
    again = ask(client, "youtube.com", "Physics lecture for Thursday", minutes=45, id="req-1")
    assert again.json["answer"] == a and len(reviews) == 1
    assert db["requests"].count_documents({}) == 1


def test_request_denied_and_permanent(ctx):
    client, db, _, emails, reviews = ctx
    client.post("/api/classify", json={"host": "youtube.com"}, headers=AUTH)
    denied = ask(client, "youtube.com", "i need it")
    assert denied.json["answer"]["decision"] == "deny" and "allowedUntil" not in denied.json["site"]
    forever = ask(client, "youtube.com", "it is never a distraction", permanent=True)
    assert forever.json["answer"]["decision"] == "approve_permanent" and forever.json["site"]["state"] == "productive"
    assert reviews[-1]["history"] == 1  # the reviewer saw the earlier request


def test_parent_list_site_is_never_cleared_for_good(ctx):
    client, db, calls, _, reviews = ctx
    r = ask(client, "espn.com", "it is never a distraction", minutes=30, permanent=True)
    assert calls == [] and reviews[-1]["allow_permanent"] is False
    assert r.json["answer"]["decision"] == "approve_temporary" and r.json["answer"]["minutes"] == 30
    assert r.json["site"]["state"] == "distraction"
    assert ask(client, "espn.com", "").status_code == 400


def test_unreviewed_request_is_retried_not_lost(ctx):
    client, db, *_ = ctx
    assert ask(client, "youtube.com", "flaky").status_code == 503
    assert db["requests"].count_documents({}) == 0


def test_daily_limit(ctx):
    client, db, _, _, reviews = ctx
    for _ in range(5):
        ask(client, "tiktok.com", "please")
    sixth = ask(client, "tiktok.com", "Physics lecture")
    assert sixth.json["answer"]["decision"] == "deny" and len(reviews) == 5


def test_daily_digest(ctx):
    client, db, _, emails, _ = ctx
    assert client.post("/api/digest", json={}, headers=AUTH).json["result"] == "nothing to report"
    client.post("/api/classify", json={"host": "youtube.com"}, headers=AUTH)
    client.post("/api/classify", json={"host": "khanacademy.org"}, headers=AUTH)
    ask(client, "youtube.com", "Physics lecture <b>for class</b>", minutes=45)
    ask(client, "youtube.com", "i need it")
    assert client.post("/api/digest", json={}).status_code == 401
    assert client.post("/api/digest", json={}, headers=AUTH).json["result"] == "sent"
    mail = emails[-1]
    assert mail["to"] == "parent@example.com" and "2 request(s), 1 approved" in mail["subject"]
    body = mail["body"]
    assert "&lt;b&gt;for class&lt;/b&gt;" in body  # the student's words, escaped
    assert "Approved for a while" in body and "for 45 min" in body and "Not approved" in body
    assert body.index("i need it") < body.index("Physics lecture")  # newest request first
    assert "A lecture is a real need." in body and "khanacademy.org" in body
    assert "http://localhost/decide?t=" in body and "a=block" not in body


def _token(emails):
    return emails[-1]["body"].split("/decide?t=")[1].split('"')[0]


def test_parent_can_overrule(ctx):
    client, db, _, emails, _ = ctx
    client.post("/api/classify", json={"host": "youtube.com"}, headers=AUTH)
    ask(client, "youtube.com", "Physics lecture", minutes=60)
    client.post("/api/digest", json={}, headers=AUTH)
    token = _token(emails)

    # Opening the link (as a mail scanner would) changes nothing.
    page = client.get(f"/decide?t={token}")
    assert page.status_code == 200 and b"Physics lecture" in page.data and b"Approved for now: sam" in page.data
    assert db["sites"].find_one({"_id": "youtube.com"})["state"] == "distraction"

    assert client.post("/decide", data={"t": token, "a": "distraction"}).status_code == 200
    site = db["sites"].find_one({"_id": "youtube.com"})
    assert site["state"] == "locked" and "approvedFor" not in site  # the approval window is ended too
    # After that, requests are turned down without asking the model.
    assert ask(client, "youtube.com", "Physics lecture").json["answer"]["decision"] == "deny"

    assert client.post("/decide", data={"t": token, "a": "allow"}).status_code == 200
    assert db["sites"].find_one({"_id": "youtube.com"})["state"] == "allowed"
    assert client.post("/decide", data={"t": token, "a": "block"}).status_code == 400
    assert client.post("/decide", data={"t": token + "x", "a": "allow"}).status_code == 403
    assert client.get("/decide?t=forged").status_code == 403


def search(client, query, **extra):
    return client.post("/api/search", json={"query": query, "engine": "google.com", "user": "sam", "device": "Mac", **extra},
                       headers=AUTH)


def test_search_labels_and_what_is_kept(ctx):
    client, db, *_ = ctx
    assert client.post("/api/search", json={"query": "x"}).status_code == 401
    assert search(client, "   ").status_code == 400
    assert search(client, "flaky lookup").status_code == 503

    work = search(client, "quadratic formula examples", id="s1", task="Algebra homework")
    assert work.json["label"] == "work" and work.json["text"] == ""
    fun = search(client, "NBA scores tonight", id="s2", task="Algebra homework")
    assert fun.json["label"] == "distraction" and fun.json["text"] == "NBA scores tonight"
    private = search(client, "how to deal with anxiety", id="s3")
    assert private.json == {"id": "s3", "at": private.json["at"], "label": "personal", "engine": "google.com",
                            "reason": "", "text": ""}

    # Only the distraction search keeps its words in the database.
    assert "text" not in db["searches"].find_one({"_id": "s1"})
    assert db["searches"].find_one({"_id": "s2"})["text"] == "NBA scores tonight"
    stored = db["searches"].find_one({"_id": "s3"})
    assert "text" not in stored and "anxiety" not in str(stored)
    # A retry of the same search is answered from the record, not labelled again.
    assert search(client, "NBA scores tonight", id="s2").json["at"] == fun.json["at"]
    assert db["searches"].count_documents({}) == 3


def test_searches_in_daily_digest(ctx):
    client, db, _, emails, _ = ctx
    search(client, "photosynthesis diagram")
    search(client, "how to deal with anxiety")
    # Schoolwork and private searches alone do not trigger an email.
    assert client.post("/api/digest", json={}, headers=AUTH).json["result"] == "nothing to report"
    search(client, "NBA scores <tonight>", task="Algebra homework")
    assert client.post("/api/digest", json={}, headers=AUTH).json["result"] == "sent"
    body = emails[-1]["body"]
    assert "NBA scores &lt;tonight&gt;" in body and "Algebra homework" in body
    assert "<b>1</b> for work" in body and "<b>1</b> private" in body
    assert "anxiety" not in body and "photosynthesis" not in body


# --- Parent dashboard ---------------------------------------------------------------------------

import re
from datetime import datetime, timezone


def sign_in(client, password="test-pass", email="parent@example.com"):
    page = client.get("/login")
    token = re.search(r'name="csrf" value="([^"]+)"', page.get_data(as_text=True)).group(1)
    return client.post("/login", data={"csrf": token, "email": email, "password": password})


def seed_day(db):
    now = datetime.now(timezone.utc).replace(microsecond=0)
    at = lambda s: now.replace(hour=10, minute=0, second=s).strftime("%Y-%m-%dT%H:%M:%SZ")
    db["sprintStarts"].insert_one({"_id": "s1", "task": "Algebra <b>homework</b>", "user": "sam", "device": "Mac",
                                   "plannedSeconds": 1500, "startedAt": at(0)})
    db["sprintEnds"].insert_one({"_id": "s1", "endedAt": now.replace(hour=10, minute=25, second=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
                                 "status": "completed", "awaySeconds": 150.0, "switchCount": 2})
    db["events"].insert_many([
        {"_id": "s1-e1", "sprintId": "s1", "seq": 1, "startedAt": at(10), "endedAt": at(40), "durationSeconds": 30.0,
         "appName": "Google Chrome", "host": "espn.com", "title": "<script>alert(1)</script>", "category": "distraction",
         "media": [{"role": "start", "kind": "image", "file": "e1-start.jpg"}]},
        {"_id": "s1-e2", "sprintId": "s1", "seq": 2, "startedAt": at(50), "endedAt": at(55), "durationSeconds": 120.0,
         "appName": "Messages", "title": "", "category": "offTask", "media": []},
    ])
    db["media"].insert_one({"_id": "s1/e1-start.jpg", "sprintId": "s1", "file": "e1-start.jpg", "data": b"\xff\xd8fakejpeg"})
    return now.strftime("%Y-%m-%d")


def test_dashboard_requires_sign_in(ctx):
    client, db, *_ = ctx
    day = seed_day(db)
    for path in ("/dashboard", f"/dashboard/day/{day}", "/dashboard/sites", "/dashboard/media/s1/e1-start.jpg"):
        r = client.get(path)
        assert r.status_code == 302 and "/login" in r.headers["Location"], path
    assert sign_in(client, password="wrong").status_code == 401
    assert sign_in(client, email="someone@else.com").status_code == 401
    assert client.get("/dashboard").status_code == 302
    # A sign-in form posted without the page's token is refused.
    assert client.post("/login", data={"email": "parent@example.com", "password": "test-pass"}).status_code == 400


def test_dashboard_shows_the_day(ctx):
    client, db, *_ = ctx
    day = seed_day(db)
    client.post("/api/search", json={"query": "NBA scores", "engine": "google.com"}, headers=AUTH)
    assert sign_in(client).status_code == 302

    overview = client.get("/dashboard").get_data(as_text=True)
    assert "Today" in overview and "10%" in overview and "2 switches" in overview  # 150s away of 1500s

    page = client.get(f"/dashboard/day/{day}").get_data(as_text=True)
    assert "espn.com" in page and "10:00:10 AM" in page and "2m 00s" in page and "90% focused" in page
    assert page.index("Messages") < page.index("espn.com")  # newest switch first
    assert "NBA scores" in page and "/dashboard/media/s1/e1-start.jpg" in page
    # Text typed by the student or taken from a page title is never run as HTML.
    assert "<script>alert(1)</script>" not in page and "&lt;script&gt;" in page
    assert "Algebra <b>homework</b>" not in page

    picture = client.get("/dashboard/media/s1/e1-start.jpg")
    assert picture.status_code == 200 and picture.data.startswith(b"\xff\xd8") and picture.mimetype == "image/jpeg"
    assert "private" in picture.headers["Cache-Control"]
    assert client.get("/dashboard/media/s1/missing.jpg").status_code == 404
    assert client.get("/dashboard/day/not-a-date").status_code == 404

    client.post("/api/classify", json={"host": "youtube.com"}, headers=AUTH)
    sites = client.get("/dashboard/sites").get_data(as_text=True)
    assert "youtube.com" in sites and "/decide?t=" in sites


def test_sign_out_and_lockout(ctx):
    client, db, *_ = ctx
    sign_in(client)
    token = re.search(r'name="csrf" value="([^"]+)"', client.get("/dashboard").get_data(as_text=True)).group(1)
    assert client.post("/logout", data={"csrf": token}).status_code == 302
    assert client.get("/dashboard").status_code == 302
    for _ in range(8):
        assert sign_in(client, password="guess").status_code == 401
    # After eight wrong tries even the right password has to wait.
    assert sign_in(client).status_code == 429


# --- More than one child, more than one computer ------------------------------------------------

def test_approvals_and_limits_are_per_child(ctx):
    client, db, _, _, reviews = ctx
    client.post("/api/classify", json={"host": "youtube.com"}, headers=AUTH)
    ask(client, "youtube.com", "Physics lecture for Thursday", minutes=30, user="mia.k")
    site = client.get("/api/sites", headers=AUTH).json["sites"][0]
    assert list(site["approvedFor"]) == ["mia_k"]  # a dot cannot be part of a field name
    # One child using up their requests for a site does not use up another child's.
    for _ in range(5):
        ask(client, "tiktok.com", "please", user="mia.k")
    assert ask(client, "tiktok.com", "Physics lecture", user="mia.k").json["answer"]["decision"] == "deny"
    assert ask(client, "tiktok.com", "Physics lecture", user="leo").json["answer"]["decision"] == "approve_temporary"
    assert reviews[-1]["history"] == 0  # and leo is judged on his own history, not mia's


def test_dashboard_filters_by_child_and_computer(ctx):
    client, db, *_ = ctx
    now = datetime.now(timezone.utc).replace(microsecond=0)
    at = lambda m: now.replace(hour=9, minute=m, second=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    for sid, user, device, site, away in (("a", "mia", "Mia Air", "tiktok.com", 60.0), ("b", "mia", "Den iMac", "espn.com", 120.0),
                                          ("c", "leo", "Leo Pro", "roblox.com", 300.0)):
        db["sprintStarts"].insert_one({"_id": sid, "task": f"Work {sid}", "user": user, "device": device, "plannedSeconds": 600, "startedAt": at(0)})
        db["sprintEnds"].insert_one({"_id": sid, "endedAt": at(10), "status": "completed", "awaySeconds": away, "switchCount": 1})
        db["events"].insert_one({"_id": sid + "-e1", "sprintId": sid, "startedAt": at(1), "endedAt": at(2), "durationSeconds": away,
                                 "appName": "Chrome", "host": site, "title": "", "category": "distraction", "media": []})
    client.post("/api/search", json={"query": "NBA scores", "user": "leo", "device": "Leo Pro"}, headers=AUTH)
    sign_in(client)
    day = now.strftime("%Y-%m-%d")

    everyone = client.get(f"/dashboard/day/{day}").get_data(as_text=True)
    assert all(x in everyone for x in ("tiktok.com", "espn.com", "roblox.com", "NBA scores"))
    assert "8m 00s" in everyone and "mia on Den iMac" in everyone  # 480s away in total; computers are named

    mia = client.get(f"/dashboard/day/{day}?user=mia").get_data(as_text=True)
    assert "tiktok.com" in mia and "espn.com" in mia and "roblox.com" not in mia and "NBA scores" not in mia
    assert "3m 00s" in mia

    den = client.get(f"/dashboard/day/{day}?user=mia&device=Den%20iMac").get_data(as_text=True)
    assert "espn.com" in den and "tiktok.com" not in den and "2m 00s" in den

    leo = client.get(f"/dashboard?user=leo").get_data(as_text=True)
    assert "50%" in leo and "1 distraction search" in leo  # 300s away of 600s
    assert "user=leo" in leo  # links to the days keep the filter


def test_digest_has_a_section_per_child(ctx):
    client, db, _, emails, _ = ctx
    client.post("/api/search", json={"query": "NBA scores", "user": "leo", "device": "Leo Pro"}, headers=AUTH)
    ask(client, "youtube.com", "Physics lecture", user="mia")
    client.post("/api/digest", json={}, headers=AUTH)
    body = emails[-1]["body"]
    leo, mia = body.index(">leo</h2>"), body.index(">mia</h2>")
    assert leo < body.index("NBA scores") < mia < body.index("Physics lecture")


def test_old_pictures_are_removed_but_records_stay(ctx):
    client, db, *_ = ctx
    from datetime import timedelta
    from app import create_app
    old_day = datetime.now(timezone.utc) - timedelta(days=20)
    old, recent = old_day.strftime("%Y%m%d") + "-101500-abc123", datetime.now(timezone.utc).strftime("%Y%m%d") + "-101500-def456"
    for sid, when in ((old, old_day), (recent, datetime.now(timezone.utc))):
        at = when.replace(hour=10, minute=15, second=0, microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
        db["sprintStarts"].insert_one({"_id": sid, "task": "Essay", "user": "sam", "device": "Mac", "plannedSeconds": 600, "startedAt": at})
        db["events"].insert_one({"_id": sid + "-e1", "sprintId": sid, "startedAt": at, "endedAt": at, "durationSeconds": 30.0,
                                 "appName": "Chrome", "host": "espn.com", "title": "", "category": "distraction",
                                 "media": [{"role": "start", "kind": "image", "file": "e1-start.jpg"}]})
        db["media"].insert_one({"_id": f"{sid}/e1-start.jpg", "sprintId": sid, "file": "e1-start.jpg", "data": b"\xff\xd8x"})
    db["media"].insert_one({"_id": "not-a-session/odd.jpg", "data": b"x"})  # anything unrecognised is left alone

    app = create_app(db=db, classify=lambda *a: None, review=lambda *a: None, send_email=lambda *a: True, label_search=lambda *a: None)
    assert app.media_keep_days == 14 and app.cleanup_media() == 1 and app.cleanup_media() == 0
    assert db["media"].find_one({"_id": f"{old}/e1-start.jpg"}) is None
    assert db["media"].find_one({"_id": f"{recent}/e1-start.jpg"}) and db["media"].find_one({"_id": "not-a-session/odd.jpg"})
    assert db["events"].count_documents({}) == 2  # the record of the old switch is still there

    sign_in(client)
    page = client.get(f"/dashboard/day/{old_day.strftime('%Y-%m-%d')}").get_data(as_text=True)
    assert "espn.com" in page and "Pictures are kept for 14 days" in page and "/dashboard/media/" not in page
