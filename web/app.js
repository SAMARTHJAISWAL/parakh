// UI for the parakh browser demo. All profiling happens in worker.js.

const $ = (id) => document.getElementById(id);
const worker = new Worker(new URL("./worker.js", import.meta.url), { type: "module" });
let last = null;
let busy = false;

// ------------------------------------------------------------ formatting

const nf0 = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
function fmtNum(x) {
  if (x === null || x === undefined) return "";
  const a = Math.abs(x);
  if (Number.isInteger(x) && a < 1e15) return nf0.format(x);
  if (a >= 1e9 || (a > 0 && a < 1e-4)) return x.toExponential(2);
  const d = a >= 1000 ? 1 : a >= 1 ? 2 : 4;
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: d }).format(x);
}
function fmtCount(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
  if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
  return nf0.format(n);
}
function fmtBytes(b) {
  if (b >= 2 ** 30) return (b / 2 ** 30).toFixed(2) + " GiB";
  if (b >= 2 ** 20) return (b / 2 ** 20).toFixed(1) + " MiB";
  if (b >= 2 ** 10) return (b / 2 ** 10).toFixed(1) + " KiB";
  return b + " B";
}
function fmtPct(r) {
  if (r === 0) return "0%";
  if (r < 0.001) return "<0.1%";
  return (r * 100).toFixed(1) + "%";
}
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const clean = (s) => String(s).replace(/[\x00-\x1f\x7f]/g, " ");
const approx = (exact, text) => (exact ? text : `<span class="approx" title="sketch estimate">~</span>${text}`);

// ------------------------------------------------------------ running

let generated = false;
function start(input, name) {
  if (busy) return;
  generated = input.kind === "orders";
  busy = true;
  document.querySelectorAll(".chip").forEach((b) => (b.disabled = true));
  $("error").hidden = true;
  $("results").hidden = true;
  $("progress").hidden = false;
  $("bar-fill").style.width = "0%";
  $("progress-label").textContent = `Reading ${name}…`;
  $("progress-rate").textContent = "";
  startedAt = performance.now();
  worker.postMessage({
    input,
    name,
    hasHeader: $("opt-header").checked,
    delimiter: Number($("opt-delim").value),
    topN: Number($("opt-top").value),
  });
}
let startedAt = 0;

worker.onmessage = (e) => {
  const m = e.data;
  if (m.type === "progress") {
    const pct = m.total ? Math.min(100, (m.bytes / m.total) * 100) : 0;
    $("bar-fill").style.width = pct.toFixed(1) + "%";
    const secs = (performance.now() - startedAt) / 1000;
    $("progress-label").textContent = `${fmtBytes(m.bytes)} of ${fmtBytes(m.total)}`;
    if (secs > 0.2) $("progress-rate").textContent = `${(m.bytes / 2 ** 20 / secs).toFixed(0)} MiB/s`;
    return;
  }
  busy = false;
  document.querySelectorAll(".chip").forEach((b) => (b.disabled = false));
  $("progress").hidden = true;
  if (m.type === "error") {
    $("error").textContent = `Could not profile this file: ${m.message}`;
    $("error").hidden = false;
    return;
  }
  last = m;
  render(m);
};

// ------------------------------------------------------------ rendering

function sparkline(hist, cls = "") {
  const w = 192, h = 26, n = hist.length, gap = 2;
  const bw = (w - gap * (n - 1)) / n;
  const max = Math.max(...hist, 1);
  let bars = "";
  hist.forEach((v, i) => {
    if (!v) return;
    const bh = Math.max(2, (v / max) * h);
    bars += `<rect x="${(i * (bw + gap)).toFixed(1)}" y="${(h - bh).toFixed(1)}" width="${bw.toFixed(1)}" height="${bh.toFixed(1)}" rx="1.5"/>`;
  });
  return `<svg class="spark ${cls}" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img" aria-label="distribution">${bars}</svg>`;
}

function shapeCell(c, total) {
  if (c.numeric) return sparkline(c.numeric.histogram);
  if (c.temporal) return sparkline(c.temporal.histogram, "date") + `<div class="muted" style="font-size:12px">${nf0.format(c.temporal.span_days)} days</div>`;
  if (c.count > 1 && c.distinct >= 0.97 * c.count) return `<span class="muted">all distinct</span>`;
  if (c.top_values.length && c.count >= 1000 && c.top_values[0].count * 200 < c.count) return `<span class="muted">high cardinality</span>`;
  return `<div class="tops">${c.top_values.slice(0, 4).map((t) => `<span>${esc(clean(t.value))}<em>${Math.round((100 * t.count) / total)}%</em></span>`).join("")}</div>`;
}

