# 0004. State backends follow the teardown order

Date: 2026-09-08

## Status

Accepted.

## Context

Three stacks (ADR 0003) and two different answers about where state lives is the kind of inconsistency that
looks like an accident when someone reads the repository later. It is not one, and this record exists so
that the rule is written down once, in one place, rather than inferred from three stacks that each explain
their own half of it.

The rule comes out of one question: at the moment this stack is destroyed, does the thing holding its state
still exist?

The Terraform state bucket is created by `infra/bootstrap`, so it does not exist when bootstrap first runs.
It is deleted by `terraform destroy` on `infra/bootstrap`, so it does not exist afterwards either. And
`infra/guardrails` is destroyed after bootstrap, deliberately, because it holds the boundary and the
sweeper that make everything else safe. A remote backend in that bucket would leave the last two destroys
of the project reading state out of an object that the second to last destroy removed.

`infra/cluster` has neither problem. It is created and destroyed inside a window, many times, always while
the bucket exists, and it is the stack most likely to be interrupted halfway through and resumed.

## Decision

The rule I settled on: a stack keeps local state if it is applied before, or destroyed after, the bucket
that would hold its state. Everything else uses the S3 backend.

| Stack | Backend | Why |
| --- | --- | --- |
| `infra/guardrails` | local | Destroyed after the bucket. ADR 0010 |
| `infra/bootstrap` | local | Creates the bucket. ADR 0020 |
| `infra/cluster` | S3, `use_lockfile = true` | Lives entirely inside the bucket's lifetime. ADR 0021 |

A new stack answers the same question before it gets a `backend.tf`.

Because the two local-state stacks cannot be read by a `terraform_remote_state` data source, no stack in
this repository uses one. Cross-stack values go through SSM parameters instead, for all three, so there is
one mechanism rather than one mechanism and an exception. That is ADR 0022.

## Consequences

The local state files are the only live copy of the truth for guardrails and bootstrap, and neither is in
version control. Snapshotting them to private working material after every apply is therefore not optional,
and it is a script's job rather than Terraform's.

CI never exercises a backend. Every `terraform init` in the workflow runs with `-backend=false`, which is
what lets validation happen with no bucket, no credentials and no lock. The consequence to be honest about
is that a broken `backend.tf` in the cluster stack is not caught by CI. It is caught by the first
`terraform init` of the next window, which is early enough, before anything is applied, but it is not
caught here.

State locking exists only for the cluster stack. The other two are single-operator by construction and have
no lock at all. If this repository ever grows a second pair of hands, that has to be revisited before the
second pair of hands arrives rather than after.

## Sources

- Terraform S3 backend, including the requirement that the bucket already exists and the `use_lockfile`
  argument: <https://developer.hashicorp.com/terraform/language/backend/s3>
- Terraform on the local backend as the default when no `backend` block is present:
  <https://developer.hashicorp.com/terraform/language/backend/local>
- Per-stack reasoning: ADR 0010, ADR 0020 and ADR 0021.
