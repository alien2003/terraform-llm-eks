# 0022. Cross-stack values travel through SSM Parameter Store

Date: 2026-09-08

## Status

Accepted.

## Context

The cluster stack needs values that the bootstrap stack owns: the weights bucket name, the ECR
registry URL, the repository prefix each pull-through cache rule writes under. The state bucket name
it needs even earlier than that, in its own backend configuration.

The usual mechanisms are a `terraform_remote_state` data source, or module outputs, or copying the
strings into the consumer by hand.

`terraform_remote_state` is unavailable. Bootstrap keeps local state, per ADR 0020, so there is
nothing remote to read. Module composition would mean one root module and one state file for the
whole project, which defeats the point of a guardrails stack that is applied by a different role and
destroyed at a different time. Hand-copied strings drift.

## Decision

Bootstrap publishes its cross-stack values as `String` SSM parameters under `/llm-eks/bootstrap/`.
The consumer reads them with `data "aws_ssm_parameter"`.

The namespace convention for the whole project is `/llm-eks/<stack>/<key>`, so guardrails publishes
under `/llm-eks/guardrails/` by the same rule.

Every value published this way is non-secret: bucket names, a registry hostname, repository prefixes.
Nothing under this namespace is a credential, and nothing here is a `SecureString`.

## Consequences

The producer and the consumer are decoupled at the level of a string in a namespace, not a state
file. I can read any of these values from a terminal with one CLI call during a window, which matters
for pre-flight checks and for the audit script.

The parameters are a real dependency: destroy bootstrap and the cluster stack's data sources start
failing. That ordering is already fixed by the teardown sequence.

The state bucket name is the one value that cannot come through this channel, because a backend
block is evaluated before any data source can run. It is duplicated as a literal in the cluster
stack's `backend.tf` and published here as `/llm-eks/bootstrap/tfstate-bucket` so that the two can be
compared. Terraform backends do not accept variables or expressions; this is a property of the
language, not an oversight.

## Sources

- `aws_ssm_parameter` resource, valid types `String`, `StringList` and `SecureString`:
  <https://registry.terraform.io/providers/hashicorp/aws/6.63.0/docs/resources/ssm_parameter>
- Workspace contract, `materials/journal/PHASE1-CONTRACT.md`, section "Naming": "Cross-stack values
  are published as SSM parameters by the producing stack and read with a `data` source by the
  consumer."
