"""Stop the money.

Terminating instances is not the same thing as stopping spend, and the first
version of this function only terminated instances. An EKS managed node group
replaces what it loses within minutes, Karpenter re-provisions a GPU node for a
pod that is still pending, and the control plane, the NAT gateway and its public
IPv4 address bill by the hour whether or not any instance exists. So a fired
timer looked decisive and was undone in about ninety seconds.

What this function does now, in this order, is written down in
infra/guardrails/README.md under "The kill Lambda". The short version:

  1. scale every managed node group of the project cluster to zero, so the Auto
     Scaling group stops replacing nodes and the Karpenter controller loses the
     only place it can run;
  2. in a full stop, delete those node groups, because the cluster cannot be
     deleted while they exist;
  3. terminate every project-tagged instance, which is now nothing's job to
     replace;
  4. in a full stop, delete the load balancers in the project VPCs, the NAT
     gateways, the cluster itself, and release the Elastic IPs.

Three things call it and they want different amounts of that:

  sweep     the always-on schedule. Does 1 and 3 when it finds a project-tagged
            instance older than max_age_minutes, which is longer than the
            longest window the approval form can grant, so an aged instance
            means no window is legitimately open and everything goes. Escalates
            to a full stop when it finds an hourly resource left behind with no
            instances running, no window timer pending, and more than
            orphan_grace_minutes on the clock.
  kill_all  the one-shot window timer armed by `mise run up`, and any alert that
            arrives on the alert topic. Full stop, no age test, no window test.
  report    describes the full stop it would perform and changes nothing. The
            drill uses it.

Idempotency and convergence. Every step is safe to repeat: a node group already
at zero is skipped, a resource that is already gone is treated as done, and a
resource that cannot go yet because something else is still deleting is recorded
as pending rather than as a failure. That matters because deleting a node group
takes minutes and the cluster cannot be deleted until it has finished, so a full
stop normally leaves the cluster for a later pass. The sweeper is what makes
that later pass happen: the cluster is then an hourly resource with no instances
and no pending window timer, which is the sweeper's own escalation condition.
Nothing here waits, polls or sleeps, so no invocation can deadlock or run into
the timeout holding a lock.

Anything that fails for a reason other than "already gone" or "not yet" is
collected and re-raised at the end, after every other step has been attempted.
That is deliberate: the scheduler's dead-letter queue and the error alarm on
this function are the only things that can tell the author the kill path is
broken, and they only see it if the invocation fails.

No network access and no credentials are needed to import this module or to run
its tests; every client is built lazily inside the handler.
"""

import datetime
import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

# An instance in any of these states is either costing money or about to.
BILLABLE_STATES = ["pending", "running", "stopping", "stopped"]

# 8 hours (the longest window the approval form can grant) plus a margin. The
# stack derives the real value from max_window_hours and passes it in.
DEFAULT_MAX_AGE_MINUTES = 510
DEFAULT_ORPHAN_GRACE_MINUTES = 60

# NAT gateway states in which there is nothing left to delete.
NAT_GONE_STATES = ("deleting", "deleted", "failed")

# Error codes that mean the work is already done. A tolerance list, not an API
# contract: a code that never arrives costs nothing, and every one of these is a
# documented code for one of the calls below.
GONE_CODES = (
    "ResourceNotFoundException",
    "NatGatewayNotFound",
    "InvalidAllocationID.NotFound",
    "InvalidInstanceID.NotFound",
    "LoadBalancerNotFound",
)

# Error codes that mean "not yet, something else is still going away". These
# converge on a later invocation and are not failures.
PENDING_CODES = (
    "ResourceInUseException",
    "InvalidRequestException",
    "InvalidIPAddress.InUse",
    "ResourceInUse",
)


class KillIncomplete(Exception):
    """Raised when a step failed for a reason that is not already-gone or not-yet."""


def _now():
    """Current time in UTC. A seam so the tests can hold the clock still."""
    return datetime.datetime.now(datetime.timezone.utc)


