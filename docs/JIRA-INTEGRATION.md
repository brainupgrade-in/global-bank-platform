# Jira Integration

Jira holds requirements and delivery status for the whole fleet. GitHub holds source code, pull
requests, Actions, and the agentic workflows. This repository is the single front door between
them — Jira talks to `global-bank-platform`, and `global-bank-platform` routes work to whichever
service repository owns it.

## The project

| | |
|---|---|
| Site | set as the `ATLASSIAN_SITE` repository variable |
| Key | `GBANK` |
| Board | project `GBANK` on that site |
| Type | Company-managed (classic) software project |
| Statuses | `To Do` · `In Progress` · `In Review` · `Done` |
| Issue types | Task · Bug · Sub-task · Epic · Improvement · New Feature |

Use Jira keys exactly as Jira prints them — `GBANK-3`, never zero-padded — in branch names,
commits and pull request titles, e.g. `GBANK-3-account-junit-baseline`.

### Components route work to repositories

This is the one place `GBANK` differs from a single-repo project. Every issue carries a
component, and the component **is** the routing key:

| Component | Repository |
|---|---|
| `account` | `brainupgrade-in/global-bank-account` |
| `authentication` | `brainupgrade-in/global-bank-authentication` |
| `customer` | `brainupgrade-in/global-bank-customer` |
| `transaction` | `brainupgrade-in/global-bank-transaction` |
| `rules` | `brainupgrade-in/global-bank-rules` |
| `frontend` | `brainupgrade-in/global-bank-frontend` |
| `platform` | `brainupgrade-in/global-bank-platform` (this repo) |

An issue with no component has no home repository. Set one before marking it ready, or the
dispatch has nowhere to send it.

For work that genuinely spans services — a port change, a Feign contract, a coordinated Spring
Boot bump — use an Epic on the `platform` component with one child per affected component, so
each child lands in its own repo and the Epic tracks the coordinated merge.

## Repository configuration

Variables are already set on this repository:

| Variable | Value |
|---|---|
| `ATLASSIAN_SITE` | `https://<your-site>.atlassian.net` |
| `JIRA_PROJECT_KEY` | `GBANK` |
| `JIRA_ISSUE_TYPE` | `Task` |
| `JIRA_SYNC_ENABLED` | `false` — **flip to `true` once the secrets below exist** |

Secrets still to add:

| Secret | Value |
|---|---|
| `ATLASSIAN_USER_EMAIL` | email of the Jira integration account |
| `ATLASSIAN_API_TOKEN` | API token for that account |

Use a dedicated Jira integration account with only the permissions needed to read issues, create
issues, add comments and transition issues. Never commit the token or put it in workflow YAML.

## Conventions

- Jira is the source of truth for requirement, priority, ownership and delivery status.
- GitHub is the source of truth for code, review, CI and agent execution.
- Agents may clarify issues, draft specs, break down tasks and post summaries.
- Humans approve scope changes, priority changes, merges and releases.
- **Never let an agent transition an issue to `Done`.** Only a merged pull request does that.
- Put the Jira key in the pull request title so the PR event can be reported back to Jira.
- Labels in use: `agent-generated`, `needs-human-review`, `blocked`, `github-synced`.

## Relationship to the agentic workflows

The three workflows in this repo (`fleet-survey`, `modernization-planner`, `cve-watch`) file
GitHub issues directly in the service repos. They do **not** write to Jira. Findings become Jira
work only when a human promotes one — that is deliberate: a weekly sweep should not be able to
fill a delivery board on its own.

## Reference implementation

The single-repo version of this loop — `jira-sync.yml`, `jira-ready-dispatch.yml`,
`jira-pr-status.yml`, plus the Jira Automation rule that drives it — is implemented and
documented in [`brainupgrade-in/weather-app`](https://github.com/brainupgrade-in/weather-app):
see its `docs/JIRA-INTEGRATION.md` and `getting-started/setup.md`.

Porting it here means one change of substance: `jira-ready-dispatch.yml` must read the issue's
component and create the GitHub issue in **that** repository rather than in itself, which needs a
token with `Issues: Read and write` on all seven repos (`GH_AW_FLEET_TOKEN`). `jira-pr-status.yml`
watches pull requests, so it belongs in each service repo, not here.
