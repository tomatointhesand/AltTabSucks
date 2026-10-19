# Local file migrations

Some files on each machine are never committed: your own hotkeys and config. A `git pull` updates
the tracked code around them but can't change them, so when an update renames, removes or replaces
something those files use, the change has to be made by hand — or by an agent following this file.

Each entry below describes one such change: which local file it touches, how to tell whether it
still needs doing, and exactly what to do. Entries are applied oldest first (top to bottom).

**Local (untracked) files these entries operate on:**

| Platform | File | Notes |
|---|---|---|
| Windows | `lib/app-hotkeys.ahk` | Hand-written hotkeys. Its tracked `lib/app-hotkeys.template.ahk` is regenerated from it on every commit (`hooks/pre-commit`), so a migration missed here comes back into the template. |
| Windows | `lib/config.ahk` | Browser paths and settings, written by the Settings GUI. |
| Windows | `lib/hotkeys.json` | Hotkeys UI bindings. Prefer changing these through the UI or server, not by hand. |
| Linux | `linux/kwin/alttabsucks/contents/code/hotkeys.json` / `hotkeys.js` | Hotkeys UI bindings; `hotkeys.js` is generated from `hotkeys.json` on Save. |
| Linux | `linux/server/config.py` | Browser config, written by `./installer.sh configure`. |

---

## For agents: applying pending migrations

Do this after the user pulls, or when `hooks/post-merge` reports pending migrations.

1. **List what's pending:** `bash dev-scripts/pending-migrations.sh`. It prints each entry not yet
   recorded for this clone and the commit that introduced it. The record lives at
   `$(git rev-parse --git-common-dir)/alttabsucks-local-migrations`, inside `.git/`, so it is
   per-clone and never committed.
2. **For each pending entry, in order:**
   1. **Platform and file.** If the entry's platform isn't this machine's, or its file doesn't
      exist here, record it as `not-applicable` (step 6) and move on.
   2. **Detect.** Run the entry's detection check. If it finds nothing, the change is already in
      place (a fresh clone, a hand edit, an earlier partial run): record it as `already-done`.
   3. **Back up** each file before changing it, to
      `$(git rev-parse --git-common-dir)/alttabsucks-migration-backups/<ID>/<repo-relative path>`.
      Inside `.git/`, so backups can never be committed — these files hold real URLs and paths.
   4. **Apply** the steps exactly. Keep the file's existing line endings (most Windows `.ahk`
      files are CRLF) and encoding. Change only what the entry names. If something matches the
      detection but the entry doesn't clearly say what to do with it, stop and ask the user rather
      than guessing — these are the user's own files.
   5. **Verify** with the entry's verify step.
   6. **Record** it: `bash dev-scripts/pending-migrations.sh --mark <ID> <applied|already-done|not-applicable>`.
3. **Report** to the user: what was applied, what was already done or not applicable, every line
   changed or removed, and where the backups are. Don't commit anything — these files are
   untracked by design.

Never run an entry's steps without its detection check first, and never skip the backup.

## For authors: adding an entry

Add one **in the same commit** as any change that leaves a local file stale: a removed or renamed
function or hotkey, a new required config value, a binding schema change that isn't backward
compatible. Changes that keep working with old local files don't need one.

- Append at the **bottom** (entries apply top to bottom).
- ID: `YYYY-MM-DD-short-slug`, the heading text after `## `. Never rename or reorder an ID once
  pushed; other clones have it recorded.
- Don't write commit hashes into an entry: a commit can't contain its own hash, and rebases change
  them. `pending-migrations.sh` finds the introducing commit from history instead.
- Make detection precise enough that running the entry twice is harmless.
- If the tracked template mirrors the file (`lib/app-hotkeys.template.ahk`), fix the template in
  the same commit too, so fresh clones are right from the start.

Use this shape:

```
## YYYY-MM-DD-short-slug

**Applies to:** <platform> — `<local file>`
**Why:** <what changed upstream and what breaks without this>
**Detect:** <exact check; no match means already done>
**Steps:**
1. ...
**Leave alone:** <things that look similar but must not change>
**Verify:** <exact check>
```

---

## 2026-09-19-linux-browser-resource-class

**Applies to:** Linux — `linux/server/config.py`
**Why:** The browser's window `resourceClass` moved from a field on every browser-scoped binding
(Cycle browser profile, Focus browser tab, split, merge) to one value in `config.py`,
`CHROMIUM_RESOURCE_CLASS`. Without it, saving any of those bindings in the Hotkeys UI fails with
"no browser configured — run ./installer.sh configure to set one".
**Detect:** `grep -q '^CHROMIUM_RESOURCE_CLASS' linux/server/config.py` succeeds → already done.
**Steps:**
1. Find the browser's resourceClass. Preferably from the old bindings: in
   `linux/kwin/alttabsucks/contents/code/hotkeys.json`, the `resourceClass` of any binding whose
   `type` is `profileCycle`, `tabFocus`, `splitTab` or `mergeTabs` (they all hold the same value).
   If there are none, ask the user, or have them run `./installer.sh configure`, which detects it.
