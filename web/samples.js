// Demo inputs: the messy test fixture, and a deterministic generator that
// mirrors bench/generate.py so the in-browser benchmark matches the CLI one.

export const messyCsv = "\ufefforder_id,customer,region,amount,currency,ordered_at,shipped,notes\r\n1001,\"Sharma, Priya\",North,1250.50,INR,2024-01-03,true,\r\n1002,Rahul Verma,South,980,INR,2024-01-04,false,\"fragile, handle with care\"\r\n1003,\"Iyer, Anand\", South ,N/A,INR,2024-01-04,true,\"line one\r\nline two\"\r\n1004,Meera Nair,East,15000,INR,2024-01-05,yes,\r\n1005,\"Das, Rohan\",West,742.25,INR,2024-01-07,no,\"said \"\"ok\"\"\"\r\n1006,Kavya Rao,North,3100,INR,2024-01-09,true,\r\n1007,Arjun Mehta,North,pending,INR,2024-01-11,false,\r\n1008,Sana Khan,East,2210.75,INR,2024-01-12,true,\r\n1009,Vikram Singh,South,450,INR,2024-01-15,true,\r\n1010,Neha Gupta,West,1875,INR,2024-01-18,false,\r\n1011,Ishaan Bose,North,6400,INR,2024-01-20,true,extra,field\r\n1012,Tara Pillai,East,1325.5,INR,2024-01-22,true,\r\n";

// Small, fast, seedable PRNG (mulberry32).
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const regions = ["North", "South", "East", "West", "Central"];
const channels = ["web", "app", "store", "partner"];
const cities = ["Bengaluru", "Mumbai", "Delhi", "Pune", "Chennai", "Hyderabad", "Kolkata", "Jaipur", "Kochi", "Indore"];
const start = Date.UTC(2023, 0, 1);
const pick = (r, xs) => xs[Math.floor(r() * xs.length)];
const gauss = (r) => Math.sqrt(-2 * Math.log(1 - r())) * Math.cos(2 * Math.PI * r());
const triangular = (r, lo, hi, mode) => {
  const u = r(), c = (mode - lo) / (hi - lo);
  return u < c ? lo + Math.sqrt(u * (hi - lo) * (mode - lo)) : hi - Math.sqrt((1 - u) * (hi - lo) * (hi - mode));
};
const round2 = (x) => Math.round(x * 100) / 100;

export class OrdersGenerator {
  constructor(rows) {
    this.rows = rows;
    this.i = 0;
    this.r = rng(7);
    this.headerDone = false;
    this.estimatedBytes = rows * 73;
  }
  // Returns the next chunk of CSV text, or null when finished.
  next() {
    if (!this.headerDone) {
      this.headerDone = true;
      return "order_id,customer_id,city,region,channel,ordered_at,quantity,unit_price,discount,amount,returned,coupon\n";
    }
    if (this.i >= this.rows) return null;
    const r = this.r;
    const end = Math.min(this.rows, this.i + 2000);
    let out = "";
    for (; this.i < end; this.i++) {
      const qty = Math.max(1, Math.floor(-Math.log(1 - r()) * 3));
      const price = round2(Math.exp(6.2 + 0.8 * gauss(r)));
      const disc = pick(r, [0, 0, 0, 0.05, 0.1, 0.15]);
      const amount = round2(qty * price * (1 - disc));
      const day = new Date(start + Math.floor(triangular(r, 0, 700, 650)) * 86400000).toISOString().slice(0, 10);
      let city = pick(r, cities);
      if (r() < 0.002) city = " " + city + " ";
      const priceS = r() < 0.0001 ? "TBD" : String(price);
      const amountS = r() < 0.0004 ? "N/A" : String(amount);
      const coupon = r() < 0.8 ? "" : "SAVE" + (5 + Math.floor(r() * 26));
      const cust = "C" + String(1 + Math.floor(r() * 250000)).padStart(6, "0");
      out += `${100000 + this.i},${cust},${city},${pick(r, regions)},${pick(r, channels)},${day},${qty},${priceS},${disc},${amountS},${r() < 0.04},${coupon}\n`;
    }
    return out;
  }
}
