import { readMigrationSources } from "./migrate.js";
import { validateMigrationSources } from "./migration-policy.js";

const sources = await readMigrationSources();
validateMigrationSources(sources);
process.stdout.write(`Validated ${sources.length} reviewed migration files.\n`);
