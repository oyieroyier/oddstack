# Safety, State, and Observation Guide

Computer-use tasks can change local app state. Keep them narrow and observable.

## State checklist

Before delegation, capture:

- Which app or browser should be used.
- Which account/environment is safe.
- Whether the user is already signed in.
- Which data may be read or changed.
- Which actions are forbidden.
- Whether the task can safely continue if the machine locks or loses focus.

## Stop conditions

Tell Codex to stop and report if it sees:

- Login, MFA, password, recovery, API key, or private key prompts.
- Payment, billing, purchase, subscription, or irreversible confirmation prompts.
- Production-only data when a test/staging environment was expected.
- Unexpected app permission prompts.
- External navigation outside the allowed domain or app.
- Sensitive personal data not needed for the task.
- Ambiguous UI where the next action could be destructive.

## Evidence standards

Good evidence includes:

- Exact route/window/screen name.
- Screenshot/appshot path.
- Console and network errors.
- Expected versus actual behavior.
- Repro steps from a clean state.
- Commit/diff summary if code changed.
- Validation of the same flow after the change.

Weak evidence:

- "It looks fixed" without a repeated flow.
- Screenshot without route or viewport.
- Test pass without saying what was tested.
- UI observation without noting account/environment.

## Local web app guidance

For local apps, ask Codex to prefer:

- Existing E2E tests.
- Playwright/Cypress if already present.
- A temporary script only when it does not add committed dependencies.
- Browser console and network inspection.
- Screenshots at relevant viewports.

Do not let Codex commit local screenshots, videos, traces, or test artifacts unless the repo convention expects them.
