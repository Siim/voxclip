"""Write Generated.g.cs: stub partial classes for what the WinUI XAML compiler generates (x:Name fields, InitializeComponent,
Bindings) so VoxClip.App's C# can be type-checked on macOS. Usage: gen.py <App dir> <out file>."""
import re, sys, pathlib
import xml.etree.ElementTree as ET

app = pathlib.Path(sys.argv[1])
PRESENTATION = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
XAML = 'http://schemas.microsoft.com/winfx/2006/xaml'
SPECIAL = {
    'Rectangle': 'Microsoft.UI.Xaml.Shapes', 'Ellipse': 'Microsoft.UI.Xaml.Shapes', 'Line': 'Microsoft.UI.Xaml.Shapes', 'Path': 'Microsoft.UI.Xaml.Shapes',
    'KeyboardAccelerator': 'Microsoft.UI.Xaml.Input', 'SolidColorBrush': 'Microsoft.UI.Xaml.Media', 'Storyboard': 'Microsoft.UI.Xaml.Media.Animation',
    'MicaBackdrop': 'Microsoft.UI.Xaml.Media', 'ResourceDictionary': 'Microsoft.UI.Xaml', 'Setter': 'Microsoft.UI.Xaml', 'Style': 'Microsoft.UI.Xaml',
    'DataTemplate': 'Microsoft.UI.Xaml', 'Thickness': 'Microsoft.UI.Xaml', 'Application': 'Microsoft.UI.Xaml',
    'VisualStateGroup': 'Microsoft.UI.Xaml', 'VisualState': 'Microsoft.UI.Xaml',
    'Run': 'Microsoft.UI.Xaml.Documents', 'Span': 'Microsoft.UI.Xaml.Documents', 'Hyperlink': 'Microsoft.UI.Xaml.Documents',
}
out = ['#pragma warning disable CS0169, CS0414, CS0649, CS8618', '']
for path in sorted(app.rglob('*.xaml')):
    if '/obj/' in str(path) or '/bin/' in str(path):
        continue
    root = ET.parse(path).getroot()
    cls = root.get('{%s}Class' % XAML)
    if not cls:
        continue
    ns, name = cls.rsplit('.', 1)
    fields = []
    def walk(element, templated):
        # Names inside templates belong to the template's own name scope, not to the class.
        yield element, templated
        local = element.tag.split('}')[-1]
        for child in element:
            yield from walk(child, templated or local in ('ControlTemplate', 'DataTemplate', 'ItemsPanelTemplate'))
    for element, templated in walk(root, False):
        field = element.get('{%s}Name' % XAML)
        if not field or element is root or templated:
            continue
        uri, local = element.tag[1:].split('}')
        if uri == PRESENTATION:
            space = SPECIAL.get(local, 'Microsoft.UI.Xaml.Controls')
        elif uri.startswith('using:'):
            space = uri[len('using:'):]
        else:
            raise SystemExit(f'unknown namespace {uri} in {path}')
        fields.append(f'    internal global::{space}.{local} {field} = null!;')
    body = '\n'.join(fields)
    out.append(f'namespace {ns}\n{{\npartial class {name}\n{{\n{body}\n    public void InitializeComponent() {{ }}\n'
               f'    private readonly __Bindings Bindings = new();\n    private sealed class __Bindings {{ public void Update() {{ }} public void StopTracking() {{ }} }}\n}}\n}}\n')
pathlib.Path(sys.argv[2]).write_text('\n'.join(out))
print('stubs for', sum(1 for line in out if line.startswith('namespace')), 'classes')
