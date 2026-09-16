# Global Bank — Architecture

Bounded context for agents. Read this before `docs/fleet.json`; read the service
repositories only when this file does not answer the question.

## Fleet

Six repositories under the `brainupgrade-in` organisation. There is no monorepo and no
shared parent POM — each service builds independently.

| Service | Repo | Port | Context path | Spring Boot | Java |
|---|---|---|---|---|---|
| Account | `global-bank-account` | 8086 | `/account` | 3.5.3 | 25 |
| Authentication | `global-bank-authentication` | 8084 | `/auth` | 3.5.3 | 25 |
| Customer | `global-bank-customer` | 8085 | `/customer` | 3.5.3 | 25 |
| Transaction | `global-bank-transaction` | 8087 | `/transaction` | 3.5.3 | 25 |
| Rules | `global-bank-rules` | 8090 | `/rules` | 3.5.3 | 25 |
| Frontend | `global-bank-frontend` (branch `k8s`) | 4200 | `/` | Angular 9.1.13 | — |

## Call graph

Services call each other over OpenFeign. Authentication is the only leaf.

```
frontend ──▶ auth, customer, account, transaction, rules   (Angular dev proxy)

account ──▶ customer, auth, transaction
customer ──▶ auth, account
rules ──▶ auth, account
transaction ──▶ account, rules
auth ──▶ (none)
```

`account` and `customer` call each other, as do `transaction` and `rules`. Any change to a
context path or port must be applied in the callers' `application.properties` too.

## Wiring

Feign targets are plain properties, not service discovery:

```properties
# global-bank-account/src/main/resources/application.properties
feign.url-customer-service=${CUSTOMER_SERVICE_URL:localhost:8085/customer}
feign.url-auth-service=${AUTH_SERVICE_URL:localhost:8084/auth}
feign.url-transaction-service=${TRANSACTION_SERVICE_URL:localhost:8087/transaction}
```

The defaults exist only so a local run works with no setup. **In the cluster the Deployment
must supply Service DNS names**, or every service will try to reach its peers on localhost.

The frontend still resolves the same map through `proxy.conf.local.json`.

## Persistence — and the two consequences people miss

Every Java service runs an **in-memory** H2 (`jdbc:h2:mem:<name>`) with
`spring.jpa.hibernate.ddl-auto=update`, seeded from `data.sql` at startup. A MariaDB driver
ships for a production profile that is not configured. Credentials are `root`/`root` in the
committed properties.

The database lives inside the JVM process. Two things follow, and both bite:

**1. These services cannot be scaled past one replica.** A second replica gets its own empty
database. A deposit made on one pod is invisible on the other, so balances diverge depending
on which pod answers a request. The Deployments pin `replicas: 1` and say so at the field.
Raising it looks like a capacity improvement and is actually a correctness bug.

**2. A restart wipes everything.** Any OOMKill, eviction or node reboot resets every balance
to seed state. Memory limits are set at roughly twice the observed peak specifically to make
that unlikely. It cannot be eliminated without a shared database.

Both are fine for a demo and unacceptable for anything else. Moving to a real datastore is the
single change that lifts both limits.

## Deployment

Deployed to a single-node k3s cluster in the `global-bank` namespace. The public URL is not
recorded here; it is shared with participants directly.

| | |
|---|---|
| Runtime | single-node k3s, **arm64** |
| Namespace | `global-bank` |
| Images | `brainupgrade/global-bank-*:3.0.0`, multi-arch amd64 + arm64 |
| Path | browser → edge proxy (TLS) → tunnel → ingress-nginx → frontend |

Two things about this are non-obvious:

- **arm64 is mandatory.** The node is arm64; an amd64-only image fails with
  `exec format error`. Build multi-arch, always.
- **The hostname is constrained.** The parent zone applies a site-wide redirect that only
  certain host prefixes are excluded from, so the name cannot be chosen freely — an
  unexcluded host is 301'd away and the demo silently dies. DNS and that exclusion are
  managed outside this repository.

Scripts live in the platform repo: `scripts/local.sh` (no Docker, no cluster),
`scripts/build-images.sh`, `scripts/deploy-k8s.sh`.

## Known debt

See `known_debt` in `docs/fleet.json`. What remains after the Sept 2026 modernisation:

- **No tests.** Zero test sources across all five Java services. The `build` workflow — a
  compiling build — is the only automated signal any of them has. It did not catch four
  runtime failures during the upgrade, all of which only appeared when the app was started.
- **In-memory H2**, with the two consequences above.
- **`.mvn/wrapper/` was never committed** to any Java repo, so `./mvnw` cannot bootstrap
  despite the script being tracked. Use `mvn`.
- **Lombok is gone fleet-wide.** 1.18.38 is the newest release and does not support JDK 25 —
  its processor silently generates nothing, which surfaces as misleading `cannot find symbol`
  errors. Sources were delomboked under JDK 21. It can return when a supporting version ships.
- **No Dockerfile in the five Java repos.** One shared `k8s/Dockerfile.jar` in the platform
  repo packages all of them, deliberately: shipping to a cluster is a deployment concern.

## Infrastructure belongs to the cluster, not the repository

These services are deployed to Kubernetes. A repository owns **application behaviour**; it does
not own infrastructure. Any dependency that re-implements a cluster capability is duplication —
a second, divergent copy of a concern the platform already handles, which then has to be
configured, upgraded and debugged separately.

Remove rather than migrate:

| Component | Where it is | What the cluster does instead |
|---|---|---|
| ~~`spring-cloud-starter-netflix-hystrix`~~ removed | customer, rules, transaction | Retries, timeouts and circuit breaking belong to the mesh/ingress layer |
| ~~`spring-cloud-starter-netflix-hystrix-dashboard`~~ removed | rules, transaction | Prometheus + Grafana |
| ~~`spring-cloud-starter-config`~~ removed | account, customer, transaction | ConfigMap and Secret |
| ~~hardcoded `feign.url-*=localhost:PORT`~~ now env vars | account, customer, rules, transaction | Service DNS, supplied as env vars by the Deployment |
| ~~`spring-boot-devtools`~~ removed | all five | Nothing — a live-reload server has no business in a production image |

Hystrix is the clearest case: it is end-of-life, its last release was `2.2.10`, and it does not
exist for Spring Cloud 2025.x. Migrating it to Resilience4j would rebuild in application code
what the platform already offers. Delete it.

### The corollary

Components that let the application **cooperate** with the cluster are not duplication, and are
missing where they matter most:

| Component | Status | Why it is needed |
|---|---|---|
| `spring-boot-starter-actuator` | **now in all five** | Liveness and readiness probes call `/<context-path>/actuator/health/liveness` and `/readiness`. Note that in `authentication` these must be explicitly permitted in the security filter chain, or the kubelet gets 403. |

Expose health and info only. The full endpoint surface is not wanted.

### Applying this

Every modernization issue filed against a service must state, per removed dependency, which
cluster capability replaces it — so removals are reviewed as decisions rather than inferred
from a diff. Removing a dependency must never remove a feature the application genuinely
offers; if something is load-bearing, say so instead of dropping it.

## Conventions for agents

- Never change a port or context path in one repo alone — update every caller listed in the
  call graph in the same change.
- Java services build with `./mvnw clean package`; the frontend with `npm ci && npm run build`.
- The frontend's default branch is `k8s`, not `main`. Target it explicitly.
