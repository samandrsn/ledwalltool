// Resource allocation, power, weight and validation.
import { PROCESSOR_MODELS, VOLTAGES } from './catalog.js';
import { byId } from './model.js';
import { resolveRuns } from './routing.js';

export const KG2LB = 2.20462;
export const M2FT = 3.28084;

export function procModel(proc) {
  return { ...PROCESSOR_MODELS[proc.model] || PROCESSOR_MODELS.custom, ...(proc.modelOverride || {}) };
}

export function portCapacityPixels(project, proc) {
  const s = project.settings;
  if (!proc) return Math.floor(650000 * 60 / s.frameRate);
  const m = procModel(proc);
  let px = proc.portPixelsOverride > 0 ? proc.portPixelsOverride : m.portPixels;
  px = px * 60 / (s.frameRate || 60);
  if (m.halfAt10bit && s.bitDepth > 8) px *= 0.5;
  return Math.floor(px);
}

export function portsAvailable(proc, distributorsUsed) {
  const m = procModel(proc);
  let n = m.trunks ? m.portsPerDistributor * (proc.autoDistributors ? m.trunks : Math.min(proc.distributors || 0, m.trunks)) : m.directPorts;
  if (proc.backup) n = Math.floor(n / 2);
  return n;
}

// Distros are lettered per processor: processor 1 → 1A, 1B…
export const distroName = (proc, d) => `${proc.code}${String.fromCharCode(65 + d)}`;

// "1A-3" = processor 1, distro A, port 3. Direct-port processors: "1-P3".
export function portLabel(proc, i) {
  const m = procModel(proc);
  if (m.trunks) return `${distroName(proc, Math.floor(i / m.portsPerDistributor))}-${(i % m.portsPerDistributor) + 1}`;
  return `${proc.code}-P${i + 1}`;
}

export function circuitCapacity(project, pt, voltageKey) {
  const s = project.settings;
  const v = VOLTAGES.find(x => x.key === (voltageKey || s.voltage)) || VOLTAGES[1];
  const watts = v.v * s.breakerAmps * s.derate;
  let n = Math.floor(watts / Math.max(1, pt.wMax));
  if (pt.maxPerPowerLink > 0) n = Math.min(n, pt.maxPerPowerLink);
  return Math.max(1, n);
}

export const ampsAt = (watts) => ({
  '120 V 1Φ': watts / 120,
  '208 V 1Φ': watts / 208,
  '208 V 3Φ (per leg)': watts / (Math.sqrt(3) * 208),
  '230 V 1Φ': watts / 230,
  '240 V 1Φ': watts / 240,
  '400 V 3Φ (per leg)': watts / (Math.sqrt(3) * 400),
});

const FEEDERS = [30, 60, 100, 200, 400, 600, 800, 1200];
export const feederFor = amps => FEEDERS.find(f => f * 0.8 >= amps) || null;

