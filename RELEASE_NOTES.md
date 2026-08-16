# Battle.net Account Switcher — Dark Edition v1.2.0

First binary release. Fork of [BNetSwitcher by Nepero27182](https://github.com/Nepero27182/BNetSwitcher),
rewritten with a working Overwatch 2 rank lookup, account management, and an Overwatch-themed UI.

## ⚠️ Read this before downloading the EXE

**Windows Defender may flag this file.** It is a false positive, and here is exactly why:
the app is a PowerShell script packaged into an executable with
[PS2EXE](https://github.com/MScholtes/PS2EXE). That packaging technique is also used by malware, so
antivirus engines flag the *technique* regardless of what the script does. Every PS2EXE build hits this.

You have three options, in order of how much you should trust them:

1. **Build it yourself** (best). Ten seconds, and you can read every line first:
   ```powershell
   git clone https://github.com/TheRealLssm/BNetSwitcher.git
   cd BNetSwitcher
   .\build.ps1
   ```
2. **Skip the EXE entirely.** Right-click `bnet-switcher-gui.ps1` → *Run with PowerShell*.
   No binary involved at any point.
3. **Download the EXE below and verify the checksum** (see next section).

The whole source is one readable PowerShell file. Read it before you run it — that advice applies to
this download as much as to anyone else's.

## Verifying the download

SHA-256 of `bnet-switcher.exe`:

```
D45203FB6EC2E46F85A2FA9EBB2421A2126E5668E6F2330502C0EC58FA8CA84D
```

Check it before running:

```powershell
Get-FileHash .\bnet-switcher.exe -Algorithm SHA256
```

If the hash does not match exactly, do not run the file.

## What it does

**Account switching**
- One-click switching between saved Battle.net accounts; double-click a row or press Enter
- Closes Battle.net (and optionally Overwatch), then relaunches
- Can launch Overwatch 2 directly, skipping the launcher's Play button
- Backs up `Battle.net.config` before every write

**Overwatch 2 ranks**
- Tank / Damage / Support / Open Queue rank per account, with official Blizzard rank badges
- Player avatar, career title and endorsement level
- Fetched on background threads, so the window never freezes
- PC and console supported

**Account management**
- Remove accounts, purging the entry from `Battle.net.config` plus locally stored data,
  with a backup and a recovery log
- Mark accounts **OK / Watch / Suspended / Banned** with notes and an optional suspension countdown;
  flagged accounts require confirmation before switching
- Bulk BattleTag import/export, with validation against the API so mistyped tags are caught immediately

**Overwatch settings profiles**
- Save named snapshots of Overwatch's local settings and bind one per account, applied on switch
- Covers FPS cap, refresh rate, graphics preset, render scale, contrast, overlays, window mode, volumes
- Does **not** cover sensitivity, crosshairs or keybinds — Overwatch syncs those server-side per account,
  so they already follow each account on their own

**Interface**
- Overwatch-themed dark mode with a proper dark title bar; light and auto modes available
- Streamer mode masks account emails
- Resizable window, context menu, `F5` to refresh, `Del` to remove

## Requirements

- Windows 10 or later
- PowerShell 5.1 (ships with Windows)
- Battle.net installed, with each account logged into at least once
- Internet only for rank lookups — switching works fully offline

## Privacy

No passwords are ever read, stored or transmitted; Battle.net handles all authentication.
No telemetry. The only network calls are the public
[OverFast API](https://overfast-api.tekrop.fr) for ranks and Blizzard's CDN for badge images, and only
for accounts where you entered a BattleTag. Your account data stays in `%APPDATA%\BNetSwitcher`.

## Known limitations

- **BattleTags cannot be auto-detected.** Battle.net stores only login emails locally; nothing on disk
  maps an account to its BattleTag. Use the bulk import to enter them quickly.
- **Ranks require a public career profile.** Overwatch sets profiles to private by default
  (Options → Social → Career Profile Visibility).
- **Ban status cannot be detected.** Blizzard publishes no such data anywhere, so the status flags are
  set manually by you. Nothing is inferred.

## Credits

Original tool by [Nepero27182](https://github.com/Nepero27182/BNetSwitcher) ·
Rank data by [OverFast API](https://overfast-api.tekrop.fr) ·
Packaging by [PS2EXE](https://github.com/MScholtes/PS2EXE) ·
Rank and profile images © Blizzard Entertainment

Not affiliated with or endorsed by Blizzard Entertainment.
