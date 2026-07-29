# Design Review Rubric

Severity communicates ship risk to the product's quality bar, not personal preference — but note the bar itself is high: mediocrity is a real severity, not a pass.

## Verdict format

```markdown
## Verdict

BLOCK | POLISH | SHIP

## Paradigm check

[Is this the right presentation at all? If not, the redesign comes first and everything below is secondary.]

## Findings

### D0/D1/D2/D3: [short title]

- Evidence: screenshot region, `path:line`, or component name
- Fails because: [which principle or spec rule it violates]
- Fix: [concrete change — exact spacing/token/component/copy, or a sketched redesign if structural]

## Anticipated flows

- [next-actions the current design fails to serve, with the suggested flow]

## Copy edits

- ["current text" → "rewritten text"]
```

## Severity

### D0 — Blocks ship

- Any deviation from the project design spec, brand guide, or token system. **No exceptions for "harmless" deviations.** If the spec says 8px radii and the button has 6px, it is D0.
- Broken or missing critical states: no loading state, no empty state, error state that dead-ends the user.
- Inaccessible core flow: keyboard trap, unlabeled interactive control, contrast below WCAG AA on primary content.
- Wrong paradigm for the data or task (table where a chart is needed, modal where a page is needed) on a primary flow.
- Frontend anti-pattern from `frontend-standards.md` in the "blocking" tier.

### D1 — Fix before ship

- Visual rhythm breaks: inconsistent spacing scale, mixed radii, off-scale font sizes, misaligned optical edges.
- Journey gaps: a predictable next action with no path (see `intuition-and-flow.md`).
- Verbose or redundant copy on a primary surface.
- Native/default controls where the project's component kit has a superior primitive (native date input vs. shadcn date range picker; browser `confirm()` vs. alert dialog; `<select>` vs. combobox for long lists).
- Missing hover/focus/active affordances on interactive elements.
- Single-value input where the real-world task needs a range or multi-select (single date filter → date range filter is the canonical case).

### D2 — Fix soon

- Density miscalibration (too airy for a data tool, too cramped for a marketing surface).
- Motion missing where it would communicate (layout shifts with no transition; state changes that teleport) or gratuitous where it distracts.
- Secondary-surface copy bloat.
- Dark mode drift: colors that were designed once in light mode and inverted mechanically.

### D3 — Advisory

- Opportunities for delight: micro-interactions, illustration in empty states, personality in the 404.
- Refinements with taste-level rather than principle-level justification. Label these as taste.

## Stunning pass — what to inspect

Work top-down, then squint:

1. **Hierarchy** — one obvious primary action per screen; type scale creates reading order without reading; the most important number/word is findable in one second.
2. **Spacing rhythm** — one spacing scale, applied everywhere; related items closer than unrelated (proximity is grouping); optical alignment over box alignment.
3. **Typography** — deliberate scale (not 13/14/15/16 chaos); tabular figures for numeric columns; line length 45–75ch for prose; weight does hierarchy work before size does.
4. **Color** — semantic tokens, not hex-of-the-day; one accent doing accent work; neutrals with a consistent temperature; states (success/warn/error) reserved for states.
5. **Depth and surface** — consistent elevation logic (what floats, what sits); borders vs. shadows vs. background shifts chosen once, used consistently.
6. **States** — every component reviewed in: default, hover, focus-visible, active, disabled, loading, empty, error, overflowing content, longest realistic string, RTL if supported, dark mode.
7. **Motion** — transitions confirm causality (thing you clicked becomes the thing you see); durations 150–300ms for UI, easing out for entrances; `prefers-reduced-motion` respected.
8. **The squint test** — blur your eyes: does the layout still communicate structure? If everything is the same gray soup, hierarchy failed.

## Screenshot review protocol

When given a screenshot rather than code:

1. Identify the screen's job in one sentence. If you can't, that's the first finding.
2. Run the paradigm check before pixel critique.
3. Estimate the spacing/type scale from the image and flag internal inconsistencies (you can measure ratios even without the CSS).
4. Ask for the design spec/tokens if not provided and the project plausibly has one — do not review spec-blind when the spec exists.
5. Deliver findings with regions ("top-right stat card", "second row of the table") so they're actionable without annotation tools.