2. Add `CHROMIUM_RESOURCE_CLASS = "<value>"` on its own line after `CHROMIUM_EXE` in `config.py`.
3. `systemctl --user restart alttabsucks-server.service`.

**Leave alone:** the old `resourceClass` keys on those bindings in `hotkeys.json` — now ignored,
harmless. `windowCycle`/`windowToggle` bindings keep their own `resourceClass`; it's still used.
**Verify:** `GET /hotkeys-config` returns the value as `browserResourceClass`:
`curl -s localhost:9876/hotkeys-config -H "X-AltTabSucks-Token: $(cat Server/token.txt)"`.

## 2026-10-18-explorer-focus-or-open

**Applies to:** Windows — `lib/app-hotkeys.ahk`
**Why:** `FocusOrOpenFolder(path)` (`lib/explorer.ahk`) replaces a bare `Run(folderPath)`, which
opened a duplicate Explorer window on every press. Optional, but it's the fix for that bug.
**Detect:** a `Run(...)` call whose argument is a **folder**: a quoted path ending in `\`, or an
`EnvGet(...)` expression for a folder like `EnvGet("USERPROFILE") "\Downloads"`. No such call →
already done.
**Steps:**
1. Replace `Run(` with `FocusOrOpenFolder(` in those calls only, keeping the argument unchanged.

**Leave alone:** `Run()` of a program, script or URL — `.exe`, `.bat`, `.ps1`, `powershell.exe ...`,
`http...`, a variable like `TrayAppPath`. When it's unclear whether an argument is a folder, ask.
**Verify:** AltTabSucks reloads (Ctrl+Alt+Shift+') without errors, and the hotkey focuses an
already-open window for that folder instead of opening another.

## 2026-10-18-remove-secrets

**Applies to:** Windows — `lib/app-hotkeys.ahk`
**Why:** The gopass secrets manager was removed: `lib/secrets.ahk`, `lib/secret-bridge.sh`,
`dev-scripts/manage-secrets.sh`. `SendSecret` and friends no longer exist; calls to them warn at
load and throw when pressed.
**Detect:**
`grep -nE 'SendSecret|GetSecret|SecretCacheClear|SecretVaultLock|SecretName[0-9]*[[:space:]]*:=|manage-secrets' lib/app-hotkeys.ahk`
— no output → already done.
**Steps:**
1. A hotkey whose whole body is a secrets call (e.g. `^!+=:: { SendSecret(PasswordSecretName1) }`,
   or a hotkey running `manage-secrets.sh`): delete the hotkey, including its `{ }` block.
2. A hotkey that does other things too (e.g. the PuTTY launcher ending in
   `SendSecret(UserSecretName1)`): delete just the secrets line. If the line right before it is a
   bare `Sleep(...)` that only waited for it, and nothing follows in the block, delete that too.
3. Delete `PasswordSecretNameN :=` and `UserSecretNameN :=` assignments, commented or not.
4. Delete a `UserName1 :=`-style assignment only if nothing else in the file uses that variable.

**Leave alone:** everything else in the sensitive section (profile variables, URLs). Don't touch
the gopass store or uninstall gopass/GnuPG — tell the user they can, if nothing else uses them.
**Verify:** the detection grep prints nothing, and AltTabSucks reloads without "never assigned"
or missing-function warnings for those names.

## 2026-10-19-remove-hotkey-reference

**Applies to:** Windows — `lib/app-hotkeys.ahk`
**Why:** The Ctrl+Alt+Shift+/ hotkey-list popup was removed; the web Hotkeys UI (Ctrl+Alt+/, or the
tray's "Hotkeys UI" entry) replaces it. `_BuildHotkeyRef` no longer exists.
**Detect:** `grep -n '_BuildHotkeyRef' lib/app-hotkeys.ahk` — no output → already done.
**Steps:**
1. Delete each hotkey line calling `_BuildHotkeyRef`, normally
   `^!+/:: ShowTextGui("Hotkey Reference", _BuildHotkeyRef(), 1250, 45)`.
2. Delete the comment line directly above it if it's the
   `; --- Hotkey quick reference (auto-generated from this file) ---` header.

**Leave alone:** other `ShowTextGui(...)` calls — the function still exists.
**Verify:** the detection grep prints nothing, and AltTabSucks reloads without errors.
