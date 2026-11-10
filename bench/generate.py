#!/usr/bin/env python3
"""Generate a realistic, slightly messy orders CSV for benchmarking parakh.

    python3 bench/generate.py 1000000 > /tmp/orders.csv
"""
import random
import sys
from datetime import date, timedelta

rows = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
rng = random.Random(7)
regions = ["North", "South", "East", "West", "Central"]
channels = ["web", "app", "store", "partner"]
cities = ["Bengaluru", "Mumbai", "Delhi", "Pune", "Chennai", "Hyderabad", "Kolkata", "Jaipur", "Kochi", "Indore"]
start = date(2023, 1, 1)
w = sys.stdout.write
w("order_id,customer_id,city,region,channel,ordered_at,quantity,unit_price,discount,amount,returned,coupon\n")
for i in range(rows):
    qty = max(1, int(rng.expovariate(1 / 3)))
    price = round(rng.lognormvariate(6.2, 0.8), 2)
    price_s = "TBD" if rng.random() < 0.0001 else f"{price}"
    disc = rng.choice([0, 0, 0, 0.05, 0.1, 0.15])
    amount = round(qty * price * (1 - disc), 2)
    day = start + timedelta(days=int(rng.triangular(0, 700, 650)))
    amount_s = "N/A" if rng.random() < 0.0004 else f"{amount}"
    city = rng.choice(cities)
    if rng.random() < 0.002:
        city = f" {city} "
    coupon = "" if rng.random() < 0.8 else f"SAVE{rng.randint(5, 30)}"
    w(f"{100000 + i},C{rng.randint(1, 250000):06d},{city},{rng.choice(regions)},{rng.choice(channels)},"
      f"{day.isoformat()},{qty},{price_s},{disc},{amount_s},{str(rng.random() < 0.04).lower()},{coupon}\n")
