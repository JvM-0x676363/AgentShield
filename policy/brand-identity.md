# Brand identity template

This optional file is distributed beside agent instructions but is read only
when a task needs visual design, documentation, diagrams, or presentation work.
It is a template: each organization should replace the placeholders below with
its approved design system before deployment.

## Default behavior

If no organization-specific design system is configured:

- Do not invent a company name, logo, palette, or marketing claims.
- Ask the user for brand guidance before making identity decisions.
- Use the existing project's design tokens when they exist.
- Use accessible neutral defaults only when the user authorizes a new visual
  direction.

## Organization profile

Replace this section before rollout when a brand system exists.

| Field | Value |
|---|---|
| Organization name | `<organization-name>` |
| Primary light surface | `<hex-color>` |
| Primary dark text | `<hex-color>` |
| Brand accent | `<hex-color>` |
| Secondary surface | `<hex-color>` |
| Typography | `<approved-fonts-or-system-stack>` |
| Design-system reference | `<approved-internal-or-public-reference>` |

## Accessibility requirements

- Text and meaningful icons must meet WCAG 2.2 AA contrast: at least `4.5:1`
  for normal text and `3:1` for large text.
- Do not use color as the only carrier of information; pair it with labels,
  shape, or pattern.
- Define success, warning, and error colors as semantic tokens. Do not infer
  them from a brand palette.
- Keep contrast, keyboard navigation, focus state, and reduced-motion behavior
  testable in the consuming project.

## Implementation guidance

Define approved values as project tokens rather than scattering literal colors:

```css
:root {
  --surface: <approved-light-surface>;
  --text: <approved-dark-text>;
  --accent: <approved-accent>;
  --surface-secondary: <approved-secondary-surface>;
}
```

This template is not an instruction to install third-party skills or design
tools. Organizations may add reviewed local skills separately after verifying
provenance, licensing, and their effect on agent behavior.
