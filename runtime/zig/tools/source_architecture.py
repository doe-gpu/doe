"""Analyze Doe Zig source ownership, dependencies, cycles, and reachability."""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ZIG_IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')
PUBLIC_DECL_RE = re.compile(
    r"^pub\s+(const|var|fn)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
TOP_LEVEL_DECL_RE = re.compile(
    r"^(?:pub\s+)?(?:export\s+|extern\s+)?"
    r"(const|var|fn|test)\b"
)
TEST_BLOCK_RE = re.compile(r'^test\s+(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_]*)')
MAIN_RE = re.compile(r"^(?:pub\s+)?fn\s+main\s*\(")


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _is_nonempty_string_list(value: Any) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(_is_nonempty_string(item) for item in value)
    )


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


@dataclass(frozen=True)
class ImportEdge:
    """A resolved source-to-source Zig import."""

    source: str
    target: str
    line: int
    import_text: str
    source_layer: str
    target_layer: str

    @property
    def key(self) -> tuple[str, str]:
        return self.source, self.target


@dataclass(frozen=True)
class ReachabilityView:
    """One named product or tooling view over the source import graph."""

    name: str
    description: str
    root_patterns: tuple[str, ...]
    roots: tuple[str, ...]
    reachable: tuple[str, ...]


@dataclass(frozen=True)
class Analysis:
    """Deterministic architecture analysis for one source tree."""

    modules: tuple[dict[str, Any], ...]
    edges: tuple[ImportEdge, ...]
    cycles: tuple[tuple[str, ...], ...]
    unreachable: tuple[str, ...]
    reachability_views: tuple[ReachabilityView, ...]
    forbidden_edges: tuple[dict[str, Any], ...]
    unresolved_imports: tuple[dict[str, Any], ...]
    manifest_errors: tuple[str, ...]
    source_tree_sha256: str
    stale_dependency_exceptions: tuple[dict[str, Any], ...]
    stale_cycle_exceptions: tuple[dict[str, Any], ...]
    stale_reachability_exceptions: tuple[dict[str, Any], ...]


def canonical_json(payload: Any) -> str:
    """Serialize a generated architecture artifact canonically."""

    return json.dumps(payload, indent=2, sort_keys=True) + "\n"


def sha256_bytes(content: bytes) -> str:
    """Return the lowercase SHA-256 digest of bytes."""

    return hashlib.sha256(content).hexdigest()


def sha256_file(path: Path) -> str:
    """Return the lowercase SHA-256 digest of one file."""

    return sha256_bytes(path.read_bytes())


def _glob_regex(pattern: str) -> re.Pattern[str]:
    pieces: list[str] = []
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "*" and index + 1 < len(pattern) and pattern[index + 1] == "*":
            pieces.append(".*")
            index += 2
            continue
        if char == "*":
            pieces.append("[^/]*")
        elif char == "?":
            pieces.append("[^/]")
        else:
            pieces.append(re.escape(char))
        index += 1
    return re.compile("^" + "".join(pieces) + "$")


def matches_glob(path: str, pattern: str) -> bool:
    """Match POSIX paths with ``*`` confined to one segment and ``**`` recursive."""

    return bool(_glob_regex(pattern).fullmatch(path))


def matching_globs(path: str, patterns: list[str]) -> list[str]:
    """Return every manifest glob matching ``path`` in declaration order."""

    return [pattern for pattern in patterns if matches_glob(path, pattern)]


def load_json_strict(path: Path) -> Any:
    """Load JSON while rejecting duplicate object keys with a path diagnostic."""

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
        )
    except FileNotFoundError as exc:
        raise FileNotFoundError(f"JSON file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON at {path}: {exc}") from exc


def _load_manifest(config_path: Path) -> dict[str, Any]:
    payload = load_json_strict(config_path)
    if not isinstance(payload, dict):
        raise ValueError(f"source-layout manifest must be an object: {config_path}")
    return payload


def load_manifest(config_path: Path) -> dict[str, Any]:
    """Load a source-layout manifest and fail with path-bearing diagnostics."""

    return _load_manifest(config_path)


