"""Static checks for VoxClip.App XAML that the Mac cannot compile: event handlers exist in the code-behind with the
right parameter count, and x:Bind paths start at a member of the page or of the template's x:DataType.
Usage: xamlcheck.py <App dir>. Approximate by design; it reports, the Windows XAML compiler decides."""
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

app = pathlib.Path(sys.argv[1])
XAML = 'http://schemas.microsoft.com/winfx/2006/xaml'
EVENTS = {'Click', 'Tapped', 'Loaded', 'Unloaded', 'KeyDown', 'KeyUp', 'Invoked', 'SelectionChanged', 'ItemInvoked', 'SizeChanged',
          'CloseButtonClick', 'PaneToggleRequested', 'TextChanged', 'ManipulationCompleted', 'DragOver', 'Drop', 'DragLeave',
          'DragEnter', 'ContainerContentChanging', 'Toggled', 'ValueChanged', 'QuerySubmitted', 'Closed', 'Opened', 'ItemClick',
          'PointerEntered', 'PointerExited', 'GotFocus', 'LostFocus', 'DoubleTapped', 'RightTapped', 'ActualThemeChanged'}
sources = {p: p.read_text() for p in app.rglob('*.cs') if '/obj/' not in str(p) and '/bin/' not in str(p)}
problems = 0


def members_of(type_name):
    """Public/internal property, field and method names declared for a type name across the App sources."""
    names = set()
    for text in sources.values():
        for match in re.finditer(r'(?:class|record)\s+' + re.escape(type_name) + r'\b[^{]*\{', text):
            depth, start = 0, match.end() - 1
            for index in range(start, len(text)):
                depth += text[index] == '{'
                depth -= text[index] == '}'
                if depth == 0:
                    body = text[start:index]
                    break
            else:
                continue
            names |= set(re.findall(r'(?:public|internal)\s+(?:static\s+)?(?:override\s+)?[\w<>\[\]?,. ]+?\s+(\w+)\s*(?:\{|=>|\(|=|;)', body))
            header = text[match.start():match.end()]
            names |= set(re.findall(r'\b(?:string|bool|int|double|MediaTile\??|CaptionCard\??|MediaStatus|TranscriptionStatus\??)\s+(\w+)', header))
    return names


for path in sorted(app.rglob('*.xaml')):
    if '/obj/' in str(path):
        continue
    root = ET.parse(path).getroot()
    cls = root.get('{%s}Class' % XAML)
    if not cls:
        continue
    code = sources.get(path.with_suffix('.xaml.cs'), '')
    page_members = members_of(cls.rsplit('.', 1)[1]) | set(re.findall(r'\b(\w+)\s*\(', code))
    # x:Name elements are fields of the page, so x:Bind paths may start at them.
    page_members |= {e.get('{%s}Name' % XAML) for e in root.iter() if e.get('{%s}Name' % XAML)}

    def walk(element, data_type):
        global problems
        local = element.tag.split('}')[-1]
        declared = element.get('{%s}DataType' % XAML)
        if local == 'DataTemplate' and declared:
            data_type = declared.split(':')[-1]
        for name, value in element.attrib.items():
            attr = name.split('}')[-1]
            if attr in EVENTS and re.fullmatch(r'\w+', value):
                handler = re.search(r'(?:async\s+)?void\s+' + value + r'\s*\(([^)]*)\)', code)
                if not handler:
                    print(f'{path.name}: {local}.{attr} -> missing handler {value}')
                    problems += 1
                elif len([p for p in handler.group(1).split(',') if p.strip()]) != 2:
                    print(f'{path.name}: {local}.{attr} -> {value} does not take (sender, args)')
                    problems += 1
            for bind in re.findall(r'\{x:Bind\s+([^,}]+)', value):
                first = re.split(r'[.(]', bind.strip())[0]
                if ':' in first or not first:
                    continue
                pool = members_of(data_type) if data_type else page_members
                if first not in pool:
                    print(f'{path.name}: {local}.{attr} -> x:Bind {bind.strip()} not found on {data_type or cls}')
                    problems += 1
        for child in element:
            walk(child, data_type)

    walk(root, None)
print('problems:', problems)

sys.exit(1 if problems else 0)
