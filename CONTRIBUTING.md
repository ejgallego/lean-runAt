# Contributing

This repository is public but still alpha. Favor conservative, well-tested changes over feature
sprawl.

## Workflow

- prefer short branches and small PRs
- start with an issue or RFC-sized discussion before larger changes
- run the smallest relevant local suite before opening a PR
- keep user-facing docs aligned with behavior when the workflow surface changes
- do not treat the broker as a replacement for Lake; when behavior gets too build-system-specific,
  say so explicitly in the PR

For local AI-first workflow guidance, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
For agent-specific runtime instructions, see [AGENTS.md](AGENTS.md).

## Commits

Follow Lean upstream's commit-message shape:

```text
<type>: <subject>

<body>
```

Supported `<type>` values:

- `feat`
- `fix`
- `doc`
- `style`
- `refactor`
- `test`
- `chore`
- `perf`

Guidelines:

- use imperative, present tense
- do not capitalize the first letter in the subject
- do not end the subject with a period
- keep the first line concise and behavior-oriented
- mention the user-visible behavior or subsystem being changed
- use the body to explain motivation and contrast with previous behavior when that context matters
- avoid mixing unrelated changes into one commit when the diff can be split cleanly

Examples:

- `fix: improve refresh and stale dependency recovery`
- `refactor: move broker workspace deps scanner into its own module`
- `doc: split human-facing README from contributor workflow guidance`

This repository does not yet enforce Lean's `changelog-*` label process, so adopt the message
format now and add changelog policy later if the release process needs it.

## Pull Requests

PRs should make review cheap. Include:

- `Summary`: what changed and why
- `Testing`: exact commands you ran
- `Risks` or `Open Questions`: only when they matter

Use the same commit convention for the PR title and description. Pull requests are expected to be
squash merged, so the final commit message should come from the PR title and body.

If the change affects the wrapper, install flow, bundle resolution, or broker protocol, say that
explicitly.

## Author Identity

Use the repository's Lean work identity for authored commits unless there is a deliberate reason not
to:

- `Emilio Jesus Gallego Arias <emilio@lean-fro.org>`

Keep author and committer identity consistent for normal local commits.

## Test Guidance

Use the smallest relevant suite first:

- `bash tests/test.sh`: core Lean test path
- `bash tests/test-broker-fast.sh`: broker-stream and barrier changes
- `bash tests/test-broker-slow.sh`: wrapper, install, and bundle-resolution changes
- `bash tests/test-broker.sh`: aggregate broker suite
- `bash scripts/lint-shell.sh`: shell wrappers, installer, and shell tests

More detail lives in [docs/TESTING.md](docs/TESTING.md).
