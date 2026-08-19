# AGENTS.md

## Repository purpose

This repository contains small, practical Windows utilities intended to remove repetitive manual workflows. Prefer tools that are easy to inspect, easy to run, and minimally dependent on third-party software.

## Platform

- Primary target: Windows 11.
- Windows PowerShell 5.1 compatibility is preferred unless a utility explicitly requires PowerShell 7+.
- Prefer functionality built into Windows and .NET when it is adequate for the task.

## Structure

Each utility belongs under:

```text
tools/<tool-name>/
```

A utility directory should normally contain:

- the implementation (`.ps1` for PowerShell tools);
- a simple launcher (`.bat`) when drag-and-drop or double-click operation is useful;
- a `README.md` explaining purpose, usage, behavior, and important safety characteristics.

Avoid coupling independent utilities to each other unless there is a clear reusable library boundary.

## Design principles

1. Optimize for a short path from recurring annoyance to reliable automation.
2. Keep behavior visible and understandable; do not hide destructive operations.
3. Preserve user data by default. Deletion, replacement, and cleanup should be explicit, confirmed, or otherwise strongly justified.
4. Prefer idempotent or safely repeatable behavior where practical.
5. Quote Windows paths correctly and expect spaces in filenames and directory names.
6. Use nonzero exit codes for failures so launchers and future automation can detect them.
7. Validate inputs before changing files.
8. When processing archives or externally supplied paths, defend against path traversal.
9. Avoid administrator privileges unless the utility genuinely requires them.
10. Keep launchers thin; substantive logic belongs in the implementation script.

## Changes and validation

For changes to a utility:

- exercise its successful path;
- exercise at least one expected failure path;
- check behavior with paths containing spaces;
- verify that failure does not trigger cleanup intended only after success;
- update the utility README when user-visible behavior changes.

When automated tests are warranted, keep them close to the utility and document any additional test dependency. Do not introduce a large framework solely for a trivial script.

## Git workflow

Use focused branches and pull requests for substantive changes. Keep unrelated utilities out of the same change unless the change is intentionally repository-wide.
