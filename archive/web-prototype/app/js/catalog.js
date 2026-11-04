// Device catalogs. Spec values are typical/published figures and MUST be verified
// against current manufacturer spec sheets before deployment. Everything here is
// editable per-project (panel library + processor overrides).

export const PANEL_LIBRARY = [
  // Unilumin
  { key: 'uni-upad4-26-500', mfr: 'Unilumin', name: 'UPAD IV 2.6 (500×500)', pxW: 192, pxH: 192, mmW: 500, mmH: 500, mmD: 79, kg: 7.5, wMax: 160, wAvg: 55, maxPerPort: 0, maxPerPowerLink: 0 },
  { key: 'uni-upad4-26-1000', mfr: 'Unilumin', name: 'UPAD IV 2.6 (500×1000)', pxW: 192, pxH: 384, mmW: 500, mmH: 1000, mmD: 79, kg: 13.5, wMax: 320, wAvg: 110, maxPerPort: 0, maxPerPowerLink: 0 },
  // Absen
  { key: 'absen-pl39xl', mfr: 'Absen', name: 'Polaris PL3.9 XL (500×1000)', pxW: 128, pxH: 256, mmW: 500, mmH: 1000, mmD: 85, kg: 12.0, wMax: 280, wAvg: 95, maxPerPort: 0, maxPerPowerLink: 0 },
  { key: 'absen-a3pro-39-500', mfr: 'Absen', name: 'A3 Pro 3.9 (500×500)', pxW: 128, pxH: 128, mmW: 500, mmH: 500, mmD: 80, kg: 7.6, wMax: 160, wAvg: 55, maxPerPort: 0, maxPerPowerLink: 0 },
  { key: 'absen-a3pro-39-1000', mfr: 'Absen', name: 'A3 Pro 3.9 (500×1000)', pxW: 128, pxH: 256, mmW: 500, mmH: 1000, mmD: 80, kg: 13.0, wMax: 300, wAvg: 100, maxPerPort: 0, maxPerPowerLink: 0 },
  // Revelux — placeholders, enter your exact model specs in the Panel Library
  { key: 'revelux-26-500', mfr: 'Revelux', name: 'Revelux 2.6 (500×500) — verify', pxW: 192, pxH: 192, mmW: 500, mmH: 500, mmD: 80, kg: 7.5, wMax: 170, wAvg: 60, maxPerPort: 0, maxPerPowerLink: 0 },
  { key: 'revelux-39-1000', mfr: 'Revelux', name: 'Revelux 3.9 (500×1000) — verify', pxW: 128, pxH: 256, mmW: 500, mmH: 1000, mmD: 85, kg: 13.0, wMax: 300, wAvg: 100, maxPerPort: 0, maxPerPowerLink: 0 },
  // ROE / generic
  { key: 'roe-bp2v2', mfr: 'ROE', name: 'Black Pearl BP2 V2', pxW: 176, pxH: 176, mmW: 500, mmH: 500, mmD: 77, kg: 9.35, wMax: 190, wAvg: 95, maxPerPort: 0, maxPerPowerLink: 0 },
  { key: 'gen-26-500', mfr: 'Generic', name: 'Generic 2.6 (500×500)', pxW: 192, pxH: 192, mmW: 500, mmH: 500, mmD: 80, kg: 8, wMax: 180, wAvg: 60, maxPerPort: 0, maxPerPowerLink: 0 },
  { key: 'gen-39-500', mfr: 'Generic', name: 'Generic 3.9 (500×500)', pxW: 128, pxH: 128, mmW: 500, mmH: 500, mmD: 80, kg: 8, wMax: 160, wAvg: 55, maxPerPort: 0, maxPerPowerLink: 0 },
];

