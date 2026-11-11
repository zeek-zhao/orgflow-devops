# Security Policy

## Reporting a vulnerability

**Do NOT open a public issue for security vulnerabilities.**

Report privately to the repository owner through GitHub's
[**Report a vulnerability**](https://github.com/zeek-zhao/orgflow-devops/security/advisories/new)
feature (repository → **Security** tab → *Report a vulnerability*).
You will receive a response within 7 days.

If the link above does not resolve (the repository may have been renamed or moved),
open the repository's **Security** tab and use *Report a vulnerability* there —
please do **not** describe the issue in a public ticket.

## Scope

- Jenkins / Nexus / LDAP / Dex / OAuth2-Proxy / Caddy configurations in this repo
- The deployment scripts and JCasC sources

## Deployment note

This platform is designed for private networks. The public repository contains
RFC 5737 documentation addresses only — real deployments must substitute their
own addresses and keep `.env` (credentials) out of version control.

## What this repository will never contain

`.env`, `secrets/`, `out/` and build artifacts are excluded by `.gitignore` and by
the export gate (`scripts/check-public-redaction.sh`) plus a full-history secret
scan in CI. If you find any of them in this repository, treat it as a security
report and use the private channel above.
