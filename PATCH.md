# noalbum patch — maintenance runbook

Adds an `isNotInAlbum` filter to the Immich timeline (the filter already exists
for search upstream; this exposes it on the timeline too) plus a toggle on the
photos page, persisted in localStorage.

Branch: `noalbum`, kept rebased on the upstream release tag the NAS runs.
Never branch from `main` — it carries unreleased migrations, and Immich applies
migrations automatically on startup with no down-path.

---

## What the patch touches

| File | Change |
|---|---|
| `server/src/dtos/time-bucket.dto.ts` | `isNotInAlbum` in `TimeBucketQueryBaseSchema` |
| `server/src/repositories/asset.repository.ts` | field on `TimeBucketOptions`; `NOT EXISTS` clause in **both** `getTimeBuckets` and `getTimeBucket` |
| `packages/sdk/src/fetch-client.ts` | generated — do not hand-edit |
| `open-api/immich-openapi-specs.json` | generated |
| `web/src/lib/stores/preferences.store.ts` | `timelineNotInAlbum` persisted store |
| `web/src/routes/(user)/photos/[[assetId=id]]/+page.svelte` | `SearchButton` toggle, `isNotInAlbum` in `options` |

Nothing in the web timeline manager needed changing: `TimelineManagerOptions`
derives from the SDK signature, both call sites spread the options object, and
`updateOptions` → `#init` clears `months` and `albumAssets` before refetching,
so toggling invalidates the bucket cache for free.

Both repository methods must carry the clause. Patch only `getTimeBucket` and
the grid filters while the scrubber counts don't — a confusing failure.

---

## Upgrading to a new release

```bash
cd ~/projects/immich
git fetch upstream --tags
git tag --list | tail -5          # pick the target, e.g. v3.3.4
git rebase v3.3.4 noalbum
```

**Expected conflict: `packages/sdk/src/fetch-client.ts`.** Upstream regenerates
it wholesale. Do not resolve by hand — take theirs and regenerate after the
server commits are applied:

```bash
git checkout --theirs packages/sdk/src/fetch-client.ts
git add packages/sdk/src/fetch-client.ts
git rebase --continue
mise run //server:sync-open-api
mise run //:open-api-typescript
git add -A && git commit --amend --no-edit    # fold into the sdk commit
```

Same applies to `open-api/immich-openapi-specs.json`.

If the server or web files conflict, read them — upstream may have refactored
the timeline query or the photos route, and the patch may need genuine rework.

---

## Verify locally before shipping

```bash
cd ~/projects/immich
docker compose -f docker/docker-compose.dev.yml up --build -d
```

Web on **:3000**, API on **:2283**. Seed it: create an account, upload ~8
photos, put 4 in an album, make an API key (avatar → Account Settings → API
Keys).

```bash
KEY=<key>
curl -s -H "x-api-key: $KEY" 'http://localhost:2283/api/timeline/buckets' \
  | python3 -c 'import sys,json; print(sum(b["count"] for b in json.load(sys.stdin)))'
curl -s -H "x-api-key: $KEY" 'http://localhost:2283/api/timeline/buckets?isNotInAlbum=true' \
  | python3 -c 'import sys,json; print(sum(b["count"] for b in json.load(sys.stdin)))'
```

Expect 8 then 4. Also check the per-bucket endpoint, which is the other code
path:

```bash
curl -s -H "x-api-key: $KEY" \
  'http://localhost:2283/api/timeline/bucket?timeBucket=YYYY-MM-01&isNotInAlbum=true' \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["id"]))'
```

Then in the browser: toggle flips the count, the scrubber shrinks too, and the
setting survives a reload.

Bring the dev stack **down** before building — concurrent writes to `dist/` and
`node_modules` caused trouble once.

---

## Build and ship

```bash
./build-noalbum.sh
```

No arguments — the version comes from `git describe`, i.e. the nearest upstream
release tag below HEAD, so it tracks the rebase automatically. The script
refuses to run on a dirty tree, off the `noalbum` branch, or with the dev stack
up; checks the patch is present in all three source files and that the
`NOT EXISTS` clause appears twice; builds; verifies `isNotInAlbum` survived into
the image; tags it `immich-server:<version>-noalbum`; and copies the tarball to
the NAS with `scp -O`.

Override the destination with `NAS_HOST=` / `NAS_PATH=` if needed.

The spec check matters: if SDK regeneration silently failed during a rebase, the
image builds fine and the toggle does nothing. Don't skip it.

---

## Deploy on the NAS

```bash
ssh andrej@storage
cd /volume1/docker/immich

# 1. dump the database (~730 MB gzipped; metadata only, not media)
sudo docker exec -t immich_postgres pg_dumpall --clean --if-exists -U postgres \
  | gzip > pre-patch-$(date +%F).sql.gz
ls -lh pre-patch-*.sql.gz

# 2. load the image
sudo docker load < /volume1/docker/immich-noalbum.tar.gz
sudo docker images | grep noalbum

# 3. point compose at it
cp docker-compose.yml docker-compose.yml.bak
#   in the immich-server service:
#     # image: ghcr.io/immich-app/immich-server:release
#     image: immich-server:v3.3.4-noalbum

# 4. restart and watch
sudo docker compose up -d immich-server
sudo docker logs -f immich_server
```

Wait for **`No schema drift detected`** from both the Api and Microservices
workers. The patch adds no migrations, so drift would mean something is wrong —
stop and investigate rather than pressing on.

Then load https://photos.prsa.us and flip the toggle.

### Rollback

```bash
# swap the commented image lines back, then
sudo docker compose up -d immich-server
```

Keep the previous tarball until the new one is proven. The database dump is the
deeper net; you shouldn't need it, since no migrations are involved.

---

## Gotchas

- **`mise install --locked` failing on `java@21.0.2` during the Docker build**
  is transient. Retry before investigating.
- **`scp` needs `-O`** (legacy protocol) for the NAS.
- **Don't `chown -R` the whole repo.** `docker/library/postgres` belongs to the
  container's postgres user (uid 999) and a recursive chown breaks the dev
  database. Scope it to `server/`, `web/`, `packages/`.
- **The dev stack runs as root** and leaves root-owned `node_modules` behind.
  `sudo chown -R $USER:$USER server web packages` if `pnpm install` hits EACCES.
- **mise supplies pnpm**; it needs `eval "$(mise activate bash)"` in `.bashrc`,
  or prefix with `mise exec --`.
- **`grep -c` counts matching lines, not occurrences.** The spec JSON packs
  several params per line. Query it with python instead:
  ```bash
  python3 -c "import json;print([x['name'] for x in json.load(open('open-api/immich-openapi-specs.json'))['paths']['/timeline/buckets']['get']['parameters']])"
  ```
- **The NAS no longer tracks `:release`.** Immich upgrades are manual now,
  security fixes included. Watch the release notes.
- **Locally built images report no version string** (`Initializing Immich` with
  no `v3.3.x`). Cosmetic; the API still reports it correctly.
