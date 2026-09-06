# 0011 — First live deployment of Epidemica server and Epigames app

**Status:** backlog
**Filed:** 2026-09-06
**Touches:** `server`, `apps/epigames`, `deploy`

## What is wanted

To deploy the Epidemica server to AWS EC2 and the Epigames app to the Apple and Google stores.

## Why it matters

This will demonstrate that the platform is ready to support testing in the real world, a registered 
RCT Epidemica study has recruited participants but the currently available version of the Epigames app
does not have the functionality required for it. The new Epigame app developed with Epidemica solved 
that, mainly by incorporating the new logic for protection attributed by connectivity status, and the 
digital twin model that simulates transmission on the server side via virtual agents added to the 
population.

## What is already in place

- `studies/epigame7` would provide the bundle for the study, after adding study arms
- `studies/epigame-debug-rct` tests the randomization.
- `studies/epigames7-live-test.md` details the deployment (server/app) step-by-step. 
- Tasks 0002 (scheduled ticks), 0006 (no background sync), 0008 (survey module) have been done, as well
  as well as the randomization (not filed as task but implemented in commit 8899ee5)

## What actually blocks it

1. **Apple/Google guidelines for permissions**, to make it clear to participants why Bluetooth is required.
   The app may not be approved by Apple and Google if their guidelines are not properly followed.
2. **Current AWS deployment of Epigames server.** It's a Lambda architecture, which needs to be retired 
   prior to deployment of the new server to EC2.
3. **Conflation of consent and instructions.** The app currently shows a single screen with text explaining
   how it works, but this is not the stuy-approved consent languate.

## How it would be verified

- Deployment of the server and running app prior to release to stores with the URL of the deployed server 
  for internal testing.
- Use the epigames-demo study for additional local and live debugging.  
