// File I/O. Uses the native Mac shell bridge when present, browser download otherwise.
const native = () => window.webkit?.messageHandlers?.native;

let reqId = 0;
const pending = new Map();
window.__nativeReply = (id, ok, value) => { const p = pending.get(id); if (p) { pending.delete(id); ok ? p.res(value) : p.rej(new Error(value)); } };
function call(msg) {
  return new Promise((res, rej) => { const id = ++reqId; pending.set(id, { res, rej }); native().postMessage({ ...msg, id }); });
}

const toB64 = async blob => {
  const buf = new Uint8Array(await blob.arrayBuffer());
  let s = ''; for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
  return btoa(s);
};

export async function saveFile(name, data, mime = 'application/octet-stream') {
  const blob = data instanceof Blob ? data : new Blob([data], { type: mime });
  if (native()) return call({ cmd: 'save', name, b64: await toB64(blob) });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  return name;
}

export function openFile(accept) {
  return new Promise(res => {
    const inp = document.createElement('input');
    inp.type = 'file'; inp.accept = accept;
    inp.onchange = () => res(inp.files[0] || null);
    inp.click();
  });
}

// Print a set of SVG sheets (one per page, 17x11 landscape).
export function printSheets(svgs, title = 'LED Wall Drawings') {
  const host = document.getElementById('print-host');
  host.innerHTML = svgs.map(s => `<div class="sheet">${s}</div>`).join('');
  document.title = title;
  setTimeout(() => {
    if (native()) native().postMessage({ cmd: 'print' });
    else window.print();
  }, 50);
}

export async function svgToPng(svg, w, h, scale = 2) {
  const img = new Image();
  const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }));
  await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = url; });
  const c = document.createElement('canvas'); c.width = w * scale; c.height = h * scale;
  const ctx = c.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);
  ctx.drawImage(img, 0, 0, c.width, c.height);
  URL.revokeObjectURL(url);
  return new Promise(res => c.toBlob(res, 'image/png'));
}

export const canvasToBlob = c => new Promise(res => c.toBlob(res, 'image/png'));
export const isNative = () => !!native();
