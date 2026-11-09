#!/bin/bash
# Run by GitHub Actions only. The dedicated delivery branch owns downloads/.
set -euo pipefail
if [[ "${GITHUB_ACTIONS:-}" != true ]] || [[ "${GITHUB_REF_NAME:-}" != codex/macos-installer-download ]]; then
    echo 'This command only publishes on the GitHub Actions delivery branch.' >&2
    exit 2
fi

mkdir -p downloads
cp "$RUNNER_TEMP/PhotoSelect-build.log" downloads/build.log
if [[ -f .build/browser-layout.png ]]; then
    cp .build/browser-layout.png downloads/browser-layout.png
else
    rm -f downloads/browser-layout.png
fi
artifact="PhotoSelect-${PHOTOSELECT_VERSION}-${PHOTOSELECT_BUILD_NUMBER}-arm64"
filename="PhotoSelect-${PHOTOSELECT_VERSION}-arm64.dmg"
if [[ "$PACKAGE_OUTCOME" == success ]]; then
    cp "dist/$artifact/$artifact.dmg" "downloads/$filename"
    (cd downloads && shasum -a 256 "$filename" > SHA256SUMS)
else
    # Do not leave a previous installer looking like the result of a failed build.
    rm -f "downloads/$filename" downloads/SHA256SUMS
fi
python3 - <<'PY'
import json
import os
from pathlib import Path
result = {
    'outcome': os.environ['PACKAGE_OUTCOME'],
    'source_commit': os.environ['GITHUB_SHA'],
    'version': os.environ['PHOTOSELECT_VERSION'],
    'build_number': os.environ['PHOTOSELECT_BUILD_NUMBER'],
    'run_url': 'https://github.com/' + os.environ['GITHUB_REPOSITORY'] + '/actions/runs/' + os.environ['GITHUB_RUN_ID'],
}
Path('downloads/build-status.json').write_text(json.dumps(result, indent=2) + '\n')
PY
git add -- downloads
if git diff --cached --quiet; then exit 0; fi
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Save macOS installer build ${GITHUB_RUN_ID} [skip ci]"
git push origin "HEAD:refs/heads/$GITHUB_REF_NAME"
