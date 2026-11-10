# OrgFlow DevOps

An enterprise-grade DevOps platform bootstrap in a single repository:
**Jenkins as the sole orchestration entry point**, self-bootstrapping an
authentication stack (OpenLDAP + Dex + OAuth2 Proxy), a Caddy gateway with
domain-based routing, a Nexus artifact registry, LDAP-direct authentication for
every service, and backup/restore — all driven by parameterized Jenkins jobs
and Configuration-as-Code.

> 🇨🇳 中文完整文档:[README.zh-CN.md](README.zh-CN.md)

## What you get

| Component | Role |
|---|---|
| Jenkins | Pipeline CI/CD; LDAP security realm, group-based matrix authorization |
| OpenLDAP + Dex + OAuth2 Proxy | Identity, OIDC, group-authorized gateway (single protected route) |
| Caddy | TLS gateway, domain routing, internal CA, static docs site |
| Nexus | Artifact registry with Docker/PyPI repositories, LDAP auth |
| Router service | `routes.yaml` → Caddyfile render → hot reload + registration API |
| Backup / Restore | Parameterized jobs with sha256-verified archives and restore drills |
| Compliance | Secret/IP redaction gate for public releases |

## Quick start

```bash
cp .env.example .env          # fill domains/credentials
make deploy                   # bootstrap the full stack (DNS-masq first, then batches)
make jobs                     # push parameterized jobs to Jenkins
```

See [docs/使用说明.md](docs/使用说明.md) (Chinese) for the daily-usage guide and
[docs/services/](docs/services/) for per-service operations runbooks.

## Repository layout

```
services/    per-service build & config (jenkins, router, auth stack, dnsmasq)
config/      JCasC, routes.yaml, JJB job definitions
scripts/     deploy / backup / restore / LDAP bootstrap / compliance gate
tests/       image pinning + bats integration tests (DinD)
docs/        architecture, per-service runbooks, usage guide
```

## License

[Apache-2.0](LICENSE)