function minMax(c) {
  if (c.numeric) return [fmtNum(c.numeric.min), approx(c.numeric.quantiles_exact, fmtNum(c.numeric.p50)), fmtNum(c.numeric.max)];
  if (c.temporal) return [esc(c.temporal.min.slice(0, 16)), "", esc(c.temporal.max.slice(0, 16))];
  if (c.text && c.type !== "boolean") return [`len ${c.text.min_length}`, "", `len ${c.text.max_length}`];
  return ["", "", ""];
}

function detailRow(c, total) {
  const kv = (pairs) => `<dl class="kv">${pairs.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join("")}</dl>`;
  let blocks = "";
  if (c.numeric) {
    const n = c.numeric;
    blocks += `<div><h4>Distribution${n.quantiles_exact ? "" : " (KLL estimate)"}</h4>${kv([
      ["min", fmtNum(n.min)], ["p05", fmtNum(n.p05)], ["p25", fmtNum(n.p25)], ["median", fmtNum(n.p50)],
      ["p75", fmtNum(n.p75)], ["p95", fmtNum(n.p95)], ["max", fmtNum(n.max)],
    ])}</div><div><h4>Moments</h4>${kv([
      ["mean", fmtNum(n.mean)], ["std dev", fmtNum(n.stddev)], ["sum", fmtNum(n.sum)],
    ])}</div>`;
  }
  if (c.temporal) blocks += `<div><h4>Range</h4>${kv([["first", esc(c.temporal.min)], ["last", esc(c.temporal.max)], ["span", nf0.format(c.temporal.span_days) + " days"]])}</div>`;
  blocks += `<div><h4>Counts</h4>${kv([
    ["values", nf0.format(c.count)], ["nulls", `${nf0.format(c.nulls)} (${fmtPct(c.null_ratio)})`],
    ["distinct", (c.distinct_exact ? "" : "~") + nf0.format(c.distinct)],
    ["anomalies", nf0.format(c.anomalies) + (c.anomaly_example ? ` · e.g. "${esc(clean(c.anomaly_example))}"` : "")],
    ...(c.text ? [["length", `${c.text.min_length}–${c.text.max_length} (avg ${c.text.mean_length.toFixed(1)})`]] : []),
  ])}</div>`;
  const keyLike = c.count > 1 && c.distinct >= 0.97 * c.count;
  const highCard = c.top_values.length && c.count >= 1000 && c.top_values[0].count * 200 < c.count;
  if (c.top_values.length && !keyLike && !highCard) {
    const max = c.top_values[0].count;
    blocks += `<div><h4>Top values${c.top_exact ? "" : " (lower bounds)"}</h4><div class="toplist">${c.top_values
      .map((t) => `<div><i style="width:${((100 * t.count) / max).toFixed(1)}%"></i><span>${esc(clean(t.value)) || '<span class="muted">(empty)</span>'}</span><b>${nf0.format(t.count)} · ${((100 * t.count) / total).toFixed(1)}%</b></div>`)
      .join("")}</div></div>`;
  }
  return `<tr class="detail" hidden><td colspan="9"><div class="detail-grid">${blocks}</div></td></tr>`;
}

