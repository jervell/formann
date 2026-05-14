# Vendored files

## `retrieve-secret.sh`

Verbatim copy. Do not edit in place — re-vendor from source instead.

| Field | Value |
|-------|-------|
| Source repo | `arne/claude-code-api-key-setup` |
| Source path | `/Users/acjervell/dev/claude-code-api-key-setup/retrieve-secret.sh` |
| Source commit | `2aa028b5002cdcb827ea363709e5c5c77e2e13d8` |
| Source last touched | 2025-11-24 |
| Vendored on | 2026-05-05 |

To re-sync after an upstream change:

```sh
cp /Users/acjervell/dev/claude-code-api-key-setup/retrieve-secret.sh \
   framework/runner/retrieve-secret.sh
chmod +x framework/runner/retrieve-secret.sh
diff /Users/acjervell/dev/claude-code-api-key-setup/retrieve-secret.sh \
     framework/runner/retrieve-secret.sh
# (no diff output = byte-identical, vendored copy is good)
```

Update the source-commit row above to reflect the new HEAD.
