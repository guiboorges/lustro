# Contributing

Thanks for helping. Lustro removes files, so every change is judged first by one question: *could this delete something a person wants to keep?*

## Adding or changing cleaning rules (`rules.json`)

Categories live in `Sources/LustroCore/Resources/rules.json`. Each target is a glob (`*`, `?`, `[…]`; no `**`).

- Prefer narrow paths. `~/Library/Application Support/Foo/Cache` is good; `~/Library/Application Support/Foo/*` is not.
- Use `"risk": "review"` unless the owning app or macOS rebuilds the files automatically; use `"caution"` for anything that can't be recreated.
- Set `minAgeHours` for temporary files that a running tool may still be using.
- List the owning apps in `owners`, so their files are held back while they run.

## Adding app knowledge (`apps.json`)

`Sources/LustroCore/Resources/apps.json` describes what belongs to a specific app:

```json
{
  "bundleIDs": ["com.vendor.App"],
  "name": "App",
  "files": [{ "path": "~/Library/Application Support/App/Cache", "kind": "cache" }],
  "never": ["~/Library/Application Support/App"],
  "why": "Profiles hold the user's documents; only Cache is disposable."
}
```

- `never` entries are never suggested for removal by any category, and a folder that *contains* one is protected too.
- `files` entries are exceptions inside `never` folders (caches inside a profile, for example). The Uninstaller also uses both lists to find the app's files in non-standard places.
- `why` is required: say what the data is and how you know (a vendor doc, the app's own help, or how you observed it).
- Paths must start with `~/`. Paths shared by several apps (like `~/Library/CloudStorage`) are fine in `never`, but the Uninstaller won't offer them for any single app.

`swift test` validates both files (`KnowledgeBaseTests.bundledFileIsValid`), and CI runs it on every pull request.

## Code

- `Sources/LustroCore` holds everything that decides or removes; it has no UI and is fully tested. New logic goes there, with tests that use a throwaway home folder.
- The UI follows the design in Figma; propose visual changes as screenshots first.
- No network access, analytics or telemetry, ever.
