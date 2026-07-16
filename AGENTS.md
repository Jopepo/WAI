# Project workflow

- After making a coherent change, run the relevant tests or build checks.
- Commit the change and push it to the branch currently being worked on, so the project agent owns the publication step.
- WAI safety rule: never push to `main`, never merge to `main`, and never alter `main`. WAI 3 work must stay on its current WAI 3 feature branch (currently `feature/wai-3-secure-foundation`) unless João explicitly changes that instruction.
- Do not switch branches or push unrelated work.
- If a push fails, report the exact reason instead of claiming success.
- Keep generated files and secrets out of commits.

