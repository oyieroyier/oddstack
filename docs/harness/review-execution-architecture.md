# Review execution harness architecture

Status: Proposed  
Date: 2026-07-30  
Owner: collaboration harness maintainers

## Decision

Replace the aggregate review shell pipeline with a small command-line interface backed by a
Python standard-library module. Keep the Git hooks as thin adapters. Put target selection, policy
validation, prompt construction, process supervision, result parsing, evidence, and cache rules
behind the module interface.

The review process gets one time limit and one spend limit for the whole run. The process
supervisor starts the reviewer in a new process group, captures output without a shell pipeline,
and reaps the full group on every exit path. Every run writes evidence, including an
`INCONCLUSIVE` run.

Local pre-push hooks verify a cached review by default. A separate local command creates that
review before `git push` opens an SSH connection. CI may run a missing review when its profile
owns the credentials and budget.

## Incident

The Lipa Mdogo Mdogo consumer exposed six faults in the current bundle:

- `AI_REVIEW_TIMEOUT=600` applied to each attempt. Two attempts could use about 20 minutes.
- The runner used `timeout | head` without a module that owned the reviewer process group.
  Descendants and open pipes could outlive the shell that launched them.
- The retry loop repeated every non-zero result, including timeouts and faults that another
  attempt could not fix.
- An output flood was retried at full price. `head -c` closed the pipe at the byte cap, the
  reviewer took `SIGPIPE`, the pipeline exited 141, and the loop bought a second attempt of the
  same over-producing review.
- Any non-empty `AI_REVIEW_HUMAN_ACK` value waved through every blocking review on every push.
  An operator who exported it once in a shell profile turned the blocker gate off permanently,
  with no warning and no binding to a specific review.
- Failed attempts returned a short message such as `15B output` but did not write an attempt
  report. The operator could not tell whether the cause was startup, quota, timeout, output,
  parsing, or cleanup.

The wider recovery also observed one review process for 4 hours, 16 minutes, and 17 seconds. That
duration is not enough to prove which launcher owned the process, but it proves the harness lacked
evidence that could assign ownership. Later aggregate attempts ended `INCONCLUSIVE` while two
independent reviews passed. The operator had to publish through a recorded human decision because
the aggregate gate could neither complete nor explain its failure.

A consumer-side repair in LMM commit `8b82f3b6` added a kill grace and shared elapsed-time check.
That repair limits the observed failure, but it leaves the main behavior in a large shell script
and lets the bundle and consumer drift.

The long review also kept a Git push connection open. The remote closed that idle connection
before the hook finished. Retrying the push could then start another paid review unless the first
run had produced a valid cache entry.

## Goals

The harness must:

1. stop the reviewer process group within the configured total time plus kill grace;
2. keep the sum of attempt spend caps at or below the run spend cap;
3. retry only a named, short-lived infrastructure fault;
4. make no paid call without CI credential scope or a one-run personal opt-in;
5. bind a decision to the base, tree, review policy, prompt version, and reviewer identity;
6. write enough evidence to diagnose every terminal result;
7. let `git push` verify a completed review without holding an SSH connection during model work;
8. keep reviewer choice explicit and never fall back to another model;
9. give installers a clear way to detect old runtimes and profiles;
10. bound cumulative paid spend across runs with a rolling ledger, not only per run.
11. let repositories preserve non-blocking findings before a completed decision becomes reusable.

## Non-goals

This change does not:

- choose which model should review a repository;
- remove the human merge gate;
- send sensitive paths to an external model;
- replace repository-specific deterministic checks;
- approve visual release records;
- promise a cross-provider measure of actual token or dollar use when a CLI does not report it.

## Module boundary

`review_gate` is the deep module. Its interface accepts a review target and policy, then returns
one decision and an evidence path.

```text
Git pre-push adapter ─┐
                      ├─> review_gate ─> reviewer adapter ─> Claude CLI
operator command ─────┘        │
                               ├─> evidence store
                               └─> decision cache
```

The hook adapter captures Git's standard input once and calls the module. It does not build
prompts, parse verdicts, manage retries, or kill processes. The Claude adapter knows CLI flags and
output format but does not decide policy. Tests use a fake reviewer adapter through the same seam.

The module hides these implementation parts:

