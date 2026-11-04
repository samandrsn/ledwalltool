import { store, byId, newWall, newProcessor, newSource, newPanelType, newProject, resizeAngles, runColor, uid, migrate } from './model.js';
import { PANEL_LIBRARY, PROCESSOR_MODELS, RES_PRESETS, ANGLE_PRESETS, VOLTAGES, GPU_PRESETS } from './catalog.js';
import { analyze, procModel, portLabel, distroName, portCapacityPixels, fmtLen, fmtKgBoth, KG2LB, M2FT, circuitCapacity, wallCode } from './analysis.js';
import { PRESETS, CHUNKS, describeRecommendation } from './routing.js';
import { wallDiagram, arrowDefs, wallSheet, systemSheet, drawPixelMap, esc } from './schematic.js';
import { angleForRadius, radiusForAngle, panelDims } from './geometry.js';
import * as io from './io.js';
import * as roomStore from './roomstore.js';
import { icon } from './icons.js';

let view3d = null; // lazy-loaded three.js module
let A = null;
const ui = {
  tab: 'map2d', sel: { type: 'project' }, wall2d: null, mode2d: 'data', selRun: 0,
  color3d: 'wall', paths3d: true, pxProc: null, pxZoom: 'fit', pxSnap: true, vb: {},
};
const $ = s => document.querySelector(s);
const app = (node, ...k) => node.append(...k.flat(3).filter(x => x != null && x !== false));

// ---------- DOM helpers ----------
function h(tag, props, ...kids) {
  const el = document.createElement(tag);
  let val;
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k === 'style') el.style.cssText = v;
    else if (k === 'html') el.innerHTML = v;
    else if (k === 'value') val = v;
    else if (k in el && typeof v !== 'string') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat(3)) if (c != null && c !== false) app(el, c.nodeType ? c : String(c));
  if (val !== undefined) el.value = val;
  return el;
}
const field = (label, ...ctl) => h('div', { class: 'f' }, h('label', {}, label), ctl.length > 1 ? h('div', { class: 'row' }, ...ctl) : ctl[0]);
function num(k, value, onset, { step = 'any', min, max, width } = {}) {
  return h('input', { type: 'number', 'data-k': k, value: value ?? 0, step, min, max, style: width ? `width:${width}px` : null,
    onchange: e => { const v = parseFloat(e.target.value); if (!isNaN(v)) onset(v); } });
}
function txt(k, value, onset, ph) { return h('input', { type: 'text', 'data-k': k, value: value ?? '', placeholder: ph, onchange: e => onset(e.target.value) }); }
function sel(k, options, value, onset) {
  const s = h('select', { 'data-k': k, onchange: e => onset(e.target.value) },
    options.map(o => Array.isArray(o) ? h('option', { value: o[0] }, o[1]) : o.group
      ? h('optgroup', { label: o.group }, o.items.map(i => h('option', { value: i[0] }, i[1]))) : h('option', { value: o }, o)));
  s.value = value ?? '';
  return s;
}
function chk(k, value, onset, label) {
  return h('label', { style: 'display:flex;gap:5px;align-items:center;color:var(--text)' }, h('input', { type: 'checkbox', 'data-k': k, checked: !!value, onchange: e => onset(e.target.checked) }), label || '');
}
function toast(msg, err) {
  const t = $('#toast'); t.textContent = msg; t.className = err ? 'err' : ''; t.hidden = false;
  clearTimeout(toast._t); toast._t = setTimeout(() => t.hidden = true, err ? 6000 : 2500);
}
const P = () => store.project;
const edit = (fn, reason) => store.commit(fn, reason);
const editWall = (id, fn) => edit(p => { const w = byId(p.walls, id); if (w) fn(w, p); });
const editProc = (id, fn) => edit(p => { const x = byId(p.processors, id); if (x) fn(x, p); });
const editSrc = (id, fn) => edit(p => { const x = byId(p.sources, id); if (x) fn(x, p); });
const editPT = (id, fn) => edit(p => { const x = byId(p.panelTypes, id); if (x) fn(x, p); });
const mm = (m) => P().units === 'metric' ? `${m.toFixed(2)} m` : `${(m * M2FT).toFixed(2)} ft`;

// ---------- render orchestration ----------
function renderAll() {
  A = analyze(P());
  const p = P();
  if (ui.sel.type !== 'project' && !byId(p[{ wall: 'walls', proc: 'processors', src: 'sources', pt: 'panelTypes' }[ui.sel.type]] || [], ui.sel.id)) ui.sel = { type: 'project' };
  if (!byId(p.walls, ui.wall2d)) ui.wall2d = p.walls[0]?.id || null;
  $('#projName').value = p.name;
  window.webkit?.messageHandlers?.native?.postMessage({ cmd: 'title', text: p.name });
  renderSettings(); renderSidebar(); renderInspector(); renderStatus(); renderTab();
}

function renderTab() {
  document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === ui.tab));
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('on', t.id === 'tab-' + ui.tab));
  if (ui.tab === 'map2d') render2D();
  else if (ui.tab === 'view3d') render3D();
  else if (ui.tab === 'pixmap') renderPixMap();
  else if (ui.tab === 'resources') renderResources();
}

// Toolbar chip summarising the signal/power settings; the controls live in the Project inspector.
function renderSettings() {
  const s = P().settings, v = VOLTAGES.find(x => x.key === s.voltage);
  const chip = $('#settingsChip');
  chip.replaceChildren(icon('settings'), `${s.frameRate} Hz · ${s.bitDepth}-bit · ${v.v} V ${s.breakerAmps} A`);
  chip.onclick = () => { ui.sel = { type: 'project' }; renderAll(); };
}

function settingsFields() {
  const p = P(), s = p.settings;
  const set = (k, v) => edit(pp => { pp.settings[k] = v; });
  const fr = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 72, 90, 100, 119.88, 120, 144, 240];
  return [
    field('Frame rate', sel('s.fr', fr.map(f => [f, f + ' Hz']), s.frameRate, v => set('frameRate', +v))),
    field('Bit depth', sel('s.bd', [[8, '8-bit'], [10, '10-bit'], [12, '12-bit']], s.bitDepth, v => set('bitDepth', +v))),
    field('Circuits', sel('s.v', VOLTAGES.map(v => [v.key, v.label]), s.voltage, v => set('voltage', v))),
    field('Breaker', sel('s.br', [[15, '15 A'], [16, '16 A'], [20, '20 A'], [30, '30 A'], [32, '32 A']], s.breakerAmps, v => set('breakerAmps', +v)),
      sel('s.dr', [[0.8, '80% load'], [1, '100% load']], s.derate, v => set('derate', +v))),
    field('Distro', chk('s.3p', s.distroThreePhase, v => set('distroThreePhase', v), 'Three-phase, balance legs')),
    field('Units', sel('s.units', [['imperial', 'Feet / pounds'], ['metric', 'Meters / kilograms']], p.units, v => edit(pp => { pp.units = v; }))),
  ];
}

// ---------- sidebar ----------
function issueLevel(pred) {
  const its = A.issues.filter(pred);
  return its.some(i => i.level === 'error') ? 'error' : its.some(i => i.level === 'warn') ? 'warn' : 'ok';
}
function renderSidebar() {
  const p = P(), sb = $('#sidebar'); sb.innerHTML = '';
  const item = (type, id, ic, tint, name, meta, dot) => {
    const i = icon(ic); if (tint) i.style.color = tint;
    return h('div', {
      class: 'sb-item' + (ui.sel.type === type && ui.sel.id === id ? ' sel' : ''),
      onclick: () => { ui.sel = { type, id }; if (type === 'wall') ui.wall2d = id; if (type === 'proc') ui.pxProc = id; renderAll(); },
    }, i, h('span', { class: 'nm' }, name), meta ? h('span', { class: 'meta' }, meta) : null, dot ? h('span', { class: 'dot ' + dot }) : null);
  };
  const sec = (title, what, onAdd, items) => h('div', { class: 'sb-sec' },
    h('div', { class: 'sb-head' }, title, h('button', { onclick: onAdd, title: `Add ${what}`, 'aria-label': `Add ${what}` }, icon('plus'))), items);

  app(sb,
    h('div', { class: 'sb-sec' }, item('project', undefined, 'project', null, 'Project', null, A.issues.some(i => i.level === 'error') ? 'error' : null)),
    sec('Walls', 'wall', addWall, p.walls.map(w => {
      const wa = A.walls.get(w.id);
      return item('wall', w.id, 'wall', w.color, w.name, wa ? `${w.cols}×${w.rows}` : '', issueLevel(i => i.ref?.wall === w.id));
    })),
    sec('Processors', 'processor', addProcessor, p.processors.map(pr => {
      const pa = A.processors.get(pr.id);
      return item('proc', pr.id, 'processor', null, pr.name, pa ? `${pa.maxIdx + 1}/${pa.portsAvail}` : '', issueLevel(i => i.ref?.proc === pr.id));
    })),
    sec('Media Servers', 'media server', addSource, p.sources.map(s => item('src', s.id, 'server', null, s.name, `${s.outputs.length} out`))),
    sec('Panel Types', 'panel type', addPanelType, p.panelTypes.map(t => item('pt', t.id, 'panel', null, `${t.mfr} ${t.name}`, `${t.pxW}×${t.pxH}`))),
  );
}

