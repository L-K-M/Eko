#!/usr/bin/env python3
"""Validate the shared protocol artifacts under protocol/.

The Kotlin and Swift suites each consume these files, so a malformed schema or
scenario shows up as two unrelated-looking platform failures — or, worse, as a
vector one side silently skips. This runs first and fails on the file itself.

What it checks, in the order protocol/README.md describes them:

  1. Every JSON file parses, with duplicate object members rejected. `jq empty`
     accepts a duplicate key (last one wins); a hand-edited vector that grew a
     second "seq" would then mean different things to different parsers.
  2. Every file in schemas/ is a valid JSON Schema Draft 2020-12 document.
  3. The local schema registry resolves: every $ref in the twenty message
     schemas and in frame.schema.json's union is retrievable by $id without
     touching the network. The https://eko.local/ identifier space does not
     resolve, by design.
  4. Every complete frame embedded in a scenario validates against
     frame.schema.json. This is the check that makes "both implementations
     consume the same vectors" enforceable rather than aspirational.
  5. Every OTP corpus file loads as YAML with duplicate keys rejected and
     declares format eko-otp-corpus-v1.
  6. Everything outside otp-corpus/ is ASCII. Unicode belongs only in corpus
     message strings whose purpose is to test Unicode or a non-English
     language, and a stray smart quote in a schema is a copy-paste artifact.

Usage: python3 scripts/check-protocol.py [--protocol-dir DIR]
Requires: PyYAML and jsonschema (CI installs them; see .github/workflows/ci.yml).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

import yaml
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
from referencing.jsonschema import DRAFT202012

# The keys protocol/README.md defines as carrying a complete core v1 frame.
# `frame_from_step` is deliberately absent: it is a back-reference to a frame
# already validated at its own step, not a frame literal.
FRAME_KEYS = (
    "frame",
    "receive",
    "expect_send",
    "captured_response",
    "buffered_old_connection_frame",
)

errors: list[str] = []


def fail(where: pathlib.Path | str, message: str) -> None:
    errors.append(f"{where}: {message}")


def no_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict:
    seen: set[str] = set()
    for key, _ in pairs:
        if key in seen:
            raise ValueError(f"duplicate object member {key!r}")
        seen.add(key)
    return dict(pairs)


class StrictYamlLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate mapping keys instead of silently
    keeping the last one — protocol/README.md requires it for the corpus."""


def _strict_mapping(loader: StrictYamlLoader, node: yaml.MappingNode) -> dict:
    mapping: dict = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=True)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate mapping key {key!r}", key_node.start_mark
            )
        mapping[key] = loader.construct_object(value_node, deep=True)
    return mapping


StrictYamlLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _strict_mapping
)


def load_json(path: pathlib.Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicate_json_keys)
    except RecursionError:
        fail(path, "JSON is nested too deeply to parse")
        return None
    except (ValueError, UnicodeDecodeError) as exc:
        fail(path, str(exc))
        return None


# Scenarios are committed, reviewed files; this bound turns a pathologically
# nested one into a clean CI failure instead of an interpreter crash.
MAX_SCENARIO_DEPTH = 128


