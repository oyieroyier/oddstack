# Intuition and Flow

The Intuitive half of the personality. The unit of review is not the screen — it is the journey. A pixel-perfect screen inside a broken journey is a broken product.

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

| Data/task shape | Wrong-but-common | Usually right |
|---|---|---|
| Trend over time | Table of dated rows | Line/area chart, table behind a toggle for auditing |
| Comparison across few entities | Cards with numbers | Bar chart or a compact stat row with deltas |
| One record's full detail from a list | Navigate to new page | Sheet/drawer over the list (context preserved) — page only when the record is a destination with its own URL-worthy identity |
| Scan + act on many records | Cards grid | Dense table with inline actions and bulk select |
| 3–7 mutually exclusive options | Dropdown | Segmented control / radio group (visible options beat hidden ones) |
| Long list selection | Native `<select>` | Combobox with typeahead |
| Date filtering for analysis | Single native date input | Range picker with presets |
| Multi-step creation, steps independent | One long form | Wizard with progress — but collapse to one screen if under ~7 fields; wizards are for genuinely sequential decisions |
| Rare-but-important status | Buried in a settings page | Inline banner/badge at the point of relevance |

The table is a starting library, not a lookup answer — justify the choice from the data's shape and the user's task, and say when you're overriding an existing paradigm and why the migration is worth it.

## Journey audit checklist

For a flow-level review, walk the journey as three users:

1. **First-timer** — do they succeed without reading anything? Where do they stall?
2. **Daily power user** — how many clicks does their most frequent loop take? Anything they'd script away? Keyboard path exists?
3. **Returning-after-a-month user** — can they re-orient from the UI alone? Does state they left behind (drafts, filters, half-done setup) greet them or ambush them?

Any stall, redundant click loop, or ambush is a finding.
