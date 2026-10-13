# Contributing to Limpo

Thanks for helping! The most useful contributions are **new cleaning rules** and **bug reports about anything Limpo removed that it shouldn't have**. The second kind is treated as the highest priority.

## Adding a cleanup rule

Rules live in `Sources/LimpoCore/Resources/rules.json`. Each category looks like this:

```json
{
  "id": "dev-example-tool",
  "section": "Developer tools",
  "title": "Example Tool cache",
  "detail": "What this is and what happens when it's removed (shown in the app).",
  "risk": "safe",
  "autoSelect": true,
  "minAgeHours": 24,
  "requiresFullDiskAccess": false,
  "targets": [
    { "path": "~/Library/Caches/com.example.tool/*", "exclude": ["keep-me"] }
  ]
}
```

| Field | Meaning |
|---|---|
| `id` | Unique, kebab-case. |
| `section` | Group heading in the UI: `AI tools`, `Developer tools`, `System`, `Trash`. |
| `risk` | `safe`: regenerated automatically. `review`: usually fine but worth a look. `caution`: may hold data the user wants; **never preselected**. |
| `autoSelect` | Whether items start selected. Ignored for `caution`. |
| `minAgeHours` | Optional. Skip items modified more recently than this (use for temp/session files). |
| `requiresFullDiskAccess` | Optional. Category is skipped unless Full Disk Access is granted. |
| `targets[].path` | Glob path. `~` and `*`, `?`, `[...]` inside a segment are supported; `**` is not, so scans stay predictable. |
| `targets[].exclude` | Optional name patterns (last path component) that are never removed. |

**Guidelines**
- Point at the *contents* that are safe to delete (`.../Cache/*` or a specific cache folder), not at an app's whole support folder.
- Order matters. More specific categories should come **before** broad ones like "App caches", because the first category to claim a path keeps it.
- If deleting it loses user data, settings, logins or work in progress, it is not junk. Don't add it, or mark it `caution`.
- Explain in `detail` what is lost and whether it comes back.
- Run `swift test`. The catalog test checks that the JSON loads and that the IDs are unique.

## Dev Purge artifacts

Artifact rules are in `Sources/LimpoCore/ProjectArtifactScanner.swift` (`ArtifactRule.defaults`). Every generic folder name must require a **sibling marker file** that proves which ecosystem it belongs to.

## Code

- `LimpoCore` holds all logic that touches the file system. Changes there need tests, written against `FakeHome` (see `Tests/LimpoCoreTests/SafetyTests.swift`). Never test against the real home folder.
- Any change to `SafetyPolicy` needs a test that shows what is still refused.
- The app makes no network requests. Please keep it that way.

## Screenshots

```sh
LIMPO_SNAPSHOT=/tmp/shot.png LIMPO_MODULE=devPurge LIMPO_AUTOSCAN=1 build/Limpo.app/Contents/MacOS/Limpo
```

This renders the window to a PNG and quits. Check screenshots for personal paths before you share them.
