#!/usr/bin/env python3
"""Bootstrap the new isolated staging VM from a public-data-only PostgreSQL dump.

Never restores over an existing nextstop schema. Production is only read, apart
from a unique temporary dump on its data disk. No app/worker process is started.
"""
from __future__ import annotations

import json
import inspect
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

from backup import archive_sha256
from common import ROOT, configuration

CONTAINER = "gcp-vm-database-1"
PRIVATE_TABLES = ("app_attest_keys", "app_attest_challenges", "user_error_reports")
AUTH_FIELDS = ("APP_ATTEST_APP_ID", "APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS")
PUBLIC_TABLES = frozenset({
    "availability_observations", "availability_snapshots", "charging_campus_park_memberships",
    "charging_campus_power_projection", "charging_campus_projection", "charging_park_food_poi_matches",
    "charging_park_location_memberships", "charging_park_power_projection", "charging_park_projection",
    "food_poi_projection", "food_poi_projection_versions", "food_poi_quarantine",
    "normalized_charging_locations", "normalized_charging_points", "projection_conflicts",
    "projection_versions", "provider_quarantine", "provider_records", "schema_migrations",
    "static_projection_input_checks",
})


def validate_source_inventory(tables):
    if not isinstance(tables, list) or set(tables) != PUBLIC_TABLES | set(PRIVATE_TABLES):
        raise RuntimeError("Source tables differ from the reviewed public/private seed inventory.")


def validate_archive_inventory(listing, allowed):
    marker = " TABLE DATA nextstop "
    names = {line.split(marker, 1)[1].rsplit(" ", 1)[0]
             for line in listing.splitlines() if marker in line and not line.startswith(";")}
    if names != set(allowed):
        raise RuntimeError("Archive data tables differ from the reviewed public seed inventory.")


def cleanup_script(directory, *, staging=False):
    match = re.fullmatch(r"/srv/nextstop/\.public-seed-([0-9a-f]{32})", directory)
    if match is None:
        raise RuntimeError("Refusing cleanup outside an exact generated seed directory.")
    files = [directory + "/public.dump"]
    files += ([f"/tmp/nextstop-public-seed-{match[1]}.tar.gz"] if staging else [directory + "/archive.list"])
    # Removing a child directory requires root on the /srv/nextstop parent.
    # rmdir deliberately refuses unexpected content; never recursively delete.
    return shlex.join(["sudo", "rm", "-f", "--", *files]) + " && " + shlex.join(["sudo", "rmdir", "--", directory])


def command(arguments, *, timeout=3600):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Public seed operation exceeded its time budget.") from None
    if result.returncode:
        raise RuntimeError("Public seed command failed; private command output was suppressed.")
    return result.stdout


def ssh(config, script, *, timeout=3600):
    return command(["gcloud", "compute", "ssh", config["target"]["instance"],
                    f"--project={config['project']}", f"--zone={config['target']['zone']}",
                    "--tunnel-through-iap", "--quiet", "--command=" + script], timeout=timeout)


def remote_python(config, source, *, sudo=False, timeout=3600):
    return ssh(config, ("sudo " if sudo else "") + "python3 -c " + shlex.quote(source), timeout=timeout)


def transfer(config, source, destination):
    command(["gcloud", "compute", "scp", str(source), str(destination),
             f"--project={config['project']}", f"--zone={config['target']['zone']}",
             "--tunnel-through-iap", "--quiet"], timeout=3600)


def event(name, **metadata):
    print(json.dumps({"event": name, **metadata}), flush=True)


def metadata_script():
    return '''import json,pathlib,shutil,subprocess
allowed={"APP_ATTEST_APP_ID","APP_ATTEST_SUPPORTED_BUNDLE_VERSIONS"}
values={line.partition("=")[0]:line.partition("=")[2].strip().strip("\\\"'") for line in pathlib.Path("/etc/nextstop/backend.env").read_text().splitlines() if line.partition("=")[0] in allowed}
query="SELECT pg_database_size(current_database())"
size=int(subprocess.run(["docker","exec","gcp-vm-database-1","psql","-XAt","-U","nextstop_app","-d","nextstop","-c",query],capture_output=True,text=True,check=True).stdout)
inventory="SELECT COALESCE(json_agg(tablename ORDER BY tablename),'[]'::json) FROM pg_tables WHERE schemaname='nextstop'"
tables=json.loads(subprocess.run(["docker","exec","gcp-vm-database-1","psql","-XAt","-U","nextstop_app","-d","nextstop","-c",inventory],capture_output=True,text=True,check=True).stdout)
print(json.dumps({"publicAuthConfig":values,"databaseBytes":size,"freeBytes":shutil.disk_usage("/srv/nextstop").free,"tables":tables}))
'''


