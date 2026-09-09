"""Tests for the kill Lambda.

Standard library plus unittest.mock. No network, no credentials: every client is
a stub and the clock is patched, so nothing here ever resolves an endpoint.

Run from this directory with `python3 -m unittest`.
"""

import datetime
import unittest
from unittest import mock

from botocore.exceptions import ClientError

import handler

NOW = datetime.datetime(2026, 9, 8, 12, 0, 0, tzinfo=datetime.timezone.utc)

ENV = {
    "PROJECT_TAG": "terraform-llm-eks",
    "CLUSTER_NAME": "llm-eks",
    "WINDOW_GROUP": "llm-eks-windows",
    "REGIONS": "us-east-1",
    "MAX_AGE_MINUTES": "510",
    "ORPHAN_GRACE_MINUTES": "60",
    "DRY_RUN": "false",
}


def client_error(code, operation="Whatever"):
    return ClientError({"Error": {"Code": code, "Message": code}}, operation)


def instance(instance_id, minutes_old, instance_type="g6.xlarge", state="running"):
    """One entry as _find_instances returns it."""
    return {
        "instance_id": instance_id,
        "instance_type": instance_type,
        "state": state,
        "launch_time": NOW - datetime.timedelta(minutes=minutes_old),
    }


def describe_page(instances):
    """One page as the EC2 describe_instances paginator returns it."""
    return {
        "Reservations": [
            {
                "Instances": [
                    {
                        "InstanceId": item["instance_id"],
                        "InstanceType": item["instance_type"],
                        "State": {"Name": item["state"]},
                        "LaunchTime": item["launch_time"],
                    }
                    for item in instances
                ]
            }
        ]
    }


def fake_client(pages=None):
    """A stub whose paginators yield the pages given, keyed by operation name."""
    client = mock.MagicMock()
    client.paginators = {}
    supplied = pages or {}

    def get_paginator(operation):
        if operation not in client.paginators:
            paginator = mock.MagicMock()
            paginator.paginate.return_value = supplied.get(operation, [{}])
            client.paginators[operation] = paginator
        return client.paginators[operation]

    client.get_paginator.side_effect = get_paginator
    return client


def paginate_kwargs(client, operation):
    _, kwargs = client.paginators[operation].paginate.call_args
    return kwargs


def region_clients(
    instances=(),
    cluster=None,
    node_groups=(),
    nat_gateways=(),
    vpcs=(),
    addresses=(),
    load_balancers=(),
    classic_load_balancers=(),
):
    """The four clients _clients() builds, stubbed with the state given."""
    ec2 = fake_client(
        {
            "describe_instances": [describe_page(list(instances))],
            "describe_nat_gateways": [{"NatGateways": list(nat_gateways)}],
            "describe_vpcs": [{"Vpcs": [{"VpcId": vpc} for vpc in vpcs]}],
        }
    )
    ec2.describe_addresses.return_value = {"Addresses": list(addresses)}

    eks = fake_client(
        {"list_nodegroups": [{"nodegroups": [item["name"] for item in node_groups]}]}
    )
    if cluster is None:
        eks.describe_cluster.side_effect = client_error(
            "ResourceNotFoundException", "DescribeCluster"
        )
    else:
        eks.describe_cluster.return_value = {"cluster": cluster}

    by_name = {item["name"]: item for item in node_groups}
    eks.describe_nodegroup.side_effect = lambda clusterName, nodegroupName: {
        "nodegroup": by_name[nodegroupName]
    }

    elbv2 = fake_client({"describe_load_balancers": [{"LoadBalancers": list(load_balancers)}]})
    elb = fake_client(
        {
            "describe_load_balancers": [
                {"LoadBalancerDescriptions": list(classic_load_balancers)}
            ]
        }
    )
    return {"ec2": ec2, "eks": eks, "elbv2": elbv2, "elb": elb}


def cluster(name="llm-eks", minutes_old=30, status="ACTIVE", tags=None):
    return {
        "name": name,
        "status": status,
        "createdAt": NOW - datetime.timedelta(minutes=minutes_old),
        "tags": {"Project": "terraform-llm-eks"} if tags is None else tags,
    }


def node_group(name, min_size=2, desired_size=2, status="ACTIVE"):
    return {
        "name": name,
        "nodegroupName": name,
        "status": status,
        "scalingConfig": {"minSize": min_size, "maxSize": 4, "desiredSize": desired_size},
    }


