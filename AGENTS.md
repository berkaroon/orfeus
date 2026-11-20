# AGENTS.md

Instructions for AI coding agents (Codex and others) working in this repository.
Read this file fully before making changes.

## 1. Project overview

**Orfeus** is a native macOS per-application volume mixer. The menu-bar popover shows open apps with active audio output, recognized media capabilities, prior volume settings, or output previously observed in the current Orfeus session. The user can adjust each listed app independently.

- Language: **Swift 6** (strict concurrency on)
- UI: **SwiftUI** first; **AppKit** only where SwiftUI has no equivalent
- Audio: **Core Audio process taps** (`CATapDescription`, `AudioHardwareCreateProcessTap`)
- Minimum deployment target: **macOS 14.2** (first release with process taps). Adjust if product decides otherwise.
- Design target: latest macOS (Liquid Glass era) with graceful fallback on older systems
- Distribution: Developer ID + notarization (optionally Mac App Store later)

### Non-goals (do NOT build these without explicit approval)
- Kernel extensions, DriverKit extensions, or HAL plug-in virtual drivers
- Network features of any kind (analytics, crash reporting, update checks, telemetry)
- Recording, saving, or transcribing audio
- Web views, Electron, Catalyst, cross-platform UI toolkits

## 2. Repository layout (target structure)

```
Orfeus/
├── App/                      # @main App, MenuBarExtra, scenes, Info.plist, entitlements
├── Assets/                   # App icon artwork (orfeus-icon-1024.png, orfeus-dock-1024.png)
├── Design/                   # Icon and template menu-bar asset generator (MakeIcon.swift)
├── Packages/
│   ├── AudioCore/            # Core Audio wrapper, taps, gain, device handling (no UI imports)
│   ├── MixerModel/           # @Observable state, persistence, business logic
│   └── MixerUI/              # SwiftUI views and components
├── Tests/                    # Unit tests per package
├── scripts/                  # Build, test, signing, and DMG packaging script
├── AGENTS.md
└── SECURITY.md
```

Keep `AudioCore` free of SwiftUI/AppKit so it is testable and reviewable in isolation.

## 3. Build, test, lint

```bash
# Build + test the app
xcodebuild -project Orfeus.xcodeproj -scheme Orfeus -destination 'platform=macOS' clean build test

# Build + test a package on its own
swift build --package-path Packages/AudioCore
swift test  --package-path Packages/AudioCore

# Lint / format (only if configured in the repo)
swiftlint --strict
swift-format lint --recursive .
```

If a command above does not exist yet, create the minimal setup for it instead of skipping it.

## 4. Coding conventions

- Follow the **Swift API Design Guidelines**. Prefer clarity over brevity.
- Use `@Observable` (Observation framework), `async/await`, and actors. No Combine unless required.
- UI types and view models are `@MainActor`. Audio device work happens off the main actor.
- No force unwraps (`!`), no `try!`, no `fatalError` in production paths. Handle or propagate errors.
- No `print`. Use `os.Logger` with subsystem = bundle ID and a per-module category.
- Prefer value types. Keep types small and single-purpose. No god objects.
- Public APIs inside packages get doc comments (`///`).
- Strings are localized via a **String Catalog** (`.xcstrings`). No hard-coded user-facing text.

### Real-time audio rules (IOProc / render callbacks)
Code that runs on the audio thread MUST NOT:
- allocate or free memory, create objects, or use Swift collections that may grow
- take locks, wait, or call into the Swift concurrency runtime
- use Objective-C messaging, `Logger`, file or network I/O
- touch any UI or `@MainActor` state

Communicate with the audio thread through preallocated buffers and atomics (e.g. a lock-free
single-writer gain value). Violations cause glitches and are treated as bugs.

### Gain safety
- Per-app gain is clamped to a defined range (default `0.0 ... 1.0`; if boost is ever added it must
  have a hard ceiling and a limiter).
- Gain changes are **ramped per buffer** (no instant jumps) to avoid clicks.
- Muting and unmuting must also ramp.

## 5. UI / UX rules — must feel like a first-party Apple app

The app should look and behave as if Apple shipped it. When in doubt, follow the
**Apple Human Interface Guidelines for macOS** and see `.agents/skills/macos-hig-ui/SKILL.md`.

- Use **system controls only**: `Slider`, `Toggle`, `Picker`, `Menu`, `List`, `Form`, `Button` with
  system styles. Do not re-draw controls.
