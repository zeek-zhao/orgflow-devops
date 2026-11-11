# OrgFlow DevOps

An enterprise-grade DevOps platform bootstrap in a single repository: **Jenkins as the
sole orchestration entry point**, self-bootstrapping an authentication stack
(OpenLDAP + Dex + OAuth2 Proxy), a Caddy gateway with domain-based routing, LDAP-direct
authentication for every service, a Nexus artifact registry, and backup/restore — all
driven by parameterized Jenkins jobs and Configuration-as-Code.

> 中文完整文档：[README.zh-CN.md](README.zh-CN.md)

## What you get

| Component | Role |
|---|---|
| Jenkins | Pipeline CI/CD; LDAP security realm, group-based matrix authorization |
| OpenLDAP + Dex + OAuth2 Proxy | Identity, OIDC, group-authorized gateway |
| Caddy | TLS gateway, domain routing, internal CA, static docs site |
| Nexus | Artifact registry with Docker/PyPI repositories, LDAP auth |
| Router service | `routes.yaml` → Caddyfile render → hot reload + registration API |
| dnsmasq | In-network DNS: `*.<domain>` → Caddy |
| Homepage | Single landing page for every service |
| Backup / Restore | Parameterized jobs, sha256-verified archives, restore drills |

Everything is driven by configuration files in `config/`; nothing is configured by
clicking through a web UI.

## Quick start

```bash
make hooks                    # install git hooks (commit identity + main-branch guard)
cp .env.example .env          # fill in domain/ports/accounts
make deploy                   # bootstrap the stack (pulls images from GHCR)
make hosts                    # generate an /etc/hosts snippet for the gateway domains
make ca                       # install the internal CA root (self-signed TLS)
make jobs                     # push parameterized jobs to Jenkins
```

**Images come from exactly one place: GitHub Actions builds them, GHCR stores them,
and the host only pulls.** All packages are public — no `docker login`, no credentials.
Before deploying, `make deploy` runs `scripts/check-image-source.sh`, which refuses to
deploy when the image contexts (Dockerfile / JCasC / router renderer) have changed since
the pinned build. Without that gate you get a deployment that pulls successfully, passes
every health check, and runs the previous version of your code.

To iterate on an image locally without waiting for CI:

```bash
make build-local              # explicit local build; never pushed to GHCR
USE_GHCR=0 make deploy        # deploy those locally built images
```

This is not an equivalent option — it exists so you can test a Dockerfile change before
committing it. Shared environments deploy from GHCR.

## Repository layout

```
services/        per-service build & config (jenkins, router, auth stack, dnsmasq)
config/          JCasC, routes.yaml, JJB job definitions
scripts/         deploy / doctor / backup / restore / gates / generators
shared-library/  deployService / backupService pipeline steps
tests/           image pinning + bats integration suite (DinD harness)
tools/           jenkins CLI, Windows acceptance scripts, JJB
docs/            architecture, ADRs, per-service runbooks, usage guide
```

## Tests

```bash
make test         # static + behavioral checks (routing, jobs, docs registry, gates)
make test-bats    # full stack in Docker-in-Docker: 10 services + nexus deployment
make docs-check   # documentation registry gate (IEEE 828 lightweight)
make doctor       # read-only environment diagnostics
```

`make test-bats` always builds from source: it verifies that *this commit* comes up, so
it never uses pre-built GHCR images (that would be testing an older commit).

## Documentation

Start at [docs/文档地图.md](docs/文档地图.md) (reading paths by role, in Chinese), or go
straight to:

| Question | Where |
|---|---|
| What is this thing and how does it run | [M0 最小核心](docs/M0-最小核心.md) |
| How do I use it day to day | [使用说明](docs/使用说明.md) |
| How is it verified | [M0 测试体系](docs/M0-测试体系.md) |
| Images and CI pipeline | [M0 镜像与 CI](docs/M0-镜像与CI.md) |
| One service is broken | [docs/services/](docs/services/) (11 runbooks) |
| Network topology and fixed IPs | [network/arch](docs/network/arch.md) |
| Why domain-based routing | [ADR-13](docs/ADR-13-域名路由.md) |
| Backup and restore drills | [备份与恢复](docs/备份与恢复.md) |
| What we redistribute and under which terms | [开源合规](docs/开源合规.md) + [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md) |
| Which docs exist, and how they're governed | [文档地图](docs/文档地图.md) · [文档登记册](docs/文档登记册.md) · [文档规范](docs/文档规范.md) |
| Known gaps and open findings | [问题索引](docs/问题索引.md) |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues must **not** be filed as public
issues — see [SECURITY.md](SECURITY.md).

## License

[Apache-2.0](LICENSE). Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); full license texts are under
[licenses/](licenses/).
