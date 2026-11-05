# specs/ — one spec per task, the only input for unattended runs

Written by `/wingman` (an expert-colleague spec session), one file per branch:
`specs/<branch-name>.md`. The spec is the **sole input** for the implementation session —
a fresh session or worktree implements from the spec, not from the conversation that
produced it.

Fixed skeleton (all sections required):

- **Objetivo** — one paragraph.
- **Fuera de alcance** — explicit list (the most-forgotten field).
- **Decisiones y porqués** — every call made during convergence, with its reason.
- **Superficies y archivos** — named files/components/interfaces per surface.
- **Edge cases** — incl. empty/error states.
- **Plan de verificación** — per surface: check type (functional / visual / judgment /
  user-decides) and the executable gate. No surface without a gate.
- **Frenos** — for the unattended run: one surface per pass, stop-and-report conditions,
  what must never be touched.

Measure of a good spec: **interventions during the run ≈ 0**. If you had to step in,
the readiness gate missed something — feed it back to `/wingman`'s checklist.
