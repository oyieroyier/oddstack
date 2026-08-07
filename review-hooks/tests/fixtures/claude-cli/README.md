# Claude CLI envelope fixtures

Sanitized captures of the installed CLI's non-stream `-p --output-format json`
stdout, taken through the production supervisor + adapter argv path by
`tests/spikes/capture_claude_envelopes.py`.

Provenance (CLI 2.1.224, model claude-haiku-4-5-20251001, captured 2026-08-07):

| Fixture | Origin | Raw stdout sha256 |
| --- | --- | --- |
| `success.json` | real capture; ids zeroed, `result` prose replaced with the canonical sentinel review result | `99c21dbd665473fc7b139bff02b434aad25c59056bf1780e5a2804db83faf75e` |
| `budget-exhausted.json` | real capture (`--max-budget-usd 0.01`, oversized prompt); ids zeroed | `27405080b32fb99e9c3213e1dd1e36423d939356848aa4ea53dac03836d2c359` |
| `partial-result.json` | real capture (local server severed the transport after the request began; CLI retried until the gate deadline); ids zeroed | `ccc14112f07e0a94a4fb75c8ab6a479785da59a03e9b0686b312c3d8c5598a2d` |
| `rate-limited.json` | **PROVISIONAL — not a real capture.** Derived from the captured error-envelope shape plus the observed `api_error_status` field. The E1 429 leg is BLOCKED pending an already-rate-limited disposable credential (`E1_RATE_LIMITED_CREDENTIAL_HOME`). Replace with a real sanitized capture and delete this note. |

Sanitization preserved every field name, type, discriminator (`type`,
`subtype`, `is_error`, `api_error_status`, `terminal_reason`), exit-relevant
structure, and cost presence. Raw captures live outside the repository and are
never committed.

Observed exit behavior: success → exit 0; budget exhaustion → exit 1 with the
envelope on stdout and actual cost **exceeding the cap** (enforcement stops
after the in-flight call; overshoot ≈ one call); transport failure → internal
CLI retries until the gate deadline, envelope with `is_error: true`,
`subtype: "error_during_execution"`, no `result` field.
