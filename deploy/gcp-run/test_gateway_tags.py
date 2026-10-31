import copy
import unittest
from unittest.mock import patch

import deploy
import gateway_tags as tags
import production
import verify
from test_verify import SyntheticHTTP
import release
import render
from test_render import configuration


class GatewayTagsTests(unittest.TestCase):
    def setUp(self):
        self.config = configuration()
        self.resource = tags.gateway_service(self.config, render.STAGING)
        self.rid = render.release_id(self.config)
        self.active = "nextstop-gateway-" + self.rid
        self.old = "nextstop-gateway-aaaaaaaaaaaa"
        self.old_tag = "r-aaaaaaaaaaaa"
        self.expected = {self.active: 100}
        self.owned = {(self.old_tag, self.old), ("r-" + self.rid, self.active)}
        self.config["retainedTraffic"] = {"gateway": [
            {"revisionName": self.old, "percent": 100, "tag": self.old_tag}]}
        def row(revision, percent=0, tag=None):
            return {"type": tags.REVISION, "revision": revision,
                    **({"percent": percent} if percent else {}), **({"tag": tag} if tag else {})}
        self.row = row
        self.stale = row(self.old, tag=self.old_tag)
        self.desired = [row(self.active, 100), row(self.active, tag="r-" + self.rid), self.stale,
                        row(self.old, tag="external"), row("nextstop-gateway-bbbbbbbbbbbb", tag="r-bbbbbbbbbbbb")]
        self.service = {"name": self.resource, "etag": "verified-version", "generation": "7",
                        "observedGeneration": "7", "terminalCondition": {"state": "CONDITION_SUCCEEDED"},
                        "traffic": self.desired, "trafficStatuses": [
                            row(self.active, 100, "r-" + self.rid), *self.desired[2:]]}

    def test_only_initially_known_matching_tag_on_zero_percent_revision(self):
        self.assertEqual(tags.retained_routes(self.service, self.expected, self.owned, self.resource),
                         [r for r in self.desired if r != self.stale])
        self.desired[0]["percent"] = 85
        self.desired.append(self.row(self.old, 15))
        self.service["trafficStatuses"][0]["percent"] = 85
        self.service["trafficStatuses"].append(self.row(self.old, 15))
        self.assertEqual(tags.retained_routes(self.service, {self.active: 85, self.old: 15}, self.owned, self.resource), self.desired)

    def test_etag_patch_never_selects_other_services_or_retries_on_conflict(self):
        with patch.object(tags.registry, "get_token", return_value="token"), patch.object(tags, "cloud_run",
                side_effect=[self.service, release.ReleaseError("conflict")]) as api, self.assertRaises(release.ReleaseError):
            tags.retire(self.config, self.expected, target=render.STAGING)
        self.assertEqual(api.call_count, 2)
        verb, path, _, body = api.call_args.args
        self.assertEqual((verb, path), ("PATCH", self.resource + "?updateMask=traffic"))
        self.assertEqual(body, {"name": self.resource, "etag": "verified-version",
                               "traffic": [r for r in self.desired if r != self.stale]})

    def test_allocation_drift_and_unsettled_or_reassigned_tags_stop_before_patch(self):
        for key in ("desired", "status", "reassignment", "reconciling", "observedGeneration"):
            with self.subTest(key=key):
                source = copy.deepcopy(self.service)
                if key == "desired": source["traffic"][0]["percent"] = 90
                elif key == "status": source["trafficStatuses"][0]["revision"] = self.old
                elif key == "reassignment": source["trafficStatuses"][1] = self.row(self.active, tag=self.old_tag)
                else: source[key] = True
                with patch.object(tags.registry, "get_token", return_value="token"), patch.object(tags, "cloud_run",
                        return_value=source) as api, self.assertRaises(release.ReleaseError):
                    tags.retire(self.config, self.expected, target=render.STAGING)
                self.assertEqual(api.call_count, 1)

    def test_post_operation_readback_and_idempotent_retry(self):
        after = copy.deepcopy(self.service)
        for key in ("traffic", "trafficStatuses"):
            after[key] = [r for r in after[key] if r != self.stale]
        op = {"name": self.resource.split("/services/")[0] + "/operations/test", "done": True}
        with patch.object(tags.registry, "get_token", return_value="token"), patch.object(tags, "cloud_run",
                side_effect=[self.service, op, after, after]) as api:
            tags.retire(self.config, self.expected, target=render.STAGING)
            tags.retire(self.config, self.expected, target=render.STAGING)
        self.assertEqual([c.args[0] for c in api.call_args_list], ["GET", "PATCH", "GET", "GET"])
        with patch.object(tags.registry, "get_token", return_value="token"), patch.object(tags, "cloud_run",
                side_effect=[self.service, op, self.service]), self.assertRaises(release.ReleaseError):
            tags.retire(self.config, self.expected, target=render.STAGING)

    def test_mismatched_target_rejected_before_read(self):
        with patch.object(tags.registry, "get_token") as token, self.assertRaises(release.ReleaseError):
            tags.retire(dict(self.config, environment="production"), self.expected, target=render.STAGING)
        token.assert_not_called()
        unknown = render.STAGING._replace(domain="other.invalid")
        with patch.object(release, "current_services") as cloud, self.assertRaises(release.ReleaseError):
            deploy.retire_after_restoration(self.config, None, target=unknown)
        cloud.assert_not_called()
        with patch.object(release, "run") as cli, self.assertRaises(release.ReleaseError):
            deploy.deploy(self.config, target=unknown)
        cli.assert_not_called()

    def test_apply_definitions_cannot_resurrect_an_externally_retired_tag(self):
        active = {"revisionName": self.old, "tag": self.old_tag, "percent": 100}
        stale = {"revisionName": "nextstop-gateway-111111111111", "tag": "r-111111111111", "percent": 0}
        original = [active, stale]
        self.config["retainedTraffic"] = {"gateway": original}
        manifest = render.render(self.config)["gateway"]
        for status in ([active], original):
            # The second case represents desired deletion with stale controller status.
            with self.subTest(status=status):
                serving = {"metadata": {"name": "nextstop-gateway", "namespace": render.STAGING.number,
                                        "generation": 5, "resourceVersion": "approved-version"},
                           "spec": {"traffic": [active]},
                           "status": {"observedGeneration": 5, "conditions": [{"type": "Ready", "status": "True"}],
                                      "traffic": status}}
                with patch.object(tags.registry, "get_token", return_value="token"), \
                        patch.object(tags, "cloud_run", return_value=serving) as api, self.assertRaises(release.ReleaseError):
                    tags.apply_definition(manifest, original, render.STAGING)
                self.assertEqual([c.args[0] for c in api.call_args_list], ["GET"])

    def test_gateway_replace_sends_exact_version_and_never_retries_a_conflict(self):
        original = self.config["retainedTraffic"]["gateway"]
        manifest = render.render(self.config)["gateway"]
        source = {"metadata": {"name": "nextstop-gateway", "namespace": render.STAGING.number,
                               "generation": 6, "resourceVersion": "read-version"},
                  "spec": {"traffic": original}, "status": {"observedGeneration": 6, "traffic": original,
                  "conditions": [{"type": "Ready", "status": "True"}]}}
        with patch.object(tags.registry, "get_token", return_value="token"), \
                patch.object(tags, "cloud_run", side_effect=[source, release.ReleaseError("conflict")]) as api, \
                self.assertRaises(release.ReleaseError):
            tags.apply_definition(manifest, original, render.STAGING)
        self.assertEqual([c.args[0] for c in api.call_args_list], ["GET", "PUT"])
        self.assertEqual(api.call_args.args[3]["metadata"]["resourceVersion"], "read-version")
        self.assertTrue(api.call_args.kwargs["v1"])

    def test_conditional_replace_confirms_created_generation_and_accommodates_split_tag_rows(self):
        original = self.config["retainedTraffic"]["gateway"]
        manifest = render.render(self.config)["gateway"]
        labels = {"name": "nextstop-gateway", "namespace": render.STAGING.number,
                  "generation": 6, "resourceVersion": "read-version"}
        ready = [{"type": "Ready", "status": "True"}]
        source = {"metadata": labels, "spec": {"traffic": [
            {"revisionName": self.old, "percent": 100}, {"revisionName": self.old, "tag": self.old_tag}]},
            "status": {"traffic": original, "observedGeneration": 6, "conditions": ready}}
        after = {"metadata": dict(labels, generation=7), "status": {
            "observedGeneration": 7, "conditions": ready, "traffic": manifest["spec"]["traffic"]}}
        with patch.object(tags.registry, "get_token", return_value="token"), \
                patch.object(tags, "cloud_run", side_effect=[source, after, after]) as api:
            tags.apply_definition(manifest, original, render.STAGING)
        self.assertEqual([c.args[0] for c in api.call_args_list], ["GET", "PUT", "GET"])
        self.assertEqual(api.call_args_list[1].args[3]["metadata"]["resourceVersion"], "read-version")

    def test_commissioning_never_replaces_a_concurrently_created_gateway(self):
        self.config["retainedTraffic"] = {}
        with patch.object(tags.registry, "get_token", return_value="token"), \
                patch.object(tags, "cloud_run", side_effect=release.ReleaseError("already exists")) as api, \
                self.assertRaises(release.ReleaseError):
            tags.apply_definition(render.render(self.config)["gateway"], [], render.STAGING)
        self.assertEqual([c.args[0] for c in api.call_args_list], ["POST"])

    def test_restored_production_uses_only_its_own_revision_broker_domain_service_and_operation(self):
        prod = render.PRODUCTION
        config = production.configuration(self.config["commit"], self.config["backendImage"], self.config["acceptanceEvidence"])
        old_id = "aaaaaaaaaaaa"
        rid = render.release_id(config)
        config["retainedTraffic"] = {s: [{"revisionName": f"nextstop-{s}-{old_id}", "percent": 100}]
                                     for s in render.SERVICES}
        v1 = [{"metadata": {"name": "nextstop-" + s}, "status": {"traffic": rows}}
              for s, rows in config["retainedTraffic"].items()]
        resource = tags.gateway_service(config, prod)
        stale = self.row("nextstop-gateway-" + rid, tag="r-" + rid)
        desired = [self.row(self.old, 100, "r-" + old_id), stale]
        before = dict(self.service, name=resource, traffic=desired, trafficStatuses=desired)
        after = dict(before, traffic=desired[:1], trafficStatuses=desired[:1])
        op = {"name": resource.split("/services/")[0] + "/operations/test", "done": True}
        old_image = render.REGISTRY + "@sha256:" + "d" * 64
        client = SyntheticHTTP(config, public=True, restored=True)
        client.digest = old_image.split("@")[1]
        def token(audience):
            self.assertEqual(audience, render.origin("broker", target=prod))
            return "private-identity" * 3
        public_check = verify.verify_public
        with patch.object(release, "current_services", return_value=v1) as services, \
                patch.object(release, "run", return_value=old_image) as cli, \
                patch.object(verify, "verify_public", side_effect=lambda c, t, **kw: public_check(c, t, request=client, **kw)), \
                patch.object(tags.registry, "get_token", return_value="token"), \
                patch.object(tags.time, "sleep"), \
                patch.object(tags, "cloud_run", side_effect=[before, dict(op, done=False), op, after]) as api:
            deploy.retire_after_restoration(config, token, target=prod)
        services.assert_called_once_with(prod)
        self.assertIn("--project=" + prod.project, cli.call_args.args[0])
        self.assertEqual(client.calls[0][0], render.origin("broker", target=prod) + "/token")
        self.assertTrue(all(c[0].startswith("https://" + prod.domain + "/") for c in client.calls[1:]))
        self.assertEqual(api.call_args_list[2].args[1], op["name"] + "?fields=name,done,error(code)")
        self.assertTrue(all(c.args[1].startswith(resource + "?") for c in (api.call_args_list[0], api.call_args_list[1], api.call_args_list[3])))
        self.assertEqual(api.call_args_list[1].args[3]["traffic"], desired[:1])
        with patch.object(tags.registry, "get_token", return_value="token"), \
                patch.object(tags, "cloud_run", return_value=self.service) as wrong, self.assertRaises(release.ReleaseError):
            tags.retire(config, {self.old: 100}, target=prod)
        self.assertEqual(wrong.call_count, 1)
