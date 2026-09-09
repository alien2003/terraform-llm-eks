#!/usr/bin/env bash
# mise run audit
#
# Scan for orphaned project-tagged resources and report zero or list them. Exit
# non-zero when anything is found. Rule 2b of the workspace rules: if this reports anything,
# fixing it is the only permitted activity until it reports clean.
#
# What counts as an orphan
#
#   Two axes, and either one is enough.
#
#   By stack. Every resource carries Stack=guardrails|bootstrap|cluster. The
#   guardrails and bootstrap stacks are meant to outlive a window; the cluster stack
#   is not. So anything tagged Stack=cluster that is still here after `mise run down`
#   is an orphan by definition, whatever it costs.
#
#   By price. Anything with an hourly price is an orphan regardless of which stack
#   claims it: instances, volumes, NAT gateways, Elastic IPs, load balancers,
#   interface endpoints, EKS clusters and node groups. A bootstrap bucket is fine. A
#   bootstrap instance would not be.
#
#   And anything carrying the Project tag with no Stack tag at all, because a
#   resource nobody can attribute is a resource nobody will remember to delete.
#
# What the Project tag cannot see
#
#   Selecting on the tag answers "no project-tagged orphans", which is not the same
#   question as "no orphans". Several billable things in this design never carry it:
#   a load balancer created by a Kubernetes Service carries kubernetes.io/* tags and
#   nothing of ours, an EBS volume left by a PVC carries the CSI driver's tags, an
#   Elastic IP allocated outside Terraform carries none, and the ECR pull-through
#   cache repositories are untagged by design because setting resource tags on a
#   creation template needs an IAM role this project does not create.
#
#   So four of the priced classes get a second, untagged sweep. Where a tag is
#   unavailable the resource is attributed by VPC id instead: the VPC is created by
#   the cluster stack and does carry the tag, and a load balancer or NAT gateway
#   inside it is this project's whatever its own tags say. Volumes and addresses are
#   not in a VPC, so those two are reported when they are unattached or unassociated,
#   which is the state in which they bill for nothing and cannot be attributed to
#   anything else.
#
#   Two more are per-unit rather than per-hour and are reported as standing costs
#   rather than as orphans: the ECR cache repositories and the project's CloudWatch
#   log groups. Both are meant to survive a window, both keep billing after
#   `mise run down`, and treating them as orphans would leave the audit permanently
#   dirty and the kill timer permanently armed. They are printed so that they reach
#   the window record in materials/costs/windows.md instead of nowhere.
#
# Two regions are scanned: the working region, and us-east-1, which is where a
# mis-set region lands things by default and where the billing-side resources live.
#
# Every call is read-only. Safe in LOCAL mode, safe to run twice.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_cmd aws jq

ORPHANS_FILE="$(mktemp "${TMPDIR:-/tmp}/llm-eks-audit.XXXXXX")"
trap 'rm -f "$ORPHANS_FILE"' EXIT

ORPHAN_COUNT=0

orphan() { # orphan <region> <kind> <identifier> <detail>
  ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
  printf '%-12s %-22s %-46s %s\n' "$1" "$2" "$3" "$4" >>"$ORPHANS_FILE"
}

heading "audit — $(date -u '+%Y-%m-%d %H:%M:%SZ')"

if ! aws_available; then
  die "no usable AWS credentials. The audit asks the account what still exists; it cannot be answered offline. Check with 'mise run auth operator'."
fi

ACCOUNT="$(account_id)"

REGIONS="$WORK_REGION"
[ "$WORK_REGION" = "$BILLING_REGION" ] || REGIONS="$WORK_REGION $BILLING_REGION"

info "account $ACCOUNT, regions: $REGIONS, Project=$PROJECT_TAG"

# ------------------------------------------------------------------ per region

