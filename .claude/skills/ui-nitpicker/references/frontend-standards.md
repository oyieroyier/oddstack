# Frontend Engineering Standards

The principal-engineer half of the personality. Beautiful pixels on rotten architecture fail review. These standards assume the 2026 ecosystem; when a project is on an older stack, apply the same principles through the best mechanisms that stack offers, and flag the upgrade path once (not on every finding).

## Blocking anti-patterns (D0 tier)

### Monolithic files

A single file holding a page's layout, data fetching, five handlers, three inline sub-components, and a modal defeats modularity, reuse, testing, and code-splitting.

- Components have one job. A file approaching ~200–300 lines of JSX/logic almost always contains 2+ components wanting out.
- Extract by responsibility, not by size: data access (hook or server loader), pure presentation, feature composition.
- Inline sub-components defined inside a render body are a bug, not a style choice — they remount on every render.
- Repeated JSX blocks with one varying prop are a `.map` over data or an extracted component, never copy-paste.

### `useEffect` spam

`useEffect` is for synchronizing with **external systems** (DOM APIs, subscriptions, analytics, non-React widgets). Nearly every other use is a bug factory. Block on:

- **Derived state in effects**: `useEffect(() => setFullName(first + last))` → compute during render, or `useMemo` if expensive. No state, no effect.
- **Data fetching in effects**: raw `fetch` + `useState` + `useEffect` + hand-rolled loading flags → server components / route loaders for initial data, TanStack Query (or SWR) for client cache with revalidation, mutations via Server Actions or `useMutation`. Hand-rolled fetch effects lose you dedup, races, retries, cache, and cancellation in one move.
- **Event logic in effects**: reacting to a state flag set by a handler (`useEffect(() => { if (submitted) ... })`) → put the logic in the handler.
- **State-to-state chains**: effect sets state, which triggers another effect, which sets more state → model the state properly (usually a reducer or derived values); chains are unreadable and render-storm.
- **Prop-mirroring**: `useState(props.value)` + effect to re-sync → use the prop directly, or fully control the component. Mirrored state is two sources of truth, one of them stale.

### `useState` spam

Six `useState` calls that change together are one state object nobody modeled. Block on:

- Booleans multiplying (`isLoading`, `isError`, `isSuccess`, `isIdle`) → one discriminated status union, or better, the state machine your data library already gives you.
- Form fields as individual `useState` → React Hook Form (or the framework's form primitive) + Zod schema. Uncontrolled by default, validation typed, re-renders scoped.
- Server data in `useState` → it belongs in the query cache / loader, where staleness and revalidation are handled.
- State that can be computed from other state or props → compute it. **The best state is state that doesn't exist.**
- UI state that should survive refresh and be shareable (filters, tabs, pagination, open sheet + selected id) → **URL state**, via nuqs or the router's search params. If a colleague can't paste a link to reproduce the view, the state is in the wrong place.

### Other blockers

- Prop drilling 4+ levels for cross-cutting data → composition first (pass components, not data), then context for genuinely global read-mostly values, then a store (Zustand/Jotai) for shared client state with frequent writes.
- Client-rendering entire pages whose content is server-derivable → server components / streaming SSR; ship interaction, not JSON-piping-into-DOM.
- Unkeyed or index-keyed dynamic lists that reorder.
- Accessibility violations in interactive primitives: divs-as-buttons, no focus management in overlays, icon buttons with no accessible name. Use Radix/shadcn primitives — a11y is why they exist.
- Hardcoded values the design system tokenizes: hex colors, px spacing, font sizes inline where tokens exist. This doubles as a design-spec violation.

## State placement decision ladder

Where does a piece of state live? First rung that fits, stop there:

1. **Nowhere** — derivable from existing state/props? Derive it.
2. **The URL** — filters, tabs, selection, pagination, modals-with-identity. (nuqs / router search params.)
3. **Local `useState`/`useReducer`** — genuinely local, ephemeral UI state (open/closed, hover, draft input).
4. **The form library** — anything a form touches.
5. **The server cache** — anything fetched. TanStack Query / RSC / loaders own it; components subscribe.
6. **A small store (Zustand/Jotai)** — client state shared across distant components with frequent writes.
7. **Context** — read-mostly DI (theme, locale, current user), not a state manager; every consumer re-renders on change.

`useEffect` appears nowhere on this ladder. That is the point.

## 2026 baseline the nitpicker expects

- **React 19+ semantics**: Actions and `useActionState` for mutations, `useOptimistic` for latency-hiding, `use()` for promises/context, refs as props (no `forwardRef` ceremony), `<form action>` over onSubmit-preventDefault chains.
- **React Compiler** (or equivalent) for memoization — hand-scattered `useMemo`/`useCallback`/`memo` everywhere is noise; hand-tuned memoization only where a profiler pointed.
- **Server-first data**: RSC / route loaders for reads, server actions or typed mutations for writes, client cache (TanStack Query v5) only where interactivity demands it.
- **Styling**: design tokens as the single source (Tailwind v4 theme / CSS variables); modern CSS natively — container queries, `:has()`, subgrid, View Transitions for route/element morphs; no JS for what CSS does.
- **Components**: shadcn/ui + Radix (or the project's equivalent) as the primitive layer; `cva`/variants over ad-hoc conditional class strings.
- **Motion**: Motion (Framer) or View Transitions API; CSS transitions for micro-interactions; everything honors `prefers-reduced-motion`.
- **Forms**: React Hook Form + Zod (schema shared with the server action — one validation source of truth).
- **Tables/lists**: TanStack Table for real data grids; virtualization (TanStack Virtual) past ~100 rendered rows.
- **TypeScript strict**, no `any` escapes in component contracts; discriminated unions for UI state.

## Performance nitpicks

- Layout shift is a design failure: reserve space (skeletons sized like content, image dimensions, `font-display` strategy).
- Interactions must respond < 100ms — optimistic updates on mutations the user can see; never spinner-block the whole screen for one widget's request (that's what Suspense boundaries scope).
- Code-split at route and heavy-widget level (charts, editors); a dashboard shouldn't ship the settings page's editor.
- Images: proper sizing, modern formats, lazy below the fold — via the framework's image primitive, not hand-rolled.
- Waterfalls are architecture bugs: parallelize independent fetches at the loader/RSC layer; a page that fetches serially in three nested components needed its data hoisted.

## Review protocol for code

1. Map the component tree and state ownership first; most rot is misplaced state, and pixel diffs won't reveal it.
2. Grep for smells: `useEffect(` count per file, `useState(` clusters, `fetch(` inside components, inline hex colors, `px` literals, `any`.
3. Check each `useEffect` against the "external systems only" bar — demand each one justify its existence.
4. Walk the state ladder for each significant piece of state and flag any that sit on the wrong rung.
5. Findings name the pattern, the cost, and the target shape with a code sketch — never just "refactor this".