- target resolver;
- policy validator;
- scope classifier and prompt builder;
- run budget ledger;
- reviewer process supervisor;
- result parser;
- evidence renderer and store;
- decision cache and incremental state store.

This boundary gives the module depth: callers see one decision while the module owns the failure
and cleanup rules. It also improves locality. Retry rules, process cleanup, and evidence for a
failed attempt change together inside one module. The same supervisor and evidence contract give
design leverage to each reviewer adapter without copying safety code.

## Public command interface

The installed runtime exposes one executable:

```text
.review-hooks/bin/review-gate review \
  --base <commit> \
  --head <commit> \
  --local-ref <ref>

.review-hooks/bin/review-gate check-push \
  --updates-file <path> \
  --mode verify|run-if-missing

.review-hooks/bin/review-gate acknowledge \
  --report <path> \
  --reason <ticket-or-reason>
```

`review` is the local preflight command. It resolves and reviews one exact base/tree pair without
opening a push connection.

`check-push` converts one Git push update into the same target. `verify` accepts only a matching
completed decision. `run-if-missing` may call the reviewer if credential and budget policy allow
it. The profile selects the mode. Version 2 profiles default local hooks to `verify`.

`acknowledge` records a human decision against the report digest, base, tree, risk class, and
policy hash. A free text environment variable must not act as a reusable override.

One environment escape remains for the operator: skipping review entirely. A version 2 skip
requires `SKIP_AI_REVIEW` to hold at least the first 12 characters of the pushed commit and a
non-empty reason, and it writes its own evidence run. The binding to the exact commit means an
exported value cannot skip any later push. This deliberately trades strength for an emergency
path: an operator with repository write access can always disable a local gate, so the harness
makes the escape explicit, single-use, and recorded instead of pretending to prevent it.

All commands use these exit codes:

| Code | Meaning |
| --- | --- |
| `0` | accepted by a completed review, matching cache entry, or bound human acknowledgement |
| `1` | completed review has blocking findings |
| `2` | no trustworthy decision: policy, input, reviewer, timeout, output, parse, or cleanup fault |

The existing `run-ai-review-gate.sh` remains for one release as a compatibility adapter. It
forwards to `review-gate check-push` and prints a migration warning.

## Policy version 2

Version 2 profiles replace ambiguous controls:

```bash
REVIEW_HOOKS_PROFILE_VERSION=2
AI_REVIEW_PUSH_MODE=verify
AI_REVIEW_TOTAL_TIMEOUT=600
AI_REVIEW_KILL_GRACE=5
AI_REVIEW_MAX_ATTEMPTS=1
AI_REVIEW_RETRYABLE_FAILURES=''
AI_REVIEW_MIN_RETRY_TIME=30
AI_REVIEW_MAX_PRIOR_REPORT_BYTES=12000
AI_REVIEW_MAX_OUTPUT_BYTES=30000
AI_REVIEW_MAX_BUDGET_USD=2.00
AI_REVIEW_MODEL='claude-sonnet-5'
AI_REVIEW_ROLLING_SPEND_LIMIT_USD=10.00
AI_REVIEW_ROLLING_SPEND_WINDOW_HOURS=24
```

`AI_REVIEW_MODEL` names the reviewer model. The adapter passes it on every launch; a paid run
must not inherit whatever default the operator's interactive CLI happens to use. Version 2
refuses to start a paid attempt without it.

`AI_REVIEW_TOTAL_TIMEOUT` starts after policy and target validation and covers prompt creation,
all reviewer attempts, result parsing, and process cleanup. The monotonic deadline never resets.
An attempt does not start when the remaining time is below `AI_REVIEW_MIN_RETRY_TIME`.

The spend cap is also run-wide. Before launch, the budget ledger assigns each possible attempt a
cap whose sum cannot exceed `AI_REVIEW_MAX_BUDGET_USD`. The evidence records assigned caps and
actual use when the reviewer reports it.

