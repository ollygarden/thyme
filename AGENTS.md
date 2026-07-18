# Repository guidance

## Purpose and scope

Thyme is a downstream OpenTelemetry Collector distribution based on
[Tulip](https://github.com/ollygarden/tulip). It is specialized for repeatable,
high-throughput log-ingestion benchmarks. It is test tooling, not a supported
production collector.

Keep changes focused on benchmarking. Do not copy Thyme-specific tuning into
Tulip or describe benchmark configurations as production recommendations
without separate evidence and review.

## Build and development

The root `Makefile` delegates Collector tasks to
`distributions/thyme/Makefile`:

```bash
make build       # download OCB, generate the distribution, and compile it
make generate    # generate the distribution without compiling
make validate    # build, then validate config.yaml
make run         # build, then run config.yaml
make clean       # remove generated build/ and bin/ directories
make docker-build
```

The distribution currently uses OpenTelemetry Collector Builder v0.151.0.
`distributions/thyme/manifest.yaml` is the component source of truth;
`distributions/thyme/build/` and `distributions/thyme/bin/` are generated and
must not be edited or committed.

`tools/exportbench/` is a separate Go module. Run its commands from that
directory, and do not assume that its dependency versions move in lockstep
with the Collector distribution.

## Architecture and configuration

The Kubernetes benchmark writes generated logs to node pod-log files. A Thyme
DaemonSet reads them with `filelog`, adds Kubernetes metadata, batches them,
and exports them to a separate Collector whose `nop` exporter discards the
records. Both Collectors send their own telemetry to the LGTM stack.

- `distributions/thyme/config.yaml` is the Kubernetes benchmark configuration.
- `distributions/thyme/config-local.yaml` is the smaller local OTLP/debug
  configuration.
- `deployment/kubernetes/` is the local k3d base.
- `deployment/aws/` overlays the base for EKS.
- `infrastructure/aws/` contains the OpenTofu EKS infrastructure.

When changing Collector configuration:

- keep Kubernetes health and profiling endpoints reachable on `0.0.0.0`;
- preserve receiver message-size limits compatible with the large configured
  batches;
- verify the batch size, sending queue, and internal-telemetry destination as
  one system rather than tuning one field in isolation;
- keep Kustomize resources and the corresponding documentation aligned.

When updating the Collector version, review the manifest distribution and
component versions, provider versions, `OCB_VERSION` in
`distributions/thyme/Makefile`, and the Docker build argument together.

## Operational safety

Benchmark workflows are stateful and potentially destructive. Obtain explicit
authorization before running either benchmark script or applying deployment or
infrastructure changes.

- `scripts/run-benchmark.sh` creates and can replace/delete a local k3d
  cluster.
- `scripts/run-benchmark-aws.sh` creates billable AWS resources, updates the
  local kubeconfig, pushes an image, deploys workloads, and may destroy the
  infrastructure afterward.
- `kubectl apply`, `kubectl delete`, `tofu apply`, and `tofu destroy` are never
  validation-only commands.

Treat cost figures in documentation as historical estimates. Confirm the
current resources and prices before obtaining approval for a cloud run. Record
the target cluster/account and cleanup outcome for every authorized run.

## Validation

Choose the checks that cover the changed paths:

| Change | Required checks |
| --- | --- |
| Documentation or repository metadata | `git diff --check` and the Markdown link check below |
| Collector manifest, config, or build logic | `make build` and `KUBE_NODE_NAME=validation-node make validate` |
| Kubernetes manifests | `kubectl kustomize deployment/kubernetes` and `kubectl kustomize deployment/aws` |
| AWS OpenTofu | `tofu fmt -check -recursive infrastructure/aws`; initialize and validate only when dependency access is appropriate |
| Benchmark shell scripts | `bash -n scripts/*.sh deployment/kubernetes/build-and-load.sh` |
| Export benchmark tool | `(cd tools/exportbench && go test ./...)` |

The Kustomize commands above only render manifests. Never substitute a live
`kubectl apply` as a validation step.

Check local Markdown links with:

```bash
perl -MFile::Basename=dirname -ne 'while (/\[[^]]+\]\(([^)#]+)(?:#[^)]+)?\)/g) { my $target = $1; next if $target =~ m{^(?:https?://|mailto:)}; my $path = $target =~ m{^/} ? $target : dirname($ARGV) . "/" . $target; die "$ARGV: missing $target\n" unless -e $path }' AGENTS.md README.md CONTRIBUTING.md
```

Before committing, also verify that `AGENTS.md` is a real file,
`CLAUDE.md -> AGENTS.md`, `.agents/skills/` is a real directory, and
`.claude/skills -> ../.agents/skills`.

## Contributions

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for change scope, commit and pull
request conventions, validation evidence, and security expectations.