function addWall() {
  let id;
  edit(p => {
    const w = newWall(p, { panelTypeId: p.panelTypes[0]?.id });
    w.processorId = p.processors[0]?.id || null;
    const last = p.walls[p.walls.length - 1];
    if (last) { const pt = byId(p.panelTypes, last.panelTypeId); w.pos.x = last.pos.x + last.cols * (pt?.mmW || 500) / 1000 + 1; }
    autoPlaceCanvas(p, w);
    p.walls.push(w); id = w.id;
  });
  ui.sel = { type: 'wall', id }; ui.wall2d = id; renderAll();
}
function addProcessor() {
  let id;
  edit(p => { const pr = newProcessor(p); pr.sourceId = p.sources[0]?.id || null; pr.sourceOutput = Math.min(p.processors.length, 3); p.processors.push(pr); id = pr.id; });
  ui.sel = { type: 'proc', id }; renderAll();
}
function addSource() {
  let id; edit(p => { const s = newSource(p); p.sources.push(s); id = s.id; });
  ui.sel = { type: 'src', id }; renderAll();
}
function addPanelType() {
  let id; edit(p => { const t = newPanelType(PANEL_LIBRARY[0]); p.panelTypes.push(t); id = t.id; });
  ui.sel = { type: 'pt', id }; renderAll();
}

// Place a new wall's canvas on its processor below/right of the others.
function autoPlaceCanvas(p, w) {
  const pr = byId(p.processors, w.processorId); if (!pr) return;
  const others = p.walls.filter(o => o.processorId === pr.id && o.id !== w.id);
  let y = 0;
  for (const o of others) { const pt = byId(p.panelTypes, o.panelTypeId); if (pt) y = Math.max(y, o.canvas.y + o.rows * pt.pxH); }
  w.canvas = { x: 0, y };
}
function autoPack(p, procId) {
  const pr = byId(p.processors, procId); if (!pr) return;
  // Skyline packing, largest walls first: each wall goes to the lowest (then leftmost) spot it fits.
  const placed = [];
  const items = p.walls.filter(o => o.processorId === procId).map(w => { const pt = byId(p.panelTypes, w.panelTypeId); return pt ? { w, W: w.cols * pt.pxW, H: w.rows * pt.pxH } : null; }).filter(Boolean)
    .sort((a, b) => b.W * b.H - a.W * a.H);
  for (const it of items) {
    let best = null;
    for (const x of [0, ...placed.map(r => r.x + r.W)]) {
      const y = Math.max(0, ...placed.filter(r => r.x < x + it.W && x < r.x + r.W).map(r => r.y + r.H));
      const fits = x + it.W <= pr.inputW && y + it.H <= pr.inputH;
      const score = (fits ? 0 : 1e9) + y * 1e5 + x;
      if (!best || score < best.score) best = { x, y, score };
    }
    it.w.canvas = { x: best.x, y: best.y };
    placed.push({ x: best.x, y: best.y, W: it.W, H: it.H });
  }
}

// ---------- inspector ----------
function renderInspector() {
  const el = $('#inspector');
  const fk = document.activeElement?.dataset?.k;
  el.innerHTML = '';
  const t = ui.sel.type;
  if (t === 'wall') inspectWall(el, byId(P().walls, ui.sel.id));
  else if (t === 'proc') inspectProc(el, byId(P().processors, ui.sel.id));
  else if (t === 'src') inspectSrc(el, byId(P().sources, ui.sel.id));
  else if (t === 'pt') inspectPT(el, byId(P().panelTypes, ui.sel.id));
  else inspectProject(el);
  if (fk) el.querySelector(`[data-k="${CSS.escape(fk)}"]`)?.focus();
}

function kv(pairs) { return h('div', { class: 'kv' }, pairs.flatMap(([k, v]) => [h('span', {}, k), h('span', {}, v)])); }

function inspectProject(el) {
  const p = P(), T = A.totals, s = p.settings, units = p.units;
  const v = VOLTAGES.find(x => x.key === s.voltage);
  app(el, 
    h('h3', {}, 'Project'),
    field('Name', txt('p.name', p.name, v => edit(pp => { pp.name = v; }))),
    field('Client', txt('p.client', p.client, v => edit(pp => { pp.client = v; }))),
    field('Venue', txt('p.venue', p.venue, v => edit(pp => { pp.venue = v; }))),
    field('Drawn by', txt('p.designer', p.designer, v => edit(pp => { pp.designer = v; }))),
    h('h4', {}, 'Signal & Power'),
    settingsFields(),
    field('Power basis', sel('p.pb', [['max', 'Max (circuit sizing)'], ['avg', 'Typical / average']], s.powerBasis, v => edit(pp => { pp.settings.powerBasis = v; }))),
    h('h4', {}, 'Totals'),
    kv([
      ['Panels', T.panels.toLocaleString()],
      ['Pixels', `${(T.pixels / 1e6).toFixed(2)} MP`],
      ['Weight', fmtKgBoth(T.kg)],
      ['Power max', `${(T.wMax / 1000).toFixed(2)} kW`],
      ['Power typical', `${(T.wAvg / 1000).toFixed(2)} kW`],
      ['Heat (typ.)', `${Math.round(T.btu).toLocaleString()} BTU/h`],
      ['Data runs', T.dataRuns],
      [`Circuits (${v.label}, ${s.breakerAmps}A)`, T.circuits],
    ]),
    h('h4', {}, 'Amps — max / typical'),
    kv(Object.keys(T.ampsMax).map(k => [k, `${T.ampsMax[k].toFixed(1)} / ${T.ampsAvg[k].toFixed(1)} A`])),
    s.distroThreePhase ? h('div', {}, h('h4', {}, 'Phase balance (max)'), kv(Object.entries(T.lineAmps).map(([k, a]) => [k, `${a.toFixed(1)} A`])),
      h('div', { class: 'note' }, `Suggested 208Y/120 3Φ feeder: ${T.feeder208 ? T.feeder208 + ' A' : '> 1200 A — split services'} (80% continuous)`)) : null,
    h('div', { class: 'note' }, 'Spec values in the catalog are typical figures — verify panel & processor specs against current manufacturer data before deployment.'),
  );
}

