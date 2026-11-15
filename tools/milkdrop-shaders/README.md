# MilkDrop shader conversion measurement (spike)

Measures how many MilkDrop 2 preset shaders (HLSL) survive projectM's front end, as a basis for
converting them offline to Metal. Nothing here ships.

- `main.cpp`: wraps projectM's `vendor/hlslparser` (MIT): preprocess, parse, emit GLSL. Build it in a
  scratch folder from a checkout of projectM, with the parser's error logging (stubbed out upstream) changed to
  print to stderr: `clang++ -std=c++17 -O1 -w -Isrc main.cpp src/*.cpp -o hlsl2glsl`.
- `run.py <preset folder> <sample size, 0 for all>`: assembles each preset's `warp_` and `comp_` shader the way
  projectM does (header, entry point, sampler declarations; `noisevol` samplers are 3D), runs the tool, tallies.

Result on the Cream of the Crop pack (9,795 presets): warp 98% and composite 99% convert to GLSL.
GLSL to Metal (`chain.py`: GLSL, then `glslangValidator`, then `spirv-cross --msl`) gives Metal source for 98% of all
15,895 shaders, and 15,608 of the 15,612 converted ones compile on the GPU. The engine runs them (`MilkUserShader`),
with stand-ins for blur textures, picture files and rotation matrices. This is a development tool only: Bitamp
bundles no third-party presets, so none of this ships, and the app has no converter.
