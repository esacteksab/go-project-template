#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Docker Hub API rate-limit (HTTP 429) handling
#
# The Hub JSON API (hub.docker.com/v2/...) applies request-based rate limits.
# This script avoids 429s by:
#   1. Filtering tags server-side with ?name=<version>- so we fetch a single
#      page instead of paginating the whole tag list.
#   2. Resolving the base image exactly once and reusing the result (no more
#      duplicate preflight + update lookups).
#   3. Optionally authenticating to raise the limit. Set DOCKERHUB_USERNAME and
#      DOCKERHUB_TOKEN (use a Personal Access Token as the token) to enable.
#   4. Retrying on 429/5xx with exponential backoff, honoring Retry-After.
#
# Note: the digest-resolution step uses `docker`, which hits the registry
# (registry-1.docker.io) and has its own pull limits. Run `docker login`
# beforehand to authenticate that path too.
# ---------------------------------------------------------------------------

readonly VERSION_INPUT="${1:-}"
readonly DOCKERFILE="Dockerfile"

# Populated by hub_authenticate (empty => anonymous Hub API access).
HUB_TOKEN=""

# Populated by resolve_base_image and reused by update_dockerfile_base_image.
RESOLVED_REPO=""
RESOLVED_TAG=""
RESOLVED_DIGEST=""
RESOLVED_STAGE_SUFFIX=""
RESOLVED_IMAGE_REF=""

log() {
  echo "[update-go-version] $*"
}

