# Windows 11 Performance Toolkit

Diagnose and fix a slow Windows 11 laptop: slow boot, freezing, slow app
launches, and overheating.

## Quick start - just make it fast

1. Copy the whole `pc-performance` folder onto the slow laptop (USB stick,
   OneDrive, or download the repo as a ZIP).
2. Right-click **`MAKE-IT-FAST.bat`** -> **Run as administrator**.
3. Leave it running for 20-40 minutes. Keep the laptop plugged in.
4. Let it restart the laptop when it asks.

That runs the diagnosis and applies every fix, including the overheating fix,
without asking any questions. It still creates a System Restore point first,
and it still backs up anything it disables.

### Or do it step by step

1. Right-click **`Run-Diagnose.bat`** -> **Run as administrator**.
   It changes nothing. It prints a prioritised list of what is actually wrong
   and saves a report to your Desktop as `pc-performance-report.txt`.
2. Right-click **`Run-Optimize.bat`** -> **Run as administrator**.
   It shows a preview first and asks before changing anything.
3. **Restart the laptop.**

If something goes wrong, run **`Undo-Startup-Changes.bat`**, or use
System Restore and pick the point named
*"Before PC performance optimisation"*.

---

## Read this first

Some causes of a slow laptop are physical, and no script can repair them.
The diagnosis will tell you if you have one of these:

| Cause | Why it is slow | Real fix |
|---|---|---|
| **Mechanical hard disk (HDD)** | Windows 11 on an HDD is painful no matter how clean it is. Boot takes minutes; any background task freezes the machine. | Replace with an SSD. Usually under $50 and gives a 5-10x improvement. **This is the single biggest win.** |
| **Less than 8 GB RAM** | Windows swaps to disk constantly; that is what the freezing *is*. | Add RAM. 16 GB if the laptop allows it. |
| **Clogged fan / dried thermal paste** | The CPU overheats and deliberately halves its own speed to survive. Loud fans are the tell. | Blow out the vents with compressed air. If it is 3+ years old, have the thermal paste replaced. |
| **Failing drive** | Random total freezes lasting seconds to minutes, disk errors in the event log. | **Back up immediately**, then replace the drive. |

You reported slow boot, freezing, slow app launches *and* loud fans together.
That combination most often means **HDD and/or low RAM, plus a cooling
problem**. Run the diagnosis and it will tell you which of these you actually
have, with numbers.

---

## What each file does

| File | Purpose |
|---|---|
| `CLEAN-TEMP-FILES.bat` | Temp and cache cleanup only. Takes ~2 minutes. |
| `MAKE-IT-FAST.bat` | **Start here.** Diagnoses and applies every fix in one go, no questions. |
| `Run-Diagnose.bat` | Double-click launcher for the diagnosis (self-elevates). |
| `Run-Optimize.bat` | Double-click launcher for the fixes (self-elevates, previews first). |
| `Undo-Startup-Changes.bat` | Re-enables anything the optimiser disabled at startup. |
| `Diagnose-PC.ps1` | The read-only analysis. |
| `Optimize-PC.ps1` | The repairs. Preview by default; `-Apply` to commit. |

### What the diagnosis measures

- Disk type (**HDD vs SSD**), free space, SMART health, wear level, errors
- RAM installed, memory pressure now, top memory and CPU consumers
- Whether the disk is pinned at 100% busy while idle
- Every startup program and logon scheduled task, enabled or disabled
- **Actual boot times** from Windows' own boot-performance log, plus the
  components Windows itself blames for slowing boot
- CPU current clock vs rated clock (**detects thermal throttling**) and
  temperature sensors where exposed
- Power plan, page file configuration
- Multiple antivirus products installed at once
- Disconnected mapped network drives (a classic cause of Explorer freezing)
- Devices with driver errors
- Disk/filesystem errors, unexpected shutdowns, and app hangs from the
  event log

### What the optimiser changes

Everything below is safe and reversible.

1. **Reclaims disk space** — user and Windows temp folders, crash dumps,
   error reports, old servicing logs, the Windows Update download cache,
   Delivery Optimization cache, Recycle Bin, and superseded update files in
   the component store.
2. **Trims the startup list** — disables *known* non-essential auto-starters
   (Spotify, Steam, Adobe/Java/Google updaters, Discord, Dropbox and similar).
   It only ever disables autostart; it never uninstalls anything. Anything it
   does not recognise is **left alone and listed for you to review**. Hardware
   and security entries (Defender, audio, touchpad, graphics, vendor tools)
   are explicitly protected.
