import os, re, sys, subprocess, collections, tempfile, json
from concurrent.futures import ThreadPoolExecutor
sys.argv = sys.argv[:1] + sys.argv[1:]
import run

def glsl_to_msl(glsl, tmp):
    lines = glsl.split('\n')
    block, out = [], []
    for l in lines:
        m = re.match(r'^uniform\s+(?!sampler)(\w+)\s+([\w\s,\[\]]+);', l)
        if m:
            for name in m.group(2).split(','): block.append('uniform %s %s;' % (m.group(1), name.strip()))
            continue
        l = re.sub(r'^(sampler2D|sampler3D)\s', r'uniform \1 ', l)
        out.append(l)
    text = '\n'.join(out)
    # The block goes after the version line.
    env = 'layout(std140, binding = 0) uniform Env {\n' + '\n'.join(re.sub(r'^uniform\s+', '', b) for b in block) + '\n};\n'
    text = text.replace('#version 330', '#version 450\n' + env, 1)
    f = os.path.join(tmp, 'a.frag'); open(f, 'w').write(text)
    r = subprocess.run(['glslangValidator', '-G', '--aml', '-S', 'frag', f, '-o', os.path.join(tmp, 'a.spv')], capture_output=True, text=True)
    if r.returncode: return None, 'glslang: ' + next((x for x in r.stdout.splitlines() if 'ERROR:' in x and 'Linking' not in x and '.frag:' in x), '?').split('.frag:')[-1]
    r = subprocess.run(['spirv-cross', os.path.join(tmp, 'a.spv'), '--msl', '--msl-version', '30000'], capture_output=True, text=True)
    if r.returncode: return None, 'spirv-cross: ' + (r.stderr.strip().splitlines() or ['?'])[-1]
    return r.stdout, ''

def work(job):
    path, kind = job
    code = run.extract(path, kind)
    if code is None: return None
    src, info = run.assemble(code, kind)
    if src is None: return (path, kind, 'FAIL', 'assemble', False)
    images = any(not run.STANDARD.match(n) for n in info)
    with tempfile.TemporaryDirectory() as tmp:
        h = os.path.join(tmp, 'a.hlsl'); open(h, 'w').write(src)
        r = subprocess.run([run.TOOL, h], capture_output=True, text=True)
        if r.returncode: return (path, kind, 'FAIL', 'hlslparser', images)
        msl, err = glsl_to_msl(r.stdout, tmp)
        if msl is None: return (path, kind, 'FAIL', err[:110], images)
        import hashlib
        name = hashlib.md5((path + kind).encode()).hexdigest()[:12] + '_' + kind
        os.makedirs('msl', exist_ok=True)
        open(os.path.join('msl', name + '.metal'), 'w').write(msl)
        return (path, kind, 'OK', name, images)


if __name__ == '__main__':
    root, limit = sys.argv[1], int(sys.argv[2])
    files = sorted(os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if f.endswith('.milk'))
    if limit: files = files[::max(1, len(files) // limit)][:limit]
    jobs = [(f, k) for f in files for k in ('warp', 'comp')]
    with ThreadPoolExecutor(8) as ex: results = [r for r in ex.map(work, jobs) if r]
    for kind in ('warp', 'comp'):
        rs = [r for r in results if r[1] == kind]
        ok = sum(1 for r in rs if r[2] == 'OK')
        print(f'{kind}: {len(rs)} shaders, {ok} convert to MSL ({100*ok//max(len(rs),1)}%)')
        for e, n in collections.Counter(r[3] for r in rs if r[2] == 'FAIL').most_common(8): print(f'   {n:5d}  {e}')
    json.dump(results, open('chain_results.json', 'w'))