die() {
  echo "[update-go-version] ERROR: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Required file not found: $file"
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

validate_version() {
  [[ "$VERSION_INPUT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid Go version '$VERSION_INPUT'. Expected format: MAJOR.MINOR.PATCH"
}

replace_or_fail() {
  local file="$1"
  local match_regex="$2"
  local sed_expr="$3"

  grep -Eq "$match_regex" "$file" || die "Expected pattern not found in $file"
  sed -E -i "$sed_expr" "$file"
}

# ---------------------------------------------------------------------------
# Docker Hub API helpers
# ---------------------------------------------------------------------------

# Obtain a Hub JWT if credentials are provided. Stores it in HUB_TOKEN.
hub_authenticate() {
  if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_TOKEN:-}" ]]; then
    log "Authenticating to Docker Hub as ${DOCKERHUB_USERNAME}"
    local resp
    resp="$(curl -fsS \
      -H 'Content-Type: application/json' \
      -d "{\"username\": \"${DOCKERHUB_USERNAME}\", \"password\": \"${DOCKERHUB_TOKEN}\"}" \
      "https://hub.docker.com/v2/users/login" 2>/dev/null || true)"
    HUB_TOKEN="$(printf '%s' "$resp" | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
    [[ -n "$HUB_TOKEN" ]] || die "Docker Hub authentication failed (check DOCKERHUB_USERNAME / DOCKERHUB_TOKEN)"
    log "Docker Hub authentication succeeded"
  else
    log "No DOCKERHUB_USERNAME/DOCKERHUB_TOKEN set; using anonymous Hub API access"
  fi
}

# GET a Hub API URL, printing the response body on success. Retries on
# 429/5xx/transport errors with exponential backoff, honoring Retry-After.
# Dies after exhausting attempts.
hub_get() {
  local url="$1"
  local attempt=1
  local max_attempts="${HUB_MAX_ATTEMPTS:-6}"
  local delay=2
  local body_file headers_file http retry_after sleep_for

  while :; do
    body_file="$(mktemp)"
    headers_file="$(mktemp)"

    # No -f: we want to read the status code on HTTP errors. curl only exits
    # non-zero on transport failures, which we map to "000".
    http="$(curl -sS \
      -o "$body_file" \
      -D "$headers_file" \
      -w '%{http_code}' \
      -H 'Accept: application/json' \
      ${HUB_TOKEN:+-H "Authorization: Bearer ${HUB_TOKEN}"} \
      "$url" 2>/dev/null || echo "000")"
    # If authentication appears ignored, try changing "Bearer" above to "JWT".

    if [[ "$http" == "200" ]]; then
      cat "$body_file"
      rm -f "$body_file" "$headers_file"
      return 0
    fi

    if { [[ "$http" == "429" ]] || [[ "$http" == 5* ]] || [[ "$http" == "000" ]]; } && (( attempt < max_attempts )); then
      retry_after="$(grep -i '^Retry-After:' "$headers_file" 2>/dev/null | tail -n1 \
        | sed -E 's/^[Rr]etry-[Aa]fter:[[:space:]]*([0-9]+).*/\1/' | tr -d '\r')"
      if [[ "$retry_after" =~ ^[0-9]+$ ]]; then
        sleep_for="$retry_after"
      else
        sleep_for="$delay"
      fi
      log "Docker Hub API returned HTTP ${http}; retry ${attempt}/${max_attempts} after ${sleep_for}s"
      rm -f "$body_file" "$headers_file"
      sleep "$sleep_for"
      (( delay = delay * 2 > 60 ? 60 : delay * 2 ))
      (( attempt++ ))
      continue
    fi

    rm -f "$body_file" "$headers_file"
    die "Docker Hub request failed (HTTP ${http}): ${url}"
  done
}

update_known_version_files() {
  log "Updating Go version references in known files"

  replace_or_fail "go.mod" '^go [0-9]+\.[0-9]+\.[0-9]+$' "s/^go [0-9]+\.[0-9]+\.[0-9]+$/go ${VERSION_INPUT}/"
  replace_or_fail "go.tool.mod" '^go [0-9]+\.[0-9]+\.[0-9]+$' "s/^go [0-9]+\.[0-9]+\.[0-9]+$/go ${VERSION_INPUT}/"
  replace_or_fail ".golangci.yaml" '^[[:space:]]*go:[[:space:]]*"?[0-9]+\.[0-9]+(\.[0-9]+)?"?[[:space:]]*$' "s/^([[:space:]]*go:[[:space:]]*).*/\\1\"${VERSION_INPUT}\"/"

  require_file ".mise.toml"
  awk -v version="$VERSION_INPUT" '
    BEGIN { in_tools = 0; updated = 0 }
    {
      if ($0 ~ /^\[tools\][[:space:]]*$/) {
        in_tools = 1
        print
        next
      }
      if (in_tools && $0 ~ /^\[[^]]+\][[:space:]]*$/) {
        in_tools = 0
      }
      if (in_tools && !updated && $0 ~ /^[[:space:]]*(go|golang)[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$/) {
        sub(/"[^"]+"/, "\"" version "\"")
        updated = 1
      }
      print
    }
    END {
      if (!updated) {
        print "missing go/golang entry in [tools] section of .mise.toml; add one like: [tools] go = \"" version "\"" > "/dev/stderr"
        exit 1
      }
    }
  ' .mise.toml > .mise.toml.tmp && mv .mise.toml.tmp .mise.toml

  if [[ -f "mise.toml" ]]; then
    log "Updating optional mise.toml"
    sed -E -i "s/^([[:space:]]*(go|golang)[[:space:]]*=[[:space:]]*)\"[^\"]+\"[[:space:]]*$/\\1\"${VERSION_INPUT}\"/" mise.toml || true
  fi
}

extract_repo_and_stage_from_dockerfile() {
  local from_line
  from_line="$(awk '/^FROM[[:space:]]+/ { print; exit }' "$DOCKERFILE")"
  [[ -n "$from_line" ]] || die "No FROM line found in $DOCKERFILE"

  local image_ref
  image_ref="$(printf '%s\n' "$from_line" | sed -E 's/^FROM[[:space:]]+([^[:space:]]+).*/\1/')"
  local stage_suffix
  stage_suffix="$(printf '%s\n' "$from_line" | sed -nE 's/^FROM[[:space:]]+[^[:space:]]+([[:space:]]+AS[[:space:]]+.+)$/\1/p')"

  [[ "$image_ref" =~ ^([^@]+)@sha256:[a-f0-9]{64}$ ]] || die "Expected digest-pinned base image in $DOCKERFILE"
  local image_with_tag="${BASH_REMATCH[1]}"
  local repo="${image_with_tag%:*}"
  [[ "$repo" != "$image_with_tag" ]] || die "Unable to parse repo and tag from Dockerfile FROM line"

  printf '%s\t%s\n' "$repo" "$stage_suffix"
}

find_latest_dated_tag() {
  local repo="$1"
  local ns_repo="$repo"
  if [[ "$ns_repo" =~ ^docker\.io/(.+/.+)$ ]]; then
    ns_repo="${BASH_REMATCH[1]}"
  fi
  [[ "$ns_repo" =~ ^[^./]+/[^/]+$ ]] || die "Docker Hub lookup expects repo in namespace/name form, got: $repo"

  local namespace="${ns_repo%/*}"
  local repository="${ns_repo#*/}"

  # Filter server-side with name=<version>- so we fetch only the dated tags we
  # care about. This almost always fits in a single page and avoids the
  # pagination that was triggering HTTP 429. If the API ignores the filter, the
  # pagination loop below still works (just with more requests), each one
  # retried/authenticated via hub_get.
  local api_url="https://hub.docker.com/v2/namespaces/${namespace}/repositories/${repository}/tags?page_size=100&name=${VERSION_INPUT}-"
  local matches=""

  while [[ -n "$api_url" && "$api_url" != "null" ]]; do
    # Declare and assign separately so a failure in hub_get (die -> exit in the
    # command-substitution subshell) is not masked by `local` returning 0.
    local body
    body="$(hub_get "$api_url")"

    local page
    page="$(printf '%s\n' "$body" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/^"name"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' | grep -E "^${VERSION_INPUT}-[0-9]{4}-[0-9]{2}-[0-9]{2}$" || true)"
    if [[ -n "$page" ]]; then
      matches+=$'\n'
      matches+="$page"
    fi

    api_url="$(printf '%s\n' "$body" | tr -d '\n' | sed -nE 's/.*"next"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p')"
    [[ -n "$api_url" ]] || api_url="null"
  done

  local latest
  latest="$(printf '%s\n' "$matches" | sed '/^[[:space:]]*$/d' | sort -u | tail -n 1)"
  [[ -n "$latest" ]] || die "No Docker Hub dated tag found for ${repo} with version ${VERSION_INPUT}"
  printf '%s\n' "$latest"
}

resolve_digest_with_docker() {
  local image_ref="$1"
  local digest=""

  local inspect_output
  inspect_output="$(docker buildx imagetools inspect "$image_ref" 2>/dev/null || true)"
  if [[ "$inspect_output" =~ Digest:[[:space:]]*(sha256:[a-f0-9]{64}) ]]; then
    digest="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$digest" ]]; then
    docker pull "$image_ref" >/dev/null 2>&1 || true
    local repo_digest
    repo_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$image_ref" 2>/dev/null || true)"
    if [[ "$repo_digest" == *@sha256:* ]]; then
      digest="${repo_digest##*@}"
    fi
  fi

  [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Failed to resolve digest for $image_ref via docker"
  printf '%s\n' "$digest"
}

