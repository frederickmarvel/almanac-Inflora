---
name: mockerize
description: >
  Turn approved mockups into production-ready UI with high visual fidelity,
  responsive behavior across device sizes, and real frontend-to-backend integration.
  Use when implementing or reconciling a UI from Figma, Pencil, screenshots, images,
  design specs, or an existing visual prototype; when asked to make the implementation
  match a mockup closely without rigid pixel positioning; or when mockup fields and
  interactions require mapping, API, service, schema, validation, or database
  adjustments. Covers visual audits, responsive inference, component and data mapping,
  minimal backward-compatible backend changes, integration states, visual comparison,
  and regression verification.
---

# Mockerize

Turn a mockup into working product behavior, not a screenshot-shaped frontend.

The governing rule is:

> Be pixel-faithful at the reference viewport and constraint-faithful at every other viewport.

## Operating contract

Apply this source-of-truth order:

1. Follow the user's explicit scope, corrections, and protected flows literally.
2. Preserve business rules, authorization, data integrity, and established contracts.
3. Use the mockup as the source of truth for visual hierarchy, information order, interaction intent, and design character.
4. Reuse the product's design system, components, and engineering conventions when they can reproduce the mockup faithfully.
5. Infer only what the supplied mockup does not define.

Do not turn implementation into a speculative redesign. Make the smallest justified deviation needed for responsiveness, accessibility, real data, or an existing business invariant.

Match the requested mode:

- For an audit, review, or impact assessment, inspect and report without changing files.
- For an implementation or fix request, make the changes, connect the real data flow, verify them, and continue through safe in-scope adjustments. Do not stop at a plan.

## Workflow

### 1. Establish the evidence

Before editing:

- Read repository instructions and identify the frontend, backend, shared contract, and test locations.
- Inspect the current route or screen, related screens, reusable components, design tokens, breakpoints, and state-management conventions.
- Inspect the mockup with the tool appropriate to its format. Record its reference viewport when available.
- Trace the relevant API handlers, request and response types, validation, services, persistence models, migrations, permissions, and consumers.
- Check the working tree and preserve unrelated user changes.
- Identify existing product flows that the new UI must not regress.

If the reference viewport is unknown, infer it from the artifact dimensions and state that assumption in the final handoff. Ask only when the ambiguity would materially change business behavior, permissions, destructive migration choices, or the target surface.

### 2. Build the implementation map

Create a compact working map before changing code:

| Mockup element | UI component | Responsive rule | Frontend field/state | API contract | Backend source | Action |
|---|---|---|---|---|---|---|
| What the user sees | Existing or new component | Fixed, fluid, wrap, collapse, scroll, reorder, or conditional | Real field and state owner | Request/response field | Service/model/table | Reuse, add, transform, or remove |

Also map every user action:

```text
user action
  -> UI event
  -> client validation
  -> request
  -> authorization
  -> service/domain operation
  -> persistence or external effect
  -> response
  -> UI feedback
```

Keep this map as working context unless the user asks for an artifact. Use it to expose gaps instead of filling them with frontend-only workarounds.

Classify mismatches at the correct layer:

- **Visual:** tokens, typography, spacing, color, radius, shadow, iconography.
- **Layout:** container, grid, alignment, sizing, wrapping, ordering, overflow.
- **Content/data:** wrong field, missing field, formatting, null handling, stale mapping.
- **Interaction:** incorrect state transition, feedback, navigation, validation, or permissions.
- **Contract/domain:** API, service, model, persistence, or business-rule mismatch.

Fix each mismatch at its owning layer. Do not hide a backend or contract gap with hardcoded presentation data.

### 3. Infer responsive behavior

Treat the mockup as one observation of a layout system, not a list of absolute coordinates.

For each region, decide whether it is:

- fixed-size;
- fluid within min/max constraints;
- intrinsically sized by content;
- wrappable;
- collapsible;
- scrollable;
- reorderable;
- conditionally visible.

Choose breakpoints where the content or layout actually stops working. Prefer existing project breakpoints when suitable; add a breakpoint only when the composition requires it.

When space decreases, apply this order:

1. Preserve primary content and primary actions.
2. Wrap or reposition secondary controls.
3. Collapse multi-column regions into fewer columns.
4. Reorder content without changing meaning or task sequence.
5. Use horizontal scrolling only for content that benefits from it, such as tables, tabs, timelines, or carousels.
6. Hide content only when it is genuinely optional and still accessible elsewhere.

Do not merely scale down the desktop layout. Protect text legibility, content hierarchy, touch targets, focus order, safe-area behavior, long localized text, and keyboard access.

Unless the project specifies its own target matrix, verify representative sizes around:

- 360×800;
- 390×844;
- 768×1024;
- 1024×768;
- 1440×900.

These are test points, not mandatory CSS breakpoints.

### 4. Implement the UI faithfully

