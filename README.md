# Codex ↔ Claude Skills

A project-local skill bundle for handing bounded work between Claude Code and Codex without losing
scope, ownership, review evidence, or resume state.

The bundle supports both directions:

- Claude → Codex for implementation, investigation, adversarial review, and computer-use prompts.
- Codex → Claude for a frontend slice backed by a durable, bidirectional task backlog.

These are workflow and prompt wrappers. They do not install either CLI, authenticate accounts,
grant permissions, or bypass sandboxing.

## Skills at a glance

| Skill                         | Invoked by  | Delegates to | Purpose                                                                    |
| ----------------------------- | ----------- | ------------ | -------------------------------------------------------------------------- |
| `codex-implementation`        | Claude Code | Codex        | Bounded implementation, debugging, refactoring, tests, or investigation    |
| `codex-review`                | Claude Code | Codex        | Adversarial, read-only review of a diff, plan, branch, commit, or patch    |
| `codex-computer-use`          | Claude Code | Codex        | Safe preparation of browser, screenshot, desktop, or visual-QA work        |
| `ui-nitpicker`                | Claude Code | —            | Exacting UI review and plan-first frontend implementation                  |
| `delegate-frontend-to-claude` | Codex       | Claude Code  | Backend-first delegation of a bounded frontend slice with resumable queues |

## How the two-way workflow works

| Phase          | Owner           | Responsibility                                                           |
| -------------- | --------------- | ------------------------------------------------------------------------ |
| 1. Scope       | Codex           | Record the request, ownership boundaries, queues, and starting state     |
| 2. Backend     | Codex           | Implement and verify backend behavior and shared contracts               |
| 3. Frontend    | Claude          | Review the backend contract, implement the UI slice, and report findings |
| 4. Return work | Codex or Claude | Route confirmed findings through the appropriate model queue             |
| 5. Integration | Codex           | Inspect the complete diff, run combined checks, and update the backlog   |
| 6. Delivery    | Operator        | Decide whether to commit, push, open a pull request, or merge            |

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
- Bash for `install.sh` and the bundled Claude runner.
- Python 3 only when rebuilding the ZIP archive with the documented release command.

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
```

To install manually:

```bash
mkdir -p /path/to/your/repo/.claude/skills
mkdir -p /path/to/your/repo/.agents/skills
cp -R .claude/skills/* /path/to/your/repo/.claude/skills/
cp -R .agents/skills/* /path/to/your/repo/.agents/skills/
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

From the target repository:

```bash
find .claude/skills .agents/skills -maxdepth 2 -name SKILL.md -print | sort
bash -n .agents/skills/delegate-frontend-to-claude/scripts/run-claude-frontend.sh
```

Expected skill entry points:

```text
.agents/skills/delegate-frontend-to-claude/SKILL.md
.claude/skills/codex-computer-use/SKILL.md
.claude/skills/codex-implementation/SKILL.md
.claude/skills/codex-review/SKILL.md
.claude/skills/ui-nitpicker/SKILL.md
```

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
Use ui-nitpicker to review this dashboard against our design spec, then write the implementation plan before changing the UI.
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
  delegate-frontend-to-claude/
    SKILL.md
    agents/openai.yaml
    references/
      delegation-backlog-template.md
      frontend-handoff-template.md
    scripts/run-claude-frontend.sh
.claude/skills/
  codex-computer-use/
  codex-implementation/
  codex-review/
  ui-nitpicker/
CLAUDE.md.codex-skills-snippet.md
README.md
install.sh
codex-claude-skills.tar.gz
codex-claude-skills.zip
```

## Maintaining releases

The ZIP and TAR files are committed release artifacts. Rebuild both after any bundled skill,
installer, snippet, or README change:

```bash
repo_root="$PWD"
release_dir="$(mktemp -d /tmp/codex-claude-skills-release.XXXXXX)"
package_dir="$release_dir/codex-claude-skills"

mkdir -p "$package_dir"
cp -R .agents .claude "$package_dir/"
cp README.md CLAUDE.md.codex-skills-snippet.md install.sh "$package_dir/"

tar -C "$release_dir" \
  -czf "$repo_root/codex-claude-skills.tar.gz" \
  codex-claude-skills

(
  cd "$release_dir"
  python3 -m zipfile \
    -c "$repo_root/codex-claude-skills.zip" \
    codex-claude-skills
)
```

Verify the archive entry points and test installation from an extracted archive before committing:

```bash
tar -tzf codex-claude-skills.tar.gz | sort
python3 -m zipfile -l codex-claude-skills.zip
bash -n install.sh
git diff --check
```

When behavior changes, update the relevant skill, this README, and both archives in the same commit.
Use Git tags or GitHub releases when consumers need a stable version instead of tracking `main`.
