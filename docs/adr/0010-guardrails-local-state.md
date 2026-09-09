# 0010. The guardrails stack keeps local state

Status: accepted
Date: 2026-09-08

## Context

Every other stack in this repository would like to use the S3 backend with native S3 locking. The
guardrails stack cannot, for two reasons that both come down to ordering.

The state bucket is created by `infra/bootstrap`. Bootstrap is applied as the operator role, and the
operator role is created by this stack. So guardrails has to be applied before the bucket it would store
its state in exists. That is a cycle.

The second reason outlives the first. Guardrails is destroyed last, after every other stack, which means
it has to still be readable at a point where the state bucket is already gone. A remote backend would
leave the last `terraform destroy` of the project with nowhere to read its own state from.

Applying this stack is not a frequent event. It happens once in cloud window 0, possibly once more if the
author asks in writing for a boundary change, and once at the end to destroy it. There is no concurrency
to protect against and no team to share state with.

## Decision

`infra/guardrails` and `infra/bootstrap` keep local state. `infra/cluster` uses the S3 backend with
`use_lockfile = true` and no DynamoDB table.

After every guardrails apply the state file is copied to `materials/guardrails/`, which is private
working material and is never pushed anywhere. That is handled by a script, not by Terraform.

## Consequences

The state file lives on one machine and is not backed up by AWS. Losing it means re-importing the role,
the boundary, the budget, the alarm and the Lambda by hand, which is unpleasant but bounded, and every
resource in the stack has a fixed name so the import IDs are all predictable.

`terraform apply` here cannot be run from CI, which is correct: CI has no cloud credentials by design and
this stack needs administrator ones.

Nothing else can read this stack's outputs through a `terraform_remote_state` data source. Cross-stack
values are published as SSM parameters under `/llm-eks/<stack>/<key>` and read with a data source
instead, which is the convention for the whole project.
