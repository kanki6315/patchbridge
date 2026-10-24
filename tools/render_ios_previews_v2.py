#!/usr/bin/env python3
"""Silent editorial preview cut: native motion, kinetic Archivo type, purposeful close-ups.

Uses Pillow and the existing brand Archivo font (converted to TTF). Captures are
made with capture_ios_previews.py.
"""
import argparse, json, os, subprocess, math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('folder',type=Path)
p.add_argument('--layouts',nargs='+',default=['iphone','duo','ipad'])
p.add_argument('--font',type=Path,default=Path('build/ios-preview-design/Archivo-ExtraBold.ttf'))
a=p.parse_args(); root=a.folder.resolve(); manifest=json.loads((root/'raw/capture.json').read_text())
ffmpeg=os.environ.get('FFMPEG','ffmpeg'); ffprobe=os.environ.get('FFPROBE','ffprobe')
FPS=30; DURATION=25
scenes=[(0,2.5,('Your rig.','Within reach.')),(2.5,6.5,('Dial it','in.')),
        (6.5,12.5,('Make it','exact.')),(12.5,19,('Stay in','tune.')),
        (19,23,('Save it.','Keep playing.')),(23,25,('Patchbridge.','Your tone. In reach.'))]
def probe(path): return json.loads(subprocess.check_output([ffprobe,'-v','error','-show_streams','-show_format','-of','json',str(path)]))
def ease(x): return 1-(1-max(0,min(1,x)))**4

def crop_for(family,scene):
    # Editorial crops never reconstruct UI. Overview and saving show the whole screen.
    if family=='ipad':
        return [(0,0,1,1),(.51,.40,.985,.83),(.51,.40,.985,.83),(.30,.06,.72,.48),(0,0,1,1),(0,0,1,1)][scene]
    if family=='duo':
        return [(0,0,1,1),(0,.11,.80,.98),(0,0,1,1),(0,0,.94,.98),(0,0,1,1),(0,0,1,1)][scene]
    return [(0,0,1,1),(.04,.07,.96,.81),(0,.06,1,.98),(0,.15,1,.99),(0,0,1,1),(0,0,1,1)][scene]

