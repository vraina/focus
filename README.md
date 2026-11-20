# YoungWonks Focus

A focus timer for a teen's Mac. The teen starts a sprint, names the apps and websites the task needs,
and every switch to anything else is recorded with a captioned screenshot or short clip. The point is
self-awareness: the teen reviews their own history, and cannot delete it.

## How it fits together

| Piece | Runs as | Job |
|---|---|---|
| `YoungWonks Focus.app` | the person using the Mac | Timer, switch detection, screen capture, floating meter, history |
| `focussprint-vaultd` | root (LaunchDaemon) | Keeps records in a root-owned vault, holds this Mac's token, sends everything to the service |
| `server/` (Flask on Render) | cloud | Accounts and households, storage, Claude labelling and reviews, daily summaries, the website |
| MongoDB Atlas | cloud | The service's database. Only the service talks to it; no Mac ever has a database address |

Records are written to disk first. The helper keeps each one queued in
`/Library/Application Support/FocusSprint/vault` until the service confirms it, so a lost connection loses nothing.

## Households

A household has an **admin**, optional **co-admins**, and **members** who are kids or other adults.

- Admins and co-admins sign in on the website, manage the household, and can see the **kids'** records.
- An **adult** member signs in to see their own records. An adult's records are private: nobody else in the household
  can see them, admins included. Admins are adults too, so their own computers are private in the same way.
- **Kids** have no sign-in. An admin adds them under People and links their computers.
- Accounts are by invitation. The service owner (the `PARENT_EMAIL` account) creates invitations for new households
  under Households; a household's admin invites co-admins and adult members under People.
- No household can see anything of another household. The service owner can see that a household exists and how
  many people and computers it has, never what it records.

### Linking a computer, and whose login is whose

1. Install the app on the Mac from an administrator account (`scripts/install.sh`, or the installer package).
2. On the website, open **Computers** and choose **Get a code**. In the app, in any login (the installing adult's is
   fine), open **Account** and type the code. It works once, for 15 minutes. The computer is now linked to the household.
3. Every Mac login on that computer then belongs to one person:
   - **From the website:** each login appears under the computer the first time it is used; an admin picks whose it is.
     A parent never needs to be let into a child's login.
   - **In the app:** an unassigned login opens on a "Who are you?" screen that stays in front and covers the app until
     a kid profile is picked. Only kid profiles not already taken on that computer are offered.
   - **Adults** are never in that list. An adult gets a code for themself on the website and types it in their own
     login; an admin can also assign a login to themself.

Until a login has a person, what it records waits on the Mac and is sent once it does. An admin can change a kid's
login on the website at any time, but cannot take over or hand out another adult's login.

The computer's token is stored where only root can read it; no password is typed on the Mac. Which login a record
came from is taken from who owns the file, not from what the app says. Each login's records on disk are readable by
that login only. Unlinking the computer needs the Mac administrator password; removing it on the website stops it at once.

### Setup (service owner, once)

1. Deploy the service (below) with `PARENT_EMAIL` and `PARENT_PASSWORD` set. On first start it creates your household,
   with you as admin, and moves any records made before accounts existed into your own, private, profile.
2. Sign in at the service's address. Add kids under People, link computers under Computers.
3. Each Mac's login for a kid must be a Standard account. An Administrator can delete anything on the Mac.

### The installer package

`scripts/package.sh` builds `build/YoungWonksFocus.pkg`, a normal Mac installer: a welcome screen, the administrator
password, and a last screen with the two steps left (allow screen recording, link the computer). It installs the app
for every login on the Mac, the background helper, and the two launch entries that start them. Running a newer
installer over an older one keeps the computer's link and everything recorded.

Unsigned, the package is only good for your own Macs. For anyone else, and for automatic updates, it has to be signed
with your Apple Developer ID and notarised by Apple.

### Releasing (service owner)

One-time setup, on the Mac you build on, with your paid Apple Developer account:

1. Xcode > Settings > Accounts > your Apple ID > Manage Certificates > **+** : create **Developer ID Application**
   and **Developer ID Installer**. `security find-identity -v` then lists both, with your team ID in brackets.
2. At appleid.apple.com create an app-specific password, then save it in the keychain under a name of your choice:
   `xcrun notarytool store-credentials youngwonks-notary --apple-id <your Apple ID> --team-id <TEAMID>`
   (it asks for the app-specific password; nothing is stored in this repository).

For every release: raise the number in `VERSION`, commit, then

```bash
DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: Your Name (TEAMID)" \
NOTARY_PROFILE=youngwonks-notary scripts/release.sh
```

That builds, signs, notarises and staples the installer, refuses to go on unless macOS accepts it, and attaches it
to a GitHub release `v<version>`. The Computers page links to the newest release by itself.

### Automatic updates

