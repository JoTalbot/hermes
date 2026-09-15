# Incident: a directory permission broke every Hermes command

- **DATE** 2026-09-15, twice: install time (~12:00) and self-inflicted (~13:50)
- **IMPACT** `PermissionError: [Errno 13] Permission denied: '/etc/hermes/.env'` on
  **every** `hermes` invocation — kanban included. The agent OS was unusable.

## FACT
- Hermes' managed-scope loader calls `(managed_dir / ".env").exists()` outside any
  try/except. With the directory at 0750 (installer default) or 0700 (a stray
  `install -d -m 0700`), the stat raises instead of returning False, and the failure
  surfaces as a traceback from deep inside `load_hermes_dotenv`.

## LESSON
An invariant that is only a convention will be violated by the next command that
looks reasonable. `/etc/hermes` must be 0755 — the secrets inside stay 0600, and
directory traversal permissions are not what protects them.

## FIX
`ensure-shim-env.sh` now checks the mode and repairs it, and `hermes-env-guard.service`
runs that on every boot. Verified by setting the directory to 0700 and watching the
guard log `FIXED /etc/hermes mode was 700, must be 755`.

## FOLLOW-UP
`hermes_managed_dir_ok` is exported as a metric so the invariant is visible between
humans, not just enforced at boot.
