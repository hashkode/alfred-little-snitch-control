---
type: decision
title: "Secret scanning: gitleaks, not a scanner bundled in the linter image"
description: The three scanners the MegaLinter flavor bundles were measured and each detects less; revisit if the image gains gitleaks or trufflehog stops running verified-only.
tags: [ci, secrets, megalinter, gitleaks]
sources:
  - { name: "Measured against a fixture through MegaLinter's own cupcake image", credibility: verified-firsthand }
  - { name: "MegaLinter repository descriptor, cli_lint_extra_args for trufflehog", credibility: documented }
verified: true
verified_on: 2026-08-22
stale_after: 2027-02-22
status: active
---

# Secret scanning: gitleaks, not a scanner bundled in the linter image

## Decision

Secret scanning runs as a separate gitleaks container in `.github/workflows/ci.yml`, not as a
MegaLinter linter — accepting a second image and a digest Dependabot cannot track.

## Why

No MegaLinter flavor ships `REPOSITORY_GITLEAKS`, but the `cupcake` flavor already bundles three
other secret scanners, so enabling one and dropping the extra container looked free. All three
were measured against a fixture holding an RSA private key, an AWS access key id and an AWS
secret key, run through MegaLinter's own image so each got the configuration CI would give it:

| scanner | private key | AWS key id | AWS secret | total |
| --- | --- | --- | --- | --- |
| gitleaks | yes | yes | yes | 3/3 |
| betterleaks | yes | yes | no | 2/3 |
| secretlint | yes | no | yes | 2/3 |
| trufflehog | no | no | no | 0/3 |

Two findings decided it:

- **trufflehog reported success** on a repository containing a private key. MegaLinter invokes it
  with `--only-verified`, so it reports only credentials it can validate against a live provider
  — which excludes most of what a pre-merge gate exists to catch.
- **betterleaks and secretlint scan the working tree** (`resource: fs.content`). gitleaks scans
  git history, so a secret committed and later deleted stays visible to gitleaks alone.

## Consequences

- A second container image, pinned by digest in an `env:` block where Dependabot's
  `github-actions` ecosystem cannot see it. Tracked by #31.
- `gitleaks detect --source` fails open: when git refuses the repository it reports
  `0 commits scanned / no leaks found` and exits 0. CI asserts the scan covered commits, because
  a clean pass is otherwise not evidence.

## Re-check triggers

- The MegaLinter image gains `REPOSITORY_GITLEAKS`.
- MegaLinter stops passing `--only-verified` to trufflehog.
- Any bundled scanner gains git-history scanning.
- gitleaks changes its licence terms for the container image.
