import copy
from decimal import Decimal
import json
from pathlib import Path
import unittest

from cost import estimate


class CostTests(unittest.TestCase):
    def test_invoice_estimate_counts_database_backups_jobs_and_tax_without_free_allowances(self):
        plan = json.loads(Path(__file__).with_name("cost-plan.json").read_text())
        result = estimate(plan)
        self.assertFalse(plan["freeAllowancesAssumed"])
        rows = {row["name"]: row for row in result["lineItems"]}
        self.assertEqual(rows["Cloud SQL g1-small"]["lowEUR"], "22.48")
        self.assertEqual(rows["Cloud SQL SSD"]["lowEUR"], "7.48")
        self.assertGreater(Decimal(rows["Filtered daily backup CPU"]["highEUR"]), 0)
        self.assertGreater(Decimal(result["withReserveAndExampleVATEUR"]["high"]), Decimal(result["withReserveNetEUR"]["high"]))
        self.assertLess(Decimal(result["withReserveNetEUR"]["high"]), Decimal("70"))

    def test_inverted_or_negative_quantity_is_not_a_savings_estimate(self):
        plan = json.loads(Path(__file__).with_name("cost-plan.json").read_text())
        plan["lineItems"][0]["highQuantity"] = -1
        with self.assertRaises(ValueError):
            estimate(plan)


if __name__ == "__main__":
    unittest.main()
