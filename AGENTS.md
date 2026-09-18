# Agent rules

- Do not run, launch, restart, or terminate the app unless the user explicitly requests that exact action. The user owns the active Xcode run session.
- Builds are allowed when the user explicitly requests them or when they are solely needed to diagnose and fix compilation errors. Do not invoke `swift build`, project run scripts, or other launch automation unless the user explicitly requests it; use an isolated DerivedData directory for diagnostic `xcodebuild` runs.
- Do not modify Xcode scheme settings on your own (including reverting or regenerating `*.xcscheme`).
- Treat `Paste.xcodeproj` as the source of truth. Do not generate or regenerate the Xcode project; edit only the required project file entries when the user requests a source change.

## RePaste identity

- This fork is developed as RePaste, an independent app: `com.aaron.RePaste`, `RePaste.app`, and `repaste-cli`.
- Preserve upstream attribution and the existing AGPL-3.0 license. `origin` is Aaron's fork; `upstream` is imeelinew/Paste.
- Keep RePaste preferences, history, controller socket, permissions, and update channel separate from the original Paste. Never restore the upstream update feed or signing key into RePaste.
- Keep source folder and project names stable unless explicitly asked to rename them. The existing Paste scheme produces RePaste.
- Keep general feature/fix commits separate from fork branding, signing, release, and migration changes so they can be proposed upstream independently.