At the reference viewport:

- Match the composition, information density, alignment, dimensions, spacing rhythm, typography hierarchy, colors, borders, radii, shadows, and icons as closely as the available assets allow.
- Preserve the mockup's content order and interaction flow.
- Use semantic, reusable components and existing design tokens where they reproduce the target.
- Centralize intentional transformations instead of scattering one-off CSS and field fallbacks.
- Avoid absolute positioning for structural layout. Reserve it for overlays or explicitly layered artwork.
- Avoid arbitrary magic numbers that only make one screenshot pass.

Prefer the smallest component boundary that is reusable and readable. Do not generalize a one-off region into a premature framework, and do not duplicate an existing component to bypass a small variant.

### 5. Connect real states and data

Implement all states that the flow can actually enter:

- initial and partial loading;
- empty;
- success;
- field and form validation errors;
- API or network error;
- unauthorized or permission-limited;
- disabled and submitting;
- stale or refetching;
- long, missing, null, and extreme values;
- slow requests and duplicate submission.

Use optimistic updates only when the operation is safely reversible and the codebase already has a reliable rollback pattern.

Never leave mock or hardcoded production data in place to simulate a successful integration. Temporary fixtures are acceptable only inside tests, stories, previews, or explicitly requested prototypes.

### 6. Adjust the backend when the UI requires it

Make backend changes only when supported by the mapped product need. Prefer the smallest complete change:

1. Reuse or compose existing data before adding a new field.
2. Add or update request/response contracts deliberately.
3. Apply normalization and formatting at a clear boundary.
4. Update validation, authorization, service logic, persistence, and migrations only where required.
5. Preserve backward compatibility for existing consumers whenever practical.
6. If a breaking change is unavoidable, provide a safe transition path rather than silently replacing the contract.
7. Keep sensitive and provider-internal fields out of public responses.
8. Update generated clients, schemas, fixtures, and contract tests when the project requires them.

For database changes:

- inspect existing naming, nullability, default, index, and migration conventions;
- make migrations safe for existing rows and realistic data volume;
- avoid destructive data changes without explicit authorization;
- verify both forward behavior and compatibility with old data.

When the visual design conflicts with a domain invariant, preserve the invariant and adapt the presentation with the smallest visible deviation. Report that deviation.

### 7. Run the visual adjustment loop

After the first implementation:

1. Render the real screen at the reference viewport with representative real data.
2. Compare it with the mockup using screenshots, side-by-side inspection, overlay, or image diff when available.
3. Rank mismatches by visual impact:
   - page geometry and hierarchy;
   - container and major component dimensions;
   - spacing and alignment;
   - typography;
   - color, borders, radius, shadow, and icons;
   - minor decorative details.
4. Fix the highest-impact mismatch at its owning layer.
5. Re-render and repeat until no substantial unexplained mismatch remains.
6. Recheck responsive sizes after reference-viewport corrections.

Do not declare visual completion from code inspection alone when the screen can be rendered.

### 8. Verify the integrated behavior

Run the repository's relevant quality gates:

- focused frontend tests;
- backend, service, or contract tests;
- type-check;
- lint;
- production build;
- migration validation when applicable.

Exercise the user flow end to end with real request and response handling. Check error paths and permission boundaries, not only the happy path.

Inspect adjacent screens and existing flows for regressions. Do not fix unrelated failures unless they prevent verification; distinguish pre-existing failures from changes introduced by this task.

## Decision rules

- Preserve an established flow unless the user explicitly asks to change it.
- Prefer existing visual assets over approximate substitutes.
- Prefer real contract changes over UI fakery when the product truly needs new data.
- Prefer UI adaptation over backend churn when existing data already expresses the required meaning.
- Prefer content-driven constraints over device-name assumptions.
- Record reasonable assumptions and continue; stop only for a material product, security, data-loss, or authorization decision.
- Keep implementation notes out of user-facing product surfaces.

## Definition of done

Do not call the task complete until:

- the reference viewport is visually faithful;
- smaller and larger viewports remain usable without accidental overflow or broken hierarchy;
- mockup fields and actions are mapped to real frontend and backend behavior;
- loading, empty, error, validation, permission, and submission states work;
- required API, service, schema, and migration adjustments are complete and compatible;
- relevant tests, type-check, lint, and build pass, or remaining failures are clearly identified as pre-existing or blocked;
- protected existing flows have been regression-checked;
- deliberate deviations from the mockup are explained.

## Final handoff

Lead with the implemented result. Summarize:

- UI and component changes;
- responsive rules and notable device-specific adjustments;
- frontend-to-backend mapping;
- API, service, schema, or database changes;
- deliberate mockup deviations and why;
- verification performed and its result;
- anything that could not be verified.

Keep the handoff concise and evidence-based. Do not dump internal working notes or the entire mapping table unless the user requests it.
