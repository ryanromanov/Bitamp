"""Compares the Core ML MSNet with PyTorch on real clips.

Usage: check.py MODEL.mlpackage SONG START SECONDS [SONG START SECONDS ...]
For each clip: how often both agree on voiced/unvoiced, how often they pick the same
pitch bin, how far apart the pitches are when both are voiced, and Core ML's speed.
"""
import os, sys, tempfile, time
import numpy as np
import soundfile as sf
import torch
import coremltools as ct

here = os.path.dirname(os.path.abspath(__file__))
repo = os.environ.get('MSNET_REPO', os.path.join(here, 'repo'))
sys.path.insert(0, repo)
import MSnet.model as model
from MSnet.cfp import cfp_process

net = model.MSnet_vocal()
net.load_state_dict(torch.load(os.path.join(repo, 'MSnet/pretrain_model/MSnet_vocal'), map_location='cpu', weights_only=True))
net.float().eval()
ml = ct.models.MLModel(sys.argv[1])

args = sys.argv[2:]
for song, start, seconds in zip(args[0::3], args[1::3], args[2::3]):
    start, seconds = float(start), float(seconds)
    info = sf.info(song)
    y, sr = sf.read(song, start=int(start * info.samplerate), frames=int(seconds * info.samplerate), dtype='float32')
    with tempfile.NamedTemporaryFile(suffix='.wav') as wav:
        sf.write(wav.name, y, sr)
        data, cen, _ = cfp_process(wav.name, model_type='vocal', sr=44100, hop=256)
    x = data[np.newaxis].astype(np.float32)
    with torch.no_grad():
        ref = net(torch.from_numpy(x))[0].numpy()[0, 0]
    began = time.time()
    got = ml.predict({'cfp': x})['salience'][0, 0]
    took = time.time() - began
    a, b = ref.argmax(0), got.argmax(0)
    both = (a > 0) & (b > 0)
    cents = 1200 * np.abs(np.log2(np.array(cen)[a[both]] / np.array(cen)[b[both]])) if both.any() else np.zeros(1)
    print(f"{os.path.basename(song)} {start:.0f}+{seconds:.0f}s: {x.shape[-1]} frames, "
          f"voicing agree {((a > 0) == (b > 0)).mean():.1%}, same bin {(a == b).mean():.1%}, "
          f"within 50 cents {(cents <= 50).mean():.1%} of co-voiced, "
          f"Core ML {took * 1000:.0f} ms ({seconds / took:.0f}x real time)")
