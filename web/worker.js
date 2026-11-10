// Runs the parakh WebAssembly module off the main thread.
//
// The module pulls its input through the imported `js_read(ptr, len)`.
// For a dropped file, that is a synchronous FileReaderSync read of the next
// slice; for the built-in sample, rows are generated on demand. Either way
// the input is never held in memory as a whole.

import { messyCsv, OrdersGenerator } from "./samples.js";

let wasm = null;
let source = null; // { read(dest: Uint8Array) -> number, size, done }
const enc = new TextEncoder();
const dec = new TextDecoder();

async function load() {
  if (wasm) return wasm;
  const { instance } = await WebAssembly.instantiateStreaming(fetch("./parakh.wasm"), {
    env: {
      js_read(ptr, len) {
        const dest = new Uint8Array(wasm.memory.buffer, ptr, len);
        return source.read(dest);
      },
      js_log(ptr, len) {
        console.error("parakh:", dec.decode(new Uint8Array(wasm.memory.buffer, ptr, len)));
      },
    },
  });
  wasm = instance.exports;
  return wasm;
}

function progressReporter(total) {
  let last = 0;
  return (bytes) => {
    const now = performance.now();
    if (now - last > 80) {
      last = now;
      postMessage({ type: "progress", bytes, total });
    }
  };
}

function fileSource(file) {
  const reader = new FileReaderSync();
  let offset = 0;
  const report = progressReporter(file.size);
  return {
    size: file.size,
    read(dest) {
      if (offset >= file.size) return 0;
      const end = Math.min(file.size, offset + dest.length);
      const chunk = new Uint8Array(reader.readAsArrayBuffer(file.slice(offset, end)));
      dest.set(chunk);
      offset = end;
      report(offset);
      return chunk.length;
    },
  };
}

function bytesSource(bytes) {
  let offset = 0;
  return {
    size: bytes.length,
    read(dest) {
      const n = Math.min(dest.length, bytes.length - offset);
      dest.set(bytes.subarray(offset, offset + n));
      offset += n;
      return n;
    },
  };
}

function generatorSource(gen) {
  let pending = new Uint8Array(0);
  let produced = 0;
  const report = progressReporter(gen.estimatedBytes);
  return {
    size: gen.estimatedBytes,
    read(dest) {
      let n = 0;
      while (n < dest.length) {
        if (pending.length === 0) {
          const text = gen.next();
          if (text === null) break;
          pending = enc.encode(text);
        }
        const take = Math.min(pending.length, dest.length - n);
        dest.set(pending.subarray(0, take), n);
        pending = pending.subarray(take);
        n += take;
      }
      produced += n;
      report(produced);
      return n;
    },
  };
}

function readOutput(len) {
  return dec.decode(new Uint8Array(wasm.memory.buffer, wasm.parakh_output_ptr(), len)).slice();
}

onmessage = async (e) => {
  const { input, name, hasHeader, delimiter, topN } = e.data;
  try {
    await load();
    if (input.kind === "file") source = fileSource(input.file);
    else if (input.kind === "messy") source = bytesSource(enc.encode(messyCsv));
    else source = generatorSource(new OrdersGenerator(input.rows));

    const nameBytes = enc.encode(name);
    const ptr = wasm.parakh_alloc(nameBytes.length || 1);
    new Uint8Array(wasm.memory.buffer, ptr, nameBytes.length).set(nameBytes);

    const t0 = performance.now();
    const errLen = wasm.parakh_profile(ptr, nameBytes.length, hasHeader, delimiter, topN);
    const ms = performance.now() - t0;
    wasm.parakh_free(ptr, nameBytes.length || 1);
    if (errLen) throw new Error(readOutput(errLen));

    postMessage({
      type: "done",
      ms,
      wasmMemory: wasm.memory.buffer.byteLength,
      json: JSON.parse(readOutput(wasm.parakh_render(0))),
      markdown: readOutput(wasm.parakh_render(1)),
      table: readOutput(wasm.parakh_render(2)),
    });
  } catch (err) {
    postMessage({ type: "error", message: String(err && err.message ? err.message : err) });
  } finally {
    source = null;
  }
};
