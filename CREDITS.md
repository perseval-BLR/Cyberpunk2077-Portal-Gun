# Credits

## Third-party content in the release archive
| What | Author / owner | Source | Terms |
|---|---|---|---|
| 3D model "HD Portalgun Remastered" (mesh, PBR textures; the inventory icon is a render of it) | Igrium (https://sketchfab.com/Sam54123) | https://sketchfab.com/3d-models/hd-portalgun-remastered-073ba676dd364b6e96c2d0a9b9991362 | CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/) |
| The portal gun and portal designs, *Portal*, Aperture Science | Valve Corporation | — | Trademarks / copyright of Valve |
| *Cyberpunk 2077*: the Militech Saratoga used as the base item; the game's portal device (`portal_1.ent`, `portals.app`, `portal_ui.inkwidget`, `portal_textures.inkatlas`, `portal_stream_texture.dtex`), copied and modified for the see-through view | CD PROJEKT S.A. | — | Used under CD PROJEKT RED's modding guidelines |
| Helper entity and mesh templates (`empty_entity.ent`, `sphere.mesh`; the portal, shot and view meshes are new geometry imported over the template) | entSpawner (Object Spawner / World Builder) by keanuWheeze | Nexus Mods, "entSpawner" | Used as templates, credited |

**This work is based on "HD Portalgun Remastered"
(https://sketchfab.com/3d-models/hd-portalgun-remastered-073ba676dd364b6e96c2d0a9b9991362) by Igrium
(https://sketchfab.com/Sam54123) licensed under CC-BY-4.0 (http://creativecommons.org/licenses/by/4.0/).**

**Changes to the model (CC BY 4.0 requires indicating them):** converted from glTF to a Cyberpunk 2077 mesh; the
pose baked; turned, scaled to 0.85 and placed on the Militech Saratoga's rig; textures resized from 4096 to 2048 px
(the emissive map to 1024 px with invisible noise), metal/roughness channels separated; emissive glow added in the
material.

All other textures (the portal swirl and rim frames) and meshes (the portal oval, rim, shot, view screen) were made
for this mod.

## Frameworks and tools
Cyber Engine Tweaks (yamashi and contributors), RED4ext (WopsS), redscript (jac3km4), ArchiveXL, TweakXL and Codeware
(psiberx), WolvenKit (WolvenKit team), the Cyberpunk 2077 Blender add-on (WolvenKit team), Blender. References: the
RED Modding wiki, the entSpawner mod (spawning helper entities, moving them, the AI teleport command), Push and Pull
NPCs (ragdoll impulses).

## Built with AI
Made by perseval-BLR with Claude Code (Anthropic, Claude Opus 5.5): API research, the portal, teleport and NPC logic,
the see-through view, the model conversion pipeline and the item files. Tested in game by perseval-BLR.