Every installed Mac asks the service (`/api/version`) for the current version a few minutes after starting and every
six hours. When there is a newer one the helper downloads the installer and installs it silently; the app restarts
by itself. The helper does not trust the service or the download. It installs a package only if

- macOS says the package is notarised by Apple,
- it is signed by the same Developer ID team as the helper already running, and
- the version inside it is newer than the installed one (an old genuine installer cannot roll a Mac back).

A development build, or one signed any other way, never updates itself. The Computers page shows each computer's
version and whether an update is still pending. A sprint that is running when an update lands is cut short.

## Apps

Every app seen in use on a linked Mac gets a label the first time: **Work**, **Distraction** or **Doesn't count**.
Claude picks it from the app's name; a household admin can change it on the website's Apps page (each adult
changes their own). The kids of a household share one list; an adult's list is private.

- All day, only apps labelled Distraction count. A Mac that is not linked yet uses a short built-in list.
- Setting up a sprint ticks the Work apps. Ticks can be changed for that one sprint; the sprint's record shows
  what was added or removed, so a parent sees it on the day's page.
- The app shows the same list under Apps. A kid sees it read-only. An adult can change their own list there, and a
  household admin or co-admin can also switch to the kids' list and change it. The helper tells the service which
  Mac login is asking, and the service decides whether that login may. Browsers are not listed: their time is
  judged per website.

## Website labels and "Needed for work"

Nothing is ever blocked. The app records and shows; the parent sees the same numbers.

- A website seen for the first time is sent (host name only) to the family service, which asks Claude whether it is
  productive or a distraction for a school-age student. The answer is stored once and reused.
- The list of distractions under Settings on the website always wins over the AI label.
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

- **Distraction** searches keep their words: shown in History and listed in the daily summary.
- **Work** searches are only counted.
- **Personal** searches (health, feelings, relationships, identity and the like) are counted with no words and no
  hint of the topic, on the Mac and in the database, so a student can still look for help.

### The website

- **Days:** the last 14 days with distraction level, time away, switches and distraction searches.
- **A day:** totals, sprints, web searches, "needed for work" requests and every switch away, newest first, with the
  pictures and a viewer (date, start, time away, end, previous / next).
- **Websites:** the kids' shared list (managed by admins) and each adult's own list, with a link to change a label.
- **People** (admins): add kids, invite adults and co-admins.
- **Computers:** link and remove computers.
- **Settings:** what is captured and the list of distractions, separately for the kids' computers and for your own;
  time zone and summary hour; your password.

Admins choose between all kids, one kid, or "Me". Kids are never mixed with an adult's own records.
The daily summary about the kids goes to every admin and co-admin; each adult gets their own.
Each household has a daily allowance of Claude calls (`FAMILY_DAILY_AI_CALLS`).

### Storage and clean-up

Pictures and clips are stored in Atlas itself (the `media` collection), about 170 KB per picture. To keep the
database from filling up, the service deletes media older than `MEDIA_KEEP_DAYS` (14 by default), checking once an
hour. Only the pictures go: the record of every switch, search and request is kept, so older days keep their numbers.
The Mac keeps its own local copies for the "keep local days" setting, independently of this.

### Deploying the service

`render.yaml` (at the top of the repository) describes it. In Render: New → Blueprint → this repository, then fill in the variables marked
`sync: false`: `MONGODB_URI` (an Atlas user with readWrite on the database), `ANTHROPIC_API_KEY`, `RESEND_API_KEY`,
`MAIL_FROM` (an address on a domain verified in Resend), `PARENT_EMAIL` and `PARENT_PASSWORD` (the owner's account),
`PUBLIC_URL` (the service's own address).
Set `TIMEZONE` to the family's time zone. The daily summary is sent by the service itself, so it must stay awake (not a free plan that sleeps).

Tests: `cd server && TEST_MONGODB_URI=mongodb://127.0.0.1:27017 .venv/bin/python -m pytest -q tests`

## What a Standard login cannot do

- Remove or replace the app, the helper or their launch files: the installer leaves them owned by root, and the app
  is restarted if it is quit.
- Unlink the Mac, or link it to a different account: both need the administrator password.
- Read the Mac's token, or delete what is waiting to be sent.

All of this depends on the login being a Standard account, and on the administrator password not being shared.

## Development

`scripts/dev-run.sh` runs the app and helper as yourself against `build/devroot`, with no installation.
`swift test` runs the unit tests; set `FOCUSSPRINT_TEST_MONGO` to a database with uploaded sprints to include the cloud read test.

## What it does not stop

- Quitting the app mid-sprint. The sprint then shows as "Interrupted" in History and in Atlas.
- Using a phone or another device during a sprint.
- Firefox and a few other browsers do not expose the tab address, so those are judged by tab title.
