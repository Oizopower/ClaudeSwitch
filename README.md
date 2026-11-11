# ClaudeSwitch

A tiny Windows launcher that starts [Claude Desktop](https://claude.ai/download) with the
account of your choice. Claude Desktop only signs in one account at a time; ClaudeSwitch
gives each account its own profile directory so you can run work and personal side by side.

![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D4)
![.NET Framework](https://img.shields.io/badge/.NET%20Framework-4.x-512BD4)
![License](https://img.shields.io/badge/license-GPLv3-blue)

## What it does

On launch a small window appears with one button per profile. Pick one and Claude opens
with that account.

- The **top profile** (orange button, marked `★` at the bottom of the window) uses your
  existing Claude Desktop login. It is started through the app's own MSIX identity, exactly
  as if you clicked the normal Claude icon.
- **Every other profile** gets its own directory, passed to Claude as `--user-data-dir`.
  You sign in there once with the other account and it is remembered from then on.

Profiles can run at the same time — each gets its own window, because Electron's
single-instance lock is per profile directory.

## Installing

1. Download `ClaudeSwitch.exe` from the
   [latest release](https://github.com/Oizopower/ClaudeSwitch/releases/latest) and put it in
   a folder of your choice — or clone the repository and build it yourself (see below).
   The binary is unsigned, so SmartScreen may ask you to confirm on first run.
2. Open it once and click **settings → Add to Start menu** to put ClaudeSwitch in the
   Start menu.
3. Optionally pin it and unpin the original Claude tile, so ClaudeSwitch becomes the way
   you start Claude.

> **Note on pinning:** Windows blocks applications from pinning themselves to Start
> (`E_ACCESSDENIED`). ClaudeSwitch creates the Start menu entry automatically and then opens
> the apps folder so you can right-click it and choose *Pin to Start* — one click, once.

## Using it

Double-click **ClaudeSwitch** and pick a profile. `Esc` closes the window.

The window sizes itself to your profiles: up to three buttons sit side by side, and from
the fourth one they continue on the next row. Prefer a wider or narrower layout? Drag the
left or right edge of the window. The width snaps to whole buttons, the height follows the
number of rows, and the choice is remembered for next time.

You can also skip the window entirely and pass a profile name — handy for extra shortcuts.
Matching ignores case and accents, so `prive` finds a profile named `Privé`:

```
ClaudeSwitch.exe Work
ClaudeSwitch.exe personal
```

On first run two profiles are created for you, **Work** (the default) and **Personal**;
rename them to whatever you like.

## Managing profiles

Click **settings** at the bottom right of the window. The profile list has these actions:

| Button | What it does |
|---|---|
| **New…** | Opens a dialog for name and folder. Leave the folder empty to get one under `profiles\` automatically, or browse to any folder you like. |
| **Edit…** | Same dialog for the selected profile (double-clicking a row works too). For the default profile only the name can be changed. |
| **Delete** | Removes a non-default profile from the list. The folder itself stays on disk. |
| **Make default** | Makes the selected profile use your existing Claude login. The previous default gets its own folder instead, and signs in once. |
| **Add to Start menu** | Creates the Start menu entry and attempts to pin it. |

Names must be unique and folders must be absolute paths; the app tells you when they are
not, instead of saving something broken. Environment variables are supported and stored
unexpanded, so `%USERPROFILE%\.claude-personal` keeps working on another machine.

**Make default** is what you use on a second machine. If your personal account is the one
signed into Claude Desktop at home, select that profile there and click it — no config file
editing, no reinstall.

## How it works

Claude Desktop ships as an MSIX package, so its executable lives in a versioned path such as
`C:\Program Files\WindowsApps\Claude_1.30096.1.0_x64__pzs8sxrjxfjjc\app\claude.exe`. That
path changes with **every** Claude update, so ClaudeSwitch never stores it. On each launch it
resolves the newest installed package from the AppModel repository in the registry
(`HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages`,
value `PackageRootFolder`). This works without needing read access to the protected
`WindowsApps` directory, and Claude updates never break the launcher.

Profiles are stored in the registry under `HKCU\Software\ClaudeSwitch\Profiles`, one subkey
per profile with `Name` and `Path` values. The subkey at index `0` is the default profile and
always has an empty path. The tree is rewritten on save, so indices stay contiguous. The
number of button columns you chose by resizing the window is kept next to it, as the
`Columns` value under `HKCU\Software\ClaudeSwitch`.

## Building

Requires nothing but Windows — it compiles with the `csc.exe` that ships with .NET
Framework 4.x, no SDK or Visual Studio needed:

```powershell
.\build.ps1
```

This produces `ClaudeSwitch.exe` next to the source, with the icon embedded. The code
targets C# 5 syntax because that is what the bundled compiler accepts.

## Repository layout

| Path | Purpose |
|---|---|
| `ClaudeSwitch.cs` | The entire application — window, settings, launch logic |
| `build.ps1` | One-line build script |
| `claudeswitch.ico` | Application icon |

`profiles/` holds live account data and is deliberately excluded from version control.

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