def walk_frames(node: object, path: str = "$"):
    """Yield (json-pointer-ish location, frame object) for every frame literal."""
    stack = [(node, path, 0)]
    while stack:
        current, here, depth = stack.pop()
        if depth > MAX_SCENARIO_DEPTH:
            raise ValueError(f"{here}: scenario nesting exceeds {MAX_SCENARIO_DEPTH} levels")
        if isinstance(current, dict):
            for key, value in current.items():
                child = f"{here}.{key}"
                if key in FRAME_KEYS and isinstance(value, dict):
                    yield child, value
                else:
                    stack.append((value, child, depth + 1))
        elif isinstance(current, list):
            for index, value in enumerate(current):
                stack.append((value, f"{here}[{index}]", depth + 1))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--protocol-dir",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent / "protocol",
    )
    args = parser.parse_args()
    root: pathlib.Path = args.protocol_dir

    if not root.is_dir():
        print(f"error: no protocol directory at {root}", file=sys.stderr)
        return 2

    schema_files = sorted((root / "schemas").glob("*.json"))
    vector_files = sorted((root / "test-vectors").glob("*.json"))
    scenario_files = sorted((root / "test-vectors" / "scenarios").glob("*.json"))
    corpus_files = sorted((root / "otp-corpus").glob("*.yaml"))

    for label, files in (
        ("schemas", schema_files),
        ("test vectors", vector_files),
        ("scenarios", scenario_files),
        ("OTP corpus", corpus_files),
    ):
        if not files:
            fail(root, f"no {label} found — the layout in protocol/README.md changed")

    # 1 + 6: parse, and hold the line on ASCII outside the corpus.
    documents: dict[pathlib.Path, dict] = {}
    for path in schema_files + vector_files + scenario_files:
        raw = path.read_bytes()
        if not raw.isascii():
            offset = next(i for i, b in enumerate(raw) if b > 0x7F)
            fail(path, f"non-ASCII byte at offset {offset}; only otp-corpus/ may carry Unicode")
        document = load_json(path)
        if document is not None:
            documents[path] = document

    # 2 + 3: valid schema documents, and a registry that resolves offline.
    resources = []
    for path in schema_files:
        schema = documents.get(path)
        if schema is None:
            continue
        schema_id = schema.get("$id")
        if not schema_id:
            fail(path, "schema has no $id, so it cannot be preloaded into the registry")
            continue
        try:
            Draft202012Validator.check_schema(schema)
        except Exception as exc:  # jsonschema raises SchemaError
            fail(path, f"not a valid Draft 2020-12 schema: {exc}")
            continue
        resources.append((schema_id, Resource.from_contents(schema, default_specification=DRAFT202012)))

    registry = Registry().with_resources(resources)

    frame_path = root / "schemas" / "frame.schema.json"
    frame_schema = documents.get(frame_path)
    if frame_schema is None:
        fail(frame_path, "missing or unparseable; cannot validate scenario frames")
        return report()

    validator = Draft202012Validator(frame_schema, registry=registry)

    # A failure against the union says only "not valid under any of the given
    # schemas" and echoes the whole frame. Re-running the frame against the one
    # branch its own "type" names turns that into the field that is actually
    # wrong. File names use hyphens where JSON type names use underscores.
    branches: dict[str, Draft202012Validator] = {}
    for path in schema_files:
        schema = documents.get(path)
        if schema is None or path.name in ("common.schema.json", "frame.schema.json"):
            continue
        kind = path.name[: -len(".schema.json")].replace("-", "_")
        branches[kind] = Draft202012Validator(schema, registry=registry)

    # 4: every embedded frame validates against the union.
    checked = 0
    for path in scenario_files:
        document = documents.get(path)
        if document is None:
            continue
        if document.get("format") != "eko-scenario-v1":
            fail(path, f"format is {document.get('format')!r}, expected 'eko-scenario-v1'")
        try:
            frames = list(walk_frames(document))
        except ValueError as exc:
            fail(path, str(exc))
            continue
        for location, frame in frames:
            checked += 1
            # iter_errors returns a generator, which is always truthy — the
            # list() is what actually decides whether the frame validated.
            if not list(validator.iter_errors(frame)):
                continue
            kind = frame.get("type")
            branch = branches.get(kind) if isinstance(kind, str) else None
            if branch is None:
                fail(path, f"{location}: type {kind!r} matches no message schema")
                continue
            reasons = [
                f"{'/'.join(str(p) for p in error.absolute_path) or '<root>'}: {error.message}"
                for error in sorted(branch.iter_errors(frame), key=lambda e: list(e.path))
            ]
            if not reasons:
                # Valid against its own branch but not the union: two branches
                # matched, which oneOf forbids.
                reasons = ["valid against more than one message schema"]
            for reason in reasons:
                fail(path, f"{location} ({kind}) {reason}")

    if checked == 0:
        fail(root / "test-vectors" / "scenarios", "no frames found — FRAME_KEYS is out of step with the vectors")

    # 5: the corpus.
    for path in corpus_files:
        try:
            corpus = yaml.load(path.read_text(encoding="utf-8"), Loader=StrictYamlLoader)
        except (yaml.YAMLError, UnicodeDecodeError) as exc:
            fail(path, str(exc))
            continue
        if not isinstance(corpus, dict):
            fail(path, "top level is not a mapping")
            continue
        if corpus.get("format") != "eko-otp-corpus-v1":
            fail(path, f"format is {corpus.get('format')!r}, expected 'eko-otp-corpus-v1'")

    print(
        f"protocol: {len(schema_files)} schemas, {len(vector_files)} vector files, "
        f"{len(scenario_files)} scenarios ({checked} frames), {len(corpus_files)} corpus files"
    )
    return report()


def report() -> int:
    if errors:
        print(f"\n{len(errors)} problem(s):", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print("protocol artifacts OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
