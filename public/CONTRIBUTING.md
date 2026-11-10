# Contributing to OrgFlow DevOps

Thanks for your interest! This project accepts pull requests.

## Ground rules

- All changes go through pull requests (no direct pushes to `main`).
- Keep the **compliance gate green**: `bash scripts/check-public-redaction.sh .`
  must exit 0 — no internal hostnames, no real user names, no credentials in
  any committed file.
- Configuration-as-code only: edit `config/` sources, never rendered artifacts.

## Pull request checklist

1. `make test` passes locally (static checks, ~10s).
2. Integration tests (`make test-bats`) pass when touching runtime behavior.
3. Describe what / why / how-tested in the PR body.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
