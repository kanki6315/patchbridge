#!/usr/bin/env python3
"""Render matching captioned App Store previews from native simulator recordings.

Requires Pillow, ffmpeg and ffprobe. No UI is reconstructed or stretched.
"""
import argparse, json, subprocess, os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('folder', type=Path)
p.add_argument('--layouts', nargs='+', default=['iphone', 'duo', 'ipad'])
a = p.parse_args()
folder = a.folder.resolve()
manifest = json.loads((folder / 'raw/capture.json').read_text())
scenes = [(4, 'Your tone in your hands'), (4, 'Dial in your sound'), (8, 'Set the exact value'), (6, 'Stay in tune'), (6, 'Save your changes')]
font = '/System/Library/Fonts/Supplemental/Arial.ttf'
bold = '/System/Library/Fonts/Supplemental/Arial Bold.ttf'
ffmpeg = os.environ.get('FFMPEG', 'ffmpeg')
ffprobe = os.environ.get('FFPROBE', 'ffprobe')
def run(*args): subprocess.run([ffmpeg if args[0]=='ffmpeg' else args[0], *args[1:]], check=True)
for family, size in [('iphone', (886, 1920)), ('duo', (886, 1920)), ('ipad', (1200, 1600))]:
    if family not in a.layouts: continue
    w, h = size
    assets = folder / 'assets' / family
    assets.mkdir(parents=True, exist_ok=True)
    concat = []
    for i, (duration, title) in enumerate(scenes):
        im = Image.new('RGB', size, '#0d0e0a')
        d = ImageDraw.Draw(im)
        d.text((w/2, 52), 'PATCHBRIDGE', font=ImageFont.truetype(bold, 25 if family != 'ipad' else 30), fill='#d5ef60', anchor='mt')
        d.text((w/2, 102), title, font=ImageFont.truetype(bold, 53 if family != 'ipad' else 64), fill='#f2f2ee', anchor='mt')
        d.text((w/2, h-43), 'Requires Quad Cortex and Patchbridge for Mac', font=ImageFont.truetype(font, 22 if family != 'ipad' else 25), fill='#b1b2ab', anchor='mm')
        file = assets / f'{i}.png'
        im.save(file)
        concat += [f"file '{file}'", f'duration {duration}']
    concat += [f"file '{file}'"]
    listing = assets / 'backgrounds.txt'
    listing.write_text('\n'.join(concat)+'\n')
    background = assets / 'background.mp4'
    run('ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(listing), '-t', '28', '-r', '30', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(background))
    info = manifest[family]
    raw = folder / 'raw' / info['source']
    # Normalize VFR before trimming; simulator recordings can have sparse timestamps.
    norm = assets / 'normalized.mp4'
    run('ffmpeg', '-v', 'error', '-y', '-i', str(raw), '-vf', 'tpad=stop_mode=clone:stop_duration=5,fps=30,setpts=PTS-STARTPTS', '-an', '-c:v', 'libx264', '-preset', 'fast', '-crf', '16', '-pix_fmt', 'yuv420p', str(norm))
    out = folder / f'Patchbridge-{family}-App-Preview-{w}x{h}.mp4'
    box_height = h-260
    graph = f'[1:v]scale={w}:{box_height}:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1[app];[0:v][app]overlay=(W-w)/2:190+({box_height}-h)/2:shortest=1,format=yuv420p[v]'
    run('ffmpeg', '-v', 'error', '-y', '-i', str(background), '-ss', str(info['trim_start']), '-i', str(norm), '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-filter_complex', graph, '-map', '[v]', '-map', '2:a', '-t', '28', '-r', '30', '-c:v', 'libx264', '-preset', 'medium', '-profile:v', 'high', '-level:v', '4.0', '-b:v', '10M', '-minrate', '10M', '-maxrate', '10M', '-bufsize', '20M', '-x264-params', 'nal-hrd=cbr:force-cfr=1', '-c:a', 'aac', '-b:a', '256k', '-movflags', '+faststart', str(out))
    probe = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(out)]))
    video = next(s for s in probe['streams'] if s['codec_type']=='video')
    audio = next(s for s in probe['streams'] if s['codec_type']=='audio')
    assert (video['width'], video['height']) == size
    assert video['r_frame_rate'] == '30/1' and video['codec_name'] == 'h264'
    assert audio['channels'] == 2 and audio['sample_rate'] == '48000'
    assert 27.9 <= float(probe['format']['duration']) <= 28.1
    assert int(probe['format']['size']) < 500_000_000
    (assets / 'validation.json').write_text(json.dumps(probe, indent=2)+'\n')
    for sec in [1, 6, 10, 13, 18, 21, 23, 27]:
        run('ffmpeg', '-v', 'error', '-y', '-ss', str(sec), '-i', str(out), '-frames:v', '1', str(assets / f'check-{sec:02d}.png'))
    print('Rendered and validated ' + str(out), flush=True)