function inspectWall(el, w) {
  if (!w) return;
  const p = P(), wa = A.walls.get(w.id), pt = wa?.pt;
  const up = fn => editWall(w.id, fn);
  const isAttached = !!w.attach?.wallId;
  const angStr = arr => arr.join(', ');
  const parseAngles = (s, n) => { const a = s.split(/[,\s]+/).filter(Boolean).map(Number).map(x => isNaN(x) ? 0 : x); while (a.length < n) a.push(a.length ? a[a.length - 1] : 0); return a.slice(0, n); };
  const dims = pt ? panelDims(pt) : { w: 0.5 };
  const uni = w.colAngles.length && w.colAngles.every(a => a === w.colAngles[0]) ? w.colAngles[0] : null;

  app(el, 
    h('h3', {}, h('input', { type: 'color', value: w.color, onchange: e => up(x => x.color = e.target.value) }), w.name),
    field('Name', txt('w.name', w.name, v => up(x => x.name = v))),
    field('Code', txt('w.code', w.code || '', v => up(x => x.code = v.trim().toUpperCase().slice(0, 6)), wallCode(w)), h('span', { class: 'note' }, 'used in circuit labels')),
    field('Panel', sel('w.pt', p.panelTypes.map(t => [t.id, `${t.mfr} ${t.name}`]), w.panelTypeId, v => up(x => x.panelTypeId = v))),
    field('Size (C×R)', num('w.cols', w.cols, v => up(x => { x.cols = Math.max(1, Math.round(v)); resizeAngles(x); }), { min: 1, step: 1, width: 56 }), '×',
      num('w.rows', w.rows, v => up(x => { x.rows = Math.max(1, Math.round(v)); resizeAngles(x); }), { min: 1, step: 1, width: 56 })),
    wa ? kv([
      ['Dimensions', `${fmtLen(wa.widthM, p.units)} × ${fmtLen(wa.heightM, p.units)}`],
      ['Resolution', `${wa.resW} × ${wa.resH}`],
      ['Panels', `${wa.panelCount}${w.disabled.length ? ` (${w.disabled.length} removed)` : ''}`],
      ['Weight', fmtKgBoth(wa.kg)],
      ['Power max / typ', `${(wa.wMax / 1000).toFixed(2)} / ${(wa.wAvg / 1000).toFixed(2)} kW`],
      ['Data', `${wa.dataRuns.length} ports · ≤${wa.dataCap}/port`],
      ['Power', `${wa.powerRuns.length} circuits · ≤${wa.powerCap}/circuit`],
    ]) : null,
    field('Rigging', sel('w.rig', [['ground', 'Ground stacked (data/power from bottom)'], ['flown', 'Flown (from top)']], w.rigging, v => up(x => x.rigging = v))),
    field('Extra kg/panel', num('w.xkg', w.extraKgPerPanel, v => up(x => x.extraKgPerPanel = v), { min: 0, step: 0.1 }), h('span', { class: 'note' }, 'frames, bumpers, blocks')),

    h('h4', {}, 'Data'),
    field('Processor', sel('w.proc', [['', '— none —'], ...p.processors.map(x => [x.id, x.name])], w.processorId || '', v => up((x, pp) => { x.processorId = v || null; autoPlaceCanvas(pp, x); }))),
    field('Canvas X / Y', num('w.cx', w.canvas.x, v => up(x => x.canvas.x = Math.round(v)), { step: 1 }), num('w.cy', w.canvas.y, v => up(x => x.canvas.y = Math.round(v)), { step: 1 })),

    h('h4', {}, 'Placement (meters, degrees)'),
    field('Attach to', sel('w.att', [['', '— free —'], ...p.walls.filter(o => o.id !== w.id).map(o => [o.id, o.name])], w.attach?.wallId || '', v => up(x => { x.attach = v ? { wallId: v, edge: x.attach?.edge || 'right', angle: x.attach?.angle ?? 0, offset: 0 } : null; }))),
    isAttached ? field('Edge / angle', sel('w.edge', [['right', 'Right edge'], ['left', 'Left edge'], ['top', 'Top (header)']], w.attach.edge, v => up(x => x.attach.edge = v)),
      num('w.aang', w.attach.angle, v => up(x => x.attach.angle = v), { step: 0.5, width: 56 })) : null,
    isAttached ? field(w.attach.edge === 'top' ? 'Col offset' : 'Height offset', num('w.aoff', w.attach.offset, v => up(x => x.attach.offset = v), { step: w.attach.edge === 'top' ? 1 : 0.05 })) : null,
    isAttached ? h('div', { class: 'note' }, w.attach.edge === 'top' ? 'Header follows the parent wall\'s curve. Angle = header tilt (+ toward audience).' : 'Angle = corner (+ concave / inside, − convex / outside, 90 = square corner).') : null,
    !isAttached ? field('Position X/Y/Z', num('w.x', w.pos.x, v => up(x => x.pos.x = v), { step: 0.1, width: 54 }), num('w.y', w.pos.y, v => up(x => x.pos.y = v), { step: 0.1, width: 54 }), num('w.z', w.pos.z, v => up(x => x.pos.z = v), { step: 0.1, width: 54 })) : null,
    !isAttached ? field('Yaw/Pitch/Roll', num('w.yaw', w.rot.yaw, v => up(x => x.rot.yaw = v), { step: 1, width: 54 }), num('w.pitch', w.rot.pitch, v => up(x => x.rot.pitch = v), { step: 1, width: 54 }), num('w.roll', w.rot.roll, v => up(x => x.rot.roll = v), { step: 1, width: 54 })) : null,

    h('h4', {}, 'Curve & hinge angles'),
    h('div', { class: 'note' }, 'Column hinges: + concave, − convex. Row hinges: + tilts upper rows toward audience. Click angle tags in Structure mode to edit one hinge.'),
    field('All columns', num('w.uni', uni ?? 0, v => up(x => x.colAngles = x.colAngles.map(() => v)), { step: 0.5 }), '°',
      uni ? h('span', { class: 'note' }, `R ≈ ${mm(radiusForAngle(dims.w, uni))}`) : null),
    field('From radius', num('w.rad', 0, v => { if (v > 0) up(x => x.colAngles = x.colAngles.map(() => +angleForRadius(dims.w, v).toFixed(2))); }, { step: 0.5, min: 0 }), h('span', { class: 'note' }, 'm (concave)')),
    field('Col angles', h('textarea', { 'data-k': 'w.ca', rows: 2, style: 'width:100%', value: angStr(w.colAngles), onchange: e => up(x => x.colAngles = parseAngles(e.target.value, x.cols - 1)) })),
    field('Row angles', h('textarea', { 'data-k': 'w.ra', rows: 2, style: 'width:100%', value: angStr(w.rowAngles), onchange: e => up(x => x.rowAngles = parseAngles(e.target.value, x.rows - 1)) })),
    h('div', { class: 'actions' },
      h('button', { onclick: () => up(x => x.colAngles = x.colAngles.map(a => -a)) }, 'Flip concave/convex'),
      h('button', { onclick: () => up(x => { x.colAngles = x.colAngles.map(() => 0); x.rowAngles = x.rowAngles.map(() => 0); }) }, 'Flatten'),
      h('button', { onclick: () => up(x => x.disabled = []) }, 'Restore all panels')),

    h('h4', {}, 'Build'),
    h('div', { class: 'actions' },
      h('button', { onclick: () => addAttached(w, 'top') }, '+ Header on top'),
      h('button', { onclick: () => addAttached(w, 'right') }, '+ Wing right (90°)'),
      h('button', { onclick: () => addAttached(w, 'left') }, '+ Wing left (90°)'),
      h('button', { onclick: () => duplicateWall(w) }, 'Duplicate'),
      h('button', { class: 'danger', onclick: () => { if (confirm(`Delete ${w.name}?`)) edit(pp => { pp.walls = pp.walls.filter(x => x.id !== w.id); pp.walls.forEach(x => { if (x.attach?.wallId === w.id) x.attach = null; }); }); } }, 'Delete')),
  );
}

function addAttached(parent, edge) {
  let id;
  edit(p => {
    const w = newWall(p, { panelTypeId: parent.panelTypeId, cols: edge === 'top' ? parent.cols : 4, rows: edge === 'top' ? 2 : parent.rows, name: `${parent.name} ${edge === 'top' ? 'Header' : edge === 'left' ? 'L Wing' : 'R Wing'}` });
    w.attach = { wallId: parent.id, edge, angle: edge === 'top' ? 0 : 90, offset: 0 };
    w.processorId = parent.processorId; w.rigging = edge === 'top' ? 'flown' : parent.rigging;
    autoPlaceCanvas(p, w);
    p.walls.push(w); id = w.id;
  });
  ui.sel = { type: 'wall', id }; ui.wall2d = id; renderAll();
}
function duplicateWall(w) {
  let id;
  edit(p => {
    const c = JSON.parse(JSON.stringify(byId(p.walls, w.id)));
    c.id = uid('w'); c.name = w.name + ' copy'; c.attach = null;
    const pt = byId(p.panelTypes, c.panelTypeId);
    c.pos.x += c.cols * (pt?.mmW || 500) / 1000 + 1;
    autoPlaceCanvas(p, c);
    p.walls.push(c); id = c.id;
  });
  ui.sel = { type: 'wall', id }; ui.wall2d = id; renderAll();
}

function modelOptions() {
  const groups = {};
  for (const [k, m] of Object.entries(PROCESSOR_MODELS)) (groups[m.vendor] ||= []).push([k, m.name]);
  return Object.entries(groups).map(([g, items]) => ({ group: g, items }));
}

function inspectProc(el, pr) {
  if (!pr) return;
  const p = P(), pa = A.processors.get(pr.id), m = procModel(pr);
  const up = fn => editProc(pr.id, fn);
  const src = byId(p.sources, pr.sourceId);
  app(el, 
    h('h3', {}, pr.name),
    field('Name', txt('p.name', pr.name, v => up(x => x.name = v))),
    field('Number', txt('p.code', pr.code, v => up(x => x.code = v.trim().slice(0, 4).toUpperCase())), h('span', { class: 'note' }, `distros ${distroName(pr, 0)}, ${distroName(pr, 1)}…`)),
    field('Model', sel('p.model', modelOptions(), pr.model, v => up(x => { x.model = v; const mm2 = PROCESSOR_MODELS[v]; x.inputW = Math.min(x.inputW, mm2.maxInputW); x.inputH = Math.min(x.inputH, mm2.maxInputH); x.distributors = mm2.trunks ? Math.min(2, mm2.trunks) : 0; }))),
    field('Input res', num('p.iw', pr.inputW, v => up(x => x.inputW = Math.round(v)), { step: 1, width: 64 }), '×', num('p.ih', pr.inputH, v => up(x => x.inputH = Math.round(v)), { step: 1, width: 64 })),
    field('', sel('p.res', [['', 'Preset…'], ...RES_PRESETS.map(([a, b]) => [`${a}x${b}`, `${a}×${b}`])], '', v => { if (v) { const [a, b] = v.split('x').map(Number); up(x => { x.inputW = a; x.inputH = b; }); } })),
    m.trunks ? field(`Distros (${m.distributor})`, chk('p.ad', pr.autoDistributors, v => up(x => x.autoDistributors = v), 'Auto'),
      !pr.autoDistributors ? num('p.dist', pr.distributors, v => up(x => x.distributors = Math.max(0, Math.min(m.trunks, Math.round(v)))), { step: 1, min: 0, max: m.trunks, width: 50 }) : null) : null,
    field('Backup', chk('p.bk', pr.backup, v => up(x => x.backup = v), 'Redundant ports (halves usable)')),
    field('Port px override', num('p.ppo', pr.portPixelsOverride, v => up(x => x.portPixelsOverride = Math.max(0, Math.round(v))), { step: 1000 }), h('span', { class: 'note' }, '0 = model default @60Hz')),
    h('h4', {}, 'Source'),
    field('Media server', sel('p.src', [['', '— none —'], ...p.sources.map(s => [s.id, s.name])], pr.sourceId || '', v => up(x => x.sourceId = v || null))),
    src ? field('Output', sel('p.out', src.outputs.map((o, k) => [k, `OUT ${k + 1} — ${o.w}×${o.h}@${o.hz}`]), pr.sourceOutput, v => up(x => x.sourceOutput = +v))) : null,
    h('h4', {}, 'Capacity'),
    pa ? kv([
      ['Model limits', `${m.maxInputW}×${m.maxInputH} in · ${(m.maxPixels / 1e6).toFixed(2)} MP`],
      ['Port capacity', `${pa.capPx.toLocaleString()} px @ ${p.settings.frameRate}Hz`],
      ['Ports used', `${pa.maxIdx + 1} / ${pa.portsAvail}${m.trunks ? ` (max ${pa.hardMax})` : ''}`],
      m.trunks ? ['Distros', `${Array.from({ length: pa.distUsed }, (_, d) => distroName(pr, d)).join(', ') || 'none'} · need ${pa.distNeeded} of ${m.trunks}`] : null,
      ['Pixel load', `${(pa.pixelsUsed / 1e6).toFixed(2)} MP (${Math.round(100 * pa.pixelsUsed / m.maxPixels)}%)`],
      ['Walls', pa.walls.map(w => w.name).join(', ') || '—'],
    ].filter(Boolean)) : null,
    h('div', { class: 'actions' },
      h('button', { onclick: () => edit(pp => autoPack(pp, pr.id)) }, 'Auto-pack canvas'),
      h('button', { onclick: () => { ui.pxProc = pr.id; ui.tab = 'pixmap'; renderAll(); } }, 'Open pixel map'),
      h('button', { class: 'danger', onclick: () => { if (confirm(`Delete ${pr.name}?`)) edit(pp => { pp.processors = pp.processors.filter(x => x.id !== pr.id); pp.walls.forEach(w => { if (w.processorId === pr.id) w.processorId = null; }); }); } }, 'Delete')),
  );
}

