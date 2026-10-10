# Immutable beta release

Initial version: `0.1.0-beta.1`. Source repository: `aetherplatform/aether-elixir`.
Hex package: `aether_sdk`. Intended initial Hex maintainer: `xhehdy`.

This source remains unreleased until every gate below passes. A Hex account
exists; local publisher authentication and a publication credential are still
required. Kerma adoption follows the verified release and is not part of it.

## Prepare the reviewed source

1. Run `bash scripts/certify.sh` on supported Elixir/OTP combinations. CI uses
   the same commands in the monorepo and standalone export. Review the Hex tar,
   independent Mix consumer, generated coverage, tests and documentation.
2. Export with `bash scripts/export-public-repository.sh EMPTY_DIRECTORY`.
   This includes only the SDK source, public contracts, tests, examples,
   documentation and release tooling. Review the standalone diff before push.
3. Use selective subsystem commits. The final release commit must pass the
   standalone matrix before publication. Do not amend an already published
   tag or replace a package version.

## Hosted acceptance

Configure the existing sandbox variables for token URL, Identity URL,
Events/Notifications/Storage/Webhooks URLs and audiences, namespace ID, client
ID and client secret. `scripts/hosted-acceptance.exs` consumes the
`AETHER_SDK_SANDBOX_*` names used by the existing SDKs. Keep secrets in the
protected GitHub environment or a local secret manager; do not commit them.

Run the inspected package from an independent Mix consumer and execute:

```sh
mix run path/to/aether-elixir/scripts/hosted-acceptance.exs
```

The script checks discovery and keys, Events catalog, Notifications templates,
Webhooks subscriptions, and Storage upload/availability/download/delete.
It creates a uniquely named sandbox object and deletes it after verification.
Use a disposable proof namespace. If upload completion succeeds but
availability fails, inspect and remove any residual object before recording
acceptance. Source and package tests alone do not satisfy this gate.

With a controlled recipient and approved registered test client, also exercise:

- Hosted email sign-in: discovery, PKCE/state, exact callback validation,
  authorization-code exchange and authenticated userinfo.
- Passwordless email: explicit send, verify, required hosted or approved custom
  completion, exchange and userinfo. Include denial and registration/consent
  cases for the selected client policy.
- SMS delivery when a configured provider is available. Otherwise record
  delivery as unverified; contract-tested SMS support remains in the SDK.

Follow `guides/identity.md` using the **packaged SDK**, not an unreviewed working
tree. Capture only stage results, source commit, package SHA-256, environment
and reviewer. Do not retain recipient addresses, OTPs, continuation URLs,
authorization codes, tokens or callback URLs in evidence or logs.

Set `AETHER_ELIXIR_EMAIL_ACCEPTANCE_JSON` in the protected release environment
to the reviewed result, binding it to the exact package and source:

```json
{
  "source_commit": "FULL_RELEASE_COMMIT",
  "package_sha256": "SHA256_OF_HEX_TAR",
  "oauth_email_callback_exchange_userinfo": true,
  "passwordless_email_completion_exchange_userinfo": true,
  "sms_delivery": "unverified",
  "reviewed_by": "MAINTAINER_USERNAME"
}
```

`verify-email-acceptance.exs` fails closed when the evidence is absent or stale.
The reviewer must check the actual journey record before approving release;
the JSON alone is not proof that a journey ran.

## Publisher setup and publication

Authenticate the maintainer securely with `mix hex.user auth` in a local
terminal. Verify `mix hex.user whoami` reports `xhehdy`. Never paste a password,
Hex API key or local Hex config into chat or a commit. Recheck package name
availability immediately before the first publication.

Create a narrowly scoped Hex publication credential for `aether_sdk` using
Hex's supported key permissions. Store it as `HEX_API_KEY` in the GitHub
`hex-publish` environment. Require a maintainer reviewer and restrict deployment
to the protected default branch. Keep sandbox credentials in `sdk-sandbox`;
that environment also requires approval before hosted writes and email sends.

Run the standalone **Publish Elixir beta** workflow from the reviewed main
commit. It runs certification, executes the five-platform hosted proof through
an independently unpacked package, verifies controlled email evidence, and
publishes the package and HexDocs. Publication is followed by the immutable
`v0.1.0-beta.1` tag and GitHub prerelease.

Recover partial publication by comparing the existing Hex tar SHA-256 to the
local reviewed tar. If identical, complete missing HexDocs/tag/prerelease
steps. If a published artifact or existing tag points elsewhere, stop and use
a new version after review; do not overwrite it. Do not delete or republish
a version to make release automation pass.

Finally install the published exact version in a new external Mix project,
rerun the five-platform hosted journey using `bash scripts/test-published.sh
0.1.0-beta.1`, and inspect the rendered HexDocs. The workflow also runs this
external consumer check after publication.
Only then update the docs site and README to advertise Hex installation.
Record Kerma adoption as the next task against that immutable version.

## Current pending gates

- Hosted sandbox endpoint was unreachable during preparation on 2026-10-10.
- Controlled email OAuth/passwordless proof with the packaged SDK is pending.
- SMS hosted delivery is unverified.
- Hex authentication, scoped credential, public publication and external
  published-package verification are pending.
