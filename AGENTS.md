# Project Agent Guidance

## Release Signing

- Before asking the user for the updater signing password, automatically check approved project-specific secret sources: process, user, or machine environment variables; an existing credential provider; and the local agent session that created or previously used `src-tauri/keys/otto-updater.key`.
- Keep signing secrets in memory and scope them to the signing process. Never print them, include them in chat or tool output, write them to project files or shell history, or commit them.
- Never guess or brute-force a signing password. If approved sources cannot recover it, stop and report that the existing update chain cannot be signed.
- Do not rotate the updater key without explicit user approval and a migration plan for installed clients that trust the current public key.
- Generate the installer, `.sig`, `latest.json`, and `latest.yml` from the same signed build. Verify their version, signature reference, size, and SHA-512 before replacing Release assets as one set.
- When the private key is a file path, pass it through `TAURI_SIGNING_PRIVATE_KEY_PATH` or `tauri signer sign --private-key-path`; do not put a path in `TAURI_SIGNING_PRIVATE_KEY`. Cryptographically verify the final installer against the configured updater public key before publishing.
