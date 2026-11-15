# Checks Reference

Every change re-runs the checks. Errors (red) mean something won't work as drawn. Warnings (orange) are worth a look. Hover over the count in the status bar to list them, click it for the full list, or open **Resources**.

## Walls

| Message | Meaning and fix |
|---|---|
| *one panel exceeds a port's capacity* | A single panel has more pixels than a port carries at this frame rate and bit depth. Lower the frame rate or bit depth, or use a different processor. |
| *data/power run N has X panels (max Y)* | A custom run is longer than the port or circuit allows. Split it. |
| *N panels with no data/power connection* | Some panels aren't on any custom run. Add them to a run, or switch back to Auto. |
| *N panels on more than one run* | A panel is on two custom runs. Remove it from one. |
| *data run N crosses into another processor's section* | A custom run starts on one processor's panels and continues onto another's. Keep each run inside one section. |
| *not assigned to a processor* | Choose a processor for the wall (or that section) in the inspector. |

## Processors

| Message | Meaning and fix |
|---|---|
| *Port 1A-3: X px exceeds port capacity* | Runs pinned to that port carry too many pixels. Move one to another port. |
| *Port 1A-3: shared by N runs* (warning) | Two runs are pinned to the same port. |
| *needs N ports but only M available — add distro 1C* | Add a distro, or turn on **Size distros automatically**. |
| *needs N ports; model supports M* | More than the processor can ever drive. Split the wall onto another processor. |
| *pixel load exceeds capacity* | Too many pixels on one processor. Move walls or sections to another. |
| *input exceeds model max* | The input resolution is larger than the model accepts. |
| *canvas falls outside the input* | A wall or section sits past the edge of the processor's input. Drag it in the Processor Map, or use Auto-Pack. |
| *overlap on the input canvas* (warning) | Two walls share canvas pixels, so they'll show the same content. Fine for mirrored walls; otherwise move one. |

## Media servers

| Message | Meaning and fix |
|---|---|
| *input larger than the server output* | The processor's input is bigger than the GPU output feeding it. |
| *output runs at X Hz but the project is Y Hz* (warning) | Match the output refresh rate to the project frame rate. |
| *mosaic grid is smaller than its outputs* (warning) | Increase the mosaic columns or rows. |
| *output N feeds several processors* (info) | Those processors need a splitter or DA and get identical content. |

## Power

| Message | Meaning and fix |
|---|---|
| *circuit X A exceeds breaker × load limit* | A custom power run draws too much. Shorten it, or check the breaker and load limit in Project Settings. |
