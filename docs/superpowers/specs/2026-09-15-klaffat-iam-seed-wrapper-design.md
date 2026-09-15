# Klaffat IAM Seed Wrapper Design

## Problem

Klaffat's IAM seed script requires AWS CLI credentials. Dellan keeps those
credentials root-only under agenix, while the script is currently invoked from
an unprivileged checkout where `aws` is not installed. Existing privileged
wrappers expose only OpenTofu and publishing operations, so the bootstrap
runbook has no safe executable path.

## Design

Add one narrow system command:

```text
sudo klaffat-iam-seed [--apply | --verify]
```

No argument preserves the seed script's dry-run default. The wrapper accepts
only those three exact forms, requires root, and remains password-gated by the
existing command-scoped sudo policy.

The wrapper refreshes the existing root-owned bare Klaffat mirror, resolves
remote `main`, archives only `deploy/iam/` and
`deploy/scripts/seed-aws-ci-identities.sh` into a fresh root-only directory,
and verifies extracted file hashes against the resolved commit before running
anything. It then reads the existing root-only agenix AWS credentials into its
own environment and invokes the reviewed seed script with packaged `aws`,
`jq`, and shell dependencies on `PATH`. Secrets are never accepted as
arguments or copied into a user-readable file. Both child output streams stay
inside the root-only temporary directory and are deleted on exit, so even a
failing or compromised seed script cannot print credential values through the
wrapper. Only wrapper-authored provenance and a validated public report are
exposed to the caller.

After successful `--apply` or `--verify`, the wrapper atomically publishes
`/run/klaffat-iam-seed/report.env` as root-owned mode 0644. It contains only
the reviewed Git revision and three nonsecret role ARNs. A mutation or verify
attempt removes any stale report before starting and leaves no report on
failure. This lets the unprivileged agent configure GitHub repository variables
without copying values through the founder or granting root access to GitHub.

## Alternatives Rejected

- Extend `klaffat-publish`: smaller diff, but combines unrelated publishing
  and IAM authority behind a confusing interface.
- Use a root shell or `sudo -E` from the founder checkout: trusts user-owned Git
  configuration and files as root, and creates avoidable credential-handling
  paths.

## Failure Behavior

Invalid arguments, non-root invocation, mirror or archive verification
failure, missing credentials, missing script, and any seed-script failure all
fail closed with non-zero status. Cleanup removes only the wrapper's fresh
temporary extraction directory and incomplete report; failed mutation or
verification cannot leave stale success evidence.

## Verification

Extend `vm-klaffat-infra` test-first. Prove command installation, root-only and
argument gates, both sudo path spellings, reviewed-source provenance, dry-run
execution through a fake AWS CLI, exact `--apply`/`--verify` forwarding,
failure propagation even when caller output is unwritable, quarantine of both
child output streams, and absence of fixture credential values from output.
Tests also prove successful apply/verify publishes an exact nonsecret report,
dry-run does not, and failure removes stale report state.
Then build the lane and invoke the generated wrapper in the interactive feature
VM.
