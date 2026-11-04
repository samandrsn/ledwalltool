import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { computeGeometry } from './geometry.js';
import { runColor } from './model.js';

let renderer, scene, camera, controls, wallGroup, roomGroup, host, raycaster, pathGroup;
let framePending = false;
let pickTargets = [];
let onPick = null;
let fitted = false;

export function init3D(el, pickCb) {
  host = el; onPick = pickCb;
  renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
  renderer.setPixelRatio(Math.min(2, window.devicePixelRatio));
  el.appendChild(renderer.domElement);
  scene = new THREE.Scene();
  scene.background = new THREE.Color(0x14161a);
  camera = new THREE.PerspectiveCamera(45, 1, 0.05, 2000);
  camera.position.set(0, 6, 22);
  controls = new OrbitControls(camera, renderer.domElement);
  controls.target.set(0, 2, 0);
  controls.addEventListener('change', requestRender);
  scene.add(new THREE.HemisphereLight(0xffffff, 0x334455, 1.6));
  const dl = new THREE.DirectionalLight(0xffffff, 1.2); dl.position.set(5, 10, 8); scene.add(dl);
  const grid = new THREE.GridHelper(100, 100, 0x3a3f48, 0x24272d); scene.add(grid);
  // 1.8 m person for scale
  const person = new THREE.Mesh(new THREE.CapsuleGeometry(0.22, 1.36, 4, 8), new THREE.MeshStandardMaterial({ color: 0x8892a0 }));
  person.position.set(0, 0.9, 4); person.name = 'person'; scene.add(person);
  wallGroup = new THREE.Group(); scene.add(wallGroup);
  pathGroup = new THREE.Group(); scene.add(pathGroup);
  roomGroup = new THREE.Group(); scene.add(roomGroup);
  raycaster = new THREE.Raycaster();

  let down = null;
  renderer.domElement.addEventListener('pointerdown', e => down = [e.clientX, e.clientY]);
  renderer.domElement.addEventListener('pointerup', e => {
    if (!down || Math.hypot(e.clientX - down[0], e.clientY - down[1]) > 4) return;
    const r = renderer.domElement.getBoundingClientRect();
    raycaster.setFromCamera(new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1), camera);
    const hit = raycaster.intersectObjects(pickTargets, false)[0];
    if (hit && onPick) onPick(hit.object.userData.wallId);
  });
  new ResizeObserver(resize).observe(el);
  resize();
  requestRender();
}

function resize() {
  if (!host) return;
  const w = host.clientWidth, h = host.clientHeight;
  if (!w || !h) return;
  renderer.setSize(w, h, false);
  renderer.domElement.style.width = w + 'px'; renderer.domElement.style.height = h + 'px';
  camera.aspect = w / h; camera.updateProjectionMatrix();
  requestRender();
}

// Render on demand only — no idle frame loop.
function requestRender() {
  if (framePending) return;
  framePending = true;
  requestAnimationFrame(() => { framePending = false; if (host.offsetParent !== null) renderer.render(scene, camera); });
}

export function poke() { resize(); requestRender(); }

function disposeGroup(g) {
  g.traverse(o => { o.geometry?.dispose(); if (o.material) [].concat(o.material).forEach(m => m.dispose()); });
  g.clear();
}

// colorMode: 'wall' | 'data' | 'power'
export function update3D(project, A, { colorMode = 'wall', selectedWallId = null, showPaths = true } = {}) {
  if (!scene) return;
  disposeGroup(wallGroup); disposeGroup(pathGroup);
  pickTargets = [];
  const geo = computeGeometry(project);
  const m4 = new THREE.Matrix4(), off = new THREE.Matrix4(), col = new THREE.Color();
  const box = new THREE.Box3();
  for (const wall of project.walls) {
    const g = geo.get(wall.id), wa = A.walls.get(wall.id);
    if (!g || !wa) continue;
    const dis = new Set(wall.disabled);
    const count = wall.cols * wall.rows - dis.size;
    if (count <= 0) continue;
    const gap = 0.004;
    const bg = new THREE.BoxGeometry(g.w - gap, g.h - gap, g.d);
    const mat = new THREE.MeshStandardMaterial({ roughness: 0.6, metalness: 0.1 });
    const mesh = new THREE.InstancedMesh(bg, mat, count);
    mesh.userData.wallId = wall.id;
    const runIdx = new Map();
    const runs = colorMode === 'data' ? wa.dataRuns : colorMode === 'power' ? wa.powerRuns : null;
    runs?.forEach((run, ri) => run.panels.forEach(([c, r]) => runIdx.set(c + ',' + r, ri)));
    off.makeTranslation(g.w / 2, g.h / 2, -g.d / 2);
    let i = 0;
    for (let c = 0; c < wall.cols; c++) for (let r = 0; r < wall.rows; r++) {
      const k = c + ',' + r; if (dis.has(k)) continue;
      m4.fromArray(g.panel(c, r)).multiply(off);
      mesh.setMatrixAt(i, m4);
      if (runs) { const ri = runIdx.get(k); col.set(ri == null ? '#333' : runColor(ri + (colorMode === 'power' ? 3 : 0))); }
      else { col.set(wall.color); col.offsetHSL(0, 0, ((c + r) % 2) * 0.06 - 0.03); }
      if (selectedWallId && wall.id !== selectedWallId) col.multiplyScalar(0.45);
      mesh.setColorAt(i, col);
      i++;
    }
    mesh.instanceMatrix.needsUpdate = true;
    if (mesh.instanceColor) mesh.instanceColor.needsUpdate = true;
    mesh.computeBoundingSphere(); mesh.computeBoundingBox();
    wallGroup.add(mesh); pickTargets.push(mesh);
    box.union(new THREE.Box3().setFromObject(mesh));

    if (runs && showPaths) {
      for (const [ri, run] of runs.entries()) {
        if (run.panels.length < 1) continue;
        const pts = run.panels.map(([c, r]) => { const p = new THREE.Vector3(g.w / 2, g.h / 2, 0.01).applyMatrix4(m4.fromArray(g.panel(c, r))); return p; });
        const lg = new THREE.BufferGeometry().setFromPoints(pts);
        pathGroup.add(new THREE.Line(lg, new THREE.LineBasicMaterial({ color: 0xffffff })));
        const s = new THREE.Mesh(new THREE.SphereGeometry(Math.min(g.w, g.h) * 0.1, 10, 8), new THREE.MeshBasicMaterial({ color: 0xffffff }));
        s.position.copy(pts[0]); pathGroup.add(s);
      }
    }
  }
  if (!fitted && !box.isEmpty()) { fitTo(box); fitted = true; }
  requestRender();
}

