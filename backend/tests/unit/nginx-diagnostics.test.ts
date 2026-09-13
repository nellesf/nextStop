import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const deploymentRoot = new URL("../../../deploy/gcp-vm/", import.meta.url);

void test("nginx error records can interpolate only allowlisted metadata", async () => {
  const configuration = await readConfiguration("nginx-request-diagnostics.conf");
  const format = configuration.match(/log_format nextstop_diagnostic escape=json\s+([\s\S]*?);/u)?.[1];
  assert.ok(format);
  const variables = [...new Set(format.match(/\$[a-z_][a-z_0-9]*/gu))].sort();
  assert.deepEqual(variables, [
    "$nextstop_diagnostic_route", "$nextstop_edge_error_category",
    "$nextstop_upstream_request_id", "$request_id", "$request_time", "$status", "$time_iso8601",
  ]);

  const values: Readonly<Record<string, string>> = {
    $nextstop_diagnostic_route: "unknown",
    $nextstop_edge_error_category: "upstream_failure",
    $nextstop_upstream_request_id: "",
    $request_id: "0123456789abcdef0123456789abcdef",
    $request_time: "0.123",
    $status: "502",
    $time_iso8601: "2026-09-11T06:49:15+00:00",
    // A future addition of any raw request field must fail the allowlist above.
    $request_uri: "/PRIVATE_ROUTE?token=PRIVATE_TOKEN",
    $http_authorization: "PRIVATE_BEARER",
    $remote_addr: "192.0.2.179",
    $http_x_request_id: "PRIVATE_CLIENT_ID",
  };
  const rendered = [...format.matchAll(/'([^']*)'/gu)].map((match) => match[1]).join("")
    .replace(/\$[a-z_][a-z_0-9]*/gu, (variable) => values[variable] ?? "PRIVATE_UNKNOWN_VARIABLE");
  assert.deepEqual(JSON.parse(rendered), {
    event: "http_edge_error", timestamp: "2026-09-11T06:49:15+00:00", route: "unknown",
    edgeRequestId: "0123456789abcdef0123456789abcdef", upstreamRequestId: "",
    status: 502, durationSeconds: 0.123, errorCategory: "upstream_failure",
  });
  assert.doesNotMatch(rendered, /PRIVATE_|192\.0\.2\.179/u);

  const routeMap = mapBody(configuration, "$uri", "$nextstop_diagnostic_route");
  assert.deepEqual(routeMap.trim().split(/\s*;\s*/u).filter(Boolean), [
    "default unknown", "/health health", "/v1/charging-parks/search charging_park_search",
    "/v1/error-reports user_error_report",
    "/v1/auth/app-attest/challenge app_attest_challenge",
    "/v1/auth/app-attest/attest app_attest_attestation",
    "/v1/auth/app-attest/assert app_attest_assertion",
  ]);
  assert.doesNotMatch(mapBody(configuration, "$status", "$nextstop_edge_error_category"), /\$/u);
});

void test("nginx emits only errors and accepts only API-generated UUID response correlation", async () => {
  const configuration = await readConfiguration("nginx-request-diagnostics.conf");
  const selection = mapBody(configuration, "$status", "$nextstop_log_error");
  assert.match(selection, /^\s*default 0;\s*~\^\[45\] 1;\s*$/u);

  // Extract and exercise the actual configured regex; arbitrary upstream text is omitted.
  const upstream = configuration.match(
    /map \$upstream_http_x_request_id \$nextstop_upstream_request_id \{\s*default "";\s*"~\*([^"\n]+)" \$upstream_http_x_request_id;\s*\}/u,
  );
  assert.ok(upstream?.[1]);
  const acceptedId = new RegExp(upstream[1], "iu");
  assert.equal(acceptedId.test("11111111-2222-4333-8444-555555555555"), true);
  for (const value of ["PRIVATE_TOKEN", "192.0.2.179", "11111111-2222-4333-8444-555555555555/PRIVATE_ROUTE"]) {
    assert.equal(acceptedId.test(value), false);
  }
  assert.doesNotMatch(configuration, /\$http_/u);
});

void test("every nginx server uses error-only diagnostics with generated response IDs", async () => {
  for (const name of ["nginx-http.conf", "nginx-https.conf"]) {
    const configuration = await readConfiguration(name);
    const include = "include /etc/nginx/nextstop-request-diagnostics.conf;";
    assert.ok(configuration.indexOf(include) >= 0);
    assert.ok(configuration.indexOf(include) < configuration.indexOf("server {"), "Define log format before use");
    const serverCount = [...configuration.matchAll(/^server \{/gmu)].length;
    const logs = [...configuration.matchAll(/^\s*access_log ([^;]+);/gmu)].map((match) => match[1]);
    assert.equal(logs.length, serverCount);
    for (const log of logs) {
      assert.equal(log, "/var/log/nextstop/nginx-errors.jsonl nextstop_diagnostic if=$nextstop_log_error");
    }
    // Each server and every named location that overrides add_header inheritance
    // must return nginx's generated ID, including locally rejected 413/429 requests.
    for (const block of configuration.split(/(?=^server \{|^ {4}location )/mu)) {
      if (!block.startsWith("server {") && !block.includes("add_header ")) continue;
      assert.match(block, /add_header X-Edge-Request-ID \$request_id always;/u);
      assert.doesNotMatch(block, /add_header X-Edge-Request-ID \$http_/u);
    }
  }
});

void test("deployment installs private bounded log rotation without truncating retained errors", async () => {
  const rotation = await readConfiguration("nginx-diagnostics.logrotate");
  assert.match(rotation, /^\/var\/log\/nextstop\/nginx-errors\.jsonl \{/u);
  assert.match(rotation, /^\s*daily$/mu);
  assert.match(rotation, /^\s*maxsize 10M$/mu);
  assert.match(rotation, /^\s*rotate 7$/mu);
  assert.match(rotation, /^\s*maxage 7$/mu);
  assert.match(rotation, /^\s*create 0640 www-data adm$/mu);
  assert.match(rotation, /\/bin\/kill -USR1/u);
  assert.doesNotMatch(rotation, /copytruncate/u);
  assert.match(await readConfiguration("bootstrap-vm.sh"), /apt-get install[^\n]* logrotate\b/u);
  for (const name of ["install-release.sh", "enable-tls.sh"]) {
    const installer = await readConfiguration(name);
    assert.ok(installer.indexOf("/etc/nginx/nextstop-request-diagnostics.conf") < installer.indexOf("nginx -t"));
    assert.match(installer, /\/etc\/logrotate\.d\/nextstop-diagnostics/u);
    assert.match(installer, /install -d -m 750 -o www-data -g adm \/var\/log\/nextstop/u);
    assert.match(installer, /chmod 640 \/var\/log\/nextstop\/nginx-errors\.jsonl/u);
    assert.doesNotMatch(installer, />\s*\/var\/log\/nextstop\/nginx-errors\.jsonl/u);
  }
});

function readConfiguration(name: string): Promise<string> {
  return readFile(new URL(name, deploymentRoot), "utf8");
}

function mapBody(configuration: string, source: string, target: string): string {
  const start = configuration.indexOf(`map ${source} ${target} {`);
  assert.ok(start >= 0);
  const bodyStart = configuration.indexOf("{", start) + 1;
  const end = configuration.indexOf("}", bodyStart);
  assert.ok(end >= bodyStart);
  return configuration.slice(bodyStart, end);
}