Spend is also bounded across runs. Before its first launch, every paid run takes an exclusive
lock on `ai-reviews/spend/ledger.jsonl`, sums the recorded spend inside
`AI_REVIEW_ROLLING_SPEND_WINDOW_HOURS` (counting the assigned cap when actual use is unknown),
and appends its own reservation under the same lock. When the sum plus the new run's cap passes
`AI_REVIEW_ROLLING_SPEND_LIMIT_USD`, the run ends `INCONCLUSIVE` before any reviewer starts.
Reserving before launch means a crash mid-run can never leave paid spend unrecorded, and two
concurrent runs cannot both squeeze under the limit. When the reviewer CLI reports actual spend
(`total_cost_usd` in its JSON envelope), the run appends a settlement entry under the same lock;
the window sum keeps only the newest entry per run id, so the settlement supersedes the
reservation without rewriting it, and a crash mid-settle leaves the conservative reservation
standing. A launched attempt that reports no cost keeps its full assigned cap; an attempt that
never launched settles to zero. Version 1 profiles keep the plain-stdout reviewer contract for
their compatibility release and never settle. This stops scope
creep in a calling agent — many pushes with slightly different trees — from buying an unbounded
series of individually-in-budget reviews, without letting unreconciled reservations pile phantom
spend against the limit. Set the limit to `0` to disable the rolling check. `verify` mode never
spends, so it never consults the ledger.

The default is one attempt. A profile may raise it to two and opt into a failure listed in
`AI_REVIEW_RETRYABLE_FAILURES`. The first version supports `startup_transport`: a known adapter
startup or transport failure that ends before the short retry window and before a review result
begins. The ledger reserves both attempt caps before the first launch and settles them to the
adapter's reported actual spend once the run ends; a cap is only reclaimed through that
settlement, never by assumption.

The runner does not retry:

- timeout or forced cleanup;
- output overflow;
- invalid or partial result data;
- prompt or diff budget failure;
- missing CLI or invalid profile;
- credential or quota refusal;
- sensitive input;
- a completed `INCONCLUSIVE` verdict;
- blocking findings.

The adapter maps only documented CLI exit data to `startup_transport`. Unknown exit codes and
free-form stderr stay `unknown_infrastructure` and do not retry.

The compatibility adapter accepts version 1 names for one release, but maps
`AI_REVIEW_TIMEOUT` to the safer run-wide deadline and does not retain unconditional retries. The
installer and doctor warn that version 1 used old timeout and retry meanings. Strict doctor mode
fails until the profile moves to version 2.

## Process supervision

The production Claude adapter starts the CLI with `subprocess.Popen(..., start_new_session=True)`.
It sends the prompt through a file handle. The supervisor owns nonblocking standard-output and
standard-error pipes and drains them with `selectors`. It retains no more than the combined byte
cap. It does not create a shell producer or `head` pipeline.

The supervisor uses `time.monotonic()`. It ends the attempt when the child and owned pipes close,
the deadline expires, or combined captured output passes the byte cap. If the direct child exits
while another group member holds a pipe open, the supervisor treats the group as still active.

On timeout, overflow, cancellation, or an internal exception, the supervisor:

1. sends `SIGTERM` to the reviewer's process group;
2. waits no longer than the configured kill grace;
3. sends `SIGKILL` to the process group if any member remains;
4. waits for and reaps the direct child;
5. checks that the process group no longer exists;
6. records cleanup outcome before returning.

Failure to prove cleanup is `INCONCLUSIVE` and gets its own reason code. Temporary directories use
mode `0700`. Cleanup happens after evidence has copied bounded diagnostics.

A POSIX process group cannot contain a child that deliberately calls `setsid()`. Reviewer adapters
must declare that they do not daemonize or move work into another session. Evidence records
`containment: process-group` and does not claim more. A future adapter that needs to run
daemonizing tools must add a stronger operating-system boundary, such as a delegated cgroup, and
its own containment tests before the harness accepts it.

## Result contract

Profile version 2 asks the reviewer for one JSON result between fixed sentinels. The adapter
validates it against a versioned schema before the harness renders Markdown.

Required fields are:

```json
{
  "schema_version": 1,
  "verdict": "SAFE",
  "risk_class": "none",
  "findings": [],
  "limitations": []
}
```

Each finding contains severity, file, line, trigger, consequence, and proposed fix. Allowed
verdicts remain `SAFE`, `MERGE-WITH-FIXES`, `DO-NOT-MERGE`, and `INCONCLUSIVE`. Blocking status is
derived from verdict and findings; the model does not supply a second field that can conflict.

The compatibility adapter can parse the three legacy markers. New evidence marks that parser as
`legacy-v1`.

