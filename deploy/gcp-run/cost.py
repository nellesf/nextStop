#!/usr/bin/env python3
"""Recalculate the reviewable staging estimate; no billing or cloud requests."""
from decimal import Decimal, ROUND_HALF_UP
import json
from pathlib import Path


def estimate(plan):
    def money(value):
        return str(value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))

    totals = {"low": Decimal(0), "high": Decimal(0)}
    rows = []
    for item in plan["lineItems"]:
        rate = Decimal(str(item["unitEUR"]))
        low, high = (Decimal(str(item[key])) for key in ("lowQuantity", "highQuantity"))
        if rate < 0 or low < 0 or high < low:
            raise ValueError("Invalid cost model quantity or rate")
        values = {"low": low * rate, "high": high * rate}
        rows.append({"name": item["name"], **{key + "EUR": money(value) for key, value in values.items()}})
        for key in totals:
            totals[key] += values[key]
    reserve = Decimal(str(plan["reserveFraction"]))
    vat = Decimal(str(plan["exampleVATRate"]))
    if not 0 <= reserve <= 1 or not 0 <= vat <= 1:
        raise ValueError("Invalid reserve or illustrative tax rate")
    return {"currency": "EUR", "kind": "planning estimate, not actual billing or a hard spend cap",
            "lineItems": rows,
            "subtotalNetEUR": {key: money(value) for key, value in totals.items()},
            "withReserveNetEUR": {key: money(value * (1 + reserve)) for key, value in totals.items()},
            "withReserveAndExampleVATEUR": {key: money(value * (1 + reserve) * (1 + vat)) for key, value in totals.items()}}


if __name__ == "__main__":
    print(json.dumps(estimate(json.loads(Path(__file__).with_name("cost-plan.json").read_text())), indent=2))
