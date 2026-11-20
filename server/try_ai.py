"""Tries the two Claude calls directly, without the web service or MongoDB.

    .venv/bin/python try_ai.py youtube.com
    .venv/bin/python try_ai.py youtube.com "Watching the physics lecture for Thursday" 45
"""
import os
import sys

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))
import classifier  # noqa: E402

if not os.environ.get("ANTHROPIC_API_KEY"):
    sys.exit("ANTHROPIC_API_KEY is not set. Add it to server/.env")
if len(sys.argv) < 2:
    sys.exit(__doc__)

host = sys.argv[1]
label = classifier.classify(host)
print("label: ", label)
if len(sys.argv) > 2:
    minutes = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    verdict = classifier.review_request(host, (label or {}).get("reason", ""), sys.argv[2], minutes,
                                        wants_permanent=False, history=[], allow_permanent=True)
    print("review:", verdict)
