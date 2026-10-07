"""Converts MSNet vocal to a Core ML package for Bitamp.

Usage: convert.py OUT.mlpackage  (see scripts/msnet/README.md for setup)

Core ML has no MaxUnpool2d, so the unpools are rebuilt from masks: each pooling window's
first maximum (the one PyTorch's indices point to) is marked, and the upsampled values are
multiplied by that mask. The result matches the original model; the script checks that,
then converts with a flexible frame count and fp16 weights.
"""
import os, sys
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

here = os.path.dirname(os.path.abspath(__file__))
repo = os.environ.get('MSNET_REPO', os.path.join(here, 'repo'))
sys.path.insert(0, repo)
import MSnet.model as model

def first_max_mask(x, k, c, f):
    """1 where x (c channels, f rows) holds the first maximum of its window of k rows, else 0.
    Sizes are constants so that only the frame count is dynamic in the traced graph."""
    w = x.reshape(1, c, f // k, k, -1)
    hit = (w == w.max(dim=3, keepdim=True).values).float()
    return (hit * (torch.cumsum(hit, dim=3) == 1).float()).reshape(1, c, f, -1)

def unpool(v, mask, k, c, f):
    return v.reshape(1, c, f // k, 1, -1).repeat(1, 1, 1, k, 1).reshape(1, c, f, -1) * mask

class MaskedMSnet(nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.k = [p.kernel_size[0] for p in (net.pool1, net.pool2, net.pool3)]

    def forward(self, x):
        n = self.net
        k1, k2, k3 = self.k
        a1 = n.conv1(x); c1 = F.max_pool2d(a1, (k1, 1))
        a2 = n.conv2(c1); c2 = F.max_pool2d(a2, (k2, 1))
        a3 = n.conv3(c2); c3 = F.max_pool2d(a3, (k3, 1))
        bm = n.bottom(c3)
        f1, f2, f3 = 320, 320 // k1, 320 // k1 // k2
        u3 = n.up_conv3(unpool(c3, first_max_mask(a3, k3, 128, f3), k3, 128, f3))
        u2 = n.up_conv2(unpool(u3, first_max_mask(a2, k2, 64, f2), k2, 64, f2))
        u1 = n.up_conv1(unpool(u2, first_max_mask(a1, k1, 32, f1), k1, 32, f1))
        return n.softmax(torch.cat((bm, u1), dim=2))

net = model.MSnet_vocal()
net.load_state_dict(torch.load(os.path.join(repo, 'MSnet/pretrain_model/MSnet_vocal'), map_location='cpu', weights_only=True))
net.float().eval()
masked = MaskedMSnet(net).eval()

torch.manual_seed(0)
x = torch.rand(1, 3, 320, 512)
with torch.no_grad():
    ref = net(x)[0]
    got = masked(x)
print(f"masked vs original: max diff {(ref - got).abs().max().item():.2e}, "
      f"argmax agree {(ref.argmax(2) == got.argmax(2)).float().mean().item():.1%}")

traced = torch.jit.trace(masked, x)
frames = ct.RangeDim(lower_bound=64, upper_bound=8192, default=1024)
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name='cfp', shape=(1, 3, 320, frames))],
    outputs=[ct.TensorType(name='salience')],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS13,
)
ml.short_description = ('MSNet vocal melody extraction (Hsieh, Su & Yang, ICASSP 2019). '
                        'Input: CFP features, 3 x 320 log-frequency bins (31 Hz at 60 per octave) x frames '
                        '(hop 256 at 44.1 kHz). Output: 321 x frames; bin 0 is unvoiced.')
ml.license = 'MIT'
ml.save(sys.argv[1])

out = ml.predict({'cfp': x.numpy()})['salience']
print(f"Core ML vs PyTorch: max diff {np.abs(out - ref.numpy()).max():.2e}, "
      f"argmax agree {(out.argmax(2) == ref.numpy().argmax(2)).mean():.1%}")
