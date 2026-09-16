# Runbook

Operating the Global Bank demo. Written for the person standing in front of participants.

## Before a session

```bash
cd ~/git/brainupgrade-in/microservices/global-bank-platform
export APP_HOST=<the host this is deployed on>   # not recorded in this repo

# 1. Is the deployment healthy?
./scripts/deploy-k8s.sh --status

# 2. Does the public URL actually serve?
curl -s -o /dev/null -w '%{http_code}\n' "https://$APP_HOST/"

# 3. Is it serving LIVE data, or silently falling back to demo data?
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"userid":"admin","password":"unigps"}' \
  "https://$APP_HOST/auth/login"
```

A JWT in that last response means the whole chain works: Cloudflare → tunnel → ingress →
frontend nginx → auth service → H2.

The UI sidebar shows **LIVE API** or **DEMO DATA**. If it says DEMO DATA the backend is
unreachable and participants are looking at seeded fixtures — the app will *look* fine, so
check the badge rather than assuming.

## Resetting between sessions

The database is in-memory. To reset every balance to seed state:

```bash
kubectl -n global-bank rollout restart deploy/account deploy/customer deploy/transaction
```

That is also what happens involuntarily on any OOMKill or node reboot.

## When something is wrong

| Symptom | Cause | Fix |
|---|---|---|
| UI loads, shows **DEMO DATA** | backend unreachable from the browser | `deploy-k8s.sh --status`; check `frontend` logs for proxy errors |
| URL 301s to a different site | the host prefix is no longer covered by the zone's redirect exclusion | re-check the DNS record and the exclusion; both are managed outside this repo |
| URL times out although DNS resolves | the zone has a wildcard, so a **missing** record still answers — from somewhere else entirely. Resolution is not evidence of correct DNS | re-create the host record |
| Pod `CrashLoopBackOff`, `exec format error` | amd64 image on the arm64 node | rebuild multi-arch: `./scripts/build-images.sh --push` |
| Pod OOMKilled | memory limit too low for load | balances are gone; restart is the only recovery |
| Balances differ between refreshes | someone scaled a Java service past 1 replica | `kubectl -n global-bank scale deploy/<svc> --replicas=1` |
| Login works, everything else 400 | client omitted `Authorization: Bearer <jwt>` | not a fault — those endpoints require it |
| Login 500s after a redeploy | JWT secret changed under running sessions | expected; participants re-login |

## Verified capacity

60 concurrent clients, 1200 requests: **all 200**, no restarts, no OOMKills, 346Mi peak
memory, 642m peak CPU. That is comfortably past a room of participants clicking around.

Do **not** add `nginx.ingress.kubernetes.io/limit-rps`. The ingress does not forward client
addresses — every request arrives from the controller's pod IP, so a per-IP limit throttles
the entire room as one client.

## Rebuilding and redeploying

```bash
./scripts/build-images.sh --push      # multi-arch; needs docker login as brainupgrade
./scripts/deploy-k8s.sh               # apply + wait for rollout
```

`--push` refuses to create a new Docker Hub repository or overwrite a published tag. If it
stops, that is the guard working — pick a free tag with `--tag`, do not reach for `--force`
without knowing what you are replacing.

A push occasionally stalls (buildkit idle, network fine). Kill it and re-run; completed layers
are cached and it resumes.

## Traps that cost real time

Each of these was hit during the Sept 2026 build and is recorded so it is not re-debugged:

- **`data.sql` runs before Hibernate creates tables** in Boot 2.5+. Needs
  `spring.jpa.defer-datasource-initialization=true`, or the app compiles and dies on startup.
- **Hibernate 6 orders generated columns differently from Hibernate 5.** A positional
  `INSERT` in `data.sql` silently lands values in the wrong columns. Name the columns.
- **Spring Security's `requestMatchers("/*")` matches one path segment.** `/actuator/health/liveness`
  falls through to `authenticated()` and every probe gets 403 — Kubernetes then kills a pod
  that was working.
- **A green build proves very little here.** Four separate runtime failures during the upgrade
  all passed CI; every one needed the app actually started to surface.
- **Running an image locally as UID 1000 may fail** with `resource temporarily unavailable`.
  That is the host's `nproc` limit shared with your desktop session, not the image. Add
  `--ulimit nproc=-1`. It does not occur on a cluster node.
