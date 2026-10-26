#!/usr/bin/env bash
# Synthetic client compatibility gate only; no production access or data.
set -euo pipefail
umask 077

client_image=${1:?pass the locally built postgres-client image}
[[ "$client_image" =~ ^europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/postgres-client:[0-9a-f]{40}$ ]]
fixture_image=postgres@sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4
work=$(mktemp -d /tmp/nextstop-client-roundtrip.XXXXXXXX)
operation=${work##*.}
server=nextstop-client-fixture-${operation}
server_process=
client_names=()
client_number=0

cleanup() {
    status=$?
    trap - EXIT
    for name in "${client_names[@]}"; do
        docker rm -f "$name" >/dev/null 2>&1 || true
    done
    if [[ -n "$server_process" ]]; then
        docker rm -f "$server" >/dev/null 2>&1 || status=1
        kill "$server_process" 2>/dev/null || true
        wait "$server_process" 2>/dev/null || true
    fi
    rm -rf -- "$work"
    if [[ "$status" == 0 ]]; then
        printf '%s\n' '{"postgresClientRoundtrip":"passed","serverVersion":"17.11","syntheticDataOnly":true}'
    else
        printf '%s\n' 'PostgreSQL client roundtrip failed; private fixture diagnostics suppressed.' >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

client_id=$(docker image inspect --format '{{.Id}}' "$client_image")
[[ "$client_id" =~ ^sha256:[0-9a-f]{64}$ ]]
docker pull --platform linux/amd64 "$fixture_image" >"$work/pull.log" 2>&1
fixture_password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')

# The official fixture's postgres user is UID/GID 70. Bypass its server
# entrypoint/gosu entirely; initdb and postgres come only from this test image.
# The sole data directory is a fresh tmpfs, with no host ports or network route.
printf '%s\n' "$fixture_password" | docker run --rm --pull=never -i \
    --name "$server" --network none --read-only --user 70:70 \
    --cap-drop ALL --security-opt no-new-privileges --pids-limit 128 \
    --memory 768m --cpus 1 --log-driver none \
    --tmpfs /var/lib/postgresql/data:rw,noexec,nosuid,nodev,mode=0700,uid=70,gid=70,size=256m \
    --tmpfs /var/run/postgresql:rw,noexec,nosuid,nodev,mode=0700,uid=70,gid=70,size=1m \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,mode=0700,uid=70,gid=70,size=16m \
    --tmpfs /run/secrets:rw,noexec,nosuid,nodev,mode=0700,uid=70,gid=70,size=1m \
    --entrypoint /bin/sh "$fixture_image" -ec '
        test "$(id -u):$(id -g)" = "70:70"
        test "$(postgres --version)" = "postgres (PostgreSQL) 17.11"
        umask 077
        IFS= read -r password
        printf "%s\n" "$password" > /run/secrets/initdb-password
        unset password
        initdb -D /var/lib/postgresql/data --username=fixture --encoding=UTF8 \
          --locale=C --auth-local=scram-sha-256 --auth-host=scram-sha-256 \
          --pwfile=/run/secrets/initdb-password >/dev/null
        rm -f /run/secrets/initdb-password
        exec postgres -D /var/lib/postgresql/data -c listen_addresses=127.0.0.1 \
          -c unix_socket_directories=/var/run/postgresql -c log_statement=none \
          -c log_parameter_max_length_on_error=0
    ' >"$work/server.log" 2>&1 &
server_process=$!

client() {
    local network=$1
    shift
    client_number=$((client_number + 1))
    local name=nextstop-client-check-${operation}-${client_number}
    client_names+=("$name")
    # Only the first stdin line is the synthetic password. The remaining bytes
    # are passed unchanged to psql/pg_restore, including a binary custom archive.
    { printf '%s\n' "$fixture_password"; cat; } | docker run --rm --pull=never -i \
        --name "$name" --network "$network" --read-only --user 65532:65532 \
        --cap-drop ALL --security-opt no-new-privileges --pids-limit 32 \
        --memory 256m --cpus 1 --log-driver none \
        --tmpfs /run/secrets:rw,noexec,nosuid,nodev,mode=0700,uid=65532,gid=65532,size=1m \
        --entrypoint /bin/sh "$client_id" -ec '
            umask 077
            IFS= read -r password
            printf "127.0.0.1:5432:*:fixture:%s\n" "$password" > /run/secrets/.pgpass
            unset password
            export PGPASSFILE=/run/secrets/.pgpass
            exec "$@"
        ' postgres-client "$@" 2>>"$work/client.log"
}

connection=(--host=127.0.0.1 --port=5432 --username=fixture --no-password)
ready=false
for attempt in {1..30}; do
    if client "container:$server" psql -X "${connection[@]}" --dbname=postgres \
        --set=ON_ERROR_STOP=1 --command='SELECT 1' </dev/null > /dev/null; then
        ready=true
        break
    fi
    kill -0 "$server_process" 2>/dev/null || exit 1
    sleep 1
done
[[ "$ready" == true ]]

# Prove TCP really requires the password; a trust-auth fixture would invalidate
# the credential-handling test even if dump and restore happened to succeed.
correct_password=$fixture_password
fixture_password=deliberately-wrong-fixture-password
if client "container:$server" psql -X "${connection[@]}" --dbname=postgres \
    --command='SELECT 1' </dev/null > /dev/null; then
    exit 1
fi
fixture_password=$correct_password
unset correct_password

client "container:$server" psql -X "${connection[@]}" --dbname=postgres \
    --set=ON_ERROR_STOP=1 > /dev/null <<'SQL'
CREATE DATABASE fixture_source;
CREATE DATABASE fixture_restored;
SQL
client "container:$server" psql -X "${connection[@]}" --dbname=fixture_source \
    --set=ON_ERROR_STOP=1 > /dev/null <<'SQL'
CREATE TABLE parent (
    id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    label text NOT NULL UNIQUE,
    payload bytea NOT NULL,
    amount numeric(12,2) NOT NULL CHECK (amount >= 0)
);
CREATE TABLE child (
    id bigserial PRIMARY KEY,
    parent_id bigint NOT NULL REFERENCES parent(id)
);
INSERT INTO parent(label, payload, amount) VALUES
    ('Grüße aus Köln – 東京 🚗', decode('00017f80feff', 'hex'), 1234.50),
    ('Straße / naïve / Ελληνικά', decode(repeat('001122ff', 256), 'hex'), 0);
INSERT INTO child(parent_id) VALUES (1), (2);
SELECT setval(pg_get_serial_sequence('parent', 'id'), 40, true);
SELECT setval(pg_get_serial_sequence('child', 'id'), 70, true);
SQL

client "container:$server" pg_dump "${connection[@]}" --dbname=fixture_source \
    --format=custom --no-owner --no-privileges </dev/null >"$work/fixture.dump"
[[ -s "$work/fixture.dump" ]]
client none pg_restore --list <"$work/fixture.dump" >"$work/catalogue.txt"
[[ -s "$work/catalogue.txt" ]]
client "container:$server" pg_restore "${connection[@]}" --dbname=fixture_restored \
    --single-transaction --exit-on-error --no-owner --no-privileges \
    <"$work/fixture.dump" > /dev/null
client "container:$server" psql -X "${connection[@]}" --dbname=fixture_restored \
    --set=ON_ERROR_STOP=1 > /dev/null <<'SQL'
DO $check$
BEGIN
    IF (SELECT count(*) FROM parent) <> 2 OR (SELECT count(*) FROM child) <> 2
       OR NOT EXISTS (SELECT FROM parent WHERE id = 1
          AND label = 'Grüße aus Köln – 東京 🚗'
          AND payload = decode('00017f80feff', 'hex') AND amount = 1234.50)
       OR NOT EXISTS (SELECT FROM parent WHERE id = 2
          AND label = 'Straße / naïve / Ελληνικά'
          AND payload = decode(repeat('001122ff', 256), 'hex') AND amount = 0)
       OR (SELECT count(*) FROM child WHERE id = parent_id) <> 2 THEN
        RAISE EXCEPTION 'Restored data mismatch';
    END IF;
    IF nextval(pg_get_serial_sequence('parent', 'id')) <> 41
       OR nextval(pg_get_serial_sequence('child', 'id')) <> 71 THEN
        RAISE EXCEPTION 'Restored sequence mismatch';
    END IF;
    BEGIN
        INSERT INTO child(parent_id) VALUES (999);
        RAISE EXCEPTION 'Foreign key did not reject invalid data';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO parent(id, label, payload, amount) VALUES (999, 'invalid', '\x00', -1);
        RAISE EXCEPTION 'Check constraint did not reject invalid data';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$check$;
SQL
