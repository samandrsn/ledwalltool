// Keeps the last imported room model in IndexedDB so it survives relaunches.
const DB = 'ledwalltool', STORE = 'files', KEY = 'room';

function db() {
  return new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
  });
}
async function tx(mode, fn) {
  const d = await db();
  return new Promise((res, rej) => { const t = d.transaction(STORE, mode); const r = fn(t.objectStore(STORE)); t.oncomplete = () => res(r?.result); t.onerror = () => rej(t.error); });
}
export const put = file => file.arrayBuffer().then(buf => tx('readwrite', s => s.put({ name: file.name, buf }, KEY)));
export const clear = () => tx('readwrite', s => s.delete(KEY)).catch(() => {});
export async function get() {
  const v = await tx('readonly', s => s.get(KEY));
  if (!v) return null;
  return { name: v.name, arrayBuffer: async () => v.buf };
}