function inspectSrc(el, s) {
  if (!s) return;
  const sa = A.sources.get(s.id);
  const up = fn => editSrc(s.id, fn);
  app(el, 
    h('h3', {}, s.name),
    field('Name', txt('s.name', s.name, v => up(x => x.name = v))),
    field('GPU', txt('s.gpu', s.gpu, v => up(x => x.gpu = v))),
    field('', sel('s.gpup', [['', 'Preset…'], ...GPU_PRESETS.map(g => [g.name, g.name])], '', v => { const g = GPU_PRESETS.find(x => x.name === v); if (g) up(x => { x.gpu = g.name; while (x.outputs.length < g.outputs) x.outputs.push({ w: 3840, h: 2160, hz: 60 }); x.outputs.length = g.outputs; x.mosaic.cols = g.outputs; x.mosaic.rows = 1; }); })),
    field('Outputs', num('s.n', s.outputs.length, v => up(x => { const n = Math.max(1, Math.min(16, Math.round(v))); while (x.outputs.length < n) x.outputs.push({ ...x.outputs[x.outputs.length - 1] }); x.outputs.length = n; }), { step: 1, min: 1, max: 16 })),
    field('Mosaic grid', num('s.mc', s.mosaic.cols, v => up(x => x.mosaic.cols = Math.max(1, Math.round(v))), { step: 1, min: 1, width: 50 }), '×', num('s.mr', s.mosaic.rows, v => up(x => x.mosaic.rows = Math.max(1, Math.round(v))), { step: 1, min: 1, width: 50 })),
    sa ? h('div', { class: 'note' }, `Mosaic desktop: ${sa.canvasW} × ${sa.canvasH}`) : null,
    h('h4', {}, 'Outputs'),
    s.outputs.map((o, k) => {
      const procs = P().processors.filter(pr => pr.sourceId === s.id && pr.sourceOutput === k);
      return h('div', {},
        field(`OUT ${k + 1}`, num(`s.o${k}w`, o.w, v => up(x => x.outputs[k].w = Math.round(v)), { step: 1, width: 56 }), '×', num(`s.o${k}h`, o.h, v => up(x => x.outputs[k].h = Math.round(v)), { step: 1, width: 56 }),
          num(`s.o${k}hz`, o.hz, v => up(x => x.outputs[k].hz = v), { width: 46 })),
        h('div', { class: 'note', style: 'margin:-2px 0 6px 102px' }, procs.length ? '→ ' + procs.map(x => x.name).join(', ') : 'unused'));
    }),
    h('div', { class: 'actions' }, h('button', { class: 'danger', onclick: () => { if (confirm(`Delete ${s.name}?`)) edit(pp => { pp.sources = pp.sources.filter(x => x.id !== s.id); pp.processors.forEach(x => { if (x.sourceId === s.id) x.sourceId = null; }); }); } }, 'Delete')),
  );
}

function inspectPT(el, t) {
  if (!t) return;
  const up = fn => editPT(t.id, fn);
  const used = P().walls.filter(w => w.panelTypeId === t.id).length;
  const n = (k, label, v, set, opts) => field(label, num('t.' + k, v, set, opts));
  app(el, 
    h('h3', {}, `${t.mfr} ${t.name}`),
    field('Load preset', sel('t.lib', [['', 'From library…'], ...PANEL_LIBRARY.map(l => [l.key, `${l.mfr} — ${l.name}`])], '', v => { const l = PANEL_LIBRARY.find(x => x.key === v); if (l) up(x => { const { key, ...rest } = l; Object.assign(x, rest, { libKey: key }); }); })),
    field('Manufacturer', txt('t.mfr', t.mfr, v => up(x => x.mfr = v))),
    field('Model', txt('t.name', t.name, v => up(x => x.name = v))),
    field('Pixels W×H', num('t.pxw', t.pxW, v => up(x => x.pxW = Math.round(v)), { step: 1, width: 58 }), '×', num('t.pxh', t.pxH, v => up(x => x.pxH = Math.round(v)), { step: 1, width: 58 })),
    field('Size mm W×H', num('t.mmw', t.mmW, v => up(x => x.mmW = v), { width: 58 }), '×', num('t.mmh', t.mmH, v => up(x => x.mmH = v), { width: 58 })),
    n('mmd', 'Depth mm', t.mmD, v => up(x => x.mmD = v)),
    n('kg', 'Weight kg', t.kg, v => up(x => x.kg = v), { step: 0.01 }),
    n('wmax', 'Max watts', t.wMax, v => up(x => x.wMax = v)),
    n('wavg', 'Typical watts', t.wAvg, v => up(x => x.wAvg = v)),
    n('mpp', 'Max / data port', t.maxPerPort, v => up(x => x.maxPerPort = Math.round(v)), { step: 1, min: 0 }),
    n('mpl', 'Max / power link', t.maxPerPowerLink, v => up(x => x.maxPerPowerLink = Math.round(v)), { step: 1, min: 0 }),
    h('div', { class: 'note' }, '0 = no limit. Power link = max panels on a powerCON/true1 daisy chain per the manufacturer.'),
    kv([
      ['Pitch', `${(t.mmW / t.pxW).toFixed(2)} mm`],
      ['Weight', `${(t.kg * KG2LB).toFixed(1)} lb`],
      ['Per circuit', VOLTAGES.map(v => `${v.v}V:${circuitCapacity(P(), t, v.key)}`).join(' ')],
      ['Used by', `${used} wall(s)`],
    ]),
    h('div', { class: 'note warn' }, 'Verify against current manufacturer spec sheet.'),
    h('div', { class: 'actions' },
      h('button', { onclick: () => { let id; edit(pp => { const c = { ...JSON.parse(JSON.stringify(t)), id: uid('pt'), name: t.name + ' copy' }; pp.panelTypes.push(c); id = c.id; }); ui.sel = { type: 'pt', id }; renderAll(); } }, 'Duplicate'),
      h('button', { class: 'danger', disabled: used > 0, title: used ? 'In use' : '', onclick: () => edit(pp => { pp.panelTypes = pp.panelTypes.filter(x => x.id !== t.id); }) }, 'Delete')),
  );
}

// ---------- status bar ----------
function renderStatus() {
  const T = A.totals, s = P().settings, v = VOLTAGES.find(x => x.key === s.voltage);
  const e = A.issues.filter(i => i.level === 'error').length, w = A.issues.filter(i => i.level === 'warn').length;
  $('#status').innerHTML = [
    `Panels <b>${T.panels.toLocaleString()}</b>`, `<b>${(T.pixels / 1e6).toFixed(2)}</b> MP`,
    `Weight <b>${fmtKgBoth(T.kg)}</b>`, `Max <b>${(T.wMax / 1000).toFixed(1)} kW</b> · Typ <b>${(T.wAvg / 1000).toFixed(1)} kW</b>`,
    `<b>${(T.wMax / v.v).toFixed(0)} A</b> @ ${v.v}V`, `<b>${(T.wMax / (Math.sqrt(3) * 208)).toFixed(0)} A</b>/leg 208 3Φ`,
    `Circuits <b>${T.circuits}</b>`, `Data runs <b>${T.dataRuns}</b>`,
    e ? `<span style="color:var(--err)">● ${e} errors</span>` : '<span style="color:var(--ok)">● no errors</span>', w ? `<span style="color:var(--warn)">${w} warnings</span>` : '',
  ].filter(Boolean).map(s => `<span>${s}</span>`).join('');
  const b = $('#issueBadge'); b.textContent = e || w || ''; b.className = e ? '' : w ? 'warn' : '';
}

// ---------- 2D map ----------
function current2DWall() { return byId(P().walls, ui.wall2d); }

