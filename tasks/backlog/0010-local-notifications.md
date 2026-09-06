# 0010 — Local notifications for scheduled instruments

**Status:** backlog
**Filed:** 2026-09-05
**Touches:** `packages/epidemica_survey/`, `apps/epigames`, `apps/*/ios/Runner/Info.plist`,
`apps/*/android/app/src/main/AndroidManifest.xml`, the consent screen
**Decision:** [ADR-0015](../../docs/adr/0015-local-notifications-for-scheduled-instruments.md)
— *Proposed*. That ADR settles the what and the why; this is the what-to-change.

## What is wanted

A participant is told when an instrument is due, instead of discovering it the next time they happen
to open the app.

## Why it matters

`SurveyModule` already decides correctly when something is due, and nothing acts on that. A survey
scheduled for day 3 at 09:00 is answered whenever the app is next opened, which turns a **scheduled
measurement into an opportunistic one** and correlates response timing with app-opening habits. For
Epigames the survey *is* the research output, so this is a measurement-validity problem rather than
a convenience feature.

It is also the last substantive gap in [0008](../done/0008-survey-module.md).

## What is already in place

- `SurveySchedule.dueAt` computes due times from either anchor, using the study's own interval.
- Completion is already tracked per instrument in the module store and already survives restart —
  and is already wiped by `withdraw()`, which is the correct behaviour for cancellation too.
- Instrument definitions are closed-response only, so a notification may safely carry the title.
- ADR-0015 has already cleared `flutter_local_notifications` as BSD-3-Clause.

## What actually blocks it

**Nothing structural.** It is the first notification dependency in the repository, so the cost is
platform plumbing and a consent change rather than design.

1. **Licence-check the transitive tree**, notably `timezone`. ADR-0009 applies to the whole tree, and
   a dependency is not checked until its dependencies are.
2. **Permissions.** iOS `UNUserNotificationCenter`, Android 13+ `POST_NOTIFICATIONS`. Asked when a
   study first schedules something, not at enrollment — see the ADR.
3. **Consent text** on the information screen, before joining.

## Traps

**A denied iOS authorisation cannot be re-prompted from inside the app.** Asking at the wrong moment
permanently costs that participant's reminders, which is why the ADR moves the prompt away from the
enrollment sequence. Treat the denial as a durable state and render the schedule in-app instead.

**Notifications must be rescheduled on launch, idempotently.** OS-scheduled notifications do not
survive reinstall, and a naive reschedule-on-every-launch produces duplicates. Cancel by a
deterministic id derived from `instrument_id@version` and the occurrence, then re-add.

**A completed instrument must cancel its notification.** Completion is device-side; a participant who
answers early and is then reminded will reasonably assume the answer was lost.

**`withdraw()` must cancel everything.** It wipes local state by design, and a withdrawn participant
receiving study reminders is the worst version of this bug.

**Android 14+ restricts exact alarms.** `SCHEDULE_EXACT_ALARM` is not grantable for this use case;
inexact delivery is appropriate here and the schedule should not assume minute precision.

**The schedule is in absolute instants, the notification is in local time.** `dueAt` returns an
instant derived from the study start or enrollment. Converting through the device's current zone is
correct, but a participant who crosses zones mid-study must not have already-scheduled reminders
silently shift relative to the study day.

## How it would be verified

- Scheduling tests against a fake clock: a notification is scheduled for each due instrument, none
  for a completed one, none for one already past its close.
- Relaunching twice schedules one notification, not three.
- Completing an instrument cancels exactly its own notification and leaves the others.
- `withdraw()` leaves nothing pending.
- A denied permission degrades to the in-app card with no crash and no repeated prompting.
- End to end on [`studies/epigame-debug`](../../studies/epigame-debug), where the check-in is due
  60 seconds in: the notification arrives with the app backgrounded.
