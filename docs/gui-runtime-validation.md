# GUI companion runtime validation, 2026-09-26

These are local RTX 4070 controls, not reproduction or proof of a fix for the severe typing-related frame drop reported on an RTX 2060 Super. The latter machine reportedly uses Minecraft 26.2, Sodium, Iris, Distant Horizons, Terralith, a tall-terrain mod likely Tectonic, and Continents. Exact affected versions and logs remain unavailable.

Local stack: Minecraft 26.2, Fabric Loader 0.19.5, Fabric API 0.161.0+26.2, Java 25, Iris 1.11.4, Sodium 0.9.2, Distant Horizons 3.3.2, Terralith and Tectonic. Continents is not installed locally. VSync is off; maximum FPS 260 is Minecraft's unlimited setting. Time and camera position were fixed, but cloud animation continued. PresentMon 2.4.1 measured actual presentation rather than the render-only CPU meter. No lost ETW events were reported.

## First runtime candidate

The initial GUI JAR used the same wait code as the final JAR but a broader pack-name gate. That gate was subsequently narrowed; no rendering/wait code changed. Both companion mods were installed. At 1920×1080, each capture lasted 10 seconds:

| Capture | Guard | Median frame ms | p95 frame ms | Median GPU busy ms |
| --- | --- | ---: | ---: | ---: |
| Ultra world | Off | 14.9637 | 16.2709 | 12.4073 |
| Ultra chat | Off | 15.0131 | 16.2882 | 12.4235 |
| Ultra chat | On | 15.6925 | 17.6152 | 12.5434 |
| Heavier GPU-load chat | Off | 19.7675 | 21.0989 | 17.1126 |
| Heavier GPU-load chat | On | 20.1074 | 21.5237 | 17.1297 |
| Heavier GPU-load chat | Off, repeat | 19.3813 | 20.8908 | 16.8907 |

The private heavier-load pack raised five coupled volumetric target scales from 0.4 to 0.75. It is not included in the release. These controls show a small throughput cost from reducing CPU/GPU overlap; they do not establish improved input latency. Static open-chat tests do not qualify continuous typing.

## Final release files

- Shader ZIP SHA-256: `5c4d0d662d1bbfc8a09d6c74b59756e97ca1c994add197013077fd52f00aa3f7`.
- GUI JAR SHA-256: `d670f01849a1818c9f8b34c1754e5f92008962ba6a43233b3acc0271fdf831a2`.
- End JAR SHA-256: `7357a8095b0f15bcfdebbc5167cec317cb2a817fb975f036731857f9f30df132`.

The final exact-named ZIP and JAR loaded after a restart. At 2402×1313, two 60-second captures included native individual character/backspace keys, plain text entry bursts, and `/locate biome` completion with Terralith biomes. Text appeared and command suggestions updated. No command was submitted. The actions were interspersed with observations and idle periods; this is not a continuous human-typing benchmark or a measurement of keypress-to-display delay.

| Capture | Median frame ms | p95 frame ms | Maximum frame ms |
| --- | ---: | ---: | ---: |
| Guard off | 18.3797 | 19.7684 | 44.5560 |
| Guard on | 19.0575 | 20.6903 | 30.3725 |

The off capture overlapped Java Flight Recorder profiling and the action sequences were not identical. Do not promote the maximum-frame difference to a claimed improvement. Neither capture reproduced the affected machine's severe collapse.

Runtime gates verified from command counters:

- The final public ZIP engaged the guard: 5,263 completed waits, zero timeouts in one interval, mean added wait 13.553 ms.
- An unlisted pack deliberately named `Afterglow Lite` showed `other shader pack` with zero engaged waits after reset, despite its matching prefix.
- Closed-screen world rendering showed zero engaged waits after reset.
- Disabled shaders showed zero engaged waits after reset in the first candidate; the final gate logic for shader enablement is unchanged.
- `/afterglowfix off` disabled waits and persisted the setting; `/afterglowfix on` re-enabled them. Both commands work through Fabric client commands without server permissions.
- No input callback exception, GUI mitigation failure, shader compilation failure or missing ambience-sound error appeared in the inspected test log. Existing unrelated Windows Perflib warnings were present.

Both mods loaded together. Entering the End displayed the storm; returning to the Overworld restored normal appearance. This was a startup/resource/visual smoke test, not an audio-quality assessment. End gusts and sound assets are unchanged from the existing ambience source.

Raw captures and screenshots remain local under `outputs/gui-lag-diagnosis/`. Raw JFR recordings and logs are not public release assets. See [the source investigation](gui-stall-diagnosis.md) for the suspected queue mechanism, alternative causes and affected-host capture procedure.
