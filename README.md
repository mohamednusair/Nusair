# Nusair

## tools/pc-performance

A self-contained toolkit for diagnosing and fixing a slow Windows 11 laptop —
slow boot, freezing, slow app launches and overheating.

- **[tools/pc-performance](tools/pc-performance/)** — start with the
  [README there](tools/pc-performance/README.md).

Quick version: copy that folder to the slow PC, right-click
`Run-Diagnose.bat` and choose **Run as administrator** to find out what is
actually wrong, then `Run-Optimize.bat` to fix what is safely fixable.

The diagnosis is read-only. The optimiser previews every change before
applying it, creates a System Restore point first, and can undo its own
startup changes.
