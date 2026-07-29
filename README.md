# Codex ↔ Claude Skills

An opinionated, configurable collaboration harness for handing bounded work between Claude Code and
Codex without losing scope, ownership, review evidence, or resume state.

It enforces conservative defaults around ownership, model spending, data egress, review scope, and
Git hook activation while allowing repository-specific commands and path policies.

The bundle supports both directions:

- Claude → Codex for implementation, investigation, adversarial review, and computer-use prompts.
- Codex → Claude for a frontend slice backed by a durable, bidirectional task backlog.
- Either model → the other for bounded, grounded ideation and architecture deliberation.

These are workflow and prompt wrappers. They do not install either CLI, authenticate accounts,
grant permissions, or bypass sandboxing.

The bundle also ships optional collaboration review hooks. Installing the bundle copies that module
but does not activate it or change Git configuration.

## Skills at a glance

| Skill                         | Invoked by  | Delegates to | Purpose                                                                      |
| ----------------------------- | ----------- | ------------ | ---------------------------------------------------------------------------- |
| `codex-implementation`        | Claude Code | Codex        | Bounded implementation, debugging, refactoring, tests, or investigation      |
| `codex-review`                | Claude Code | Codex        | Adversarial, read-only review of a diff, plan, branch, commit, or patch      |
| `codex-computer-use`          | Claude Code | Codex        | Safe preparation of browser, screenshot, desktop, or visual-QA work          |
| `ui-nitpicker`                | Claude Code | Codex        | UI implementation plus optional/required Codex frontend-logic audit          |
| `delegate-frontend-to-claude` | Codex       | Claude Code  | Backend-first delegation of a bounded frontend slice with resumable queues   |
| `deliberate-with-peer`        | Either      | Other model  | Grounded proposals, critique, adjudication, and bounded consensus            |
| `setup-collaboration-hooks`   | Codex       | —            | Safe installation, adaptation, composition, and deactivation of review hooks |

## How the two-way workflow works

| Phase          | Owner           | Responsibility                                                             |
| -------------- | --------------- | -------------------------------------------------------------------------- |
| 1. Scope       | Codex           | Record the request, ownership boundaries, queues, and starting state       |
| 2. Backend     | Codex           | Implement and verify backend behavior and shared contracts                 |
| 3. Frontend    | Claude          | Review the backend contract, implement the UI slice, and report findings   |
| 4. Return work | Codex or Claude | Route confirmed findings through the appropriate model queue               |
| 5. Audit       | Codex           | Audit Claude's frontend logic and report a separate evidence-based verdict |
| 6. Integration | Codex           | Inspect the complete diff, run combined checks, and update the backlog     |
| 7. Delivery    | Operator        | Decide whether to commit, push, open a pull request, or merge              |

Delegation state lives in:

```text
plans/agent-handoffs/<task-slug>.md
```

The backlog records stable task IDs, model-owned queues, contract checkpoints, blockers, changed
paths, verification evidence, the next owner, and an exact resume prompt. A temporary CLI prompt
points to this file; it never replaces it.

## Requirements

- Git repository with project instructions available to both agents.
- Claude Code CLI installed and authenticated for Claude-owned work.
- Codex CLI installed and authenticated for Codex-owned work.
- Bash 4 or newer for the installers, hook scripts, and bundled Claude runner.
- Git and standard Unix tools; AI pre-push review additionally requires `timeout` and `sha256sum`.
- Python 3 for peer preference parsing, session handling, alert configuration, and release archives.

Verify the CLIs:

```bash
command -v claude
claude --version
command -v codex
codex --version
codex exec --help | sed -n '1,80p'
```

Do not infer browser or computer-use support from the Codex CLI alone. Use those capabilities only
when the active environment visibly exposes them.

## Install into a project

Project-local installation is recommended because the skills and their assumptions can be reviewed
and versioned with the repository.

From this repository or an extracted release bundle:

```bash
./install.sh /path/to/your/repo
```

The installer copies:

