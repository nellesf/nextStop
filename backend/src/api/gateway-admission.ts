export type GatewayAdmissionClass = "api" | "auth" | "reports" | "invalid";

/** Per-process public admission limits. Constant, dependency-free liveness is handled separately. */
export const gatewayAdmissionLimits = {
  api: { perIP: { burst: 5, perMinute: 60 }, global: { burst: 20, perMinute: 120 } },
  auth: { perIP: { burst: 5, perMinute: 12 }, global: { burst: 10, perMinute: 60 } },
  reports: { perIP: { burst: 3, perMinute: 6 }, global: { burst: 3, perMinute: 12 } },
  invalid: { perIP: { burst: 5, perMinute: 12 }, global: { burst: 10, perMinute: 60 } },
} as const;
const maximumIPEntries = 10_000;
const idleLifetimeMilliseconds = 300_000;
const sweepIntervalMilliseconds = 60_000;
interface Policy { readonly burst: number; readonly perMinute: number }
const requestCost = 60_000;
interface Bucket { credits: number; refilledAt: number; lastAcceptedAt: number }

export class GatewayAdmission {
  private readonly entries = new Map<string, Bucket>();
  private readonly global = new Map<GatewayAdmissionClass, Bucket>();
  private lastNow = Number.NEGATIVE_INFINITY;
  private nextSweepAt = Number.NEGATIVE_INFINITY;
  constructor(private readonly now: () => number) {}

  allows(address: string, group: GatewayAdmissionClass): boolean {
    const clock = this.now();
    if (!Number.isFinite(clock)) return false;
    const now = Math.max(clock, this.lastNow);
    this.lastNow = now;
    const policy = gatewayAdmissionLimits[group];
    const global = this.global.get(group) ?? this.bucket(policy.global, now);
    this.global.set(group, global);
    this.refill(global, policy.global, now);
    if (global.credits < requestCost) return false;

    const key = `${group}:${address}`;
    let local = this.entries.get(key);
    if (local === undefined) {
      // Never evict a live budget (which would grant a new burst) to admit a new IP.
      // A rejected caller cannot extend retention, and full-table sweeps are bounded.
      if (this.entries.size >= maximumIPEntries && now >= this.nextSweepAt) {
        this.nextSweepAt = now + sweepIntervalMilliseconds;
        for (const [oldKey, entry] of this.entries) {
          if (now - entry.lastAcceptedAt >= idleLifetimeMilliseconds) this.entries.delete(oldKey);
        }
      }
      if (this.entries.size >= maximumIPEntries) return false;
      local = this.bucket(policy.perIP, now);
      this.entries.set(key, local);
    }
    this.refill(local, policy.perIP, now);
    if (local.credits < requestCost) return false;
    // Consume both budgets only after both checks, so one noisy IP cannot spend
    // the allowance for other IPs merely by repeatedly hitting its own limit.
    local.credits -= requestCost;
    global.credits -= requestCost;
    local.lastAcceptedAt = now;
    global.lastAcceptedAt = now;
    return true;
  }

  private bucket(policy: Policy, now: number): Bucket {
    return { credits: policy.burst * requestCost, refilledAt: now, lastAcceptedAt: now };
  }
  private refill(bucket: Bucket, policy: Policy, now: number): void {
    bucket.credits = Math.min(policy.burst * requestCost, bucket.credits + (now - bucket.refilledAt) * policy.perMinute);
    bucket.refilledAt = now;
  }
}