// portPixels = pixels per 1G port at 60 Hz, 8-bit.
// halfAt10bit: capacity halves at >8-bit (Novastar behaviour).
// distributor: ports are reached through distribution units (Brompton XD) fed by trunks.
export const PROCESSOR_MODELS = {
  'brompton-sx40': { vendor: 'Brompton', name: 'Tessera SX40', maxInputW: 4096, maxInputH: 2160, maxPixels: 4096 * 2160, directPorts: 0, trunks: 4, distributor: 'XD', portsPerDistributor: 10, portPixels: 525000, halfAt10bit: false, portLabel: 'xd' },
  'brompton-s8':   { vendor: 'Brompton', name: 'Tessera S8', maxInputW: 4096, maxInputH: 2160, maxPixels: 8 * 525000, directPorts: 8, trunks: 0, portPixels: 525000, halfAt10bit: false },
  'brompton-s4':   { vendor: 'Brompton', name: 'Tessera S4', maxInputW: 2048, maxInputH: 1080, maxPixels: 4 * 525000, directPorts: 4, trunks: 0, portPixels: 525000, halfAt10bit: false },
  'nova-vx4s':     { vendor: 'Novastar', name: 'VX4S', maxInputW: 3840, maxInputH: 1920, maxPixels: 2300000, directPorts: 4, trunks: 0, portPixels: 650000, halfAt10bit: true },
  'nova-vx6s':     { vendor: 'Novastar', name: 'VX6s', maxInputW: 10240, maxInputH: 8192, maxPixels: 3900000, directPorts: 6, trunks: 0, portPixels: 650000, halfAt10bit: true },
  'nova-uhdjr':    { vendor: 'Novastar', name: 'NovaPro UHD Jr', maxInputW: 4096, maxInputH: 2160, maxPixels: 10400000, directPorts: 16, trunks: 0, portPixels: 650000, halfAt10bit: true },
  'nova-mx20':     { vendor: 'Novastar', name: 'COEX MX20', maxInputW: 4096, maxInputH: 2160, maxPixels: 3900000, directPorts: 6, trunks: 0, portPixels: 650000, halfAt10bit: true },
  'nova-mx30':     { vendor: 'Novastar', name: 'COEX MX30', maxInputW: 4096, maxInputH: 2160, maxPixels: 6500000, directPorts: 10, trunks: 0, portPixels: 650000, halfAt10bit: true },
  'nova-mx40pro':  { vendor: 'Novastar', name: 'COEX MX40 Pro', maxInputW: 4096, maxInputH: 2160, maxPixels: 9000000, directPorts: 20, trunks: 0, portPixels: 650000, halfAt10bit: true },
  'custom':        { vendor: 'Custom', name: 'Custom processor', maxInputW: 3840, maxInputH: 2160, maxPixels: 8294400, directPorts: 8, trunks: 0, portPixels: 650000, halfAt10bit: false },
};

export const GPU_PRESETS = [
  { name: 'NVIDIA RTX A6000 / Quadro (4× DP)', outputs: 4 },
  { name: 'NVIDIA RTX 6000 Ada (4× DP)', outputs: 4 },
  { name: 'Media server (2 outputs)', outputs: 2 },
];

export const RES_PRESETS = [
  [1920, 1080], [2048, 1080], [2560, 1440], [3840, 2160], [4096, 2160],
];

// Common curve-block / hinge angles (degrees). Positive = concave.
export const ANGLE_PRESETS = [-15, -10, -7.5, -5, -2.5, 0, 2.5, 5, 7.5, 10, 15, 90, -90];

export const VOLTAGES = [
  { key: '120', label: '120 V 1Φ', v: 120, threePhase: false },
  { key: '208', label: '208 V 1Φ (L-L)', v: 208, threePhase: false },
  { key: '230', label: '230 V 1Φ', v: 230, threePhase: false },
  { key: '240', label: '240 V 1Φ', v: 240, threePhase: false },
];

export const RUN_COLORS = [
  '#ff5a5f', '#ffb400', '#3ec300', '#00a8e8', '#b07cff', '#ff7ac6', '#00d2b4', '#ff8c42',
  '#7bdff2', '#c3f73a', '#f25f5c', '#ffe066', '#70c1b3', '#9b5de5', '#f15bb5', '#00bbf9',
  '#fee440', '#00f5d4', '#e76f51', '#8ecae6',
];