def prepare_script(auth, release_directory, archive):
    # Only public App Attest metadata crosses environments. All keys/passwords
    # are independently generated on staging and never returned to this process.
    return f'''import json,os,pathlib,secrets,subprocess,tarfile,urllib.request
project=urllib.request.urlopen(urllib.request.Request("http://metadata.google.internal/computeMetadata/v1/project/project-id",headers={{"Metadata-Flavor":"Google"}}),timeout=5).read().decode()
assert project == "nextstop-tech-testing", "Refusing non-staging host"
assert pathlib.Path("/var/lib/nextstop-bootstrap-complete").is_file()
root=pathlib.Path({release_directory!r});root.mkdir(mode=0o700,parents=True,exist_ok=True)
with tarfile.open({archive!r}) as bundle:
    for member in bundle.getmembers():
        parts=pathlib.Path(member.name).parts
        assert not member.issym() and not member.islnk() and not member.name.startswith("/") and ".." not in parts
        assert member.isfile() and (member.name.startswith("deploy/gcp-vm/") or member.name.startswith("deploy/releases/"))
    bundle.extractall(root)
secrets_path=pathlib.Path("/etc/nextstop/backend.env")
if not secrets_path.exists():
    values={{key:secrets.token_hex(32) for key in ["POSTGRES_PASSWORD","API_DATABASE_PASSWORD","AUTH_DATABASE_PASSWORD","SUPPORT_DATABASE_PASSWORD","WORKER_DATABASE_PASSWORD","SNAPSHOT_SIGNING_KEY","SEARCH_ACCESS_TOKEN_SIGNING_KEY","SEARCH_API_BEARER_TOKEN"]}}
    values.update({auth!r})
    values.update(APP_ATTEST_ALLOW_DEVELOPMENT="false",ALLOW_LEGACY_STAGING_BEARER="false",OSM_INGESTION_ENABLED="true")
    descriptor=os.open(secrets_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(descriptor,"w") as output: output.write("".join(key+"="+value+"\\n" for key,value in values.items()))
os.chmod(secrets_path,0o600)
config={{"NEXTSTOP_ENVIRONMENT":"staging","DOMAIN":"api-staging.nextstop.tech","PROJECT_ID":"nextstop-tech-testing","DATABASE_INSTANCE":"nextstop-backend","DATABASE_MODE":"local","DATABASE_HOST":"database","DATABASE_PORT":"5432","DATABASE_OWNER":"nextstop_app","COMPOSE_PROJECT_NAME":"gcp-vm"}}
config_path=pathlib.Path("/etc/nextstop/release.env")
if config_path.exists():
    existing=dict(line.partition("=")[::2] for line in config_path.read_text().splitlines() if "=" in line)
    assert existing.get("NEXTSTOP_ENVIRONMENT")=="staging"
config_path.write_text("".join(key+"="+value+"\\n" for key,value in config.items()));os.chmod(config_path,0o644)
# This command starts only PostgreSQL. No application or worker image is needed.
subprocess.run(["docker","compose","--project-name","gcp-vm","--env-file",str(secrets_path),"-f",str(root/"deploy/gcp-vm/compose.yaml"),"up","-d","--no-recreate","--wait","database"],capture_output=True,text=True,check=True,timeout=300)
result=subprocess.run(["docker","exec","gcp-vm-database-1","psql","-XAt","-U","nextstop_app","-d","nextstop","-c","SELECT to_regnamespace('nextstop') IS NULL"],capture_output=True,text=True,check=True)
assert result.stdout.strip()=="t", "Refusing to overwrite existing staging schema"
print(json.dumps({{"databaseReady":True,"applicationStarted":False,"secretsMode":oct(secrets_path.stat().st_mode&0o777),"releaseDirectory":str(root)}}))
'''


