# Battle.net Account Switcher — Dark Edition

A fast, dark-themed GUI for switching between Battle.net accounts on Windows, with live Overwatch 2 rank display.

> **Fork notice** — this is a fork of [**BNetSwitcher** by Nepero27182](https://github.com/Nepero27182/BNetSwitcher).
> All credit for the original tool and the core switching approach goes to them. This fork rewrites the GUI,
> fixes the rank lookup, and adds account management. The original is licensed "use as you wish".

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

### Interface
- Dark mode by default, including a proper dark title bar. Light and Auto (follow Windows) also available.
- Resizable window that remembers its size.
- Active account marked with a coloured ●.
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
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO
.\build.ps1
```

`build.ps1` installs the `ps2exe` module if needed and produces `bnet-switcher.exe` next to the script.

If module installation fails, run this once and retry:

```powershell
Install-Module ps2exe -Scope CurrentUser -Force
```

### No build required

You can skip the EXE entirely and run the script directly — right-click `bnet-switcher-gui.ps1` →
**Run with PowerShell**, or make a shortcut to:

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
| `%APPDATA%\BNetSwitcher\removed-accounts.json` | Recovery log of removed accounts |

Nothing is written inside the repo folder, so your account data can never end up in a commit.

---

## Privacy & safety

- **No passwords, ever.** The app never reads, stores, or transmits credentials. Battle.net handles all authentication.
- **No telemetry.** No analytics, no tracking, no phone-home.
- **Two network calls only**, and only for accounts where *you* entered a BattleTag:
  1. `overfast-api.tekrop.fr` — public rank lookup
  2. `static.playoverwatch.com` — Blizzard's CDN, for rank badge images
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

**Ranks show "Rate limited"** — the public API has rate limits. Wait a minute and press `F5`.

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
