import os
import pathlib
import re

QUOTE = re.compile(r'(#+)?("""|")')

def without_literals(source):
    output = list(source)
    cursor = 0
    while cursor < len(source):
        end = cursor
        if source.startswith('//', cursor):
            end = source.find('\n', cursor)
            if end < 0:
                end = len(source)
        elif source.startswith('/*', cursor):
            end = cursor + 2
            depth = 1
            while end < len(source) and depth:
                if source.startswith('/*', end):
                    depth += 1
                    end += 2
                elif source.startswith('*/', end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
        else:
            quote = QUOTE.match(source, cursor)
            if quote:
                hashes = quote.group(1) or ''
                delimiter = quote.group(2) + hashes
                end = cursor + len(quote.group())
                while end < len(source):
                    if source.startswith(delimiter, end):
                        end += len(delimiter)
                        break
                    if source.startswith('\\' + hashes, end):
                        end += len(hashes) + 2
                    else:
                        end += 1
        if end > cursor:
            for index in range(cursor, min(end, len(source))):
                if source[index] != '\n':
                    output[index] = ' '
            cursor = end
        else:
            cursor += 1
    return ''.join(output)


def release_condition(expression):
    tokens = re.findall(r'&&|\|\||!|[()]|[A-Za-z_][A-Za-z_0-9.]*|\S', expression)
    cursor = 0

    def atom():
        nonlocal cursor
        if cursor >= len(tokens):
            return {False, True}
        token = tokens[cursor]
        cursor += 1
        if token == '!':
            return {not value for value in atom()}
        if token == '(':
            value = expression_value()
            if cursor < len(tokens) and tokens[cursor] == ')':
                cursor += 1
            return value
        if cursor < len(tokens) and tokens[cursor] == '(':
            depth = 0
            while cursor < len(tokens):
                item = tokens[cursor]
                cursor += 1
                depth += (item == '(') - (item == ')')
                if depth == 0:
                    break
            return {False, True}
        return {False} if token in ('DEBUG', 'false') else {True} if token == 'true' else {False, True}

    def conjunction():
        nonlocal cursor
        value = atom()
        while cursor < len(tokens) and tokens[cursor] == '&&':
            cursor += 1
            right = atom()
            value = {left and other for left in value for other in right}
        return value

    def expression_value():
        nonlocal cursor
        value = conjunction()
        while cursor < len(tokens) and tokens[cursor] == '||':
            cursor += 1
            right = conjunction()
            value = {left or other for left in value for other in right}
        return value

    result = expression_value()
    return result if cursor == len(tokens) else {False, True}


def release_source(source):
    stack = []
    active = True
    output = []
    for line in without_literals(source).splitlines(keepends=True):
        directive = re.match(r'\s*#(if|elseif|else|endif)\b(.*)', line)
        if directive:
            kind, expression = directive.groups()
            if kind == 'if':
                values = release_condition(expression)
                stack.append([active, False in values])
                active = active and True in values
            elif kind == 'elseif':
                parent, remaining = stack[-1]
                values = release_condition(expression)
                active = parent and remaining and True in values
                stack[-1][1] = remaining and False in values
            elif kind == 'else':
                parent, remaining = stack[-1]
                active = parent and remaining
                stack[-1][1] = False
            else:
                active = stack.pop()[0]
            output.append('\n' if line.endswith('\n') else '')
        else:
            output.append(line if active else ''.join('\n' if value == '\n' else ' ' for value in line))
    if stack:
        raise ValueError('Unbalanced Swift conditional compilation')
    return ''.join(output)


def initializer_violations(source, names=None):
    names = names or {'VoiceSpeakerCheck'}
    source = release_source(source)
    matches = list(re.finditer(r'`[A-Za-z_][A-Za-z_0-9]*`|[A-Za-z_][A-Za-z_0-9]*|[^\s]', source))
    tokens = [item.group().strip('`') for item in matches]
    types = {}
    for index, token in enumerate(tokens[:-1]):
        if token not in ('class', 'struct', 'actor', 'enum', 'extension'):
            continue
        cursor = index + 1
        qualified = [tokens[cursor]]
        while cursor + 2 < len(tokens) and tokens[cursor + 1] == '.':
            cursor += 2
            qualified.append(tokens[cursor])
        if not qualified[-1].isidentifier():
            continue
        while cursor < len(tokens) and tokens[cursor] not in ('{', ';', '}'):
            cursor += 1
        if cursor < len(tokens) and tokens[cursor] == '{':
            types[cursor] = qualified[-1] in names
    stack = []
    violations = []
    modifiers = {'private', 'fileprivate', 'internal', 'package', 'public', 'open', 'convenience', 'required', 'override', 'nonisolated', 'isolated'}
    for index, token in enumerate(tokens):
        if token == '{':
            stack.append(types.get(index))
        elif token == '}':
            if stack:
                stack.pop()
        elif token == 'init' and stack and stack[-1] is True and (index == 0 or tokens[index - 1] != '.'):
            cursor = index - 1
            access = set()
            while cursor >= 0:
                if tokens[cursor] in modifiers:
                    access.add(tokens[cursor])
                    cursor -= 1
                elif tokens[cursor] == ')':
                    end = cursor
                    depth = 1
                    cursor -= 1
                    while cursor >= 0 and depth:
                        depth += (tokens[cursor] == ')') - (tokens[cursor] == '(')
                        cursor -= 1
                    if cursor >= 1 and tokens[cursor - 1] == '@':
                        cursor -= 2
                    elif cursor >= 0 and tokens[cursor] == 'nonisolated':
                        cursor -= 1
                    else:
                        cursor = end
                        break
                else:
                    break
            if 'private' not in access:
                violations.append(source.count('\n', 0, matches[index].start()) + 1)
    return violations


def scan(root):
    failures = []
    sources = []
    aliases = {}
    for directory, folders, files in os.walk(root):
        folders[:] = [name for name in folders if name not in {'.git', '.build', 'node_modules', 'bin', 'obj'}]
        for name in files:
            if name.endswith('.swift'):
                source = pathlib.Path(directory) / name
                contents = source.read_text()
                sources.append((source, contents))
                if 'typealias' in contents:
                    tokens = re.findall(r'`[A-Za-z_][A-Za-z_0-9]*`|[A-Za-z_][A-Za-z_0-9]*|[^\s]', release_source(contents))
                    tokens = [item.strip('`') for item in tokens]
                    for index in range(len(tokens) - 3):
                        if tokens[index] == 'typealias' and tokens[index + 2] == '=':
                            cursor = index + 3
                            target = tokens[cursor]
                            while cursor + 2 < len(tokens) and tokens[cursor + 1] == '.':
                                cursor += 2
                                target = tokens[cursor]
                            aliases.setdefault(tokens[index + 1], set()).add(target)
    names = {'VoiceSpeakerCheck'}
    while True:
        expanded = names | {alias for alias, targets in aliases.items() if targets & names}
        if expanded == names:
            break
        names = expanded
    for source, contents in sources:
        if any(name in contents for name in names):
            for line in initializer_violations(contents, names):
                failures.append(f'{source}:{line}')
    if failures:
        raise RuntimeError('Non-private Release VoiceSpeakerCheck initializer: ' + ', '.join(failures))