def _config():
    """Read configuration from the environment, with the defaults the stack sets."""
    regions = [r.strip() for r in os.environ.get("REGIONS", "").split(",") if r.strip()]
    if not regions:
        # Lambda sets AWS_REGION itself. Falling back to it keeps the function
        # working on its own region if REGIONS is ever unset.
        regions = [os.environ.get("AWS_REGION", "us-east-1")]

    return {
        "project_tag": os.environ.get("PROJECT_TAG", "terraform-llm-eks"),
        "cluster_name": os.environ.get("CLUSTER_NAME", "llm-eks"),
        "window_group": os.environ.get("WINDOW_GROUP", ""),
        "regions": regions,
        "max_age_minutes": int(
            os.environ.get("MAX_AGE_MINUTES", DEFAULT_MAX_AGE_MINUTES)
        ),
        "orphan_grace_minutes": int(
            os.environ.get("ORPHAN_GRACE_MINUTES", DEFAULT_ORPHAN_GRACE_MINUTES)
        ),
        "dry_run": os.environ.get("DRY_RUN", "false").lower() == "true",
    }


def _mode(event):
    """Work out what the caller wants.

    An SNS envelope is always a stop-everything signal. Anything else carries an
    explicit mode, and the default is the conservative one: age-based sweeping.
    """
    if isinstance(event, dict) and event.get("Records"):
        first = event["Records"][0]
        if first.get("EventSource") == "aws:sns" or first.get("Sns"):
            return "kill_all"

    if isinstance(event, dict):
        requested = event.get("mode", "sweep")
        if requested == "full_stop":
            # The prose name for what kill_all does. Accepted so that a caller
            # can say what it means.
            return "kill_all"
        if requested in ("sweep", "kill_all", "report"):
            return requested
        raise ValueError("unknown mode: {0}".format(requested))

    return "sweep"


def _age_minutes(moment, now):
    """Minutes between a timestamp and now, never negative."""
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    delta = now - moment
    return max(0.0, delta.total_seconds() / 60.0)


def _pages(client, operation, **kwargs):
    """Every page of a paginated call."""
    paginator = client.get_paginator(operation)
    return paginator.paginate(**kwargs)


def _error_code(error):
    """The service error code out of a ClientError, or the empty string."""
    if isinstance(error, ClientError):
        return error.response.get("Error", {}).get("Code", "")
    return ""


class Steps:
    """What one invocation did, is waiting on, and could not do.

    Collecting instead of raising is what lets a single pass do everything it
    can: a NAT gateway that cannot be deleted must not stop the cluster from
    being deleted.
    """

    def __init__(self):
        self.done = []
        self.pending = []
        self.failed = []

    def call(self, what, function, **kwargs):
        """Make one mutating call and classify the outcome."""
        try:
            function(**kwargs)
        except ClientError as error:  # noqa: PERF203 - one call, one verdict
            code = _error_code(error)
            if code in GONE_CODES:
                self.done.append("{0} (already gone)".format(what))
                return True
            if code in PENDING_CODES:
                self.pending.append("{0} ({1})".format(what, code))
                return False
            self.failed.append("{0} ({1})".format(what, code or error.__class__.__name__))
            return False
        except Exception as error:  # noqa: BLE001 - the alarm needs the reason, not a traceback
            self.failed.append("{0} ({1})".format(what, error.__class__.__name__))
            return False
        self.done.append(what)
        return True

    def read(self, what, function, **kwargs):
        """Make one read. A read that fails is a failure, and returns None."""
        try:
            return function(**kwargs)
        except ClientError as error:
            code = _error_code(error)
            if code in GONE_CODES:
                return None
            self.failed.append("{0} ({1})".format(what, code or "ClientError"))
            return None
        except Exception as error:  # noqa: BLE001
            self.failed.append("{0} ({1})".format(what, error.__class__.__name__))
            return None


def _find_instances(ec2, project_tag):
    """Every project-tagged instance in a billable state, with its age inputs."""
    found = []
    for page in _pages(
        ec2,
        "describe_instances",
        Filters=[
            {"Name": "tag:Project", "Values": [project_tag]},
            {"Name": "instance-state-name", "Values": BILLABLE_STATES},
        ],
    ):
        for reservation in page.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                found.append(
                    {
                        "instance_id": instance["InstanceId"],
                        "instance_type": instance.get("InstanceType", "unknown"),
                        "state": instance.get("State", {}).get("Name", "unknown"),
                        "launch_time": instance.get("LaunchTime"),
                    }
                )
    return found


