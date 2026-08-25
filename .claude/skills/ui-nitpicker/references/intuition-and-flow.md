# Intuition and Flow

The Intuitive half of the personality. The unit of review is not the screen — it is the journey. A pixel-perfect screen inside a broken journey is a broken product.

## Audience and actionability

The first question on any screen is not "is this beautiful?" but "who is this for, and can they act on what it shows?" First-pass builds — by AI agents especially — are written with the developer as the only user in the room, so the UI doubles as a debugging surface: the payments page shows the webhook URL, the callback endpoint, the payment-initiation payload, the provider's transaction reference, the raw status enum. Every one of those is useful to the person who wired the integration, and noise — or worse — to the person paying.

Without this check the nitpicker's instinct is to _restyle_ that content: a well-set monospace card for the callback URL. That is polishing a defect. Decide what belongs before deciding how it looks.

### Method

1. **Name the viewer persona from evidence, not from the role string.** Read the copy's addressee ("your order", "your customers"), the surrounding actions, the product's tenancy, and where the screen sits in the journey. Typical personas: end customer, merchant/operator, ops or support staff, developer/integrator, platform operator. A role label is not a persona. In a single-tenant product the `superadmin` is the client who bought the software, not an engineer; in a multi-tenant platform the account owner is the customer and only the platform operator's own staff are elevated. The test: _does anyone with this role, in this product, open a terminal or the integration docs because of what they saw here?_ If not, they are not elevated for this data, whatever the role is called.
2. **For every value rendered, name the action it enables for that persona.** "Reference the customer quotes to support" is an action. "Might be useful" is not. A value with no action for this persona on this surface is not information.
3. **Assign a disposition**, in this order of preference:
   - **DROP** — no persona in the product acts on it from a UI, or it exists only because the developer needed to see it while building: correlation ids, raw payloads, callback URLs, `NODE_ENV` badges, internal enum strings, ISO timestamps with milliseconds. Delete it; logs and the developer console are where it belongs. This is the default for anything you cannot attach an action to — when in doubt, drop.
   - **RELOCATE** — an actor exists, but not here. Move it to the surface where that actor works: integration/developer settings, the API keys page, an ops console, support tooling, an audit log. The move is the finding; leaving it here behind a role check is not a fix (below).
   - **TRANSLATE** — the underlying fact matters to this persona but the representation is developer-shaped. `PENDING_3DS` → "Waiting for your bank to confirm". `pi_3Nx9…` → gone, unless support genuinely asks customers for it, in which case it is labelled "Reference" and lives in the receipt where support flows send people.
   - **KEEP** — this persona acts on it, here, now. Say what the action is.
4. **Escalate secrets regardless of persona.** Tokens, API keys, webhook/callback/IPN URLs, request payloads, stack traces, internal hostnames are D0 wherever they render — an admin page included — unless that page _is_ the integration console and the viewer is the integrator. Exposure is a security defect first and a design defect second.

### Why role-gating on the same page is the wrong fix

Rendering the developer block when `role === 'admin'` keeps the page as a debugging surface with a lock on it. It fails three ways: the role is frequently the client, so the block still shows to the wrong person; the page now serves two audiences and its hierarchy serves neither; and the block is one misconfigured check away from leaking. Prefer one surface per persona. Reserve in-page gating for the narrow case where the same persona legitimately switches modes — a developer toggling "show technical details" on their own integration page.

### Tells of a debugging surface

Any of these on a non-developer surface triggers the method above:

- URLs the user never types: webhook, callback, redirect, IPN, return URLs.
- Code, config, or payload snippets; JSON; cURL; "copy this into…" instructions outside an integration page.
- Identifiers with no human meaning: UUIDs, provider references (`pi_`, `ch_`, `txn_`), database ids, correlation/request ids.
- Enum-cased or snake_cased strings surfaced as status text; boolean columns rendered as `true`/`false`.
- Environment leakage: "sandbox", "test mode", "staging" badges; provider names on a white-labelled product; version strings and build hashes.
- ISO 8601 timestamps with milliseconds or a `Z` suffix on a customer-facing screen.
- Tables that mirror a database row or API response one-to-one, column names included.
- Error text that is a raw exception message, HTTP status, or stack frame.

### Worked example

E-commerce merchant dashboard, payments page. Shows: gateway name, webhook URL with a copy button, callback URL, a "payment initiation code" snippet, and the last 20 transactions with `txn_` references and `status: SUCCEEDED`.

- Persona: the merchant — the `superadmin` of their own store. They never wire integrations; the platform did.
- Webhook URL, callback URL, initiation snippet → **DROP** from this page. If merchants can bring their own gateway, **RELOCATE** to Settings → Integrations, where the integrator persona works, copy button intact there.
- `txn_` reference → **TRANSLATE**: hidden by default, exposed as "Reference" inside the transaction detail sheet because merchants quote it to the gateway's support.
- `SUCCEEDED` → **TRANSLATE** to "Paid", using the semantic success token.
- Gateway name → **KEEP** only if the merchant chose it and can change it here; otherwise DROP.

