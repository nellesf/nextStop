#!/usr/bin/env python3
"""Configure the approved CI identities and gates, leaving deployments disabled.

Run by an authorized project/repository administrator. No VM deployment, service
account key, runtime VM identity, DNS or database operation is performed.
"""
from __future__ import annotations

import argparse
import http.client
import json
import subprocess
import sys

from common import configuration

REPOSITORY = "nellesf/nextStop"
REPOSITORY_ID = "1333251411"
OWNER_ID = "26274002"
SUBJECT_PREFIX = f"repo:nellesf@{OWNER_ID}/nextStop@{REPOSITORY_ID}"
PROJECT_NUMBERS = {"staging": "353471052580", "production": "1022346259037"}
POOL = "nextstop-github"
PROVIDER = "release"
METADATA_ROLE = "nextstopCiProjectMetadata"
BACKUP_METADATA_ROLE = "nextstopCiBackupMetadata"
SSH_CONDITION = {"title": "nextstop-ci-ssh", "expression": "destination.port == 22"}
MAPPING = {"google.subject": "assertion.sub", "attribute.repository_id": "assertion.repository_id",
           "attribute.repository_owner_id": "assertion.repository_owner_id", "attribute.ref": "assertion.ref",
           "attribute.workflow_ref": "assertion.workflow_ref"}


class SetupError(Exception):
    pass


