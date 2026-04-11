#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 WORKSPACE_ROOT PROJECT_NAME [PROVIDER] [MODEL]" >&2
  echo "example: $0 /tmp/ashex-smoke DemoApp openai gpt-5.4" >&2
  exit 1
fi

WORKSPACE_ROOT="$1"
PROJECT_NAME="$2"
PROVIDER="${3:-openai}"
MODEL="${4:-gpt-5.4}"
APPROVAL_MODE="${ASHEX_SMOKE_APPROVAL_MODE:-trusted}"

mkdir -p "$WORKSPACE_ROOT"

run_ashex() {
  local prompt="$1"
  echo
  echo "==> $prompt"
  swift run ashex \
    --provider "$PROVIDER" \
    --model "$MODEL" \
    --workspace "$WORKSPACE_ROOT" \
    --approval-mode "$APPROVAL_MODE" \
    "$prompt"
}

run_ashex "Create a small SwiftPM command line project named $PROJECT_NAME in ./$PROJECT_NAME. Add a README.md explaining what it does and make sure the package builds."
run_ashex "Enhance ./$PROJECT_NAME with one more useful feature, update tests if needed, and validate with swift test if the package has tests or swift build otherwise."
run_ashex "Edit ./$PROJECT_NAME/README.md to add a short usage section with one realistic example command."
run_ashex "Initialize git in ./$PROJECT_NAME if needed, stage the project files, and create an initial commit with a concise message."

echo
echo "Smoke flow finished for $WORKSPACE_ROOT/$PROJECT_NAME"
