# Agent conventions

Standing rules for any agent working in this repo:

- **Every PR gets the polish loop, by default.** Opening a PR is not done until the loop passes: Greptile Confidence Score 5/5 (or every summary-body finding addressed), zero unresolved review threads, and the `Checks` workflow green on the head SHA. Loop mechanics: [.cursor/skills/polish-pr/SKILL.md](.cursor/skills/polish-pr/SKILL.md). Run it without being asked.
- **Never merge.** The user reviews and merges every PR himself.
- **The Xcode project file is generated.** After adding or removing files under `App/`, regenerate `Mural.xcodeproj/project.pbxproj` with `scripts/generate_project.py` and commit the result.
- **Provider keys stay out of the repo and out of chat.** Keys are entered by the user in-app (Settings) and live in the Keychain; never commit, log, or paste them.
