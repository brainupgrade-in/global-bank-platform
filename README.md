# global-bank-platform

The orchestrating repository for the **Global Bank** microservices fleet. It holds no
application code. It holds the fleet map and the agentic workflows that survey the six service
repositories and dispatch work into them.

This is the *Central Repo Ops* pattern from GitHub Agentic Workflows: one central repo
analyses N repositories, creates tailored issues, and dispatches them to the repo that owns
the work.

```
                       ┌──────────────────────┐
                       │ global-bank-platform │
                       │  (this repository)   │
                       │                      │
                       │  fleet-survey        │
                       │  modernization-      │
                       │      planner         │
                       │  cve-watch           │
                       └──────────┬───────────┘
                                  │ reads all six, files findings in the repo that owns them
      ┌──────────┬────────────┬───┴────┬─────────────┬──────────┐
      ▼          ▼            ▼        ▼             ▼          ▼
   account    authentication  customer transaction  rules    frontend
```

## The fleet

| Service | Port | Context path | Stack |
|---|---|---|---|
| `global-bank-account` | 8086 | `/account` | Spring Boot 3.5.3, JDK 25 |
| `global-bank-authentication` | 8084 | `/auth` | Spring Boot 3.5.3, JDK 25 |
| `global-bank-customer` | 8085 | `/customer` | Spring Boot 3.5.3, JDK 25 |
| `global-bank-transaction` | 8087 | `/transaction` | Spring Boot 3.5.3, JDK 25 |
| `global-bank-rules` | 8090 | `/rules` | Spring Boot 3.5.3, JDK 25 |
| `global-bank-frontend` | 4200 | `/` | React 19 + Vite |

`docs/RUNBOOK.md` is what to read before and during a session — health checks, resetting
between groups, and the failure table. `docs/architecture.md` is the human-readable map — call graph, wiring, known debt.
`docs/fleet.json` is the same thing machine-readable, and is what the workflows read so they
do not spend tokens rediscovering the fleet on every run.

## Running the fleet

### On localhost — no Docker, no Kubernetes

```bash
./scripts/local.sh start        # build if needed, start all six, wait for health
./scripts/local.sh status       # what is up, and on which port
./scripts/local.sh logs auth    # tail one service
./scripts/local.sh stop         # stop everything it started
```

Plain `java -jar` and `npm run dev`. Nothing is containerised, nothing needs a cluster. The
five services come up on 8084–8090 and the UI on **http://localhost:4200** — sign in as
`admin`, `eric`, `john` or `ratan`, password `unigps`.

Requirements: **JDK 25+**, Maven, Node 22+. The script finds a JDK 25 under `/usr/lib/jvm` if
`JAVA_HOME` points at something older, and fails early with a clear message if it cannot.

It uses `mvn`, not `./mvnw`: the repos ship the wrapper script but `.mvn/wrapper/` was never
committed, so `./mvnw` cannot bootstrap in any of them.

`start` is safe to re-run — a service already answering its health check is left alone. Logs
and PIDs go to `.run/`, which is gitignored.

### On Kubernetes

The deployed URL is not published here — it is shared with participants during the session.
Sign in as `admin`, `eric`, `john` or `ratan`, password `unigps`.

Manifests live in [`k8s/`](k8s/) and everything lands in the **`global-bank`** namespace.

```bash
./scripts/build-images.sh                 # build images (--push to publish)
./scripts/deploy-k8s.sh                   # apply, then wait for rollout
./scripts/deploy-k8s.sh --forward         # UI on http://localhost:8080
./scripts/deploy-k8s.sh --status
./scripts/deploy-k8s.sh --delete          # remove the namespace
```

| File | What it is |
|---|---|
| `k8s/00-namespace.yaml` | the `global-bank` namespace |
| `k8s/10-config.yaml` | ConfigMap of inter-service URLs, plus the JWT Secret |
| `k8s/20-*.yaml` | Deployment + Service per Java service |
| `k8s/30-frontend.yaml` | the React client behind nginx |
| `k8s/40-ingress.yaml` | optional; `--forward` works without it |
| `k8s/Dockerfile.service` | hermetic build (Maven runs inside Docker) |
| `k8s/Dockerfile.jar` | packages a natively-built jar; the default, and far faster |

Images are **multi-arch (amd64 + arm64)**. arm64 is not optional: the Spark cluster is a DGX
Spark, and an amd64-only image fails there with `exec format error`. Enable emulation once
with `docker run --privileged --rm tonistiigi/binfmt --install arm64`.

