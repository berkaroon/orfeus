# Security Policy

This document covers (1) how to report vulnerabilities and (2) the security design rules that
contributors and AI agents must follow in this project. Set up a private reporting channel before publishing a public release.

## 1. Supported versions

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Previous minor | ⚠️ critical fixes only |
| Older | ❌ |

## 2. Reporting a vulnerability

**Do not open a public issue for security problems.**

- If Orfeus is published via GitHub, use *Private vulnerability reporting* (Security → Report a vulnerability).

Please include: affected version, macOS version, reproduction steps, and impact. Coordinate public disclosure with the maintainer after a fix ships.

## 3. What the app does (and does not do)

| Property | Design |
|---|---|
| Purpose | Per-app volume control on macOS |
| Audio access | Reads system audio of selected processes with active output via Core Audio process taps, applies gain, and plays it back to the output device |
| App discovery | Uses the local macOS list of running apps, local app bundle metadata and icons, and Core Audio output activity. Observed app identities are kept in memory for the Orfeus session |
| Audio storage | **None.** Samples live only in memory buffers and are never written, logged, or transmitted |
| Network | **None.** No telemetry, analytics, crash upload, or update checks |
| Microphone | **Not used** |
| Accessibility / Full Disk Access / Screen Recording | **Not used** |
| Persistent data | Per-app volume/mute settings in `UserDefaults`, keyed by bundle identifier |
| Privileged helpers / drivers | **None** (no kernel/DriverKit extension, no HAL plug-in, no root helper) |

If a change would alter any row of this table, it needs an explicit security review and a
documented update to this file.

## 4. Threat model (summary)

**Assets:** the user's audio streams (may contain calls, meetings, private media), the list of
running audio apps, user settings, signing identity, release artifacts.

| Threat | Mitigation |
|---|---|
| Eavesdropping on audio by the app or a compromised dependency | No network entitlement; no dependencies by default; audio never persisted; code review for any buffer handling |
| Over-broad permissions / privilege creep | Least-privilege entitlements; any new permission requires approval and an entry in §5 |
| Malicious code injection into the app process | Hardened Runtime, library validation on, no JIT, no DYLD env vars, signed and notarized builds |
| Supply-chain compromise (dependency, CI, build tools) | Few/no dependencies; pinned versions; reviewed updates; CI actions pinned by commit SHA |
| Tampered distribution | Developer ID signature, notarization, stapled ticket, published checksums |
| Privacy leakage via logs | `os.Logger` with `privacy: .private` for app names, bundle IDs, paths; no audio content ever logged |
| Memory-safety bugs in audio path | Swift renderer with bounded buffer layout checks and unit tests. The in-tree C11 shim only implements lock-free atomic handoff to support macOS 14.2. |
| Stale taps / aggregate devices left behind (resource leak, audio muted forever) | Explicit teardown on quit and error. Taps and aggregate devices are private and macOS owns their cleanup when the process exits. |
| Hearing/speaker damage from gain bugs | Hard clamp on gain, per-buffer ramping, optional limiter, tested gain math |

Out of scope: attacks requiring an already-root attacker or physical access with the user's login.

## 5. Permissions and entitlements

Keep this table in sync with the real `.entitlements` and `Info.plist`.

| Item | Status | Reason |
|---|---|---|
| `NSAudioCaptureUsageDescription` (Info.plist) | Required | Core Audio process taps need the user's "System Audio Recording" consent. The string must honestly say audio is processed locally for volume control and never saved or sent |
| App Sandbox (`com.apple.security.app-sandbox`) | **OFF in this build** | No entitlements requested. Enabling App Sandbox requires approval and process-tap compatibility verification. |
| `com.apple.security.network.client` / `.server` | **OFF** | No networking |
| `com.apple.security.files.*` | **OFF** | No file access needed |
| Hardened Runtime | **ON** | Verified on the local app signature. Developer ID and notarization are separate public release steps. |
| `allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`, `allow-dyld-environment-variables` | **Forbidden** | Weakens code-signing protections |
| Launch at Login (`SMAppService.mainApp`) | Omitted | The menu-bar app has no login registration or helper bundle. |

Rules:
- Permission denial must degrade gracefully: show a clear in-app explanation and a button that
  opens the relevant System Settings pane. Never loop-prompt.
- Request permission **in context** (when the user first enables control of an app), not at launch. If the
  selected app is idle, defer the first capture attempt until its output becomes active.

## 6. Secure development rules

1. **Dependencies:** default is zero third-party dependencies. If one is approved: pin an exact
   version, commit `Package.resolved`, review the source and its transitive dependencies, and
   record the justification in the PR. Re-review on every update.
2. **No dynamic code:** no `Process`/`NSTask`/`system()`, no `dlopen` of non-system paths, no
   scripting engines, no plug-in loading.
3. **Memory safety:** avoid `Unsafe*` APIs. Where unavoidable (Core Audio buffers), confine them
   to a tiny audited wrapper with explicit bounds checks and tests.
4. **Input handling:** treat data from the system (process lists, bundle IDs, device names) and
   from `UserDefaults` as untrusted. Validate and clamp (e.g. gain in `0...1`, finite floats only —
   reject `NaN`/`inf`).
5. **Concurrency:** Swift 6 strict concurrency enabled; no `@unchecked Sendable` without a written justification.
6. **Errors:** no force unwraps, `try!`, or `fatalError` in production paths. Fail safe: if anything goes
   wrong in the audio path, **restore pass-through (unity gain / remove taps)** rather than staying muted or distorted.
7. **Logging:** `os.Logger` only; mark identifying values `.private`; never log audio data.
8. **Secrets:** none in the repo. `.gitignore` must cover `*.p12`, `*.cer`, `*.mobileprovision`,
   `*.provisionprofile`, `.env*`, notarization credentials. Use the macOS Keychain /
   `notarytool store-credentials` locally and encrypted CI secrets.
9. **CI:** least-privilege tokens, GitHub Actions pinned to full commit SHA, no secrets exposed to
   pull requests from forks, branch protection with required review on `main`.
10. **Updates:** if auto-update is ever added it requires a design review (signature verification
    with a pinned public key, HTTPS only, no downgrade). Until then, there is no update mechanism.

## 7. Pre-release security checklist

- [ ] `.entitlements` and `Info.plist` match §5 exactly (no extras)
- [ ] No network code or entitlement (`grep -R "URLSession\|NWConnection\|CFNetwork" .` returns nothing relevant)
- [ ] Dependency list unchanged or each change reviewed
- [ ] No new `Unsafe*` usage outside the audited wrapper
- [ ] Logs reviewed for private data
- [ ] Teardown tested: quit, force-quit, crash relaunch, device unplug, target app exit
- [ ] Permission denied / revoked flows tested
- [ ] Signed with Developer ID, Hardened Runtime on, **notarized and stapled**
- [ ] Checksums (SHA-256) published with the release

Verification commands:

```bash
codesign --verify --deep --strict --verbose=2 Orfeus.app
codesign -dvv --entitlements :- Orfeus.app     # inspect entitlements & flags
spctl --assess --type execute --verbose Orfeus.app
xcrun stapler validate Orfeus.app
shasum -a 256 Orfeus.dmg
```

## 8. For AI agents

Before finishing any change that touches audio, entitlements, `Info.plist`, dependencies, logging,
or storage, review this policy and, if available, run through `.agents/skills/security-review/SKILL.md`. If a requested change conflicts
with this policy, stop and ask the human instead of working around it.