function fitTo(box) {
  const c = box.getCenter(new THREE.Vector3()), size = box.getSize(new THREE.Vector3());
  const d = Math.max(size.x, size.y, size.z) * 1.4 + 4;
  controls.target.copy(c);
  camera.position.set(c.x, c.y + d * 0.25, c.z + d);
  controls.update();
}

export function frameAll() {
  const box = new THREE.Box3().setFromObject(wallGroup);
  if (!box.isEmpty()) fitTo(box);
  requestRender();
}

export function setView(name) {
  const box = new THREE.Box3().setFromObject(wallGroup);
  const c = box.isEmpty() ? new THREE.Vector3() : box.getCenter(new THREE.Vector3());
  const d = box.isEmpty() ? 20 : Math.max(...box.getSize(new THREE.Vector3()).toArray()) * 1.5 + 4;
  controls.target.copy(c);
  if (name === 'top') camera.position.set(c.x, c.y + d, c.z + 0.001);
  else if (name === 'front') camera.position.set(c.x, c.y, c.z + d);
  else if (name === 'side') camera.position.set(c.x + d, c.y, c.z);
  controls.update(); requestRender();
}

export function screenshot() {
  renderer.render(scene, camera);
  return renderer.domElement.toDataURL('image/png');
}

// ---- room model import (SketchUp exports: .dae, .obj, .glb/.gltf, .stl, .fbx)
let roomObj = null;
export async function loadRoom(file) {
  const name = file.name.toLowerCase();
  const buf = await file.arrayBuffer();
  let obj;
  if (name.endsWith('.dae')) {
    const { ColladaLoader } = await import('three/addons/loaders/ColladaLoader.js');
    obj = new ColladaLoader().parse(new TextDecoder().decode(buf), '').scene;
  } else if (name.endsWith('.obj')) {
    const { OBJLoader } = await import('three/addons/loaders/OBJLoader.js');
    obj = new OBJLoader().parse(new TextDecoder().decode(buf));
  } else if (name.endsWith('.glb') || name.endsWith('.gltf')) {
    const { GLTFLoader } = await import('three/addons/loaders/GLTFLoader.js');
    obj = await new Promise((res, rej) => new GLTFLoader().parse(buf, '', g => res(g.scene), rej));
  } else if (name.endsWith('.stl')) {
    const { STLLoader } = await import('three/addons/loaders/STLLoader.js');
    obj = new THREE.Mesh(new STLLoader().parse(buf), new THREE.MeshStandardMaterial({ color: 0x9aa3ad }));
  } else if (name.endsWith('.fbx')) {
    const { FBXLoader } = await import('three/addons/loaders/FBXLoader.js');
    obj = new FBXLoader().parse(buf, '');
  } else if (name.endsWith('.skp')) {
    throw new Error('SketchUp .skp is a closed format. In SketchUp use File → Export → 3D Model → COLLADA (.dae), OBJ or glTF, then import that file.');
  } else throw new Error('Unsupported model format');
  disposeGroup(roomGroup);
  roomObj = obj;
  roomGroup.add(obj);
  requestRender();
  const box = new THREE.Box3().setFromObject(obj);
  return { size: box.getSize(new THREE.Vector3()).toArray() };
}

export function applyRoom(room) {
  if (!roomObj || !room) { roomGroup.visible = !!roomObj; requestRender(); return; }
  roomGroup.visible = room.visible !== false;
  roomGroup.scale.setScalar(room.scale || 1);
  roomGroup.position.set(room.offset?.x || 0, room.offset?.y || 0, room.offset?.z || 0);
  roomGroup.rotation.set(0, (room.rotY || 0) * Math.PI / 180, 0);
  roomObj.traverse(o => {
    if (!o.isMesh) return;
    for (const m of [].concat(o.material)) { m.transparent = (room.opacity ?? 1) < 1; m.opacity = room.opacity ?? 1; m.depthWrite = (room.opacity ?? 1) >= 1; m.side = THREE.DoubleSide; }
  });
  requestRender();
}
export const hasRoom = () => !!roomObj;
export function clearRoom() { disposeGroup(roomGroup); roomObj = null; requestRender(); }
