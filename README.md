# Meeting Minder

A macOS menu bar app that makes it very hard to miss a meeting.

It does two things:

1. **A full-screen blocker 5 minutes before every event**, on every display, above full-screen
   apps and the menu bar. It can be dismissed, or deferred with **Remind me 1 minute before**
   or **Remind me at meeting time**, and carries a **Join** button when the invite has a
   Google Meet, Microsoft Teams, Zoom, or Webex link.
2. **The next event's title in the menu bar** once it is within the next hour, truncated and
   followed by `in X m`. Beyond an hour the menu bar shows the icon alone — hover it to see
   what is next.

No Dock icon, no window — it is `LSUIElement`, menu bar only. Access to Google Calendar is
**read-only** (`calendar.readonly`), and everything stays on your Mac.

---

## Setting up Google access

The app talks to Google using **your own** OAuth client, so there is a one-time setup. It takes
about five minutes.

1. Open the [Google Cloud Console](https://console.cloud.google.com/) and create a project
   (or pick an existing one).
2. **APIs & Services → Library** → search for **Google Calendar API** → **Enable**.
3. **APIs & Services → OAuth consent screen**:
   - User type **External** (unless you have a Workspace org, in which case **Internal** is
     simpler — it skips the test-user step).
   - Fill in the app name and your email.
   - Under **Scopes**, add `.../auth/calendar.readonly`.
   - Under **Test users**, add your own Google address.
4. **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Desktop app**.
   - Name it anything, e.g. "Meeting Minder".
5. Copy the **Client ID** (and the **Client secret** if one is shown).
6. Open Meeting Minder's **Settings…** from the menu bar and paste them in.
7. Click **Sign in with Google…**. Your browser opens, you approve, and the tab confirms it is
   connected.

> An **External** consent screen left in *Testing* expires its refresh tokens after 7 days, so
> you would need to sign in again weekly. Publishing the app (**Publish app** on the consent
> screen) removes that limit. Because the client is only ever used by you, it does not need
> Google verification for this scope set to keep working — you will simply see an
> "unverified app" interstitial at sign-in, which you can click through with **Advanced →
> Go to … (unsafe)**.

---

## Building and running

```sh
# Build
xcodebuild -project "Meeting Minder.xcodeproj" -scheme "Meeting Minder" \
           -configuration Release -destination 'platform=macOS' build

# Tests
xcodebuild -project "Meeting Minder.xcodeproj" -scheme "Meeting Minder" \
           -destination 'platform=macOS' -only-testing:"Meeting MinderTests" test
```

Or just open the project in Xcode and hit ⌘R.

To keep it around, copy the built `Meeting Minder.app` into `/Applications`, then turn on
**Launch at Login** from the menu. (`SMAppService` is happiest with an app that lives in
`/Applications` rather than in DerivedData.)

There is one developer flag:

```sh
open -a "Meeting Minder.app" --args --preview-alert   # show a sample blocker immediately
```

The same thing is available at any time from the menu as **Test Alert**.

---

## How it behaves

**The alert fires** when `now` is inside `[start − 5 min, start + 2 min)`. The two-minute tail
means a Mac that was asleep through the warning window still tells you about the meeting you
are currently late for, rather than staying silent.

**Dismiss** silences that specific occurrence for good.

**The two reminder buttons are anchored to the meeting, not to when you pressed them** — so
pressing at four minutes out and at two minutes out both return the alert at the same instant.
*Remind me 1 minute before* returns it at `start − 1 min`; *Remind me at meeting time* returns
it at `start`. Each button withdraws itself once the meeting is too close for that reminder to
land in the future, so the one-minute option disappears first and you are never offered a
reminder that would fire immediately.

**Joining early re-arms rather than dismisses.** If you press **Join** more than 10 seconds before
the start, the alert comes back at meeting time — joining early then switching tabs is the
easiest way to miss a meeting you had every intention of attending. That includes joining from
the *1 minute before* reminder to check your audio and video. The alert says so before you press
it. Joining inside the last 10 seconds counts as joining on time and simply dismisses.

Moving a meeting in Google Calendar resets its state, so a rescheduled meeting warns you again.

**Skipped:** all-day events, cancelled events, and invitations you have declined. Events that
appear on more than one subscribed calendar are shown once, preferring your primary calendar's
copy.

**Refreshing** is a poll every 60 seconds over a 7-day window, plus an immediate refresh on
wake from sleep and whenever you open the menu. A poll needs no public webhook, is
self-correcting after network loss, and sits far inside Google's quota.

**Meeting links** come from `conferenceData` first, then the legacy `hangoutLink`, then a scan
of the location and description — which is how most Zoom and Teams invites arrive in a Google
Calendar.

---

## Where things live

| Path | What it does |
| --- | --- |
| `Meeting Minder/Meeting_MinderApp.swift` | Entry point and wiring; sets `.accessory` activation |
| `Meeting Minder/Auth/` | OAuth: PKCE, loopback redirect server, token exchange, storage |
| `Meeting Minder/CalendarKit/` | Calendar API client, event model, link detection, polling store |
| `Meeting Minder/Alerts/` | When to alert (`AlertScheduler`), the blocker windows, the SwiftUI alert |
| `Meeting Minder/MenuBar/` | Status item title and dropdown menu |
| `Meeting Minder/Settings/` | Settings pane |

## Privacy and security notes

- The OAuth scope is `calendar.readonly` plus `openid`/`email` (used only to label the menu).
  The app has no code that writes to your calendar.
- Sign-in uses the loopback redirect flow with PKCE. The local HTTP listener binds to
  `127.0.0.1` only, accepts exactly one redirect, and shuts down immediately after.
- The refresh token is stored in the Keychain. Locally-signed builds can be denied a keychain
  access group, so there is a fallback to a `0600` file inside the app's sandbox container.
- The app is sandboxed with only `network.client` (to reach Google) and `network.server`
  (for the sign-in redirect).