def nat_gateway(gateway_id="nat-1", minutes_old=30, state="available"):
    return {
        "NatGatewayId": gateway_id,
        "State": state,
        "CreateTime": NOW - datetime.timedelta(minutes=minutes_old),
    }


def scheduler_client(timers=()):
    """A scheduler stub. Each timer is (name, fire_expression, state)."""
    client = fake_client(
        {
            "list_schedules": [
                {"Schedules": [{"Name": name, "State": state} for name, _, state in timers]}
            ]
        }
    )
    by_name = {name: expression for name, expression, _ in timers}
    client.get_schedule.side_effect = lambda GroupName, Name: {
        "ScheduleExpression": by_name[Name]
    }
    return client


class ModeTest(unittest.TestCase):
    def test_sns_envelope_means_kill_all(self):
        event = {"Records": [{"EventSource": "aws:sns", "Sns": {"Message": "over"}}]}
        self.assertEqual(handler._mode(event), "kill_all")

    def test_sns_envelope_without_eventsource_still_means_kill_all(self):
        self.assertEqual(handler._mode({"Records": [{"Sns": {"Message": "x"}}]}), "kill_all")

    def test_default_is_sweep(self):
        self.assertEqual(handler._mode({}), "sweep")

    def test_explicit_modes_are_accepted(self):
        for mode in ("sweep", "kill_all", "report"):
            self.assertEqual(handler._mode({"mode": mode}), mode)

    def test_full_stop_is_an_alias_for_kill_all(self):
        self.assertEqual(handler._mode({"mode": "full_stop"}), "kill_all")

    def test_unknown_mode_is_refused(self):
        with self.assertRaises(ValueError):
            handler._mode({"mode": "delete_the_account"})


class AgeTest(unittest.TestCase):
    def test_age_in_minutes(self):
        self.assertAlmostEqual(
            handler._age_minutes(NOW - datetime.timedelta(minutes=90), NOW), 90.0
        )

    def test_naive_timestamp_is_read_as_utc(self):
        naive = (NOW - datetime.timedelta(minutes=30)).replace(tzinfo=None)
        self.assertAlmostEqual(handler._age_minutes(naive, NOW), 30.0)

    def test_future_timestamp_is_not_negative(self):
        self.assertEqual(
            handler._age_minutes(NOW + datetime.timedelta(minutes=5), NOW), 0.0
        )

    def test_aged_takes_only_instances_at_or_over_the_age(self):
        instances = [instance("i-young", 10), instance("i-exactly", 510), instance("i-old", 900)]
        aged = handler._aged(instances, 510, NOW)
        self.assertEqual([item["instance_id"] for item in aged], ["i-exactly", "i-old"])

    def test_aged_takes_an_instance_with_no_launch_time(self):
        orphan = instance("i-nolaunch", 1)
        orphan["launch_time"] = None
        self.assertEqual(
            [item["instance_id"] for item in handler._aged([orphan], 510, NOW)],
            ["i-nolaunch"],
        )


class FireTimeTest(unittest.TestCase):
    def test_reads_a_one_shot_expression_as_utc(self):
        self.assertEqual(
            handler._fire_time("at(2026-09-08T18:00:00)"),
            datetime.datetime(2026, 9, 8, 18, 0, 0, tzinfo=datetime.timezone.utc),
        )

    def test_anything_else_is_unreadable(self):
        for expression in ("rate(15 minutes)", "cron(0 12 * * ? *)", "", "at(nonsense)"):
            self.assertIsNone(handler._fire_time(expression))


class WindowPendingTest(unittest.TestCase):
    def test_no_group_configured_means_assume_a_window_is_open(self):
        steps = handler.Steps()
        self.assertTrue(handler._window_pending(fake_client(), steps, "", NOW))

    def test_a_timer_in_the_future_is_a_window(self):
        steps = handler.Steps()
        client = scheduler_client([("llm-eks-window-3", "at(2026-09-08T18:00:00)", "ENABLED")])
        self.assertTrue(handler._window_pending(client, steps, "llm-eks-windows", NOW))

    def test_a_timer_that_has_already_fired_is_not_a_window(self):
        steps = handler.Steps()
        client = scheduler_client([("llm-eks-window-3", "at(2026-09-08T06:00:00)", "ENABLED")])
        self.assertFalse(handler._window_pending(client, steps, "llm-eks-windows", NOW))

    def test_no_timers_at_all_is_not_a_window(self):
        steps = handler.Steps()
        self.assertFalse(
            handler._window_pending(scheduler_client([]), steps, "llm-eks-windows", NOW)
        )

    def test_an_unreadable_expression_is_treated_as_a_window(self):
        steps = handler.Steps()
        client = scheduler_client([("odd", "rate(1 hours)", "ENABLED")])
        self.assertTrue(handler._window_pending(client, steps, "llm-eks-windows", NOW))

    def test_a_scheduler_error_is_treated_as_a_window(self):
        steps = handler.Steps()
        client = fake_client()
        client.get_paginator.side_effect = client_error("AccessDeniedException", "ListSchedules")
        self.assertTrue(handler._window_pending(client, steps, "llm-eks-windows", NOW))
        self.assertEqual(steps.failed, [])
        self.assertEqual(len(steps.pending), 1)


