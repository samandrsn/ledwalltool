// Data & power run generation. A "run" is an ordered chain of panels: one data port
// or one power circuit. Coordinates: c = column (0 = left), r = row (0 = bottom).

export const PRESETS = {
  recommend: { label: 'Auto-recommend' },
  snakeV:  { label: 'N — vertical snake', primary: 'cols', serpentine: true },
  snakeH:  { label: 'S — horizontal snake (zig-zag)', primary: 'rows', serpentine: true },
  rasterV: { label: 'Straight vertical (up/down)', primary: 'cols', serpentine: false },
  rasterH: { label: 'Z — straight horizontal', primary: 'rows', serpentine: false },
  uV:      { label: 'U — vertical, returns to start edge', primary: 'cols', serpentine: true, even: true },
  cH:      { label: 'C — horizontal, returns to start side', primary: 'rows', serpentine: true, even: true },
  centerV: { label: 'Center-out vertical snake', primary: 'cols', serpentine: true, fromCenter: true },
  centerH: { label: 'Center-out horizontal snake', primary: 'rows', serpentine: true, fromCenter: true },
};

export const CHUNKS = {
  lines: 'Whole lines per run',
  fill: 'Fill each run to max',
  balanced: 'Balanced (equal runs)',
};

export const key = (c, r) => c + ',' + r;

function enabledSet(wall) {
  const dis = new Set(wall.disabled || []);
  return (c, r) => !dis.has(key(c, r));
}

// Returns groups -> lines -> panels, each line ordered forward from the start edge.
function buildLines(wall, { primary, start, fromCenter }) {
  const ok = enabledSet(wall);
  const left = start.includes('L'), bottom = start.includes('B');
  const range = (n, fwd) => Array.from({ length: n }, (_, i) => fwd ? i : n - 1 - i);
  const mid = Math.ceil(wall.cols / 2);
  const groups = [];
  if (primary === 'cols') {
    const colLine = c => range(wall.rows, bottom).map(r => [c, r]).filter(([c, r]) => ok(c, r));
    if (fromCenter && wall.cols > 1) {
      const L = []; for (let c = mid - 1; c >= 0; c--) L.push(colLine(c));
      const R = []; for (let c = mid; c < wall.cols; c++) R.push(colLine(c));
      groups.push(L, R);
    } else groups.push(range(wall.cols, left).map(colLine));
  } else {
    const rowsOrder = range(wall.rows, bottom);
    if (fromCenter && wall.cols > 1) {
      const L = rowsOrder.map(r => { const a = []; for (let c = mid - 1; c >= 0; c--) a.push([c, r]); return a.filter(p => ok(...p)); });
      const R = rowsOrder.map(r => { const a = []; for (let c = mid; c < wall.cols; c++) a.push([c, r]); return a.filter(p => ok(...p)); });
      groups.push(L, R);
    } else groups.push(rowsOrder.map(r => range(wall.cols, left).map(c => [c, r]).filter(p => ok(...p))));
  }
  return groups.map(g => g.filter(l => l.length));
}

function snake(lines, serpentine) {
  const out = [];
  lines.forEach((l, i) => out.push(...(serpentine && i % 2 ? [...l].reverse() : l)));
  return out;
}

function chunkGroup(lines, cap, chunk, serpentine, even) {
  const total = lines.reduce((s, l) => s + l.length, 0);
  if (!total) return [];
  if (chunk === 'fill' || chunk === 'balanced') {
    const path = snake(lines, serpentine);
    const size = chunk === 'balanced' ? Math.ceil(total / Math.ceil(total / cap)) : cap;
    const runs = [];
    for (let i = 0; i < path.length; i += size) runs.push(path.slice(i, i + size));
    return runs;
  }
  // whole lines
  const runs = [];
  let cur = [];
  const count = ls => ls.reduce((s, l) => s + l.length, 0);
  const flush = () => {
    if (!cur.length) return;
    let carry = null;
    if (even && cur.length > 1 && cur.length % 2) carry = cur.pop();
    runs.push(snake(cur, serpentine));
    cur = carry ? [carry] : [];
  };
  for (const line of lines) {
    if (line.length > cap) {
      flush(); flush();
      for (let i = 0; i < line.length; i += cap) runs.push(line.slice(i, i + cap));
      continue;
    }
    if (count(cur) + line.length > cap) flush();
    if (count(cur) + line.length > cap) flush();
    cur.push(line);
  }
  flush(); flush();
  return runs;
}

export function generateRuns(wall, cap, pattern) {
  cap = Math.max(1, cap | 0);
  const p = { ...PRESETS[pattern.preset] || {}, ...pattern };
  const start = p.start || (wall.rigging === 'flown' ? 'TL' : 'BL');
  if (pattern.preset === 'recommend' || !pattern.preset) return recommend(wall, cap, pattern, start).runs;
  const chunk = p.chunk || 'lines';
  const effCap = pattern.maxPerRun > 0 ? Math.min(cap, pattern.maxPerRun) : cap;
  const groups = buildLines(wall, { primary: p.primary, start, fromCenter: p.fromCenter });
  return groups.flatMap(g => chunkGroup(g, effCap, chunk, p.serpentine, p.even));
}

export function recommend(wall, cap, pattern = {}, start) {
  start = start || pattern.start || (wall.rigging === 'flown' ? 'TL' : 'BL');
  const effCap = pattern.maxPerRun > 0 ? Math.min(cap, pattern.maxPerRun) : cap;
  let best = null;
  for (const primary of ['cols', 'rows']) {
    for (const chunk of ['lines', 'balanced']) {
      const groups = buildLines(wall, { primary, start, fromCenter: false });
      const runs = groups.flatMap(g => chunkGroup(g, effCap, chunk, true, false));
      // Prefer fewest runs, then whole-line runs, then vertical snakes.
      const score = runs.length * 100 + (chunk === 'balanced' ? 30 : 0) + (primary === 'rows' ? 1 : 0);
      if (!best || score < best.score) best = { score, runs, primary, chunk, start };
    }
  }
  return best;
}

export function describeRecommendation(wall, cap, pattern) {
  const b = recommend(wall, cap, pattern);
  if (!b) return '';
  return `${b.primary === 'cols' ? 'Vertical (N)' : 'Horizontal (S)'} snake from ${b.start}, ${b.chunk === 'lines' ? 'whole lines' : 'balanced fill'} → ${b.runs.length} runs`;
}

// Resolve the runs for a wall + kind ('data'|'power').
export function resolveRuns(wall, kind, cap) {
  const cfg = wall[kind];
  if (cfg.mode === 'custom') {
    const dis = new Set(wall.disabled);
    return cfg.runs.map(run => ({ ...run, panels: run.panels.filter(([c, r]) => c < wall.cols && r < wall.rows && !dis.has(key(c, r))) }));
  }
  return generateRuns(wall, cap, cfg.pattern).map(panels => ({ panels, port: null }));
}
