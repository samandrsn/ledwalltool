// Panel geometry. Units: meters. Y up, walls face +Z (audience side).
// Matrices are column-major Float64 4x4 (same layout as three.js).
//
// Column hinge angle > 0 = concave (wall wraps toward the audience), < 0 = convex.
// Row hinge angle > 0 = upper rows tilt toward the audience.

import { byId } from './model.js';

const D2R = Math.PI / 180;

export const I = () => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
export function mul(a, b) {
  const o = new Array(16);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) {
    o[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
  }
  return o;
}
export const T = (x, y, z) => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1];
export const Rx = d => { const a = d * D2R, c = Math.cos(a), s = Math.sin(a); return [1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]; };
export const Ry = d => { const a = d * D2R, c = Math.cos(a), s = Math.sin(a); return [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]; };
export const Rz = d => { const a = d * D2R, c = Math.cos(a), s = Math.sin(a); return [c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; };
export const apply = (m, [x, y, z]) => [
  m[0] * x + m[4] * y + m[8] * z + m[12],
  m[1] * x + m[5] * y + m[9] * z + m[13],
  m[2] * x + m[6] * y + m[10] * z + m[14],
];
// Inverse of a rigid transform.
export function rigidInv(m) {
  const r = [m[0], m[4], m[8], 0, m[1], m[5], m[9], 0, m[2], m[6], m[10], 0, 0, 0, 0, 1];
  const t = apply(r, [m[12], m[13], m[14]]);
  r[12] = -t[0]; r[13] = -t[1]; r[14] = -t[2];
  return r;
}

export const panelDims = pt => ({ w: pt.mmW / 1000, h: pt.mmH / 1000, d: (pt.mmD || 80) / 1000 });

// Local column walk (no base frame): frames at the bottom-left of each column, plus the end frame.
function colWalk(wall, w) {
  const frames = [I()];
  for (let c = 0; c < wall.cols; c++) {
    const ang = c < wall.cols - 1 ? (wall.colAngles[c] || 0) : 0;
    frames.push(mul(mul(frames[c], T(w, 0, 0)), Ry(-ang)));
  }
  return frames; // length cols+1, last = right edge
}
function rowWalk(wall, h) {
  const frames = [I()];
  for (let r = 0; r < wall.rows; r++) {
    const ang = r < wall.rows - 1 ? (wall.rowAngles[r] || 0) : 0;
    frames.push(mul(mul(frames[r], T(0, h, 0)), Rx(ang)));
  }
  return frames;
}

export function computeGeometry(project) {
  const out = new Map();
  const visiting = new Set();

  function wallBase(wall) {
    return mul(mul(mul(T(wall.pos.x, wall.pos.y, wall.pos.z), Ry(wall.rot.yaw || 0)), Rx(wall.rot.pitch || 0)), Rz(wall.rot.roll || 0));
  }

  function build(wall) {
    if (out.has(wall.id)) return out.get(wall.id);
    const pt = byId(project.panelTypes, wall.panelTypeId) || project.panelTypes[0];
    const { w, h, d } = panelDims(pt);
    const cw = colWalk(wall, w), rw = rowWalk(wall, h);
    let colFrames;
    const a = wall.attach;
    const parent = a && !visiting.has(a.wallId) ? byId(project.walls, a.wallId) : null;
    visiting.add(wall.id);
    if (parent && parent.id !== wall.id) {
      const pg = build(parent);
      const ang = a.angle || 0;
      if (a.edge === 'top') {
        const off = Math.round(a.offset || 0);
        colFrames = [];
        for (let c = 0; c <= wall.cols; c++) {
          const pc = c + off;
          if (pc >= 0 && pc <= parent.cols) colFrames.push(mul(mul(pg.colFrames[pc], pg.rowTop), Rx(ang)));
          else if (c > 0) colFrames.push(mul(mul(colFrames[c - 1], T(w, 0, 0)), Ry(-(wall.colAngles[c - 1] || 0))));
          else colFrames.push(mul(mul(mul(pg.colFrames[0], pg.rowTop), Rx(ang)), T(off * w, 0, 0)));
        }
      } else if (a.edge === 'left') {
        const target = mul(mul(pg.colFrames[0], T(0, a.offset || 0, 0)), Ry(ang));
        const base = mul(target, rigidInv(cw[wall.cols]));
        colFrames = cw.map(f => mul(base, f));
      } else { // right
        const base = mul(mul(pg.colFrames[parent.cols], T(0, a.offset || 0, 0)), Ry(-ang));
        colFrames = cw.map(f => mul(base, f));
      }
    } else {
      const base = wallBase(wall);
      colFrames = cw.map(f => mul(base, f));
    }
    visiting.delete(wall.id);
    const g = {
      pt, w, h, d, colFrames, rowFrames: rw, rowTop: rw[wall.rows],
      panel(c, r) { return mul(colFrames[c], rw[r]); },
      center(c, r) { return apply(this.panel(c, r), [w / 2, h / 2, 0]); },
      localCols: cw,
    };
    out.set(wall.id, g);
    return g;
  }
  for (const wall of project.walls) build(wall);
  return out;
}

// Plan (top) view polyline of the wall's bottom edge in its own local frame.
export function planPolyline(wall, pt) {
  const { w } = panelDims(pt);
  return colWalk(wall, w).map(f => [f[12], f[14]]);
}

// Section (side) polyline of the wall's left edge in its own local frame.
export function sectionPolyline(wall, pt) {
  const { h } = panelDims(pt);
  return rowWalk(wall, h).map(f => [f[14], f[13]]);
}

// Chord / radius helpers for uniform curves.
export const angleForRadius = (panelW, R) => 2 * Math.asin(Math.min(1, panelW / (2 * R))) / D2R;
export const radiusForAngle = (panelW, deg) => deg === 0 ? Infinity : panelW / (2 * Math.sin(Math.abs(deg) * D2R / 2));
