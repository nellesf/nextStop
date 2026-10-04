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
        self.assertLess(Decimal(result["withReserveNetEUR"]["high"]), Decimal(str(plan["verifiedUsageBaseline"]["normalized730HourNetEUR"])))
        self.assertTrue(any("before projected68.94EUR net" in gate for gate in plan["measurementGates"]))
        self.assertFalse(any("projected70EUR" in gate for gate in plan["measurementGates"]))

    def test_hourly_cleanup_replaces_daily_minimum_without_double_counting(self):
        plan = json.loads(Path(__file__).with_name("cost-plan.json").read_text())
        items = {row["name"]: row for row in plan["lineItems"]}
        cpu = items["Hourly cleanup CPU"]
        memory = items["Hourly cleanup memory"]
        self.assertEqual((cpu["lowQuantity"], cpu["highQuantity"]), (12, 60))
        self.assertEqual((memory["lowQuantity"], memory["highQuantity"]), (6, 30))
        self.assertEqual(items["Hourly purge and daily due checks CPU"]["lowQuantity"], 13 - 0.5)
        self.assertEqual(items["Hourly purge and daily due checks CPU"]["highQuantity"], 15 - 0.5)
        self.assertEqual(items["Hourly purge and daily due checks memory"]["lowQuantity"], 6.5 - 0.25)
        self.assertEqual(items["Hourly purge and daily due checks memory"]["highQuantity"], 7.5 - 0.25)
        delta = (Decimal("12") - Decimal("0.5")) * Decimal(str(cpu["unitEUR"])) + (Decimal("6") - Decimal("0.25")) * Decimal(str(memory["unitEUR"]))
        self.assertEqual(delta, Decimal("0.692208"))
        self.assertEqual(delta * Decimal("1.1") * Decimal("1.19"), Decimal("0.906100272"))
        high_delta = (Decimal("60") - Decimal("0.5")) * Decimal(str(cpu["unitEUR"])) + (Decimal("30") - Decimal("0.25")) * Decimal(str(memory["unitEUR"]))
        self.assertEqual(high_delta, Decimal("3.581424"))
        self.assertEqual(high_delta * Decimal("1.1") * Decimal("1.19"), Decimal("4.688084016"))
        result = estimate(plan)
        self.assertEqual(result["withReserveNetEUR"], {"low": "42.04", "high": "59.13"})
        self.assertEqual(result["withReserveAndExampleVATEUR"], {"low": "50.02", "high": "70.36"})

    def test_inverted_or_negative_quantity_is_not_a_savings_estimate(self):
        plan = json.loads(Path(__file__).with_name("cost-plan.json").read_text())
        plan["lineItems"][0]["highQuantity"] = -1
        with self.assertRaises(ValueError):
            estimate(plan)


if __name__ == "__main__":
    unittest.main()
