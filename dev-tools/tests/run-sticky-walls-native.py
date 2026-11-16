"""Build and run native wall tests on an isolated mp_galaxy server; no live restart."""
from pathlib import Path
import subprocess,os,re
root=Path(__file__).resolve().parents[2]
out=root/'dev-tools/local/sticky-wall-spike';out.mkdir(exist_ok=True)
asm=(root/'cod4x-server/src/asmsource/_bg_slidemove.asm').read_text()
asm=asm.replace('SECTION .text','extern StickyTrace\nSECTION .text',1)
asm=asm.replace('extern PM_playerTrace','extern StickyTestPlayerTrace').replace('call PM_playerTrace','call StickyTestPlayerTrace')
asm=asm.replace('\tcall StickyTestPlayerTrace\n','\tcall StickyTestPlayerTrace\n\tpushad\n\tpush ebp\n\tcall StickyTrace\n\tadd esp, 4\n\tpopad\n',1)
(out/'slide-live-test.asm').write_text(asm)
BUILD_SCRIPT = "set -e\ncd /workspace/cod4x-server\nnasm -f elf ../dev-tools/local/sticky-wall-spike/slide-live-test.asm -o ../dev-tools/local/sticky-wall-spike/slide-live-test.o\ngcc -m32 -msse2 -mfpmath=sse -fno-pie -O0 -c ../dev-tools/tests/sticky-walls-native.c -o ../dev-tools/local/sticky-wall-spike/trace.o\ngcc -m32 -msse2 -mfpmath=sse -fno-pie -O1 -Wall -Werror -DOpenCJ_StickyWallRecovery=StickyWallFixed -c src/opencj_stickywalls.c -o ../dev-tools/local/sticky-wall-spike/fixed-test.o\npython3 - <<'PY'\nimport subprocess,shlex\nfrom pathlib import Path\nout=subprocess.check_output(['make','-n','TARGETNAME=cod4x18_sticky_live_test'],text=True)\nline=next(l for l in out.splitlines() if l.startswith('gcc ') and ' -o bin/cod4x18_sticky_live_test ' in l)\nargs=shlex.split(line)\nargs[args.index('obj/_bg_slidemove.o')]='../dev-tools/local/sticky-wall-spike/slide-live-test.o'\nargs[args.index('bin/cod4x18_sticky_live_test')]='../dev-tools/local/sticky-wall-spike/cod4x18_sticky_live_test'\nargs[args.index('obj/opencj_stickywalls.o')]='../dev-tools/local/sticky-wall-spike/fixed-test.o'\nargs.append('../dev-tools/local/sticky-wall-spike/trace.o')\nsubprocess.run(args,check=True)\nPY\n"
(out/'build-live-test.sh').write_text(BUILD_SCRIPT)
build=subprocess.run(['docker','compose','run','--rm','--no-deps','--entrypoint','sh','server','/workspace/dev-tools/local/sticky-wall-spike/build-live-test.sh'],cwd=root/'dev-tools',capture_output=True,text=True)
(out/'regression-build.log').write_text(build.stdout+build.stderr)
assert build.returncode==0,'See '+str(out/'regression-build.log')
for mode in ['0','1']:
 env=os.environ.copy();env['STICKY_TEST']=mode
 result=subprocess.run(['python3',str(root/'dev-tools/tests/run-sticky-walls-server.py'),'mp_galaxy'],env=env,capture_output=True,text=True)
 (out/('suite-'+mode+'.txt')).write_text(result.stdout+result.stderr)
 assert result.returncode==0,'Isolated runner failed'
 alt=[l for l in result.stdout.splitlines() if 'NATIVE ALTERNATE ' in l]
 bad=[l for l in alt if 'stalls=0 ' not in l]
 assert len(alt)==1728
 assert not bad if mode=='1' else bool(bad)
 assert 'NATIVE REGRESSION COMPLETE cases=40 failures=0' in result.stdout
 for setting in ['0','1']:
  cmd=[l for l in result.stdout.splitlines() if 'NATIVE COMMAND mode='+setting+' ' in l]
  assert len(cmd)==700
  if setting=='1':assert all('stalls=0 ' in l for l in cmd)
 print('PASS: toggle='+mode+', alternating='+str(len(alt))+', stalled='+str(len(bad))+', unrelated parity=40, full Pmove sequences=1400',flush=True)
