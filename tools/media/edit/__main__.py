"""Offline media commands. Run from tools/media: python -m edit --help."""
import argparse
import json
from pathlib import Path
from PIL import Image
from .art import contact_sheet, cover, footer, headline, palette, shadow
from .audio import loudnorm
from .model import resolve_beats
from .render import render


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ['render', 'plan']:
        sub = commands.add_parser(command)
        sub.add_argument('edit', type=Path)
        sub.add_argument('--events', type=Path, required=True)
        if command == 'render':
            sub.add_argument('--out', type=Path, required=True)
            sub.add_argument('--work', type=Path, required=True)
            sub.add_argument('--encoder', choices=['mpeg4', 'h264_videotoolbox', 'h264_mf'], default='mpeg4')
    for command in ['audio', 'poster', 'contact']:
        sub = commands.add_parser(command)
        sub.add_argument('input', type=Path, nargs='+' if command == 'contact' else None)
        sub.add_argument('--out', type=Path, required=True)
        if command == 'poster':
            sub.add_argument('--headline', default='Cut video by its words.')
    args = parser.parse_args()
    if args.command in {'render', 'plan'}:
        spec = json.loads(args.edit.read_text())
        # Media paths are relative to the edit file, never to the caller's cwd.
        for clip in spec['clips']:
            clip['source'] = str((args.edit.parent / clip['source']).resolve())
            if clip.get('narration'):
                clip['narration'] = str((args.edit.parent / clip['narration']).resolve())
        if spec.get('audio'):
            spec['audio'] = str((args.edit.parent / spec['audio']).resolve())
        events = json.loads(args.events.read_text())
        if args.command == 'plan':
            print(json.dumps(resolve_beats(spec['clips'], spec.get('words', []), events), indent=2))
        else:
            render(spec, args.out, args.work, events, args.encoder)
    elif args.command == 'audio':
        loudnorm(args.input, args.out)
    elif args.command == 'contact':
        images = []
        for path in args.input:
            with Image.open(path, formats=('PNG', 'JPEG', 'WEBP', 'TIFF')) as image:
                images.append(image.copy())
        contact_sheet(images, [path.name for path in args.input]).save(args.out, optimize=True)
    else:
        base = Image.new('RGBA', (1280, 720), palette()['ink'])
        with Image.open(args.input, formats=('PNG', 'JPEG', 'WEBP', 'TIFF')) as image:
            thumb = cover(image.convert('RGBA'), 1120, 420)
        shadow(base, (80, 170, 1200, 590))
        base.alpha_composite(thumb, (80, 170))
        headline(base, args.headline)
        footer(base, 'VoxClip / clip.voxconvo.com')
        base.convert('RGB').save(args.out, optimize=True)


if __name__ == '__main__':
    main()
