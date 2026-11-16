"""Build client assets in an isolated directory using explicit installation paths."""
from pathlib import Path
import ctypes as C,hashlib,json,os,shutil,struct,subprocess,sys,runpy,contextlib,io,zipfile
ROOT=Path(__file__).resolve().parents[1]
import argparse,re
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mod-tools', type=Path, required=True)
parser.add_argument("--game-dir", type=Path, required=True)
args=parser.parse_args()
INSTALL=args.mod_tools.resolve()
SCRIPT=INSTALL/'Mods/opencj/cod4/makeMod.py'
assert ROOT.parent==SCRIPT.parent and ROOT.name.startswith('_'), 'Build root must be a private Mod Tools subfolder'
TOOL=ROOT/'toolroot'; RAW=TOOL/'raw'; COD4=TOOL/'Mods/proof/cod4'
for p in [TOOL/'bin',RAW,COD4,TOOL/'zone_source',TOOL/'zone_source/english/assetlist',TOOL/'zone/english',ROOT/'evidence']:
    p.mkdir(parents=True,exist_ok=True)
watched=[SCRIPT,SCRIPT.parent/'mod.csv',SCRIPT.parent.parent/'mod.ff',SCRIPT.parent.parent/'z_opencj.iwd',INSTALL/'raw/shader_bin/shader_names',INSTALL/'zone_source/mod.csv',INSTALL/'zone/english/mod.ff']
before={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched if p.exists()}
for name in ['linker_pc.exe','MSVCP71.DLL','msvcr71.dll','mss32.dll']:
    shutil.copy2(INSTALL/'bin'/name,TOOL/'bin'/name)
for p in INSTALL.glob('*.dll'):
    shutil.copy2(p,TOOL/p.name)
shutil.copy2(INSTALL/'raw/fileSysCheck.cfg',RAW/'fileSysCheck.cfg')
for name in ['techsets','techniques','statemaps','shader_bin','ui','ui_mp','mp']:
    if not (RAW/name).exists():
        shutil.copytree(INSTALL/'raw'/name,RAW/name)
for folder in ['materials','material_properties']:
    (RAW/folder).mkdir(exist_ok=True)
    for name in ['white']:
        p=INSTALL/'raw'/folder/name
        if p.exists():shutil.copy2(p,RAW/folder/name)
# Complete builds also need stock model, sound and UI-material dependencies.
# Copy missing files into the private tree; never junction or hard-link shared inputs.
for folder in ['materials','material_properties','images','xmodel','xmodelparts','xmodelsurfs','xanim','soundaliases','sound','fx','animtrees','english','info','vision']:
    source_folder=INSTALL/'raw'/folder
    if not source_folder.exists():continue
    for source_file in source_folder.rglob('*'):
        if not source_file.is_file():continue
        target=RAW/folder/source_file.relative_to(source_folder)
        if not target.exists():
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source_file,target)
shutil.copytree(ROOT/'stage',COD4,dirs_exist_ok=True)
for folder in ['techsets','techniques']:
    shutil.copytree(ROOT/'stage'/folder,RAW/folder,dirs_exist_ok=True)
# DirectX's system HLSL compiler, no downloaded executables or client modifications.
dll=C.WinDLL('d3dcompiler_47.dll')
compile=dll.D3DCompile
compile.argtypes=[C.c_void_p,C.c_size_t,C.c_char_p,C.c_void_p,C.c_void_p,C.c_char_p,C.c_char_p,C.c_uint,C.c_uint,C.POINTER(C.c_void_p),C.POINTER(C.c_void_p)]
compile.restype=C.c_long
def method(blob,index,restype,*args):
    vt=C.cast(blob,C.POINTER(C.POINTER(C.c_void_p))).contents
    return C.WINFUNCTYPE(restype,C.c_void_p,*args)(vt[index])
def blob_data(blob):
    ptr=method(blob,3,C.c_void_p)(blob)
    size=method(blob,4,C.c_size_t)(blob)
    data=C.string_at(ptr,size)
    method(blob,2,C.c_ulong)(blob)
    return data
