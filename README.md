<p align="center"><img src="docs/icon.png" width="128" alt="Limpo icon"></p>

<h1 align="center">Limpo</h1>

<p align="center">A free, open-source Mac cleaner that shows you exactly what it removes.<br>
Native SwiftUI · no network access · no telemetry · moves to Trash by default.</p>

<p align="center"><a href="#português">Português</a></p>

---

## What it does

| Module | What it finds |
|---|---|
| **Cleanup** | App caches and logs, Xcode Derived Data, package-manager caches (Homebrew, npm, Yarn, pip, Cargo, Go…), editor caches, leftovers from AI tools (Claude Code, Claude Desktop, Codex, Gemini CLI, Cursor, OpenCode), local AI models, iOS update files and backups, installers in Downloads, and the Trash. |
| **Dev Purge** | `node_modules`, `target`, `.venv`, `.next`, `build`, `DerivedData` and ~40 other regenerable folders inside your projects. Projects you haven't touched in 30 days are preselected. |
| **Space Lens** | A treemap and sorted list of what takes up space in any folder. Browse in, select, remove. |
| **Uninstaller** | Removes an app together with its preferences, caches, containers, saved state and launch agents. |
| **History** | Every removal, with one-click restore for items still in the Trash. |

## Safety first

Cleaning tools delete things. Limpo is designed so that a mistake is hard to make and easy to undo:

- **Trash by default.** Everything goes to the Trash unless you switch to permanent deletion in Settings.
- **Review before removing.** Nothing is removed without a confirmation that shows the item count and size. Every item has a **Why?** button that lists the checks it passed (owner app, age, rule, protections), and can be revealed in Finder or ignored forever.
- **Undo from History.** Every run is recorded on your Mac. Items still in the Trash can be put back where they were with one click.
- **Open apps are respected.** Files of apps that are running are held back until you quit them (Limpo can quit and reopen them for you).
- **Dry run mode** shows what would be removed without touching anything.
- **Protected locations.** Your home folder, Documents, Desktop, `~/Library` itself, `/System`, `/usr` and similar folders are never removed. Keychains, SSH keys, Mail, Messages, Safari, Photos and iCloud Drive are never touched at any depth.
- **Re-validated at removal time.** Each path is checked again right before removal. Symlinks are never followed, so a link can't redirect a removal outside the allowed folders. Locked, SIP-protected and iCloud-only files are skipped, never force-unlocked.
- **Proof before purge.** Dev Purge only flags a folder when a project file proves what it is: `node_modules` needs a `package.json` beside it, and `target` needs `Cargo.toml`, `pom.xml` or `build.sbt`. A random folder called `build` in your notes is left alone.
- **Active work is left alone.** Temporary files of AI tools touched in the last 24 hours are skipped, so running sessions aren't broken.
- **Exact matching in the uninstaller.** Leftovers are matched by exact bundle identifier, never by fuzzy name guessing. Apple apps are not listed.
- **Caution items are never preselected,** for example Xcode archives, iPhone backups and local AI models.

## Privacy

Limpo makes **no network requests**. It has no analytics, no crash reporter, no remote configuration and no account. Your settings live in `~/Library/Application Support/Limpo/settings.json`.

## Install

### Download

1. Get `Limpo.zip` from [Releases](../../releases) and move `Limpo.app` to `/Applications`.
2. Releases are not notarized by Apple yet, so macOS will block the first launch. Allow it once:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Limpo.app
   ```
   Alternatively, try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Build from source

Requires macOS 14+ and Xcode 16+.

```sh
git clone https://github.com/guiboorges/limpo.git
cd limpo
scripts/build-app.sh        # creates build/Limpo.app
open build/Limpo.app
```

Run the tests with `swift test`.

### Full Disk Access (optional)

Some categories live in protected folders: sandboxed app caches, Mail downloads and iPhone backups. To include them, add Limpo under **System Settings → Privacy & Security → Full Disk Access**. Without it, those categories are skipped instead of flooding you with permission prompts.

## Adding cleaning rules

Cleanup rules live in [`Sources/LimpoCore/Resources/rules.json`](Sources/LimpoCore/Resources/rules.json), so you can add support for an app without writing Swift. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Project layout

```
Sources/LimpoCore   scanning, safety policy and removal (no UI; fully tested)
Sources/Limpo       SwiftUI app
Tests               unit tests, run against a throwaway fake home folder
scripts             app bundle and icon builders
```

## Disclaimer

Limpo is an independent project and is not affiliated with any commercial Mac cleaner. Use it at your own risk; the defaults are conservative, but always review what you remove. Licensed under the [MIT License](LICENSE).

---

## Português

**Limpo** é um limpador para Mac gratuito e de código aberto que mostra exatamente o que vai remover. É uma app nativa em SwiftUI, não faz ligações à rede, não tem telemetria e manda tudo para o Lixo por omissão.

- **Limpeza:** caches e logs de apps, Xcode, gestores de pacotes, editores e ferramentas de IA (Claude Code, Codex, Cursor…), atualizações e backups de iOS, instaladores e o Lixo.
- **Dev Purge:** `node_modules`, `target`, `.venv`, `.next` e outros artefactos de projetos que podem ser reconstruídos. Só aparecem quando existe um ficheiro de projeto que prove o que são.
- **Space Lens:** mapa do que ocupa espaço numa pasta.
- **Desinstalador:** remove apps juntamente com os ficheiros de suporte, que são encontrados pelo bundle ID exato.

**Segurança:**
- vai para o Lixo por omissão e tem modo de simulação;
- há pastas protegidas que nunca são apagadas;
- cada caminho volta a ser validado antes de ser removido;
- nunca segue links simbólicos;
- os itens de risco nunca vêm pré-selecionados.

**Privacidade:** zero pedidos de rede, sem analytics nem configuração remota.

**Instalar:** descarrega `Limpo.zip` em [Releases](../../releases). Depois, corre `xattr -dr com.apple.quarantine /Applications/Limpo.app`, ou compila tu mesmo com `scripts/build-app.sh`.

**Contribuir:** as regras de limpeza estão em `rules.json`. Vê o [CONTRIBUTING.md](CONTRIBUTING.md).
