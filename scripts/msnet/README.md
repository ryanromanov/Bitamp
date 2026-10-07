# MSNet: the chiptune cover's vocal line

The chiptune cover (Retro Sound ▸ Chiptune) takes most of its notes from Basic Pitch, which
often misses the part of a song people would hum. MSNet follows the sung melody instead,
and while someone sings, that line takes the lead.

- **Model:** MSNet vocal, from *Hsieh, Su & Yang, "A Streamlined Encoder/Decoder Architecture
  for Melody Extraction", ICASSP 2019*, github.com/bill317996/Melody-extraction-with-melodic-segnet.
  MIT licence (bundled as `Sources/BitampKit/Resources/MSNet/LICENSE`). The Core ML package
  there is fp16, 1 MB.
- **In the app:** `CFP.swift` computes the model's input features (a port of the repo's
  `cfp.py`), `MSNet.swift` runs the model, `VocalTracker.swift` runs both ahead of the
  playhead and turns frames into notes, and `ChipArranger.addVocal` lays them over the
  arrangement.
- **Rejected:** Demucs (80–160 MB), Spleeter (~79 MB), Open-Unmix (35 MB; UMX-L is
  CC BY-NC-SA), RMVPE (181 MB, unclear weight licence), FTANet (no licence), CREPE tiny
  (monophonic, so it tracks the loudest thing, not the voice).

## Regenerating and checking the model

One-time setup (Python 3.12; `repo/` and `venv/` are gitignored):

```sh
cd scripts/msnet
git clone https://github.com/bill317996/Melody-extraction-with-melodic-segnet repo
git -C repo apply ../cfp.patch          # numpy/scipy API updates
python3 -m venv venv && venv/bin/pip install torch==2.7.0 numpy scipy soundfile pandas coremltools
```

coremltools 9.0 fails on newer torch, hence the pin.

- `convert.py OUT.mlpackage` converts the PyTorch weights. Core ML has no `MaxUnpool2d`, so
  each unpool is rebuilt from a first-maximum mask; that matches PyTorch exactly before the
  fp16 conversion.
- `check.py MODEL SONG START SECONDS [...]` compares Core ML with PyTorch on real clips. On
  four test clips: voicing agreed on 99.8–100% of frames, and 99.7–99.9% of pitches were
  within 50 cents.
- `dump-features.py SONG START SECONDS OUT.cfp` writes a clip's samples, Python's features
  and PyTorch's pitches; `BITAMP_CFP_DUMP=OUT.cfp scripts/test.sh --filter MSNetDumpTests`
  compares the Swift side with them (features within 6e-8, pitches 99% the same).

## Things learned

- **Normalisation matters a lot.** `cfp.py` scales each feature map by its peak over all the
  audio it's given, and MSNet's voicing shifts with that scale: scaling each few-second
  stretch on its own dropped agreement to 87–90%. Bitamp scales each stretch by the peaks
  within 10 seconds either side, like the 20–30 s clips the cover was tuned on by ear, which
  keeps it at 99%. Whole-song peaks run 5–10% higher than a clip's
  (`BITAMP_PEAKS_FILES=a.mp3:b.mp3 scripts/test.sh --filter MSNetPeakSurvey`).
- **Choirs count as singing.** MSNet's confidence is nearly always 0 or 1, and it is
  confidently voiced on choirs (Boadicea's intro, the Halo 2 chant).
- **By ear (2026-10-07):** adding the vocal line beat replacing Basic Pitch's lead with it.
  The full arrangement (arpeggios, the displaced lead behind the voice) was too busy, so the
  default is sparse: nothing but the bass behind the voice, no arpeggio, and longer minimum
  notes. A steadier vocal line (1 semitone, 8 ticks) sounded worse.
- **Speed:** the features are the slow part, about 3.4× real time on one core in a release
  build (22,050-point transforms via Bluestein); `VocalTracker` uses up to four cores, so
  transcription runs at about 4× real time end to end, and it stays within 30 s of the playhead.

The chip harness renders clips for listening:
`BITAMP_CHIP_FILE=SONG BITAMP_CHIP_START=45 BITAMP_CHIP_SECONDS=20 BITAMP_CHIP_OUT=DIR scripts/test.sh --filter ChipHarnessTests/basicPitchCover`,
with `BITAMP_CHIP_STYLE=a...e` for the arrangements compared and `BITAMP_CHIP_VOCAL=0` for none.
