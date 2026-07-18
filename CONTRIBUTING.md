# Contributing to Thyme

Thank you for improving Thyme. This public repository welcomes focused fixes,
benchmark improvements, and documentation updates that support its purpose as
an OpenTelemetry Collector benchmarking distribution.

## Before starting

Check the current issues and pull requests before beginning work. For a large
change, open an issue first so the design, benchmark method, and operational
cost can be agreed before implementation.

Fork the repository, create a branch from the current `main`, and keep each
pull request to one logical change. Do not include unrelated refactors,
dependency upgrades, generated files, or broad formatting changes.

Never include secrets, credentials, customer data, production exports, or
sensitive benchmark-environment data. Report a suspected vulnerability
privately through GitHub's security reporting features rather than a public
issue.

## Commit and pull request conventions

Use Conventional Commits:

```text
<type>(<optional scope>): <short imperative description>
```

Common types include `feat`, `fix`, `docs`, `test`, `build`, `ci`, `refactor`,
and `chore`. Examples for this repository include:

```text
fix(config): preserve large OTLP batches
docs(benchmark): clarify k3d cleanup
build(distribution): update collector components
```

Use `!` and a `BREAKING CHANGE:` footer when a change is intentionally
breaking. Pull requests are squash-merged, so the pull request title must also
follow Conventional Commits.

The pull request description must include:

- a summary and motivation;
- the linked issue, when applicable;
- exact validation commands and results;
- risk and rollout notes, or `None`;
- matching documentation, configuration, and generated-output updates.

You are responsible for reviewing and validating agent-generated work before
submitting it.

## Validation

Read [AGENTS.md](AGENTS.md) for the repository architecture, safety rules, and
full path-based validation matrix. At minimum, run:

```bash
git diff --check
make build
KUBE_NODE_NAME=validation-node make validate
```

Run the additional checks for every changed path. Do not commit generated
`distributions/thyme/build/` or downloaded `distributions/thyme/bin/` content.

Benchmark and deployment commands are not routine validation. The local script
creates and can delete a k3d cluster; the AWS script creates billable resources
and may destroy them. Obtain explicit authorization before running either one,
state the target environment and expected cost, and confirm cleanup afterward.

## Review expectations

Explain how a performance claim was measured and include enough detail for a
reviewer to reproduce it. Reviewers may ask for a smaller change, more evidence,
or documentation updates. Keep discussion respectful and focused on the
technical change.