def _aged(instances, max_age_minutes, now):
    """The instances that have outlived the longest window the protocol allows."""
    aged = []
    for instance in instances:
        launch_time = instance.get("launch_time")
        if launch_time is None:
            # An instance whose launch time cannot be read is treated as old. The
            # cheap mistake is terminating something young; the expensive one is
            # leaving a GPU node running because a field was missing.
            aged.append(instance)
            continue
        if _age_minutes(launch_time, now) >= max_age_minutes:
            aged.append(instance)
    return aged


def _find_cluster(eks, steps, cluster_name, project_tag):
    """The project cluster in this region, if it exists.

    Selected by name, because the name is fixed by the project contract and the
    kill role's policy is scoped to that one cluster ARN. A cluster of that name
    carrying a different Project tag belongs to somebody else and is left alone;
    one carrying no Project tag at all is still ours to stop, because an
    untagged cluster is exactly the resource nothing else in this project can
    see.
    """
    response = steps.read(
        "describe cluster {0}".format(cluster_name), eks.describe_cluster, name=cluster_name
    )
    if not response:
        return None
    cluster = response.get("cluster", {})
    tags = cluster.get("tags") or {}
    if tags.get("Project", project_tag) != project_tag:
        return None
    return {
        "name": cluster.get("name", cluster_name),
        "status": cluster.get("status", "unknown"),
        "created_at": cluster.get("createdAt"),
    }


def _find_node_groups(eks, steps, cluster_name):
    """Every managed node group of the cluster, with its scaling configuration."""
    names = []
    try:
        for page in _pages(eks, "list_nodegroups", clusterName=cluster_name):
            names.extend(page.get("nodegroups", []))
    except ClientError as error:
        if _error_code(error) not in GONE_CODES:
            steps.failed.append("list node groups ({0})".format(_error_code(error)))
        return []

    groups = []
    for name in names:
        response = steps.read(
            "describe node group {0}".format(name),
            eks.describe_nodegroup,
            clusterName=cluster_name,
            nodegroupName=name,
        )
        scaling = {}
        status = "unknown"
        if response:
            node_group = response.get("nodegroup", {})
            scaling = node_group.get("scalingConfig", {}) or {}
            status = node_group.get("status", "unknown")
        groups.append(
            {
                "name": name,
                "status": status,
                "min_size": scaling.get("minSize"),
                "desired_size": scaling.get("desiredSize"),
            }
        )
    return groups


def _scale_node_groups_to_zero(eks, steps, cluster_name, node_groups, dry_run):
    """Set every node group's minimum and desired size to zero.

    maxSize is left alone: the API requires it to be at least 1, and it is the
    ceiling rather than the thing that is running. Setting minSize and
    desiredSize to zero is what stops the Auto Scaling group replacing a node
    that has just been terminated.
    """
    scaled = []
    for group in node_groups:
        if group["min_size"] == 0 and group["desired_size"] == 0:
            continue
        scaled.append(group["name"])
        if dry_run:
            continue
        steps.call(
            "scale node group {0} to zero".format(group["name"]),
            eks.update_nodegroup_config,
            clusterName=cluster_name,
            nodegroupName=group["name"],
            scalingConfig={"minSize": 0, "desiredSize": 0},
        )
    return scaled


def _delete_node_groups(eks, steps, cluster_name, node_groups, dry_run):
    """Delete every managed node group, so the cluster can be deleted."""
    deleted = []
    for group in node_groups:
        if group["status"] == "DELETING":
            continue
        deleted.append(group["name"])
        if dry_run:
            continue
        steps.call(
            "delete node group {0}".format(group["name"]),
            eks.delete_nodegroup,
            clusterName=cluster_name,
            nodegroupName=group["name"],
        )
    return deleted


