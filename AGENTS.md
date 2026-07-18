# CodexAura repository guidance

## Product context

- CodexAura is a macOS 14+ menu-bar app written in Swift.
- It changes Codex appearance through local CDP injection without modifying the Codex app bundle.
- Preserve the existing security boundary: loopback-only CDP, signature validation, reversible injection, and no analytics.

## Required workflow

- Never develop directly on `main`. Create an `agent/<short-description>` branch.
- Keep each pull request focused on one coherent user outcome.
- Do not merge a pull request or deploy/release externally without explicit user confirmation.
- Before asking for confirmation, explain in plain Chinese: what changed, user-visible impact, risks, validation evidence, and rollback method.
- Treat a green CI result as a technical gate, not proof that the product behavior is correct.
- For UI changes, provide a screenshot or a concrete manual verification path.

## Verification

- Run unit tests with `./Scripts/test.sh`.
- Run the production build with `./Scripts/build-app.sh`.
- Verify the universal binary with `lipo build/CodexAura.app/Contents/MacOS/CodexAura -verify_arch arm64 x86_64`.
- Verify signing with `codesign --verify --deep --strict build/CodexAura.app`.
- New behavior and bug fixes must include proportionate automated tests.
- Do not weaken, skip, or delete checks merely to make CI green.

## Risk policy

- High-risk changes include signature/CDP security, destructive file operations, imported theme validation, release signing, credentials, and data migration.
- For high-risk changes, state failure modes and rollback steps before implementation, and add tests for the safety boundary.
- Never commit secrets, tokens, certificates, signing identities, `.env` files, or user data.
- Preserve unrelated user changes and avoid destructive Git operations.

## Repository conventions

- Shared, testable theme logic belongs in `Sources/CodexAuraCore`.
- App lifecycle and UI integration belong in `Sources/CodexAura`.
- Bundled presets live under `Sources/CodexAuraCore/Presets/<theme-id>` and contain `theme.json`, `background.jpg`, and `thumb.jpg`.
- Use `apply_patch` for hand-edited text files. Keep generated or mechanical asset transformations reproducible and documented.
- Keep README and `docs/` guidance synchronized when commands, theme schema, or release behavior changes.
