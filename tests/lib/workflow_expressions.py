"""Reject Actions expressions in workflow scripts and shell launch commands.

Compose YAML nodes instead of constructing Python objects: this preserves source
locations, duplicate keys, and the literal `on` key (a YAML 1.1 boolean). Scalar
values already include YAML folding and escape decoding. Aliases share nodes,
so a value anchored in env is checked again when used as a script.
"""

import argparse
from pathlib import Path
import sys

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode


class WorkflowError(ValueError):
    """An input cannot be checked without guessing its meaning."""


def location(node):
    if node is None:
        return "1:1"
    return f"{node.start_mark.line + 1}:{node.start_mark.column + 1}"


def mapping(node, path):
    if not isinstance(node, MappingNode):
        raise WorkflowError(f"{location(node)}: {path}: expected a mapping")
    result = {}
    for key, value in node.value:
        if not isinstance(key, ScalarNode):
            raise WorkflowError(f"{location(key)}: {path}: expected a scalar key")
        if key.value == "<<":
            raise WorkflowError(f"{location(key)}: {path}: YAML merge keys are not supported")
        if key.value in result:
            raise WorkflowError(f"{location(key)}: {path}: duplicate key {key.value!r}")
        result[key.value] = value
    return result


def validate_graph(node, active, checked):
    """Reject ambiguity and cycles once per node, without expanding alias DAGs."""
    if node is None:
        raise WorkflowError("1:1: empty YAML document")
    if node in active:
        raise WorkflowError(f"{location(node)}: recursive YAML alias")
    if node in checked:
        return
    # compose() never constructs tagged objects. Still refuse custom tags so
    # the checker does not assign them a meaning the Actions parser may not use.
    allowed_tags = {
        ScalarNode: {"str", "bool", "int", "float", "null", "timestamp"},
        SequenceNode: {"seq"},
        MappingNode: {"map"},
    }
    if node.tag not in {
        "tag:yaml.org,2002:" + tag for tag in allowed_tags[type(node)]
    }:
        raise WorkflowError(f"{location(node)}: unsupported YAML tag {node.tag!r}")
    active.add(node)
    if isinstance(node, MappingNode):
        mapping(node, "YAML mapping")
        children = [child for pair in node.value for child in pair]
    elif isinstance(node, SequenceNode):
        children = node.value
    else:
        children = []
    for child in children:
        validate_graph(child, active, checked)
    active.remove(node)
    checked.add(node)


def check_workflow(source, filename="workflow.yml"):
    """Return diagnostics; an empty list means every modeled sink was checked.

    Scope is step run/shell, including parallel groups, plus workflow/job
    defaults.run.shell. Inputs to actions and called workflows are not scripts
    here; auditing what those consumers execute is a separate concern.
    """
    findings = []

    def executable(node, path):
        if not isinstance(node, ScalarNode):
            raise WorkflowError(f"{location(node)}: {path}: expected a scalar")
        # ScalarNode.value is decoded text even when SafeLoader's YAML 1.1
        # resolver inferred bool (yes/on), timestamp, etc. Actions uses YAML
        # 1.2 and its template reader also converts scalar literals for string
        # fields. Inspect the text, not the inferred tag: conversion cannot
        # create an expression in a boolean, number or null literal. Explicit
        # tags cannot hide an opener either; validate_graph still rejects
        # unsupported tags and collections are refused above.
        if "${{" in node.value:
            # For an alias, this location names the anchor's scalar while path
            # names the executable use. Never cache this check by node identity:
            # the same scalar can be data in env and code in a later step.
            findings.append(
                f"{filename}:{location(node)}: {path}: Actions expression in executable value"
            )

    def defaults(parent, path):
        if "defaults" in parent:
            values = mapping(parent["defaults"], path + ".defaults")
            if "run" in values:
                run = mapping(values["run"], path + ".defaults.run")
                if "shell" in run:
                    executable(run["shell"], path + ".defaults.run.shell")

    def steps(node, path):
        if not isinstance(node, SequenceNode) or not node.value:
            raise WorkflowError(f"{location(node)}: {path}: expected a nonempty sequence")
        for index, step in enumerate(node.value):
            step_path = f"{path}[{index}]"
            values = mapping(step, step_path)
            for key in ("run", "shell"):
                if key in values:
                    executable(values[key], step_path + "." + key)
            if "parallel" in values:
                steps(values["parallel"], step_path + ".parallel")

    try:
        root = yaml.compose(source, Loader=yaml.SafeLoader)
        validate_graph(root, set(), set())
        workflow = mapping(root, "workflow")
        defaults(workflow, "workflow")
        if "jobs" not in workflow:
            raise WorkflowError("1:1: workflow: missing jobs mapping")
        jobs = mapping(workflow["jobs"], "jobs")
        if not jobs:
            raise WorkflowError(f"{location(workflow['jobs'])}: jobs: empty mapping")
        for name, job in jobs.items():
            path = f"jobs.{name}"
            values = mapping(job, path)
            defaults(values, path)
            if "steps" in values:
                steps(values["steps"], path + ".steps")
            elif "uses" not in values:
                raise WorkflowError(f"{location(job)}: {path}: missing steps or reusable workflow uses")
    except (yaml.YAMLError, WorkflowError, RecursionError) as error:
        findings.append(f"{filename}: cannot check workflow: {error}")
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workflow_dir", type=Path)
    args = parser.parse_args(argv)
    try:
        workflows = sorted(
            path for path in args.workflow_dir.iterdir()
            if path.is_file() and path.suffix in {".yml", ".yaml"}
        )
    except OSError as error:
        print(f"{args.workflow_dir}: cannot list workflows: {error}", file=sys.stderr)
        return 1
    if not workflows:
        print(f"{args.workflow_dir}: no .yml or .yaml workflows found", file=sys.stderr)
        return 1
    findings = []
    for path in workflows:
        try:
            findings.extend(check_workflow(path.read_text(encoding="utf-8"), str(path)))
        except (OSError, UnicodeError) as error:
            findings.append(f"{path}: cannot read workflow: {error}")
    if findings:
        print("\n".join(findings), file=sys.stderr)
        print(
            'Pass script inputs through env: and read "${VAR}"; keep shell: static.',
            file=sys.stderr,
        )
        return 1
    print(f"checked run/shell expressions in {len(workflows)} workflow(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