for region in $REGIONS; do
  heading "region $region"

  # --- The project's VPCs. Not a check in itself: the tagging API below reports a
  #     leftover VPC on its own. This is the key the untagged sweeps use, because a
  #     load balancer or a NAT gateway inside a VPC this project created is this
  #     project's regardless of what its own tags say.
  project_vpcs="$(aws_ro ec2 describe-vpcs --region "$region" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" --output json |
    jq -r '.Vpcs[].VpcId')"

  in_project_vpc() { # in_project_vpc <vpc-id>
    [ -n "${1:-}" ] || return 1
    printf '%s\n' "$project_vpcs" | grep -Fxq "$1"
  }

  # --- EC2 instances. The one thing that must never be left running.
  instances="$(aws_ro ec2 describe-instances --region "$region" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" \
              "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --output json |
    jq -r '.Reservations[].Instances[] |
      [.InstanceId, .InstanceType, .State.Name, .LaunchTime,
       ((.Tags // []) | map(select(.Key == "Window")) | .[0].Value // "-")] | @tsv')"
  if [ -z "$instances" ]; then
    check PASS "instances" "none"
  else
    while IFS=$'\t' read -r id itype state launched window; do
      [ -n "$id" ] || continue
      check FAIL "instance" "$id $itype $state (window ${window}, launched $launched)"
      orphan "$region" instance "$id" "$itype $state since $launched"
    done <<<"$instances"
  fi

  # An instance without the Project tag is invisible to the sweeper and to this
  # audit, which is the failure mode the boundary's tag condition exists to prevent.
  # Counting them is the only way to notice that the condition has stopped working.
  untagged="$(aws_ro ec2 describe-instances --region "$region" \
    --filters "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
    --output json |
    jq -r --arg p "$PROJECT_TAG" '.Reservations[].Instances[] |
      select(((.Tags // []) | map(select(.Key == "Project" and .Value == $p)) | length) == 0) |
      [.InstanceId, .InstanceType, .State.Name] | @tsv')"
  if [ -z "$untagged" ]; then
    check PASS "untagged instances" "none — the sweeper can see everything that is running"
  else
    while IFS=$'\t' read -r id itype state; do
      [ -n "$id" ] || continue
      check FAIL "untagged instance" "$id $itype $state — no Project tag, so the sweeper will never touch it"
      orphan "$region" untagged-instance "$id" "$itype $state, invisible to the sweeper"
    done <<<"$untagged"
  fi

  # --- EBS volumes. They bill whether or not anything is attached to them.
  volumes="$(aws_ro ec2 describe-volumes --region "$region" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" --output json |
    jq -r '.Volumes[] | [.VolumeId, .State, (.Size|tostring) + "GiB", .VolumeType] | @tsv')"
  if [ -z "$volumes" ]; then
    check PASS "volumes" "none"
  else
    while IFS=$'\t' read -r id state size vtype; do
      [ -n "$id" ] || continue
      check FAIL "volume" "$id $state $size $vtype"
      orphan "$region" volume "$id" "$state $size $vtype"
    done <<<"$volumes"
  fi

  # An available volume is a volume nothing is attached to, and it bills for its full
  # provisioned size regardless. A PVC's volume carries the CSI driver's tags and not
  # ours, and a volume is not in a VPC, so the tag sweep above cannot see it and there
  # is nothing to key it on: unattached is the discriminator. Nothing in this project
  # is supposed to leave one behind, which is what makes reporting all of them cheap.
  loose_volumes="$(aws_ro ec2 describe-volumes --region "$region" --output json |
    jq -r --arg p "$PROJECT_TAG" '.Volumes[] |
      select(.State == "available") |
      select(((.Tags // []) | map(select(.Key == "Project" and .Value == $p)) | length) == 0) |
      [.VolumeId, (.Size|tostring) + "GiB", .VolumeType,
       ((.Tags // []) | map(.Key) | join(","))] | @tsv')"
  if [ -z "$loose_volumes" ]; then
    check PASS "unattached volumes" "none without the Project tag"
  else
    while IFS=$'\t' read -r id size vtype keys; do
      [ -n "$id" ] || continue
      check FAIL "unattached volume" "$id $size $vtype — no Project tag, tags: ${keys:-none}"
      orphan "$region" loose-volume "$id" "$size $vtype available, invisible to the tag sweep"
    done <<<"$loose_volumes"
  fi

  # --- Elastic IPs. An unassociated address bills by the hour; an associated one
  #     means something is still attached to it.
  eips="$(aws_ro ec2 describe-addresses --region "$region" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" --output json |
    jq -r '.Addresses[] | [.AllocationId // .PublicIp, .PublicIp, (.AssociationId // "unassociated")] | @tsv')"
  if [ -z "$eips" ]; then
    check PASS "elastic IPs" "none"
  else
    while IFS=$'\t' read -r id ip assoc; do
      [ -n "$id" ] || continue
      check FAIL "elastic IP" "$id $ip $assoc"
      orphan "$region" elastic-ip "$id" "$ip $assoc"
    done <<<"$eips"
  fi

  # An unassociated address bills by the hour for nothing at all, and an address
  # allocated by anything other than Terraform carries no Project tag. Same reasoning
  # as the volumes above: no VPC to key on, so unassociated is the discriminator.
  loose_eips="$(aws_ro ec2 describe-addresses --region "$region" --output json |
    jq -r --arg p "$PROJECT_TAG" '.Addresses[] |
      select(has("AssociationId") | not) |
      select(((.Tags // []) | map(select(.Key == "Project" and .Value == $p)) | length) == 0) |
      [(.AllocationId // .PublicIp), .PublicIp,
       ((.Tags // []) | map(.Key) | join(","))] | @tsv')"
  if [ -z "$loose_eips" ]; then
    check PASS "unassociated elastic IPs" "none without the Project tag"
  else
    while IFS=$'\t' read -r id ip keys; do
      [ -n "$id" ] || continue
      check FAIL "unassociated elastic IP" "$id $ip — no Project tag, tags: ${keys:-none}"
      orphan "$region" loose-elastic-ip "$id" "$ip unassociated, billing for nothing"
    done <<<"$loose_eips"
  fi

  # --- NAT gateways. describe-nat-gateways takes --filter, singular, and unlike the
  #     other describes it returns deleted ones unless they are filtered out.
  nats="$(aws_ro ec2 describe-nat-gateways --region "$region" \
    --filter "Name=tag:Project,Values=$PROJECT_TAG" --output json |
    jq -r '.NatGateways[] | select(.State != "deleted") | [.NatGatewayId, .State, .VpcId] | @tsv')"
  if [ -z "$nats" ]; then
    check PASS "NAT gateways" "none"
  else
    while IFS=$'\t' read -r id state vpc; do
      [ -n "$id" ] || continue
      check FAIL "NAT gateway" "$id $state in $vpc"
      orphan "$region" nat-gateway "$id" "$state in $vpc"
    done <<<"$nats"
  fi

  # A NAT gateway is always in a VPC, so it is the one hourly resource here that can
  # always be attributed even with no tags at all.
  loose_nats="$(aws_ro ec2 describe-nat-gateways --region "$region" --output json |
    jq -r --arg p "$PROJECT_TAG" '.NatGateways[] |
      select(.State != "deleted") |
      select(((.Tags // []) | map(select(.Key == "Project" and .Value == $p)) | length) == 0) |
      [.NatGatewayId, .State, (.VpcId // "-")] | @tsv')"
  loose_nat_found=0
  if [ -n "$loose_nats" ]; then
    while IFS=$'\t' read -r id state vpc; do
      [ -n "$id" ] || continue
      if in_project_vpc "$vpc"; then
        loose_nat_found=1
        check FAIL "untagged NAT gateway" "$id $state in $vpc — a project VPC, but no Project tag"
        orphan "$region" untagged-nat-gateway "$id" "$state in project VPC $vpc"
      fi
    done <<<"$loose_nats"
  fi
  [ "$loose_nat_found" -eq 0 ] && check PASS "untagged NAT gateways" "none in a project VPC"

  # --- Interface VPC endpoints bill hourly per endpoint per AZ. Gateway endpoints
  #     are free, which is why the stack uses one for S3, so they are not orphans.
  endpoints="$(aws_ro ec2 describe-vpc-endpoints --region "$region" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" --output json |
    jq -r '.VpcEndpoints[] | select(.VpcEndpointType == "Interface") |
      [.VpcEndpointId, .ServiceName, .State] | @tsv')"
  if [ -z "$endpoints" ]; then
    check PASS "interface endpoints" "none"
  else
    while IFS=$'\t' read -r id service state; do
      [ -n "$id" ] || continue
      check FAIL "interface endpoint" "$id $service $state"
      orphan "$region" vpc-endpoint "$id" "$service $state"
    done <<<"$endpoints"
  fi

  # --- Load balancers. Two APIs and two ways in, and the review that found this gap
  #     was right about both.
  #
  #     describe-load-balancers has no tag filter, so every load balancer is listed and
  #     each is then judged twice: by the Project tag, and by whether it sits in a VPC
  #     this project created. The second test is the one that matters, because a load
  #     balancer created by a Kubernetes Service of type LoadBalancer is created by the
  #     in-tree cloud provider or a controller, not by Terraform, and it carries
  #     kubernetes.io/* tags and nothing of ours. It also blocks the VPC from being
  #     deleted, so a failed teardown leaves both and the audit should name the load
  #     balancer rather than only the VPC that cannot go.
  #
  #     And elbv2 is not the whole story: a type: LoadBalancer Service with no
  #     controller and no annotation gets a CLASSIC load balancer, which lives in a
  #     different API entirely and is invisible to elbv2 before any tag is considered.
  #     Both are queried.
  lb_found=0
  lb_records="$(aws_ro elbv2 describe-load-balancers --region "$region" --output json |
    jq -r '.LoadBalancers[] | [.LoadBalancerArn, (.VpcId // "-"), (.Type // "-")] | @tsv')"
  if [ -n "$lb_records" ]; then
    while IFS=$'\t' read -r arn vpc lbtype; do
      [ -n "$arn" ] || continue
      if aws_ro elbv2 describe-tags --region "$region" --resource-arns "$arn" --output json |
         jq -e --arg p "$PROJECT_TAG" \
           '.TagDescriptions[].Tags[] | select(.Key == "Project" and .Value == $p)' >/dev/null; then
        lb_found=1
        check FAIL "load balancer" "$arn"
        orphan "$region" load-balancer "${arn##*/}" "$arn"
      elif in_project_vpc "$vpc"; then
        lb_found=1
        check FAIL "untagged load balancer" "$lbtype $arn in $vpc — a project VPC, but no Project tag"
        orphan "$region" untagged-load-balancer "${arn##*/}" "$lbtype in project VPC $vpc, probably from a Kubernetes Service"
      fi
    done <<<"$lb_records"
  fi

  classic_lbs="$(aws_ro elb describe-load-balancers --region "$region" --output json |
    jq -r '.LoadBalancerDescriptions[] | [.LoadBalancerName, (.VPCId // "-")] | @tsv')"
  if [ -n "$classic_lbs" ]; then
    while IFS=$'\t' read -r name vpc; do
      [ -n "$name" ] || continue
      if in_project_vpc "$vpc"; then
        lb_found=1
        check FAIL "classic load balancer" "$name in $vpc — a project VPC. Classic load balancers are what an unannotated type: LoadBalancer Service creates"
        orphan "$region" classic-load-balancer "$name" "classic ELB in project VPC $vpc"
      fi
    done <<<"$classic_lbs"
  fi

  [ "$lb_found" -eq 0 ] && check PASS "load balancers" "none tagged, none in a project VPC, elbv2 and classic both checked"

  # --- EKS. A cluster is the most expensive thing this project creates that is not
  #     an instance, and it is easy to forget because it has no console-visible price.
  clusters="$(aws_ro eks list-clusters --region "$region" --output json | jq -r '.clusters[]')"
  cluster_found=0
  if [ -n "$clusters" ]; then
    while IFS= read -r cluster; do
      [ -n "$cluster" ] || continue
      if aws_ro eks describe-cluster --region "$region" --name "$cluster" --output json |
         jq -e --arg p "$PROJECT_TAG" '.cluster.tags.Project == $p' >/dev/null; then
        cluster_found=1
        check FAIL "EKS cluster" "$cluster"
        orphan "$region" eks-cluster "$cluster" "control plane billing by the hour"

        nodegroups="$(aws_ro eks list-nodegroups --region "$region" --cluster-name "$cluster" \
          --output json | jq -r '.nodegroups[]')"
        while IFS= read -r ng; do
          [ -n "$ng" ] || continue
          check FAIL "EKS node group" "$cluster/$ng"
          orphan "$region" eks-nodegroup "$cluster/$ng" "nodes billing by the hour"
        done <<<"$nodegroups"
      fi
    done <<<"$clusters"
  fi
  [ "$cluster_found" -eq 0 ] && check PASS "EKS clusters" "none"

  # --- Everything else, by tag. The Resource Groups Tagging API sees services this
  #     script does not name. It can lag by minutes, so it supplements the explicit
  #     describes above rather than replacing them.
  #     https://docs.aws.amazon.com/cli/latest/userguide/cli_resource-groups-tagging-api_code_examples.html
  tagged="$(aws_ro resourcegroupstaggingapi get-resources --region "$region" \
    --tag-filters "Key=Project,Values=$PROJECT_TAG" --output json |
    jq -r '.ResourceTagMappingList[] |
      [.ResourceARN, ((.Tags // []) | map(select(.Key == "Stack")) | .[0].Value // "-")] | @tsv')"

  persistent=0
  if [ -n "$tagged" ]; then
    while IFS=$'\t' read -r arn stack; do
      [ -n "$arn" ] || continue
      case "$stack" in
        guardrails|bootstrap)
          persistent=$((persistent + 1))
          ;;
        cluster)
          # Already reported above if it was an instance, volume, load balancer or
          # cluster; reported here if it is anything else the cluster stack left.
          case "$arn" in
            *:instance/*|*:volume/*|*:natgateway/*|*:loadbalancer/*|*:cluster/*|*:nodegroup/*|*:vpc-endpoint/*)
              ;;
            *)
              check FAIL "cluster-stack leftover" "$arn"
              orphan "$region" cluster-leftover "${arn##*:}" "$arn"
              ;;
          esac
          ;;
        *)
          check FAIL "unattributed resource" "$arn has Project but no Stack tag"
          orphan "$region" unattributed "${arn##*:}" "$arn"
          ;;
      esac
    done <<<"$tagged"
  fi
  check PASS "persistent resources" "$persistent tagged guardrails or bootstrap, which is where they belong"

  # --- A timer armed in this group is information, not a fault: window-down runs
  #     this audit while the timer is still deliberately armed.
  armed="$(aws_ro scheduler list-schedules --group-name "$WINDOW_GROUP_NAME" --region "$region" \
    --output json 2>/dev/null | jq -r '[.Schedules[].Name] | join(", ")' || true)"
  if [ -n "$armed" ]; then
    check PASS "window timers" "armed: $armed"
  fi

  # --- Standing per-unit costs, reported and not counted as orphans.
  #
  #     These bill after `mise run down` and they are supposed to: re-uploading the
  #     weights and re-pulling multi-gigabyte images every window would cost more than
  #     storing them, and the control-plane log group holds the evidence of what the
  #     cluster did. Counting them as orphans would leave the audit permanently dirty
  #     and the kill timer permanently armed, which is the opposite of the intent. They
  #     are printed so the figures reach materials/costs/windows.md.

  # ECR pull-through cache repositories. Untagged by design: setting resource tags on
  # a repository creation template requires a custom_role_arn, so infra/bootstrap
  # documents that these are found by prefix instead. Storage is per GB-month and
  # accrues from the first window onward.
  cache_repos="$(aws_ro ecr describe-repositories --region "$region" --output json 2>/dev/null |
    jq -r --arg pfx "${NAME_PREFIX}-cache/" '.repositories[]?
      | select(.repositoryName | startswith($pfx)) | .repositoryName' || true)"
  if [ -z "$cache_repos" ]; then
    check PASS "ECR cache storage" "no repositories under ${NAME_PREFIX}-cache/ yet"
  else
    repo_count=0
    total_bytes=0
    while IFS= read -r repo; do
      [ -n "$repo" ] || continue
      repo_count=$((repo_count + 1))
      bytes="$(aws_ro ecr describe-images --region "$region" --repository-name "$repo" \
        --output json 2>/dev/null | jq -r '[.imageDetails[]? | .imageSizeInBytes // 0] | add // 0' || true)"
      case "$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
      esac
      total_bytes=$((total_bytes + bytes))
    done <<<"$cache_repos"
    total_mib=$((total_bytes / 1048576))
    check PASS "ECR cache storage" "$repo_count repositories, ${total_mib} MiB stored — per GB-month, survives every teardown, record it in materials/costs/windows.md"
  fi

  # CloudWatch log groups. The EKS control-plane group is created by the control plane
  # rather than by Terraform and it outlives the cluster until its retention expires;
  # the kill Lambda's group is meant to outlive everything.
  for prefix in "/aws/eks/${NAME_PREFIX}" "/aws/lambda/${NAME_PREFIX}"; do
    groups="$(aws_ro logs describe-log-groups --region "$region" \
      --log-group-name-prefix "$prefix" --output json 2>/dev/null |
      jq -r '.logGroups[]? | [.logGroupName, ((.storedBytes // 0)|tostring),
        ((.retentionInDays // 0)|tostring)] | @tsv' || true)"
    if [ -z "$groups" ]; then
      check PASS "log groups $prefix" "none"
      continue
    fi
    while IFS=$'\t' read -r name bytes retention; do
      [ -n "$name" ] || continue
      mib=$((bytes / 1048576))
      if [ "$retention" = "0" ]; then
        check FAIL "log group" "$name never expires — ${mib} MiB and growing, an open-ended storage charge. Fix: aws logs put-retention-policy --region $region --log-group-name $name --retention-in-days 7"
        orphan "$region" log-group "$name" "no retention policy, ${mib} MiB stored, grows without bound"
      else
        check PASS "log group" "$name, ${mib} MiB, ${retention}d retention — storage and ingestion are per-unit, record them"
      fi
    done <<<"$groups"
  done
done

# ------------------------------------------------------------------ buckets

heading "global"

# S3 buckets are global. The two bootstrap buckets are meant to be here; anything
# else carrying the project prefix is not.
buckets="$(aws_ro s3api list-buckets --output json |
  jq -r --arg p "$NAME_PREFIX" '.Buckets[].Name | select(startswith($p + "-"))')"
expected_buckets=("${NAME_PREFIX}-tfstate-${ACCOUNT}" "${NAME_PREFIX}-weights-${ACCOUNT}")
if [ -z "$buckets" ]; then
  check PASS "buckets" "none with the $NAME_PREFIX- prefix"
else
  while IFS= read -r bucket; do
    [ -n "$bucket" ] || continue
    if printf '%s\n' "${expected_buckets[@]}" | grep -Fxq "$bucket"; then
      check PASS "bucket" "$bucket (bootstrap, expected between windows)"
    else
      check FAIL "bucket" "$bucket is not one of the two bootstrap buckets"
      orphan global bucket "$bucket" "unexpected project-prefixed bucket"
    fi
  done <<<"$buckets"
fi

# ------------------------------------------------------------------ verdict

hr
if [ "$ORPHAN_COUNT" -eq 0 ]; then
  printf '\n%sAUDIT CLEAN. Zero orphans.%s\n' "$C_GREEN" "$C_RESET" >&2
  printf 'Tagged and untagged sweeps both clean: instances, volumes, addresses, NAT\n' >&2
  printf 'gateways, interface endpoints, load balancers (elbv2 and classic), EKS and\n' >&2
  printf 'the tagging API. The standing per-unit costs above are expected and are not\n' >&2
  printf 'orphans; copy their figures into the window entry.\n' >&2
  exit 0
fi

printf '\n%sAUDIT DIRTY: %d orphan(s).%s\n\n' "$C_RED" "$ORPHAN_COUNT" "$C_RESET" >&2
printf '%-12s %-22s %-46s %s\n' REGION KIND IDENTIFIER DETAIL >&2
cat "$ORPHANS_FILE" >&2
cat >&2 <<'EOF'

Rule 2b of the workspace rules: fixing this is the only permitted activity until the audit reports
clean. Do not close the window, do not disarm the timer, do not start something else.

The usual cause is a terraform destroy that failed part way. Re-run it:

    mise run down

If a resource has escaped Terraform entirely, delete it by hand, then work out how it
got there and write that down in the journal — an untracked resource is a hole in the
safety net, not just a charge.
EOF
exit 1
