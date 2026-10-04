import { createHash } from "node:crypto";

export interface MigrationManifestEntry {
  readonly name: string;
  readonly sha256: string;
  readonly compatibility: "historical" | "expand";
}

// Historical migrations predate online deployment. Their exact reviewed bytes
// remain usable for isolated bootstrap, never as new automatic rolling changes.
export const migrationManifest: readonly MigrationManifestEntry[] = [
  { name: "0001_initial_postgis_projection.sql", sha256: "d09cd9acb57e526f5225acc3cf66be740a87847d2c8c42767eea31f4ee2f6d47", compatibility: "historical" },
  { name: "0002_live_availability_snapshots.sql", sha256: "896aa20549d272a531083c5596862a3bb7f40f57ac26f717bd71a3cafd4d14e9", compatibility: "historical" },
  { name: "0003_operator_charging_point_counts.sql", sha256: "934c012d67267ec2adbe243e0228dbaeb680d9e9680664306c897fe519a88bef", compatibility: "historical" },
  { name: "0004_osm_food_poi_projection.sql", sha256: "0954413d6777858da559c9963e1cb1a5f607f5c29e76cf23bea669c378c18b77", compatibility: "historical" },
  { name: "0005_power_search_projection.sql", sha256: "e1da9582a7884ff377da545a65f083c3f884a2ee391968504cf119d7eeae69ed", compatibility: "historical" },
  { name: "0006_power_projection_work_memory.sql", sha256: "7cd26721278c847f2438c7d4ac8babe7414b4f880073a7961ee7d34b74d4580e", compatibility: "historical" },
  { name: "0007_power_projection_spatial_lookup.sql", sha256: "e0644f5e71c2a3e094aeeca02c4e0990dd1a801972808b478c91df1c1c0f3427", compatibility: "historical" },
  { name: "0008_conditional_charging_campus.sql", sha256: "e1723c576a3a671334ef1555b9c4ef452d1732bd3b5c5f40d8bf0d68d87409f9", compatibility: "historical" },
  { name: "0009_app_attest_authentication.sql", sha256: "59fd1bf7ec174181557026d3d16072c7d59dc07b2600d82c55b5ace395d4910f", compatibility: "historical" },
  { name: "0010_audit_only_projection_conflicts.sql", sha256: "e5295e3f1ef1ee8a7530d2f0b7372a6c7bcef6a7286235b8b16d991539b4c108", compatibility: "historical" },
  { name: "0011_user_error_reports.sql", sha256: "054e14d8e0ff4be5c9baf92dacd72cabf76c0b5e51773edb483d2b54847ce54f", compatibility: "historical" },
  { name: "0012_projection_build_statistics.sql", sha256: "cb993cbb61ec24f589b388a692a6495cc0b0b466b63091ae0baadca240780549", compatibility: "historical" },
  { name: "0013_search_projection_retention.sql", sha256: "35db54686383e9d8fc173002ea1f99848a49f2366027cfb69549d958bef2f3eb", compatibility: "historical" },
  { name: "0014_static_projection_input_checks.sql", sha256: "62d047f2587e821aab915d3246366bfa2cfdc0c6ce792dbb6693d4eae6c13e84", compatibility: "historical" },
  { name: "0015_runtime_readiness.sql", sha256: "4eac9074003426a6974baeab2de307458e30b4feef66035d457b222fd79402b4", compatibility: "expand" },
  { name: "0016_demand_live_refresh.sql", sha256: "508c8f37240f4a1810d50789caff45235ef0ee0477642dbe96cb5c5a9d33906c", compatibility: "expand" },
  { name: "0017_monthly_ingestion_schedule.sql", sha256: "10f41f81f7e3d3180245fd6d1c55af0b1d23d7e0ebacd4dfc0991bf44a6808d5", compatibility: "expand" },
  { name: "0018_monthly_import_budget.sql", sha256: "4e5f9058fc9f3f4b3f59b33e3a406ed91802c309ad076dce27610742fe7bf004", compatibility: "expand" },
];

export interface MigrationSource {
  readonly name: string;
  readonly sql: string;
}

export function validateMigrationSources(sources: readonly MigrationSource[]): void {
  if (sources.length !== migrationManifest.length) throw new Error("Migration manifest does not match SQL files.");
  const seen = new Set<string>();
  for (const source of sources) {
    const entry = migrationManifest.find(({ name }) => name === source.name);
    if (entry === undefined || seen.has(source.name)) throw new Error("Unclassified or duplicate migration.");
    seen.add(source.name);
    if (createHash("sha256").update(source.sql).digest("hex") !== entry.sha256) {
      throw new Error(`Migration bytes differ from the reviewed manifest: ${source.name}`);
    }
    if (entry.compatibility === "historical") {
      if (entry.name > "0014_static_projection_input_checks.sql") {
        throw new Error("New migrations cannot use the historical bootstrap exemption.");
      }
    } else {
      assertExpandOnlySQL(source.sql);
    }
  }
}

export function assertExpandOnlySQL(sql: string): void {
  const statements = sql.replace(/--[^\n]*/gu, "").replace(/\/\*[\s\S]*?\*\//gu, "");
  // Intentionally conservative. A destructive/data-rewriting migration needs a
  // separately reviewed maintenance procedure, never an automatic production run.
  if (/\b(?:DROP|TRUNCATE|DELETE|UPDATE|RENAME)\b/iu.test(statements) ||
      /\bALTER\s+TABLE\b[^;]*\b(?:ALTER\s+(?:COLUMN\s+)?|SET\s+NOT\s+NULL|ADD\s+CONSTRAINT)\b/iu.test(statements) ||
      /\bALTER\s+TABLE\b[^;]*\bADD\s+(?:COLUMN\s+)?[^;]*\bNOT\s+NULL\b/iu.test(statements) ||
      /\bCREATE\s+OR\s+REPLACE\b/iu.test(statements)) {
    throw new Error("Automatic rolling migrations must be additive and preserve existing readers and writers.");
  }
}