What remains is the merchant's actual job: money in, money pending, money failed, and what to do about the failed ones. That is the page to design.

## Next-action anticipation

For every screen or feature, ask: **what does the user do immediately after this succeeds?** Then check whether the design serves it. You have seen these journeys hundreds of times; use that.

Method:

1. Name the user's actual goal (never "create a product" — the goal is "sell things").
2. List the 2–3 most probable next actions after the current step succeeds.
3. For each, check: is there a path? Is it one step away? Does the system check preconditions on the user's behalf?
4. A missing path or an unguarded precondition is a D1 finding with a proposed flow.

Canonical examples of the reasoning:

- **E-commerce, product created** → next need is selling it. Check: is fulfillment/shipping configured? Is a payment method connected? If not, the success state should say so and route there: "Product live. Set up fulfillment so orders can ship →". Don't strand the user on a success toast.
- **Invoice sent** → the user will come back asking "did they pay?". Surface status inline, offer a reminder action at the moment it becomes relevant.
- **Filter added** → real analysis is almost always comparative or ranged. A single date filter is a smell: propose a range picker (shadcn date range picker, not a native input) with presets (Today, 7d, 30d, Custom).
- **Item deleted** → mistakes happen at scale. Undo beats confirm; confirm dialogs are a tax on the 99% to protect the 1%.
- **Form completed** → never dead-end on a success message. Offer the next verb: view it, share it, create another.
- **Search returned nothing** → zero results is a fork, not a wall: loosen filters for them, suggest near-matches, or offer to create the thing they searched for.

## Show, don't tell

Journeys must demonstrate. Every explanatory paragraph is a design failure being papered over with words.

- **Empty states are the feature's demo.** Show a ghosted example of the filled state, or pre-populate sample data, with the single primary action to make it real. Never a paragraph describing what the feature will do.
- **Onboarding is doing.** The first-run experience should have the user complete one real, valuable action — not a carousel of screenshots of the actions they could take later.
- **Preview over description.** Settings that change appearance show the change live. Destructive actions show what will be affected ("Delete 3 products and 14 variants"), not a generic "Are you sure?".
- **Progressive disclosure over instruction.** If users need to be told about a feature, consider surfacing it contextually at the moment of need instead of documenting it.
- **Tooltips are a confession.** A tooltip that explains what a control does means the control's label or icon failed. Fix the control.

## Copy economy

Ruthless with words. Findings should include the rewrite.

- Verbs over descriptions: "Save changes", not "Click here to save your changes".
- Kill throat-clearing: "Please note that", "In order to", "You can use this to".
- Kill apology and hedging: "Oops! Something seems to have gone wrong" → "Couldn't save. Retry?" with the reason if known.
- Headings never restate the nav item the user just clicked.
- Error messages: what happened + what to do, one line each, no error codes as the headline.
- Buttons say what happens: "Send invoice", not "Submit". "Delete 3 items", not "Confirm".
- If a sentence can lose a word without losing meaning, it must.

## Paradigm selection

Choosing the presentation is the highest-leverage design decision, and you make it fresh every time rather than accepting what's there. Radical restructuring is expected when the current paradigm is wrong.

| Data/task shape                        | Wrong-but-common          | Usually right                                                                                                                |
| -------------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Trend over time                        | Table of dated rows       | Line/area chart, table behind a toggle for auditing                                                                          |
| Comparison across few entities         | Cards with numbers        | Bar chart or a compact stat row with deltas                                                                                  |
| One record's full detail from a list   | Navigate to new page      | Sheet/drawer over the list (context preserved) — page only when the record is a destination with its own URL-worthy identity |
| Scan + act on many records             | Cards grid                | Dense table with inline actions and bulk select                                                                              |
| 3–7 mutually exclusive options         | Dropdown                  | Segmented control / radio group (visible options beat hidden ones)                                                           |
| Long list selection                    | Native `<select>`         | Combobox with typeahead                                                                                                      |
| Date filtering for analysis            | Single native date input  | Range picker with presets                                                                                                    |
| Multi-step creation, steps independent | One long form             | Wizard with progress — but collapse to one screen if under ~7 fields; wizards are for genuinely sequential decisions         |
| Rare-but-important status              | Buried in a settings page | Inline banner/badge at the point of relevance                                                                                |

The table is a starting library, not a lookup answer — justify the choice from the data's shape and the user's task, and say when you're overriding an existing paradigm and why the migration is worth it.

## Journey audit checklist

For a flow-level review, walk the journey as three users:

1. **First-timer** — do they succeed without reading anything? Where do they stall?
2. **Daily power user** — how many clicks does their most frequent loop take? Anything they'd script away? Keyboard path exists?
3. **Returning-after-a-month user** — can they re-orient from the UI alone? Does state they left behind (drafts, filters, half-done setup) greet them or ambush them?

Any stall, redundant click loop, or ambush is a finding.