def _terminate(ec2, steps, instance_ids, dry_run):
    """Terminate instances one at a time.

    One call per instance rather than one call for the batch: a single
    un-terminatable instance in a batch fails the whole call, and the one that
    cannot be terminated is exactly the one worth knowing about.
    """
    terminated = []
    for instance_id in instance_ids:
        if dry_run:
            continue
        if steps.call(
            "terminate {0}".format(instance_id),
            ec2.terminate_instances,
            InstanceIds=[instance_id],
        ):
            terminated.append(instance_id)
    return terminated


def _project_vpc_ids(ec2, steps, project_tag):
    """VPC IDs carrying the project tag."""
    vpc_ids = []
    try:
        for page in _pages(
            ec2, "describe_vpcs", Filters=[{"Name": "tag:Project", "Values": [project_tag]}]
        ):
            vpc_ids.extend(vpc.get("VpcId") for vpc in page.get("Vpcs", []))
    except ClientError as error:
        steps.failed.append("describe VPCs ({0})".format(_error_code(error)))
    return [vpc_id for vpc_id in vpc_ids if vpc_id]


def _delete_load_balancers(elbv2, elb, steps, vpc_ids, dry_run):
    """Delete every load balancer in a project VPC, both generations.

    Selected by VPC rather than by tag on purpose. A load balancer created by a
    Kubernetes Service carries the kubernetes.io tags and never the project tag,
    so a tag filter would miss the one case where a load balancer appears
    without anybody writing Terraform for it.
    """
    deleted = []
    if not vpc_ids:
        return deleted

    try:
        for page in _pages(elbv2, "describe_load_balancers"):
            for balancer in page.get("LoadBalancers", []):
                if balancer.get("VpcId") not in vpc_ids:
                    continue
                name = balancer.get("LoadBalancerName", balancer.get("LoadBalancerArn"))
                deleted.append(name)
                if not dry_run:
                    steps.call(
                        "delete load balancer {0}".format(name),
                        elbv2.delete_load_balancer,
                        LoadBalancerArn=balancer["LoadBalancerArn"],
                    )
    except ClientError as error:
        steps.failed.append("describe load balancers ({0})".format(_error_code(error)))

    try:
        for page in _pages(elb, "describe_load_balancers"):
            for balancer in page.get("LoadBalancerDescriptions", []):
                if balancer.get("VPCId") not in vpc_ids:
                    continue
                name = balancer["LoadBalancerName"]
                deleted.append(name)
                if not dry_run:
                    steps.call(
                        "delete classic load balancer {0}".format(name),
                        elb.delete_load_balancer,
                        LoadBalancerName=name,
                    )
    except ClientError as error:
        steps.failed.append("describe classic load balancers ({0})".format(_error_code(error)))

    return deleted


def _find_nat_gateways(ec2, steps, project_tag):
    """Project-tagged NAT gateways that still exist, with their creation times."""
    gateways = []
    try:
        for page in _pages(
            ec2,
            "describe_nat_gateways",
            Filters=[{"Name": "tag:Project", "Values": [project_tag]}],
        ):
            for gateway in page.get("NatGateways", []):
                if gateway.get("State") in NAT_GONE_STATES:
                    continue
                gateways.append(
                    {
                        "id": gateway["NatGatewayId"],
                        "state": gateway.get("State", "unknown"),
                        "created_at": gateway.get("CreateTime"),
                    }
                )
    except ClientError as error:
        steps.failed.append("describe NAT gateways ({0})".format(_error_code(error)))
    return gateways


def _delete_nat_gateways(ec2, steps, gateways, dry_run):
    """Delete every project-tagged NAT gateway."""
    deleted = []
    for gateway in gateways:
        deleted.append(gateway["id"])
        if dry_run:
            continue
        steps.call(
            "delete NAT gateway {0}".format(gateway["id"]),
            ec2.delete_nat_gateway,
            NatGatewayId=gateway["id"],
        )
    return deleted


