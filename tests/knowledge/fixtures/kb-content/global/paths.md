---
name: paths
description: d
metadata:
  type: reference
  verified: 2026-10-20
  evidence: tested
---
Missing: `~/omk-fixture-missing/x.txt`
Exists: `~/omk-fixture-present/y.txt`
Template: `~/<project>/z.txt` and `~/.claude/projects/*/memory` and `~/${NAME}/q` and `~/logs/YYYY-MM-DD.log`
Not a path: `ls ~/omk-fixture-missing`
