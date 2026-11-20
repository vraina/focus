"""Sends the parent email through Resend. Without RESEND_API_KEY the email is logged instead (local development)."""
import html
import logging
import os

import resend

log = logging.getLogger(__name__)


DECISION_LABEL = {"approve_temporary": "Approved for a while", "approve_permanent": "Approved for good", "deny": "Not approved"}
DECISION_COLOR = {"approve_temporary": "#15803d", "approve_permanent": "#15803d", "deny": "#b91c1c"}


def digest_email(day_label: str, requests: list[dict], new_sites: list[dict], link_for,
                 children: list[dict] | None = None, dashboard_url: str = "") -> tuple[str, str]:
    """`children`: one entry per child with that child's requests, search counts and distraction searches.
    `link_for(host)` gives the page where the parent can overrule a site's label."""
    e = html.escape
    children = children or []
    approved = sum(1 for r in requests if r["decision"] != "deny")
    subject = f"YoungWonks Focus daily summary, {day_label}: {len(requests)} request(s), {approved} approved"
    parts = [f'''<div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:15px;color:#1a1a1a;max-width:620px">
<h2 style="margin:0 0 4px">Daily summary, {e(day_label)}</h2>
<p style="color:#666;margin:0 0 18px">Nothing is blocked. Requests are judged automatically; you can overrule any site below. Newest first.</p>''']

    for child in children:
        if len(children) > 1:
            # More than one child: each gets their own section, so one child's day is never read as another's.
            parts.append(f'''<h2 style="margin:22px 0 10px;padding:8px 12px;background:#eef0ff;border-radius:8px;font-size:17px">{e(child["name"])}</h2>''')
        if child["requests"]:
            parts.append('<h3 style="margin:0 0 8px">"Needed for work" requests</h3>')
        for r in child["requests"]:
            granted = ""
            if r["decision"] == "approve_temporary":
                granted = f" for {r.get('grantedMinutes', 0)} min (asked for {r.get('requestedMinutes', 0)})"
            elif r["decision"] == "deny":
                asked = "for good" if r.get("wantsPermanent") else f"{r.get('requestedMinutes', 0)} min"
                granted = f" (asked for {asked})"
            parts.append(f'''<div style="border:1px solid #e5e7eb;border-radius:8px;padding:12px 14px;margin:0 0 10px">
<div><b>{e(r["host"])}</b> <span style="color:#666">· {e(r.get("localTime", ""))} · {e(r.get("who", ""))}</span></div>
<div style="margin:6px 0;padding:8px 10px;background:#f3f4f6;border-radius:6px">{e(r.get("reason", ""))}</div>
<div><b style="color:{DECISION_COLOR[r["decision"]]}">{DECISION_LABEL[r["decision"]]}</b>{e(granted)}</div>
<div style="color:#444;margin-top:4px">{e(r.get("explanation", ""))}</div>
<div style="margin-top:8px"><a href="{e(link_for(r["host"]))}" style="color:#1d4ed8">Overrule this site</a></div>
</div>''')
        counts = child.get("counts") or {}
        if sum(counts.values()):
            parts.append(f'''<h3 style="margin:18px 0 6px">Web searches</h3>
<p style="margin:0 0 8px"><b>{counts.get("work", 0)}</b> for work · <b style="color:#b45309">{counts.get("distraction", 0)}</b> distraction ·
<b>{counts.get("personal", 0)}</b> private</p>''')
            if child["searches"]:
                parts.append('<table style="border-collapse:collapse;width:100%">')
                for x in child["searches"][:60]:
                    during = f" (during: {e(x['task'])})" if x.get("task") else ""
                    where = f" · {e(x['device'])}" if x.get("device") else ""
                    parts.append(f'''<tr><td style="padding:5px 10px 5px 0;vertical-align:top;color:#666;white-space:nowrap">{e(x.get("localTime", ""))}{where}</td>
<td style="padding:5px 0;vertical-align:top"><b>{e(x.get("text", ""))}</b><span style="color:#666">{during}</span><br>
<span style="color:#444">{e(x.get("reason", ""))}</span></td></tr>''')
                parts.append("</table>")
    if any(sum((c.get("counts") or {}).values()) for c in children):
        parts.append('''<p style="color:#666;font-size:13px;margin:10px 0 0">Only distraction searches are listed. Schoolwork searches are counted, and private topics
(health, feelings, relationships and the like) are counted without their words, so your child can still look for help.</p>''')

    if new_sites:
        parts.append('<h3 style="margin:18px 0 8px">Websites labelled for the first time today</h3><table style="border-collapse:collapse;width:100%">')
        for s in new_sites:
            good = s["state"] == "productive"
            parts.append(f'''<tr><td style="padding:5px 8px 5px 0;vertical-align:top"><b>{e(s["_id"])}</b></td>
<td style="padding:5px 8px;vertical-align:top;color:{"#15803d" if good else "#b45309"}">{"Productive" if good else "Distraction"}</td>
<td style="padding:5px 0;vertical-align:top;color:#444">{e(s.get("reason", ""))} <a href="{e(link_for(s["_id"]))}" style="color:#1d4ed8">Change</a></td></tr>''')
        parts.append("</table>")
    if dashboard_url:
        parts.append(f'''<p style="margin:22px 0 0"><a href="{e(dashboard_url)}" style="display:inline-block;padding:10px 16px;border-radius:6px;
background:#5e57f0;color:#ffffff;text-decoration:none;font-weight:600">Open the full day, with pictures</a></p>''')
    parts.append("</div>")
    return subject, "".join(parts)


def send(to: str, subject: str, body_html: str) -> bool:
    api_key = os.environ.get("RESEND_API_KEY")
    sender = os.environ.get("MAIL_FROM", "YoungWonks Focus <onboarding@resend.dev>")
    if not api_key:
        log.warning("RESEND_API_KEY not set, email not sent. To: %s Subject: %s", to, subject)
        return False
    resend.api_key = api_key
    try:
        resend.Emails.send({"from": sender, "to": [to], "subject": subject, "html": body_html})
        return True
    except Exception as exc:  # the dispute itself is already stored; a failed email must not lose it
        log.error("could not send email to %s: %s", to, exc)
        return False
