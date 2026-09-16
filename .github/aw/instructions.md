# Repository overlay — global-bank-platform

This repository is the **central orchestrator** for the Global Bank fleet. It contains no
application code. Its job is to analyse the six service repositories and dispatch tailored
work into them (the *Central Repo Ops* pattern).

## Context budget

Read `docs/architecture.md` and `docs/fleet.json` first. They are the authoritative fleet
map. Clone or read a service repository only for a question those two files cannot answer,
and read the narrowest path that answers it (`pom.xml`, one `application.properties`, one
controller) rather than the tree.

## Write rules

- This repo's own issues are for **fleet-wide** reports and roll-ups.
- Per-service findings belong in the **service repo**, not here. Set the `repo` field on the
  safe output to the target repository.
- Never open the same issue in more than one repository. One finding, one home.
- Before creating an issue in a service repo, search that repo's open issues for an existing
  one covering the same scope, and `noop` with the issue number if found.

## Fleet facts that agents get wrong

- `global-bank-frontend`'s default branch is `k8s`, not `main`.
- There is no parent POM and no monorepo. Every service pins its own Spring Boot version.
- A port or context-path change touches every caller in the call graph, in separate repos.

## Infrastructure duplication

These services run on Kubernetes. The repository owns application behaviour; the cluster owns
infrastructure. When proposing or planning work, treat any dependency that re-implements a
cluster capability as something to **delete, not migrate** — Hystrix and its dashboard, Spring
Cloud Config, hardcoded `localhost:PORT` service URLs, devtools. See
"Infrastructure belongs to the cluster" in `docs/architecture.md` for the full table.

The inverse is equally important: `spring-boot-starter-actuator` is missing from four of the
five services, so Kubernetes cannot probe them. Adding it is part of the same concern, not a
separate nicety.

Never recommend migrating Hystrix to Resilience4j. That rebuilds a platform capability in
application code.
