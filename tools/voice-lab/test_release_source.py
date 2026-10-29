import pathlib
import tempfile
import unittest
from release_source import initializer_violations, release_condition, scan


class ReleaseSourceTests(unittest.TestCase):
    def test_every_nonprivate_access_and_signature_is_rejected(self):
        for access in ['', 'internal', 'package', 'public', 'fileprivate']:
            for signature in ['init(anything: Int)', 'convenience init?(different: String)', 'required init<T>(value: T)']:
                self.assertTrue(initializer_violations(f'class VoiceSpeakerCheck {{ {access} {signature} {{}} }}'))
        self.assertFalse(initializer_violations('class VoiceSpeakerCheck { private convenience init() {} }'))
        self.assertTrue(initializer_violations('extension Module.`VoiceSpeakerCheck` { init() {} }'))

    def test_nested_conditionals_and_else_branches(self):
        self.assertFalse(initializer_violations('''class VoiceSpeakerCheck {
#if DEBUG
#if INNER
public init(first: Int) {}
#else
package init(second: Int) {}
#endif
#elseif OTHER && DEBUG
init(third: Int) {}
#else
private init() {}
#endif
}'''))
        self.assertTrue(initializer_violations('''extension VoiceSpeakerCheck {
#if DEBUG
private init() {}
#else
#if SOMETHING
init(bypass: Int) {}
#endif
#endif
}'''))
        self.assertEqual(release_condition('DEBUG && os(macOS)'), {False})
        self.assertEqual(release_condition('!DEBUG'), {True})
        self.assertEqual(release_condition('DEBUG || UNKNOWN'), {False, True})

    def test_comments_strings_other_types_and_calls_are_not_initializers(self):
        source = '''/* class VoiceSpeakerCheck { init() {} /* nested */ } */
let text = #"extension VoiceSpeakerCheck { init() {} }"#
class VoiceSpeakerCheck {
private let number = 1
private init() {}
struct Nested { init() {} }
func copy() { let value = Other.init() }
}
struct Other { init() {} }
'''
        self.assertFalse(initializer_violations(source))
        self.assertTrue(initializer_violations('class VoiceSpeakerCheck { private let value = 0; init() {} }'))
        self.assertFalse(initializer_violations('class VoiceSpeakerCheck { private\n@available(*, deprecated)\nconvenience init() {} }'))

    def test_extension_in_another_module_is_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'ModuleA').mkdir()
            (root / 'ModuleB').mkdir()
            (root / 'ModuleA/Main.swift').write_text('class VoiceSpeakerCheck { private init() {} }')
            scan(root)
            (root / 'ModuleB/Extension.swift').write_text('extension VoxClipMedia.VoiceSpeakerCheck { internal init(unexpected: Bool) {} }')
            with self.assertRaisesRegex(RuntimeError, 'ModuleB/Extension.swift'):
                scan(root)

    def test_alias_extension_in_another_file_cannot_hide_an_initializer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Alias.swift').write_text('typealias First = VoxClipMedia.VoiceSpeakerCheck\ntypealias Second = First')
            (root / 'Extension.swift').write_text('extension Second { package init(anySignature: Double) {} }')
            with self.assertRaisesRegex(RuntimeError, 'Extension.swift'):
                scan(root)
