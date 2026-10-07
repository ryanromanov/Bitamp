# Hummable lead: MSNet prototype

Work in progress on the `chiptune-melody` branch. The chiptune cover (draft PR #8) builds
its lead from Basic Pitch's notes, which often miss the part of a song people would hum.
This experiment adds a vocal melody tracker on top. So far it runs offline only, through the
chip harness; the app doesn't use it yet.

## Where things stand (2026-10-07)

- **Model:** MSNet vocal, from *Hsieh, Su & Yang, "A Streamlined Encoder/Decoder Architecture
  for Melody Extraction", ICASSP 2019*, github.com/bill317996/Melody-extraction-with-melodic-segnet.
  MIT licence, weights in the repo (`MSnet/pretrain_model/MSnet_vocal`, 2,090,119 bytes,
  about 0.5M parameters; roughly 1 MB as fp16 Core ML).
- **Rejected:** Demucs (80–160 MB), Spleeter (~79 MB), Open-Unmix (35 MB; UMX-L is
  CC BY-NC-SA), RMVPE (181 MB, unclear weight licence), FTANet (no licence),
  CREPE tiny (MIT and small, but monophonic, so it tracks the loudest thing, not the voice).
- **Three versions, each on a branch:**
  - `chiptune-basicpitch`: no MSNet (today's app).
  - `chiptune-msnet-replace`: MSNet's vocal line replaces the lead.
  - `chiptune-melody`: MSNet's vocal line is **added**. It becomes the lead while it sounds,
    and Basic Pitch's own lead moves to the chord voice at 0.7× its level. With no vocal,
    nothing changes. **The user picked this one as probably best.**
- **What the user heard:** replacing made vocals more apparent and Shock the Monkey better,
  but lost Boadicea's intro backing; adding was meant to keep both. Halo (Mjolnir Mix) is a
  poor fit either way.
- **Known limit:** MSNet's voicing confidence is bimodal (nearly always 0 or 1) and it is
  confidently "voiced" on choirs (Boadicea's intro, the Halo chant). Gating on confidence
  can't separate the hummable vocal from backing voices.

## Reproducing the clips

One-time setup (Python 3.12):

```sh
cd scripts/msnet
git clone https://github.com/bill317996/Melody-extraction-with-melodic-segnet repo
git -C repo apply ../cfp.patch          # numpy/scipy API updates; repo/ is gitignored
python3 -m venv venv && venv/bin/pip install torch numpy scipy soundfile pandas
```

Then, per clip:

```sh
scripts/msnet/venv/bin/python scripts/msnet/pitch-track.py SONG.mp3 START SECONDS /tmp/x/name.f0.txt
BITAMP_CHIP_FILE=SONG.mp3 BITAMP_CHIP_START=START BITAMP_CHIP_SECONDS=SECONDS \
BITAMP_CHIP_NAME=name-msnet-add BITAMP_CHIP_OUT=/tmp/x \
BITAMP_CHIP_LEAD=/tmp/x/name.f0.txt BITAMP_CHIP_LEAD_MODE=add \
scripts/test.sh --filter ChipHarnessTests/basicPitchCover
```

Leave out `BITAMP_CHIP_LEAD_MODE` for the replace version, and `BITAMP_CHIP_LEAD` for today's.
Clips used so far: Enya "Boadicea" 0–20 s, Peter Gabriel "Shock the Monkey" 45–65 s,
Halo 2 "Halo Theme Mjolnir Mix" 0–30 s (intro) and 78–98 s (high part).

The pitch track becomes notes in `ChipHarnessTests.withLead(fromPitchTrack:...)`: per 11.6 ms
score tick, the median voiced pitch if at least half the tick's frames are voiced; a note holds
while the pitch stays within 0.8 semitone; unvoiced gaps of up to 3 ticks are bridged; notes
under 4 ticks merge into the previous one.

## Next: port to the app

1. **Core ML model.** Load `MSnet_vocal` into `model.MSnet_vocal()`, trace it, convert with
   coremltools (fp16). `MaxUnpool2d` may not convert directly; if not, rewrite the unpool as
   a scatter or as `upsample × (input == maxpool-upsampled)` masks before tracing. Check the
   Core ML output against PyTorch on the four clips. Bundle it with its MIT licence next to
   Basic Pitch's in `Resources/`, compiled and cached at runtime the same way.
2. **CFP features in Swift (vDSP).** Port `feature_extraction` in `MSnet/cfp.py` for the vocal
   settings: 44.1 kHz mono, hop 256 (5.8 ms), Blackman-Harris window of 2049, frequency
   resolution 2 Hz (so a 22,050-point FFT), gammas [0.24, 0.6, 1], 31–1250 Hz at
   60 bins per octave. Three channels: spectrum, generalized cepstrum, and their product,
   each `norm(lognorm(·))`. That normalisation is over the whole input, so for streaming
   ahead of the playhead it has to become per window (check that this doesn't hurt).
   Write a test that compares the Swift features with the Python ones on a short clip.
3. **Runtime.** Run it in windows ahead of the playhead alongside `NoteTranscription`
   (the Python reference runs at 2–3.4× real time on CPU; Core ML should be far faster).
   Decode with argmax over frequency, index 0 = unvoiced, and move `withLead` from the
   harness into `ChipArranger` as the add mode.
4. **Listen again** in the app on the same four songs, then update PR #8.