def validate_manifest(config: dict[str, Any]) -> list[str]:
    """Validate the architecture-specific version-3 manifest contract."""

    errors: list[str] = []
    if config.get("version") != 3:
        errors.append("source-layout version must be 3")
    architecture = config.get("architecture")
    if not isinstance(architecture, dict):
        return errors + ["source-layout architecture must be an object"]
    layers = architecture.get("layers")
    if not isinstance(layers, dict) or not layers:
        return errors + ["architecture.layers must be a non-empty object"]
    layer_names = set(layers)
    for name, contract in layers.items():
        if not isinstance(contract, dict):
            errors.append(f"architecture layer {name!r} must be an object")
            continue
        globs = contract.get("globs")
        may_import = contract.get("mayImport")
        if (
            not isinstance(globs, list)
            or not globs
            or not all(isinstance(pattern, str) and pattern for pattern in globs)
        ):
            errors.append(f"architecture layer {name!r} must declare non-empty globs")
        if not isinstance(may_import, list) or not all(
            isinstance(target, str) and target for target in may_import
        ):
            errors.append(f"architecture layer {name!r} must declare mayImport")
            continue
        if len(may_import) != len(set(may_import)):
            errors.append(f"architecture layer {name!r} repeats a mayImport entry")
        unknown = sorted(set(may_import) - layer_names)
        if unknown:
            errors.append(
                f"architecture layer {name!r} references unknown layers: "
                + ", ".join(unknown)
            )
    roots = architecture.get("productionRoots")
    if not _is_nonempty_string_list(roots):
        errors.append("architecture.productionRoots must be a non-empty list")
    reachability_views = architecture.get("reachabilityViews")
    if not isinstance(reachability_views, dict) or not reachability_views:
        errors.append("architecture.reachabilityViews must be a non-empty object")
    else:
        for name, contract in reachability_views.items():
            if not _is_nonempty_string(name) or not isinstance(contract, dict):
                errors.append(
                    "reachability views require non-empty name/object entries"
                )
                continue
            required = {"description", "roots"}
            missing = sorted(required - set(contract))
            if missing:
                errors.append(
                    f"reachability view {name!r} missing: " + ", ".join(missing)
                )
                continue
            if not _is_nonempty_string(contract["description"]):
                errors.append(
                    f"reachability view {name!r} requires a description"
                )
            if not _is_nonempty_string_list(contract["roots"]):
                errors.append(
                    f"reachability view {name!r} requires non-empty roots"
                )
            elif len(contract["roots"]) != len(set(contract["roots"])):
                errors.append(f"reachability view {name!r} repeats a root")
    roles = architecture.get("specialRoles")
    if not isinstance(roles, dict):
        errors.append("architecture.specialRoles must be an object")
    else:
        for name, contract in roles.items():
            if not isinstance(contract, dict) or not isinstance(
                contract.get("globs"), list
            ) or not all(
                _is_nonempty_string(pattern) for pattern in contract.get("globs", [])
            ):
                errors.append(f"special role {name!r} must declare globs")
    enforcement = architecture.get("enforcement")
    if not isinstance(enforcement, dict):
        errors.append("architecture.enforcement must be an object")
    else:
        for name in ("cycles", "unreachableModules"):
            if enforcement.get(name) not in {"error", "report"}:
                errors.append(
                    f"architecture.enforcement.{name} must be 'error' or 'report'"
                )
    facade_paths = set(config.get("compatibilityFacades", []))
    facade_contracts = architecture.get("compatibilityFacadeContracts", {})
    if not isinstance(facade_contracts, dict):
        errors.append("architecture.compatibilityFacadeContracts must be an object")
    elif set(facade_contracts) != facade_paths:
        errors.append(
            "compatibilityFacadeContracts keys must exactly match compatibilityFacades"
        )
    else:
        required = {"consumer", "owner", "reason", "removalCondition", "test"}
        for path, contract in facade_contracts.items():
            if not isinstance(contract, dict):
                errors.append(
                    f"compatibility facade contract {path!r} must be an object"
                )
                continue
            missing = sorted(required - set(contract))
            if missing:
                errors.append(
                    f"compatibility facade contract {path!r} missing: "
                    + ", ".join(missing)
                )
                continue
            invalid = sorted(
                field for field in required if not _is_nonempty_string(contract[field])
            )
            if invalid:
                errors.append(
                    f"compatibility facade contract {path!r} has empty fields: "
                    + ", ".join(invalid)
                )
    for collection_name in (
        "dependencyExceptions",
        "cycleExceptions",
        "reachabilityExceptions",
    ):
        if not isinstance(architecture.get(collection_name), list):
            errors.append(f"architecture.{collection_name} must be a list")
    dependency_keys: set[tuple[str, str]] = set()
    for entry in architecture.get("dependencyExceptions", []):
        required = {"reason", "removalCondition", "source", "target"}
        if not isinstance(entry, dict) or not required <= set(entry):
            errors.append(
                "every dependency exception requires source, target, reason, "
                "and removalCondition"
            )
            continue
        if not all(_is_nonempty_string(entry[field]) for field in required):
            errors.append("dependency exception fields must be non-empty strings")
            continue
        key = entry["source"], entry["target"]
        if key in dependency_keys:
            errors.append(f"duplicate dependency exception: {key[0]} -> {key[1]}")
        dependency_keys.add(key)
    cycle_keys: set[tuple[str, ...]] = set()
    for entry in architecture.get("cycleExceptions", []):
        required = {"members", "reason", "removalCondition"}
        if not isinstance(entry, dict) or not required <= set(entry):
            errors.append(
                "every cycle exception requires members, reason, and "
                "removalCondition"
            )
            continue
        if (
            not _is_nonempty_string_list(entry["members"])
            or not _is_nonempty_string(entry["reason"])
            or not _is_nonempty_string(entry["removalCondition"])
        ):
            errors.append(
                "cycle exception members and lifecycle fields must be non-empty"
            )
            continue
        members = tuple(sorted(entry["members"]))
        if len(members) < 2 or len(members) != len(set(members)):
            errors.append("cycle exception members must contain unique module paths")
        if members in cycle_keys:
            errors.append("duplicate cycle exception: " + ", ".join(members))
        cycle_keys.add(members)
    reachability_paths: set[str] = set()
    for entry in architecture.get("reachabilityExceptions", []):
        required = {"path", "reason", "removalCondition"}
        if not isinstance(entry, dict) or not required <= set(entry):
            errors.append(
                "every reachability exception requires path, reason, and "
                "removalCondition"
            )
            continue
        if not all(_is_nonempty_string(entry[field]) for field in required):
            errors.append("reachability exception fields must be non-empty strings")
            continue
        path = entry["path"]
        if path in reachability_paths:
            errors.append(f"duplicate reachability exception: {path}")
        reachability_paths.add(path)
    justifications = architecture.get("cohesiveModuleJustifications")
    if not isinstance(justifications, list):
        errors.append("architecture.cohesiveModuleJustifications must be a list")
    else:
        justification_paths: set[str] = set()
        required = {"path", "reason", "responsibility"}
        for entry in justifications:
            if not isinstance(entry, dict) or not required <= set(entry):
                errors.append(
                    "every cohesive-module justification requires path, reason, "
                    "and responsibility"
                )
                continue
            if not all(_is_nonempty_string(entry[field]) for field in required):
                errors.append(
                    "cohesive-module justification fields must be non-empty strings"
                )
                continue
            path = entry["path"]
            if path in justification_paths:
                errors.append(f"duplicate cohesive-module justification: {path}")
            justification_paths.add(path)
    canonical_contracts = architecture.get("canonicalContracts")
    if not isinstance(canonical_contracts, dict):
        errors.append("architecture.canonicalContracts must be an object")
    else:
        required = {"forbiddenLegacyPaths", "path", "requiredPublicDeclarations"}
        for name, contract in canonical_contracts.items():
            if not _is_nonempty_string(name) or not isinstance(contract, dict):
                errors.append("canonical contracts require name/object entries")
                continue
            missing = sorted(required - set(contract))
            if missing:
                errors.append(
                    f"canonical contract {name!r} missing: " + ", ".join(missing)
                )
                continue
            if (
                not _is_nonempty_string(contract["path"])
                or not _is_nonempty_string_list(
                    contract["requiredPublicDeclarations"]
                )
                or not isinstance(contract["forbiddenLegacyPaths"], list)
                or not all(
                    _is_nonempty_string(path)
                    for path in contract["forbiddenLegacyPaths"]
                )
            ):
                errors.append(f"canonical contract {name!r} has invalid fields")
    generated_contracts = architecture.get("generatedSourceContracts")
    if not isinstance(generated_contracts, dict):
        errors.append("architecture.generatedSourceContracts must be an object")
    else:
        required = {"check", "generator", "inputs", "owner", "reason"}
        for path, contract in generated_contracts.items():
            if not _is_nonempty_string(path) or not isinstance(contract, dict):
                errors.append("generated source contracts require path/object entries")
                continue
            missing = sorted(required - set(contract))
            if missing:
                errors.append(
                    f"generated source contract {path!r} missing: "
                    + ", ".join(missing)
                )
                continue
            if not all(
                _is_nonempty_string(contract[field])
                for field in ("owner", "reason")
            ) or not all(
                _is_nonempty_string_list(contract[field])
                for field in ("check", "generator", "inputs")
            ):
                errors.append(
                    f"generated source contract {path!r} has invalid or empty fields"
                )
    decision_reviews = architecture.get("moduleDecisionReviews")
    if not isinstance(decision_reviews, dict):
        errors.append("architecture.moduleDecisionReviews must be an object")
    else:
        decisions = {"Delete", "Elevate", "Keep", "Merge", "Recompose"}
        required = {"decision", "moduleSha256", "reason", "reviewer"}
        for path, review in decision_reviews.items():
            if not _is_nonempty_string(path) or not isinstance(review, dict):
                errors.append("module decision reviews require path/object entries")
                continue
            missing = sorted(required - set(review))
            if missing:
                errors.append(
                    f"module decision review {path!r} missing: "
                    + ", ".join(missing)
                )
                continue
            if review["decision"] not in decisions:
                errors.append(
                    f"module decision review {path!r} has invalid decision: "
                    f"{review['decision']!r}"
                )
            for field in ("moduleSha256", "reason", "reviewer"):
                if not _is_nonempty_string(review[field]):
                    errors.append(
                        f"module decision review {path!r} has empty {field}"
                    )
    line_policy = architecture.get("linePolicy")
    if not isinstance(line_policy, dict):
        errors.append("architecture.linePolicy must be an object")
    else:
        required_line_fields = {
            "advisoryReviewLines",
            "futureHardMaximumLines",
            "futureJustificationAboveLines",
            "mode",
            "transitionMaximumLines",
        }
        if not required_line_fields <= set(line_policy):
            errors.append(
                "architecture.linePolicy is missing required transition/future fields"
            )
        elif line_policy["mode"] not in {"future", "transition"}:
            errors.append(
                "architecture.linePolicy.mode must be 'transition' or 'future'"
            )
        elif not (
            0 < line_policy["advisoryReviewLines"]
            < line_policy["futureJustificationAboveLines"]
            < line_policy["futureHardMaximumLines"]
        ):
            errors.append(
                "architecture.linePolicy future thresholds must be increasing"
            )
    return errors


