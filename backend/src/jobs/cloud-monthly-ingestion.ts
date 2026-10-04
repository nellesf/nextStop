import type { Pool } from "pg";
import { nextMonthlyImport, runDueMonthlyImports, type MonthlyIngestionDependencies, type MonthlyIngestionJob } from "./monthly-ingestion.js";

export interface MonthlyImportBudget {
  reserve(now: Date): Promise<boolean>;
  deferDueUntilNextMonth(now: Date): Promise<void>;
}

export class PostgresMonthlyImportBudget implements MonthlyImportBudget {
  constructor(private readonly pool: Pool) {}
  async reserve(now: Date): Promise<boolean> {
    const month = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10);
    const result = await this.pool.query(`INSERT INTO nextstop.monthly_import_budget (scope, month_start, attempts)
      VALUES ('monthly-import', $1::date, 1)
      ON CONFLICT (scope) DO UPDATE SET month_start = EXCLUDED.month_start,
        attempts = CASE WHEN monthly_import_budget.month_start < EXCLUDED.month_start THEN 1
          ELSE monthly_import_budget.attempts + 1 END
      WHERE monthly_import_budget.month_start < EXCLUDED.month_start
        OR (monthly_import_budget.month_start = EXCLUDED.month_start AND monthly_import_budget.attempts < 3)
      RETURNING attempts`, [month]);
    return result.rowCount === 1;
  }
  async deferDueUntilNextMonth(now: Date): Promise<void> {
    await this.pool.query(`UPDATE nextstop.monthly_ingestion_schedule SET next_due_at = $2
      WHERE next_due_at <= $1`, [now, nextMonthlyImport(now)]);
  }
}

/** Three whole executions (charging + food together), not three attempts per provider. */
export async function runBudgetedMonthlyImports(dependencies: MonthlyIngestionDependencies,
  budget: MonthlyImportBudget): Promise<"not_due" | "completed" | "budget_exhausted"> {
  const release = await dependencies.schedule.acquireMaintenance();
  if (release === undefined) throw new Error("MonthlyImportBusy");
  try {
    const now = dependencies.now ?? (() => new Date());
    const jobs: readonly MonthlyIngestionJob[] = dependencies.foodEnabled ? ["charging-static", "food-pois"] : ["charging-static"];
    let due = false;
    for (const job of jobs) if ((await dependencies.schedule.dueAt(job, now())).getTime() <= now().getTime()) due = true;
    if (!due) return "not_due";
    if (!await budget.reserve(now())) {
      await budget.deferDueUntilNextMonth(now());
      return "budget_exhausted";
    }
    let failed = false;
    await runDueMonthlyImports({ ...dependencies,
      // Already held across due check, budget reservation, download and publish.
      schedule: {
        acquireMaintenance: () => Promise.resolve(() => Promise.resolve()),
        dueAt: (job, time) => dependencies.schedule.dueAt(job, time),
        claim: (job, time, attempt) => dependencies.schedule.claim(job, time, attempt),
        complete: (job, time, attempt) => dependencies.schedule.complete(job, time, attempt),
      },
      report: (job, outcome) => { if (outcome === "failed") failed = true; dependencies.report(job, outcome); },
    });
    if (failed || dependencies.stopped()) throw new Error("MonthlyImportFailed");
    return "completed";
  } finally { await release(); }
}
