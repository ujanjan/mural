# polish-pr

Run the polish-pr flow defined in `.cursor/skills/polish-pr/SKILL.md` (kept there so every agent reads one canonical file): iteratively fix Greptile review threads, summary-body findings, and failing `Checks` CI on this PR, pushing fixes and re-polling until the done-gate holds - zero unresolved threads, Greptile 5/5 (or every named finding addressed), and required checks green on the head SHA. Never merge.