def dump_script(directory):
    excludes = " ".join("--exclude-table-data=nextstop." + table for table in PRIVATE_TABLES)
    script = f'''set -eu
umask 077
sudo mkdir -m 700 -- {directory}
sudo chown "$(id -u):$(id -g)" {directory}
sudo docker exec {CONTAINER} nice -n 10 pg_dump -U nextstop_app -d nextstop -Fc --compress=1 --schema=nextstop --no-owner --no-privileges --lock-wait-timeout=500ms {excludes} > {directory}/public.dump
sudo docker exec -i {CONTAINER} pg_restore --list < {directory}/public.dump > {directory}/archive.list
python3 - {directory} <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);listing=(root/'archive.list').read_text()
{inspect.getsource(validate_archive_inventory)}
validate_archive_inventory(listing,{sorted(PUBLIC_TABLES)!r})
for table in {PRIVATE_TABLES!r}:
    assert ' TABLE DATA nextstop '+table+' ' not in listing, 'Private table data in seed archive'
digest=hashlib.sha256()
with (root/'public.dump').open('rb') as source:
    for chunk in iter(lambda: source.read(8*1024*1024),b''): digest.update(chunk)
print(json.dumps({{'size':(root/'public.dump').stat().st_size,'sha256':digest.hexdigest()}}))
PY
'''
    return "timeout --kill-after=10s 3600s bash -c " + shlex.quote(script) + " 2>/dev/null"


def restore_script(directory, expected):
    return f'''import hashlib,json,pathlib,subprocess,urllib.request
project=urllib.request.urlopen(urllib.request.Request("http://metadata.google.internal/computeMetadata/v1/project/project-id",headers={{"Metadata-Flavor":"Google"}}),timeout=5).read().decode()
assert project=="nextstop-tech-testing", "Refusing non-staging host"
path=pathlib.Path({directory!r})/"public.dump"
digest=hashlib.sha256()
with path.open("rb") as source:
    for chunk in iter(lambda:source.read(8*1024*1024),b""):digest.update(chunk)
assert path.stat().st_size=={expected['size']!r} and digest.hexdigest()=={expected['sha256']!r}
base=["docker","exec","{CONTAINER}","psql","-XAt","-U","nextstop_app","-d","nextstop","-c"]
assert subprocess.run(base+["SELECT to_regnamespace('nextstop') IS NULL"],capture_output=True,text=True,check=True).stdout.strip()=="t"
# Extensions live in public and are intentionally outside the application-only
# archive. The UUID+geography GiST indexes require btree_gist as well as PostGIS.
subprocess.run(base+["CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public; CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public"],capture_output=True,text=True,check=True)
# pg_restore's schema filter excludes the CREATE SCHEMA archive entry. Create
# only this verified-absent namespace; all objects/data restore in one transaction.
subprocess.run(base+["CREATE SCHEMA nextstop AUTHORIZATION nextstop_app"],capture_output=True,text=True,check=True)
try:
    with path.open("rb") as source:
        subprocess.run(["docker","exec","-i","{CONTAINER}","pg_restore","-U","nextstop_app","-d","nextstop","--schema=nextstop","--single-transaction","--exit-on-error","--no-owner","--no-privileges"],stdin=source,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,timeout=3600)
except BaseException:
    # No CASCADE: remove only the empty namespace we just created after rollback.
    # An uncertain committed restore or concurrent objects must remain intact.
    subprocess.run(base+["DROP SCHEMA nextstop"],capture_output=True,text=True,check=False)
    raise
counts={{}}
for table in {PRIVATE_TABLES!r}:
    counts[table]=int(subprocess.run(base+["SELECT count(*) FROM nextstop."+table],capture_output=True,text=True,check=True).stdout)
assert not any(counts.values()), "Private staging tables must be empty"
for label,query in {{"activeChargingVersions":"SELECT count(*) FROM nextstop.projection_versions WHERE status='active'","activeFoodVersions":"SELECT count(*) FROM nextstop.food_poi_projection_versions WHERE status='active'","activeParks":"SELECT count(*) FROM nextstop.charging_park_projection p JOIN nextstop.projection_versions v ON v.id=p.projection_id WHERE v.status='active'","activeFoodPois":"SELECT count(*) FROM nextstop.food_poi_projection p JOIN nextstop.food_poi_projection_versions v ON v.id=p.projection_id WHERE v.status='active'"}}.items():
    counts[label]=int(subprocess.run(base+[query],capture_output=True,text=True,check=True).stdout)
assert counts["activeChargingVersions"]==1 and counts["activeFoodVersions"]==1 and counts["activeParks"]>0 and counts["activeFoodPois"]>0
subprocess.run(base+["ANALYZE"],capture_output=True,text=True,check=True,timeout=600)
print(json.dumps(counts))
'''