# Resolve the base image (repo, latest dated tag, digest, stage suffix) exactly
# once, before any files are mutated. Results are cached in RESOLVED_* globals
# and reused by update_dockerfile_base_image. Running this before mutation also
# preserves the original fail-early behavior without leaving partial edits.
resolve_base_image() {
  local parsed
  parsed="$(extract_repo_and_stage_from_dockerfile)"
  RESOLVED_REPO="${parsed%%$'\t'*}"
  RESOLVED_STAGE_SUFFIX="${parsed#*$'\t'}"

  RESOLVED_TAG="$(find_latest_dated_tag "$RESOLVED_REPO")"
  RESOLVED_IMAGE_REF="${RESOLVED_REPO}:${RESOLVED_TAG}"
  log "Resolving digest for $RESOLVED_IMAGE_REF"
  RESOLVED_DIGEST="$(resolve_digest_with_docker "$RESOLVED_IMAGE_REF")"
}

update_dockerfile_base_image() {
  [[ -n "$RESOLVED_IMAGE_REF" && -n "$RESOLVED_DIGEST" ]] || die "Base image not resolved; call resolve_base_image first"

  local replacement="FROM ${RESOLVED_IMAGE_REF}@${RESOLVED_DIGEST}${RESOLVED_STAGE_SUFFIX}"
  awk -v line="$replacement" 'BEGIN { done = 0 } { if (!done && $0 ~ /^FROM[[:space:]]+/) { print line; done = 1 } else { print } } END { if (!done) { exit 1 } }' "$DOCKERFILE" > "$DOCKERFILE.tmp" && mv "$DOCKERFILE.tmp" "$DOCKERFILE"
}

show_detected_go_version_refs() {
  log "Scanning tracked files for Go version keys"
  grep -HnE '(^go [0-9]+\.[0-9]+\.[0-9]+$|^[[:space:]]*go:[[:space:]]*"?[0-9]+\.[0-9]+(\.[0-9]+)?"?[[:space:]]*$|^[[:space:]]*(go|golang)[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$)' go.mod go.tool.mod .golangci.yaml .mise.toml 2>/dev/null || true
  if [[ -f "mise.toml" ]]; then
    grep -HnE '^[[:space:]]*(go|golang)[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$' mise.toml 2>/dev/null || true
  fi
}

main() {
  validate_version
  require_file "go.mod"
  require_file "go.tool.mod"
  require_file ".golangci.yaml"
  require_file ".mise.toml"
  require_file "$DOCKERFILE"
  require_cmd grep
  require_cmd sed
  require_cmd awk
  require_cmd curl
  require_cmd docker
  require_cmd mktemp

  hub_authenticate

  # Single resolution before mutating files (was: preflight + a duplicate
  # lookup inside update_dockerfile_base_image).
  resolve_base_image

  show_detected_go_version_refs
  update_known_version_files
  update_dockerfile_base_image
  log "Done. Updated Go references to $VERSION_INPUT"
}

main
