# Contributing

Nanobook is a single-developer research project. Issues and PRs are welcome,
but expect slow review — this is not a staffed open-source project.

## Before opening a PR

1. Read [`CLAUDE.md`](CLAUDE.md) for the canonical workflow rules. The same
   rules apply to humans: conventional commits, no direct pushes to `main`,
   squash before pushing to a PR branch, no AI-tool footers in commits or PR
   descriptions.
2. Activate the repo's git hooks:

   ```bash
   git config core.hooksPath .githooks
   ```

   Hooks enforce: no direct push to `main`, markdownlint on staged `.md`
   files, and conventional commit format on every commit message.
3. Run lint locally before pushing:

   ```bash
   make lint                       # Verilator lint, must be zero warnings
   markdownlint-cli2 "**/*.md"     # if you touched any .md
   ```

4. If you touched a module with a unit testbench under `dv/unit/<module>/`,
   run it. CI will run them too, but a fast local fail is cheaper.

## Commit format

Conventional commits, enforced by the `commit-msg` hook:

```text
<type>[(scope)]: <description>
```

Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `perf`,
`revert`. Example: `feat(itch_decoder): widen field_extract to 6 lanes`.

## Scope of accepted changes

Likely accepted:

- Bug fixes in RTL, testbenches, or build scripts with a reproducer.
- Documentation fixes (typos, broken links, stale paths).
- Lint/tooling improvements that keep CI green.

Likely declined or deferred:

- Adding new architectural features outside the published roadmap
  (`docs/design.md`). The roadmap is sequenced for a reason — out-of-order
  work creates merge risk.
- Refactors that don't have a concrete bug or perf win attached.
- New third-party dependencies. The pinned submodule list in `third_party/`
  is intentionally short.

## Reporting issues

Open a GitHub issue with the affected commit SHA, a minimal reproducer, and
the relevant log/waveform output. For security issues see [`SECURITY.md`](SECURITY.md).