def run(arguments, *, payload=None, raw=False, timeout=180):
    try:
        result = subprocess.run(arguments, input=None if payload is None else json.dumps(payload),
                                capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SetupError("CI configuration command unavailable or timed out.") from error
    if result.returncode:
        # Tool errors can contain authentication details. Report operation names,
        # not credentials, subprocess output or arbitrary exception text.
        raise SetupError("CI configuration command failed: " + " ".join(arguments[:4]))
    return result.stdout if raw else json.loads(result.stdout or "null")


def gcloud(*arguments):
    return run(["gcloud", *arguments, "--quiet", "--format=json"])


def github(path, *, method="GET", payload=None):
    arguments = ["gh", "api", "--method", method, f"repos/{REPOSITORY}/{path}"]
    if payload is not None:
        arguments += ["--input", "-"]
    return run(arguments, payload=payload)


def condition(environment):
    return (f"assertion.repository_id == '{REPOSITORY_ID}' && assertion.repository_owner_id == '{OWNER_ID}'"
            f" && assertion.ref == 'refs/heads/main'"
            f" && assertion.workflow_ref == '{REPOSITORY}/.github/workflows/backend-{environment}.yml@refs/heads/main'"
            f" && assertion.sub == '{SUBJECT_PREFIX}:environment:{environment}'")


def verify_subject_template(template):
    # New GitHub repositories use immutable owner/repository IDs in their sub.
    # Reject drift instead of silently broadening the cloud trust condition.
    if (template.get("use_default") is not True or template.get("use_immutable_subject") is not True
            or template.get("sub_claim_prefix") != SUBJECT_PREFIX):
        raise SetupError("GitHub OIDC subject template does not match the approved immutable identity.")


def identities(environment, config):
    project = config["project"]
    base = f"projects/{PROJECT_NUMBERS[environment]}/locations/global/workloadIdentityPools/{POOL}"
    return {"provider": base + "/providers/" + PROVIDER,
            "principal": "principalSet://iam.googleapis.com/" + base + "/attribute.repository_id/" + REPOSITORY_ID,
            "deploy": f"nextstop-{environment}-deploy@{project}.iam.gserviceaccount.com",
            **({"build": f"nextstop-staging-build@{project}.iam.gserviceaccount.com"} if environment == "staging" else {})}


def iap_policy(number, zone, instance_id, *, policy=None):
    # The stable gcloud release has no per-VM IAP IAM command. Use its documented
    # REST resource with optimistic concurrency and an in-memory credential.
    token = run(["gcloud", "auth", "print-access-token", "--quiet"], raw=True).strip()
    if not token or any(character.isspace() for character in token):
        raise SetupError("Invalid administration credential.")
    action = "getIamPolicy" if policy is None else "setIamPolicy"
    body = {"options": {"requestedPolicyVersion": 3}} if policy is None else {"policy": policy}
    connection = http.client.HTTPSConnection("iap.googleapis.com", timeout=30)
    try:
        connection.request("POST", f"/v1/projects/{number}/iap_tunnel/zones/{zone}/instances/{instance_id}:{action}",
                           body=json.dumps(body), headers={"Authorization": "Bearer " + token,
                                                          "Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            raise SetupError(f"IAP VM policy operation failed (HTTP {response.status}).")
        data = response.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise SetupError("IAP policy response exceeds limit.")
        return json.loads(data)
    finally:
        connection.close()


def member_bindings(policy, member):
    return [binding for binding in policy.get("bindings", []) if member in binding.get("members", [])]


def ensure_iap_ssh(number, zone, instance_id, member):
    policy = iap_policy(number, zone, instance_id)
    own = member_bindings(policy, member)
    expected = {"role": "roles/iap.tunnelResourceAccessor", "condition": SSH_CONDITION}
    if any(binding.get("role") != expected["role"] or binding.get("condition") != SSH_CONDITION for binding in own):
        raise SetupError("Unexpected broader IAP binding on dedicated CI identity.")
    if not own:
        policy.setdefault("bindings", []).append({**expected, "members": [member]})
        policy["version"] = 3
        iap_policy(number, zone, instance_id, policy=policy)


def configure_environment(environment, config):
    project, target = config["project"], config["target"]
    ids = identities(environment, config)
    project_info = gcloud("projects", "describe", project)
    if str(project_info["projectNumber"]) != PROJECT_NUMBERS[environment]:
        raise SetupError("Cloud project number does not match the approved environment.")
    gcloud("services", "enable", "iam.googleapis.com", "iamcredentials.googleapis.com", "sts.googleapis.com",
           "iap.googleapis.com", "oslogin.googleapis.com", f"--project={project}")
    instance = gcloud("compute", "instances", "describe", target["instance"], f"--zone={target['zone']}", f"--project={project}")
    metadata = {item["key"]: item["value"] for item in instance.get("metadata", {}).get("items", [])}
    if metadata.get("enable-oslogin", "").upper() != "TRUE" or instance.get("serviceAccounts"):
        raise SetupError("CI setup requires the approved OS Login VM without a runtime service account.")
    pools = gcloud("iam", "workload-identity-pools", "list", "--location=global", f"--project={project}")
    if not any(pool["name"].endswith("/" + POOL) for pool in pools):
        gcloud("iam", "workload-identity-pools", "create", POOL, "--location=global", f"--project={project}",
               f"--display-name=nextStop {environment} CI")
    providers = gcloud("iam", "workload-identity-pools", "providers", "list", "--location=global",
                       f"--workload-identity-pool={POOL}", f"--project={project}")
    operation = "update-oidc" if any(item["name"].endswith("/" + PROVIDER) for item in providers) else "create-oidc"
    gcloud("iam", "workload-identity-pools", "providers", operation, PROVIDER, "--location=global",
           f"--workload-identity-pool={POOL}", f"--project={project}", "--issuer-uri=https://token.actions.githubusercontent.com",
           "--attribute-mapping=" + ",".join(f"{key}={value}" for key, value in MAPPING.items()),
           "--attribute-condition=" + condition(environment))
    accounts = gcloud("iam", "service-accounts", "list", f"--project={project}")
    existing = {account["email"] for account in accounts}
    for kind in ("deploy", "build"):
        if kind not in ids:
            continue
        email = ids[kind]
        if email not in existing:
            gcloud("iam", "service-accounts", "create", email.split("@")[0], f"--project={project}",
                   f"--display-name=nextStop {environment} {kind}")
        gcloud("iam", "service-accounts", "add-iam-policy-binding", email, f"--project={project}",
               "--role=roles/iam.workloadIdentityUser", "--member=" + ids["principal"], "--condition=None")
    roles = gcloud("iam", "roles", "list", f"--project={project}")
    operation = "update" if any(role["name"].endswith("/" + METADATA_ROLE) for role in roles) else "create"
    gcloud("iam", "roles", operation, METADATA_ROLE, f"--project={project}", "--title=nextStop CI project metadata",
           "--permissions=compute.projects.get", "--stage=GA")
    member = "serviceAccount:" + ids["deploy"]
    gcloud("projects", "add-iam-policy-binding", project, "--member=" + member,
           f"--role=projects/{project}/roles/{METADATA_ROLE}", "--condition=None")
    gcloud("compute", "instances", "add-iam-policy-binding", target["instance"], f"--zone={target['zone']}",
           f"--project={project}", "--member=" + member, "--role=roles/compute.osAdminLogin", "--condition=None")
    ensure_iap_ssh(PROJECT_NUMBERS[environment], target["zone"], instance["id"], member)
    for kind, role in [("deploy", "reader"), ("build", "writer")]:
        if kind in ids:
            gcloud("artifacts", "repositories", "add-iam-policy-binding", "nextstop", "--location=europe-west3",
                   "--project=" + config["registryProject"], "--member=serviceAccount:" + ids[kind],
                   "--role=roles/artifactregistry." + role, "--condition=None")
    if environment == "production":
        bucket = "gs://" + config["backupBucket"]
        settings = gcloud("storage", "buckets", "describe", bucket)
        if settings.get("uniform_bucket_level_access") is not True or settings.get("public_access_prevention") != "enforced":
            raise SetupError("Backup bucket must enforce uniform IAM and public-access prevention.")
        operation = "update" if any(role["name"].endswith("/" + BACKUP_METADATA_ROLE) for role in roles) else "create"
        gcloud("iam", "roles", operation, BACKUP_METADATA_ROLE, f"--project={project}",
               "--title=nextStop CI backup bucket metadata", "--permissions=storage.buckets.get", "--stage=GA")
        gcloud("storage", "buckets", "add-iam-policy-binding", bucket, "--member=" + member,
               f"--role=projects/{project}/roles/{BACKUP_METADATA_ROLE}")
        for role in ("objectViewer", "objectCreator"):
            gcloud("storage", "buckets", "add-iam-policy-binding", bucket, "--member=" + member,
                   "--role=roles/storage." + role)
    github("environments/" + environment, method="PUT", payload={
        "wait_timer": 0, "prevent_self_review": False,
        "reviewers": [{"type": "User", "id": int(OWNER_ID)}] if environment == "production" else [],
        "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}})
    policies = github(f"environments/{environment}/deployment-branch-policies")
    for policy in policies["branch_policies"]:
        if policy["name"] != "main" or policy["type"] != "branch":
            github(f"environments/{environment}/deployment-branch-policies/{policy['id']}", method="DELETE")
    if not any(policy["name"] == "main" and policy["type"] == "branch" for policy in policies["branch_policies"]):
        github(f"environments/{environment}/deployment-branch-policies", method="POST", payload={"name": "main", "type": "branch"})
    for name, value in environment_variables(ids).items():
        run(["gh", "variable", "set", name, "--repo", REPOSITORY, "--env", environment, "--body", value], raw=True)
    print(json.dumps({"event": "ci-environment-configured", "environment": environment}), flush=True)


def environment_variables(ids):
    return {"NEXTSTOP_WORKLOAD_IDENTITY_PROVIDER": ids["provider"], "NEXTSTOP_DEPLOY_SERVICE_ACCOUNT": ids["deploy"],
            **({"NEXTSTOP_BUILD_SERVICE_ACCOUNT": ids["build"]} if "build" in ids else {})}


def verify_backup_access(config):
    role = gcloud("iam", "roles", "describe", BACKUP_METADATA_ROLE, "--project=" + config["project"])
    if role.get("includedPermissions") != ["storage.buckets.get"]:
        raise SetupError("Unexpected backup metadata role permissions.")
    bucket = gcloud("storage", "buckets", "describe", "gs://" + config["backupBucket"])
    if bucket.get("uniform_bucket_level_access") is not True or bucket.get("public_access_prevention") != "enforced":
        raise SetupError("Backup bucket privacy verification failed.")
    policy = gcloud("storage", "buckets", "get-iam-policy", "gs://" + config["backupBucket"])
    bindings = member_bindings(policy, "serviceAccount:" + identities("production", config)["deploy"])
    expected = {"roles/storage.objectCreator", "roles/storage.objectViewer",
                f"projects/{config['project']}/roles/{BACKUP_METADATA_ROLE}"}
    if {item["role"] for item in bindings} != expected or any(item.get("condition") for item in bindings):
        raise SetupError("Backup bucket CI role verification failed.")


def verify_environment(environment, config):
    ids, project, target = identities(environment, config), config["project"], config["target"]
    provider = gcloud("iam", "workload-identity-pools", "providers", "describe", PROVIDER, "--location=global",
                      f"--workload-identity-pool={POOL}", f"--project={project}")
    if (provider.get("attributeCondition") != condition(environment) or provider.get("attributeMapping") != MAPPING
            or provider.get("state") != "ACTIVE" or provider.get("disabled", False)
            or provider.get("oidc", {}).get("issuerUri") != "https://token.actions.githubusercontent.com"
            or provider.get("oidc", {}).get("allowedAudiences")):
        raise SetupError("Federation provider verification failed.")
    project_policy = gcloud("projects", "get-iam-policy", project)
    for kind in ("deploy", "build"):
        if kind not in ids:
            continue
        member = "serviceAccount:" + ids[kind]
        expected_roles = {f"projects/{project}/roles/{METADATA_ROLE}"} if kind == "deploy" else set()
        bindings = member_bindings(project_policy, member)
        if {item["role"] for item in bindings} != expected_roles or any(item.get("condition") for item in bindings):
            raise SetupError("Unexpected project-wide access for a dedicated CI identity.")
        policy = gcloud("iam", "service-accounts", "get-iam-policy", ids[kind], f"--project={project}")
        if policy.get("bindings") != [{"role": "roles/iam.workloadIdentityUser", "members": [ids["principal"]]}]:
            raise SetupError("Unexpected service-account impersonation policy.")
        if gcloud("iam", "service-accounts", "keys", "list", "--iam-account=" + ids[kind], "--managed-by=user", f"--project={project}"):
            raise SetupError("Long-lived key found on CI identity.")
    role = gcloud("iam", "roles", "describe", METADATA_ROLE, f"--project={project}")
    if role.get("includedPermissions") != ["compute.projects.get"]:
        raise SetupError("Unexpected metadata role permissions.")
    member = "serviceAccount:" + ids["deploy"]
    instance = gcloud("compute", "instances", "describe", target["instance"], f"--zone={target['zone']}", f"--project={project}")
    if instance.get("serviceAccounts"):
        raise SetupError("Runtime VM identity changed unexpectedly.")
    policy = gcloud("compute", "instances", "get-iam-policy", target["instance"], f"--zone={target['zone']}", f"--project={project}")
    if {item["role"] for item in member_bindings(policy, member)} != {"roles/compute.osAdminLogin"}:
        raise SetupError("VM-scoped OS Login verification failed.")
    policy = iap_policy(PROJECT_NUMBERS[environment], target["zone"], instance["id"])
    own = member_bindings(policy, member)
    if len(own) != 1 or own[0].get("condition") != SSH_CONDITION or own[0]["role"] != "roles/iap.tunnelResourceAccessor":
        raise SetupError("VM-scoped IAP SSH verification failed.")
    actual = github("environments/" + environment)
    if actual.get("deployment_branch_policy") != {"protected_branches": False, "custom_branch_policies": True}:
        raise SetupError("GitHub branch restriction verification failed.")
    policies = github(f"environments/{environment}/deployment-branch-policies")["branch_policies"]
    if len(policies) != 1 or policies[0]["name"] != "main" or policies[0]["type"] != "branch":
        raise SetupError("GitHub environment must allow only the main branch.")
    reviewers = [reviewer["reviewer"]["id"] for rule in actual.get("protection_rules", [])
                 if rule["type"] == "required_reviewers" for reviewer in rule.get("reviewers", [])]
    if reviewers != ([int(OWNER_ID)] if environment == "production" else []):
        raise SetupError("GitHub environment reviewer verification failed.")
    variables = {item["name"]: item["value"] for item in github(f"environments/{environment}/variables")["variables"]}
    if any(variables.get(name) != value for name, value in environment_variables(ids).items()):
        raise SetupError("GitHub identity variable verification failed.")
    return {"environment": environment, "project": project, **environment_variables(ids), "mainOnly": True,
            "requiredOwnerReview": environment == "production", "vmScopedSSH": True, "userManagedKeys": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Apply the approved IAM/environment setup; otherwise verify only.")
    args = parser.parse_args()
    configs = {environment: configuration(environment) for environment in PROJECT_NUMBERS}
    repo = run(["gh", "api", f"repos/{REPOSITORY}"])
    if str(repo["id"]) != REPOSITORY_ID or str(repo["owner"]["id"]) != OWNER_ID:
        raise SetupError("GitHub repository identity mismatch.")
    verify_subject_template(github("actions/oidc/customization/sub"))
    registry_project = configs["staging"]["registryProject"]
    if args.apply:
        # Disable before granting any identity, including on an intentional rerun.
        run(["gh", "variable", "set", "NEXTSTOP_RELEASES_ENABLED", "--repo", REPOSITORY, "--body", "false"], raw=True)
        gcloud("services", "enable", "artifactregistry.googleapis.com", f"--project={registry_project}")
        repositories = gcloud("artifacts", "repositories", "list", "--location=europe-west3", f"--project={registry_project}")
        existing = next((item for item in repositories if item["name"].endswith("/repositories/nextstop")), None)
        if existing is None:
            gcloud("artifacts", "repositories", "create", "nextstop", "--location=europe-west3", f"--project={registry_project}",
                   "--repository-format=docker", "--immutable-tags", "--description=nextStop immutable backend releases")
        elif existing.get("format") != "DOCKER":
            raise SetupError("Existing nextstop repository has a different format.")
        elif existing.get("dockerConfig", {}).get("immutableTags") is not True:
            gcloud("artifacts", "repositories", "update", "nextstop", "--location=europe-west3", f"--project={registry_project}", "--immutable-tags")
        for environment, config in configs.items():
            configure_environment(environment, config)
    repository = gcloud("artifacts", "repositories", "describe", "nextstop", "--location=europe-west3", f"--project={registry_project}")
    if repository.get("format") != "DOCKER" or repository.get("dockerConfig", {}).get("immutableTags") is not True:
        raise SetupError("Registry immutability verification failed.")
    reports = [verify_environment(environment, config) for environment, config in configs.items()]
    registry_policy = gcloud("artifacts", "repositories", "get-iam-policy", "nextstop", "--location=europe-west3", f"--project={registry_project}")
    for environment, config in configs.items():
        for kind, email in identities(environment, config).items():
            if kind in ("deploy", "build"):
                roles = {item["role"] for item in member_bindings(registry_policy, "serviceAccount:" + email)}
                if roles != {"roles/artifactregistry." + ("writer" if kind == "build" else "reader")}:
                    raise SetupError("Registry-scoped CI access verification failed.")
    verify_backup_access(configs["production"])
    if github("actions/variables/NEXTSTOP_RELEASES_ENABLED")["value"] != "false":
        raise SetupError("Release workflows must remain disabled after setup.")
    print(json.dumps({"event": "ci-configuration-verified", "releasesEnabled": False, "environments": reports}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (SetupError, OSError, ValueError, KeyError, http.client.HTTPException) as error:
        print(str(error) if isinstance(error, SetupError) else "CI setup failed; inspect the last operation.", file=sys.stderr)
        raise SystemExit(1)
