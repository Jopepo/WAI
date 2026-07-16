# Project workflow

- After making a coherent change, run the relevant tests or build checks.
- Commit the change and push it to the branch currently being worked on, so the project agent owns the publication step.
- WAI safety rule: never push to `main`, never merge to `main`, and never alter `main`. WAI 3 work must stay on its current WAI 3 feature branch (currently `feature/wai-3-secure-foundation`) unless João explicitly changes that instruction.
- Do not switch branches or push unrelated work.
- If a push fails, report the exact reason instead of claiming success.
- Keep generated files and secrets out of commits.

## Efficiency and execution policy

- Use an economical model for routine implementation, tests, documentation,
  maintenance, and repetitive tasks.
- Reserve the strongest model for architecture decisions, security-sensitive
  review, Supabase/RLS decisions, and difficult blockers.
- Work in small, verifiable steps. Do not start a new work round without a
  concrete objective.
- Stop when the objective of the current round is complete; do not continue
  speculative work.
- End every round with a concise report covering changes, tests, risks, and the
  next concrete step.
