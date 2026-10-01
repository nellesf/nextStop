"""CI identities are bound to exact workflows and VM-scoped access."""
import copy
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("configure_ci", Path(__file__).with_name("configure-ci.py"))
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ConfigureCITests(unittest.TestCase):
    def test_federation_restricts_numeric_identity_branch_workflow_and_environment(self):
        for environment in ("staging", "production"):
            expression = setup.condition(environment)
            for required in ["assertion.repository_id == '1333251411'", "assertion.repository_owner_id == '26274002'",
                             "assertion.ref == 'refs/heads/main'",
                             f"assertion.workflow_ref == 'nellesf/nextStop/.github/workflows/backend-{environment}.yml@refs/heads/main'",
                             f"assertion.sub == 'repo:nellesf@26274002/nextStop@1333251411:environment:{environment}'"]:
                self.assertIn(required, expression)

    def test_github_subject_template_must_match_the_exact_immutable_identity(self):
        template = {"use_default": True, "use_immutable_subject": True,
                    "sub_claim_prefix": "repo:nellesf@26274002/nextStop@1333251411"}
        setup.verify_subject_template(template)
        for changed in [{"use_default": False}, {"use_immutable_subject": False},
                        {"sub_claim_prefix": "repo:nellesf/nextStop"},
                        {"sub_claim_prefix": "repo:nellesf@26274002/nextStop@999"}]:
            with self.subTest(changed=changed), self.assertRaisesRegex(setup.SetupError, "subject template"):
                setup.verify_subject_template({**template, **changed})

    def test_iap_binding_preserves_existing_policy_and_restricts_ssh(self):
        original = {"etag": "unchanged-version", "bindings": [{"role": "roles/iap.admin", "members": ["user:owner@example.test"]}]}
        member = "serviceAccount:ci@example.test"
        with patch.object(setup, "iap_policy", return_value=copy.deepcopy(original)) as policy:
            setup.ensure_iap_ssh("123", "europe-west3-a", "456", member)
            updated = policy.call_args.kwargs["policy"]
            self.assertEqual(updated["etag"], original["etag"])
            self.assertEqual(updated["bindings"][0], original["bindings"][0])
            self.assertEqual(updated["bindings"][1], {"role": "roles/iap.tunnelResourceAccessor",
                "members": [member], "condition": {"title": "nextstop-ci-ssh", "expression": "destination.port == 22"}})
            self.assertEqual(updated["version"], 3)
        with patch.object(setup, "iap_policy", return_value=updated) as policy:
            setup.ensure_iap_ssh("123", "europe-west3-a", "456", member)
            self.assertEqual(policy.call_count, 1)

    def test_existing_unconditional_iap_access_is_not_silently_accepted(self):
        member = "serviceAccount:ci@example.test"
        with patch.object(setup, "iap_policy", return_value={"bindings": [
            {"role": "roles/iap.tunnelResourceAccessor", "members": [member]}]}), self.assertRaises(setup.SetupError):
            setup.ensure_iap_ssh("123", "europe-west3-a", "456", member)

    def test_staging_setup_grants_project_metadata_only_and_vm_scoped_admin(self):
        config = setup.configuration("staging")
        calls = []

        def cloud(*arguments):
            calls.append(arguments)
            if arguments[:2] == ("projects", "describe"):
                return {"projectNumber": setup.PROJECT_NUMBERS["staging"]}
            if arguments[:3] == ("compute", "instances", "describe"):
                return {"id": "123", "metadata": {"items": [{"key": "enable-oslogin", "value": "TRUE"}]}}
            return []

        with patch.object(setup, "gcloud", side_effect=cloud), patch.object(setup, "ensure_iap_ssh") as iap, \
                patch.object(setup, "github", return_value={"branch_policies": []}), \
                patch.object(setup, "run"), patch("builtins.print"):
            setup.configure_environment("staging", config)
        project_grants = [call for call in calls if call[:2] == ("projects", "add-iam-policy-binding")]
        self.assertEqual(len(project_grants), 1)
        self.assertIn("--role=projects/nextstop-tech-testing/roles/nextstopCiProjectMetadata", project_grants[0])
        vm_grant = next(call for call in calls if call[:3] == ("compute", "instances", "add-iam-policy-binding"))
        self.assertIn("nextstop-backend", vm_grant)
        self.assertIn("--project=nextstop-tech-testing", vm_grant)
        self.assertIn("--role=roles/compute.osAdminLogin", vm_grant)
        iap.assert_called_once_with("353471052580", "europe-west3-a", "123",
            "serviceAccount:nextstop-staging-deploy@nextstop-tech-testing.iam.gserviceaccount.com")
        self.assertFalse(any("roles/iam.serviceAccountUser" in str(call) for call in calls))

    def test_production_backup_metadata_permission_is_bound_only_to_its_bucket(self):
        config = setup.configuration("production")
        calls = []

        def cloud(*arguments):
            calls.append(arguments)
            if arguments[:2] == ("projects", "describe"):
                return {"projectNumber": setup.PROJECT_NUMBERS["production"]}
            if arguments[:3] == ("compute", "instances", "describe"):
                return {"id": "456", "metadata": {"items": [{"key": "enable-oslogin", "value": "TRUE"}]}}
            if arguments[:3] == ("storage", "buckets", "describe"):
                return {"uniform_bucket_level_access": True, "public_access_prevention": "enforced"}
            return []

        with patch.object(setup, "gcloud", side_effect=cloud), patch.object(setup, "ensure_iap_ssh"), \
                patch.object(setup, "github", return_value={"branch_policies": []}), \
                patch.object(setup, "run"), patch("builtins.print"):
            setup.configure_environment("production", config)
        role = next(call for call in calls if call[:4] == ("iam", "roles", "create", setup.BACKUP_METADATA_ROLE))
        self.assertIn("--permissions=storage.buckets.get", role)
        self.assertIn("--project=nextstop-tech-staging", role)
        bucket_grants = [call for call in calls if call[:3] == ("storage", "buckets", "add-iam-policy-binding")]
        self.assertEqual(len(bucket_grants), 3)
        for call in bucket_grants:
            self.assertEqual(call[3], "gs://nextstop-tech-staging-release-backups")
            self.assertIn("--member=serviceAccount:nextstop-production-deploy@nextstop-tech-staging.iam.gserviceaccount.com", call)
        self.assertEqual({argument for call in bucket_grants for argument in call if argument.startswith("--role=")}, {
            "--role=roles/storage.objectCreator", "--role=roles/storage.objectViewer",
            "--role=projects/nextstop-tech-staging/roles/nextstopCiBackupMetadata"})
        project_grants = [call for call in calls if call[:2] == ("projects", "add-iam-policy-binding")]
        self.assertEqual(len(project_grants), 1)
        self.assertIn("--role=projects/nextstop-tech-staging/roles/nextstopCiProjectMetadata", project_grants[0])

    def test_backup_metadata_verification_rejects_additional_permission(self):
        config = setup.configuration("production")
        member = "serviceAccount:" + setup.identities("production", config)["deploy"]
        roles = ["roles/storage.objectCreator", "roles/storage.objectViewer",
                 "projects/nextstop-tech-staging/roles/nextstopCiBackupMetadata"]
        with patch.object(setup, "gcloud", side_effect=[
                {"includedPermissions": ["storage.buckets.get"]},
                {"uniform_bucket_level_access": True, "public_access_prevention": "enforced"},
                {"bindings": [{"role": role, "members": [member]} for role in roles]}]):
            setup.verify_backup_access(config)
        with patch.object(setup, "gcloud", return_value={
                "includedPermissions": ["storage.buckets.get", "storage.buckets.update"]}), \
                self.assertRaisesRegex(setup.SetupError, "Unexpected backup metadata"):
            setup.verify_backup_access(config)


if __name__ == "__main__":
    unittest.main()