def _classify_layer(relative_path: str, layers: dict[str, Any]) -> list[str]:
    return [
        name
        for name, contract in layers.items()
        if matching_globs(relative_path, contract["globs"])
    ]


def _classify_roles(relative_path: str, roles: dict[str, Any]) -> list[str]:
    return sorted(
        name
        for name, contract in roles.items()
        if matching_globs(relative_path, contract["globs"])
    )


def _is_relative_zig_import(import_text: str) -> bool:
    return import_text.startswith(".") or import_text.endswith(".zig")


def _module_record(
    path: Path,
    root: Path,
    layer: str,
    roles: list[str],
) -> dict[str, Any]:
    content = path.read_text(encoding="utf-8")
    lines = content.splitlines()
    public_declarations: list[dict[str, Any]] = []
    top_level_count = 0
    for line_number, line in enumerate(lines, start=1):
        top_level = TOP_LEVEL_DECL_RE.match(line)
        if top_level:
            top_level_count += 1
        public = PUBLIC_DECL_RE.match(line)
        if public:
            public_declarations.append(
                {
                    "kind": public.group(1),
                    "line": line_number,
                    "name": public.group(2),
                }
            )
    relative_path = path.relative_to(root).as_posix()
    relative_source = path.relative_to(root / "src")
    owner = (
        relative_source.parts[0]
        if len(relative_source.parts) > 1
        else "package-root"
    )
    substantive = [
        line.strip()
        for line in lines
        if line.strip() and not line.lstrip().startswith("//")
    ]
    reexport_only = bool(substantive) and all(
        line.startswith("const ") and "@import(" in line
        or line.startswith("pub const ")
        or line in {"};", "}"}
        for line in substantive
    )
    return {
        "containsCImport": "@cImport(" in content,
        "definesMain": any(MAIN_RE.match(line) for line in lines),
        "layer": layer,
        "lineCount": len(lines),
        "onlyReexports": reexport_only,
        "owner": owner,
        "path": relative_path,
        "publicDeclarationCount": len(public_declarations),
        "publicDeclarations": public_declarations,
        "roles": roles,
        "sha256": sha256_bytes(content.encode("utf-8")),
        "testBlockCount": sum(bool(TEST_BLOCK_RE.match(line)) for line in lines),
        "topLevelDeclarationCount": top_level_count,
    }


