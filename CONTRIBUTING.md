# Contributing to OrgFlow DevOps

This repository is **public for reading and forking**, not as an open contribution
target. Please read the first section before sending anything.

## What we accept

| We accept | We do not accept |
|---|---|
| Bug reports (public issue) | Pull requests from external authors |
| Security reports (private channel, see [SECURITY.md](SECURITY.md)) | Patches pasted into issues |
| Questions and documentation corrections (issue) | Changes to CI, gates, or licence files |

**Why no external PRs:** every commit on `main` must have `author = zeek.zhao
<zeek.zhao@foxmail.com>` and no co-author/AI trailers — that is a hard rule enforced by
git hooks, by the `Identity` workflow, and by `make identity-check`. A repository cannot
at the same time require a single author on its default branch and merge commits written
by other people. Rather than loosen the rule silently, we state it: fork freely, report
issues, but code changes stay with the maintainer.

If you send a PR anyway, CI will fail on identity — that is expected behaviour, not a
bug in your patch.

## Reporting a bug

Open an issue with: what you ran, what you expected, what happened, and the output.
If the report involves credentials, a real host address, or anything you would not want
public, use the private channel in [SECURITY.md](SECURITY.md) instead.

## For the maintainer: working on this repo

### First clone

```bash
git config core.hooksPath .githooks     # or: make hooks
git config user.name  "zeek.zhao"
git config user.email "zeek.zhao@foxmail.com"
```

`core.hooksPath` is local configuration — it does not travel with a clone, and there is
no way to make it do so. A clone without hooks will happily commit with the wrong
identity, and you will only find out from CI.

### Commit rules

- `author` **and** `committer` must be `zeek.zhao <zeek.zhao@foxmail.com>`.
- No `Co-authored-by:` / `Signed-off-by:` / `Assisted-by:` trailers — the commit history
  is audit evidence, and two authors per commit destroys "who is responsible".
  This is the rule for the **maintainer's own commits**. It is not the same question as
  DCO for outside contributors, which does not currently apply because no outside
  contribution path exists — see [Why there is no DCO check](#why-there-is-no-dco-check-yet).
- No AI attribution (`Generated with …`, `Co-authored-by: Copilot`, 🤖). Write what
  changed and why, not who typed it.
- Message body explains *why*. The diff already says *what*.

### Branch and merge

```bash
git switch -c feat/<issue#>-<slug>
git commit -m "feat(area): 一句话说清改了什么"
git push -u origin HEAD
# open a PR, wait for both checks, then merge with **Rebase**
```

- Never push directly to `main` (the `pre-push` hook blocks it).
- Merge with **Rebase**, never Squash: a squash commit is authored by the GitHub
  account's noreply address and committed by GitHub, which turns every subsequent
  push-to-main identity check red. This is not a style preference — it broke the gate
  once already.

### Before opening a PR

```bash
make check                     # fast gates: docs registry / links / redaction / labels (seconds)
make check-all                 # the above + make test + lint + bats (SKIP_BATS=1 to skip bats)
make test-bats                 # full stack in DinD (when touching runtime behavior)
```

`make hooks` installs the same two layers locally: `pre-commit` runs the fast gates,
`pre-push` runs the heavy ones. They are deliberately split — a slow pre-commit hook
gets `--no-verify`'d, and a bypassed hook is worse than no hook.

### Changing an image

Images are built only by CI and pulled from GHCR. After changing anything under
`services/`, `tools/jjb`, `tools/jenkins`, `tools/jenkins-agent`, or `tests/harness`:

1. Merge the change and let the **Images** workflow finish.
2. `git pull` then `make images-pin` — this rewrites the digests in
   `docker-compose.ghcr.yml` and moves the `# pinned-at:` marker to the commit that
   produced them.
3. Commit the pin update.

`make deploy` refuses to run while the image contexts have moved past `pinned-at`.
Use `make build-local` + `USE_GHCR=0 make deploy` to test a Dockerfile change before
committing — those images are never pushed.

### Documentation

`docs/` is governed by a registry: every document has a DOC-ID, an owner, a status and a
review interval. `make docs-check` enforces bidirectional consistency between the
registry and the files on disk. Read [docs/文档规范.md](docs/engineering/文档规范.md) before adding
or removing a document, and start from [docs/文档地图.md](docs/文档地图.md) when reading.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Why there is no DCO check (yet)

A DCO (Developer Certificate of Origin) asks every commit to carry a
`Signed-off-by:` line, by which the contributor states they have the right to submit
that code. It exists to answer one question: *"when a stranger's patch enters this
history, what did they licence it under, and who vouched for it?"*

This repository has no stranger's patch entering its history, by design — see
[What we accept](#what-we-accept). Every commit on `main` must carry one fixed author,
so there is no path by which an outside `Signed-off-by` could arrive. A DCO gate added
today could never fail: it would be a green badge with nothing behind it, and this
repository treats a check that cannot fail as worse than no check — it converts
"nobody looked" into "the machine says it's fine".

So the position is recorded rather than instrumented:

- **Now**: inbound licence is stated (see [License](#license)); no DCO gate, because
  the object it inspects does not exist.
- **If external PRs are ever accepted**: DCO becomes mandatory *in the same change*
  that relaxes the single-author rule. Taking one without the other produces either a
  forgeable history (DCO without the identity rule) or an unlicensed contribution
  (identity rule relaxed without DCO).

## License

Inbound = outbound. Anything you send to this repository — code, documentation, a patch
pasted into an issue, a suggested diff in an email — is licensed under
[Apache-2.0](LICENSE), the same licence the repository ships under. You keep your
copyright; you grant the project the right to distribute the contribution under that
licence, and you confirm you have the right to grant it.

This is stated explicitly rather than left implicit: a reviewer looking at this
repository should be able to answer "what licence applies to a contribution?" from the
repository alone, without inferring it from the project's outbound licence.

