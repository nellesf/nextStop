# Optional Cloud Armor cost indication

Checked 2026-10-04 at 17:06 UTC. This is a price comparison, not a deployment
approval or a bill. No Cloud Armor, load balancer, address or certificate was
created. Prices below exclude VAT, credits and negotiated discounts.

Cloud Armor Standard plus an external Application Load Balancer would add about
**EUR 23.10–24.86 per month before requests and bytes** for one policy and
three to five rules in total, including the default rule. The existing staging
model is EUR 42.09–59.18 net, including its 10% reserve. The observed previous
staging usage normalized to 730 hours is EUR 68.94 net; that is not a monthly
invoice. The optional protection therefore cannot be promised to remain below
the previous cost across the modeled workload range.

## Smallest modeled configuration

One global external HTTPS Application Load Balancer, one serverless NEG pointing
to the existing gateway in `europe-west1`, one backend security policy, one
assigned static IPv4 address, the existing domain and a Compute Engine
Google-managed TLS certificate. No proxy VM, NAT, CDN, Enterprise subscription,
reCAPTCHA or additional application service is included. Google documents this
[Cloud Run topology](https://docs.cloud.google.com/load-balancing/docs/https/setup-global-ext-https-serverless)
and the supported
[managed certificate](https://docs.cloud.google.com/load-balancing/docs/ssl-certificates/google-managed-certs).

| Component | USD list price | EUR public catalog | Monthly quantity |
| --- | ---: | ---: | ---: |
| Standard policy | $5/month | EUR 4.40/month | 1 |
| Policy rules, including default | $1/rule-month | EUR 0.88/rule-month | 3–5 |
| Global forwarding-rule minimum | $0.025/hour | EUR 0.022/hour | 730 hours |
| IPv4 assigned to forwarding rule | $0 | EUR 0 | 1 |
| Global-policy requests | $0.75/million | EUR 0.659/million | Actual requests |
| Belgium LB data processing | $0.008/GiB in and out | EUR 0.00704/GiB in and out | Both byte directions |
| **Fixed subtotal** | **$26.25–28.25** | **EUR 23.10–24.86** | **Before requests/bytes** |

Sources: [Cloud Armor prices](https://cloud.google.com/armor/pricing),
[load-balancer prices](https://cloud.google.com/load-balancing/pricing),
[assigned-IP pricing](https://cloud.google.com/vpc/network-pricing#ipaddress), and
the live [Networking EUR catalog](https://cloudbilling.googleapis.com/v1/services/E505-1604-58F8/skus?currencyCode=EUR&pageSize=5000).
Catalog prices were effective at 07:00 UTC; tiny rounding differences from the
USD conversion are retained. Relevant SKUs: policy `4B13-E64F-4A2B`, rule
`A321-89BD-F5BC`, requests `1A87-DEB9-C4BE`, global forwarding minimum
`DEE3-C42E-3E4D`, Belgium inbound `352B-4670-13F6` and outbound
`8AE2-BE75-D426`. The first five forwarding rules share the minimum charge;
this estimate does not assume another existing load balancer pays it.

## Traffic examples and comparison

Assume each request carries 5 KiB and each response 50 KiB, with all responses
sent to Europe. This is an explicit example, not measured payload size. Internet
egress uses $0.12/GiB, approximately EUR 0.1056/GiB at the catalog's 0.88
conversion, with no free allowance. Provider downloads are not these requests.

| Monthly requests | Input / output GiB | Armor + LB, EUR net | Including example internet egress, EUR net |
| --- | ---: | ---: | ---: |
| 100,000 | 0.477 / 4.768 | 23.20–24.96 | 23.71–25.47 |
| 1,000,000 | 4.768 / 47.684 | 24.13–25.89 | 29.16–30.92 |

The existing staging model already budgets 10–50 GiB of internet egress. Add the
Armor + LB column, not the entire last column, when comparing those same bytes.
Adding 10% reserve to the new edge charges as well gives combined illustrative
ranges of **EUR 67.61–86.64** at 100,000 requests and **EUR 68.63–87.66** at
one million. The upper endpoint combines five rules with the high existing
workload scenario. Application compute under a changed request mix must be
measured separately. These ranges are not spending caps.

For serverless NEGs, Google charges internet outbound transfer but does not also
charge the serverless outbound-transfer rate for the same load-balanced path.
See [serverless NEG billing](https://cloud.google.com/load-balancing/pricing#serverless)
and [internet transfer prices](https://cloud.google.com/vpc/network-pricing#internet_egress).

A [regional external load balancer](https://docs.cloud.google.com/load-balancing/docs/https/setting-up-reg-ext-https-serverless)
in Belgium is also supported. Its forwarding minimum is the same (SKU
`A30C-6EFD-A10F`); regional Armor requests are EUR 0.527/million (SKU
`928E-CF60-E186`). That saves only EUR 0.132 per million requests before transfer.
Choosing Standard Network Tier instead of Premium lowers the modeled internet
rate to $0.085/GiB, approximately EUR 0.0748/GiB, without assuming its free
allowance. It uses a different regional network path and needs a proxy-only
subnet. Regional managed TLS uses Certificate Manager: allow a further
$0.20/EUR 0.176 per certificate-month if its free certificate tier is unavailable;
use a key type without per-connection fees. See
[certificate pricing](https://cloud.google.com/certificate-manager/pricing).

## Security and operational conditions

This would replace direct domain mapping at the gateway. Its ingress must be
restricted to `internal-and-cloud-load-balancing`, and direct public bypass paths
must be tested. Keeping the ordinary public `run.app` path open would bypass the
policy. Repeat the real two-source client-IP test behind the new proxy path.
See [Cloud Armor integration](https://docs.cloud.google.com/armor/docs/integrating-cloud-armor)
and [Cloud Run ingress](https://docs.cloud.google.com/run/docs/securing/ingress).

Keep API, auth, live worker and broker IAM-private. App Attest and application
token checks remain required. Disable or redact the new load-balancer request
logs before traffic; the current Cloud Run log exclusion does not cover them.
Rule false positives need testing against synthetic search and auth requests.
Standard charges requests even when security processing rejects them; it is not
an unlimited attack-cost guarantee. Enterprise, bot management, raw logging and
larger traffic volumes require a separate cost decision.