def seed():
    production, staging = configuration("production"), configuration("staging")
    if (production["project"]!="nextstop-tech-staging" or staging["project"]!="nextstop-tech-testing"
            or any(config["target"]["instance"]!="nextstop-backend" or config["database"]["mode"]!="local" for config in (production,staging))):
        raise RuntimeError("Seed targets must be the existing production and new isolated staging VMs.")
    metadata=json.loads(remote_python(production,metadata_script(),sudo=True))
    validate_source_inventory(metadata["tables"])
    if metadata["freeBytes"] < metadata["databaseBytes"]+10*1024**3:
        raise RuntimeError("Insufficient source disk space for a bounded public snapshot.")
    stage_free=int(remote_python(staging,"import shutil;print(shutil.disk_usage('/srv/nextstop').free)"))
    if stage_free < 2*metadata["databaseBytes"]+10*1024**3:
        raise RuntimeError("Insufficient staging disk space for dump plus restored database.")
    auth=metadata["publicAuthConfig"]
    if set(auth)!=set(AUTH_FIELDS) or any("\n" in value for value in auth.values()):
        raise RuntimeError("Public App Attest metadata is incomplete.")
    operation=uuid.uuid4().hex
    directory=f"/srv/nextstop/.public-seed-{operation}"
    release_directory=f"/opt/nextstop/bootstrap-public-seed-{operation}"
    temporary=Path(tempfile.mkdtemp(prefix="nextstop-public-seed-",dir="/tmp"))
    if shutil.disk_usage(temporary).free < metadata["databaseBytes"]+1024**3:
        raise RuntimeError("Insufficient local disk space.")
    event("public-seed-preflight",databaseBytes=metadata["databaseBytes"],operation=operation)
    bundle_path=temporary/"deployment.tar.gz"
    with tarfile.open(bundle_path,"w:gz") as bundle:
        for subtree in (ROOT/"deploy/gcp-vm",ROOT/"deploy/releases"):
            for file in sorted(subtree.rglob("*")):
                if file.is_file() and ".env" not in file.name and "__pycache__" not in file.parts and not file.name.endswith(".pyc"):
                    bundle.add(file,arcname=str(file.relative_to(ROOT)),recursive=False)
    remote_bundle=f"/tmp/nextstop-public-seed-{operation}.tar.gz"
    transfer(staging,bundle_path,staging["target"]["instance"]+":"+remote_bundle)
    prepared=json.loads(remote_python(staging,prepare_script(auth,release_directory,remote_bundle),sudo=True))
    event("staging-database-prepared",**prepared)
    event("public-dump-started")
    dump=json.loads(ssh(production,dump_script(directory),timeout=3660))
    event("public-dump-validated",size=dump["size"])
    local_dump=temporary/"public.dump"
    descriptor=os.open(local_dump,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(descriptor)
    transfer(production,production["target"]["instance"]+":"+directory+"/public.dump",local_dump)
    os.chmod(local_dump,0o600)
    if local_dump.stat().st_size!=dump["size"] or archive_sha256(local_dump)!=dump["sha256"]:
        raise RuntimeError("Transferred public dump checksum mismatch.")
    ssh(staging,"sudo mkdir -m 700 -- "+directory+" && sudo chown \"$(id -u):$(id -g)\" "+directory)
    transfer(staging,local_dump,staging["target"]["instance"]+":"+directory+"/public.dump")
    ssh(staging,"chmod 600 -- "+directory+"/public.dump")
    event("staging-restore-started")
    counts=json.loads(remote_python(staging,restore_script(directory,dump),sudo=True,timeout=3660))
    event("staging-seed-verified",**counts)
    # Only generated dump copies are removed, and only after validated restore.
    ssh(production,cleanup_script(directory))
    ssh(staging,cleanup_script(directory,staging=True))
    shutil.rmtree(temporary)
    event("public-seed-completed",releaseDirectory=release_directory)


if __name__ == "__main__":
    try:
        seed()
    except (RuntimeError,ValueError,KeyError,OSError):
        print("Public staging seed failed. No production data was changed; keep temporary dumps until verified recovery.",file=sys.stderr)
        raise SystemExit(1)