```text
.claude/skills/*  →  /path/to/your/repo/.claude/skills/
.agents/skills/*  →  /path/to/your/repo/.agents/skills/
review-hooks/*    →  /path/to/your/repo/review-hooks/
```

The copied hook module remains inactive. Before writing anything, the installer compares every
existing bundled skill and `review-hooks/` directory with the bundle. Any drift is displayed and
preserved. After reviewing the diff, `--force` explicitly updates bundled files:

```bash
./install.sh --repo /path/to/your/repo --force
```

This makes repeat installation safe for repositories whose local skill copies have evolved. Files
that exist only in a drifted destination are retained even with `--force`; remove obsolete local
files as a separate, reviewable change.

To install manually:

```bash
mkdir -p /path/to/your/repo/.claude/skills
mkdir -p /path/to/your/repo/.agents/skills
cp -R .claude/skills/* /path/to/your/repo/.claude/skills/
cp -R .agents/skills/* /path/to/your/repo/.agents/skills/
cp -R review-hooks /path/to/your/repo/
```

Optionally copy the relevant content from
`CLAUDE.md.codex-skills-snippet.md` into the target repository's `CLAUDE.md`.

## Install for one user

Global installation makes the skills available across repositories, but project-local copies are
safer when repositories have different ownership or verification rules.

```bash
mkdir -p ~/.claude/skills ~/.agents/skills
cp -R .claude/skills/* ~/.claude/skills/
cp -R .agents/skills/* ~/.agents/skills/
```

## Verify installation

Run the read-only doctor against the target repository:

```bash
./doctor.sh --repo /path/to/your/repo
```

It reports a capability matrix covering bundled skill presence and drift, CLI availability, the
active Git hook path, hook executability, AI-review state, the `implement` → `/tdd` dependency,
manual page-audit safeguards, and release-archive freshness. Warnings are advisory by default;
`--strict` makes them fail. The doctor does not install skills, change Git config, enable AI review,
or approve pages.

For direct inspection from the target repository:

```bash
find .claude/skills .agents/skills -maxdepth 2 -name SKILL.md -print | sort
bash -n .agents/skills/delegate-frontend-to-claude/scripts/run-claude-frontend.sh
```

Expected skill entry points:

```text
.agents/skills/delegate-frontend-to-claude/SKILL.md
.agents/skills/deliberate-with-peer/SKILL.md
.agents/skills/setup-collaboration-hooks/SKILL.md
.claude/skills/codex-computer-use/SKILL.md
.claude/skills/deliberate-with-peer/SKILL.md
.claude/skills/codex-implementation/SKILL.md
.claude/skills/codex-review/SKILL.md
.claude/skills/ui-nitpicker/SKILL.md
```

## One-command bootstrap

`bootstrap.sh` is the single entry point for installing the bundled helpers and, when explicitly
requested, activating their deterministic hardening gates:

```bash
./bootstrap.sh \
  --repo /path/to/your/repo \
  --activate \
  --profile generic
```

It runs the doctor first, installs from the current bundle directory with drift protection,
activates `pre-commit` and `pre-push` through `core.hooksPath`, then runs the doctor again. Omit
`--activate` for install-only behavior.

The activation flag does not enable quota-consuming AI review, add CI secrets, configure branch
protection, or approve pages. Those remain separate operator decisions. Existing hook systems are
still refused unless the operator explicitly selects `--replace-hooks-path`; use manual composition
when both systems must remain active.

In an interactive terminal, bootstrap also asks whether to enable Claude Code's user-level terminal
bell when Claude finishes or needs attention. Automation can decide explicitly:

```bash
./bootstrap.sh --repo /path/to/your/repo --claude-alert enable
./bootstrap.sh --repo /path/to/your/repo --claude-alert skip
```

The setting is merged into `~/.claude/settings.json` without replacing other keys. It uses Claude
Code's supported `preferredNotifChannel: "terminal_bell"` setting; it does not install a
quota-consuming hook.

## Optional collaboration review hooks

The optional module separates deterministic commit checks from aggregate AI review:

```text
pre-commit → staged whitespace, secret scan, configured deterministic commands
pre-push   → configured deterministic commands → bounded aggregate AI review
```

