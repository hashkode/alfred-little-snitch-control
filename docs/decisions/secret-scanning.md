# Secret scanning: why gitleaks, not a bundled linter

**Decided** 2026-08-22 · **Re-check** when the linter image is upgraded, or 2027-02-22

## Decision

Secret scanning runs as a separate gitleaks container in `.github/workflows/ci.yml`, not as a
MegaLinter linter, even though that means a second image and a digest Dependabot cannot track
(#31).

## Why

No MegaLinter flavor ships `REPOSITORY_GITLEAKS`. The `cupcake` flavor does bundle three other
secret scanners, so the obvious move was to enable one and drop the extra container. All three
were measured against a fixture holding an RSA private key, an AWS access key id and an AWS
secret key, run through MegaLinter's own image so each got the configuration CI would give it:

| scanner | private key | AWS key id | AWS secret | total |
| --- | --- | --- | --- | --- |
| gitleaks | yes | yes | yes | 3/3 |
| betterleaks | yes | yes | no | 2/3 |
| secretlint | yes | no | yes | 2/3 |
| trufflehog | no | no | no | 0/3 |

Two findings decided it:

- **trufflehog reported success** on a repository containing a private key. MegaLinter invokes
  it with `--only-verified`, so it reports only credentials it can validate against a live
  provider — which excludes most of what a pre-merge gate needs to catch.
- **betterleaks and secretlint scan the working tree** (`resource: fs.content`); gitleaks scans
  git history. A secret committed and later deleted stays visible to gitleaks alone.

## Consequences

- A second container image, pinned by digest, outside Dependabot's reach — tracked in #31.
- `gitleaks detect --source` fails open: when git refuses the repository it reports
  `0 commits scanned / no leaks found` and exits 0. CI asserts the scan covered commits.

## Re-check triggers

Revisit if the linter image gains `REPOSITORY_GITLEAKS`, if MegaLinter stops passing
`--only-verified` to trufflehog, or if a bundled scanner gains git-history scanning.
