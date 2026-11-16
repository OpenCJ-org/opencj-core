"""Decode the supplied MP3s with libsndfile; make quiet 44.1 kHz PCM16 game assets."""
from pathlib import Path
import array, ctypes as C, ctypes.util, json, math, sys, wave
root=Path(__file__).resolve().parents[2]
lib=C.CDLL(ctypes.util.find_library('sndfile'))
class Info(C.Structure):
    _fields_=[('frames',C.c_int64),('samplerate',C.c_int),('channels',C.c_int),('format',C.c_int),('sections',C.c_int),('seekable',C.c_int)]
lib.sf_open.argtypes=[C.c_char_p,C.c_int,C.POINTER(Info)];lib.sf_open.restype=C.c_void_p
lib.sf_readf_float.argtypes=[C.c_void_p,C.POINTER(C.c_float),C.c_int64];lib.sf_readf_float.restype=C.c_int64
lib.sf_close.argtypes=[C.c_void_p]
report=[]
for source,target in [('freesound_gamestudio-level-complete-394515.mp3','route_complete.wav'),('universfield-victory-fanfare-152480.mp3','route_record.wav')]:
    path=root/'client-mod/audio-source'/source
    info=Info();handle=lib.sf_open(str(path).encode(),0x10,C.byref(info))
    if not handle:raise RuntimeError('Cannot decode '+source)
    try:
        raw=(C.c_float*(info.frames*info.channels))()
        count=lib.sf_readf_float(handle,raw,info.frames)
        # MP3 frame estimates can include encoder padding beyond the decoded end.
        assert 0<count<=info.frames and info.channels in (1,2)
        samples=list(raw[:count*info.channels])
    finally:lib.sf_close(handle)
    if info.samplerate!=44100:
        ratio=info.samplerate/44100
        samples=[samples[min(int(i*ratio),count-1)*info.channels+c]*(1-(i*ratio%1))+samples[min(int(i*ratio)+1,count-1)*info.channels+c]*(i*ratio%1) for i in range(round(count/ratio)) for c in range(info.channels)]
    peak=max(abs(v) for v in samples)
    rms=math.sqrt(sum(v*v for v in samples)/len(samples))
    # Never amplify the originals. Cap both peaks (-6 dBFS) and RMS (-20 dBFS).
    gain=min(1,10**(-6/20)/peak,10**(-20/20)/rms)
    pcm=array.array('h',(round(v*gain*32767) for v in samples))
    if sys.byteorder!='little':pcm.byteswap()
    out=root/'client-mod/cod4/sound/opencj'/target;out.parent.mkdir(parents=True,exist_ok=True)
    with wave.open(str(out),'wb') as f:
        f.setnchannels(info.channels);f.setsampwidth(2);f.setframerate(44100);f.writeframes(pcm.tobytes())
    report.append(dict(source=source,output=target,seconds=round(len(samples)/info.channels/44100,3),channels=info.channels,gain_db=round(20*math.log10(gain),2),peak_dbfs=round(20*math.log10(peak*gain),2),rms_dbfs=round(20*math.log10(rms*gain),2),alias_volume=0.5))
print(json.dumps(report,indent=2))
