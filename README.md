# Windows Tools

Small, inspectable utilities for recurring Windows workflows.

The repository is organized as a collection rather than around a single application. Each utility should live in its own directory under `tools/` and include enough documentation to run it without repository-specific setup.

## Tools

| Tool | Purpose |
| --- | --- |
| `google-drive-zip-merger` | Merge the multiple ZIP archives produced by large Google Drive folder downloads into one destination tree. |

## Repository conventions

- Target Windows 11 unless a tool documents broader support.
- Prefer built-in Windows capabilities and PowerShell over additional dependencies when practical.
- Keep launchers simple enough for non-technical use where appropriate.
- Put reusable logic in PowerShell rather than batch files; use `.bat` files primarily as convenient Windows entry points.
- Avoid destructive behavior by default. Cleanup operations should be explicit or confirmed after successful work.
- Keep each utility self-contained under `tools/<tool-name>/`.

See each tool's README for usage details.