export function analyze(project) {
  const s = project.settings;
  const issues = [];
  const res = { walls: new Map(), processors: new Map(), sources: new Map(), issues, totals: null };
  const add = (level, msg, ref) => issues.push({ level, msg, ref });
  const volt = VOLTAGES.find(x => x.key === s.voltage) || VOLTAGES[1];

  // ---- walls
  for (const wall of project.walls) {
    const pt = byId(project.panelTypes, wall.panelTypeId);
    if (!pt) { add('error', `${wall.name}: no panel type`, { wall: wall.id }); continue; }
    const dis = new Set(wall.disabled);
    const panelCount = wall.cols * wall.rows - [...dis].length;
    const proc = byId(project.processors, wall.processorId);
    const dataCapPx = portCapacityPixels(project, proc);
    let dataCap = Math.floor(dataCapPx / (pt.pxW * pt.pxH));
    if (pt.maxPerPort > 0) dataCap = Math.min(dataCap, pt.maxPerPort);
    const powerCap = circuitCapacity(project, pt);
    if (dataCap < 1) add('error', `${wall.name}: a single ${pt.name} exceeds one port's pixel capacity at ${s.frameRate} Hz / ${s.bitDepth}-bit`, { wall: wall.id });
    const dataRuns = resolveRuns(wall, 'data', Math.max(1, dataCap));
    const powerRuns = resolveRuns(wall, 'power', powerCap);

    // coverage checks
    for (const [kind, runs, cap] of [['data', dataRuns, dataCap], ['power', powerRuns, powerCap]]) {
      const seen = new Map();
      runs.forEach((run, i) => {
        if (run.panels.length > cap) add('error', `${wall.name}: ${kind} run ${i + 1} has ${run.panels.length} panels (max ${cap})`, { wall: wall.id, kind });
        for (const [c, r] of run.panels) seen.set(c + ',' + r, (seen.get(c + ',' + r) || 0) + 1);
      });
      let missing = 0, dup = 0;
      for (let c = 0; c < wall.cols; c++) for (let r = 0; r < wall.rows; r++) {
        const k = c + ',' + r; if (dis.has(k)) continue;
        const n = seen.get(k) || 0; if (!n) missing++; if (n > 1) dup++;
      }
      if (missing) add('error', `${wall.name}: ${missing} panel(s) have no ${kind} connection`, { wall: wall.id, kind });
      if (dup) add('error', `${wall.name}: ${dup} panel(s) on more than one ${kind} run`, { wall: wall.id, kind });
    }

    const kgPer = pt.kg + (wall.extraKgPerPanel || 0);
    res.walls.set(wall.id, {
      wall, pt, proc, panelCount,
      pixels: panelCount * pt.pxW * pt.pxH,
      resW: wall.cols * pt.pxW, resH: wall.rows * pt.pxH,
      widthM: wall.cols * pt.mmW / 1000, heightM: wall.rows * pt.mmH / 1000,
      kg: panelCount * kgPer,
      wMax: panelCount * pt.wMax, wAvg: panelCount * pt.wAvg,
      dataCap, dataCapPx, powerCap,
      dataRuns: dataRuns.map(r => ({ ...r, pixels: r.panels.length * pt.pxW * pt.pxH })),
      powerRuns: powerRuns.map(r => ({ ...r, watts: r.panels.length * pt.wMax, amps: r.panels.length * pt.wMax / volt.v })),
    });
    if (!proc) add('warn', `${wall.name}: not assigned to a processor`, { wall: wall.id });
  }

  // ---- processors: port allocation
  for (const proc of project.processors) {
    const m = procModel(proc);
    const capPx = portCapacityPixels(project, proc);
    const walls = project.walls.filter(w => w.processorId === proc.id && res.walls.has(w.id));
    const ports = new Map(); // idx -> {pixels, panels, runs:[{wallId, runIdx}]}
    const explicit = new Set();
    for (const w of walls) for (const run of res.walls.get(w.id).dataRuns) if (Number.isInteger(run.port)) explicit.add(run.port);
    let next = 0;
    for (const w of walls) {
      const wa = res.walls.get(w.id);
      wa.dataRuns.forEach((run, i) => {
        let idx = run.port;
        if (!Number.isInteger(idx)) { while (explicit.has(next) || ports.has(next)) next++; idx = next++; }
        run.portIdx = idx;
        run.label = portLabel(proc, idx);
        run.loadPct = 100 * run.pixels / capPx;
        const p = ports.get(idx) || { pixels: 0, panels: 0, runs: [] };
        p.pixels += run.pixels; p.panels += run.panels.length; p.runs.push({ wallId: w.id, runIdx: i });
        ports.set(idx, p);
      });
    }
    const maxIdx = ports.size ? Math.max(...ports.keys()) : -1;
    const distNeeded = m.trunks ? Math.ceil((maxIdx + 1) / m.portsPerDistributor) : 0;
    const distUsed = m.trunks ? (proc.autoDistributors ? distNeeded : proc.distributors) : 0;
    let avail = m.trunks ? m.portsPerDistributor * Math.min(distUsed, m.trunks) : m.directPorts;
    const hardMax = m.trunks ? m.portsPerDistributor * m.trunks : m.directPorts;
    if (proc.backup) avail = Math.floor(avail / 2);
    const pixelsUsed = walls.reduce((s2, w) => s2 + res.walls.get(w.id).pixels, 0);

    const pa = { proc, model: m, capPx, ports, portsUsed: ports.size, maxIdx, portsAvail: avail, hardMax: proc.backup ? Math.floor(hardMax / 2) : hardMax, distNeeded, distUsed, pixelsUsed, walls };
    res.processors.set(proc.id, pa);
    const name = proc.name;

    for (const [idx, p] of ports) {
      if (p.pixels > capPx) add('error', `Port ${portLabel(proc, idx)}: ${p.pixels.toLocaleString()} px exceeds port capacity ${capPx.toLocaleString()} px`, { proc: proc.id });
      if (p.runs.length > 1) add('warn', `Port ${portLabel(proc, idx)}: shared by ${p.runs.length} runs`, { proc: proc.id });
    }
    if (maxIdx + 1 > pa.hardMax) add('error', `${name}: needs ${maxIdx + 1} ports, ${m.name} supports ${pa.hardMax}${m.trunks ? ` (${m.trunks} distros)` : ''}${proc.backup ? ' with backup' : ''}`, { proc: proc.id });
    else if (maxIdx + 1 > avail) add('error', `${name}: needs ${maxIdx + 1} ports but only ${avail} available — add ${m.trunks ? 'a distro (' + distroName(proc, distUsed) + ')' : 'ports'}`, { proc: proc.id });
    if (m.trunks && distUsed > m.trunks) add('error', `${name}: needs ${distUsed} distros, max ${m.trunks}`, { proc: proc.id });
    if (pixelsUsed > m.maxPixels) add('error', `${name}: pixel load ${pixelsUsed.toLocaleString()} exceeds ${m.name} capacity ${m.maxPixels.toLocaleString()}`, { proc: proc.id });
    if (proc.inputW > m.maxInputW || proc.inputH > m.maxInputH) add('error', `${name}: input ${proc.inputW}×${proc.inputH} exceeds ${m.name} max ${m.maxInputW}×${m.maxInputH}`, { proc: proc.id });
    if (proc.inputW * proc.inputH > m.maxPixels && m.vendor === 'Novastar') add('warn', `${name}: input canvas larger than processor load capacity`, { proc: proc.id });

    // canvas fit & overlap
    const rects = walls.map(w => { const wa = res.walls.get(w.id); return { w, x: w.canvas.x, y: w.canvas.y, W: wa.resW, H: wa.resH }; });
    for (const r of rects) {
      if (r.x < 0 || r.y < 0 || r.x + r.W > proc.inputW || r.y + r.H > proc.inputH)
        add('error', `${r.w.name}: canvas ${r.W}×${r.H} @ ${r.x},${r.y} falls outside ${name} input ${proc.inputW}×${proc.inputH}`, { wall: r.w.id, proc: proc.id });
    }
    for (let i = 0; i < rects.length; i++) for (let j = i + 1; j < rects.length; j++) {
      const a = rects[i], b = rects[j];
      if (a.x < b.x + b.W && b.x < a.x + a.W && a.y < b.y + b.H && b.y < a.y + a.H)
        add('warn', `${a.w.name} and ${b.w.name} overlap on ${name}'s input canvas (mirrored content)`, { proc: proc.id });
    }
  }

  // ---- sources / GPU mosaic
  for (const src of project.sources) {
    const used = new Map();
    for (const proc of project.processors.filter(p => p.sourceId === src.id)) {
      const o = src.outputs[proc.sourceOutput];
      if (!o) { add('error', `${proc.name}: ${src.name} has no output ${proc.sourceOutput + 1}`, { proc: proc.id }); continue; }
      if (proc.inputW > o.w || proc.inputH > o.h) add('error', `${proc.name}: input ${proc.inputW}×${proc.inputH} larger than ${src.name} output ${proc.sourceOutput + 1} (${o.w}×${o.h})`, { proc: proc.id });
      if (o.hz && o.hz !== s.frameRate) add('warn', `${src.name} output ${proc.sourceOutput + 1} at ${o.hz} Hz but project frame rate is ${s.frameRate} Hz`, { proc: proc.id });
      used.set(proc.sourceOutput, [...(used.get(proc.sourceOutput) || []), proc]);
    }
    for (const [o, procs] of used) if (procs.length > 1) add('info', `${src.name} output ${o + 1} feeds ${procs.length} processors (needs a splitter/DA, identical canvas)`, {});
    const cells = mosaicLayout(src);
    res.sources.set(src.id, { src, used, cells, canvasW: Math.max(0, ...cells.map(c => c.x + c.w)), canvasH: Math.max(0, ...cells.map(c => c.y + c.h)) });
    if (src.outputs.length > src.mosaic.cols * src.mosaic.rows) add('warn', `${src.name}: mosaic grid ${src.mosaic.cols}×${src.mosaic.rows} smaller than ${src.outputs.length} outputs`, {});
  }
  for (const proc of project.processors) if (!proc.sourceId) add('info', `${proc.name}: no media server output assigned`, { proc: proc.id });

  // ---- power phase balancing across all circuits
  const legs = s.voltage === '120' ? ['L1', 'L2', 'L3'] : ['L1-L2', 'L2-L3', 'L3-L1'];
  const lineAmps = { L1: 0, L2: 0, L3: 0 };
  let ci = 0;
  for (const w of project.walls) {
    const wa = res.walls.get(w.id); if (!wa) continue;
    wa.powerRuns.forEach((run, i) => {
      run.label = `${wallCode(w)}-C${i + 1}`;
      run.globalIdx = ci;
      if (s.distroThreePhase) {
        run.phase = legs[ci % 3];
        for (const L of run.phase.split('-')) lineAmps[L] += run.amps;
      }
      if (run.amps > s.breakerAmps * s.derate + 1e-6) add('error', `${w.name} ${run.label}: ${run.amps.toFixed(1)} A exceeds ${s.breakerAmps} A × ${s.derate * 100}%`, { wall: w.id, kind: 'power' });
      ci++;
    });
  }

  // ---- totals
  let panels = 0, kg = 0, wMax = 0, wAvg = 0, pixels = 0, circuits = 0, dataRuns = 0;
  for (const wa of res.walls.values()) { panels += wa.panelCount; kg += wa.kg; wMax += wa.wMax; wAvg += wa.wAvg; pixels += wa.pixels; circuits += wa.powerRuns.length; dataRuns += wa.dataRuns.length; }
  const basisW = s.powerBasis === 'avg' ? wAvg : wMax;
  const leg3 = wMax / (Math.sqrt(3) * 208);
  res.totals = { panels, kg, wMax, wAvg, pixels, circuits, dataRuns, basisW, lineAmps, ampsMax: ampsAt(wMax), ampsAvg: ampsAt(wAvg), feeder208: feederFor(Math.max(leg3, ...Object.values(lineAmps))), btu: wAvg * 3.412 };
  return res;
}

