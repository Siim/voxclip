"""Projects for the caption fixtures that need an edited take (gen_cards.py and gen_gallery.py).

A project is a stored fixture project (file), another project with an RFC 7396 patch (from), or a synthetic take built
on a template. caption_copies() plans every project with the editing fixture generator's reference planner, through
card_plans.mjs (Node 22.13 or newer). Standard library only, except validate(), which needs `jsonschema`.
"""
import copy
import hashlib
import json
import os
import subprocess

from .style import merge_patch
from .util import REPO, SHARED, load_json

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def synthetic(name, spec, template, prefix):
    """A schema-valid take built on the template project, with deterministic ids and timings."""
    project = copy.deepcopy(template)
    digest = hashlib.sha256((prefix + "-" + name).encode()).hexdigest()
    project["id"] = "-".join((digest[:8], digest[8:12], digest[12:16], digest[16:20], digest[20:32]))
    if spec.get("title") is None:
        project.pop("title", None)
    else:
        project["title"] = spec["title"]
    tokens = spec.get("words", "").split()
    times = spec.get("times") or [(round(0.2 + 0.45 * i, 6), round(0.55 + 0.45 * i, 6)) for i in range(len(tokens))]
    if len(times) != len(tokens):
        raise SystemExit("%s: %d words but %d times" % (name, len(tokens), len(times)))
    duration = round(max(1.0, (times[-1][1] if times else 0) + 0.5), 6)
    source = project["media"]["source"]
    source.update(absolutePath="/Users/example/Movies/%s.mov" % name, relativePath=name + ".mov", sizeBytes=1048576,
                  durationSeconds=duration, contentKey=digest)
    if spec.get("video") is False:
        source["video"] = None
    if spec.get("transcript") is False:
        project["transcript"] = None
    else:
        transcript = project["transcript"]
        transcript["words"] = [{"id": "w%d" % (i + 1), "text": text, "kind": "word", "start": start, "end": end,
                                "rawStart": start, "rawEnd": end, "conf": 0.95, "speaker": None, "timing": "native"}
                               for i, (text, (start, end)) in enumerate(zip(tokens, times))]
        transcript.update(language=spec["language"], durationSeconds=duration,
                          rawKey=hashlib.sha256((prefix + "-raw-" + name).encode()).hexdigest())
    project["edits"] = {
        "pauseThresholdSeconds": 0.8, "pauseKeepSeconds": 0.15, "cutWordIds": spec.get("cut", []),
        "cutPauseIds": spec.get("cutPauses", []), "corrections": spec.get("corrections", {}),
        "clips": [{"id": c["id"], "startWordId": c["start"], "endWordId": c["end"], "title": c.get("title"),
                   "origin": "manual", "aiResultId": None, "aiClipIndex": None, "selected": True}
                  for c in spec.get("clips", [])],
        "activeClipId": None}
    project["captions"] = {"styleId": spec["style"], "overrides": spec.get("overrides", {}), "position": None,
                           "positionByAspect": {}}
    project["export"]["aspect"] = spec.get("aspect", "9:16")
    project["share"] = {"captions": {}}
    return project


def build_projects(doc, prefix):
    """Every project of a cases document; `prefix` seeds the synthetic takes' ids."""
    template = load_json(os.path.join(REPO, doc["template"]))
    specs, built = doc["projects"], {}

    def get(name):
        if name not in built:
            spec = specs[name]
            if "file" in spec:
                built[name] = load_json(os.path.join(REPO, spec["file"]))
            elif "from" in spec:
                built[name] = merge_patch(get(spec["from"]), spec["patch"])
            else:
                built[name] = synthetic(name, spec, template, prefix)
        return built[name]

    for name in specs:
        get(name)
    return built


def validate(projects):
    """Refuse a project that does not match shared/schemas/project.schema.json."""
    from jsonschema import Draft202012Validator, FormatChecker
    from referencing import Registry, Resource

    registry, project_schema = Registry(), None
    for file in sorted(os.listdir(os.path.join(SHARED, "schemas"))):
        if file.endswith(".schema.json"):
            schema = load_json(os.path.join(SHARED, "schemas", file))
            registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
            if file == "project.schema.json":
                project_schema = schema
    validator = Draft202012Validator(project_schema, registry=registry, format_checker=FormatChecker())
    for name in sorted(projects):
        errors = sorted(validator.iter_errors(projects[name]), key=lambda e: list(e.path))
        if errors:
            raise SystemExit("project %s is not schema-valid: %s at %s" % (name, errors[0].message, list(errors[0].path)))


def caption_copies(projects):
    """The caption copy (editing spec 7.6) of each project's full take and stored clips, with their edited durations:
    {name: {take, clips: {id: copy}, durations: {take, clips: {id: seconds}}}}. Projects without a transcript are left
    out."""
    payload = {name: p for name, p in projects.items() if p.get("transcript") is not None}
    run = subprocess.run(["node", "--no-warnings=ExperimentalWarning", os.path.join(TOOLS, "card_plans.mjs")],
                         input=json.dumps(payload), capture_output=True, text=True, encoding="utf-8", check=False)
    if run.returncode != 0:
        raise SystemExit("card_plans.mjs failed:\n" + run.stderr)
    return json.loads(run.stdout)
