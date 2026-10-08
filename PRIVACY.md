# Meeting Minder Privacy Policy

**Effective date:** 8 October 2026

Meeting Minder ("the app") is a macOS menu bar app. It reads your Google Calendar so it can show
your next meeting in the menu bar and alert you before each meeting starts. This policy explains what data the app accesses, how it uses that data, and
what it never does with it.

## Summary

- The app uses your Google data **only** to show your upcoming meetings and alert you before they
  start. It is not used for anything else, with no exceptions.
- Everything happens on your Mac. The app talks directly to Google and to no one else. It has no
  servers of its own, and your data is never sent to, seen by, or stored by anyone else.
- Your data is never sold, shared, or transferred, used for advertising, or used to train AI or
  machine-learning models.

## Google user data the app accesses

When you sign in with Google, the app asks for these permissions:

| Permission (scope) | What it allows | Why the app needs it |
| --- | --- | --- |
| `https://www.googleapis.com/auth/calendar.readonly` | Read-only access to your calendars and events | To find your upcoming meetings |
| `openid`, `email` | Your Google account's email address | To show which account is signed in |

The app cannot create, change, or delete anything in your Google Calendar or Google Account.

From Google Calendar, the app reads:

- **Your list of calendars:** each calendar's ID and name, and whether it is your primary calendar,
  shown in your calendar list, or deleted. This decides which calendars to check.
- **Events in the next seven days on those calendars:** title, start and end time and time zone,
  status (for example, cancelled), location, description, video-conferencing details (such as
  Google Meet, Zoom, Microsoft Teams, or Webex links), the event's Google Calendar link, the
  organizer's name and email address, and the attendee list (email addresses and responses).

## How the app uses this data

The data is used only to provide the app's features:

- Showing your next meeting in the menu bar and listing upcoming meetings in the menu.
- Showing a full-screen alert before a meeting starts, with its time, location, and number of
  guests.
- Finding the meeting's video-call link so you can join with one click.
- Skipping events you do not need an alert for, such as cancelled events and invitations you have
  declined (identified from your own response in the attendee list), and showing an event only once
  when it appears on more than one of your calendars.
- Showing your email address in the menu and in Settings, so you know which account is connected.

The data is not used for anything else. The app has no analytics, advertising, tracking, or crash
reporting, and it contains no third-party code.

## Where data is stored, and for how long

All data stays on your Mac.

- **Calendar data** is held only in the app's memory while it is running. It is refreshed about once
  a minute, is never written to disk or cached, and is discarded when you quit the app.
- **Sign-in credentials** (the access and refresh tokens Google issues, and your email address) are
  stored in the macOS Keychain. If the Keychain is unavailable to the app, they are stored instead in
  a file inside the app's private sandbox folder that only your macOS user account can read. They
  are kept until you sign out.
- **Settings** (the Google OAuth client ID and secret entered in Settings, and your preferences) are
  stored in the app's preferences on your Mac.
- **Diagnostic logs:** the app writes short diagnostic messages to the macOS system log, and these can
  include the titles of meetings it alerts you about. The log stays on your Mac and is managed and
  expired by macOS. The app never sends it anywhere.

## Sharing and disclosure

The app sends requests only to Google, and only to sign you in, keep you signed in, revoke access
when you sign out, and read your calendar. All of these connections are encrypted with HTTPS.

Your Google user data is never sold, rented, shared, disclosed, or transferred to anyone. Because it
never leaves your Mac, no one other than you can read it.

When you choose to join a meeting, the app opens that meeting's link in your web browser or meeting
app. What happens next is between you and the meeting provider (for example, Google Meet or Zoom),
under that provider's own privacy policy.

## Google API Services User Data Policy

Meeting Minder's use and transfer to any other app of information received from Google APIs will
adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

In particular, Meeting Minder:

- uses Google user data only to provide the user-facing features described in this policy;
- does not transfer Google user data to any third party;
- does not use Google user data for advertising, including personalized, retargeted, or
  interest-based advertising;
- does not sell Google user data, or use it to determine credit-worthiness or for lending purposes;
- does not allow any person to read Google user data;
- does not use Google user data to develop, improve, or train generalized AI or machine-learning
  models.

## Security

- Sign-in uses Google's OAuth 2.0 flow for desktop apps, protected with PKCE. You enter your Google
  password only on Google's own sign-in page in your browser. The app never sees it.
- Google returns the sign-in result to a temporary listener that accepts connections only from your
  own Mac (`127.0.0.1`). It accepts a single response and then shuts down.
- The app runs in the macOS App Sandbox, which limits what it can access on your Mac.

## Your choices: revoking access and deleting your data

- **Sign out** from the app's menu or Settings. This deletes the stored credentials from your Mac and
  asks Google to revoke the app's access.
- **Revoke access at any time** from your Google Account at
  [myaccount.google.com/connections](https://myaccount.google.com/connections).
- **Remove everything:** sign out, quit the app, delete it, and then delete its folder at
  `~/Library/Containers/valorstudio.Meeting-Minder`.

No copy of your data is held anywhere other than your Mac, so these steps remove it completely.

## Children

The app is not directed at children under 13, and it does not collect personal information from
anyone, including children.

## Changes to this policy

If this policy changes, the updated version will be published here with a new effective date. If a
change would affect how the app uses Google user data, the app will ask for your consent before the
change applies to you.