A jar is bytecode and runs anywhere, so `build-images.sh` compiles natively and copies the
same jar into each platform's JRE base. Emulating a full Maven build per architecture takes
hours and produces an identical artifact; `--hermetic` does it the slow way when
reproducibility matters more than wall-clock time.

Service names (`auth`, `customer`, `account`, `transaction`, `rules`) are load-bearing: the
ConfigMap and the frontend's `nginx.conf` both address the services by those names.

Probes point at `/<context-path>/actuator/health/{liveness,readiness}`, not the usual
`/actuator/...`, because every service runs under its own context path.

> **Replace the JWT secret before this is anything but a demo.** `10-config.yaml` ships a
> placeholder so `kubectl apply` works out of the box:
> ```bash
> kubectl -n global-bank create secret generic auth-secrets \
>   --from-literal=JWT_SECRET="$(openssl rand -base64 48)" \
>   --dry-run=client -o yaml | kubectl apply -f -
> ```

The Dockerfile for the Java services lives here rather than in the five app repos: how an app
is shipped to a cluster is a deployment concern, and those repos own application behaviour.
See [Infrastructure belongs to the cluster](docs/architecture.md).


## Workflows

| Workflow | Runs | Pattern | Writes |
|---|---|---|---|
| [`fleet-survey`](.github/workflows/fleet-survey.md) | weekly (Mon) + manual | Central Repo Ops | one issue per service with findings, in that service's repo; one roll-up here |
| [`modernization-planner`](.github/workflows/modernization-planner.md) | manual, or `/plan <service>` in a comment | Research–Plan–Assign | one staged upgrade plan in the service's repo; optionally assigned to the Copilot coding agent |
| [`cve-watch`](.github/workflows/cve-watch.md) | weekly (Thu) + manual | Central Repo Ops | one advisory issue per affected service, in that service's repo |

Each workflow is a Markdown file with YAML frontmatter, compiled by
[`gh aw`](https://github.com/github/gh-aw) into the `.lock.yml` beside it. **Edit the `.md`,
never the `.lock.yml`** — recompile with `gh aw compile` and commit both.

All three keep the agent job read-only. Every write goes through a gh-aw *safe output*, capped
(`max:`) and restricted to the six repositories by `allowed-repos`.

## Setup

Two secrets are required on this repository before the workflows will run.

| Secret | Why | Scope needed |
|---|---|---|
| `COPILOT_GITHUB_TOKEN` | Runs the Copilot engine. `brainupgrade-in` is a personal account on Copilot Pro+, so the org-only `permissions.copilot-requests: write` inference path is not available and a PAT is required. | Copilot access |
| `GH_AW_FLEET_TOKEN` | The default `GITHUB_TOKEN` cannot write to *other* repositories. This token is what lets a safe output file an issue in a service repo. | Fine-grained PAT, **Issues: read & write** on the six `global-bank-*` repos |

```bash
gh aw secrets set COPILOT_GITHUB_TOKEN --value "<pat>"
gh aw secrets set GH_AW_FLEET_TOKEN   --value "<pat>"
gh aw secrets bootstrap   # verify what each workflow still needs
```

`modernization-planner`'s assign step additionally wants `GH_AW_AGENT_TOKEN` (a PAT that may
assign the Copilot coding agent). It is configured with `ignore-if-error: true`, so without
that secret the plan issue is still filed — only the hand-off to Copilot is skipped.

## Working on the workflows

```bash
gh aw compile                 # compile all; always run before committing
gh aw compile <id> --approve  # approve newly referenced secrets/actions
gh aw run fleet-survey        # dispatch a run
gh aw logs fleet-survey       # pull logs and token usage
gh aw status                  # what is enabled, and recent outcomes
gh aw forecast                # projected AI Credit usage before you enable a schedule
```

## Cost

Agentic CI spends money on a schedule, quietly. Before enabling or widening a cadence, run
`gh aw forecast`, and after a few runs `gh aw logs` for the actual token split. The three
workflows here are written to keep that bill down: the fleet map is pre-computed in
`docs/fleet.json` rather than rediscovered per run, every workflow has an explicit `noop` path
for a quiet week, and `max:` caps the number of issues any single run can create.

To add GitHub's own token audit and optimizer workflows:

```bash
gh aw add githubnext/agentic-ops
```