function render(m) {
  const r = m.json;
  const secs = m.ms / 1000;
  const warns = r.findings.filter((f) => f.severity === "warn").length;
  $("summary").innerHTML = [
    ["rows", nf0.format(r.rows)],
    ["columns", r.column_count],
    ["size", fmtBytes(r.bytes)],
    [generated ? "time (incl. sample gen)" : "time", secs < 1 ? `${Math.round(m.ms)} ms` : `${secs.toFixed(2)} s`],
    ["throughput", r.bytes < 2 ** 20 ? "—" : `${(r.bytes / 2 ** 20 / Math.max(secs, 1e-3)).toFixed(0)} MiB/s`],
    ["engine memory", fmtBytes(m.wasmMemory)],
    ["warnings", warns],
  ].map(([k, v], i) => `<div class="stat${i === 5 ? " hl" : ""}"><b>${v}</b><span>${k}</span></div>`).join("");

  $("findings").innerHTML = r.findings
    .map((f) => `<div class="finding ${f.severity}"><span class="sev">${f.severity === "warn" ? "warn" : "info"}</span><span class="col">${esc(f.column ?? "(file)")}</span><span>${esc(clean(f.message))}</span></div>`)
    .join("");

  const total = r.rows || 1;
  $("col-body").innerHTML = r.columns.map((c) => {
    const [mn, md, mx] = minMax(c);
    return `<tr class="row" tabindex="0" aria-expanded="false">
      <td class="num muted">${c.index + 1}</td>
      <td class="name" title="${esc(c.name)}">${esc(c.name)}</td>
      <td><span class="type t-${c.type}">${c.type}</span></td>
      <td class="num"><span class="nulls">${fmtPct(c.null_ratio)}<span class="nullbar"><i style="width:${(c.null_ratio * 100).toFixed(1)}%"></i></span></span></td>
      <td class="num">${approx(c.distinct_exact, fmtCount(c.distinct))}</td>
      <td class="num">${mn}</td><td class="num">${md}</td><td class="num">${mx}</td>
      <td class="shape">${shapeCell(c, total)}</td>
    </tr>${detailRow(c, total)}`;
  }).join("");

  $("view-terminal").textContent = m.table;
  $("results").hidden = false;
  $("results").scrollIntoView({ behavior: "smooth", block: "start" });
}

// ------------------------------------------------------------ interactions

$("col-body").addEventListener("click", (e) => toggle(e.target.closest("tr.row")));
$("col-body").addEventListener("keydown", (e) => {
  if (e.key === "Enter" || e.key === " ") {
    e.preventDefault();
    toggle(e.target.closest("tr.row"));
  }
});
function toggle(row) {
  if (!row) return;
  const open = row.classList.toggle("open");
  row.setAttribute("aria-expanded", String(open));
  row.nextElementSibling.hidden = !open;
}

document.querySelectorAll(".tabs button").forEach((b) =>
  b.addEventListener("click", () => {
    document.querySelectorAll(".tabs button").forEach((x) => x.setAttribute("aria-selected", String(x === b)));
    $("view-columns").hidden = b.dataset.view !== "columns";
    $("view-terminal").hidden = b.dataset.view !== "terminal";
  }),
);

$("copy-md").addEventListener("click", async () => {
  if (!last) return;
  await navigator.clipboard.writeText(last.markdown);
  flash($("copy-md"), "Copied");
});
$("dl-json").addEventListener("click", () => {
  if (!last) return;
  const blob = new Blob([JSON.stringify(last.json, null, 2)], { type: "application/json" });
  const a = Object.assign(document.createElement("a"), { href: URL.createObjectURL(blob), download: `${last.json.source}.profile.json` });
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
});
function flash(btn, text) {
  const old = btn.textContent;
  btn.textContent = text;
  setTimeout(() => (btn.textContent = old), 1200);
}

$("file").addEventListener("change", (e) => {
  const f = e.target.files[0];
  if (f) start({ kind: "file", file: f }, f.name);
  e.target.value = "";
});
const drop = $("drop");
["dragenter", "dragover"].forEach((t) => drop.addEventListener(t, (e) => { e.preventDefault(); drop.classList.add("over"); }));
["dragleave", "drop"].forEach((t) => drop.addEventListener(t, () => drop.classList.remove("over")));
drop.addEventListener("drop", (e) => {
  e.preventDefault();
  const f = e.dataTransfer.files[0];
  if (f) start({ kind: "file", file: f }, f.name);
});
window.addEventListener("dragover", (e) => e.preventDefault());
window.addEventListener("drop", (e) => e.preventDefault());

document.querySelectorAll(".chip").forEach((b) =>
  b.addEventListener("click", () => {
    if (b.dataset.sample === "messy") start({ kind: "messy" }, "messy_orders.csv");
    else start({ kind: "orders", rows: Number(b.dataset.rows) }, "orders_sample.csv");
  }),
);

fetch("./parakh.wasm", { method: "HEAD" })
  .then((r) => {
    const n = Number(r.headers.get("content-length"));
    if (n) $("wasm-size").textContent = `${Math.round(n / 1024)} KB`;
  })
  .catch(() => {});