def _release_addresses(ec2, steps, project_tag, dry_run):
    """Release project-tagged Elastic IPs that are not associated with anything.

    An in-use public IPv4 address is charged by the hour, and the NAT gateway's
    address stays associated until the gateway has finished deleting. So the
    first pass releases nothing and a later pass releases it, which is the same
    convergence the cluster deletion relies on.
    """
    released = []
    response = steps.read(
        "describe addresses",
        ec2.describe_addresses,
        Filters=[{"Name": "tag:Project", "Values": [project_tag]}],
    )
    if not response:
        return released

    for address in response.get("Addresses", []):
        allocation_id = address.get("AllocationId")
        if not allocation_id or address.get("AssociationId"):
            continue
        released.append(allocation_id)
        if dry_run:
            continue
        steps.call(
            "release address {0}".format(allocation_id),
            ec2.release_address,
            AllocationId=allocation_id,
        )
    return released


def _window_pending(scheduler, steps, window_group, now):
    """True when a one-shot window timer is still in the future.

    The sweeper uses this to decide whether an hourly resource with no instances
    is an orphan or a window that is legitimately mid-apply: a cluster exists for
    ten minutes or so before its first node does, and a window in which a node
    group launch is being debugged can sit there for much longer than that.

    Anything unexpected here answers True. Refusing to collect an orphan costs
    an hour of a control plane; collecting one that was still in use costs the
    author their window.
    """
    if not window_group:
        return True

    try:
        names = []
        for page in _pages(scheduler, "list_schedules", GroupName=window_group):
            for summary in page.get("Schedules", []):
                if summary.get("State") == "DISABLED":
                    continue
                names.append(summary["Name"])
    except Exception as error:  # noqa: BLE001 - any doubt means "a window is open"
        steps.pending.append("list window timers ({0})".format(error.__class__.__name__))
        return True

    for name in names:
        try:
            schedule = scheduler.get_schedule(GroupName=window_group, Name=name)
        except Exception as error:  # noqa: BLE001
            steps.pending.append("read window timer {0} ({1})".format(name, error.__class__.__name__))
            return True
        fire_at = _fire_time(schedule.get("ScheduleExpression", ""))
        if fire_at is None or fire_at > now:
            return True
    return False