def found_cluster(minutes_old=30, name="llm-eks"):
    """A cluster in the shape _find_cluster returns."""
    return {
        "name": name,
        "status": "ACTIVE",
        "created_at": NOW - datetime.timedelta(minutes=minutes_old),
    }


def found_gateway(minutes_old=30, gateway_id="nat-1"):
    """A NAT gateway in the shape _find_nat_gateways returns."""
    return {
        "id": gateway_id,
        "state": "available",
        "created_at": NOW - datetime.timedelta(minutes=minutes_old),
    }


class OrphanTest(unittest.TestCase):
    def test_a_young_cluster_is_not_an_orphan(self):
        self.assertEqual(handler._orphans(found_cluster(minutes_old=10), [], NOW, 60), [])

    def test_an_old_cluster_and_an_old_gateway_are_orphans(self):
        found = handler._orphans(
            found_cluster(minutes_old=120), [found_gateway(minutes_old=180)], NOW, 60
        )
        self.assertEqual(found, ["cluster llm-eks", "nat nat-1"])

    def test_a_missing_creation_time_counts_as_old(self):
        gateway = found_gateway()
        gateway["created_at"] = None
        self.assertEqual(handler._orphans(None, [gateway], NOW, 60), ["nat nat-1"])


class StepsTest(unittest.TestCase):
    def test_a_gone_error_counts_as_done(self):
        steps = handler.Steps()
        call = mock.MagicMock(side_effect=client_error("ResourceNotFoundException"))
        self.assertTrue(steps.call("delete it", call))
        self.assertEqual(steps.failed, [])
        self.assertEqual(len(steps.done), 1)

    def test_an_in_use_error_is_pending_not_failed(self):
        steps = handler.Steps()
        call = mock.MagicMock(side_effect=client_error("ResourceInUseException"))
        self.assertFalse(steps.call("delete it", call))
        self.assertEqual(steps.failed, [])
        self.assertEqual(len(steps.pending), 1)

    def test_anything_else_is_a_failure(self):
        steps = handler.Steps()
        call = mock.MagicMock(side_effect=client_error("AccessDenied"))
        self.assertFalse(steps.call("delete it", call))
        self.assertEqual(len(steps.failed), 1)