function render2D() {
  const tb = $('#tb2d'), stage = $('#stage2d'), rp = $('#runsPanel');
  tb.innerHTML = ''; rp.innerHTML = '';
  const w = current2DWall();
  if (!w) { stage.innerHTML = '<div class="empty">No walls yet. Add one from the sidebar.</div>'; return; }
  const wa = A.walls.get(w.id);
  if (!wa) { stage.innerHTML = ''; return; }
  const kind = ui.mode2d;
  const cfg = kind === 'structure' ? null : w[kind];
  const up = fn => editWall(w.id, fn);

  app(tb, 
    sel('t2.wall', P().walls.map(x => [x.id, x.name]), w.id, v => { ui.wall2d = v; ui.sel = { type: 'wall', id: v }; ui.selRun = 0; renderAll(); }),
    h('div', { class: 'grp' }, ['data', 'power', 'structure'].map(m => h('button', { class: ui.mode2d === m ? 'on' : '', onclick: () => { ui.mode2d = m; ui.selRun = 0; render2D(); } }, { data: 'Data', power: 'Power', structure: 'Structure' }[m]))),
  );
  if (cfg) {
    const cap = kind === 'data' ? wa.dataCap : wa.powerCap;
    app(tb, h('div', { class: 'grp' },
      h('button', { class: cfg.mode === 'auto' ? 'on' : '', onclick: () => up(x => x[kind].mode = 'auto') }, 'Auto'),
      h('button', { class: cfg.mode === 'custom' ? 'on' : '', onclick: () => toCustom(w, kind) }, 'Custom')));
    if (cfg.mode === 'auto') {
      const pat = cfg.pattern;
      const setPat = (k, v) => up(x => { x[kind].pattern = { ...x[kind].pattern, [k]: v }; });
      app(tb, 
        sel('t2.pre', Object.entries(PRESETS).map(([k, v]) => [k, v.label]), pat.preset || 'recommend', v => setPat('preset', v)),
        h('label', {}, 'Start', sel('t2.start', [['', 'Auto (rigging)'], ['BL', 'Bottom-left'], ['BR', 'Bottom-right'], ['TL', 'Top-left'], ['TR', 'Top-right']], pat.start || '', v => setPat('start', v || undefined))),
        pat.preset !== 'recommend' ? sel('t2.chunk', Object.entries(CHUNKS), pat.chunk || 'lines', v => setPat('chunk', v)) : null,
        h('label', {}, 'Max/run', num('t2.max', pat.maxPerRun || 0, v => setPat('maxPerRun', Math.max(0, Math.round(v))), { step: 1, min: 0, width: 50 })),
        h('span', { class: 'hint' }, pat.preset === 'recommend' ? describeRecommendation(w, cap, pat) : `cap ${cap}/run`),
      );
    } else {
      const runs = cfg.runs;
      const selRun = runs[ui.selRun];
      app(tb, 
        h('button', { onclick: () => { up(x => x[kind].runs.push({ panels: [], port: null })); ui.selRun = w[kind].runs.length; render2D(); } }, '+ New run'),
        h('button', { disabled: !selRun, onclick: () => up(x => x[kind].runs[ui.selRun].panels.reverse()) }, 'Reverse'),
        h('button', { disabled: !selRun, onclick: () => up(x => x[kind].runs[ui.selRun].panels = []) }, 'Clear'),
        h('button', { disabled: !selRun, onclick: () => { up(x => x[kind].runs.splice(ui.selRun, 1)); ui.selRun = Math.max(0, ui.selRun - 1); } }, 'Delete run'),
        kind === 'data' && selRun && wa.proc ? h('label', {}, 'Port', sel('t2.port', [['', 'Auto'], ...Array.from({ length: A.processors.get(wa.proc.id).hardMax }, (_, i) => [i, portLabel(wa.proc, i)])], Number.isInteger(selRun.port) ? selRun.port : '', v => up(x => x[kind].runs[ui.selRun].port = v === '' ? null : +v))) : null,
        h('button', { onclick: () => { if (confirm('Discard custom wiring and go back to auto?')) up(x => { x[kind].mode = 'auto'; x[kind].runs = []; }); } }, 'Reset to auto'),
        h('span', { class: 'hint' }, `Click/drag panels to add to the selected run (cap ${cap}). ⌥-click removes.`),
      );
    }
  } else {
    app(tb, h('span', { class: 'hint' }, 'Click/drag panels to remove or restore (cut-outs, irregular shapes). Click angle tags to set hinge / curve-block angles.'));
  }
  app(tb, h('span', { style: 'flex:1' }), h('button', { onclick: () => { delete ui.vb[w.id]; render2D(); } }, 'Fit'));

  // diagram
  const diag = wallDiagram(w, wa, kind, { ink: '#e8ecf2', selectedRun: cfg?.mode === 'custom' || kind !== 'structure' ? ui.selRun : null, coords: kind === 'structure' });
  const pad = Math.max(diag.cw, diag.ch);
  const fit = [-pad, -pad, diag.w + pad * 2, diag.h + pad * 2];
  const vb = ui.vb[w.id] || fit;
  stage.innerHTML = `<svg viewBox="${vb.join(' ')}" preserveAspectRatio="xMidYMid meet">${arrowDefs(1).replace(/#111/g, '#e8ecf2')}<rect x="${-pad * 50}" y="${-pad * 50}" width="${pad * 100 + diag.w}" height="${pad * 100 + diag.h}" fill="transparent" class="bg"/>${diag.svg}</svg>`;
  setup2DInteraction(stage.firstChild, w, kind, fit);

  // run chips
  if (cfg) {
    const runs = kind === 'data' ? wa.dataRuns : wa.powerRuns;
    const cap = kind === 'data' ? wa.dataCap : wa.powerCap;
    runs.forEach((r, i) => app(rp, h('div', { class: 'runchip' + (i === ui.selRun ? ' sel' : '') + (r.panels.length > cap ? ' over' : ''), onclick: () => { ui.selRun = i; render2D(); } },
      h('span', { class: 'sw', style: `background:${runColor(i + (kind === 'power' ? 3 : 0))}` }),
      `${r.label || i + 1} · ${r.panels.length}${kind === 'data' ? ` · ${Math.round(r.loadPct || 0)}%` : ` · ${r.amps.toFixed(1)}A${r.phase ? ' ' + r.phase : ''}`}`)));
  }
}

function toCustom(w, kind) {
  const wa = A.walls.get(w.id);
  editWall(w.id, x => {
    if (x[kind].mode === 'custom') return;
    x[kind].runs = (kind === 'data' ? wa.dataRuns : wa.powerRuns).map(r => ({ panels: r.panels.map(p => [...p]), port: Number.isInteger(r.port) ? r.port : null }));
    x[kind].mode = 'custom';
  });
}

let cur2DEnd = null;
window.addEventListener('pointerup', () => cur2DEnd?.());

function setup2DInteraction(svg, w, kind, fit) {
  const getVB = () => svg.viewBox.baseVal;
  const toLocal = (e) => { const pt = svg.createSVGPoint(); pt.x = e.clientX; pt.y = e.clientY; return pt.matrixTransform(svg.getScreenCTM().inverse()); };
  const saveVB = () => { const b = getVB(); ui.vb[w.id] = [b.x, b.y, b.width, b.height]; };

  svg.addEventListener('wheel', e => {
    e.preventDefault();
    const b = getVB();
    if (e.ctrlKey || e.metaKey) {
      const f = Math.exp(e.deltaY * 0.01), p = toLocal(e);
      b.x = p.x - (p.x - b.x) * f; b.y = p.y - (p.y - b.y) * f; b.width *= f; b.height *= f;
    } else {
      const s = b.width / svg.clientWidth;
      b.x += e.deltaX * s; b.y += e.deltaY * s;
    }
    saveVB();
  }, { passive: false });

  let mode = null, start = null, paintState = null, touched = null, last = null;
  // Fill in grid cells skipped between two pointer samples.
  const paintTo = pnl => {
    if (!last) { last = pnl; applyPaint(pnl); return; }
    const dc = pnl[0] - last[0], dr = pnl[1] - last[1], n = Math.max(Math.abs(dc), Math.abs(dr));
    for (let i = 1; i <= n; i++) applyPaint([Math.round(last[0] + dc * i / n), Math.round(last[1] + dr * i / n)]);
    last = pnl;
  };
  const panelAt = e => { const t = document.elementFromPoint(e.clientX, e.clientY); return t?.classList?.contains('pnl') ? [+t.dataset.c, +t.dataset.r] : null; };

  svg.addEventListener('pointerdown', e => {
    const hinge = e.target.closest?.('.hinge');
    if (hinge) { anglePopover(e, w, hinge.dataset.hinge, +hinge.dataset.i); return; }
    const pnl = e.target.classList?.contains('pnl') ? [+e.target.dataset.c, +e.target.dataset.r] : null;
    if (!pnl || e.button === 1) { mode = 'pan'; start = { x: e.clientX, y: e.clientY, b: { ...getVB() } }; svg.setPointerCapture(e.pointerId); return; }
    const k = pnl.join(',');
    if (kind === 'structure') {
      store.undoStack.push(store.snapshot()); store.redoStack = [];
      const wl = byId(P().walls, w.id);
      paintState = !wl.disabled.includes(k); // true => disable
      mode = 'paint'; touched = new Set(); last = null; paintTo(pnl);
    } else {
      const wl = byId(P().walls, w.id);
      if (wl[kind].mode !== 'custom') {
        // In auto mode: select the run containing this panel.
        const wa = A.walls.get(w.id);
        const runs = kind === 'data' ? wa.dataRuns : wa.powerRuns;
        const i = runs.findIndex(r => r.panels.some(([c, r2]) => c === pnl[0] && r2 === pnl[1]));
        if (i >= 0) { ui.selRun = i; render2D(); }
        toast('Switch to Custom to hand-wire runs');
        return;
      }
      store.undoStack.push(store.snapshot()); store.redoStack = [];
      if (!wl[kind].runs.length) wl[kind].runs.push({ panels: [], port: null });
      if (ui.selRun >= wl[kind].runs.length) ui.selRun = wl[kind].runs.length - 1;
      mode = e.altKey ? 'erase' : 'wire'; touched = new Set(); last = null; paintTo(pnl);
    }
    svg.setPointerCapture(e.pointerId);
  });

  function applyPaint(pnl) {
    const k = pnl.join(',');
    if (touched.has(k)) return; touched.add(k);
    const wl = byId(P().walls, w.id);
    if (mode === 'paint') {
      wl.disabled = wl.disabled.filter(x => x !== k);
      if (paintState) wl.disabled.push(k);
    } else {
      for (const run of wl[kind].runs) run.panels = run.panels.filter(([c, r]) => !(c === pnl[0] && r === pnl[1]));
      if (mode === 'wire') wl[kind].runs[ui.selRun].panels.push([...pnl]);
    }
    A = analyze(P());
    const vbSaved = getVB(); ui.vb[w.id] = [vbSaved.x, vbSaved.y, vbSaved.width, vbSaved.height];
    // redraw just the diagram content
    const wa = A.walls.get(w.id);
    const diag = wallDiagram(wl, wa, kind, { ink: '#e8ecf2', selectedRun: ui.selRun, coords: kind === 'structure' });
    [...svg.children].forEach(ch => { if (!ch.matches('defs, rect.bg')) ch.remove(); });
    svg.insertAdjacentHTML('beforeend', diag.svg);
  }

  svg.addEventListener('pointermove', e => {
    if (mode === 'pan') {
      const s = start.b.width / svg.clientWidth, b = getVB();
      b.x = start.b.x - (e.clientX - start.x) * s; b.y = start.b.y - (e.clientY - start.y) * s;
      return;
    }
    if (mode === 'paint' || mode === 'wire' || mode === 'erase') { const p = panelAt(e); if (p) paintTo(p); }
  });
  const end = () => {
    if (mode === 'pan') saveVB();
    else if (mode) { store.dirty = true; store.save(); store.emit('paint'); }
    mode = null;
  };
  svg.addEventListener('pointerup', end);
  svg.addEventListener('pointercancel', end);
  svg.addEventListener('lostpointercapture', end);
  cur2DEnd = end;
}

