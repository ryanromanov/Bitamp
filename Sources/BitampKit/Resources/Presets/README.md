# Original presets

Written from scratch for Bitamp (MIT, like the rest of the repo). None are copied or adapted from
any other preset pack. They use MilkDrop's preset format, so they also run in other players.

Bitamp reads the `.milk` format but can't run a preset's own HLSL shaders, so a preset that depends on
them draws only its feedback, waves and shapes. Presets that use none look the same here as anywhere.

A preset can set `bitamp_dither=<levels per colour>` among its settings to ask for finer dithering than the
default six, which suits soft dark gradients. Other players ignore the line.