class HandlerTest(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict("os.environ", dict(ENV), clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def run_handler(self, event, clients, timers=(), regions=None):
        """Run the handler against one stubbed region, or several."""
        by_region = clients if isinstance(clients, dict) and "ec2" not in clients else None
        scheduler = scheduler_client(timers)

        def clients_for(region):
            return by_region[region] if by_region else clients

        with mock.patch.object(handler, "_now", return_value=NOW), mock.patch.object(
            handler, "_clients", side_effect=clients_for
        ), mock.patch.object(handler.boto3, "client", return_value=scheduler):
            result = handler.handler(event, None)
        return result

    # ---------------------------------------------------------------- sweeping

    def test_a_sweep_with_nothing_running_changes_nothing(self):
        clients = region_clients()
        result = self.run_handler({}, clients)
        clients["ec2"].terminate_instances.assert_not_called()
        clients["eks"].update_nodegroup_config.assert_not_called()
        self.assertEqual(result["terminated"], [])
        self.assertFalse(result["regions"][0]["full_stop"])

    def test_a_sweep_leaves_a_young_instance_alone(self):
        clients = region_clients(
            instances=[instance("i-young", 30)],
            cluster=cluster(),
            node_groups=[node_group("system")],
        )
        result = self.run_handler({}, clients)
        clients["ec2"].terminate_instances.assert_not_called()
        clients["eks"].update_nodegroup_config.assert_not_called()
        self.assertEqual(result["found"], 1)

    def test_an_aged_instance_scales_the_node_group_before_terminating(self):
        clients = region_clients(
            instances=[instance("i-old", 900), instance("i-young", 5)],
            cluster=cluster(),
            node_groups=[node_group("system")],
        )
        result = self.run_handler({}, clients)

        clients["eks"].update_nodegroup_config.assert_called_once_with(
            clusterName="llm-eks",
            nodegroupName="system",
            scalingConfig={"minSize": 0, "desiredSize": 0},
        )
        # Everything goes, not only the aged one: an aged instance means the
        # longest approvable window has already been exceeded.
        self.assertEqual(sorted(result["terminated"]), ["i-old", "i-young"])
        # A sweep on age stops the compute and leaves the hourly resources for
        # the escalation pass.
        clients["eks"].delete_cluster.assert_not_called()
        clients["ec2"].delete_nat_gateway.assert_not_called()

    def test_a_node_group_already_at_zero_is_not_scaled_again(self):
        clients = region_clients(
            instances=[instance("i-old", 900)],
            cluster=cluster(),
            node_groups=[node_group("system", min_size=0, desired_size=0)],
        )
        self.run_handler({}, clients)
        clients["eks"].update_nodegroup_config.assert_not_called()

    def test_a_sweep_escalates_to_a_full_stop_for_an_orphaned_cluster(self):
        clients = region_clients(
            cluster=cluster(minutes_old=200),
            node_groups=[node_group("system")],
            nat_gateways=[nat_gateway(minutes_old=200)],
            vpcs=["vpc-1"],
        )
        result = self.run_handler({}, clients, timers=[("w", "at(2026-09-08T06:00:00)", "ENABLED")])

        self.assertTrue(result["regions"][0]["full_stop"])
        self.assertEqual(result["regions"][0]["orphans"], ["cluster llm-eks", "nat nat-1"])
        clients["eks"].delete_nodegroup.assert_called_once_with(
            clusterName="llm-eks", nodegroupName="system"
        )
        clients["ec2"].delete_nat_gateway.assert_called_once_with(NatGatewayId="nat-1")
        clients["eks"].delete_cluster.assert_called_once_with(name="llm-eks")

    def test_a_pending_window_stops_the_escalation(self):
        clients = region_clients(
            cluster=cluster(minutes_old=200),
            node_groups=[node_group("system")],
            nat_gateways=[nat_gateway(minutes_old=200)],
        )
        result = self.run_handler({}, clients, timers=[("w", "at(2026-09-08T18:00:00)", "ENABLED")])

        self.assertTrue(result["window_pending"])
        self.assertFalse(result["regions"][0]["full_stop"])
        clients["eks"].delete_cluster.assert_not_called()
        clients["ec2"].delete_nat_gateway.assert_not_called()

    def test_a_running_instance_stops_the_escalation(self):
        clients = region_clients(
            instances=[instance("i-young", 20)],
            cluster=cluster(minutes_old=200),
            node_groups=[node_group("system")],
            nat_gateways=[nat_gateway(minutes_old=200)],
        )
        result = self.run_handler({}, clients, timers=[])
        self.assertEqual(result["regions"][0]["orphans"], [])
        clients["eks"].delete_cluster.assert_not_called()

    # ------------------------------------------------------------- full stop

    def test_the_window_timer_stops_everything_that_bills(self):
        clients = region_clients(
            instances=[instance("i-gpu", 30), instance("i-system", 200)],
            cluster=cluster(),
            node_groups=[node_group("system")],
            nat_gateways=[nat_gateway()],
            vpcs=["vpc-1"],
            addresses=[
                {"AllocationId": "eipalloc-free"},
                {"AllocationId": "eipalloc-busy", "AssociationId": "eipassoc-1"},
            ],
            load_balancers=[
                {"LoadBalancerArn": "arn:lb/app/a/1", "LoadBalancerName": "a", "VpcId": "vpc-1"},
                {"LoadBalancerArn": "arn:lb/app/b/2", "LoadBalancerName": "b", "VpcId": "vpc-other"},
            ],
            classic_load_balancers=[{"LoadBalancerName": "k8s-classic", "VPCId": "vpc-1"}],
        )
        result = self.run_handler({"mode": "kill_all", "window_id": "3"}, clients)

        eks = clients["eks"]
        ec2 = clients["ec2"]
        eks.update_nodegroup_config.assert_called_once()
        eks.delete_nodegroup.assert_called_once_with(clusterName="llm-eks", nodegroupName="system")
        self.assertEqual(
            sorted(call.kwargs["InstanceIds"][0] for call in ec2.terminate_instances.call_args_list),
            ["i-gpu", "i-system"],
        )
        clients["elbv2"].delete_load_balancer.assert_called_once_with(
            LoadBalancerArn="arn:lb/app/a/1"
        )
        clients["elb"].delete_load_balancer.assert_called_once_with(
            LoadBalancerName="k8s-classic"
        )
        ec2.delete_nat_gateway.assert_called_once_with(NatGatewayId="nat-1")
        eks.delete_cluster.assert_called_once_with(name="llm-eks")
        # Only the unassociated address: the NAT gateway still holds the other.
        ec2.release_address.assert_called_once_with(AllocationId="eipalloc-free")
        self.assertEqual(result["mode"], "kill_all")
        self.assertEqual(result["window_id"], "3")
        self.assertEqual(result["failed"], [])

    def test_a_spend_alert_on_the_topic_is_a_full_stop(self):
        clients = region_clients(
            instances=[instance("i-young", 2)], cluster=cluster(), node_groups=[node_group("system")]
        )
        event = {"Records": [{"EventSource": "aws:sns", "Sns": {"Message": "over"}}]}
        result = self.run_handler(event, clients)
        self.assertTrue(result["regions"][0]["full_stop"])
        clients["eks"].delete_cluster.assert_called_once_with(name="llm-eks")

    def test_a_full_stop_without_a_cluster_still_terminates_and_deletes(self):
        clients = region_clients(
            instances=[instance("i-1", 5)], nat_gateways=[nat_gateway()], vpcs=["vpc-1"]
        )
        result = self.run_handler({"mode": "kill_all"}, clients)
        self.assertIsNone(result["regions"][0]["cluster"])
        clients["ec2"].terminate_instances.assert_called_once_with(InstanceIds=["i-1"])
        clients["ec2"].delete_nat_gateway.assert_called_once_with(NatGatewayId="nat-1")
        clients["eks"].delete_cluster.assert_not_called()
        self.assertEqual(result["failed"], [])

    def test_the_node_group_scale_comes_before_the_node_group_delete(self):
        clients = region_clients(
            cluster=cluster(), node_groups=[node_group("system")], instances=[instance("i-1", 5)]
        )
        order = []
        clients["eks"].update_nodegroup_config.side_effect = lambda **_: order.append("scale")
        clients["eks"].delete_nodegroup.side_effect = lambda **_: order.append("delete")
        clients["ec2"].terminate_instances.side_effect = lambda **_: order.append("terminate")
        self.run_handler({"mode": "kill_all"}, clients)
        self.assertEqual(order, ["scale", "delete", "terminate"])

    # ------------------------------------------------------ dry runs and drills

    def test_report_mode_describes_a_full_stop_and_changes_nothing(self):
        clients = region_clients(
            instances=[instance("i-1", 5)],
            cluster=cluster(),
            node_groups=[node_group("system")],
            nat_gateways=[nat_gateway()],
            vpcs=["vpc-1"],
            addresses=[{"AllocationId": "eipalloc-free"}],
        )
        result = self.run_handler({"mode": "report"}, clients)

        clients["ec2"].terminate_instances.assert_not_called()
        clients["eks"].update_nodegroup_config.assert_not_called()
        clients["eks"].delete_nodegroup.assert_not_called()
        clients["eks"].delete_cluster.assert_not_called()
        clients["ec2"].delete_nat_gateway.assert_not_called()
        clients["ec2"].release_address.assert_not_called()
        self.assertTrue(result["dry_run"])
        self.assertEqual(result["selected"], ["i-1"])
        self.assertEqual(result["terminated"], [])
        region = result["regions"][0]
        self.assertEqual(region["scaled"], ["system"])
        self.assertEqual(region["nat_gateways_deleted"], ["nat-1"])
        self.assertEqual(region["addresses_released"], ["eipalloc-free"])

    def test_the_dry_run_environment_variable_overrides_a_real_kill(self):
        clients = region_clients(
            instances=[instance("i-1", 9)], cluster=cluster(), node_groups=[node_group("system")]
        )
        with mock.patch.dict("os.environ", {"DRY_RUN": "true"}):
            result = self.run_handler({"mode": "kill_all"}, clients)
        clients["ec2"].terminate_instances.assert_not_called()
        clients["eks"].delete_cluster.assert_not_called()
        self.assertTrue(result["dry_run"])

    # ------------------------------------------------------------ housekeeping

    def test_the_project_tag_and_states_come_from_the_environment(self):
        clients = region_clients()
        with mock.patch.dict("os.environ", {"PROJECT_TAG": "something-else"}):
            result = self.run_handler({}, clients)
        self.assertEqual(
            paginate_kwargs(clients["ec2"], "describe_instances")["Filters"],
            [
                {"Name": "tag:Project", "Values": ["something-else"]},
                {"Name": "instance-state-name", "Values": handler.BILLABLE_STATES},
            ],
        )
        self.assertEqual(result["project_tag"], "something-else")

    def test_the_event_can_shorten_the_age(self):
        clients = region_clients(
            instances=[instance("i-15", 15)], cluster=cluster(), node_groups=[node_group("system")]
        )
        result = self.run_handler({"mode": "sweep", "max_age_minutes": 10}, clients)
        clients["ec2"].terminate_instances.assert_called_once_with(InstanceIds=["i-15"])
        self.assertEqual(result["max_age_minutes"], 10)

    def test_every_configured_region_is_swept(self):
        east = region_clients(instances=[instance("i-east", 900)])
        west = region_clients(instances=[instance("i-west", 900)])
        with mock.patch.dict("os.environ", {"REGIONS": "us-east-1,us-west-2"}):
            result = self.run_handler({}, {"us-east-1": east, "us-west-2": west})
        self.assertEqual([item["region"] for item in result["regions"]], ["us-east-1", "us-west-2"])
        east["ec2"].terminate_instances.assert_called_once_with(InstanceIds=["i-east"])
        west["ec2"].terminate_instances.assert_called_once_with(InstanceIds=["i-west"])

    def test_one_unterminatable_instance_does_not_stop_the_others(self):
        clients = region_clients(
            instances=[instance("i-stuck", 900), instance("i-fine", 900)],
            cluster=cluster(),
            node_groups=[node_group("system")],
        )

        def terminate(InstanceIds):
            if InstanceIds == ["i-stuck"]:
                raise client_error("UnauthorizedOperation", "TerminateInstances")
            return {}

        clients["ec2"].terminate_instances.side_effect = terminate
        with self.assertRaises(handler.KillIncomplete):
            self.run_handler({}, clients)
        self.assertEqual(clients["ec2"].terminate_instances.call_count, 2)

    def test_a_cluster_that_cannot_be_deleted_yet_is_not_a_failure(self):
        clients = region_clients(
            instances=[instance("i-1", 5)], cluster=cluster(), node_groups=[node_group("system")]
        )
        clients["eks"].delete_cluster.side_effect = client_error(
            "ResourceInUseException", "DeleteCluster"
        )
        result = self.run_handler({"mode": "kill_all"}, clients)
        self.assertEqual(result["failed"], [])
        self.assertEqual(len(result["pending"]), 1)
        self.assertFalse(result["regions"][0]["cluster_deleted"])

    def test_a_denied_scale_still_terminates_and_then_fails_loudly(self):
        clients = region_clients(
            instances=[instance("i-1", 900)], cluster=cluster(), node_groups=[node_group("system")]
        )
        clients["eks"].update_nodegroup_config.side_effect = client_error(
            "AccessDeniedException", "UpdateNodegroupConfig"
        )
        with self.assertRaises(handler.KillIncomplete):
            self.run_handler({}, clients)
        clients["ec2"].terminate_instances.assert_called_once_with(InstanceIds=["i-1"])

    def test_a_cluster_owned_by_somebody_else_is_left_alone(self):
        clients = region_clients(
            instances=[instance("i-1", 900)],
            cluster=cluster(tags={"Project": "someone-elses-project"}),
            node_groups=[node_group("system")],
        )
        result = self.run_handler({}, clients)
        self.assertIsNone(result["regions"][0]["cluster"])
        clients["eks"].update_nodegroup_config.assert_not_called()

    def test_a_cluster_with_no_project_tag_is_still_ours(self):
        clients = region_clients(
            instances=[instance("i-1", 900)],
            cluster=cluster(tags={}),
            node_groups=[node_group("system")],
        )
        result = self.run_handler({}, clients)
        self.assertEqual(result["regions"][0]["cluster"], "llm-eks")
        clients["eks"].update_nodegroup_config.assert_called_once()


if __name__ == "__main__":
    unittest.main()
