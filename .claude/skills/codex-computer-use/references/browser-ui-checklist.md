# Browser and UI Checklist

Use this when reviewing or delegating visual/browser work.

## Functional states

Check:

- Initial load.
- Loading state.
- Empty state.
- Success state.
- Error state.
- Retry/reconnect behavior.
- Slow network or delayed API response.
- Duplicate submit/click.
- Back/forward navigation.
- Refresh persistence.

## Input states

Check:

- Empty input.
- Very long input.
- Special characters.
- Invalid values.
- Boundary values.
- Copy/paste.
- Keyboard-only completion.
- Form reset/cancel.

## Layout states

Check:

- Mobile width.
- Tablet width.
- Desktop width.
- Long text and localization expansion.
- Overflow and scroll behavior.
- Modals/popovers near viewport edges.
- Dark/light mode if supported.
- High zoom / large text.

## Accessibility states

Check:

- Focus visible and logical.
- Labels for controls.
- Button/link semantics.
- Dialog focus trapping and escape behavior.
- Error messages associated with inputs.
- Color is not the only signal.
- Screen-reader names where relevant.

## Evidence to request

Ask for:

- Route and viewport.
- Screenshot path.
- Console errors.
- Network errors.
- Exact reproduction steps.
- Expected and actual behavior.
- Files changed and why.
