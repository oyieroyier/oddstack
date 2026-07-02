# Codex Computer Use Prompt Template

Use this template for GUI, browser, screenshot, and visual QA tasks.

```markdown
You are Codex working on a tightly scoped UI/computer-use task. Use the safest available method: repository inspection and tests first; browser automation or Browser use for rendered web flows; true Computer Use only when the task cannot be completed through structured tools.

## Goal
[Exact user-visible outcome.]

## Target
- App/browser/route/simulator/screenshot: [target]
- Environment: [local/staging/test only]
- Starting state: [what should already be open, running, signed in, or configured]

## Allowed actions
- [read/click/type/navigate/run local server/capture screenshot/etc.]

## Prohibited actions
- Do not enter passwords, recovery codes, private keys, payment details, or secrets.
- Do not purchase, delete, deploy, invite real users, change account security, or perform irreversible actions.
- Do not navigate outside [allowed host/app/scope].
- Stop and report if login, production data, destructive prompts, or unexpected permission dialogs appear.

## Flow
1. [Step]
2. [Step]
3. [Step]

## What to inspect
- Functional correctness.
- Loading, empty, error, success, and retry states.
- Keyboard and focus behavior.
- Mobile/responsive behavior if relevant.
- Console/network errors if available.
- Visual mismatch against screenshot/spec if provided.

## If fixing code
- Make the smallest focused change.
- Do not rewrite unrelated UI.
- Preserve existing component APIs and styling conventions.
- Add or update tests where feasible.
- Rerun the same UI flow after the fix.

## Required report
Return:
1. Result: fixed / reproduced-only / not-reproduced / blocked.
2. Steps performed.
3. Expected vs actual result.
4. Evidence: screenshot paths, console errors, network errors, logs.
5. Files changed.
6. Validation commands or repeated UI flow.
7. Risks and coverage gaps.
```
```

## Screenshot-only variant

```markdown
You have been given one or more screenshots. Analyze them against the repository implementation. Identify the likely source files and the smallest fix. If running in read-only mode, do not edit; return a plan. If running in workspace-write mode, implement the fix and explain how you validated it.
```

## QA report variant

```markdown
Perform a QA pass over these flows: [flows]. Do not fix code unless explicitly asked. Report every bug with severity, repro steps, expected result, actual result, evidence, and likely owner/file area.
```
