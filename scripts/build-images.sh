#!/usr/bin/env bash
#
# Build container images for the whole fleet.
#
#   ./scripts/build-images.sh              build locally
#   ./scripts/build-images.sh --push       build and push to Docker Hub
#   ./scripts/build-images.sh --push --force   push even if the tag exists
#   ./scripts/build-images.sh --platforms linux/arm64   build one architecture
#
# Images are multi-arch (amd64 + arm64). arm64 matters: the Spark cluster runs
# on a DGX Spark, and an amd64-only image fails there with "exec format error".
# arm64 is built under QEMU emulation here, which is slow; enable it once with
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
#   ./scripts/build-images.sh --tag 2.1.0  build a specific tag
#
# Images go to repositories that already exist under the brainupgrade namespace:
# global-bank-{account,authentication,customer,transaction,rules,frontend}.
# --push refuses to run if a name would create a new repository, or if the tag
# is already published, unless --force is given.
#
# Only needed for the Kubernetes path. Running locally needs no images at all —
# see scripts/local.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="$(cd "$HERE/.." && pwd)"
FLEET="$(cd "$PLATFORM/.." && pwd)"

TAG=3.0.0
REGISTRY=brainupgrade
PUSH=0
FORCE=0
# The Spark cluster is a DGX Spark: arm64. Building amd64 only produces images
# that fail there with "exec format error", so both are built by default.
PLATFORMS=linux/amd64,linux/arm64
BUILDER=fleet
# A jar is bytecode and runs anywhere, so there is no reason to emulate a whole
# Maven build per architecture. FROM_JARS compiles natively then copies the jar
# into each platform's JRE base: minutes instead of hours for arm64. Set
# FROM_JARS=0 for the hermetic in-Docker build (Dockerfile.service).
FROM_JARS=1
while [[ $# -gt 0 ]]; do
  case $1 in
    --push)  PUSH=1; shift ;;
    --force) FORCE=1; shift ;;
    --tag)  TAG=$2; shift 2 ;;
    --registry)  REGISTRY=$2; shift 2 ;;
    --platforms) PLATFORMS=$2; shift 2 ;;
    --hermetic)  FROM_JARS=0; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

# image name : source repo
# The image name is NOT always the Service name: the Service is "auth" because
# nginx.conf and the ConfigMap address it that way, but the image has to be
# global-bank-authentication to match the Docker Hub repo that already exists.
JAVA_SERVICES=(
  "authentication:global-bank-authentication"
  "customer:global-bank-customer"
  "account:global-bank-account"
  "transaction:global-bank-transaction"
  "rules:global-bank-rules"
)

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
command -v curl   >/dev/null || { echo "curl not found" >&2; exit 1; }

# Does this repository already exist under the namespace?
repo_exists() {
  curl -sf -o /dev/null "https://hub.docker.com/v2/repositories/$REGISTRY/$1/"
}

# Is this tag already published? Pushing over it replaces an image someone may
# still be running.
tag_exists() {
  curl -sf -o /dev/null "https://hub.docker.com/v2/repositories/$REGISTRY/$1/tags/$2/"
}

if [[ $PUSH -eq 1 ]]; then
  # Fail before building anything, not after twenty minutes of Maven.
  echo "Checking $REGISTRY on Docker Hub before building"
  problems=0
  for entry in "${JAVA_SERVICES[@]}" "frontend:global-bank-frontend"; do
    IFS=: read -r name _ <<< "$entry"
    repo="global-bank-$name"
    [[ "$name" == frontend ]] && repo="global-bank-frontend"
    if ! repo_exists "$repo"; then
      echo "  ! $REGISTRY/$repo does not exist — pushing would create a new repository" >&2
      problems=$((problems + 1))
    elif tag_exists "$repo" "$TAG"; then
      echo "  ! $REGISTRY/$repo:$TAG already exists and would be overwritten" >&2
      problems=$((problems + 1))
    else
      echo "  ok $REGISTRY/$repo:$TAG is new in an existing repository"
    fi
  done
  if [[ $problems -gt 0 && "${FORCE:-0}" -ne 1 ]]; then
    echo >&2
    echo "Refusing to push. Choose a tag that is free (--tag), or pass --force to overwrite." >&2
    exit 1
  fi
  docker info 2>/dev/null | grep -q '^ *Username:' || {
    echo "Not logged in to Docker Hub. Run: docker login" >&2; exit 1; }
  echo
fi

for entry in "${JAVA_SERVICES[@]}"; do
  IFS=: read -r name repo <<< "$entry"
  image="$REGISTRY/global-bank-$name:$TAG"
  echo "==> $image  (from $repo)"
  if [[ $FROM_JARS -eq 1 ]]; then
    # Compile natively first; the jar is then identical for every platform.
    ( cd "$FLEET/$repo" && mvn -B -q clean package -DskipTests )
    DOCKERFILE="$PLATFORM/k8s/Dockerfile.jar"
  else
    DOCKERFILE="$PLATFORM/k8s/Dockerfile.service"
  fi

  if [[ $PUSH -eq 1 ]]; then
    docker buildx build --builder "$BUILDER" --platform "$PLATFORMS" \
      -f "$DOCKERFILE" -t "$image" --push "$FLEET/$repo"
  else
    # Multi-platform results cannot be loaded into the local image store, so a
    # non-push build produces the host architecture only.
    docker build -f "$DOCKERFILE" -t "$image" "$FLEET/$repo"
  fi
done

# The frontend keeps its own Dockerfile: it is a multi-stage node+nginx build
# specific to that app, not the shared JRE packaging above.
image="$REGISTRY/global-bank-frontend:$TAG"
echo "==> $image  (from global-bank-frontend)"
if [[ $PUSH -eq 1 ]]; then
  docker buildx build --builder "$BUILDER" --platform "$PLATFORMS" \
    -t "$image" --push "$FLEET/global-bank-frontend"
else
  docker build -t "$image" "$FLEET/global-bank-frontend"
fi

echo
echo "Built at tag $TAG. Deploy with: ./scripts/deploy-k8s.sh"