source=(ROOT/'source/opencj_flag_atlas.hlsl').read_bytes()
out=C.c_void_p();err=C.c_void_p()
hr=compile(source,len(source),b'opencj_flag_atlas.hlsl',None,None,b'main',b'ps_2_0',1<<15,0,C.byref(out),C.byref(err))
messages=blob_data(err).decode(errors='replace') if err.value else ''
(ROOT/'evidence/compiler.log').write_text(messages)
if hr<0:raise RuntimeError(f'D3DCompile {hr}: {messages}')
bytecode=blob_data(out)
assert bytecode[:4]==struct.pack('<I',0xffff0200)
name='opencj_flag_atlas';h=0
for c in name.encode():h=((h*33)^c)&0xffffffff
file_id=0xffffffff-int.from_bytes(h.to_bytes(4,'little'),'big')
names=RAW/'shader_bin/shader_names';data=names.read_bytes()
vs=struct.unpack_from('<I',data)[0];pspos=4+vs*8;ps=struct.unpack_from('<I',data,pspos)[0]
assert len(data)==8+(vs+ps)*8
records=[struct.unpack_from('<II',data,pspos+4+i*8) for i in range(ps)]
assert all(a[0]<b[0] for a,b in zip(records,records[1:]))
existing=[x for x in records if x[0]==h]
assert not existing or existing==[(h,file_id)]
if not existing:records.append((h,file_id))
records.sort()
names.write_bytes(data[:pspos]+struct.pack('<I',len(records))+b''.join(struct.pack('<II',*x) for x in records))
shader_path=RAW/'shader_bin'/f'ps_2_0_{file_id:08x}'
shader_path.write_bytes(struct.pack('<I',len(bytecode))+bytecode)
(ROOT/'evidence/compiled-shader.bin').write_bytes(bytecode)
# The stock linker also emits an SM3 technique variant.
out3=C.c_void_p();err3=C.c_void_p()
hr3=compile(source,len(source),b'opencj_flag_atlas.hlsl',None,None,b'main',b'ps_3_0',1<<15,0,C.byref(out3),C.byref(err3))
messages3=blob_data(err3).decode(errors='replace') if err3.value else ''
if hr3<0:raise RuntimeError(messages3)
bytecode3=blob_data(out3)
(RAW/'shader_bin'/f'ps_3_0_{file_id:08x}').write_bytes(struct.pack('<I',len(bytecode3))+bytecode3)
(ROOT/'evidence/compiled-shader-sm3.bin').write_bytes(bytecode3)
disassemble=dll.D3DDisassemble
disassemble.argtypes=[C.c_void_p,C.c_size_t,C.c_uint,C.c_char_p,C.POINTER(C.c_void_p)]
disassemble.restype=C.c_long
asm=C.c_void_p();hr=disassemble(bytecode,len(bytecode),0,None,C.byref(asm))
if hr>=0:(ROOT/'evidence/shader.asm').write_bytes(blob_data(asm))
print('Shader compiled:',len(bytecode),'bytes, isolated lookup',shader_path.name,flush=True)
# Use the existing unmodified script, with its expected directory structure isolated.
original_run=subprocess.run
def bounded_run(args,**kwargs):
    assert args[0]=='linker_pc.exe',args
    try:
        return original_run(args,timeout=45,**kwargs)
    except (subprocess.CalledProcessError,subprocess.TimeoutExpired) as e:
        text=(e.stdout or b'') if isinstance(e.stdout,bytes) else (e.stdout or '').encode()
        (ROOT/'evidence/linker-error.log').write_bytes(text)
        raise
def run_existing_make_mod():
    stdout=io.StringIO();stderr=io.StringIO();returncode=0
    prior_cwd=Path.cwd()
    try:
        os.chdir(COD4);subprocess.run=bounded_run
        with contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
            try:runpy.run_path(str(SCRIPT),run_name='__main__')
            except SystemExit as e:returncode=e.code or 0
            except subprocess.TimeoutExpired:
                returncode=124
                print('Isolated linker timed out; its output is in linker-error.log.')
    finally:
        os.chdir(prior_cwd);subprocess.run=original_run
    return subprocess.CompletedProcess([str(SCRIPT)],returncode,stdout.getvalue(),stderr.getvalue())

def extract_stock_images(names):
    missing=set(names)
    for archive in sorted((args.game_dir/'main').glob('*.iwd')):
        with zipfile.ZipFile(archive) as source:
            lookup={name.lower():name for name in source.namelist()}
            for name in list(missing):
                entry=lookup.get(name.lower())
                if entry is None:continue
                target=RAW/name
                assert name.startswith('images/') and target.resolve().is_relative_to((RAW/'images').resolve())
                target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(source.read(entry));missing.remove(name)
        if not missing:break
    if missing:raise RuntimeError('Missing stock images in --game-dir: '+', '.join(sorted(missing)))
    print('Copied',len(names),'stock image dependencies into private raw files.',flush=True)

for attempt in range(5):
    result=run_existing_make_mod()
    (ROOT/'evidence'/f'makeMod-attempt-{attempt+1}.log').write_text(result.stdout+'\n'+result.stderr)
    missing=set(re.findall(r"ERROR: image '(images/[^']+\.iwi)' is missing",result.stdout))
    if not missing:break
    if attempt==4:raise RuntimeError('Stock image dependency extraction did not resolve linker errors')
    extract_stock_images(missing)
(ROOT/'evidence/makeMod.log').write_text(result.stdout+'\n'+result.stderr)
after={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in watched if p.exists()}
changed=[p for p in before if before[p]!=after.get(p)]
(ROOT/'evidence/build-isolation.json').write_text(json.dumps({'before':before,'after':after,'shared_files_changed':changed,'makeMod_sha256':before[str(SCRIPT)],'returncode':result.returncode},indent=2))
if changed:print('Other work changed shared outputs concurrently; left untouched:',changed)
print(result.stdout[-5000:]);print(result.stderr[-2000:])
if result.returncode or not (COD4.parent/'mod.ff').exists():raise RuntimeError('See makeMod.log; no usable proof fastfile')
assert 'Menu load error' not in result.stdout and 'UNRECOVERABLE ERROR' not in result.stdout and not re.search(r'(?m)^ERROR:',result.stdout), 'See makeMod.log'
with zipfile.ZipFile(COD4.parent/'z_opencj.iwd','a',compression=zipfile.ZIP_DEFLATED) as z:
    for license_file in (ROOT/'stage/licenses').glob('*'):
        if license_file.is_file():z.write(license_file,'licenses/'+license_file.name)
print('BUILD COMPLETE; all build writes were confined to the private toolroot.')