Incremental reviews include structured open findings from the last completed report. They do not
paste an unbounded Markdown report. The prompt builder enforces the prior-report byte cap and the
total prompt cap after it has built the full prompt.

## Evidence

Every invocation that reaches a decision or a refusal writes evidence. A push with nothing to
review — no branch update, or an empty diff against a trustworthy base — writes none; there was
no decision to record. Every other terminal path, including every `INCONCLUSIVE`, writes:

```text
ai-reviews/runs/<run-id>/run.json
ai-reviews/runs/<run-id>/report.md
ai-reviews/runs/<run-id>/attempt-1.json
ai-reviews/runs/<run-id>/attempt-1.stdout
ai-reviews/runs/<run-id>/attempt-1.stderr
```

Output files are bounded and state whether truncation occurred. `run.json` contains:

- run and schema versions;
- base, head, tree, local ref, and file list digest;
- policy, prompt, and reviewer identity hashes;
- credential scope and personal opt-in state;
- UTC start and end time, plus elapsed monotonic duration;
- total time and spend caps;
- each attempt's cap, exit code, signal, duration, byte counts, and reason code;
- process-group cleanup result;
- parsed decision or terminal failure;
- cache and prior-report inputs;
- acknowledgement digest when present.

`report.md` is the operator view. It links the machine record and includes bounded stderr for a
failed attempt. `ai-reviews/latest.md` points to or copies the latest report for every outcome,
including `INCONCLUSIVE`.

The harness must not write prompt text or raw diffs to evidence by default. Their hashes and file
digests are enough to bind the run without making a second copy of source that may contain private
data.

## Cache and state

A decision cache key includes:

```text
base + tree + policy_hash + prompt_template_version + reviewer_identity
```

The reviewer identity includes adapter, provider, model when known, and a CLI capability
fingerprint. The fingerprint hashes the resolved executable path, size, and modification time
instead of running `--version`: a run-time probe would cost a process launch on every push, and a
misbehaving CLI could stall it. A CLI upgrade changes the fingerprint, misses the cache, and buys
a fresh review. Changing scope rules, prompt rules, budgets that affect completeness, or reviewer
identity causes a cache miss.

Version 2 requires an explicit model identity before it can reuse a decision. If the reviewer CLI
cannot expose its effective model before launch, the profile must name the model. A run with an
unknown model may write evidence but cannot write a reusable decision cache entry.

If the remote base changes after local preflight, `check-push` gets a different cache key and
fails quickly in `verify` mode. It never stretches an older review over the new range.

Only a parsed, completed review writes a decision cache entry. `INCONCLUSIVE` evidence never acts
as a decision. A completed blocking review may be cached so repeated pushes do not buy the same
answer. A bound human acknowledgement can accept that exact cached decision.

A version 2 profile may name a repository-owned durable-intake command; version 1 profiles that
name one are refused. For a fresh completed non-blocking `MERGE-WITH-FIXES` decision, the harness
runs that command from the repository root with the reviewed head in `AI_REVIEW_HEAD_COMMIT` and
the parsed result on its standard input as JSON — schema version, run id, start time, base, head,
verdict, risk class, the complete finding set, and limitations. It also exports `CATALOG_COMMIT`
with the same value for one release, so an updater written against the pre-2.2.0 name does not
silently receive an empty commit. Because intake precedes finalization the run's report does not
yet exist, so that payload is the only material the command has and must suffice to write a tracked
artifact immediately; carrying the run id and start time lets a consumer mint durable identifiers
that match the finalized run. Raw reviewer text is never included. The finding set is never
truncated — reviewer output is already bounded by the output cap, and re-capping intake would drop
accepted findings from the artifact intake exists to produce. It
must succeed before review evidence is finalized and before the decision cache or incremental
branch state is written; evidence is finalized exactly once, with the terminal outcome. The
command is bounded by both a 60-second cap and the remaining run deadline and runs in a supervised
process group whose descendants are terminated and reaped on failure; its output is captured
bounded for diagnostics, and output volume alone never fails it. Failure is recorded as the
terminal inconclusive outcome while retaining the parsed reviewer decision as context; SAFE
decisions, blocking decisions, a disabled command, and exact cache reuse bypass the command — a
blocking decision persists through its cache entry and the bound acknowledgement flow, which a
broken updater must not destroy. Its text participates in the policy hash, so enabling or changing
intake cannot reuse a decision cached under different persistence policy. The harness does not
prescribe the tracked artifact format or copy reviewer text itself; secret exclusion, redaction,
reconciliation, and committing generated intake remain consumer-owned policy.

