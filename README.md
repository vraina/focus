# YoungWonks Focus

A focus timer for a teen's Mac. The teen starts a sprint, names the apps and websites the task needs,
and every switch to anything else is recorded with a captioned screenshot or short clip. The point is
self-awareness: the teen reviews their own history, and cannot delete it.

## How it fits together

| Piece | Runs as | Job |
|---|---|---|
| `YoungWonks Focus.app` | the teen | Timer, switch detection, screen capture, floating meter, history |
| `focussprint-vaultd` | root (LaunchDaemon) | Copies records into a root-owned vault, uploads them to Atlas |
| MongoDB Atlas | cloud | Append-only copy: `sprintStarts`, `sprintEnds`, `events`, `media`; plus `sites` (labels and parent decisions) |
| `server/` (Flask on Render) | cloud | Labels new websites with Claude, emails the parent, serves the decision pages |

Records are written to disk first. The helper keeps each one queued in
`/Library/Application Support/FocusSprint/vault` until Atlas confirms it, so a lost connection loses nothing.

## Setup (parent, once)

1. **Atlas.** In the project you use for this:
   - Database Access → Custom Roles → new role `focussprintWriter` with the single action `insert` on database `focussprint`.
   - Add a database user with only that role. This is the connection string the Mac uploads with; it cannot delete or change anything.
   - Optional: a second user with the built-in `read` role on `focussprint`, for the Cloud view in History.
   - Network Access: allow the addresses the Mac will connect from.
2. **The teen's Mac login must be a Standard account** (System Settings → Users & Groups). An Administrator can delete anything on the Mac, including the vault.
3. From an Administrator account, in this folder: `scripts/install.sh`
4. Log in as the teen, open YoungWonks Focus, grant Screen Recording (and Automation for the browser when asked).
5. Parent settings tab → paste the insert-only connection string → Save (asks for the administrator password).

## Website labels and "Needed for work"

Nothing is ever blocked. The app records and shows; the parent sees the same numbers.

- A website seen for the first time is sent (host name only) to the family service, which asks Claude whether it is
  productive or a distraction for a school-age student. The answer is stored once and reused.
- The parent's own list under Parent settings always wins over the AI label.
- On a distraction site the floating meter offers **Needed for work**. The student says why and for how long
  (15 minutes to 2 hours, or "always"). Claude reviews the request straight away and answers in a popup:
  - **Approved for a while**: the site does not count as a distraction until the time is up. Never longer than asked, 4 hours at most.
  - **Approved for good**: only for sites that are educational or tools and were simply mislabelled. Never for a site on the parent's own list.
  - **Not approved**: it keeps counting. The student can ask again with a more specific reason, up to 5 times a day per site.
- No email per request. At the end of the day (`DIGEST_HOUR`, in `TIMEZONE`) the parent gets one summary: every request, the
  student's words, the decision and its explanation, plus the websites labelled for the first time that day. Each site has
  an **Overrule** link to a page with **Always allow** and **Always a distraction**; a parent's choice is final.
- History and the meter show the totals twice: everything as recorded, and leaving out sites approved since.

### Web searches

The app reads the search words from the tab address on Google, Bing, DuckDuckGo, Yahoo, Brave and Ecosia, and
Claude labels each search as work, distraction or personal (during a sprint, judged against the sprint's task).

- **Distraction** searches keep their words: shown in History and listed in the parent's daily summary.
- **Work** searches are only counted.
- **Personal** searches (health, feelings, relationships, identity and the like) are counted with no words and no
  hint of the topic, on the Mac and in the database, so a student can still look for help.

### Deploying the service

`render.yaml` (at the top of the repository) describes it. In Render: New → Blueprint → this repository, then fill in the variables marked
`sync: false`: `MONGODB_URI` (an Atlas user with readWrite on `focussprint`), `ANTHROPIC_API_KEY`, `RESEND_API_KEY`,
`MAIL_FROM` (an address on a domain verified in Resend), `PARENT_EMAIL`, `PUBLIC_URL` (the service's own address).
Set `TIMEZONE` to the family's time zone. The daily summary is sent by the service itself, so it must stay awake (not a free plan that sleeps).
Then copy `DEVICE_TOKEN` from Render and paste it, with the service address, into Parent settings on the Mac.

Tests: `cd server && TEST_MONGODB_URI=mongodb://127.0.0.1:27017 .venv/bin/python -m pytest -q tests`

## Parent-only settings and uninstalling

- The Parent settings tab stays locked until a Mac administrator password is entered, and locks again when you leave it.
- `scripts/install.sh` installs the app, the helper and both launch files owned by root. A Standard account cannot
  delete, move or replace any of them, and the app is restarted if it is quit.
- Both of these depend on the teen's login being a Standard account. Do not share the administrator password.

## Development

`scripts/dev-run.sh` runs the app and helper as yourself against `build/devroot`, with no installation.
`swift test` runs the unit tests; set `FOCUSSPRINT_TEST_MONGO` to a database with uploaded sprints to include the cloud read test.

## What it does not stop

- Quitting the app mid-sprint. The sprint then shows as "Interrupted" in History and in Atlas.
- Using a phone or another device during a sprint.
- Firefox and a few other browsers do not expose the tab address, so those are judged by tab title.
