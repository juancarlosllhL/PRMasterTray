#!/usr/bin/env bash
# Writes a compare-shaped response with 300 files and about 50,000 diff lines.
# Usage: scripts/large-diff-fixture.sh [output.json]
set -euo pipefail
out="${1:-/tmp/large-diff.json}"

python3 - "$out" <<'EOF'
import json, sys

files = []
for f in range(300):
    lines = []
    for i in range(55):
        lines.append(f" let context{i} = compute(\"value {i}\") // keep")
    for i in range(55):
        lines.append(f"-    return legacy{i}(input, options: .default)")
    for i in range(57):
        lines.append(f"+    return modern{i}(input, options: [.fast, .safe]) /* updated */")
    old, new = 110, 112
    patch = f"@@ -1,{old} +1,{new} @@ struct Widget{f} {{\n" + "\n".join(lines)
    files.append({
        "filename": f"Sources/Module{f // 30}/Widget{f}.swift",
        "status": "modified", "additions": 57, "deletions": 55, "changes": 112, "patch": patch,
    })

json.dump({"status": "ahead", "ahead_by": 1, "behind_by": 0, "files": files}, open(sys.argv[1], "w"))
print(f"{sys.argv[1]}: {len(files)} files, {sum(167 for _ in files)} lines")
EOF