function anglePopover(e, w, which, i) {
  const pop = $('#popover');
  const arr = which === 'col' ? w.colAngles : w.rowAngles;
  const cur = arr[i] || 0;
  let all = false;
  const apply = v => { editWall(w.id, x => { const a = which === 'col' ? x.colAngles : x.rowAngles; if (all) a.fill(v); else a[i] = v; }); pop.hidden = true; };
  const inp = h('input', { type: 'number', value: cur, step: 0.5, style: 'width:80px', onkeydown: ev => { if (ev.key === 'Enter') apply(parseFloat(inp.value) || 0); if (ev.key === 'Escape') pop.hidden = true; } });
  pop.innerHTML = '';
  pop.append(
    h('b', {}, which === 'col' ? `Column hinge ${i + 1}|${i + 2}` : `Row hinge ${i + 1}/${i + 2}`),
    h('div', { class: 'presets' }, ANGLE_PRESETS.map(a => h('button', { class: 'mini' + (a === cur ? ' on' : ''), onclick: () => apply(a) }, (a > 0 ? '+' : '') + a + '°'))),
    h('div', { style: 'display:flex;gap:6px;align-items:center' }, inp, '°', h('button', { class: 'primary', onclick: () => apply(parseFloat(inp.value) || 0) }, 'Set')),
    chk('pop.all', false, v => all = v, 'Apply to all ' + (which === 'col' ? 'column' : 'row') + ' hinges'),
    h('div', { class: 'note' }, which === 'col' ? '+ concave · − convex · 90 corner' : '+ tilt toward audience'),
  );
  pop.hidden = false;
  const r = pop.getBoundingClientRect();
  pop.style.left = Math.min(window.innerWidth - r.width - 10, e.clientX) + 'px';
  pop.style.top = Math.min(window.innerHeight - r.height - 10, e.clientY + 10) + 'px';
  setTimeout(() => inp.select(), 0);
}
document.addEventListener('pointerdown', e => { const pop = $('#popover'); if (!pop.hidden && !pop.contains(e.target) && !e.target.closest?.('.hinge')) pop.hidden = true; });

// ---------- 3D ----------
async function ensure3D() {
  if (view3d) return view3d;
  view3d = await import('./view3d.js');
  view3d.init3D($('#stage3d'), id => { ui.sel = { type: 'wall', id }; ui.wall2d = id; renderAll(); });
  const blob = await roomStore.get().catch(() => null);
  if (blob && P().room) { try { await view3d.loadRoom(blob); view3d.applyRoom(P().room); } catch (e) { /* ignore */ } }
  return view3d;
}

async function render3D() {
  const tb = $('#tb3d'); tb.innerHTML = '';
  const p = P(), room = p.room;
  const upRoom = fn => edit(pp => { pp.room ||= { scale: 1, offset: { x: 0, y: 0, z: 0 }, rotY: 0, opacity: 0.6, visible: true }; fn(pp.room); });
  app(tb, 
    h('div', { class: 'grp' }, ['wall', 'data', 'power'].map(m => h('button', { class: ui.color3d === m ? 'on' : '', onclick: () => { ui.color3d = m; render3D(); } }, { wall: 'Walls', data: 'Data', power: 'Power' }[m]))),
    chk('3d.paths', ui.paths3d, v => { ui.paths3d = v; render3D(); }, 'Paths'),
    h('div', { class: 'grp' }, ['front', 'top', 'side'].map(v => h('button', { onclick: () => view3d?.setView(v) }, v[0].toUpperCase() + v.slice(1))), h('button', { onclick: () => view3d?.frameAll() }, 'Fit')),
    h('span', { class: 'sep' }),
    h('button', { onclick: importRoom, title: 'SketchUp: export as COLLADA (.dae), OBJ or glTF' }, 'Import room model…'),
  );
  if (room) {
    app(tb, 
      h('label', {}, 'Units', sel('3d.u', [[1, 'm'], [0.0254, 'in'], [0.3048, 'ft'], [0.001, 'mm'], [0.01, 'cm']], room.scale, v => upRoom(r => r.scale = +v))),
      h('label', {}, 'Offset', num('3d.ox', room.offset.x, v => upRoom(r => r.offset.x = v), { width: 50, step: 0.1 }), num('3d.oy', room.offset.y, v => upRoom(r => r.offset.y = v), { width: 50, step: 0.1 }), num('3d.oz', room.offset.z, v => upRoom(r => r.offset.z = v), { width: 50, step: 0.1 })),
      h('label', {}, 'Rot', num('3d.ry', room.rotY, v => upRoom(r => r.rotY = v), { width: 50, step: 5 })),
      h('label', {}, 'Opacity', h('input', { type: 'range', min: 0.05, max: 1, step: 0.05, value: room.opacity, onchange: e => upRoom(r => r.opacity = +e.target.value) })),
      chk('3d.rv', room.visible !== false, v => upRoom(r => r.visible = v), 'Show'),
      h('button', { class: 'mini', title: 'Remove room model', onclick: () => { roomStore.clear(); view3d?.clearRoom(); edit(pp => { pp.room = null; }); } }, icon('close')),
    );
  }
  const v = await ensure3D();
  v.poke();
  v.update3D(p, A, { colorMode: ui.color3d, selectedWallId: ui.sel.type === 'wall' ? ui.sel.id : null, showPaths: ui.paths3d });
  if (v.hasRoom()) v.applyRoom(p.room);
  else if (room) app(tb, h('span', { class: 'hint' }, `Re-import ${room.fileName || 'room model'} to display`));
}

async function importRoom() {
  const f = await io.openFile('.dae,.obj,.glb,.gltf,.stl,.fbx,.skp');
  if (!f) return;
  try {
    const v = await ensure3D();
    const info = await v.loadRoom(f);
    roomStore.put(f).catch(() => {});
    // Guess units: SketchUp exports are usually inches. If the model is huge, assume inches.
    const maxDim = Math.max(...info.size);
    const scale = maxDim > 300 ? 0.0254 : 1;
    edit(p => { p.room = { fileName: f.name, scale, offset: { x: 0, y: 0, z: 0 }, rotY: 0, opacity: 0.6, visible: true }; });
    toast(`Loaded ${f.name}${scale !== 1 ? ' (assumed inches)' : ''}`);
  } catch (e) { toast(e.message, true); }
}

// ---------- pixel map ----------
function renderPixMap() {
  const p = P(), tb = $('#tbpx'), st = $('#stagepx');
  tb.innerHTML = ''; st.innerHTML = '';
  if (!p.processors.length) { st.innerHTML = '<div class="empty">No processors yet. Add one from the sidebar.</div>'; return; }
  if (!byId(p.processors, ui.pxProc)) ui.pxProc = p.processors[0].id;
  const pr = byId(p.processors, ui.pxProc);
  app(tb, 
    sel('px.proc', p.processors.map(x => [x.id, `${x.name} (${x.inputW}×${x.inputH})`]), pr.id, v => { ui.pxProc = v; renderPixMap(); }),
    h('label', {}, 'Zoom', sel('px.z', [['fit', 'Fit'], [0.25, '25%'], [0.5, '50%'], [1, '100%']], ui.pxZoom, v => { ui.pxZoom = v; renderPixMap(); })),
    chk('px.snap', ui.pxSnap, v => ui.pxSnap = v, 'Snap to panel'),
    h('button', { onclick: () => edit(pp => autoPack(pp, pr.id)) }, 'Auto-pack'),
    h('button', { onclick: exportPixelMap }, 'Export PNG'),
    h('span', { class: 'hint' }, 'Drag walls to set their position on the processor input canvas.'),
  );
  const canvas = h('canvas');
  drawPixelMap(canvas, p, A, pr);
  const availW = st.clientWidth - 40, availH = st.clientHeight - 200;
  const z = ui.pxZoom === 'fit' ? Math.min(1, availW / pr.inputW, Math.max(0.1, availH / pr.inputH)) : +ui.pxZoom;
  canvas.style.width = pr.inputW * z + 'px'; canvas.style.height = pr.inputH * z + 'px';
  const wrap = h('div', { class: 'pxwrap' }, canvas);
  for (const w of p.walls.filter(x => x.processorId === pr.id)) {
    const wa = A.walls.get(w.id); if (!wa) continue;
    const d = h('div', { class: 'pxwall' + (ui.sel.id === w.id ? ' sel' : ''), title: `${w.name} ${wa.resW}×${wa.resH} @ ${w.canvas.x},${w.canvas.y}`,
      style: `left:${w.canvas.x * z}px;top:${w.canvas.y * z}px;width:${wa.resW * z}px;height:${wa.resH * z}px;border-color:${w.color}` });
    d.addEventListener('pointerdown', e => {
      e.preventDefault(); d.setPointerCapture(e.pointerId);
      const sx = e.clientX, sy = e.clientY, ox = w.canvas.x, oy = w.canvas.y;
      const snapX = ui.pxSnap ? wa.pt.pxW : 1, snapY = ui.pxSnap ? wa.pt.pxH : 1;
      let nx = ox, ny = oy;
      const mv = ev => {
        nx = Math.max(0, Math.round((ox + (ev.clientX - sx) / z) / snapX) * snapX);
        ny = Math.max(0, Math.round((oy + (ev.clientY - sy) / z) / snapY) * snapY);
        d.style.left = nx * z + 'px'; d.style.top = ny * z + 'px'; d.title = `${nx},${ny}`;
      };
      const upH = () => {
        d.removeEventListener('pointermove', mv); d.removeEventListener('pointerup', upH);
        ui.sel = { type: 'wall', id: w.id };
        if (nx !== ox || ny !== oy) editWall(w.id, x => { x.canvas = { x: nx, y: ny }; }); else renderAll();
      };
      d.addEventListener('pointermove', mv); d.addEventListener('pointerup', upH);
    });
    app(wrap, d);
  }
  app(st, h('div', { class: 'pxcap' }, `${pr.name} input canvas ${pr.inputW}×${pr.inputH}`), wrap);

  // Media server mosaic
  const src = byId(p.sources, pr.sourceId);
  if (src) {
    const sa = A.sources.get(src.id);
    const mz = Math.min(0.08, (st.clientWidth - 60) / Math.max(1, sa.canvasW));
    const box = h('div', { class: 'mosaic', style: `position:relative;width:${sa.canvasW * mz}px;height:${sa.canvasH * mz}px` });
    for (const c of sa.cells) {
      const procs = p.processors.filter(x => x.sourceId === src.id && x.sourceOutput === c.k);
      app(box, h('div', { class: 'cell' + (procs.length ? ' used' : ''), style: `left:${c.x * mz}px;top:${c.y * mz}px;width:${c.w * mz}px;height:${c.h * mz}px` },
        `OUT ${c.k + 1} ${c.w}×${c.h}`, h('br'), procs.map(x => x.name).join(', ')));
    }
    app(st, h('div', { class: 'pxcap' }, `${src.name} mosaic desktop ${sa.canvasW}×${sa.canvasH} (${src.mosaic.cols}×${src.mosaic.rows})`), box);
  }
}

