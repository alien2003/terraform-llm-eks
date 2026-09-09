# 0013. The budget measures gross spend with credits excluded, and its action attaches a deny policy

Status: accepted
Date: 2026-09-08

## Context

The account holds Free Tier credits. The project treats credits as cash, because they are the budget:
spending them on a forgotten node is the same loss as spending money on one.

A cost budget can be told which charge types to count. AWS documents cost budgets as able to include or
exclude refunds, credits, upfront reservation fees, recurring reservation charges, non-reservation
subscription costs, taxes and support charges. A budget left on its defaults includes credits, which
means it reads close to zero for as long as credits are covering the usage, and then reads the truth on
the day they run out. By then the money is gone.

Separately, a budget that only notifies is a budget that depends on somebody reading the notification.
The account needs something that acts.

## Decision

`llm-eks-gross-spend` is a monthly `COST` budget with `include_credit = false` and
`include_refund = false` in its cost types, and every other charge type included. It measures what the
usage would have cost.

Notifications fire at each percentage in `var.budget_notification_percentages` on actual spend, plus one
on forecast at 100 percent. All of them are delivered to `alert_email` directly and none of them goes to
the alert topic, because the kill Lambda is subscribed to that topic and reads any message on it as stop
everything now. A percentage notification sent there is not a notification, it is a teardown at 25 percent
of the limit.

The automatic action is `APPLY_IAM_POLICY`, attaching a customer managed policy to the operator role at an
absolute dollar threshold, with `approval_model = AUTOMATIC`. `APPLY_IAM_POLICY` takes a policy ARN and a
list of roles, users or groups; this action names one role.

That policy is a `Deny` with `NotAction`, not a deny of everything. It denies every action except the
reads and the deletes that `terraform destroy`, `mise run down`, `mise run audit` and `mise run
guard-status` need: `sts`, the state bucket, `scheduler`, and `Describe`, `List`, `Get` and `Delete`
across the services the cluster stack creates, plus the billing and quota reads. Everything that creates
anything is denied, `PassRole` included.

## Consequences

`APPLY_SCP_POLICY` was not an option: it needs an organization, and this account must never join one
because that expires the credits immediately. `RUN_SSM_DOCUMENTS` was rejected on capability: its
subtypes stop named EC2 and RDS instance IDs, and the instance IDs are not known when the action is
written, because Karpenter creates them.

Attaching the policy stops the account from growing but does not stop what is already running. That is why
the same alert also lands on the topic and invokes the kill Lambda, which does stop it. One control stops
new spend, the other ends the spend in flight. Neither is sufficient alone.

The `NotAction` shape replaced a `Deny` on `Action "*"` before this stack was ever applied, because an
adversarial review pointed out that the blanket version was the worst available failure mode. The
identities that grow the account at that moment are an Auto Scaling group, the EKS control plane and the
Karpenter controller role, and none of them is the operator, so a blanket deny stopped nothing that was
spending. What it did stop was the only identity that can tear the cluster down, because it covered the
reads as well: `mise run audit`, which Rule 2b makes the only permitted activity when something is wrong,
failed on its first call. The answer to a spending problem was a spending problem that could not be fixed
without uncommenting the admin profile.

The cost of the narrower shape is that it is a list, and a list can be incomplete. That cost came due
twice. The first miss was `logs:List*`, `ssm:List*` and `eks:DisassociateAccessPolicy`: the tag reads two
provider refreshes make, and the call that destroying the operator's own cluster-admin access entry
issues. The second was the whole `events` service. The `karpenter` submodule at 21.25.0 creates five
EventBridge rules and their targets for Spot interruption handling, and no entry in the list began with
`events:`, so once the action attached, `terraform destroy` of the cluster stack would have failed on the
rules it could not delete. That is precisely the failure the `NotAction` rewrite existed to prevent, one
service narrower, and both misses were found by reading the list again, which is what produced them.

## Decision: the list is checked against the calls, not maintained by eye

`budgets.tf` now carries `local.teardown_api_calls`, an enumeration of the API operations the paths this
policy must leave open actually issue, grouped by the resource that issues them: `module.vpc`,
`module.eks`, `module.karpenter`, the IAM objects the cluster stack and the platform layer create, the
cross-stack SSM parameters, the `infra/bootstrap` deletes, and the calls `mise run audit`,
`mise run guard-status`, `mise run down` and the S3 state backend make. A `precondition` on
`aws_iam_policy.budget_stop` reads the `NotAction` list back out of the rendered document, turns each
entry into an anchored regular expression, and fails the plan by name for any call none of them cover.

Two properties make it worth the lines. It runs during `terraform plan`, because every value it reads is
a literal, so it fails before the apply rather than during a spending emergency. And it inverts the
maintenance burden: adding a resource to a stack means adding its calls, and a `NotAction` entry that
never gets written stops the plan instead of stopping the teardown.

The frame is stated in the code, because a coverage claim without a frame is not a claim. In scope: the
cluster stack destroy, which is where every hourly charge lives; the audit and pre-flight reads, which
Rule 2b makes the only permitted activity while something is wrong; the Terraform state access; and the
`infra/bootstrap` deletes that cannot grow the account. Out of scope, deliberately: `s3:DeleteBucket`,
because a bucket carries no hourly charge and removing the state bucket while the account is stopped
removes the ability to destroy anything else, and `mise run guard-drill`, because
`iam:SimulatePrincipalPolicy` rehearses the boundary before a window opens and a window does not open
while this policy is attached.

The check runs in one direction. Every enumerated call must be covered; an extra `NotAction` entry that
cannot create a billable resource is allowed to stay. Over-denial is the failure that strands the author
with a running cluster, so that is the one the check is pointed at.

One entry in the list is not a read and not a delete. `logs:PutRetentionPolicy` is the remediation
`mise run audit` prints for a log group with no retention policy, and Rule 2b makes fixing what the audit
reports the only permitted activity. It cannot create a log group and it cannot start a charge.

Reversing the action is an administrator job. The boundary denies the operator `iam:DetachRolePolicy`
against its own role, so an operator that has been stopped cannot un-stop itself. That is intentional and
it will be inconvenient exactly once.

Whether AWS Budgets observes gross pre-credit usage at all on a Free Plan account is undocumented and
still open. Until `Budget.CalculatedSpend` has been compared against `ce get-cost-and-usage` with
`UnblendedCost` on this account, the budget is a second opinion, the sweeper and the one-shot window
timer are the controls that actually stop spend, and any worst-case arithmetic is written against those.

## Sources

- <https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html>
- <https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_budgets_CostTypes.html>
- <https://docs.aws.amazon.com/cost-management/latest/userguide/billing-example-policies.html>
- <http://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-budgets-budgetsaction-iamactiondefinition.html>