export function mosaicLayout(src) {
  const cells = [];
  const cols = Math.max(1, src.mosaic.cols);
  const colW = [], rowH = [];
  src.outputs.forEach((o, k) => {
    const c = k % cols, r = Math.floor(k / cols);
    colW[c] = Math.max(colW[c] || 0, o.w); rowH[r] = Math.max(rowH[r] || 0, o.h);
  });
  src.outputs.forEach((o, k) => {
    const c = k % cols, r = Math.floor(k / cols);
    cells.push({ k, x: colW.slice(0, c).reduce((a, b) => a + b, 0), y: rowH.slice(0, r).reduce((a, b) => a + b, 0), w: o.w, h: o.h });
  });
  return cells;
}

export const fmtLen = (m, units) => units === 'metric' ? `${m.toFixed(2)} m` : ftIn(m);
export function ftIn(m) { const inch = m * 39.3701; const ft = Math.floor(inch / 12); const i = inch - ft * 12; return `${ft}' ${i.toFixed(1)}"`; }
export const fmtKg = (kg, units) => units === 'metric' ? `${Math.round(kg).toLocaleString()} kg` : `${Math.round(kg * KG2LB).toLocaleString()} lb`;
export const fmtKgBoth = kg => `${Math.round(kg * KG2LB).toLocaleString()} lb / ${Math.round(kg).toLocaleString()} kg`;

// Short wall code for labels: explicit code, else initials ("Main Wall" → MW), else first 4 letters.
export function wallCode(w) {
  if (w.code) return w.code;
  const words = w.name.trim().split(/\s+/).filter(Boolean);
  return (words.length > 1 ? words.map(x => /^\d+$/.test(x) ? x : x[0]).join('') : (words[0] || 'W').slice(0, 4)).toUpperCase();
}
