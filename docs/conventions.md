# Conventions

Names, tags, layout and the decision-record process. These are fixed because they are referenced across
stacks and scripts, and an inconsistency in any of them costs more than it saves. If something here is
wrong, change it here first and then in the code.

## Naming

Everything this project creates is prefixed `llm-eks-`. The prefix is what `mise run audit` and the sweeper
recognise, together with the project tag, so a resource that does not carry it is a resource the safety net
cannot see.

| Thing | Name |
| --- | --- |
| Operator role | `llm-eks-operator` |
| Operator permission boundary | `llm-eks-operator-boundary` |
| Administrator role (created by hand, not by Terraform) | `llm-eks-admin` |
| Base IAM user (created by hand, not by Terraform) | `llm-eks-human` |
| Alert topic | `llm-eks-alerts` |
| Budget | `llm-eks-gross-spend` |
| Kill Lambda | `llm-eks-kill` |
| Sweeper schedule, always on | `llm-eks-sweeper` |
| Schedule group for one-shot window timers | `llm-eks-windows` |
| One-shot window timer | `llm-eks-window-<WINDOW_ID>` |
| Terraform state bucket | `llm-eks-tfstate-<account-id>` |
| Model weights bucket | `llm-eks-weights-<account-id>` |
| ECR pull-through cache namespace | `llm-eks-cache` |
| EKS cluster | `llm-eks` |
| Karpenter interruption queue | `llm-eks-karpenter-interruption` |

Bucket names carry the account id because S3 bucket names are globally unique and nothing else about this
project is. The account id is not a secret, but it is an identifier, so it is not written into documentation
by hand; it comes from `data.aws_caller_identity` in Terraform and from the CLI in scripts.

`llm-eks-cache` is a namespace and not, on its own, an image path. What ECR calls the *repository prefix*
(`ecrRepositoryPrefix` in the API, `ecr_repository_prefix` in the provider) is set per cache rule, one
rule per upstream registry, and every rule in `infra/bootstrap` sets it to `llm-eks-cache/<upstream>`:
`llm-eks-cache/ecr-public`, `llm-eks-cache/kubernetes`, `llm-eks-cache/quay`,
`llm-eks-cache/docker-hub`. A reference built as `<registry-url>/llm-eks-cache/<image>` matches no rule
and no repository. The bare namespace is published to SSM as `ecr-cache-namespace`, named that way on
purpose, and the values a consumer should actually pull an image through are the per-upstream
`ecr-cache-repository-prefix/<key>` parameters. `infra/bootstrap/README.md` has the table.

Terraform identifiers are snake case (`operator_boundary`, not `operator-boundary`). AWS resource names are
kebab case, because that is what reads correctly in the console and in an ARN.

## Tags

Every taggable resource, in every stack, carries three tags:

```hcl
Project   = "terraform-llm-eks"
Stack     = "guardrails" | "bootstrap" | "cluster"
ManagedBy = "terraform"
```

Resources created inside a cloud window carry a fourth, `Window = "<WINDOW_ID>"`.

These go in the provider's `default_tags` block, not on individual resources. Tagging resource by resource
is how one resource ends up untagged, and an untagged resource is invisible to both `mise run audit` and the
sweeper, which select on `Project=terraform-llm-eks`. An instance that the sweeper cannot see is an instance
that runs until someone notices the bill.

A handful of AWS resource types do not accept tags from `default_tags` and need them passed explicitly.
Where that happens the stack says so in a comment next to the resource.

## Cross-stack values

Stacks do not read each other's state. Two of the three keep local state and cannot be read that way
(ADR 0004), so rather than have one mechanism plus an exception there is one mechanism.

A stack that produces a value another stack needs publishes it as an SSM parameter under
`/llm-eks/<stack>/<key>`, and the consumer reads it with a data source. ADR 0022 has the details.

## Stack layout

Each stack is a root module and looks the same from the outside:

```text
versions.tf     required_version and pinned required_providers
providers.tf    provider blocks, including default_tags
variables.tf    inputs, every one with a description and a type
locals.tf       computed names and shared expressions
data.tf         data sources, including cross-stack SSM lookups
<topic>.tf      one file per subject: buckets.tf, budgets.tf, eks.tf, karpenter.tf
outputs.tf      outputs, every one with a description
README.md       what the stack is, how it is applied, and what it costs to leave running
.trivyignore    accepted findings, each with a reason, if there are any
```

`backend.tf` exists only in `infra/cluster`. The other two stacks keep local state on purpose.

## Repository layout

```text
infra/          the three stacks, plus the platform layer as a child module of the cluster stack
scripts/        one script per mise task, plus scripts/lib/common.sh
test/           the kind-based integration suite
bench/          k6 load profiles
docs/           this file, and the decision records
.github/        CI
```

Everything is run through `mise run <task>`. That is the whole interface, and documentation names a task
rather than reproducing the command it runs. A command written into a document is a command that goes stale
without anyone noticing.

## Decision records

Anything non-obvious gets an ADR in `docs/adr/`, named `NNNN-short-slug.md`. That includes decisions that
turned out to be wrong: an ADR that records a mistake and what was learned is more useful than a tidy
directory.

Write one when the answer to "why is it like this?" is longer than a comment, when a version or a limit was
chosen rather than defaulted, or when observed behaviour disagreed with documentation. Do not write one for
something the code already says plainly.

The format is fixed so the records can be skimmed. The header is the title line and the date, in that
order, and nothing else; a record whose facts were corrected after it was accepted gains a
`Revised: YYYY-MM-DD` line directly under `Date:`. Status is a section rather than a header field, because
it is the thing a reader most often needs a sentence about and a bare word will not carry that.

```markdown
# NNNN. Title as a statement, not a question

Date: YYYY-MM-DD
Revised: YYYY-MM-DD   (only if a fact in it was corrected later)

## Status

Accepted. (or: Superseded by ADR NNNN, or: Rejected)

## Context

What forced a decision. The constraints, in enough detail that the decision looks inevitable or clearly
does not.

## Decision

What was decided, stated plainly.

## Consequences

What this costs, what it rules out, and what would make it worth revisiting. Being honest here is the
whole value of the document.

## Sources

Every URL the decision rests on, with the sentence that mattered quoted where it is short enough.
```

`Sources` is the one section a record may leave out, and only for the case where it rests on nothing
outside this repository: an ordering rule, a file layout, a decision whose whole argument is about code that
is already here. Every other section is mandatory. A missing `Sources` on a record that cites a version, a
price, a quota or an API behaviour is a defect, not a style choice.

Numbers are never reused and an ADR is never edited to say a different thing was decided. A decision that
changes gets a new record whose Status supersedes the old one, and the old one gets a Status line pointing
forwards.

Correcting a fact is not the same act and does not need a new number. A record that got a price, a version,
an API behaviour or a count wrong is edited in place, keeps its Decision, and gains the `Revised:` line. The
record exists so the reasoning can be checked; leaving a claim in it that has been checked and found wrong
defeats that.

Numbers are grouped by subject so that a reader can find the ones that concern a stack:

| Range | Subject |
| --- | --- |
| 0001 to 0009 | Cross-cutting: toolchain, repository shape, CI, documentation |
| 0010 to 0019 | The guardrails stack |
| 0020 to 0029 | The bootstrap stack |
| 0030 to 0039 | The cluster stack |
| 0040 to 0049 | The platform layer |
| 0050 to 0059 | Scripts, tasks and the test suite |

## Prose

Documentation in this repository is written in first person singular where a person is speaking, with
concrete numbers instead of adjectives and short paragraphs. No marketing tone.

Every number in a document traces back to a file that recorded it. If a benchmark has not been run, the
table gets its columns and an explicit note that nothing has been measured, not a plausible figure. A
number written from memory is a number that will be quoted back later as if it were evidence.
