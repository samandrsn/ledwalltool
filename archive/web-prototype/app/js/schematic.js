// SVG drawing generation: interactive wall diagrams and printable sheets.
import { runColor } from './model.js';
import { planPolyline, sectionPolyline, radiusForAngle } from './geometry.js';
import { fmtLen, fmtKgBoth, procModel, distroName, KG2LB } from './analysis.js';
import { VOLTAGES } from './catalog.js';

export const esc = s => String(s ?? '').replace(/[&<>"]/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[ch]));

// Diagram of one wall (unrolled elevation). Returns {svg (inner markup), w, h} in local units.
// kind: 'data' | 'power' | 'structure'
export function wallDiagram(wall, wa, kind, opts = {}) {
  const pt = wa.pt;
  const cw = pt.mmW / 10, ch = pt.mmH / 10; // cm
  const W = wall.cols * cw, H = wall.rows * ch;
  const dis = new Set(wall.disabled);
  const runs = kind === 'data' ? wa.dataRuns : kind === 'power' ? wa.powerRuns : [];
  const at = new Map();
  runs.forEach((run, ri) => run.panels.forEach(([c, r], pi) => at.set(c + ',' + r, { ri, pi })));
  const X = c => c * cw, Y = r => (wall.rows - 1 - r) * ch;
  const fs = Math.min(cw, ch) * 0.22;
  const o = [];
  o.push(`<g class="panels">`);
  for (let c = 0; c < wall.cols; c++) for (let r = 0; r < wall.rows; r++) {
    const k = c + ',' + r, x = X(c), y = Y(r);
    if (dis.has(k)) {
      o.push(`<rect data-c="${c}" data-r="${r}" class="pnl off" x="${x}" y="${y}" width="${cw}" height="${ch}" fill="transparent" stroke="#888" stroke-dasharray="4 4" stroke-width="0.6"/>`);
      o.push(`<path d="M${x + cw * .3} ${y + ch * .3}L${x + cw * .7} ${y + ch * .7}M${x + cw * .7} ${y + ch * .3}L${x + cw * .3} ${y + ch * .7}" stroke="#888" stroke-width="0.6"/>`);
      continue;
    }
    const a = at.get(k);
    const sel = opts.selectedRun != null && a && a.ri === opts.selectedRun;
    const fill = kind === 'structure' ? wall.color : a ? runColor(a.ri + (kind === 'power' ? 3 : 0)) : '#444';
    const op = kind === 'structure' ? 0.35 : a ? (sel ? 0.65 : 0.38) : 0.15;
    o.push(`<rect data-c="${c}" data-r="${r}" class="pnl" x="${x}" y="${y}" width="${cw}" height="${ch}" fill="${fill}" fill-opacity="${op}" stroke="${opts.ink || '#111'}" stroke-width="${sel ? 1.6 : 0.6}"/>`);
    if (a) {
      o.push(`<text x="${x + cw - fs * 0.4}" y="${y + fs * 1.15}" font-size="${fs}" text-anchor="end" fill="${opts.ink || '#111'}" opacity=".75">${a.pi + 1}</text>`);
    } else if (kind !== 'structure') {
      o.push(`<text x="${x + cw / 2}" y="${y + ch / 2 + fs / 3}" font-size="${fs * 1.4}" text-anchor="middle" fill="#e33" font-weight="700">!</text>`);
    }
    if (kind === 'structure' || opts.coords) o.push(`<text x="${x + fs * 0.4}" y="${y + ch - fs * 0.5}" font-size="${fs * 0.8}" fill="${opts.ink || '#111'}" opacity=".5">${c + 1}.${r + 1}</text>`);
  }
  o.push(`</g>`);

  // Run paths
  if (kind !== 'structure') {
    runs.forEach((run, ri) => {
      if (!run.panels.length) return;
      const col = runColor(ri + (kind === 'power' ? 3 : 0));
      const pts = run.panels.map(([c, r]) => [X(c) + cw / 2, Y(r) + ch / 2]);
      const d = pts.map((p, i) => (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join('');
      o.push(`<path d="${d}" fill="none" stroke="${opts.ink || '#111'}" stroke-width="${fs * 0.32}" stroke-linejoin="round" opacity=".85"/>`);
      o.push(`<path d="${d}" fill="none" stroke="${col}" stroke-width="${fs * 0.18}" stroke-linejoin="round" marker-end="url(#arrow-${kind})"/>`);
      const [sx, sy] = pts[0];
      const label = run.label || `${kind === 'data' ? 'D' : 'C'}${ri + 1}`;
      const tw = label.length * fs * 0.62 + fs;
      o.push(`<g class="runlabel"><rect x="${sx - tw / 2}" y="${sy - fs * 0.75}" width="${tw}" height="${fs * 1.5}" rx="${fs * 0.3}" fill="${col}" stroke="${opts.ink || '#111'}" stroke-width=".6"/>`);
      o.push(`<text x="${sx}" y="${sy + fs * 0.35}" font-size="${fs}" text-anchor="middle" font-weight="700" fill="#000">${esc(label)}</text></g>`);
      if (kind === 'power' && run.phase) o.push(`<text x="${sx}" y="${sy + fs * 1.8}" font-size="${fs * 0.8}" text-anchor="middle" fill="${opts.ink || '#111'}">${run.phase}</text>`);
    });
  }

  // Hinge angles (curves / corners)
  const ink = opts.ink || '#111';
  const afs = fs * 0.85;
  wall.colAngles.forEach((a, i) => {
    if (!a && kind !== 'structure') return;
    const x = X(i + 1);
    o.push(`<g class="hinge" data-hinge="col" data-i="${i}"><rect x="${x - cw * 0.18}" y="${H + 2}" width="${cw * 0.36}" height="${afs * 1.6}" rx="3" fill="${a ? (a > 0 ? '#2b8a3e' : '#c2410c') : 'transparent'}" stroke="${ink}" stroke-width=".4" stroke-opacity=".4"/>`);
    o.push(`<text x="${x}" y="${H + 2 + afs * 1.15}" font-size="${afs}" text-anchor="middle" fill="${a ? '#fff' : ink}">${a ? (a > 0 ? '+' : '') + a + '°' : '0'}</text></g>`);
  });
  wall.rowAngles.forEach((a, i) => {
    if (!a && kind !== 'structure') return;
    const y = Y(i + 1) + ch;
    o.push(`<g class="hinge" data-hinge="row" data-i="${i}"><rect x="${-cw * 0.42}" y="${y - afs * 0.8}" width="${cw * 0.38}" height="${afs * 1.6}" rx="3" fill="${a ? (a > 0 ? '#2b8a3e' : '#c2410c') : 'transparent'}" stroke="${ink}" stroke-width=".4" stroke-opacity=".4"/>`);
    o.push(`<text x="${-cw * 0.23}" y="${y + afs * 0.35}" font-size="${afs}" text-anchor="middle" fill="${a ? '#fff' : ink}">${a ? (a > 0 ? '+' : '') + a + '°' : '0'}</text></g>`);
  });
  // Column / row numbers
  for (let c = 0; c < wall.cols; c++) o.push(`<text x="${X(c) + cw / 2}" y="${-fs * 0.5}" font-size="${fs * 0.9}" text-anchor="middle" fill="${ink}" opacity=".6">${c + 1}</text>`);
  for (let r = 0; r < wall.rows; r++) o.push(`<text x="${W + fs * 0.4}" y="${Y(r) + ch / 2 + fs * 0.3}" font-size="${fs * 0.9}" fill="${ink}" opacity=".6">R${r + 1}</text>`);

  return { svg: o.join(''), w: W, h: H, cw, ch, fs };
}

export function arrowDefs(scale = 1) {
  const m = (id) => `<marker id="arrow-${id}" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="${4 * scale}" markerHeight="${4 * scale}" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#111"/></marker>`;
  return `<defs>${m('data')}${m('power')}</defs>`;
}

// Plan view (top-down) polyline of a curved wall + angle annotations.
function planView(wall, pt, x, y, w, h, ink) {
  const pl = planPolyline(wall, pt);
  const xs = pl.map(p => p[0]), zs = pl.map(p => p[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minZ = Math.min(...zs), maxZ = Math.max(...zs);
  const s = Math.min(w / Math.max(0.1, maxX - minX), h / Math.max(0.1, maxZ - minZ), 200);
  const ox = x + (w - (maxX - minX) * s) / 2, oy = y + h / 2 + ((maxZ + minZ) / 2) * s;
  const P = ([px, pz]) => [ox + (px - minX) * s, oy - pz * s];
  const d = pl.map((p, i) => (i ? 'L' : 'M') + P(p).map(v => v.toFixed(1)).join(' ')).join('');
  let o = `<path d="${d}" stroke="${wall.color}" stroke-width="4" fill="none" stroke-linejoin="round"/>`;
  pl.forEach((p, i) => { const [a, b] = P(p); o += `<circle cx="${a}" cy="${b}" r="2.5" fill="${ink}"/>`; });
  const uniform = wall.colAngles.every(a => a === wall.colAngles[0]);
  if (!uniform) wall.colAngles.forEach((a, i) => { if (!a) return; const [px, py] = P(pl[i + 1]); o += `<text x="${px}" y="${py - 7}" font-size="10" text-anchor="middle" fill="${ink}">${a > 0 ? '+' : ''}${a}°</text>`; });
  const total = wall.colAngles.reduce((s2, a) => s2 + a, 0);
  const summary = uniform ? `all ${wall.colAngles.length} hinges ${wall.colAngles[0] > 0 ? '+' : ''}${wall.colAngles[0]}° · R ${radiusForAngle(pt.mmW / 1000, wall.colAngles[0]).toFixed(2)} m · ` : '';
  o += `<text x="${x}" y="${y + h + 14}" font-size="10" fill="${ink}" opacity=".7">PLAN VIEW (audience ↓) — ${summary}total ${total > 0 ? '+' : ''}${total.toFixed(1)}° · + concave / − convex</text>`;
  return o;
}

function sectionView(wall, pt, x, y, w, h, ink) {
  const pl = sectionPolyline(wall, pt);
  const zs = pl.map(p => p[0]), ys = pl.map(p => p[1]);
  const minZ = Math.min(...zs), maxZ = Math.max(...zs), maxY = Math.max(...ys);
  const s = Math.min(h / Math.max(0.1, maxY), w / Math.max(0.5, maxZ - minZ + 1));
  const P = ([pz, py]) => [x + w / 2 + (pz - (minZ + maxZ) / 2) * s, y + h - py * s];
  const d = pl.map((p, i) => (i ? 'L' : 'M') + P(p).map(v => v.toFixed(1)).join(' ')).join('');
  let o = `<path d="${d}" stroke="${wall.color}" stroke-width="4" fill="none"/>`;
  wall.rowAngles.forEach((a, i) => { if (!a) return; const [px, py] = P(pl[i + 1]); o += `<text x="${px + 8}" y="${py + 3}" font-size="10" fill="${ink}">${a > 0 ? '+' : ''}${a}°</text>`; });
  o += `<text x="${x}" y="${y + h + 14}" font-size="10" fill="${ink}" opacity=".7">SECTION (audience →)</text>`;
  return o;
}

const SHEET_W = 1632, SHEET_H = 1056; // 17×11 in @ 96 dpi

function titleBlock(project, title, sub, rows, sheetNo) {
  const x = SHEET_W - 400, y = SHEET_H - 200;
  let o = `<g font-family="Helvetica, Arial, sans-serif"><rect x="${x}" y="${y}" width="380" height="180" fill="#fff" stroke="#111" stroke-width="1.5"/>`;
  o += `<text x="${x + 12}" y="${y + 26}" font-size="18" font-weight="700">${esc(project.name)}</text>`;
  o += `<text x="${x + 12}" y="${y + 46}" font-size="12">${esc([project.client, project.venue].filter(Boolean).join(' · '))}</text>`;
  o += `<line x1="${x}" x2="${x + 380}" y1="${y + 56}" y2="${y + 56}" stroke="#111"/>`;
  o += `<text x="${x + 12}" y="${y + 78}" font-size="16" font-weight="700">${esc(title)}</text>`;
  o += `<text x="${x + 12}" y="${y + 96}" font-size="11">${esc(sub)}</text>`;
  rows.slice(0, 4).forEach((r, i) => { o += `<text x="${x + 12}" y="${y + 116 + i * 14}" font-size="10.5">${esc(r)}</text>`; });
  o += `<text x="${x + 368}" y="${y + 172}" font-size="10" text-anchor="end">${esc(project.designer || '')}  ${new Date().toLocaleDateString()}  ·  ${sheetNo}</text></g>`;
  return o;
}

export function wallSheet(project, A, wall, kind, sheetNo = '') {
  const wa = A.walls.get(wall.id);
  if (!wa) return '';
  const pt = wa.pt, s = project.settings, units = project.units;
  const diag = wallDiagram(wall, wa, kind, { ink: '#111' });
  const areaX = 50, areaY = 70, areaW = SHEET_W - 520, areaH = SHEET_H - 290;
  const pad = diag.cw * 0.6;
  const scale = Math.min(areaW / (diag.w + pad * 2), areaH / (diag.h + pad * 2));
  const tx = areaX + (areaW - diag.w * scale) / 2, ty = areaY + (areaH - diag.h * scale) / 2;

  let o = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SHEET_W} ${SHEET_H}" width="${SHEET_W}" height="${SHEET_H}" font-family="Helvetica, Arial, sans-serif">`;
  o += arrowDefs();
  o += `<rect width="${SHEET_W}" height="${SHEET_H}" fill="#fff"/><rect x="20" y="20" width="${SHEET_W - 40}" height="${SHEET_H - 40}" fill="none" stroke="#111" stroke-width="2"/>`;
  o += `<text x="40" y="52" font-size="22" font-weight="700">${esc(wall.name)} — ${kind === 'data' ? 'DATA MAP' : 'POWER MAP'}</text>`;
  o += `<text x="${SHEET_W - 40}" y="52" font-size="12" text-anchor="end">VIEWED FROM FRONT (AUDIENCE SIDE)</text>`;
  o += `<g transform="translate(${tx} ${ty}) scale(${scale})">${diag.svg}</g>`;

  // Legend / run table
  const lx = SHEET_W - 400, ly = 70;
  const runs = kind === 'data' ? wa.dataRuns : wa.powerRuns;
  o += `<text x="${lx}" y="${ly}" font-size="13" font-weight="700">${kind === 'data' ? 'DATA RUNS' : 'POWER CIRCUITS'}</text>`;
  const maxRows = 34;
  const colsN = runs.length > maxRows ? 2 : 1;
  runs.forEach((run, i) => {
    const col = Math.floor(i / maxRows), row = i % maxRows;
    if (col > 1) return;
    const x = lx + col * 190, y = ly + 14 + row * 15;
    const c = runColor(i + (kind === 'power' ? 3 : 0));
    o += `<rect x="${x}" y="${y}" width="10" height="10" fill="${c}" stroke="#111" stroke-width=".5"/>`;
    const txt = kind === 'data'
      ? `${run.label}  ${run.panels.length} pnl  ${Math.round(run.loadPct)}%`
      : `${run.label}  ${run.panels.length} pnl  ${run.amps.toFixed(1)}A${run.phase ? ' ' + run.phase : ''}`;
    o += `<text x="${x + 15}" y="${y + 9}" font-size="${colsN > 1 ? 9.5 : 11}">${esc(txt)}</text>`;
  });
  if (runs.length > maxRows * 2) o += `<text x="${lx}" y="${ly + 14 + maxRows * 15 + 10}" font-size="10">+${runs.length - maxRows * 2} more…</text>`;

  // Plan / section strips if curved
  const curved = wall.colAngles.some(a => a), tilted = wall.rowAngles.some(a => a);
  if (curved) o += planView(wall, pt, 50, SHEET_H - 215, 620, 150, '#111');
  if (tilted) o += sectionView(wall, pt, curved ? 720 : 50, SHEET_H - 215, 180, 150, '#111');

  const v = VOLTAGES.find(x => x.key === s.voltage);
  const info = [
    `${pt.mfr} ${pt.name} · ${wall.cols}×${wall.rows} (${wa.panelCount} panels) · ${wa.resW}×${wa.resH}px`,
    `${fmtLen(wa.widthM, units)} W × ${fmtLen(wa.heightM, units)} H · ${fmtKgBoth(wa.kg)}`,
    kind === 'data'
      ? `${wa.proc ? wa.proc.name + ' (' + procModel(wa.proc).name + ')' : 'No processor'} · max ${wa.dataCap} pnl/port @ ${s.frameRate}Hz ${s.bitDepth}-bit`
      : `${v.label} · ${s.breakerAmps}A @ ${Math.round(s.derate * 100)}% · max ${wa.powerCap} pnl/circuit`,
    kind === 'data' ? `Canvas @ ${wall.canvas.x},${wall.canvas.y}` : `Max ${(wa.wMax / 1000).toFixed(1)} kW · avg ${(wa.wAvg / 1000).toFixed(1)} kW · ${(wa.wMax / v.v).toFixed(1)} A @ ${v.v}V`,
  ];
  o += titleBlock(project, `${wall.name} ${kind === 'data' ? 'Data' : 'Power'}`, `${runs.length} ${kind === 'data' ? 'ports' : 'circuits'}`, info, sheetNo);
  o += `</svg>`;
  return o;
}

// System signal-flow overview: media servers → processors → walls.
export function systemSheet(project, A, sheetNo = '') {
  let o = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SHEET_W} ${SHEET_H}" width="${SHEET_W}" height="${SHEET_H}" font-family="Helvetica, Arial, sans-serif">`;
  o += `<rect width="${SHEET_W}" height="${SHEET_H}" fill="#fff"/><rect x="20" y="20" width="${SHEET_W - 40}" height="${SHEET_H - 40}" fill="none" stroke="#111" stroke-width="2"/>`;
  o += `<text x="40" y="52" font-size="22" font-weight="700">SYSTEM OVERVIEW — SIGNAL FLOW</text>`;
  const colX = [60, 470, 900], top = 90, bottom = SHEET_H - 230;
  const pos = new Map();
  const box = (x, y, w, h, title, lines, color = '#111') => {
    let s = `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#fff" stroke="${color}" stroke-width="2" rx="6"/>`;
    s += `<text x="${x + 10}" y="${y + 20}" font-size="14" font-weight="700">${esc(title)}</text>`;
    lines.forEach((l, i) => s += `<text x="${x + 10}" y="${y + 38 + i * 14}" font-size="11">${esc(l)}</text>`);
    return s;
  };
  // sources
  const srcs = project.sources;
  let y = top;
  for (const src of srcs) {
    const h = 40 + src.outputs.length * 22;
    o += box(colX[0], y, 300, h, src.name, [src.gpu]);
    src.outputs.forEach((out, k) => {
      const oy = y + 46 + k * 22;
      o += `<text x="${colX[0] + 20}" y="${oy + 4}" font-size="11">OUT ${k + 1}: ${out.w}×${out.h}@${out.hz}</text>`;
      pos.set(src.id + ':' + k, [colX[0] + 300, oy]);
    });
    y += h + 20;
  }
  // processors
  y = top;
  for (const proc of project.processors) {
    const pa = A.processors.get(proc.id); const m = procModel(proc);
    const lines = [`${m.vendor} ${m.name}`, `Input ${proc.inputW}×${proc.inputH}`, `Ports ${pa.portsUsed}/${pa.portsAvail}${m.trunks ? ` · distros ${Array.from({ length: pa.distUsed }, (_, d) => distroName(proc, d)).join(', ') || 'none'}` : ''}`, `Load ${(pa.pixelsUsed / 1e6).toFixed(2)} / ${(m.maxPixels / 1e6).toFixed(2)} MP`];
    o += box(colX[1], y, 330, 104, proc.name, lines, '#1c64f2');
    const from = pos.get(proc.sourceId + ':' + proc.sourceOutput);
    if (from) o += `<path d="M${from[0]} ${from[1]}C${from[0] + 80} ${from[1]} ${colX[1] - 80} ${y + 30} ${colX[1]} ${y + 30}" stroke="#1c64f2" stroke-width="2" fill="none"/>`;
    pos.set(proc.id, [colX[1] + 330, y + 52]);
    y += 124;
  }
  // walls
  y = top;
  for (const wall of project.walls) {
    const wa = A.walls.get(wall.id); if (!wa) continue;
    const runs = wa.dataRuns;
    const labels = runs.map(r => r.label).filter(Boolean);
    const portStr = labels.length ? `${labels[0]} … ${labels[labels.length - 1]}` : '—';
    o += box(colX[2], y, 340, 74, wall.name, [`${wall.cols}×${wall.rows} ${wa.pt.name}`, `${wa.resW}×${wa.resH}px @ ${wall.canvas.x},${wall.canvas.y} · ${runs.length} ports (${portStr})`, `${wa.powerRuns.length} circuits · ${fmtKgBoth(wa.kg)}`], wall.color);
    const from = pos.get(wall.processorId);
    if (from) o += `<path d="M${from[0]} ${from[1]}C${from[0] + 80} ${from[1]} ${colX[2] - 80} ${y + 37} ${colX[2]} ${y + 37}" stroke="${wall.color}" stroke-width="${1 + Math.min(6, runs.length / 4)}" fill="none"/>`;
    y += 90;
    if (y > bottom) break;
  }
  const T = A.totals;
  o += titleBlock(project, 'System Overview', `${project.walls.length} walls · ${project.processors.length} processors · ${T.panels} panels`, [
    `${(T.pixels / 1e6).toFixed(2)} MP · ${T.dataRuns} data runs · ${T.circuits} circuits`,
    `Weight ${fmtKgBoth(T.kg)}`,
    `Power max ${(T.wMax / 1000).toFixed(1)} kW · avg ${(T.wAvg / 1000).toFixed(1)} kW`,
    `208V 3Φ ${(T.wMax / (Math.sqrt(3) * 208)).toFixed(0)} A/leg (max)`,
  ], sheetNo);
  o += `</svg>`;
  return o;
}

// Pixel map at native resolution (canvas element) for one processor.
export function drawPixelMap(canvas, project, A, proc, opts = {}) {
  const ctx = canvas.getContext('2d');
  canvas.width = proc.inputW; canvas.height = proc.inputH;
  ctx.fillStyle = '#000'; ctx.fillRect(0, 0, proc.inputW, proc.inputH);
  for (const wall of project.walls.filter(w => w.processorId === proc.id)) {
    const wa = A.walls.get(wall.id); if (!wa) continue;
    const { pxW, pxH } = wa.pt;
    const dis = new Set(wall.disabled);
    for (let c = 0; c < wall.cols; c++) for (let r = 0; r < wall.rows; r++) {
      if (dis.has(c + ',' + r)) continue;
      const x = wall.canvas.x + c * pxW, y = wall.canvas.y + (wall.rows - 1 - r) * pxH;
      ctx.fillStyle = wall.color; ctx.globalAlpha = ((c + r) % 2) ? 0.55 : 0.8;
      ctx.fillRect(x, y, pxW, pxH);
      ctx.globalAlpha = 1; ctx.strokeStyle = '#fff'; ctx.lineWidth = 1; ctx.strokeRect(x + .5, y + .5, pxW - 1, pxH - 1);
      if (opts.labels !== false && pxW >= 48) {
        ctx.fillStyle = '#fff'; ctx.font = `${Math.max(9, Math.floor(pxH / 7))}px Helvetica`;
        ctx.fillText(`${c + 1}.${r + 1}`, x + 4, y + Math.max(11, pxH / 6));
      }
    }
    ctx.fillStyle = '#fff'; ctx.font = `bold ${Math.max(14, Math.min(64, wa.resH / 8))}px Helvetica`;
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.lineWidth = 4; ctx.strokeStyle = '#000';
    const tx = wall.canvas.x + wa.resW / 2, ty = wall.canvas.y + wa.resH / 2;
    ctx.strokeText(`${wall.name}  ${wa.resW}×${wa.resH}`, tx, ty); ctx.fillText(`${wall.name}  ${wa.resW}×${wa.resH}`, tx, ty);
    ctx.textAlign = 'start'; ctx.textBaseline = 'alphabetic';
  }
}

export { KG2LB };
