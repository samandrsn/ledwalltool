// SF Symbols–style line icons, 16×16, drawn with currentColor.
const P = {
  plus: 'M8 3.5v9M3.5 8h9',
  close: 'M4.5 4.5l7 7M11.5 4.5l-7 7',
  chevron: 'M4.5 6.5L8 10l3.5-3.5',
  undo: 'M6 3.5L3 6.5l3 3M3.5 6.5H10a3 3 0 0 1 0 6H7.5',
  redo: 'M10 3.5l3 3-3 3M12.5 6.5H6a3 3 0 0 0 0 6h2.5',
  new: 'M9 2.5H4.5a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V6L9 2.5zM9 2.5V6h3.5M8 8v4M6 10h4',
  open: 'M2.5 4.5a1 1 0 0 1 1-1h3l1.5 1.5h4.5a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1z',
  save: 'M8 2.5v7M5 6.5l3 3 3-3M3 10.5v1.5a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-1.5',
  print: 'M4.5 6V2.5h7V6M4.5 11h-1a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h9a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1h-1M4.5 9h7v4.5h-7z',
  export: 'M8 9.5v-7M5 5.5l3-3 3 3M5.5 7.5H4a1 1 0 0 0-1 1v4a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-4a1 1 0 0 0-1-1h-1.5',
  project: 'M4 2.5h8a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1zM5.5 5.5h5M5.5 8h5M5.5 10.5h3',
  wall: 'M2.5 3.5h11v9h-11zM2.5 6.5h11M2.5 9.5h11M6.2 3.5v9M9.8 3.5v9',
  processor: 'M4.5 4.5h7v7h-7zM6.5 2v2.5M9.5 2v2.5M6.5 11.5V14M9.5 11.5V14M2 6.5h2.5M2 9.5h2.5M11.5 6.5H14M11.5 9.5H14',
  server: 'M2.5 3h11v7.5h-11zM6 13.5h4M8 10.5v3',
  panel: 'M3 3h4v4H3zM9 3h4v4H9zM3 9h4v4H3zM9 9h4v4H9z',
  fit: 'M3 6V3h3M10 3h3v3M13 10v3h-3M6 13H3v-3',
  settings: 'M2.5 5h6M11.5 5h2M2.5 11h2M7.5 11h6M10 3.5v3M6 9.5v3',
};

export function icon(name, cls = '') {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  s.setAttribute('viewBox', '0 0 16 16');
  s.setAttribute('class', ('ic ' + cls).trim());
  s.setAttribute('aria-hidden', 'true');
  s.innerHTML = `<path d="${P[name] || ''}"/>`;
  return s;
}
export const iconHTML = (name, cls = '') => `<svg viewBox="0 0 16 16" class="ic ${cls}" aria-hidden="true"><path d="${P[name] || ''}"/></svg>`;
