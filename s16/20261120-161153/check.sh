#!/bin/sh
# policy: every deploy must require approval
grep -q "^deploy: .*approval required" "$(dirname "$0")/plan.txt" \
  && echo "policy ok" || { echo "POLICY VIOLATED: deploy must require approval"; exit 1; }
