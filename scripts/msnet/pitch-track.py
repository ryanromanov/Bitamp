"""Writes MSNet's vocal pitch track for a clip of a song, for the chip harness's BITAMP_CHIP_LEAD.

Usage: pitch-track.py SONG START SECONDS OUT.f0.txt  (see scripts/msnet/README.md for setup)
Each output line is "seconds hertz voiced": hertz is 0 when unvoiced, and voiced is
1 minus the model's probability of the unvoiced bin.
"""
import os, sys, time
import numpy as np
import soundfile as sf

here = os.path.dirname(os.path.abspath(__file__))
repo = os.environ.get('MSNET_REPO', os.path.join(here, 'repo'))
sys.path.insert(0, repo)
import MSnet.MelodyExtraction as ME

captured = {}
_est = ME.est
def est_with_voicing(output, CenFreq, time_arr):
    captured['voiced'] = 1 - output[0, 0, 0, :]
    return _est(output, CenFreq, time_arr)
ME.est = est_with_voicing

song, start, seconds, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
info = sf.info(song)
y, sr = sf.read(song, start=int(start * info.samplerate), frames=int(seconds * info.samplerate), dtype='float32')
wav = out + '.wav'
sf.write(wav, y, sr)
began = time.time()
est = ME.MeExt(wav, model_type='vocal', model_path=os.path.join(repo, 'MSnet/pretrain_model/MSnet_vocal'), GPU=False)
os.remove(wav)
est = np.concatenate((est, captured['voiced'][:len(est), None]), axis=1)
np.savetxt(out, est, fmt='%.4f')
print(f"{seconds:.0f} s in {time.time() - began:.1f} s, voiced {(est[:, 1] > 0).mean():.0%} -> {out}")
