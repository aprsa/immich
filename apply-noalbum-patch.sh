#!/usr/bin/env bash
#
# Build the patched immich-server image and copy it to the NAS.
# Deployment itself is manual — see PATCH.md.
#
# Lives in the repo root on the `noalbum` branch. The release version is read
# from the nearest upstream tag below HEAD, so it stays correct after a rebase.
#
# Usage: ./apply-noalbum-patch.sh
#
set -euo pipefail

NAS_HOST="${NAS_HOST:-andrej@storage}"
NAS_PATH="${NAS_PATH:-/volume1/docker}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# --- which release are we sitting on? ----------------------------------------

# Nearest release tag reachable from HEAD — i.e. the tag this branch is rebased
# on. Release candidates are excluded so a v3.4.0-rc.1 can't win over v3.3.4.
VERSION="$(git describe --tags --abbrev=0 --match='v[0-9]*' --exclude='*-rc*' HEAD 2>/dev/null || true)"

if [[ -z "$VERSION" ]]; then
  echo "Could not determine the base release tag." >&2
  echo "Fetch upstream tags first:  git fetch upstream --tags" >&2
  exit 1
fi

TAG="immich-server:${VERSION}-noalbum"
TARBALL="/tmp/immich-noalbum-${VERSION}.tar.gz"

say "Base release tag: ${VERSION}"

# --- sanity checks -----------------------------------------------------------

say "Checking working tree"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash first." >&2
  git status --short >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "noalbum" ]]; then
  echo "On branch '$BRANCH', expected 'noalbum'." >&2
  exit 1
fi

echo "Patch commits on top of ${VERSION}:"
git log --oneline "${VERSION}..HEAD"

# Source-level check that the patch is actually present. Cheap, and catches a
# rebase that dropped a commit.
for f in server/src/dtos/time-bucket.dto.ts \
         server/src/repositories/asset.repository.ts \
         packages/sdk/src/fetch-client.ts; do
  if ! grep -q isNotInAlbum "$f"; then
    echo "isNotInAlbum missing from $f — patch is incomplete." >&2
    exit 1
  fi
done

# Both timeline repository methods must carry the clause, not just one.
# If upstream rewrites this expression, this will false-alarm — go look rather
# than deleting the check.
if [[ "$(grep -c "selectFrom('album_asset').whereRef('assetId', '=', 'asset.id')" \
         server/src/repositories/asset.repository.ts)" -lt 2 ]]; then
  echo "Expected the NOT EXISTS clause in both getTimeBuckets and getTimeBucket." >&2
  exit 1
fi

# --- dev stack must be down --------------------------------------------------

if docker compose -f docker/docker-compose.dev.yml ps --quiet 2>/dev/null | grep -q .; then
  echo "Dev stack is running — bring it down first:" >&2
  echo "  docker compose -f docker/docker-compose.dev.yml down" >&2
  exit 1
fi

# --- build -------------------------------------------------------------------

say "Building (15-30 min; retry if mise fails on java@21.0.2)"
docker compose -f docker/docker-compose.prod.yml build immich-server

docker tag immich-server:latest "$TAG"
docker images | grep -- "${VERSION}-noalbum"

# --- verify the built image --------------------------------------------------

say "Verifying the parameter survived into the image"

# If SDK/spec regeneration silently failed during a rebase, the image still
# builds cleanly and the toggle just does nothing. Check inside the artifact.
SPEC_RC=0
SPEC_PARAMS="$(docker run --rm --entrypoint sh "$TAG" -c \
  'cat /usr/src/app/open-api/immich-openapi-specs.json 2>/dev/null || true' \
  | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(42)
spec = json.loads(raw)
params = spec["paths"]["/timeline/buckets"]["get"]["parameters"]
print(",".join(p["name"] for p in params))
' 2>/dev/null)" || SPEC_RC=$?

if [[ "$SPEC_RC" -eq 42 ]]; then
  echo "Spec file not bundled in the image; checking the SDK build instead."
  if ! docker run --rm --entrypoint sh "$TAG" -c \
      'grep -rl isNotInAlbum /usr/src/app/packages/sdk/build 2>/dev/null | head -1' \
      | grep -q .; then
    echo "isNotInAlbum not found in the image's SDK build — regeneration failed." >&2
    echo "Run: mise run //server:sync-open-api && mise run //:open-api-typescript" >&2
    exit 1
  fi
  echo "OK — found in the bundled SDK."
elif [[ "$SPEC_PARAMS" != *isNotInAlbum* ]]; then
  echo "isNotInAlbum missing from the image's spec: $SPEC_PARAMS" >&2
  echo "Run: mise run //server:sync-open-api && mise run //:open-api-typescript" >&2
  exit 1
else
  echo "OK — /timeline/buckets params: $SPEC_PARAMS"
fi

# --- ship --------------------------------------------------------------------

say "Saving to $TARBALL"
docker save "$TAG" | gzip > "$TARBALL"
ls -lh "$TARBALL"

say "Copying to ${NAS_HOST}:${NAS_PATH}"
scp -O "$TARBALL" "${NAS_HOST}:${NAS_PATH}/immich-noalbum.tar.gz"

cat <<EOF

$(printf '\033[1m')Built and shipped: ${TAG}$(printf '\033[0m')

Now deploy by hand (see PATCH.md):

  ssh ${NAS_HOST}
  cd ${NAS_PATH}/immich
  sudo docker exec -t immich_postgres pg_dumpall --clean --if-exists -U postgres \\
    | gzip > pre-patch-\$(date +%F).sql.gz
  sudo docker load < ${NAS_PATH}/immich-noalbum.tar.gz
  # edit docker-compose.yml:  image: ${TAG}
  sudo docker compose up -d immich-server
  sudo docker logs -f immich_server     # want: No schema drift detected

EOF
