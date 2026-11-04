# LED Wall Tool

A native macOS app for planning LED wall data and power before deployment: from one small wall up to multi-wall sets split across several processors fed by a mosaiced media server.

## Download

Grab **LEDWallTool-x.y.z-macOS.zip** from the [Releases](../../releases) page, unzip it and drag **LEDWallTool.app** to Applications. It runs on macOS 14 Sonoma or later, on Apple Silicon and Intel.

The app isn't notarized by Apple yet, so the first launch needs one extra step:

- **Right-click (or Control-click) the app → Open → Open.** After that it opens normally.
- If macOS says the app "is damaged" or still won't open, run this once in Terminal:

  ```bash
  xattr -dr com.apple.quarantine /Applications/LEDWallTool.app
  ```

## Build

```bash
xcodegen generate
open LEDWallTool.xcodeproj
```

The app icon is drawn by `tools/make-icon.swift` (`swift tools/make-icon.swift LEDWallTool/Resources/Assets.xcassets/AppIcon.appiconset`).

Core logic lives in `Packages/WallKit` (no UI) and has its own tests:

```bash
cd Packages/WallKit && swift test
```

## Layout

| Path | What |
|---|---|
| `Packages/WallKit/Sources/WallKit/Catalog.swift` | Panel library (Unilumin, Absen, Revelux, ROE…) and processor specs (Brompton SX40/S8/S4, Novastar VX4S/VX6s/UHD Jr/MX20/MX30/MX40 Pro) |
| `…/Model.swift` | Project, walls, processors, media servers, wiring; house naming (processor 1 → distros 1A, 1B → port 1A-3) |
| `…/Geometry.swift` | Curves, concave/convex hinges, curve blocks, corners, headers that follow their parent's curve |
| `…/Routing.swift` | Auto patterns (N, S/zig-zag, Z, straight, U, C, center-out) + recommendation + custom runs |
| `…/Analysis.swift` | Port/distro/pixel/input capacity, canvas fit, GPU outputs, power per circuit, phase balance, weight |
| `LEDWallTool/Views` | Sidebar, inspector, 2D map editor, SceneKit 3D, pixel map, resources |
| `LEDWallTool/App/Drawings.swift` | As-built vector PDF set (title block, revisions, zones, audience/rear views, schedules, BOM) |

## Workflow

1. **Sidebar**: add walls, processors, media servers and panel types. Right-click a wall to add a header or 90° wings.
2. **Inspector**: size, panel, rigging, processor and canvas position, placement/attachment, curve (all hinges, from radius, or per-hinge list). **Split Across Processors** is a quick left/right or top/bottom split; each section (S1, S2…) gets its own processor, ports and input-canvas position.
3. **2D Map**:
   - **Data / Power**: Auto patterns, or **Custom**. Drag across panels to hand-wire a run; ⌥-drag removes; each data run can be pinned to a specific port.
   - **Processors**: paint any panels onto another processor (e.g. split down the center, bottom two rows on a third). Right-click a data run to move it to another processor, or (Custom) pin it to a distro port.
   - **Structure**: click or drag to cut panels out; click an angle tag to set a curve block.
4. **3D**: walls in space, colored by wall, data or power. Import a room from SketchUp via File ▸ Export ▸ 3D Model ▸ COLLADA (.dae), OBJ or USDZ.
5. **Processor Map**: drag walls on each processor's input canvas, auto-pack, export native-resolution PNGs; see the media server mosaic.
6. **Comp & Mask**: build the whole content comp (e.g. a Resolume composition). Walls start in an unrolled stage layout (headers above, wings beside), or match the media server outputs; drag to place, set the comp size or fit it to the walls. Export a **mask PNG** (transparent = LED, black = unused), a labelled **template PNG**, and a **slices CSV** mapping each comp region to its server output and position. (The 3D view is hidden for now; launch with `-workspace 3D` to reach it.)
7. **Resources**: every over-capacity check (ports, distros, pixel load, input size, GPU outputs, circuits), port grid per distro, weight, amps at 120/208/230/240/400 V, phase balance and feeder size.
8. **Export ▸ Drawing Set… (⌘E)**: choose sheets, audience and/or rear (build-side, mirrored) views, paper (11×17, ARCH C/D, A3, A1, Letter), dimensions, panel IDs, border zones, AS-BUILT stamp, BOM spares, walls, title block and revisions, with a live preview. The set is LED-000 cover & index, LED-001 system, LED-1xx data, LED-2xx power, LED-3xx structure & curve-block schedule, LED-4xx cable schedule, LED-501 BOM, and LED-6xx pixel maps. ⌘P prints with the same settings; CSV and pixel-map PNGs are under Export.

## Known limits

- Catalog figures are typical published specs. Verify panels and processors against current manufacturer data. Revelux entries are placeholders to fill in.
- SketchUp `.skp` can't be read directly; export COLLADA/OBJ/USDZ from SketchUp.

The original web prototype is kept in `archive/web-prototype`.