def _fire_time(expression):
    """The instant an `at(...)` schedule expression fires, or None.

    `mise run up` creates the one-shot timer as `at(yyyy-mm-ddThh:mm:ss)` with
    the schedule timezone set to UTC. Any other shape is not a one-shot window
    timer and is read as pending by the caller.
    https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html
    """
    text = expression.strip()
    if not text.startswith("at(") or not text.endswith(")"):
        return None
    try:
        moment = datetime.datetime.strptime(text[3:-1], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    return moment.replace(tzinfo=datetime.timezone.utc)


def _orphans(cluster, gateways, now, grace_minutes):
    """Hourly resources that have been running with no instances long enough.

    Reached only when no project-tagged instance is running and no window timer
    is pending, so the question left is whether this is a window that has not
    launched a node yet.
    """
    orphans = []
    if cluster:
        created = cluster.get("created_at")
        if created is None or _age_minutes(created, now) >= grace_minutes:
            orphans.append("cluster {0}".format(cluster["name"]))
    for gateway in gateways:
        created = gateway.get("created_at")
        if created is None or _age_minutes(created, now) >= grace_minutes:
            orphans.append("nat {0}".format(gateway["id"]))
    return orphans


def _clients(region):
    """One client per service for one region. A seam for the tests."""
    return {
        "ec2": boto3.client("ec2", region_name=region),
        "eks": boto3.client("eks", region_name=region),
        "elbv2": boto3.client("elbv2", region_name=region),
        "elb": boto3.client("elb", region_name=region),
    }


def _stop_region(region, mode, config, now, window_pending, steps):
    """Do as much of the stop as this region needs, in the documented order."""
    clients = _clients(region)
    ec2 = clients["ec2"]
    eks = clients["eks"]

    dry_run = config["dry_run"] or mode == "report"

    instances = _find_instances(ec2, config["project_tag"])
    cluster = _find_cluster(eks, steps, config["cluster_name"], config["project_tag"])
    gateways = _find_nat_gateways(ec2, steps, config["project_tag"])

    aged = _aged(instances, config["max_age_minutes"], now)
    orphans = []
    if mode == "sweep" and not instances and not window_pending:
        orphans = _orphans(cluster, gateways, now, config["orphan_grace_minutes"])

    full_stop = mode in ("kill_all", "report") or bool(orphans)
    # An instance older than the longest window the approval form can grant
    # means no window is legitimately open, so every project-tagged instance in
    # the region goes, not only the aged ones. Leaving the young ones would keep
    # a GPU node that Karpenter replaced late in the window running for hours
    # after everything around it was stopped.
    stopping = full_stop or bool(aged)

    result = {
        "region": region,
        "full_stop": full_stop,
        "aged": [item["instance_id"] for item in aged],
        "orphans": orphans,
        "cluster": cluster["name"] if cluster else None,
        "found": len(instances),
        "selected": [],
        "scaled": [],
        "node_groups_deleted": [],
        "terminated": [],
        "load_balancers_deleted": [],
        "nat_gateways_deleted": [],
        "addresses_released": [],
        "cluster_deleted": False,
    }
    if not stopping:
        return result

    node_groups = _find_node_groups(eks, steps, cluster["name"]) if cluster else []

    # 1. Nothing may replace what is about to be terminated.
    result["scaled"] = _scale_node_groups_to_zero(
        eks, steps, cluster["name"] if cluster else "", node_groups, dry_run
    )

    # 2. The cluster cannot be deleted while its node groups exist.
    if full_stop and cluster:
        result["node_groups_deleted"] = _delete_node_groups(
            eks, steps, cluster["name"], node_groups, dry_run
        )

    # 3. Everything project-tagged that is running.
    result["selected"] = [item["instance_id"] for item in instances]
    result["terminated"] = _terminate(ec2, steps, result["selected"], dry_run)

    if not full_stop:
        return result

    # 4. The charges that do not care whether an instance exists.
    result["load_balancers_deleted"] = _delete_load_balancers(
        clients["elbv2"],
        clients["elb"],
        steps,
        _project_vpc_ids(ec2, steps, config["project_tag"]),
        dry_run,
    )
    result["nat_gateways_deleted"] = _delete_nat_gateways(ec2, steps, gateways, dry_run)

    if cluster and not dry_run:
        # Fails with ResourceInUseException while the node groups are still
        # deleting, which is recorded as pending. The sweeper finishes the job.
        result["cluster_deleted"] = steps.call(
            "delete cluster {0}".format(cluster["name"]),
            eks.delete_cluster,
            name=cluster["name"],
        )

    result["addresses_released"] = _release_addresses(
        ec2, steps, config["project_tag"], dry_run
    )
    return result


def handler(event, context):  # noqa: ARG001 - context is part of the Lambda contract
    """Lambda entry point."""
    config = _config()
    mode = _mode(event)

    if isinstance(event, dict) and "max_age_minutes" in event:
        config["max_age_minutes"] = int(event["max_age_minutes"])

    dry_run = config["dry_run"] or mode == "report"
    now = _now()
    steps = Steps()

    # Only the sweeper asks. The other two modes stop regardless, and reporting
    # None rather than True keeps the log honest about what was checked.
    window_pending = None
    if mode == "sweep":
        window_pending = _window_pending(
            boto3.client("scheduler"), steps, config["window_group"], now
        )

    regions = []
    for region in config["regions"]:
        regions.append(_stop_region(region, mode, config, now, window_pending, steps))

    result = {
        "mode": mode,
        "dry_run": dry_run,
        "project_tag": config["project_tag"],
        "max_age_minutes": config["max_age_minutes"],
        "window_id": event.get("window_id") if isinstance(event, dict) else None,
        "window_pending": window_pending,
        "regions": regions,
        "found": sum(item["found"] for item in regions),
        "selected": [i for item in regions for i in item["selected"]],
        "terminated": [i for item in regions for i in item["terminated"]],
        "done": steps.done,
        "pending": steps.pending,
        "failed": steps.failed,
    }

    LOG.info(json.dumps(result, default=str))

    if steps.failed:
        # Everything that could be done has been done. Failing now is what puts
        # the event on the dead-letter queue and lights the error alarm, which
        # is the only way anybody hears that the kill path is broken.
        raise KillIncomplete("; ".join(steps.failed))

    return result