A cache entry proves its own consistency before it acts: its stored base, tree, policy hash,
prompt version, and reviewer identity must match the live target; its report must sit inside the
evidence store and match the stored digest; and blocking is derived from the verdict and finding
counts, never read from a stored flag. These checks defend against staleness, copied entries, and
accidental edits. They are not authentication: a local writer who could forge a fully consistent
entry could equally skip or disable the gate, so the trust boundary is the repository itself.

The prompt builder refuses to build a prompt whose diff or prior findings contain the result
sentinel. A committed result block could otherwise be echoed by the model and parsed as the
verdict. The refusal fails closed as `INCONCLUSIVE`; prompt injection that merely persuades the
reviewer remains an accepted limit of any model-based gate.

Branch incremental state uses atomic JSON writes and refers only to completed reports. It binds
to the policy hash, prompt template version, and reviewer identity that produced it: a changed
policy, prompt, or reviewer reviews the full range again rather than inheriting an earlier
reviewer's coverage of older commits. Missing, malformed, moved, ancestry-invalid, or
binding-mismatched state is ignored and recorded; it is not a reason to paste unknown content
into a prompt.

## Install, drift, and source ownership

This repository owns the canonical runtime. Installed copies contain a bundle version and source
digest. `doctor.sh` compares the installed runtime, profile version, and release digest with the
bundle:

- normal mode warns on local drift or profile version 1;
- strict mode fails on drift, profile version 1, stale archives, or missing Python 3;
- install refuses to overwrite drift unless the operator passes the existing reviewed `--force`
  option.

The LMM emergency patch must move upstream through this design. After release, LMM should install
the bundle version and remove its private review-runner fork or reduce it to a repository profile
adapter.

## Security and trust

The sourced shell profile remains trusted repository code. The shell adapter normalizes its
values into environment variables; the Python module validates all values before use.

Reviewer arguments use an array and never a shell string. File paths stay below the repository
root or the private run directory. Sensitive-path checks happen before prompt construction.
Reviewer output remains untrusted data. The harness escapes it when rendering Markdown and never
executes content from a result or prior report.

No adapter fallback is automatic. Adding a provider requires a new adapter with an enforceable
run-wide budget contract and the same process cleanup tests.

## Rejected designs

### Patch the current Bash loop

Adding `timeout -k` and an elapsed-time check reduces the immediate risk. It leaves prompt,
retry, process, parser, evidence, and cache behavior in one 395-line script. Tests still have to
infer internal state through shell side effects. This seam has low depth and poor locality.

### Run the reviewer in a local daemon

A daemon could own child processes and queue work before push. It would add service lifecycle,
socket security, stale-job cleanup, and platform support. The current workload needs one bounded
process, so a daemon adds more failure modes than it removes.

### Keep paid review inside every push

This keeps one command for the operator, but it holds the remote connection open and makes a
network retry look like a reason to buy another review. Explicit preflight plus exact cache
verification separates those concerns.

### Cache by base and tree only

The source may stay unchanged while policy, prompt, or reviewer changes. Reusing that decision
would claim review coverage that did not occur.

## Acceptance rules

The architecture is satisfied only when tests prove:

- wall time stays below the total timeout plus the kill grace plus a five-second cleanup and
  verification allowance, with two seconds of test slack;
- a reviewer and nested same-group child that ignore `SIGTERM` do not survive the command;
- timeout causes one attempt even when the maximum is two;
- an output flood ends the run without a second attempt;
- the sum of attempt spend arguments does not exceed the run cap;
- a paid launch is refused when the rolling ledger is at its limit;
- every paid launch passes the profile's named model to the reviewer;
- personal quota is never used without an explicit one-run opt-in;
- every terminal path writes `run.json` and `report.md`;
- invalid result data cannot enter the decision cache;
- cache lookup fails after a policy, prompt version, or reviewer identity change;
- a preflight review lets a later push finish without a reviewer call;
- an acknowledgement accepts only its exact report, base, tree, risk class, and policy hash;
- version 1 profile and installed-runtime drift appear in doctor output;
- package archives contain the tested runtime and match source.
