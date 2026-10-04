from decimal import Decimal
import json
from pathlib import Path
import unittest

from cost import estimate
import render
from test_render import configuration


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
        self.assertEqual(items["Hourly purge and daily due checks CPU"]["lowQuantity"], 13)
        self.assertEqual(items["Hourly purge and daily due checks CPU"]["highQuantity"], 15)
        self.assertEqual(items["Hourly purge and daily due checks memory"]["lowQuantity"], 10)
        self.assertEqual(items["Hourly purge and daily due checks memory"]["highQuantity"], 11)
        delta = (Decimal("12") - Decimal("0.5")) * Decimal(str(cpu["unitEUR"])) + (Decimal("6") - Decimal("0.25")) * Decimal(str(memory["unitEUR"]))
        self.assertEqual(delta, Decimal("0.692208"))
        self.assertEqual(delta * Decimal("1.1") * Decimal("1.19"), Decimal("0.906100272"))
        high_delta = (Decimal("60") - Decimal("0.5")) * Decimal(str(cpu["unitEUR"])) + (Decimal("30") - Decimal("0.25")) * Decimal(str(memory["unitEUR"]))
        self.assertEqual(high_delta, Decimal("3.581424"))
        self.assertEqual(high_delta * Decimal("1.1") * Decimal("1.19"), Decimal("4.688084016"))
        result = estimate(plan)
        self.assertEqual(result["withReserveNetEUR"], {"low": "42.09", "high": "59.18"})
        self.assertEqual(result["withReserveAndExampleVATEUR"], {"low": "50.09", "high": "70.43"})

    def test_daily_due_check_counts_the_rendered_monthly_job_resources(self):
        plan = json.loads(Path(__file__).with_name("cost-plan.json").read_text())
        items = {row["name"]: row for row in plan["lineItems"]}
        job = render.job(configuration(), "monthly")
        limits = job["spec"]["template"]["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"]
        self.assertEqual(render.SCHEDULES["monthly"], "0 2 * * *")
        billed_hours = Decimal(30 * 60) / Decimal(3600)
        due_cpu = Decimal(limits["cpu"]) * billed_hours
        self.assertTrue(limits["memory"].endswith("Gi"))
        due_memory = Decimal(limits["memory"].removesuffix("Gi")) * billed_hours
        self.assertEqual((due_cpu, due_memory), (Decimal("1"), Decimal("4")))
        for side, purge_cpu, purge_memory in (("low", 12, 6), ("high", 14, 7)):
            self.assertEqual(items["Hourly purge and daily due checks CPU"][side + "Quantity"], purge_cpu + due_cpu)
            self.assertEqual(items["Hourly purge and daily due checks memory"][side + "Quantity"], purge_memory + due_memory)
        correction = (due_cpu - Decimal("0.5")) * Decimal(str(items["Hourly purge and daily due checks CPU"]["unitEUR"]))
        correction += (due_memory - Decimal("0.25")) * Decimal(str(items["Hourly purge and daily due checks memory"]["unitEUR"]))
        self.assertEqual(correction, Decimal("0.052272"))
        self.assertEqual(correction * Decimal("1.1"), Decimal("0.0574992"))
        self.assertEqual(estimate(plan)["subtotalNetEUR"], {"low": "38.27", "high": "53.80"})

    def test_inverted_or_negative_quantity_is_not_a_savings_estimate(self):
        plan = json.loads(Path(__file__).with_name("cost-plan.json").read_text())
        plan["lineItems"][0]["highQuantity"] = -1
        with self.assertRaises(ValueError):
            estimate(plan)


if __name__ == "__main__":
    unittest.main()
