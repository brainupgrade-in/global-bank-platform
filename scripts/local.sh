#!/usr/bin/env bash
#
# Run the whole Global Bank fleet on localhost.
#
#   ./scripts/local.sh start      build if needed, then start everything
#   ./scripts/local.sh start --build   force a rebuild first
#   ./scripts/local.sh stop       stop everything this script started
#   ./scripts/local.sh status     what is up, and on which port
#   ./scripts/local.sh logs auth  tail one service's log
#
# The six repositories are expected to sit side by side, which is how they are
# laid out when cloned from the brainupgrade-in account:
#
#   microservices/
#     global-bank-platform/     <- you are here
#     global-bank-account/  global-bank-authentication/  ...
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$(cd "$HERE/../.." && pwd)"
RUN="$HERE/../.run"
LOGS="$RUN/logs"

# name : repo directory : port : context path
SERVICES=(
  "auth:global-bank-authentication:8084:auth"
  "customer:global-bank-customer:8085:customer"
  "account:global-bank-account:8086:account"
  "transaction:global-bank-transaction:8087:transaction"
  "rules:global-bank-rules:8090:rules"
)
FRONTEND_DIR="global-bank-frontend"
FRONTEND_PORT=4200

c_dim=$'\033[2m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_yel" "$c_off" "$*"; }
die()  { printf '  %s✗%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

find_jdk() {
  # The services target Java 25. Prefer an explicit JAVA_HOME if it is new enough.
  if [[ -n "${JAVA_HOME:-}" ]] && "$JAVA_HOME/bin/java" -version 2>&1 | grep -qE '"2[5-9]'; then
    printf '%s' "$JAVA_HOME"; return
  fi
  local candidate
  for candidate in /usr/lib/jvm/java-25-openjdk-* /usr/lib/jvm/java-2[5-9]* /usr/lib/jvm/jdk-2[5-9]*; do
    [[ -x "$candidate/bin/java" ]] && { printf '%s' "$candidate"; return; }
  done
  # Fall back to whatever java is on PATH, and let the version check below complain.
  printf '%s' "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
}

preflight() {
  command -v mvn  >/dev/null || die "mvn not found. The repos ship mvnw but .mvn/wrapper was never committed, so the wrapper cannot bootstrap."
  command -v java >/dev/null || die "java not found."
  command -v curl >/dev/null || die "curl not found."

  JAVA_HOME="$(find_jdk)"; export JAVA_HOME
  local ver
  ver="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')"
  [[ "${ver:-0}" -ge 25 ]] || die "Java 25+ required, found $ver at $JAVA_HOME. The services were upgraded to JDK 25."

  local entry dir
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r _ dir _ _ <<< "$entry"
    [[ -d "$FLEET/$dir" ]] || die "$dir not found next to global-bank-platform. Clone the fleet side by side."
  done
}

port_busy() { curl -sf -o /dev/null --max-time 1 "http://localhost:$1/" 2>/dev/null || lsof -ti tcp:"$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- build

build_one() {
  local dir=$1
  ( cd "$FLEET/$dir" && mvn -B -q clean package -DskipTests > "$LOGS/build-$dir.log" 2>&1 )
}

build_all() {
  say "Building services (JDK $("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"'))"
  local entry name dir pids=() names=()
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name dir _ _ <<< "$entry"
    build_one "$dir" & pids+=($!); names+=("$name:$dir")
  done
  local i rc=0
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then ok "${names[$i]%%:*} built"
    else
      local d="${names[$i]#*:}"
      printf '  %s✗%s %s failed — last lines of %s:\n' "$c_red" "$c_off" "${names[$i]%%:*}" "$LOGS/build-$d.log"
      tail -12 "$LOGS/build-$d.log" | sed 's/^/      /'
      rc=1
    fi
  done
  [[ $rc -eq 0 ]] || die "Build failed. Nothing was started."
}

jar_for() { ls "$FLEET/$1"/target/*.jar 2>/dev/null | grep -v sources | head -1; }

# ---------------------------------------------------------------- start

wait_healthy() {
  local name=$1 port=$2 ctx=$3 tries=0
  # Every service now exposes actuator health; that is what Kubernetes probes too.
  until curl -sf -o /dev/null --max-time 2 "http://localhost:$port/$ctx/actuator/health"; do
    tries=$((tries + 1))
    if [[ $tries -gt 60 ]]; then
      printf '  %s✗%s %-14s did not become healthy in 120s — see %s\n' "$c_red" "$c_off" "$name" "$LOGS/$name.log"
      tail -8 "$LOGS/$name.log" | sed 's/^/      /'
      return 1
    fi
    sleep 2
  done
}

start_all() {
  mkdir -p "$LOGS"
  [[ "${1:-}" == "--build" ]] && build_all

  local entry name dir port ctx jar missing=0
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name dir port ctx <<< "$entry"
    [[ -n "$(jar_for "$dir")" ]] || missing=1
  done
  [[ $missing -eq 1 && "${1:-}" != "--build" ]] && { warn "some jars missing — building first"; build_all; }

  say ""
  say "Starting services"
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name dir port ctx <<< "$entry"

    if curl -sf -o /dev/null --max-time 1 "http://localhost:$port/$ctx/actuator/health" 2>/dev/null; then
      warn "$name already healthy on $port — leaving it alone"
      continue
    fi
    if port_busy "$port"; then
      die "port $port is in use by something that is not $name. Free it, or run '$0 stop'."
    fi

    jar="$(jar_for "$dir")"
    [[ -n "$jar" ]] || die "no jar for $name — run '$0 start --build'"
    ( cd "$FLEET/$dir" && nohup "$JAVA_HOME/bin/java" -jar "$jar" > "$LOGS/$name.log" 2>&1 < /dev/null & echo $! > "$RUN/$name.pid" )
  done

  local failed=0
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name dir port ctx <<< "$entry"
    if wait_healthy "$name" "$port" "$ctx"; then
      ok "$(printf '%-14s' "$name") http://localhost:$port/$ctx"
    else
      failed=1
    fi
  done

  # Frontend last: it is the only thing a person actually opens.
  say ""
  say "Starting frontend"
  if [[ -d "$FLEET/$FRONTEND_DIR" ]]; then
    [[ -d "$FLEET/$FRONTEND_DIR/node_modules" ]] || ( cd "$FLEET/$FRONTEND_DIR" && npm install --silent )
    if port_busy "$FRONTEND_PORT"; then
      warn "port $FRONTEND_PORT already in use — not starting a second dev server"
    else
      ( cd "$FLEET/$FRONTEND_DIR" && nohup npm run dev > "$LOGS/frontend.log" 2>&1 < /dev/null & echo $! > "$RUN/frontend.pid" )
      local t=0
      until curl -sf -o /dev/null --max-time 2 "http://localhost:$FRONTEND_PORT/" || [[ $t -ge 60 ]]; do sleep 2; t=$((t+2)); done
    fi
    ok "$(printf '%-14s' frontend) http://localhost:$FRONTEND_PORT"
  else
    warn "$FRONTEND_DIR not found — services are up, no UI"
  fi

  say ""
  if [[ $failed -eq 0 ]]; then
    say "  ${c_grn}Fleet is up.${c_off}  Open ${c_grn}http://localhost:$FRONTEND_PORT${c_off}"
    say "  ${c_dim}Sign in as admin / eric / john / ratan, password unigps${c_off}"
  else
    say "  ${c_yel}Some services did not start. The UI falls back to demo data for those.${c_off}"
  fi
  say "  ${c_dim}Logs: $LOGS    Stop: $0 stop${c_off}"
}

# ---------------------------------------------------------------- stop / status

# Kill a process and every descendant, deepest first. `npm run dev` is why this
# has to recurse: it spawns the dev server as a grandchild, so sweeping only
# direct children leaves it running and the port held.
kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null
}

stop_all() {
  local stopped=0 f name pid
  shopt -s nullglob
  for f in "$RUN"/*.pid; do
    name="$(basename "$f" .pid)"; pid="$(cat "$f" 2>/dev/null)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      # Never a process group: these share the launching shell's group, so a
      # group kill would take the terminal this script was run from with it.
      kill_tree "$pid"
      ok "stopped $name (pid $pid)"; stopped=$((stopped+1))
    fi
    rm -f "$f"
  done
  shopt -u nullglob
  [[ $stopped -eq 0 ]] && say "  nothing was running that this script started"
}

status_all() {
  local entry name dir port ctx
  printf '  %-14s %-6s %s\n' SERVICE PORT STATUS
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r name dir port ctx <<< "$entry"
    if curl -sf -o /dev/null --max-time 2 "http://localhost:$port/$ctx/actuator/health" 2>/dev/null; then
      printf '  %-14s %-6s %sUP%s\n' "$name" "$port" "$c_grn" "$c_off"
    else
      printf '  %-14s %-6s %sdown%s\n' "$name" "$port" "$c_dim" "$c_off"
    fi
  done
  if curl -sf -o /dev/null --max-time 2 "http://localhost:$FRONTEND_PORT/" 2>/dev/null; then
    printf '  %-14s %-6s %sUP%s\n' frontend "$FRONTEND_PORT" "$c_grn" "$c_off"
  else
    printf '  %-14s %-6s %sdown%s\n' frontend "$FRONTEND_PORT" "$c_dim" "$c_off"
  fi
}

# ---------------------------------------------------------------- main

case "${1:-start}" in
  start)  preflight; start_all "${2:-}" ;;
  build)  preflight; mkdir -p "$LOGS"; build_all ;;
  stop)   stop_all ;;
  status) status_all ;;
  logs)   [[ -n "${2:-}" ]] || die "which service? e.g. $0 logs auth"
          tail -f "$LOGS/${2}.log" ;;
  *)      sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//' ;;
esac