- Use **SF Symbols** for interface icons, with the appropriate symbol variants and rendering modes.
  App rows use the actual app icons supplied by macOS.
- Use **semantic colors and materials** (`.primary`, `.secondary`, `Color.accentColor`,
  `.regularMaterial`). No hard-coded hex colors, no custom fonts. Use system text styles
  (`.body`, `.caption`, …).
- Menu bar: `MenuBarExtra` with `.menuBarExtraStyle(.window)`; the icon is a custom template image (`MenuBarIcon` in `Assets.xcassets`) matching SF Symbols weight and rendering.
- **Liquid Glass**: on the newest macOS use the system's glass APIs/materials for floating controls
  and let standard components adopt the new look automatically. Do not fake glass with custom
  blurs. Never stack glass on glass. Guard newer APIs with `if #available(...)` and fall back to
  system materials.
- Support **Light and Dark** appearance, the user's **accent color**, **Increase Contrast**,
  **Reduce Transparency**, and **Reduce Motion**.
- **Accessibility**: every control has an accessibility label, value, and hint; full keyboard
  navigation; VoiceOver tested; sliders expose `accessibilityValue` as a percentage.
- Standard macOS behaviors: keep native keyboard navigation and ⌘Q. The initial mixer has no standalone Settings scene or Launch at Login registration.
- Animations: short, spring-based, system defaults. Honor Reduce Motion.
- Provide an app icon built to current Apple icon guidelines.

## 6. Security rules (summary — full policy in `SECURITY.md`)

- **Principle of least privilege.** Do not add entitlements, `Info.plist` usage strings, or system
  permissions without asking first.
- **No network access.** Do not add `com.apple.security.network.*` entitlements or networking code.
- **Hardened Runtime stays on.** Never add `allow-jit`, `allow-unsigned-executable-memory`,
  `disable-library-validation`, or `allow-dyld-environment-variables`.
- **No shelling out** (`Process`, `NSTask`, `system()`), no `eval`-like behavior, no dynamic code loading.
- **Never access audio samples outside the real-time renderer.** The renderer checks that the tap provides signal before muting the source and copies attenuated audio directly into Core Audio output buffers. Samples are never stored, logged, or transmitted.
- Logs must not contain app names, bundle IDs, or paths unless marked `privacy: .private`.
- No secrets, certificates, `.p12`, provisioning profiles, or API keys in the repo.
- New third-party dependency? **Ask first.** Default answer is no — prefer Apple frameworks.

## 7. Boundaries

### ✅ Always
- Run build + tests before declaring work done
- Write or update unit tests for logic changes (gain math, device selection, persistence, model state)
- Keep changes small and focused. Explain *why* in commit messages.
- Handle audio device changes, app termination, and permission denial gracefully
- Clean up taps and aggregate devices on quit and on errors. Use only process-private HAL objects so macOS reclaims them when their owner exits.

### ⚠️ Ask first
- Adding any dependency (SPM, binary, script)
- Adding or changing entitlements, `Info.plist` privacy keys, or deployment target
- Changing the audio architecture (taps ↔ driver)
- Adding persistence beyond `UserDefaults`
- Adding any background helper, login item, or XPC service

### 🚫 Never
- Commit secrets or signing material
- Disable security features, warnings, or tests to make a build pass
- Silence strict-concurrency errors with `@unchecked Sendable` without a written justification
- Ship UI that ignores the HIG for the sake of a custom look
- Edit generated files or the `.xcodeproj` by hand if a project generator/manifest owns them

## 8. Definition of done

A task is complete only when:
1. The project builds with **zero warnings**
2. All tests pass; new logic has tests
3. UI changes verified in Light + Dark, and with VoiceOver / keyboard-only
4. No new permissions, entitlements, or dependencies unless approved
5. `SECURITY.md` and this file updated if behavior or rules changed
6. A short summary lists what changed, what was tested, and any open risks

## 9. Skills

When the project-specific playbooks are available in `.agents/skills/`, load the relevant one before starting:

| Skill | Use when |
|---|---|
| `macos-hig-ui` | Creating or changing any UI, icons, menu bar, or accessibility |
| `coreaudio-process-taps` | Touching per-app capture, gain, aggregate devices, device switching |
| `security-review` | Before finishing any change touching audio, entitlements, deps, logging, or storage |
| `release-notarization` | Preparing a build for distribution |
