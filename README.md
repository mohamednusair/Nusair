# Nusair

## tools/pc-performance

A self-contained toolkit for diagnosing and fixing a slow Windows 11 laptop —
slow boot, freezing, slow app launches and overheating.

- **[tools/pc-performance](tools/pc-performance/)** — start with the
  [README there](tools/pc-performance/README.md).

Quick version: copy that folder to the slow PC, then right-click
`MAKE-IT-FAST.bat` and choose **Run as administrator**. It diagnoses and
applies every fix in one pass. `Run-Diagnose.bat` and `Run-Optimize.bat` are
there if you would rather do it step by step and approve each change.

The diagnosis is read-only. The optimiser previews every change before
applying it, creates a System Restore point first, and can undo its own
startup changes.
