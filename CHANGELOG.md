# Changelog

## 0.2.0 - 2026-11-13

### Features

- finalize liquid glass pressure icon
- menu bar ring grows a core dot in orange, full in red
- menu bar ring sized like system icons, red fills its core
- mocked demo snapshot for the readme, make screenshot
- app icon, built into the bundle from Assets/AppIcon.png
- one 14pt gap across the panel, outer rings on content edges
- larger contributor rings, 28pt to 34pt
- memory ring second, before gpu

### Fixes

- self-check failed on a quiet screen, test gpu counters not activity
- app stayed in panel-open mode after closing, 11% idle cpu
- snapshots washed out on hdr displays, redraw into 8-bit srgb

### Performance

- no panel state updates while closed, hidden views rendered them
- menu bar ring redraws on a colour change or a move of 5, not per step
- 500ms leeway on the sampling timer, so wakeups batch
- no ps spawn while the panel is closed, idle walk 28.9ms to 1.9ms cpu

## 0.1.0 - 2026-11-12

### Features

- panel rings animate between samples
- rings fill with pressure, louder as overload grows
- overload compounds across contributors
- gpu contributor at full weight, gpu culprits per app
- rings drain clockwise from 12 o'clock
- disk contributor (space + activity, half weight), swap lowers memory
- hero score ring with contributor trio, rings fill with headroom
- pressure ring in panel header and contributor rows
- pressure ring as menu bar icon
- add nimmersatt menu bar app for monitoring cpu and memory usage

### Fixes

- score number snaps, only rings and colour animate
- panel window keeps old height after collapsing details

### Performance

- cut idle overhead from 1.3-2.1% to 0.2-0.8% cpu

### Other

- nimmersatt: menu bar app that names the app eating resources