Inspect its interface and perform a dry run before activation:

```bash
sed -n '1,260p' review-hooks/README.md
review-hooks/install.sh \
  --repo "$PWD" \
  --profile generic \
  --dry-run
```

The generic profile leaves AI review disabled. Activation is a separate explicit command:

```bash
review-hooks/install.sh \
  --repo "$PWD" \
  --profile generic
```

The installer refuses to replace an existing Husky, Lefthook, `.githooks`, or other
`core.hooksPath` configuration by default. Use `--no-activate` to compose with an existing system.
See [`review-hooks/README.md`](review-hooks/README.md) for the profile interface, resource budgets,
credential rules, deactivation, and the LMM reference adapter.

Repositories with a manual page-review ledger can add its advisory checker to
`PRE_PUSH_COMMANDS`. The LMM reference profile does this with `pnpm audit:pages`. Agents may detect
stale approvals, demote affected routes with a specific reason, register new routes as `PENDING`,
and report the operator queue. They must never approve a page: approval represents a person
physically inspecting the rendered surface.

## Optional engineering-flow dependency

The broader Matt Pocock engineering flow's `implement` skill invokes `/tdd`. This collaboration
bundle does not vendor that third-party flow, but the doctor detects a dangling reference when
`implement` is installed without `tdd`.

Install the upstream skill explicitly for agents that use that flow:

```bash
npx skills add https://github.com/mattpocock/skills \
  --skill tdd \
  --agent '*' \
  --global \
  --yes \
  --copy \
  --full-depth
```

Review upstream changes before updating it. Skill-directory install counts are discovery and
popularity signals, not security or quality audit evidence.

## Usage

### Claude → Codex implementation

Ask Claude Code:

```text
Use codex-implementation to implement the narrowest fix for this bug, then inspect the complete diff and run the relevant tests yourself.
```

### Claude → Codex review

```text
Use codex-review adversarially on my staged changes. Block on concrete correctness, security, migration, data, or compatibility issues.
```

### Claude → Codex visual or browser work

```text
Use codex-computer-use to prepare a scoped browser QA pass for the local checkout flow. Do not touch production, billing, or real customer data.
```

### Claude-owned UI work

```text
Use ui-nitpicker to review this dashboard against our design spec, write the implementation plan, implement it, then give Codex a read-only frontend logic audit under my peer-audit policy.
```

### Codex → Claude frontend delegation

Ask Codex:

```text
Use delegate-frontend-to-claude to record both model queues in a durable backlog, implement and verify the backend contract, delegate the bounded frontend slice to Claude, and verify the integrated result.
```

The Codex-side runner can also be invoked directly after creating the backlog and a filled handoff
prompt:

```bash
prompt_file="$(mktemp /tmp/claude-frontend-handoff.XXXXXX.md)"

.agents/skills/delegate-frontend-to-claude/scripts/run-claude-frontend.sh \
  --prompt-file "$prompt_file" \
  --backlog-file "plans/agent-handoffs/<task-slug>.md" \
  --repo "$PWD"
```

The runner refuses unrelated dirty files by default. Use `--allow-dirty` only after proving every
existing change belongs to the delegated task. Use `--dry-run` to validate the inputs without
launching Claude.

### Reciprocal frontend audit

Claude reviews Codex's backend and contract checkpoint before consuming it. After Claude implements
the frontend, Codex separately audits the Claude-authored logic before integration. The Codex
verdict covers state, data flow, contract consumption, permissions, failure states, accessibility
semantics, rendering cost, and test sensitivity; Claude retains design ownership and fixes its
frontend findings.

Direct Claude Code UI work gets the same opportunity through `ui-nitpicker` → `codex-review`. The
policy is `required`, `offer`, or `off`. An explicit skip records authority and reason; capacity or
execution failure is `INCONCLUSIVE`, never a pass.

### Grounded peer deliberation

Invoke `deliberate-with-peer` from either environment:

```text
Use deliberate-with-peer to evaluate whether this checkout workflow belongs in the API or web shell. Ground both positions in the repository, reconcile material disagreements, and preserve the decision record.
```

