---
emoji: 🏦
description: Weekly health survey of the six Global Bank repositories, with per-service findings dispatched into each service repo.
intent: Every service repository in the Global Bank fleet has an open, current, evidence-backed statement of its own health, and the platform repo carries one roll-up of the fleet.
on:
  schedule: weekly on monday
  workflow_dispatch:
permissions:
  contents: read
  issues: read
  pull-requests: read
  actions: read
tools:
  github:
    mode: gh-proxy
    toolsets: [default]
safe-outputs:
  github-token: ${{ secrets.GH_AW_FLEET_TOKEN }}
  create-issue:
    max: 7
    title-prefix: "[fleet-survey] "
    close-older-issues: true
    allowed-repos:
      - brainupgrade-in/global-bank-account
      - brainupgrade-in/global-bank-authentication
      - brainupgrade-in/global-bank-customer
      - brainupgrade-in/global-bank-transaction
      - brainupgrade-in/global-bank-rules
      - brainupgrade-in/global-bank-frontend
---

# Fleet Survey

## Context

Read `docs/architecture.md` and `docs/fleet.json` in this repository first. They are the
authoritative fleet map: six repositories, their ports, context paths, framework versions and
call graph. Do not re-derive any of it by cloning repositories.

## Task

Survey the fleet for the **last 7 days** and report what changed and what is now at risk.

For each of the six services in `docs/fleet.json`:

1. Read the repository's recent activity with `gh` — commits on its listed branch, open
   issues, open pull requests, and the conclusion of its most recent Actions run if it has any.
2. Check the claims in `docs/fleet.json` still hold. Specifically confirm the declared
   `spring_boot`, `java` and `port` values against the repo's `pom.xml` and
   `application.properties`. A mismatch is a finding: the fleet map has drifted.
3. Identify at most **two** highest-value problems for that service. Prefer problems that are
   specific, evidenced by a file and line, and actionable in a single pull request. The entries
   under `known_debt` in `docs/fleet.json` are already known — only raise one if it has
   materially changed or you have new evidence about its blast radius.

Then produce output in this order:

- **One issue per service that has findings**, created in that **service's own repository**
  by setting the `repo` field to its `repo` value from `docs/fleet.json`. Title it for the
  service. Body: the findings, each with the file path that evidences it, why it matters for
  this service specifically, and a suggested first step. Skip services with no findings —
  do not open an empty issue.
- **One roll-up issue in this repository** (`brainupgrade-in/global-bank-platform`, the
  default target — omit `repo`). Body: a table of the six services with their current
  framework version, activity in the window, and the count of findings dispatched; then the
  three fleet-wide risks you would fix first, and any drift you found between
  `docs/fleet.json` and reality.

## Guardrails

- Before creating an issue in a service repo, search that repo for an open issue with the
  `[fleet-survey] ` prefix covering the same scope. If one exists and nothing material has
  changed, leave it alone and say so in the roll-up instead of opening a duplicate.
- Never open the same finding in two repositories.
- Read-only. All writes go through the `create-issue` safe output.
- Call `noop` with a one-line reason if the window contains no activity and no drift — a quiet
  week should cost one skipped run, not seven issues.

## Safe Outputs

- `create-issue` — at most 7 (six services plus the roll-up), each with a substantive body.
- `noop` — when there is nothing worth a human's attention.