3. **Power settings** — switches off Power Saver, stops the disk sleeping on
   AC power. With `-ThermalFix`, caps the CPU at 99% max state, which disables
   turbo boost. On an overheating laptop this cuts heat and fan noise sharply
   and often *increases* sustained speed, because the CPU stops throttling.
4. **UI overhead** — sets visual effects to best-performance, disables menu
   animation delay, turns off Windows suggestions/tips/ads.
5. **Windows 11 background bloat** — removes the artificial logon startup
   delay, enables Fast Startup (a large boot-time win on a slow disk),
   disables the Widgets board (it runs a hidden background browser process),
   turns off Xbox Game Bar background recording, stops Store apps running in
   the background, disables the telemetry service, and switches on Storage
   Sense so the drive does not fill up again.
6. **Storage maintenance** — TRIM on SSDs, defragment on HDDs, disables
   SysMain **only on SSD** (it genuinely helps on an HDD, so it is kept there),
   restores a system-managed page file if it was misconfigured.
7. **Repairs system corruption** — `DISM /RestoreHealth`, `sfc /scannow`, and
   a read-only `chkdsk /scan`. This stage takes 10-30 minutes. Skip it with
   `-SkipRepair`.

---

## Just cleaning temp files

If you only want disk space back and not the full tune-up, right-click
**`CLEAN-TEMP-FILES.bat`** -> **Run as administrator**. It takes about two
minutes and clears:

- user and Windows temp folders, prefetch data
- crash dumps, error reports, kernel crash reports, servicing logs
- Internet and graphics shader caches
- the Windows Update download cache and Delivery Optimization cache
- the Recycle Bin

It deletes no documents, photos or settings - only caches and leftovers that
Windows recreates on its own. Files that are open at the time are skipped and
reported, which is normal; restart and run it again to catch those.

```powershell
.\Clean-TempFiles.ps1 -Preview              # show sizes, delete nothing
.\Clean-TempFiles.ps1                        # clean
.\Clean-TempFiles.ps1 -IncludeBrowserCache   # also clear Edge/Chrome cache
```

For the largest wins beyond this - old Windows installations left by an
upgrade, which can exceed 20 GB - press <kbd>Win</kbd>+<kbd>R</kbd>, run
`cleanmgr`, and choose **Clean up system files**.

## Command line use

```powershell
# Preview everything, change nothing (the default)
.\Optimize-PC.ps1

# Apply the safe fixes
.\Optimize-PC.ps1 -Apply

# Apply, and also fix overheating by disabling turbo boost
.\Optimize-PC.ps1 -Apply -ThermalFix

# Apply but skip the slow sfc/DISM repair stage
.\Optimize-PC.ps1 -Apply -SkipRepair

# Undo the startup changes
.\Optimize-PC.ps1 -RestoreStartup
```

### Undoing things

| Change | How to undo |
|---|---|
| Startup items | `.\Optimize-PC.ps1 -RestoreStartup`, or Task Manager > Startup apps |
| CPU turbo cap | `powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100` then `powercfg /setactive SCHEME_CURRENT` |
| SysMain disabled | `Set-Service SysMain -StartupType Automatic` |
| Telemetry disabled | `Set-Service DiagTrack -StartupType Automatic` |
| Widgets disabled | Delete `AllowNewsAndInterests` under `HKLM:\SOFTWARE\Policies\Microsoft\Dsh` |
| Everything | System Restore > *"Before PC performance optimisation"* |

Logs and the startup backup are written to
`%LOCALAPPDATA%\PCOptimize\`.

---

## If it is still slow afterwards

Catch it in the act. When the laptop hangs, open Task Manager
(<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Esc</kbd>), go to **Processes**, and
look at which column is at 100%:

- **Disk at 100%** — a failing drive, an HDD, Windows Update, search indexing,
  OneDrive sync, or an antivirus scan.
- **Memory at 90%+** — not enough RAM. Close browser tabs; add RAM.
- **CPU at 100% with loud fans** — thermal throttling, or one runaway process.
  Note its name.
- **Everything low but still frozen** — almost always a failing drive or a
  dead network drive.

Send that information along and the cause can be narrowed down precisely.

## Requirements

Windows 11 (also works on Windows 10), Administrator rights, built-in
PowerShell 5.1. No installation and no third-party software.
