#!/usr/bin/env python3
"""Compose a 26-second branded preview from recorded fixture clips or a labeled still-image review cut."""
import argparse
import json
import os
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('screenshots', type=Path)
    parser.add_argument('--recording', type=Path, help='Screen recording of the 28-second fixture sequence, cropped to the app window')
    parser.add_argument('--start', type=float, default=0, help='Time in the recording where the first 5.6-second clip begins')
    parser.add_argument('--crop', help='Optional recording crop as width:height:x:y in source pixels')
    parser.add_argument('--reuse-backgrounds', action='store_true', help='Reuse existing 1080p scene layouts')
    args = parser.parse_args()
    if args.crop and not re.fullmatch(r'[1-9][0-9]*:[1-9][0-9]*:[0-9]+:[0-9]+', args.crop):
        parser.error('--crop must be width:height:x:y with positive dimensions')
    crop_filter = f'crop={args.crop},' if args.crop else ''
    source = args.screenshots.resolve()
    ffmpeg = os.environ.get('FFMPEG', 'ffmpeg')
    ffprobe = os.environ.get('FFPROBE', 'ffprobe')
    if args.recording:
        if args.start < 0:
            raise ValueError('--start must be nonnegative')
        recording_info = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(args.recording.resolve())]))
        if not any(s['codec_type'] == 'video' for s in recording_info['streams']):
            raise ValueError('The recording has no video stream')
        if float(recording_info['format']['duration']) < args.start + 28:
            raise ValueError('The recording must contain the full 28-second sequence after --start')
    render = ['node', str(ROOT / 'tools/render_mac_previews.mjs'), str(source), '--video']
    if not args.reuse_backgrounds:
        subprocess.run(render, check=True)
    scenes = sorted((source / 'video-frames').glob('0*.png'))
    if len(scenes) != 5:
        raise ValueError('Expected five scenes')
    output = source / ('Patchbridge-Mac-Preview-Clips-1080p.mp4' if args.recording else 'Patchbridge-Mac-Preview-Review-Cut-1080p.mp4')
    if args.recording:
        # Decode the whole macOS VFR recording once before seeking. Direct input seeking
        # can land at inconsistent states when the source contains discontinuous timestamps.
        intermediate = ROOT / 'build/mac-preview-video/recording-normalized.mp4'
        intermediate.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'warning', '-y', '-i', str(args.recording.resolve()),
                        '-vf', crop_filter + 'fps=30,setpts=PTS-STARTPTS', '-an', '-c:v', 'libx264',
                        '-preset', 'fast', '-crf', '16', '-pix_fmt', 'yuv420p', '-fps_mode', 'cfr',
                        '-video_track_timescale', '90000', str(intermediate)], check=True)
        args.recording = intermediate
        crop_filter = ''
    command = [ffmpeg, '-hide_banner', '-loglevel', 'warning', '-y']
    for i, scene in enumerate(scenes):
        command += ['-loop', '1', '-framerate', '30', '-t', '5.6', '-i', str(scene)]
        if args.recording:
            command += ['-ss', str(args.start + 5.6 * i), '-t', '5.6', '-i', str(args.recording.resolve())]
    command += ['-f', 'lavfi', '-t', '26', '-i', 'anullsrc=r=48000:cl=stereo']
    normalize = 'format=yuv420p,setsar=1,settb=1/30,setpts=PTS-STARTPTS,fps=30'
    filters = []
    for i in range(5):
        if args.recording:
            filters += [f'[{2*i}:v]drawbox=x=1151:y=35:w=658:h=1010:color=0x050504:t=fill,{normalize}[b{i}]',
                        f'[{2*i+1}:v]{crop_filter}scale=658:1000:force_original_aspect_ratio=decrease,pad=658:1000:(ow-iw)/2:(oh-ih)/2:color=0x0d0e0a,{normalize},tpad=stop_mode=clone:stop_duration=6,trim=duration=5.6,setpts=PTS-STARTPTS[c{i}]',
                        f'[b{i}][c{i}]overlay=1151:35:shortest=1,{normalize}[v{i}]']
        else:
            filters.append(f'[{i}:v]{normalize}[v{i}]')
    last = 'v0'
    for i in range(1, 5):
        filters.append(f'[{last}][v{i}]xfade=transition=fade:duration=0.5:offset={5.1*i:.1f},fps=30[x{i}]')
        last = f'x{i}'
    filters.append(f'[{last}]tpad=stop_mode=clone:stop_duration=1,trim=duration=26,fps=30[final]')
    last = 'final'
    command += ['-filter_complex_threads', '1', '-filter_complex', ';'.join(filters),
                '-map', f'[{last}]', '-map', '10:a' if args.recording else '5:a', '-t', '26', '-r', '30',
                '-c:v', 'libx264', '-preset', 'medium', '-profile:v', 'high', '-level:v', '4.0',
                '-pix_fmt', 'yuv420p', '-b:v', '11M', '-minrate', '11M', '-maxrate', '11M',
                '-bufsize', '22M', '-x264-params', 'nal-hrd=cbr:force-cfr=1',
                '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
                '-c:a', 'aac', '-b:a', '256k', '-ar', '48000', '-ac', '2',
                '-movflags', '+faststart', str(output)]
    subprocess.run(command, check=True)
    verify_output(ffmpeg, ffprobe, output)

def verify_output(ffmpeg, ffprobe, output):
    source = output.parent
    probe = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(output)]))
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    assert (video['width'], video['height'], video['codec_name'], video['r_frame_rate']) == (1920, 1080, 'h264', '30/1')
    assert video['profile'] == 'High' and video['level'] == 40 and video['pix_fmt'] == 'yuv420p'
    assert abs(float(probe['format']['duration']) - 26) < 0.1
    assert abs(float(video['duration']) - 26) < 0.1
    assert int(video['nb_frames']) == 780
    assert 10_000_000 <= int(video['bit_rate']) <= 12_000_000
    assert output.stat().st_size < 500_000_000
    (source / 'video-specifications.json').write_text(json.dumps(probe, indent=2) + '\n')
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-ss', '5', '-i', str(output), '-frames:v', '1',
                    str(source / 'video-poster-5s.png')], check=True)
    print(f'Validated: {output}')

if __name__ == '__main__':
    main()
