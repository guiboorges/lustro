# Decision engine: deciding what can be removed

Status: **proposal**. This describes how Limpo should decide, for any file, whether it may be removed, whether it should be preselected, and why. It is informed by a behavioural study of how commercial cleaners make these decisions. No code, data or assets from them are used.

## Goals

1. Every item has an **owner**, a **kind** and a **verdict** (`safe`, `review`, `caution`, `never`), with **reasons** a user can read.
2. Unknown files are never treated as junk. Something becomes junk only when a rule or a strong signal says so.
3. The knowledge is **open data**: anyone can read, review and improve it. That is the main advantage over closed, encrypted rule databases.

## Current pipeline vs. reference behaviour

| Stage | Commercial reference (observed behaviour) | Limpo today |
|---|---|---|
| Discovery | Fixed locations per category; the KB can request a deep search inside a folder | Glob rules in `rules.json` |
| Scan-time exclusions | Central KB ignore list (closed), user ignore list, `.DS_Store`, SIP (`com.apple.rootless`) and `SF_RESTRICTED` flags; tiny logs skipped | User ignore list, protected/denied paths, per-rule `exclude`, symlink-safe resolution |
| Ownership | Cache folder name looked up as a bundle ID through LaunchServices; the uninstaller adds KB file lists, container metadata and team IDs | Rule `owners` + bundle-ID/name folder heuristics (`AppOwnership`) |
| Preselection | A per-item flag set by each scanner, plus a global Off/Smart/Full mode; per-category exceptions (keep newest backup per device, keep most-recent Photos cache) | Per-category `autoSelect`; `caution` never preselected; project inactivity for Dev Purge |
| Running apps | Blocking Quit / Force Quit / Ignore; apps it closed are reopened afterwards | Quit / Skip / Cancel; apps are **not** reopened yet |
| Removal guards | Protected top-level folders; refuses symlinks in privileged removals; disables iCloud downloads process-wide; permanent delete; clears immutable flags | Re-validation before every removal, symlink-safe; **Trash by default**; respects immutable flags (fails instead of clearing them) |
| Age / in use | No minimum age for caches; no open-file check | 24 h minimum age for AI-tool temp files |

Limpo is already stricter on removal: Trash by default, re-validation, symlink safety, exact uninstaller matching. Its gaps are in **knowledge** (no curated per-app data), **ownership** (no LaunchServices lookup, no orphan detection) and **preselection nuance**.

## Proposed design

### 1. Classification result

Every scanner returns items with a classification instead of a bare path:

```swift
struct Classification {
    var owner: Owner?          // bundle ID, display name, installed?, running?
    var kind: Kind             // cache, log, temporary, buildArtifact, download, backup, appData, settings, unknown
    var verdict: RiskLevel     // safe / review / caution (+ never = filtered out)
    var preselect: Bool
    var reasons: [Reason]      // rule ID, signals that fired, exceptions applied
}
```

The UI shows `reasons` under an **"Why is this safe?"** disclosure, for example: *"Cache of Google Chrome (com.google.Chrome) · Chrome rebuilds it · not modified in 3 days · rule system-user-caches"*.

### 2. Knowledge base v2 (open, per-app)

`rules.json` stays for categories. A new `apps/` folder holds one small file per app:

```jsonc
// Sources/LimpoCore/Resources/apps/com.google.Chrome.json
{
  "bundleIDs": ["com.google.Chrome"],
  "names": ["Google Chrome"],
  "files": [
    { "path": "~/Library/Caches/Google/Chrome/*",                       "kind": "cache",    "verdict": "safe" },
    { "path": "~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage", "kind": "cache", "verdict": "safe" },
    { "path": "~/Library/Application Support/Google/Chrome",           "kind": "appData",  "verdict": "never" }
  ],
  "requiresQuit": true
}
```

- `never` entries override everything. They are the curated "do not touch" knowledge, e.g. sync clients' caches that hold unsent files, or Chrome's profile data.
- The uninstaller uses the same entries, so leftovers found in non-standard places are found too.
- Contributions are reviewable JSON with CI validation. Each entry should cite where the behaviour is documented.

### 3. Ownership resolver

The resolver tries, in order:
1. **Rule/KB owner.**
2. **Bundle-ID folder name → LaunchServices** (`NSWorkspace.urlForApplication(withBundleIdentifier:)`) to learn whether the app is installed and where.
3. **Container metadata** (`.com.apple.containermanagerd.metadata.plist`, `MCMMetadataIdentifier`) for `~/Library/Containers`.
4. **Team-ID prefix** for Group Containers.
5. **Name heuristics**, as today.

The outcome is installed / not installed / unknown, which unlocks the next feature.

### 4. Leftovers of removed apps (new category)

When a bundle-ID-named folder in `~/Library/{Application Support,Caches,Containers,Preferences,…}` has **no installed owner**, it is a candidate leftover. Its verdict is `review`, and it is never preselected unless the KB confirms the bundle ID and the folder is older than 30 days. This is one of the most valuable things commercial cleaners do. Exact bundle-ID matching keeps it safe.

### 5. Signals and guards

Each signal adds a reason and may lower the verdict. None of them can raise it:
- **iCloud / File Provider:** items that are ubiquitous or dataless (`SF_DATALESS`, `URLResourceKey.ubiquitousItemDownloadingStatus`) are skipped. Measuring them must never trigger a download.
- **System protection:** the `com.apple.rootless` xattr, or `SF_RESTRICTED`/`UF_IMMUTABLE` flags, mean the item is skipped (`never`). Unlike some cleaners, Limpo will **not** clear immutable flags.
- **Recency:** a per-kind minimum age (temporary 24 h; logs and caches optional). `kMDItemLastUsedDate` is used where it is meaningful.
- **Size floor:** zero-byte and tiny items are hidden to reduce noise.
- **In use (optional, later):** a check of open file handles via `proc_pidinfo` for items above a size threshold.

### 6. Preselection policy

- A global mode in Settings: **Off / Smart (default) / All safe**.
- Category exceptions expressed as data, for example `"keepNewest": { "groupBy": "deviceID", "count": 1 }` for iOS backups, or `"keepNewest": 1` for Xcode device-support versions.
- `caution` is never preselected, whatever the mode.

### 7. After removal

- Apps that Limpo quit are **reopened in the background** afterwards.
- A **removal history** (`~/Library/Application Support/Limpo/history.jsonl`) records path, size, rule and Trash location, so items can be restored in one click while they are still in the Trash.

## Roadmap

| Phase | Scope | Size |
|---|---|---|
| 1 | Classification reasons + "Why?" UI; iCloud/dataless and SIP/restricted/immutable guards; reopen quit apps; keep newest iOS backup per device | Small |
| 2 | Ownership resolver (LaunchServices + container metadata); **Leftovers of removed apps** category | Medium |
| 3 | Per-app knowledge base v2 with `never` entries; uninstaller reuses it; CI validation + contribution guide | Medium |
| 4 | Preselection modes; removal history with restore; optional open-file check | Medium |
