# Security Policy

## Reporting a vulnerability

**Do NOT open a public issue for security vulnerabilities.**

Report privately to the repository owner via GitHub's
["Report a vulnerability"](https://github.com/zeek-zhao/orgflow-devops/security/advisories/new)
feature. You will receive a response within 7 days.

## Scope

- Jenkins / Nexus / LDAP / Dex / OAuth2-Proxy / Caddy configurations in this repo
- The deployment scripts and JCasC sources

## Deployment note

This platform is designed for private networks. The public repository contains
RFC 5737 documentation addresses only — real deployments must substitute their
own addresses and keep `.env` (credentials) out of version control.