def _tarjan_cycles(adjacency: dict[str, set[str]]) -> list[tuple[str, ...]]:
    index = 0
    indices: dict[str, int] = {}
    lowlinks: dict[str, int] = {}
    stack: list[str] = []
    on_stack: set[str] = set()
    components: list[tuple[str, ...]] = []

    def visit(node: str) -> None:
        nonlocal index
        indices[node] = index
        lowlinks[node] = index
        index += 1
        stack.append(node)
        on_stack.add(node)
        for target in sorted(adjacency[node]):
            if target not in indices:
                visit(target)
                lowlinks[node] = min(lowlinks[node], lowlinks[target])
            elif target in on_stack:
                lowlinks[node] = min(lowlinks[node], indices[target])
        if lowlinks[node] != indices[node]:
            return
        component: list[str] = []
        while True:
            member = stack.pop()
            on_stack.remove(member)
            component.append(member)
            if member == node:
                break
        ordered = tuple(sorted(component))
        if len(ordered) > 1 or node in adjacency[node]:
            components.append(ordered)

    for node in sorted(adjacency):
        if node not in indices:
            visit(node)
    return sorted(components)


def _reachable(adjacency: dict[str, set[str]], roots: set[str]) -> set[str]:
    reached: set[str] = set()
    pending = sorted(roots, reverse=True)
    while pending:
        node = pending.pop()
        if node in reached:
            continue
        reached.add(node)
        pending.extend(sorted(adjacency[node] - reached, reverse=True))
    return reached


