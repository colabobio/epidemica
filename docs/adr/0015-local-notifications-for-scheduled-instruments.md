# ADR-0015: Local notifications for scheduled instruments

- **Status:** Proposed
- **Date:** 2026-09-04
- **Deciders:** Colubri (PI)
- **Supersedes / Superseded by:** —

## Context

[`epidemica_survey`](../../packages/epidemica_survey) schedules instruments as an offset from a
study's start, and [`SurveyModule`](../../packages/epidemica_survey/lib/src/survey_module.dart)
decides correctly when one is due. Nothing tells the participant. The card appears on the game
screen, so a survey scheduled for "day 3, 09:00" is actually answered whenever the participant next
happens to open the app — which converts a scheduled measurement into an opportunistic one, and
silently correlates response timing with app-opening habits.

Three facts constrain the decision:

1. **There is no notification dependency anywhere in the repository.** This is the first one.
2. **Notifications are scheduled by the operating system, not by us.** Unlike upload, they do *not*
   depend on [`0006`](../../tasks/done/0006-no-background-sync.md): the OS fires them whether or
   not the app is running, so this is independent of the background-sync problem.
3. **Asking to interrupt someone is a request, not a technical step.** It needs a runtime permission
   on both platforms and a sentence in what a participant agrees to before joining.

The instrument content itself is already handled: definitions are closed-response only, so a
notification can safely carry the instrument's title without leaking anything a participant has not
already consented to see.

## Decision

We will deliver scheduled instruments with **OS-scheduled local notifications**, using
`flutter_local_notifications`, and we will ask for the permission at the moment the study first
schedules something rather than at enrollment.

**Licence.** `flutter_local_notifications` is **BSD-3-Clause** (verified on pub.dev, v22.3.0,
verified publisher, Flutter Favorite). BSD-3-Clause is permissive and one-way compatible with
Apache-2.0, so it satisfies [ADR-0009](0009-open-source-license.md). Its transitive dependencies —
notably `timezone` — must clear the same bar before adoption; a dependency is not checked until its
tree is.

**Permissions.**

| Platform | Requirement |
|---|---|
| iOS | `UNUserNotificationCenter` authorisation. Denied by default; a denied request cannot be re-prompted from inside the app. |
| Android 13+ | `POST_NOTIFICATIONS` runtime permission. Older releases grant it at install. |

**When we ask.** Not at enrollment, alongside Bluetooth. A participant joining a study is already
being asked for a radio permission and a consent screen; adding a third prompt to that sequence
buries it. We ask the first time a study actually schedules an instrument, with a sentence saying
what the notification is for.

**Consent text.** The information screen gains a line stating that the study will send reminders
when there is something to answer, and that declining them means answering when the app is next
opened. Declining is a supported state, not a degraded one: the card still appears.

## Consequences

**Positive.** A scheduled instrument is answered near the moment it was scheduled for, which is the
only thing that makes "15 minutes in" or "day 3" a measurement rather than a label. Response timing
stops being a proxy for how often someone opens the app.

**Negative.** A permission that can be denied, and on iOS denied permanently — so the app must work
properly without it, which means the in-app card is not a fallback but the primary path, and the
notification is an accelerator. A first-party dependency in a repository that has so far kept them
few. Notification copy becomes participant-facing study content, which means it is another thing an
IRB may want to see, and another thing to translate.

**Neutral.** Scheduling moves partly into the OS, so cancelling and rescheduling on bundle changes
becomes our responsibility: an instrument whose window has closed must not still fire.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Push notifications via FCM/APNs | Requires a server-side push service, per-app credentials, and a device token that is a new identifier to hold. Everything needed here is known on the device already. |
| In-app only, as today | Turns a scheduled measurement into an opportunistic one. Acceptable for a debug study, not for one making claims about timing. |
| Email or SMS reminders | Requires contact details the platform deliberately does not hold. Directly contradicts the pseudonymity the observation store is built on. |
| Silent background fetch that opens the app | Not possible on either platform, and would be hostile if it were. |

## Open questions

- Whether a participant who denies the permission should be told once, later, that they will not be
  reminded — or whether that is nagging.
- Whether notification copy belongs in the instrument definition (so it versions with the questions)
  or in the bundle's schedule entry (so it versions with the study's decision to ask). The second is
  probably right, since the *reason* for asking now is the study's, not the instrument's.
- Whether a missed window should notify at all. Firing "you have a survey" for one that expired
  minutes later is worse than silence.

## Validation

A study runs with instruments scheduled at several offsets. If the distribution of
`completed_at − due_at` is materially tighter than it is for the same study without notifications,
the decision paid for itself. If it is not — because participants ignore them — then the permission,
the dependency and the consent text bought nothing, and in-app delivery was sufficient all along.
