import os, re, sys, subprocess, collections, tempfile, json
from concurrent.futures import ThreadPoolExecutor
S = os.path.dirname(os.path.abspath(__file__))
EXT = os.path.join(S, '..', 'ext')
HEADER = open(os.path.join(EXT, 'projectm/src/libprojectM/MilkdropPreset/Shaders/PresetShaderHeaderGlsl330.inc'), encoding='latin-1').read()
TOOL = os.path.join(S, 'hlsl2glsl')

def strip_comments(t):
    t = re.sub(r'/\*.*?\*/', lambda m: re.sub(r'[^\n]', ' ', m.group(0)), t, flags=re.S)
    return re.sub(r'//[^\n]*', '', t)

def extract(path, kind):
    lines = []
    for raw in open(path, encoding='latin-1'):
        m = re.match(r'%s_(\d+)=(.*)$' % kind, raw.rstrip('\r\n'))
        if m:
            lines.append((int(m.group(1)), m.group(2).lstrip('`')))
    if not lines: return None
    return '\n'.join(l for _, l in sorted(lines))

def assemble(code, kind):
    p = strip_comments(code)
    p = re.sub(r'=\s*sampler_state\s*\{[^}]*\}', '', p, flags=re.I)
    i = p.find('shader_body')
    if i < 0: return None, 'no shader_body'
    brace = p.find('{', i)
    if brace < 0: return None, 'no brace'
    depth, j = 0, brace
    while j < len(p):
        if p[j] == '{': depth += 1
        elif p[j] == '}':
            depth -= 1
            if depth == 0: break
        j += 1
    if depth != 0: return None, 'unbalanced braces'
    body = p[brace + 1:j]
    pre = p[:i]
    if kind == 'warp':
        sig = 'void PS(float4 _vDiffuse : COLOR, float4 _uv : TEXCOORD0, float2 _rad_ang : TEXCOORD1, out float4 _return_value : COLOR0)'
        entry = '{\nfloat3 ret = 0;\n'
        defs = '#define rad _rad_ang.x\n#define ang _rad_ang.y\n#define uv _uv.xy\n#define uv_orig _uv.zw\n'
    else:
        sig = 'void PS(float4 _vDiffuse : COLOR, float2 _uv : TEXCOORD0, float2 _rad_ang : TEXCOORD1, out float4 _return_value : COLOR)'
        entry = '{\nfloat3 ret = 0;\n'
        defs = '#define rad _rad_ang.x\n#define ang _rad_ang.y\n#define uv _uv.xy\n#define uv_orig _uv.xy\n#define hue_shader _vDiffuse.xyz\n'
    # projectM erases the shader's own sampler and texsize declarations, then declares what's referenced.
    pre = re.sub(r'sampler(2D|3D|)(\s+|\().*', '', pre)
    pre = re.sub(r'float4\s+texsize_.*', '', pre)
    names = set(m.lower() for m in re.findall(r'\bsampler_(\w+)', pre + body, flags=re.I) if m.lower() != 'state')
    names |= {'main'}
    if re.search(r'GetBlur3', body): names |= {'blur1', 'blur2', 'blur3'}
    elif re.search(r'GetBlur2', body): names |= {'blur1', 'blur2'}
    elif re.search(r'GetBlur1', body): names |= {'blur1'}
    texsizes = set(m.lower() for m in re.findall(r'\btexsize_(\w+)', pre + body, flags=re.I))
    decls = ''.join(('sampler3D' if 'noisevol' in n else 'sampler2D') + ' sampler_%s;\n' % n for n in sorted(names))
    decls += ''.join('float4 texsize_%s;\n' % n for n in sorted(set(n for n in names if not n.startswith('blur')) | texsizes))
    src = decls + HEADER + '\n' + defs + pre + sig + '\n' + entry + body + '\n_return_value = float4(ret.xyz, 1.0);\n}\n'
    return src, names

STANDARD = re.compile(r'^(main|blur[123]|noise_(lq|mq|hq)(_lite)?|noisevol_(lq|hq)|rand\d\d(_.*)?|fw_main|fc_main|pw_main|pc_main|(fw|fc|pw|pc)_(noise_(lq|mq|hq)(_lite)?|blur[123]|noisevol_(lq|hq)|rand\d\d.*))$')

def work(job):
    path, kind = job
    code = extract(path, kind)
    if code is None: return None
    src, info = assemble(code, kind)
    if src is None: return (path, kind, 'FAIL', 'assemble: ' + info, False)
    images = any(not STANDARD.match(n) for n in info)
    with tempfile.NamedTemporaryFile('w', suffix='.hlsl', delete=False) as f:
        f.write(src); name = f.name
    try:
        r = subprocess.run([TOOL, name], capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        os.unlink(name); return (path, kind, 'FAIL', 'timeout', images)
    os.unlink(name)
    if r.returncode == 0: return (path, kind, 'OK', '', images)
    err = (r.stderr.strip().splitlines() or ['?'])
    first = next((l for l in err if 'error' in l.lower()), err[-1])
    first = re.sub(r'^.*?\(\d+\)\s*:\s*', '', first)
    first = re.sub(r"'[^']*'", "'_'", first)
    return (path, kind, 'FAIL', first[:90], images)

if __name__ == '__main__':
    root, limit = sys.argv[1], int(sys.argv[2])
    files = []
    for d, _, fs in os.walk(root):
        files += [os.path.join(d, f) for f in fs if f.endswith('.milk')]
    files.sort()
    if limit: files = files[::max(1, len(files) // limit)][:limit]
    jobs = [(f, k) for f in files for k in ('warp', 'comp')]
    with ThreadPoolExecutor(8) as ex: results = [r for r in ex.map(work, jobs) if r]
    for kind in ('warp', 'comp'):
        rs = [r for r in results if r[1] == kind]
        ok = sum(1 for r in rs if r[2] == 'OK')
        noimg = [r for r in rs if not r[4]]
        okno = sum(1 for r in noimg if r[2] == 'OK')
        print(f'{kind}: {len(rs)} shaders, {ok} convert ({100*ok//max(len(rs),1)}%); without disk images {len(noimg)}, {okno} convert ({100*okno//max(len(noimg),1)}%)')
        errs = collections.Counter(r[3] for r in rs if r[2] == 'FAIL')
        for e, n in errs.most_common(8): print(f'   {n:5d}  {e}')
    json.dump(results, open(os.path.join(S, 'results.json'), 'w'))
