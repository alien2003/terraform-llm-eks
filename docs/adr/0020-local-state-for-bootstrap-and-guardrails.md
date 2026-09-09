# 0020. Bootstrap and guardrails keep local Terraform state

Date: 2026-09-08

## Status

Accepted.

## Context

Three stacks exist: `infra/guardrails`, `infra/bootstrap` and `infra/cluster`. The obvious default is
that all three keep state in S3, in one bucket, behind one backend configuration.

That default is a circular dependency twice over.

`infra/bootstrap` is the stack that creates the state bucket. On a clean account the bucket does not
exist, so a bootstrap run configured to use it cannot initialise, cannot plan, and cannot create the
thing it needs in order to start. The usual workaround is to apply once with a local backend and
then migrate state into the bucket it just made. That works, and it means every future contributor
inherits a stack whose backend depends on a resource in its own state file, which is the kind of
thing that is fine until the day the bucket is deleted.

`infra/guardrails` fails the other way round. It is destroyed last, after everything else, because it
holds the budget, the kill Lambda, the sweeper schedule and the permission boundary that make the
rest of the project safe to run at all. If its state lived in the bootstrap bucket, the teardown
order would be: destroy cluster, destroy bootstrap (which deletes the bucket), then try to destroy
guardrails using a state file that no longer exists.

Both stacks are applied by hand a handful of times, by one person, never concurrently. The problems a
remote backend solves, shared access and locking between several operators or a CI runner, are
problems neither of these stacks has.

## Decision

`infra/guardrails` and `infra/bootstrap` keep local state. Neither has a `backend` block. The
`terraform.tfstate` file sits next to the configuration and is covered by the repository's
`.gitignore`.

`infra/cluster` uses the S3 backend against the bucket bootstrap creates.

After every guardrails or bootstrap apply, the state file is snapshotted to `materials/guardrails/`.
That is a `scripts/` concern and not a Terraform concern.

## Consequences

The local state file is the only live copy of the truth for both stacks. Losing it means importing
every resource by hand: for bootstrap that is two buckets, their versioning, encryption, public
access block, policy and lifecycle configurations, up to four cache rules, one secret and the SSM
parameters. The snapshot step is therefore not optional.

Neither stack can be read by a `terraform_remote_state` data source. That is why cross-stack values
are published as SSM parameters instead, which is ADR 0022.

Both stacks are single-operator by construction. There is no state locking on either, and there does
not need to be, but if this project ever grows a second pair of hands or a CI apply the decision has
to be revisited before that happens, not after.

## Sources

- Terraform S3 backend, including the note that the bucket must already exist:
  <https://developer.hashicorp.com/terraform/language/backend/s3>
- Workspace contract, `materials/journal/PHASE1-CONTRACT.md`, section "State".