def _tree_digest(modules: list[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for module in sorted(modules, key=lambda item: item["path"]):
        digest.update(module["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(module["sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def analyze(root: Path, config: dict[str, Any]) -> Analysis:
    """Analyze the source tree described by a validated version-3 manifest."""

    root = root.resolve()
    manifest_errors = validate_manifest(config)
    if manifest_errors:
        return Analysis(
            (), (), (), (), (), (), (), tuple(manifest_errors), "", (), (), ()
        )
    source_root = (root / config["sourceRoot"]).resolve()
    architecture = config["architecture"]
    layers = architecture["layers"]
    roles = architecture["specialRoles"]
    modules: list[dict[str, Any]] = []
    module_paths: dict[str, Path] = {}
    path_layers: dict[str, str] = {}
    errors: list[str] = []
    for path in sorted(source_root.rglob("*.zig")):
        relative_path = path.relative_to(root).as_posix()
        matched_layers = _classify_layer(relative_path, layers)
        if len(matched_layers) != 1:
            errors.append(
                f"{relative_path}: expected exactly one layer, got {matched_layers}"
            )
            continue
        layer = matched_layers[0]
        module = _module_record(
            path,
            root,
            layer,
            _classify_roles(relative_path, roles),
        )
        modules.append(module)
        module_paths[relative_path] = path
        path_layers[relative_path] = layer
    edges: list[ImportEdge] = []
    unresolved: list[dict[str, Any]] = []
    for source in sorted(module_paths):
        path = module_paths[source]
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            for match in ZIG_IMPORT_RE.finditer(line):
                import_text = match.group(1)
                if not _is_relative_zig_import(import_text):
                    continue
                target_path = (path.parent / import_text).resolve(strict=False)
                try:
                    target = target_path.relative_to(root).as_posix()
                except ValueError:
                    unresolved.append(
                        {
                            "import": import_text,
                            "line": line_number,
                            "reason": "import-leaves-runtime-root",
                            "source": source,
                        }
                    )
                    continue
                if target not in module_paths:
                    unresolved.append(
                        {
                            "import": import_text,
                            "line": line_number,
                            "reason": "relative-zig-import-not-found",
                            "source": source,
                            "target": target,
                        }
                    )
                    continue
                edges.append(
                    ImportEdge(
                        source=source,
                        target=target,
                        line=line_number,
                        import_text=import_text,
                        source_layer=path_layers[source],
                        target_layer=path_layers[target],
                    )
                )
    edges.sort(key=lambda edge: (edge.source, edge.line, edge.target))
    adjacency = {path: set() for path in module_paths}
    reverse_adjacency = {path: set() for path in module_paths}
    for edge in edges:
        adjacency[edge.source].add(edge.target)
        reverse_adjacency[edge.target].add(edge.source)
    roots: set[str] = set()
    for pattern in architecture["productionRoots"]:
        roots.update(path for path in module_paths if matches_glob(path, pattern))
        if not any(matches_glob(path, pattern) for path in module_paths):
            errors.append(f"production root glob matches no Zig source: {pattern}")
    reached = _reachable(adjacency, roots)
    unreachable = sorted(set(module_paths) - reached)
    reachability_views: list[ReachabilityView] = []
    view_names_by_path = {path: [] for path in module_paths}
    view_roots_by_path = {path: [] for path in module_paths}
    for name, contract in sorted(architecture["reachabilityViews"].items()):
        view_roots: set[str] = set()
        for pattern in contract["roots"]:
            matches = {
                path for path in module_paths if matches_glob(path, pattern)
            }
            if not matches:
                errors.append(
                    f"reachability view {name!r} root matches no Zig source: "
                    f"{pattern}"
                )
            view_roots.update(matches)
        view_reached = _reachable(adjacency, view_roots)
        for path in view_reached:
            view_names_by_path[path].append(name)
        for path in view_roots:
            view_roots_by_path[path].append(name)
        reachability_views.append(
            ReachabilityView(
                name=name,
                description=contract["description"],
                root_patterns=tuple(contract["roots"]),
                roots=tuple(sorted(view_roots)),
                reachable=tuple(sorted(view_reached)),
            )
        )
    for module in modules:
        path = module["path"]
        module["fanIn"] = len(reverse_adjacency[path])
        module["fanOut"] = len(adjacency[path])
        module["imports"] = sorted(adjacency[path])
        module["reverseImports"] = sorted(reverse_adjacency[path])
        module["reachable"] = path in reached
        module["isProductionRoot"] = path in roots
        module["reachabilityViews"] = sorted(view_names_by_path[path])
        module["reachabilityViewRoots"] = sorted(view_roots_by_path[path])
    generated_paths = {
        module["path"] for module in modules if "generated" in module["roles"]
    }
    generated_contracts = set(architecture["generatedSourceContracts"])
    if generated_paths != generated_contracts:
        missing = sorted(generated_paths - generated_contracts)
        stale = sorted(generated_contracts - generated_paths)
        if missing:
            errors.append(
                "generated modules missing generation contracts: " + ", ".join(missing)
            )
        if stale:
            errors.append(
                "generation contracts without generated modules: " + ", ".join(stale)
            )
    modules_by_path = {module["path"]: module for module in modules}
    for path, review in architecture["moduleDecisionReviews"].items():
        module = modules_by_path.get(path)
        if module is None:
            errors.append(f"module decision review references missing module: {path}")
        elif review["moduleSha256"] != module["sha256"]:
            errors.append(
                f"module decision review is stale for {path}: expected "
                f"{module['sha256']}, got {review['moduleSha256']}"
            )
    dependency_exceptions = {
        (entry["source"], entry["target"]): entry
        for entry in architecture["dependencyExceptions"]
    }
    used_dependency_exceptions: set[tuple[str, str]] = set()
    compatibility_facades = set(config["compatibilityFacades"])
    concrete_layers = {"backend-d3d12", "backend-metal", "backend-vulkan"}
    forbidden: list[dict[str, Any]] = []
    for edge in edges:
        reason: str | None = None
        allowed_layers = set(layers[edge.source_layer]["mayImport"])
        if edge.target_layer not in allowed_layers:
            reason = "layer-import-not-permitted"
        if (
            edge.source_layer in concrete_layers
            and edge.target_layer in concrete_layers
            and edge.source_layer != edge.target_layer
        ):
            reason = "concrete-backend-sibling-import"
        if (
            edge.target in compatibility_facades
            and edge.source not in compatibility_facades
        ):
            reason = "implementation-imports-compatibility-facade"
        if reason is None:
            continue
        exception = dependency_exceptions.get(edge.key)
        if exception is not None:
            used_dependency_exceptions.add(edge.key)
        forbidden.append(
            {
                "allowedByException": exception is not None,
                "import": edge.import_text,
                "line": edge.line,
                "reason": reason,
                "source": edge.source,
                "sourceLayer": edge.source_layer,
                "target": edge.target,
                "targetLayer": edge.target_layer,
            }
        )
    stale_dependency = [
        entry
        for key, entry in dependency_exceptions.items()
        if key not in used_dependency_exceptions
    ]
    cycles = _tarjan_cycles(adjacency)
    cycle_exceptions = {
        tuple(sorted(entry["members"])): entry
        for entry in architecture["cycleExceptions"]
    }
    stale_cycles = [
        entry for members, entry in cycle_exceptions.items() if members not in cycles
    ]
    reachability_exceptions = {
        entry["path"]: entry for entry in architecture["reachabilityExceptions"]
    }
    stale_reachability = [
        entry
        for path, entry in reachability_exceptions.items()
        if path not in unreachable
    ]
    return Analysis(
        modules=tuple(sorted(modules, key=lambda item: item["path"])),
        edges=tuple(edges),
        cycles=tuple(cycles),
        unreachable=tuple(unreachable),
        reachability_views=tuple(reachability_views),
        forbidden_edges=tuple(forbidden),
        unresolved_imports=tuple(unresolved),
        manifest_errors=tuple(errors),
        source_tree_sha256=_tree_digest(modules),
        stale_dependency_exceptions=tuple(stale_dependency),
        stale_cycle_exceptions=tuple(stale_cycles),
        stale_reachability_exceptions=tuple(stale_reachability),
    )


def exception_for_cycle(
    cycle: tuple[str, ...], config: dict[str, Any]
) -> dict[str, Any] | None:
    """Return the exact manifest exception for a cycle, if present."""

    for entry in config["architecture"]["cycleExceptions"]:
        if tuple(sorted(entry["members"])) == cycle:
            return entry
    return None


def reachability_exception(
    path: str, config: dict[str, Any]
) -> dict[str, Any] | None:
    """Return the exact manifest exception for an unreachable module."""

    for entry in config["architecture"]["reachabilityExceptions"]:
        if entry["path"] == path:
            return entry
    return None
