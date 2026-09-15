# Credentials pasted into a chat context — rotate, not ration

FACT — an OpenSSH private key for `ubuntu@129.213.177.56` (comment `oci-arm-server`, SHA256:HpoCySL5…)
and a GitHub PAT were pasted into this conversation.
FACT — `x-oauth-scopes` on that token: `admin:enterprise, admin:org, admin:org_hook, admin:repo_hook,
audit_log, codespace, copilot, delete_repo, gist, notifications, project, repo, user, workflow,
write:packages`. `delete_repo` + `repo` on 63 repos is total account compromise, not one server.
FACT — the key authenticated successfully as root-sudo-capable `ubuntu`.

DECISION: push nothing with the exposed token; the user reissues a fine-grained, repo-scoped one.
HYPOTHESIS (testable, unchecked): the token's `admin:org` scope exceeds anything in this plan.
  Test: reissue repo-only to `JoTalbot/hermes`, re-run the sync pipeline; if all steps pass, drop the wide token.
LESSON: pasted credentials are rotated, not "used carefully". Nothing in this repo or on the server
should be built assuming the old pair stays valid.
NOTE: this file records *classes* of secret and their scopes — never key material or token values.
