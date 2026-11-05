#!/bin/bash
# Finder double-click entry point; keep the terminal open to show the result.
set -uo pipefail
repo_dir="$(cd "$(dirname "$0")" && pwd -P)"
status=0
/bin/bash "$repo_dir/scripts/package-macos.sh" || status=$?
if [[ "$status" -eq 0 ]]; then
    open "$repo_dir/dist"
else
    echo "설치 파일 생성에 실패했습니다 (종료 코드 $status). 위 오류를 확인하세요." >&2
fi
if [[ -t 0 ]]; then
    read -r -p 'Enter를 누르면 종료합니다. ' ignored || true
fi
exit "$status"
