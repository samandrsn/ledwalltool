import { PANEL_LIBRARY, PROCESSOR_MODELS, RUN_COLORS } from './catalog.js';

export const uid = (p = 'id') => p + '_' + Math.random().toString(36).slice(2, 9);

const WALL_COLORS = ['#4f8cff', '#ff9f43', '#2ed573', '#a29bfe', '#ff6b81', '#1dd1a1', '#feca57', '#54a0ff'];

export function newPanelType(src = PANEL_LIBRARY[0]) {
  const { key, ...rest } = src;
  return { id: uid('pt'), libKey: key || null, ...rest };
}

export function newWall(project, opts = {}) {
  const n = project.walls.length;
  const cols = opts.cols ?? 12, rows = opts.rows ?? 6;
  return {
    id: uid('w'),
    name: opts.name ?? `Wall ${n + 1}`,
    color: WALL_COLORS[n % WALL_COLORS.length],
    panelTypeId: opts.panelTypeId ?? project.panelTypes[0]?.id,
    cols, rows,
    pos: { x: opts.x ?? n * 8, y: 0, z: 0 },
    rot: { yaw: 0, pitch: 0, roll: 0 },
    colAngles: Array(cols - 1).fill(0),
    rowAngles: Array(rows - 1).fill(0),
    attach: null, // { wallId, edge: 'top'|'bottom'|'left'|'right', angle, offset }
    disabled: [], // ["c,r"]
    rigging: 'ground', // ground | flown
    extraKgPerPanel: 0,
    processorId: null,
    canvas: { x: 0, y: 0 },
    data: { mode: 'auto', pattern: { preset: 'recommend' }, runs: [] },
    power: { mode: 'auto', pattern: { preset: 'recommend' }, runs: [] },
  };
}

export function newProcessor(project, model = 'brompton-sx40') {
  const m = PROCESSOR_MODELS[model];
  const n = project.processors.length;
  return {
    id: uid('p'),
    name: `Processor ${n + 1}`,
    code: String(n + 1),
    model,
    inputW: Math.min(m.maxInputW, 3840), inputH: Math.min(m.maxInputH, 2160),
    distributors: m.trunks ? Math.min(2, m.trunks) : 0, // house standard: 2 distros per processor (1A, 1B)
    autoDistributors: false,
    backup: false,
    portPixelsOverride: 0,
    sourceId: null, sourceOutput: 0,
  };
}

export function newSource(project) {
  const n = project.sources.length;
  return {
    id: uid('s'),
    name: `Media Server ${n + 1}`,
    gpu: 'NVIDIA Quadro / RTX (4× DP)',
    outputs: Array.from({ length: 4 }, () => ({ w: 3840, h: 2160, hz: 60 })),
    mosaic: { cols: 4, rows: 1 },
  };
}

export function newProject() {
  const p = {
    version: 1,
    name: 'Untitled Set',
    client: '', venue: '', designer: '',
    units: 'imperial',
    settings: { frameRate: 60, bitDepth: 8, voltage: '208', breakerAmps: 20, derate: 0.8, powerBasis: 'max', distroThreePhase: true },
    panelTypes: [],
    walls: [], processors: [], sources: [],
    room: null, // { name, scale, offset:{x,y,z}, rotY, opacity } (model kept in memory/IndexedDB)
  };
  p.panelTypes.push(newPanelType(PANEL_LIBRARY[0]));
  p.panelTypes.push(newPanelType(PANEL_LIBRARY[2]));
  const src = newSource(p); p.sources.push(src);
  const proc = newProcessor(p); proc.sourceId = src.id; p.processors.push(proc);
  const w = newWall(p, { name: 'Main Wall', cols: 16, rows: 8, x: -4 });
  w.processorId = proc.id;
  p.walls.push(w);
  return p;
}

export function migrate(p) {
  p.settings = { frameRate: 60, bitDepth: 8, voltage: '208', breakerAmps: 20, derate: 0.8, powerBasis: 'max', distroThreePhase: true, ...(p.settings || {}) };
  p.sources ||= []; p.processors ||= []; p.walls ||= []; p.panelTypes ||= [];
  // Older projects lettered processors (A, B…); house convention is numbers with lettered distros (1A, 1B).
  p.processors.forEach((pr, i) => {
    if (/^[A-Z]$/.test(pr.code || '')) { const n = String(pr.code.charCodeAt(0) - 64); if (pr.name === `Processor ${pr.code}`) pr.name = `Processor ${n}`; pr.code = n; }
  });
  for (const w of p.walls) {
    w.colAngles ||= []; w.rowAngles ||= [];
    resizeAngles(w);
    w.disabled ||= [];
    w.data ||= { mode: 'auto', pattern: { preset: 'recommend' }, runs: [] };
    w.power ||= { mode: 'auto', pattern: { preset: 'recommend' }, runs: [] };
    w.canvas ||= { x: 0, y: 0 };
    w.rot ||= { yaw: 0, pitch: 0, roll: 0 };
  }
  return p;
}

export function resizeAngles(w) {
  const fit = (arr, n) => { arr = arr.slice(0, n); while (arr.length < n) arr.push(0); return arr; };
  w.colAngles = fit(w.colAngles || [], Math.max(0, w.cols - 1));
  w.rowAngles = fit(w.rowAngles || [], Math.max(0, w.rows - 1));
  w.disabled = (w.disabled || []).filter(k => { const [c, r] = k.split(',').map(Number); return c < w.cols && r < w.rows; });
}

export const runColor = i => RUN_COLORS[i % RUN_COLORS.length];

// ---------- store with undo ----------
const LS_KEY = 'ledwalltool.autosave.v1';

export const store = {
  project: null,
  undoStack: [], redoStack: [],
  listeners: new Set(),
  filePath: null,
  dirty: false,

  init() {
    let p = null;
    try { const s = localStorage.getItem(LS_KEY); if (s) p = migrate(JSON.parse(s)); } catch (e) { /* ignore */ }
    this.project = p || newProject();
  },
  subscribe(fn) { this.listeners.add(fn); },
  emit(reason) { for (const fn of this.listeners) fn(reason); },
  snapshot() { return JSON.stringify(this.project); },
  // Run a mutation as one undoable step.
  commit(fn, reason = 'edit') {
    const before = this.snapshot();
    fn(this.project);
    this.undoStack.push(before);
    if (this.undoStack.length > 150) this.undoStack.shift();
    this.redoStack = [];
    this.dirty = true;
    this.save();
    this.emit(reason);
  },
  undo() {
    if (!this.undoStack.length) return;
    this.redoStack.push(this.snapshot());
    this.project = JSON.parse(this.undoStack.pop());
    this.save(); this.emit('undo');
  },
  redo() {
    if (!this.redoStack.length) return;
    this.undoStack.push(this.snapshot());
    this.project = JSON.parse(this.redoStack.pop());
    this.save(); this.emit('redo');
  },
  replace(p) {
    this.undoStack = []; this.redoStack = [];
    this.project = migrate(p);
    this.dirty = false;
    this.save(); this.emit('load');
  },
  save() {
    try { localStorage.setItem(LS_KEY, this.snapshot()); } catch (e) { /* quota */ }
  },
};

export const byId = (arr, id) => arr.find(x => x.id === id);