async function exportPixelMap() {
  const pr = byId(P().processors, ui.pxProc) || P().processors[0];
  if (!pr) return;
  const c = document.createElement('canvas');
  drawPixelMap(c, P(), A, pr);
  await io.saveFile(`${P().name} - ${pr.name} pixel map ${pr.inputW}x${pr.inputH}.png`, await io.canvasToBlob(c));
}

// ---------- resources ----------
function bar(label, val, max, fmt = v => v.toLocaleString()) {
  const pct = max ? 100 * val / max : 0;
  return `<div class="bar ${pct > 100 ? 'over' : pct > 85 ? 'hi' : ''}"><div class="lbl"><span>${esc(label)}</span><b>${fmt(val)} / ${fmt(max)} (${Math.round(pct)}%)</b></div><div class="trk"><div class="fill" style="width:${Math.min(100, pct)}%"></div></div></div>`;
}

function fitsModels(pa) {
  const p = P();
  return Object.entries(PROCESSOR_MODELS).filter(([k, m]) => {
    if (k === 'custom') return false;
    const fake = { ...pa.proc, model: k };
    const cap = portCapacityPixels(p, fake);
    const ports = m.trunks ? m.trunks * m.portsPerDistributor : m.directPorts;
    const need = [...pa.ports.values()].reduce((s, x) => s + Math.ceil(x.pixels / cap), 0);
    return need <= (pa.proc.backup ? ports / 2 : ports) && pa.pixelsUsed <= m.maxPixels && pa.proc.inputW <= m.maxInputW && pa.proc.inputH <= m.maxInputH;
  }).map(([, m]) => m.name);
}

function renderResources() {
  const p = P(), s = p.settings, T = A.totals, el = $('#resources');
  const v = VOLTAGES.find(x => x.key === s.voltage);
  let o = '<div class="res">';
  // Issues
  o += `<h2>Checks</h2>`;
  o += A.issues.length ? `<ul class="issues">${A.issues.map((i, n) => `<li class="${i.level}" data-n="${n}">${esc(i.msg)}</li>`).join('')}</ul>` : `<div class="allclear">All walls fully connected, no processor, port, input or circuit is over capacity.</div>`;

  // Processors
  o += `<h2>Processors & distribution</h2><div class="cards">`;
  for (const pa of A.processors.values()) {
    const pr = pa.proc, m = pa.model;
    const over = A.issues.some(i => i.level === 'error' && i.ref?.proc === pr.id);
    o += `<div class="card ${over ? 'bad' : ''}"><h3>${esc(pr.name)} <small>${esc(m.vendor + ' ' + m.name)}</small></h3>`;
    o += bar('Ports', pa.maxIdx + 1, pa.portsAvail);
    if (m.trunks) o += bar(`Distros needed (${m.distributor})`, pa.distNeeded, pa.distUsed || m.trunks);
    o += bar('Pixel load (MP)', pa.pixelsUsed / 1e6, m.maxPixels / 1e6, x => x.toFixed(2));
    const usedW = Math.max(0, ...pa.walls.map(w => w.canvas.x + A.walls.get(w.id).resW)), usedH = Math.max(0, ...pa.walls.map(w => w.canvas.y + A.walls.get(w.id).resH));
    o += bar('Input width used', usedW, pr.inputW) + bar('Input height used', usedH, pr.inputH);
    o += `<div class="note">Input ${pr.inputW}×${pr.inputH} (max ${m.maxInputW}×${m.maxInputH}) · ${pa.capPx.toLocaleString()} px/port @ ${s.frameRate}Hz ${s.bitDepth}-bit${pr.backup ? ' · backup on' : ''}</div>`;
    o += `<div class="portgrid" style="grid-template-columns:repeat(${m.trunks ? m.portsPerDistributor : Math.min(10, Math.max(4, pa.portsAvail))}, 1fr)">`;
    const n = Math.max(pa.portsAvail, pa.maxIdx + 1);
    for (let i = 0; i < n; i++) {
      const pt = pa.ports.get(i), pct = pt ? 100 * pt.pixels / pa.capPx : 0;
      o += `<div class="port ${pt ? '' : 'free'} ${pct > 100 || i >= pa.portsAvail ? 'over' : ''}" title="${pt ? pt.panels + ' panels, ' + pt.pixels.toLocaleString() + ' px' : 'free'}">${portLabel(pr, i)}<br>${pt ? Math.round(pct) + '%' : '—'}<i style="width:${Math.min(100, pct)}%"></i></div>`;
    }
    o += `</div>`;
    const capOver = pa.maxIdx + 1 > pa.portsAvail || pa.pixelsUsed > m.maxPixels || [...pa.ports.values()].some(x => x.pixels > pa.capPx);
    if (over && !capOver) o += `<div class="note warn">Canvas placement issue — try Auto-pack on the processor or move walls in Pixel Map.</div>`;
    if (capOver) { const f = fitsModels(pa); o += `<div class="note warn">Would fit on: ${f.length ? esc(f.join(', ')) : 'no single unit — split across processors'}</div>`; }
    o += `</div>`;
  }
  o += `</div>`;

  // Sources
  if (A.sources.size) {
    o += `<h2>Media servers</h2><div class="cards">`;
    for (const sa of A.sources.values()) {
      o += `<div class="card"><h3>${esc(sa.src.name)} <small>${esc(sa.src.gpu)}</small></h3>`;
      o += bar('Outputs used', sa.used.size, sa.src.outputs.length);
      o += `<table class="t"><tr><th>Output</th><th>Res</th><th>Feeds</th></tr>${sa.src.outputs.map((out, k) => `<tr><td>OUT ${k + 1}</td><td>${out.w}×${out.h}@${out.hz}</td><td>${esc((sa.used.get(k) || []).map(x => x.name).join(', ') || '—')}</td></tr>`).join('')}</table>`;
      o += `<div class="note">Mosaic desktop ${sa.canvasW}×${sa.canvasH}</div></div>`;
    }
    o += `</div>`;
  }

  // Walls table
  o += `<h2>Walls — weight & power</h2><table class="t"><tr><th>Wall</th><th>Panel</th><th>Layout</th><th>Size</th><th>Res</th><th>Weight</th><th>kW max</th><th>kW typ</th><th>A @${v.v}V</th><th>Circuits</th><th>Data ports</th><th>Processor</th></tr>`;
  for (const wa of A.walls.values()) {
    o += `<tr><td>${esc(wa.wall.name)}</td><td>${esc(wa.pt.name)}</td><td>${wa.wall.cols}×${wa.wall.rows} (${wa.panelCount})</td><td>${fmtLen(wa.widthM, p.units)} × ${fmtLen(wa.heightM, p.units)}</td><td>${wa.resW}×${wa.resH}</td><td>${fmtKgBoth(wa.kg)}</td><td>${(wa.wMax / 1000).toFixed(2)}</td><td>${(wa.wAvg / 1000).toFixed(2)}</td><td>${(wa.wMax / v.v).toFixed(1)}</td><td>${wa.powerRuns.length}</td><td>${wa.dataRuns.length}</td><td>${esc(wa.proc?.name || '—')}</td></tr>`;
  }
  o += `<tr><th>Total</th><th></th><th>${T.panels}</th><th></th><th>${(T.pixels / 1e6).toFixed(2)} MP</th><th>${fmtKgBoth(T.kg)}</th><th>${(T.wMax / 1000).toFixed(2)}</th><th>${(T.wAvg / 1000).toFixed(2)}</th><th>${(T.wMax / v.v).toFixed(1)}</th><th>${T.circuits}</th><th>${T.dataRuns}</th><th></th></tr></table>`;

  // Power service
  o += `<h2>Power service</h2><div class="cards"><div class="card"><h3>Amps by service <small>max / typical</small></h3><table class="t">`;
  for (const k of Object.keys(T.ampsMax)) o += `<tr><td>${k}</td><td>${T.ampsMax[k].toFixed(1)} A</td><td>${T.ampsAvg[k].toFixed(1)} A</td></tr>`;
  o += `</table></div><div class="card"><h3>Circuits needed <small>${s.breakerAmps}A @ ${Math.round(s.derate * 100)}%</small></h3><table class="t"><tr><th>Wall</th>${VOLTAGES.map(x => `<th>${x.v}V</th>`).join('')}</tr>`;
  const tot = VOLTAGES.map(() => 0);
  for (const wa of A.walls.values()) {
    o += `<tr><td>${esc(wa.wall.name)}</td>${VOLTAGES.map((x, i) => { const n = Math.ceil(wa.panelCount / circuitCapacity(p, wa.pt, x.key)); tot[i] += n; return `<td>${n}</td>`; }).join('')}</tr>`;
  }
  o += `<tr><th>Total</th>${tot.map(n => `<th>${n}</th>`).join('')}</tr></table><div class="note">Minimum circuit counts with whole-panel chains. Actual auto-routing (lines) may use more.</div></div>`;
  if (s.distroThreePhase) {
    o += `<div class="card"><h3>Phase balance <small>${s.voltage === '120' ? '208Y/120 L-N' : '208 L-L'} round-robin</small></h3><table class="t">${Object.entries(T.lineAmps).map(([k, a]) => `<tr><td>${k}</td><td>${a.toFixed(1)} A</td></tr>`).join('')}</table><div class="note">Suggested feeder: ${T.feeder208 ? T.feeder208 + ' A 3Φ 208Y/120' : 'split across multiple services'}</div></div>`;
  }
  o += `</div></div>`;
  el.innerHTML = o;
  el.querySelectorAll('.issues li').forEach(li => li.onclick = () => {
    const i = A.issues[+li.dataset.n];
    if (i.ref?.wall) { ui.sel = { type: 'wall', id: i.ref.wall }; ui.wall2d = i.ref.wall; ui.tab = 'map2d'; if (i.ref.kind) ui.mode2d = i.ref.kind; }
    else if (i.ref?.proc) { ui.sel = { type: 'proc', id: i.ref.proc }; }
    renderAll();
  });
}

