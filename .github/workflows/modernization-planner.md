---
emoji: 🧭
description: Researches one Global Bank service in depth and files a staged modernization plan in that service's repository, optionally handing it to the Copilot coding agent.
intent: A named service has one current, evidence-backed modernization plan in its own repository, broken into independently mergeable steps, with the first step ready for an agent to pick up.
on:
  workflow_dispatch:
    inputs:
      service:
        description: "Service to plan (e.g. global-bank-account), or 'auto' to pick the service with the oldest framework and no open plan."
        required: false
        default: "auto"
      assign:
        description: "Hand the first step to the Copilot coding agent."
        type: boolean
        default: false
  slash_command:
    name: plan
    events: [issues, issue_comment]
concurrency:
  job-discriminator: ${{ inputs.service || github.run_id }}
permissions:
  contents: read
  issues: read
  pull-requests: read
safe-outputs:
  github-token: ${{ secrets.GH_AW_FLEET_TOKEN }}
  create-issue:
    max: 1
    title-prefix: "[modernization] "
    allowed-repos:
      - brainupgrade-in/global-bank-account
      - brainupgrade-in/global-bank-authentication
      - brainupgrade-in/global-bank-customer
      - brainupgrade-in/global-bank-transaction
      - brainupgrade-in/global-bank-rules
      - brainupgrade-in/global-bank-frontend
  assign-to-agent:
    allowed: [copilot]
    max: 1
    target: "*"
    ignore-if-error: true
    allowed-pull-request-repos:
      - brainupgrade-in/global-bank-account
      - brainupgrade-in/global-bank-authentication
      - brainupgrade-in/global-bank-customer
      - brainupgrade-in/global-bank-transaction
      - brainupgrade-in/global-bank-rules
      - brainupgrade-in/global-bank-frontend
---

# Modernization Planner

## Context

Read `docs/architecture.md` and `docs/fleet.json` in this repository first — they carry the
fleet map, the call graph and the known debt. Do not re-derive them.

Requested service: `${{ github.event.inputs.service }}`

When that value is empty, this run came from a `/plan` comment; take the service name from the
triggering text. When it is `auto` or names something not in `docs/fleet.json`, select the
service yourself: the one with the oldest framework version that has **no** open issue with
the `[modernization] ` prefix. Say which you picked and why.

## Task — Research

Research the selected service in its **own repository**, reading only what you need:

1. `pom.xml` (or `package.json`) — current framework, language level, and every pinned version.
2. `src/main/resources/application.properties` — ports, context path, Feign targets, datasource.
3. The service's controllers, to know its public surface.
4. Its open issues and pull requests, so the plan does not restate work already in flight.

Then check what the upgrade actually costs. For a Java service that means at minimum: which
pinned dependencies block the next Spring Boot line (springfox 2.9.2 does), whether Netflix
Hystrix is present and what replaces it, what the Java language-level jump requires, and which
**other** repositories in the call graph must change in lockstep.

## Task — Plan

File **one issue in the selected service's repository** (set the `repo` field to its `repo`
value from `docs/fleet.json`; do not file it here). Structure the body as:

- **Current state** — versions and language level, each with the file that evidences it.
- **Target state** — the specific versions you are proposing, and why that target and not a
  further one.
- **Staged steps** — numbered, each one independently mergeable and each small enough to be a
  single pull request. Order them so the repository builds and starts after every step. Name
  the blocking dependency each step clears.
- **Cross-repo impact** — the callers from the call graph that must change with it, by repo.
  If a step cannot land alone, say which repos must merge together.
- **Verification** — what proves each step worked. This fleet has no tests, so say plainly
  what has to be written before a step can be verified rather than assuming a suite exists.
- **Step 1** — spelled out in enough detail that an agent can start on it without more context.

## Task — Assign

When `${{ github.event.inputs.assign }}` is `true`, assign the issue you just created to the
Copilot coding agent, targeting the service's own repository for the pull request. Otherwise do
not assign — the plan is for a human to read first.

## Guardrails

- One issue, in the service repo, per run. Never file the plan in this repository.
- If the service already has an open `[modernization] ` issue and nothing material has changed
  since it was written, call `noop` with that issue number instead of filing a second plan.
- Read-only. All writes go through the safe outputs above.
- Do not propose a target version you have not checked the service's pinned dependencies
  against. An unverified upgrade path is worse than no plan.

## Safe Outputs

- `create-issue` — exactly one, in the selected service's repository.
- `assign-to-agent` — only when explicitly requested.
- `noop` — when a current plan already exists.
