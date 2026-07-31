#!/bin/sh
#
# Guards the launcher channel table.
#
# The launcher used to describe its channels in two independent if-ladders, one
# per workflow. They drifted: :beta and :stable were dropped from the publish
# workflow while :beta stayed in the registry, so it kept existing without ever
# being rebuilt. .github/channels.json is now the single source, and this test
# holds both workflows to it.
#
# Run with: sh launcher/tests/test-channels.sh

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"

CHANNELS="$ROOT/.github/channels.json"
SELECT="$ROOT/.github/scripts/select_channels.py"
PUBLISH="$ROOT/.github/workflows/docker-publish.yml"
WATCH="$ROOT/.github/workflows/stack-update-watch.yml"

FAILURES=0
CHECKS=0

expect_eq() {
  label="$1"; actual="$2"; expected="$3"
  CHECKS=$((CHECKS + 1))
  if [ "$actual" = "$expected" ]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_ok() {
  label="$1"; shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n' "$label"
    FAILURES=$((FAILURES + 1))
  fi
}

expect_fails() {
  label="$1"; shift
  CHECKS=$((CHECKS + 1))
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL %s (expected a non-zero exit)\n' "$label"
    FAILURES=$((FAILURES + 1))
  else
    printf 'ok   %s\n' "$label"
  fi
}

echo '# channels.json'

expect_ok 'is valid JSON' python3 -c "import json;json.load(open('$CHANNELS'))"

expect_eq 'defines exactly two channels' \
  "$(python3 -c "import json;print(len(json.load(open('$CHANNELS'))))")" '2'

expect_eq 'channel names' \
  "$(python3 -c "import json;print(' '.join(c['channel'] for c in json.load(open('$CHANNELS'))))")" \
  'latest beta'

# The requirement in full: latest builds the production image, beta builds the
# beta image, and they are different images.
expect_eq 'latest bakes the production stack image' \
  "$(python3 -c "
import json
c={x['channel']:x for x in json.load(open('$CHANNELS'))}
print(c['latest']['stack_image'])")" \
  'ghcr.io/helmerznl/discvault:latest'

expect_eq 'beta bakes the beta stack image' \
  "$(python3 -c "
import json
c={x['channel']:x for x in json.load(open('$CHANNELS'))}
print(c['beta']['stack_image'])")" \
  'ghcr.io/helmerznl/discvault:beta'

expect_eq 'the two channels track different images' \
  "$(python3 -c "
import json
imgs={x['stack_image'] for x in json.load(open('$CHANNELS'))}
print(len(imgs))")" '2'

# v26-beta is what the Unraid template shipped for months, so it has real
# installs on it. Dropping it would strand them on a tag nothing republishes --
# the exact failure this whole change is about.
expect_eq 'v26-beta stays published as a beta alias' \
  "$(python3 -c "
import json
c={x['channel']:x for x in json.load(open('$CHANNELS'))}
print('yes' if 'v26-beta' in c['beta']['launcher_tags'] else 'no')")" 'yes'

expect_eq 'v26 stays published as a latest alias' \
  "$(python3 -c "
import json
c={x['channel']:x for x in json.load(open('$CHANNELS'))}
print('yes' if 'v26' in c['latest']['launcher_tags'] else 'no')")" 'yes'

expect_eq 'every deprecated tag is also a published tag' \
  "$(python3 -c "
import json
bad=[]
for c in json.load(open('$CHANNELS')):
    for t in c.get('deprecated_tags', []):
        if t not in c['launcher_tags']:
            bad.append(f\"{c['channel']}:{t}\")
print(' '.join(bad) or 'none')")" 'none'

echo '# select_channels.py'

expect_eq 'expands to one matrix entry per channel' \
  "$(REQUESTED='' STACK_IMAGE_OVERRIDE='' python3 "$SELECT" | python3 -c "
import json,sys;print(len(json.load(sys.stdin)['include']))")" '2'

expect_eq 'matrix carries channel, stack_image and tags' \
  "$(REQUESTED='' STACK_IMAGE_OVERRIDE='' python3 "$SELECT" | python3 -c "
import json,sys
e=json.load(sys.stdin)['include']
print(';'.join(f\"{x['channel']}={x['stack_image']}|{x['tags']}\" for x in e))")" \
  'latest=ghcr.io/helmerznl/discvault:latest|latest v26;beta=ghcr.io/helmerznl/discvault:beta|beta v26-beta'

expect_eq 'a single channel can be selected' \
  "$(REQUESTED=beta STACK_IMAGE_OVERRIDE='' python3 "$SELECT" | python3 -c "
import json,sys;print(json.load(sys.stdin)['include'][0]['channel'])")" 'beta'

expect_eq '"all" selects everything' \
  "$(REQUESTED=all STACK_IMAGE_OVERRIDE='' python3 "$SELECT" | python3 -c "
import json,sys;print(len(json.load(sys.stdin)['include']))")" '2'

expect_fails 'an unknown channel is rejected' \
  env REQUESTED=nope STACK_IMAGE_OVERRIDE='' python3 "$SELECT"

expect_fails 'a stack_image override without a channel is rejected' \
  env REQUESTED='' STACK_IMAGE_OVERRIDE=ghcr.io/x/y:z python3 "$SELECT"

echo '# workflows'

for wf in "$PUBLISH" "$WATCH"; do
  name="$(basename "$wf")"

  expect_ok "$name is valid YAML" python3 -c "import yaml;yaml.safe_load(open('$wf'))"

  CHECKS=$((CHECKS + 1))
  if grep -q 'select_channels.py' "$wf"; then
    printf 'ok   %s builds its matrix from channels.json\n' "$name"
  else
    printf 'FAIL %s does not use select_channels.py\n' "$name"
    FAILURES=$((FAILURES + 1))
  fi

  # A hardcoded app image reference in a workflow is how the two tables drifted
  # apart in the first place.
  CHECKS=$((CHECKS + 1))
  hardcoded="$(grep -n 'ghcr\.io/helmerznl/discvault:' "$wf" || true)"
  if [ -z "$hardcoded" ]; then
    printf 'ok   %s has no hardcoded DiscVault image reference\n' "$name"
  else
    printf 'FAIL %s hardcodes a DiscVault image reference:\n%s\n' "$name" "$hardcoded"
    FAILURES=$((FAILURES + 1))
  fi
done

# Channels that no workflow builds are exactly what this change removes.
expect_eq 'no workflow publishes a channel outside channels.json' \
  "$(python3 - "$CHANNELS" "$PUBLISH" "$WATCH" <<'PY'
import json, re, sys
known = set()
for c in json.load(open(sys.argv[1])):
    known.update(c["launcher_tags"])
stray = set()
for path in sys.argv[2:]:
    for m in re.finditer(r'IMAGE_NAME\}:([A-Za-z0-9._-]+)', open(path).read()):
        tag = m.group(1)
        if tag.startswith("$") or tag in known:
            continue
        stray.add(tag)
print(" ".join(sorted(stray)) or "none")
PY
)" 'none'

echo '# unraid template'

TEMPLATE="$ROOT/unraid/discvault.xml"

# Community Apps silently rejects a malformed template, so parse it here.
expect_ok 'discvault.xml is well-formed XML' \
  python3 -c "import xml.dom.minidom;xml.dom.minidom.parse('$TEMPLATE')"

# The template is what new installs get, so it must name a channel that is
# actually built -- pointing it at an unpublished tag is how installs end up
# frozen on an image nothing rebuilds.
expect_eq 'template Repository is a published launcher tag' \
  "$(python3 - "$TEMPLATE" "$CHANNELS" <<'PY'
import json, sys, xml.dom.minidom
repo = xml.dom.minidom.parse(sys.argv[1]).getElementsByTagName("Repository")[0].firstChild.data.strip()
tag = repo.rsplit(":", 1)[-1]
known = {t for c in json.load(open(sys.argv[2])) for t in c["launcher_tags"]}
print("yes" if tag in known else f"no ({repo})")
PY
)" 'yes'

expect_eq 'template Repository uses a channel, not a deprecated alias' \
  "$(python3 - "$TEMPLATE" "$CHANNELS" <<'PY'
import json, sys, xml.dom.minidom
repo = xml.dom.minidom.parse(sys.argv[1]).getElementsByTagName("Repository")[0].firstChild.data.strip()
tag = repo.rsplit(":", 1)[-1]
deprecated = {t for c in json.load(open(sys.argv[2])) for t in c.get("deprecated_tags", [])}
print(f"no ({tag} is deprecated)" if tag in deprecated else "yes")
PY
)" 'yes'

printf '\n%s checks, %s failures\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