for family in a.layouts:
    w,h=(1200,1600) if family=='ipad' else (886,1920)
    assets=root/'assets'/family; assets.mkdir(parents=True,exist_ok=True)
    info=manifest[family]; source=root/'raw'/info['source']
    native=next(s for s in probe(source)['streams'] if s['codec_type']=='video')
    sw=min(native['width'],int(w*1.3)//2*2); sh=round(native['height']*sw/native['width']/2)*2
    # Remove idle overview / return-to-overview holds; retain real-time editing and saving.
    offset=info['trim_start']
    graph=(f'[0:v]tpad=stop_mode=clone:stop_duration=6,fps=30,trim=start={offset},setpts=PTS-STARTPTS,split=3[a][b][c];'
           '[a]trim=start=0:end=2.5,setpts=PTS-STARTPTS[a0];'
           '[b]trim=start=4:end=14,setpts=PTS-STARTPTS[b0];'
           '[c]trim=start=16:end=28.5,setpts=PTS-STARTPTS[c0];'
           f'[a0][b0][c0]concat=n=3:v=1:a=0,fps=30,scale={sw}:{sh}:flags=lanczos,setsar=1[v]')
    dec=subprocess.Popen([ffmpeg,'-v','error','-i',str(source),'-filter_complex',graph,'-map','[v]','-an','-r','30','-fps_mode','cfr','-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
    out=root/f'Patchbridge-{family}-Preview-v2-{w}x{h}.mp4'
    enc=subprocess.Popen([ffmpeg,'-v','error','-y','-f','rawvideo','-pix_fmt','rgb24','-s',f'{w}x{h}','-r','30','-i','-',
        '-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t',str(DURATION),'-map','0:v','-map','1:a',
        '-c:v','libx264','-preset','fast','-profile:v','high','-level:v','4.0','-pix_fmt','yuv420p',
        '-b:v','10M','-minrate','10M','-maxrate','10M','-bufsize','20M','-x264-params','nal-hrd=cbr:force-cfr=1',
        '-c:a','aac','-b:a','256k','-movflags','+faststart',str(out)],stdin=subprocess.PIPE)
    fonts={size:ImageFont.truetype(str(a.font),size) for size in [28,32,40,48,80,88,96,104,112]}
    small=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',26 if family!='ipad' else 30)
    samples=[.8,3.5,5,8.8,11.5,14.5,17.5,20.5,22,24]
    previous_scene=-1; previous_frame=None; frozen=None
    try:
        for frame in range(FPS*DURATION):
            data=dec.stdout.read(sw*sh*3)
            if len(data)!=sw*sh*3: raise RuntimeError(f'{family}: incomplete native footage at frame {frame}')
            nativeframe=Image.frombytes('RGB',(sw,sh),data)
            t=frame/FPS
            si=next(i for i,(s,e,_) in enumerate(scenes) if s<=t<e)
            start,end,lines=scenes[si]; local=t-start
            if si!=previous_scene:
                frozen=previous_frame
                previous_scene=si
            im=Image.new('RGB',(w,h),'#0d0e0a')
            # Layout stays stable while the camera makes one gentle 2% approach.
            crop=crop_for(family,si)
            if si == 3 and local > 4.1:
                pullback = ease((local - 4.1) / .65)
                crop = tuple(value + (full - value) * pullback for value, full in zip(crop, (0,0,1,1)))
            zoom=1+.025*ease(local/(end-start))
            cx=(crop[0]+crop[2])/2; cy=(crop[1]+crop[3])/2
            cw=(crop[2]-crop[0])/zoom; ch=(crop[3]-crop[1])/zoom
            box=((cx-cw/2)*sw,(cy-ch/2)*sh,(cx+cw/2)*sw,(cy+ch/2)*sh)
            top=345 if family!='ipad' else 320
            bottom=96 if si==5 else 58
            available_h=h-top-bottom
            scale=min((w-64)/(cw*sw),available_h/(ch*sh))
            vw=int(cw*sw*scale); vh=int(ch*sh*scale)
            ui=nativeframe.resize((vw,vh),Image.Resampling.BICUBIC,box=box)
            x=(w-vw)//2; y=top+(available_h-vh)//2+int(18*(1-ease(local/.5)))
            im.paste(ui,(x,y))
            d=ImageDraw.Draw(im)
            # Staggered, clipped line reveals: short movements, no bounce or flashing.
            for line_no,line in enumerate(lines):
                size=(104 if family!='ipad' else 112)
                if si==5: size=88 if line_no==0 else (40 if family!='ipad' else 48)
                f=fonts[size]
                while d.textbbox((0,0),line,font=f)[2]>w-104:
                    size-=1; f=ImageFont.truetype(str(a.font),size)
                line_top=65+line_no*116 if family!='ipad' else 52+line_no*126
                if si==5: line_top=80+line_no*115
                progress=ease((local-line_no*.09)/.42)
                layer=Image.new('RGBA',(w,145),(0,0,0,0));ld=ImageDraw.Draw(layer)
                ld.text((48,int(50*(1-progress))),line,font=f,fill=('#f2f2ee' if line_no==0 else '#d1e14a'),anchor='lt')
                im.paste(layer,(0,line_top),layer)
            # A restrained transition preserves the sense of one continuous session.
            if frozen is not None and local<.18:
                im=Image.blend(frozen,im,ease(local/.18))
            # Product identity lives below the demonstration, never as a tiny eyebrow.
            d=ImageDraw.Draw(im)
            if si==5:
                d.text((w/2,h-59),'Requires Quad Cortex + Patchbridge for Mac',font=small,fill='#b1b2ab',anchor='mm')
            else:
                d.text((w-40,h-26),'Patchbridge',font=fonts[28 if family!='ipad' else 32],fill='#b1b2ab',anchor='rs')
            for sample in samples:
                if frame==round(sample*FPS): im.save(assets/f'check-{sample:04.1f}.png')
            enc.stdin.write(im.tobytes()); previous_frame=im
        enc.stdin.close()
        if enc.wait()!=0: raise RuntimeError('Video encoder failed')
        dec.stdout.close(); dec.wait()
    finally:
        if enc.poll() is None: enc.kill()
        if dec.poll() is None: dec.kill()
    result=probe(out);v=next(s for s in result['streams'] if s['codec_type']=='video');au=next(s for s in result['streams'] if s['codec_type']=='audio')
    assert (v['width'],v['height'],v['r_frame_rate'],v['codec_name'],v['level'])==(w,h,'30/1','h264',40)
    assert abs(float(result['format']['duration'])-DURATION)<.1 and au['channels']==2 and au['sample_rate']=='48000'
    assert int(result['format']['size'])<500_000_000
    (assets/'validation.json').write_text(json.dumps(result,indent=2)+'\n')
    (assets/'edit.json').write_text(json.dumps({'duration':DURATION,'source_trim':offset,'source_ranges':[[0,2.5],[4,14],[16,28.5]],'captions':scenes,'audio':'silent'},indent=2)+'\n')
    print(f'Rendered and validated {family}: {out}',flush=True)
