"""Writes a clip's mono samples and MSNet's CFP features, for checking the Swift port.

Usage: dump-features.py SONG START SECONDS OUT.cfp  (see scripts/msnet/README.md for setup)
OUT.cfp is little-endian: int32 sample count, int32 frame count, float32 samples, then
float32 spectrum, generalized cepstrum of spectrum and cepstrum (each 320 x frames,
row-major), before the log and min-max normalisation that cfp_process applies, and last
int32 PyTorch MSNet's pitch bin for each frame (0 = unvoiced), from cfp_process's features.
"""
import os, sys
import numpy as np
import soundfile as sf
import torch

here = os.path.dirname(os.path.abspath(__file__))
repo = os.environ.get('MSNET_REPO', os.path.join(here, 'repo'))
sys.path.insert(0, repo)
from MSnet.cfp import feature_extraction, lognorm, norm
import MSnet.model as model

song, start, seconds, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
info = sf.info(song)
assert info.samplerate == 44100, 'MSNet vocal expects 44.1 kHz'
y, _ = sf.read(song, start=int(start * 44100), frames=int(seconds * 44100), dtype='float32')
if y.ndim > 1:
    y = y.mean(axis=1)
y = y.astype(np.float32)
_, _, _, tfrL0, tfrLF, tfrLQ = feature_extraction(y, 44100, Hop=256, StartFreq=31.0, StopFreq=1250.0, NumPerOct=60)
net = model.MSnet_vocal()
net.load_state_dict(torch.load(os.path.join(repo, 'MSnet/pretrain_model/MSnet_vocal'), map_location='cpu', weights_only=True))
net.float().eval()
W = np.stack([norm(lognorm(m)) for m in (tfrL0, tfrLF, tfrLQ)])[np.newaxis].astype(np.float32)
with torch.no_grad():
    bins = net(torch.from_numpy(W))[0].numpy()[0, 0].argmax(0)
with open(out, 'wb') as f:
    np.array([len(y), tfrL0.shape[1]], dtype='<i4').tofile(f)
    y.astype('<f4').tofile(f)
    for m in (tfrL0, tfrLF, tfrLQ):
        assert m.shape[0] == 320
        m.astype('<f4').tofile(f)
    bins.astype('<i4').tofile(f)
print(f"{len(y)} samples, {tfrL0.shape[1]} frames, voiced {(bins > 0).mean():.0%} -> {out}")
