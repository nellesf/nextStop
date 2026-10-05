BEGIN;

-- Cloud-only execution budget. No request, provider payload or user identifiers.
CREATE TABLE nextstop.monthly_import_budget (
  scope text PRIMARY KEY CHECK (scope = 'monthly-import'),
  month_start date NOT NULL CHECK (EXTRACT(DAY FROM month_start) = 1),
  attempts integer NOT NULL CHECK (attempts BETWEEN 0 AND 3)
);

INSERT INTO nextstop.schema_migrations (name)
VALUES ('0018_monthly_import_budget.sql');

COMMIT;
