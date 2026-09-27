# Installing Afterglow

Afterglow is a shader pack for **Iris** on **Minecraft 26.2**.

## What you need

| | |
| --- | --- |
| Minecraft | 26.2 (Java Edition) |
| Mod loader | Fabric |
| Shader loader | Iris 1.11.4, which installs Sodium alongside it |
| Graphics | A GPU and driver with OpenGL 4.3 support. Tested on an NVIDIA RTX 4070 under Windows 11. |
| Optional | Distant Horizons 3.3.2 |

macOS is not supported: Afterglow uses compute shaders, and macOS OpenGL stops at version 4.1. AMD, Intel and Linux setups have not been tested yet.

## Option A: Modrinth App or Prism Launcher

1. Create an instance for **Minecraft 26.2** with **Fabric**.
2. Add **Iris** from the mod browser. Sodium is added as a dependency.
3. [Download the development preview](https://github.com/trevor050/mc-shader-bench/releases/download/preview-2026-09-26.2/Afterglow-preview-2026-09-26.2.zip) and drop the ZIP into the instance's shader packs page. This preview is hosted on GitHub, not listed on Modrinth yet.
4. Launch, then choose Afterglow in **Options → Video Settings → Shader Packs**.

## Option B: official launcher

1. Run the **Iris installer** from [irisshaders.dev](https://www.irisshaders.dev/download), pick Minecraft 26.2 and install. It sets up Fabric and a profile for you.
2. Start Minecraft with the new Iris profile.
3. Go to **Options → Video Settings → Shader Packs** and click **Open Shader Pack Folder**.
4. Put `Afterglow-preview-2026-09-26.2.zip` in that folder. **Don't unzip it.**
5. Back in the game, select **Afterglow** and click **Apply**. The first load takes a few seconds while the shaders compile.

## Optional companion mods

The [combined preview bundle](https://github.com/trevor050/mc-shader-bench/releases/tag/preview-2026-09-26.2) includes the End ambience mod and an experimental GUI queue mitigation. Both require Fabric API for 26.2 and Java 25. They are independent, optional client mods; copy the desired JAR from `optional-mods/` to your instance's `mods` folder, then restart. Leave the inner shader ZIP intact in `shaderpacks`.

The End companion adds storm audio, lightning coordination and gusts that push the player. The GUI companion changes GPU queue behavior only with an in-world screen open. It may reduce GUI FPS and has not been confirmed to fix the reported RTX 2060 Super typing stall. Use `/afterglowfix off` to disable it immediately. Keep the shader archive's filename unchanged.

See [the bundle guide](PREVIEW-2026-09-26.2.md) for exact filenames, versions and the compatibility experiment's limits.

## Choosing a profile

Open **Shader Pack Settings** (the button under the pack list) and pick a profile at the top.

| Profile | Use it when |
| --- | --- |
| Ultra (default) | You have a strong GPU and want the full look. |
| High / Medium | You want most of the look at a lower cost. |
| Low | You're on mid-range hardware or playing at high resolution. Water loses screen-space reflections. |
| Potato | You want the sky and clouds with the lowest cost. It uses Minecraft's own lighting and drops shadows, colored light and anti-aliasing. |

Changing a quality setting by hand switches the profile label to **Custom**. Artistic settings (colors, aurora, sunsets, brightness) don't affect the profile.

Other ways to gain frame rate: lower Minecraft's render distance, lower the Distant Horizons radius, or play at a lower resolution.

## Distant Horizons

Afterglow supports Distant Horizons 3.3.2. Install it like any other mod. The shader draws fog and sky over the distant terrain. It was tested with a Distant Horizons radius of 64 chunks; very large radii use a lot of video memory.

## Troubleshooting

**Afterglow isn't in the list.**
Check that the zip is directly inside `shaderpacks` (not in a subfolder) and that it's still zipped.

**Black screen, all-white fog or a compile error.**
- Update your graphics driver.
- Make sure you're running Iris 1.11.4 on Minecraft 26.2.
- On a laptop with two GPUs, set `javaw.exe` to use the high-performance GPU in your system's graphics settings.
- On Windows over Remote Desktop, the NVIDIA OpenGL driver isn't available; play on the local session.
- If it still fails, open `logs/latest.log`, copy the lines that mention `Iris` or `shader`, and include them in a bug report.

**Stutter or long pauses.**
Try a lower profile and a smaller Distant Horizons radius. Very long sessions with large render distances can also build up memory use; restarting the game clears it.

**It looks different from the screenshots.**
Sunsets and clouds vary from day to day by design, and the aurora only shows on some nights (see *Night Sky* in the settings). The screenshots were taken in a Terralith + Tectonic world, so terrain shapes come from those mods.

## Removing it

Pick **None** (or another pack) in **Shader Packs**, or delete the zip from the `shaderpacks` folder.

## Reporting a bug

Open an issue on GitHub with your GPU, driver version, operating system, Minecraft, Iris and (if installed) Distant Horizons versions, the profile you were using, a screenshot, and the relevant part of `logs/latest.log`.