The initiator remains in its current thread. The runner starts one fresh peer session for the
decision and resumes that exact session for at most one focused rebuttal or confirmation. Session
ids, positions, evidence, disagreements, adjudication, and the exact resume prompt live in:

```text
plans/model-deliberations/<task-slug>.md
```

Architecture and implementation plans can select Codex as artifact author and Claude as
adversarial reviewer even when the request begins in Claude. The terminal states are `CONVERGED`,
`CONVERGED_WITH_DISSENT`, `NEEDS_EXPERIMENT`, `NEEDS_OPERATOR`, or an explicit capacity/execution
blocker. The flow never forces matching preferences or silently treats an unavailable peer as
agreement.

### Personal model and effort preferences

Copy and edit the non-executable JSON example outside the project:

```bash
mkdir -p ~/.config/codex-claude-skills
cp preferences.example.json ~/.config/codex-claude-skills/preferences.json
```

The example selects Claude Fable/high and GPT Sol/high for peer work, a two-call maximum,
resume-within-task sessions, Codex-authored architecture, and an `offer` peer-audit policy. Explicit
runner flags take precedence. Missing values preserve each environment's normal defaults. No
fallback model is selected automatically.

## Safety and ownership

- Keep the operator as the commit, push, and merge gate unless explicitly authorized otherwise.
- Give every task a stable ID and assign it to Codex, Claude, or the operator before delegation.
- Preserve unrelated work; never reset, stash, discard, or reformat it to manufacture a clean tree.
- Inspect staged, unstaged, and untracked files after every delegated run.
- Treat model summaries as leads, not proof. Re-run relevant checks in the integrating agent.
- Keep credentials, private data, production values, and unrelated diffs out of prompts.
- Escalate security and money-movement blockers to a human instead of silently downgrading them.
- Never mark a delegation complete while any model or operator queue still contains open work.

## Portability and current assumptions

The Claude → Codex skills are broadly repository-agnostic and instruct the agent to discover local
guidance before acting.

`delegate-frontend-to-claude` currently encodes the ownership model it was designed for:

- Codex owns backend services, APIs, SQL, migrations, and shared backend contracts.
- Claude owns `apps/web/` implementation and frontend tests.
- Non-trivial frontend work uses `ui-nitpicker`.
- Its handoff template references TanStack navigation, a design system, `pnpm` checks, and a page
  visual-audit workflow.

Before using that skill in a repository with a different layout or stack, adapt the ownership paths,
frontend guidance, validation commands, and visual-release rules. Do not let either model guess
replacement conventions.

## Bundle layout

```text
.agents/skills/
  deliberate-with-peer/
  delegate-frontend-to-claude/
    SKILL.md
    agents/openai.yaml
    references/
      delegation-backlog-template.md
      frontend-handoff-template.md
    scripts/run-claude-frontend.sh
  setup-collaboration-hooks/
    SKILL.md
.claude/skills/
  codex-computer-use/
  deliberate-with-peer/
  codex-implementation/
  codex-review/
  ui-nitpicker/
review-hooks/
  hooks/
  profiles/
  scripts/
  tests/
  README.md
  install.sh
scripts/configure-claude-alert.py
CLAUDE.md.codex-skills-snippet.md
README.md
LICENSE
bootstrap.sh
doctor.sh
install.sh
package.sh
preferences.example.json
tests/
codex-claude-skills.tar.gz
codex-claude-skills.zip
```

## Maintaining releases

The ZIP and TAR files are committed release artifacts. Rebuild both after any bundled skill,
installer, snippet, or README change:

```bash
./package.sh
```

Verify the archive entry points and test installation from an extracted archive before committing:

```bash
./package.sh --check
bash -n install.sh
tests/run.sh
review-hooks/tests/run.sh
git diff --check
```

When behavior changes, update the relevant skill, this README, and both archives in the same commit.
Use Git tags or GitHub releases when consumers need a stable version instead of tracking `main`.

## Author

Bob Oyier

## License

Licensed under the [MIT License](LICENSE).
