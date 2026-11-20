"""Needs a MongoDB to talk to: set TEST_MONGODB_URI (a throwaway local mongod is enough)."""
import os
import sys
import uuid

import pytest
from pymongo import MongoClient

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
os.environ.update(SECRET_KEY="test-secret", DEVICE_TOKEN="test-device", PARENT_EMAIL="parent@example.com",
                  PUBLIC_URL="https://focus.example.com")
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
    assert r.json["site"]["state"] == "distraction" and r.json["site"]["allowedUntil"] == a["allowedUntil"] > "2026"
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
    assert "https://focus.example.com/decide?t=" in body and "a=block" not in body


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
    assert page.status_code == 200 and b"Physics lecture" in page.data and b"Approved until" in page.data
    assert db["sites"].find_one({"_id": "youtube.com"})["state"] == "distraction"

    assert client.post("/decide", data={"t": token, "a": "distraction"}).status_code == 200
    site = db["sites"].find_one({"_id": "youtube.com"})
    assert site["state"] == "locked" and "allowedUntil" not in site  # the approval window is ended too
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