// ---------- exports ----------
function allSheets() {
  const p = P(), out = [systemSheet(p, A, 'S-1')];
  p.walls.forEach((w, i) => { out.push(wallSheet(p, A, w, 'data', `D-${i + 1}`)); out.push(wallSheet(p, A, w, 'power', `P-${i + 1}`)); });
  return out;
}
const safe = s => s.replace(/[\/:*?"<>|]/g, '-');

function buildCSV() {
  const p = P(), rows = [['Section', 'Item', 'Detail', 'Panels', 'Pixels', 'Load %', 'Watts max', 'Amps', 'Phase']];
  for (const wa of A.walls.values()) {
    rows.push(['Wall', wa.wall.name, `${wa.wall.cols}x${wa.wall.rows} ${wa.pt.mfr} ${wa.pt.name}; ${wa.resW}x${wa.resH}; ${Math.round(wa.kg * KG2LB)} lb`, wa.panelCount, wa.pixels, '', wa.wMax, '', '']);
    for (const r of wa.dataRuns) rows.push(['Data', wa.wall.name, r.label, r.panels.length, r.pixels, r.loadPct?.toFixed(1), '', '', '']);
    for (const r of wa.powerRuns) rows.push(['Power', wa.wall.name, r.label, r.panels.length, '', '', r.watts, r.amps.toFixed(2), r.phase || '']);
  }
  for (const pa of A.processors.values()) rows.push(['Processor', pa.proc.name, `${pa.model.name}; ports ${pa.maxIdx + 1}/${pa.portsAvail}; input ${pa.proc.inputW}x${pa.proc.inputH}`, '', pa.pixelsUsed, (100 * pa.pixelsUsed / pa.model.maxPixels).toFixed(1), '', '', '']);
  for (const i of A.issues) rows.push(['Issue', i.level, i.msg, '', '', '', '', '', '']);
  return rows.map(r => r.map(c => `"${String(c ?? '').replace(/"/g, '""')}"`).join(',')).join('\n');
}

async function act(a) {
  const p = P();
  const w = current2DWall();
  try {
    switch (a) {
      case 'new': if (confirm('Start a new project? Unsaved changes are kept in autosave only until you start editing the new one.')) { store.replace(newProject()); ui.sel = { type: 'project' }; } break;
      case 'open': {
        const f = await io.openFile('.ledwall,.json'); if (!f) return;
        store.replace(JSON.parse(await f.text())); ui.sel = { type: 'project' }; toast(`Opened ${f.name}`); break;
      }
      case 'save': await io.saveFile(`${safe(p.name)}.ledwall`, JSON.stringify(p, null, 1), 'application/json'); store.dirty = false; toast('Saved'); break;
      case 'undo': store.undo(); break;
      case 'redo': store.redo(); break;
      case 'print': io.printSheets(allSheets(), p.name); break;
      case 'exp-sheet-data': case 'exp-sheet-power': {
        if (!w) return; const k = a.endsWith('data') ? 'data' : 'power';
        await io.saveFile(`${safe(p.name)} - ${safe(w.name)} ${k}.svg`, wallSheet(p, A, w, k), 'image/svg+xml'); break;
      }
      case 'exp-sheet-png': {
        if (!w) return; const k = ui.mode2d === 'power' ? 'power' : 'data';
        await io.saveFile(`${safe(p.name)} - ${safe(w.name)} ${k}.png`, await io.svgToPng(wallSheet(p, A, w, k), 1632, 1056, 2)); break;
      }
      case 'exp-drawings-html': {
        const html = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(p.name)} — LED drawings</title><style>@page{size:17in 11in;margin:0}body{margin:0;background:#666}.sheet{width:17in;height:11in;margin:0 auto 20px;background:#fff;page-break-after:always}.sheet svg{width:100%;height:100%}@media print{body{background:#fff}.sheet{margin:0}}</style></head><body>${allSheets().map(s => `<div class="sheet">${s}</div>`).join('')}</body></html>`;
        await io.saveFile(`${safe(p.name)} drawings.html`, html, 'text/html'); break;
      }
      case 'exp-pixelmap': await exportPixelMap(); break;
      case 'exp-csv': await io.saveFile(`${safe(p.name)} resources.csv`, buildCSV(), 'text/csv'); break;
      case 'exp-3d': {
        ui.tab = 'view3d'; renderTab(); const v = await ensure3D(); await new Promise(r => setTimeout(r, 100));
        const d = v.screenshot(); const blob = await (await fetch(d)).blob();
        await io.saveFile(`${safe(p.name)} 3D.png`, blob); break;
      }
      case 'exp-lib': await io.saveFile('panel-library.json', JSON.stringify(p.panelTypes, null, 1), 'application/json'); break;
      case 'imp-lib': {
        const f = await io.openFile('.json'); if (!f) return;
        const list = JSON.parse(await f.text());
        edit(pp => { for (const t of list) if (t.pxW && t.mmW) pp.panelTypes.push({ ...t, id: uid('pt') }); });
        toast(`Imported ${list.length} panel types`); break;
      }
    }
  } catch (e) { if (e.message !== 'cancelled') toast(e.message, true); }
}

// ---------- boot ----------
function boot() {
  store.init();
  store.subscribe(() => renderAll());
  document.querySelectorAll('[data-icon]').forEach(b => b.prepend(icon(b.dataset.icon)));
  document.querySelectorAll('[data-act]').forEach(b => b.addEventListener('click', () => { document.activeElement?.blur(); document.querySelector('.menu.open')?.classList.remove('open'); act(b.dataset.act); }));
  // Toolbar menus open on click, like an NSMenu; any outside click closes them.
  document.querySelectorAll('.menu > button').forEach(b => b.addEventListener('click', e => { e.stopPropagation(); b.parentElement.classList.toggle('open'); }));
  document.addEventListener('click', e => { const m = document.querySelector('.menu.open'); if (m && !m.contains(e.target)) m.classList.remove('open'); });
  document.querySelectorAll('#tabs button').forEach(b => b.addEventListener('click', () => { ui.tab = b.dataset.tab; renderTab(); }));
  $('#projName').addEventListener('change', e => edit(p => { p.name = e.target.value; }));
  document.addEventListener('keydown', e => {
    const inField = /INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName);
    if (e.metaKey && e.key.toLowerCase() === 'z' && !inField) { e.preventDefault(); e.shiftKey ? store.redo() : store.undo(); }
    else if (e.metaKey && e.key === 's') { e.preventDefault(); act('save'); }
    else if (e.metaKey && e.key === 'o') { e.preventDefault(); act('open'); }
    else if (e.metaKey && e.key === 'p') { e.preventDefault(); act('print'); }
    else if (!inField && ui.tab === 'map2d' && ['1', '2', '3'].includes(e.key)) { ui.mode2d = ['data', 'power', 'structure'][+e.key - 1]; render2D(); }
  });
  window.addEventListener('resize', () => { if (ui.tab === 'pixmap') renderPixMap(); });
  window.__app = { store, ui, get A() { return A; }, renderAll };
  renderAll();
}
boot();
