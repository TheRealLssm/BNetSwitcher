# Battle.net Account Switcher — Dark Edition

A fast, dark-themed GUI for switching between Battle.net accounts on Windows, with live Overwatch 2 rank display.

> **Fork notice** — this is a fork of [**BNetSwitcher** by Nepero27182](https://github.com/Nepero27182/BNetSwitcher).
> All credit for the original tool and the core switching approach goes to them. This fork rewrites the GUI,
> fixes the rank lookup, and adds account management. The original is licensed "use as you wish".

https://discord.gg/ySbvQZn4X3 My Discord server for any issues or Future tools
---

## Why this fork exists

The original tool worked, but the rank column never populated. Three separate bugs caused that, all fixed here:

1. **TLS.** PowerShell 5.1 defaults to TLS 1.0, which the rank API rejects — every lookup failed silently. Now forces TLS 1.2.
2. **Wrong field name.** The code read `open_queue`; the API actually calls it `open`.
3. **Obsolete schema.** It parsed SR/`value` fields that no longer exist in Overwatch 2. Ranks are now division + tier (e.g. `Diamond 3`).

---

## Features

### Account switching
- One-click switching — the selected account moves to the top of `SavedAccountNames`, which is the account Battle.net logs into next.
- Double-click a row, press `Enter`, or use the Switch button.
- Automatically closes Battle.net (and optionally Overwatch), then relaunches.
- Optionally launches **Overwatch 2 directly**, skipping the launcher's Play button.
- Creates a `.backup` of `Battle.net.config` before every write.

### Overwatch 2 ranks
- Shows **Tank / Damage / Support / Open Queue** rank per account, with the official Blizzard rank badge next to each.
- Rank icons are downloaded once and cached locally in `%APPDATA%\BNetSwitcher\rankicons`.
- Fetching runs on background threads, so the window never freezes.
- PC and Console rank support.
- Data comes from the public [OverFast API](https://overfast-api.tekrop.fr).

> You enter each account's BattleTag once (`Name#1234`). Battle.net only stores emails, and a BattleTag
> cannot be derived from an email locally — so a one-time entry per account is unavoidable.

### BattleTag import / export
Right-click any row → **Import / export BattleTags** (also in Settings).

- Paste every tag at once instead of editing cells one at a time. Two accepted forms:
  `someone@mail.com = Name#1234` (explicit) or a bare `Name#1234` per line, filled into accounts top-down.
- Load from a `.txt`, `.csv` or `.json` file, or export your current tags to one — handy as a backup or
  when moving to another PC.
- **Validate tags** checks each one against the API before you commit, so a mistyped discriminator is
  caught immediately rather than showing up later as a missing rank.
- A preview table shows exactly what will change, and lines naming unknown accounts are flagged and skipped.
  Nothing is written until you press Apply.

> **Why there is no auto-detect:** BattleTags are not stored anywhere on your PC. Battle.net keeps login
> emails locally and fetches everything else from Blizzard's servers at runtime — the game logs, the
> per-account config files and the client's own caches contain no BattleTag. There is nothing on disk to
> read, so bulk entry with validation is as automatic as this can honestly get.

### Account management
- **Remove accounts** — purges the entry from `Battle.net.config` and deletes its saved BattleTag/status here.
  Writes a `.backup` first, plus a `removed-accounts.json` recovery log. Refuses to remove your last account,
  and warns if Battle.net is running (it rewrites its config on exit and would restore the entry).
- **Status flags** — mark an account **OK / Watch / Suspended / Banned**, with a free-text note and an optional
  suspension end date that counts down in the grid. Switching into a flagged account requires confirmation.

> **On ban detection:** this app cannot detect bans, and does not pretend to. Blizzard publishes no ban or
> suspension data, and no public API exposes it — the OverFast schema has no such field. The only available
> signal is a `404`, which equally means a typo'd BattleTag, a renamed account, a private profile, or an account
> that never played Overwatch. Auto-flagging on that would label working accounts as banned. **Status flags are
> set by you, manually**, which is why they're trustworthy.

### Overwatch settings profiles
Save named snapshots of Overwatch's local settings file and bind one to each account — it's applied
automatically on switch, while the game is closed.

- Save the current in-game settings as a named profile (e.g. `Competitive`, `Streaming`).
- Bind a profile to an account; switching to that account applies it before Battle.net relaunches.
- Update a profile from your current settings, or apply one on demand.
- Backs up the existing file first, and refuses to write while Overwatch is running (the game rewrites
  that file on exit and would discard the change).

**What a profile covers:** FPS cap, refresh rate, graphics preset, render scale, contrast, FPS/latency
overlays, window mode, master and music volume.

> **What it deliberately does *not* cover:** sensitivity, crosshairs and keybinds. Overwatch 2 does not
> store those locally — they're synced server-side per account, so they **already follow each account
> automatically**. A local preset for them would be redundant and would simply be overwritten by the
> cloud on login.

### Interface
- Overwatch-inspired dark theme by default — deep slate with the signature orange accent, and a proper
  dark title bar. Light and Auto (follow Windows) also available.
- **Player identity per account** — avatar, career title, endorsement level and namecard art, pulled from
  the same API call as the ranks, so it costs no extra requests.
- Resizable window that remembers its size.
- Active account marked with an orange bar.
- **Streamer mode** — masks account emails (`ab•••`) so they never appear on stream.
- Right-click any row for switch / status / refresh / copy email / remove.
- Status bar, per-cell tooltips, `F5` to refresh ranks, `Del` to remove.

---

## Install

### Recommended: build it yourself

Prebuilt PowerShell executables are frequently flagged as false positives by antivirus, because
[PS2EXE](https://github.com/MScholtes/PS2EXE) packaging is a technique malware also uses. Rather than asking you
to trust a binary from a stranger, **build your own from source in about ten seconds**:

```powershell
git clone https://github.com/TheRealLssm/BNetSwitcher.git
cd BNetSwitcher
.\build.cmd
```

Or just double-click **`build.cmd`** in the folder. It runs `build.ps1`, which installs the `ps2exe` module if
needed and produces `bnet-switcher.exe` next to the script. No admin rights needed.

> **"running scripts is disabled on this system"?** That's Windows' default PowerShell execution policy, and it's
> why `build.cmd` exists: it runs the build with `-ExecutionPolicy Bypass` for that one run only, without changing
> any system setting. If you'd rather call the `.ps1` yourself, allow scripts for the current window only:
>
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> .\build.ps1
> ```
>
> Downloaded the repo as a ZIP instead of cloning? Windows marks those files as "from the internet". Unblock
> them once from inside the folder: `Get-ChildItem -Recurse | Unblock-File`

If module installation still fails, run this once and retry:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
Install-Module ps2exe -Scope CurrentUser -Force
```

### No build required

You can skip the EXE entirely and run the script directly — double-click **`run.cmd`**, or make a shortcut to:

```
powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\bnet-switcher-gui.ps1"
```

Keep `bnet-switcher.ico` beside the script if you want the window icon.

---

## Requirements

- Windows 10 or later
- PowerShell 5.1 (ships with Windows) or newer
- Battle.net installed, and each account logged into at least once so it appears in the saved list
- Internet connection for rank lookups only — switching works fully offline

---

## Files this app touches

| Path | Purpose |
|---|---|
| `%APPDATA%\Battle.net\Battle.net.config` | Read + write `Client.SavedAccountNames` only |
| `%APPDATA%\Battle.net\Battle.net.config.backup` | Automatic backup before every write |
| `%APPDATA%\BNetSwitcher\accounts.json` | Your BattleTags, status flags and notes |
| `%APPDATA%\BNetSwitcher\settings.json` | App settings |
| `%APPDATA%\BNetSwitcher\rankicons\` | Cached rank badge images |
| `%APPDATA%\BNetSwitcher\playericons\` | Cached avatar and namecard images |
| `%APPDATA%\BNetSwitcher\profiles\` | Saved Overwatch settings profiles |
| `%APPDATA%\BNetSwitcher\removed-accounts.json` | Recovery log of removed accounts |
| `%APPDATA%\BNetSwitcher\network.log` | Every outbound request: time, host, resolved IP, result (capped at ~1 MB) |
| `Documents\Overwatch\Settings\Settings_v0.ini` | Read when saving a profile; written when applying one (backed up first) |

Nothing is written inside the repo folder, so your account data can never end up in a commit.

---

## Privacy & safety

- **No passwords, ever.** The app never reads, stores, or transmits credentials. Battle.net handles all authentication.
- **No telemetry.** No analytics, no tracking, no phone-home.
- **Two kinds of network call only**, and only for accounts where *you* entered a BattleTag:
  1. `overfast-api.tekrop.fr` — public rank lookup
  2. Blizzard's image hosts (`*.playoverwatch.com`, `d15f34w2p8l1cc.cloudfront.net`, `*.blizzard.com`) —
     rank badges, avatars and namecards
- **Image links are locked down.** The image addresses come from the API's response, so the app only follows
  `https://` links to Blizzard's image hosts above, and refuses files over 5 MB. Anything else is skipped and
  written to the network log as `BLOCKED`, so a bad or tampered response can't send your PC somewhere else.
- **Network log.** Every request is logged to `network.log` with the IP it resolved to (Settings →
  *Open network log*). If you see an unfamiliar IP in `netstat` or a firewall prompt, check the log: if it
  isn't there, it didn't come from this app.
- **Offline mode.** Settings → *Offline mode* turns off rank lookups, tag validation and image downloads.
  The app then makes no network calls at all and just switches accounts.
- **Backups before every config write.**
- **Open source.** It's plain PowerShell — read exactly what it does before you run it.

### Is this against Blizzard's rules?

This tool reorders a list in your own local config file — the same result as logging out and picking a different
saved account by hand. It does not touch the game client, read game memory, automate input, or interact with
Blizzard's servers in any unofficial way. It is a convenience wrapper around actions you can already perform manually.

That said, it is an unofficial community tool: use it at your own risk.

---

## Troubleshooting

**"Battle.net.config not found"** — install Battle.net and launch it at least once.

**Ranks show "Not found"** — check the BattleTag format (`Name#1234`, case-sensitive). A profile that has never
played competitive Overwatch, or a private profile, will also return not-found. This says nothing about ban status.

**Ranks show "Rate limited" or "Timeout"** — the public API has rate limits, and a profile it hasn't cached yet
can be slow. The app already retries twice with a short wait before giving up, so if you still see this, wait a
minute and press `F5`.

**No banner behind an account** — expected for most accounts. Blizzard stopped listing banners (namecards) in the
player search the rank service relies on, so it usually has none to send. The row gets a plain accent wash instead;
hover the account name to confirm the reason.

**A rank shows but its icon doesn't** — hover the rank cell. It says exactly why: the download failed (with the
error), the server sent something that isn't a picture, or the link was blocked as not coming from Blizzard.
`network.log` (Settings → *Open network log*) has the full request history.

**A removed account came back** — Battle.net was running and rewrote its config on exit. Close Battle.net, then remove again.

**Windows Defender flags the EXE** — that's the PS2EXE false positive described above. Build it yourself from
source, or skip the EXE and run the `.ps1` directly.

---

## Credits

- Original tool: [**Nepero27182/BNetSwitcher**](https://github.com/Nepero27182/BNetSwitcher)
- Rank data: [OverFast API](https://overfast-api.tekrop.fr) by TeKrop
- EXE packaging: [PS2EXE](https://github.com/MScholtes/PS2EXE) by Markus Scholtes
- Rank badge images: © Blizzard Entertainment, served from Blizzard's public CDN

Overwatch and Battle.net are trademarks of Blizzard Entertainment, Inc. This project is not affiliated with,
endorsed by, or associated with Blizzard Entertainment.

## License

Use as you wish — same terms as the original project.
