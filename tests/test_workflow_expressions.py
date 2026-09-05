"""Regression cases for YAML spellings that must not hide executable values."""

from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from lib.workflow_expressions import check_workflow


EXPRESSION = "${{ github.event.pull_request.title }}"
CHECKER = Path(__file__).parent / "lib" / "workflow_expressions.py"


def workflow(steps):
    return (
        "name: Fixture\non: workflow_dispatch\njobs:\n  check:\n"
        "    runs-on: ubuntu-latest\n    steps: # comment after steps\n"
        + textwrap.indent(steps, "      ")
        + "\n"
    )


class WorkflowExpressionsTest(unittest.TestCase):
    def assert_executable(self, source, *paths):
        findings = check_workflow(source, "fixture.yaml")
        self.assertEqual(len(paths), len(findings), findings)
        for path, finding in zip(paths, findings):
            self.assertIn(path + ": Actions expression in executable value", finding)
            self.assertRegex(finding, r"^fixture.yaml:\d+:\d+: ")

    def test_run_scalar_spellings(self):
        cases = {
            "plain": "- run: echo EXPR",
            "single quoted": "- run: 'echo EXPR'",
            "double quoted": '- run: "echo EXPR"',
            "quoted key": '- "run": echo EXPR',
            "single quoted key": "- 'run': echo EXPR",
            "escaped key": r'- "\u0072un": echo EXPR',
            "literal": "- run: |\n    echo EXPR",
            "commented indicator": "- run: |- # comment\n    echo EXPR",
            "explicit indentation": "- run: |2+\n    echo EXPR",
            "folded": "- run: >-\n    echo EXPR",
            "plain continuation": "- run: echo start\n    && echo EXPR",
            "mapping-shaped continuation": '- run: "echo start\n    name: EXPR"',
            "single quoted continuation": "- run: 'echo start\n    name: EXPR'",
            "heredoc": "- run: |\n    cat <<'EOF'\n    name: EXPR\n    EOF",
            "shell comment": "- run: |\n    # EXPR\n    echo safe",
            "flow mapping": "- {name: Flow, run: 'echo EXPR'}",
            "whole script": "- run: EXPR",
            "multiline expression": "- run: |\n    echo ${{\n      github.actor\n    }}",
        }
        for label, steps in cases.items():
            with self.subTest(label=label):
                self.assert_executable(
                    workflow(steps.replace("EXPR", EXPRESSION)), "jobs.check.steps[0].run"
                )

    def test_decoded_expression_openers(self):
        for opener in (r"\x24{{", r"\u0024{{", r"\U00000024{{", "$\\\n    {{"):
            with self.subTest(opener=opener):
                source = workflow('- run: "echo ' + opener + ' github.actor }}"')
                self.assertNotIn("${{", source)
                self.assert_executable(source, "jobs.check.steps[0].run")

    def test_plain_scalars_are_command_text(self):
        # Actions uses YAML 1.2 and converts scalar literals for string fields.
        # PyYAML's inferred YAML 1.1 tag must not reject valid command text.
        values = (
            "yes", "Yes", "YES", "no", "No", "NO", "on", "On", "ON",
            "off", "Off", "OFF", "y", "n", "2026-09-05", "12:34:56",
            "true", "false", "0", "1.5", "null", "~", "",
        )
        for value in values:
            with self.subTest(value=value):
                source = workflow("- run: " + value + "\n  shell: " + value)
                source = "defaults: {run: {shell: " + value + "}}\n" + source
                source = source.replace(
                    "    steps:",
                    "    defaults: {run: {shell: " + value + "}}\n    steps:",
                )
                self.assertEqual([], check_workflow(source))

    def test_scalar_tags_do_not_hide_expressions(self):
        # compose() retains explicit tags without constructing their values.
        # Regardless of a tag, the decoded text must still be inspected.
        for tag in ("str", "bool", "int", "float", "null", "timestamp"):
            with self.subTest(tag=tag):
                self.assert_executable(
                    workflow("- run: !!" + tag + " " + EXPRESSION),
                    "jobs.check.steps[0].run",
                )

    def test_shell_scalar_spellings(self):
        for value in (
            "EXPR {0}", '"bash -c\n  EXPR -- {0}"',
            "'bash -c\n  EXPR -- {0}'", "bash -c\n  EXPR -- {0}",
            "|\n  EXPR {0}", ">- # comment\n  EXPR {0}",
        ):
            with self.subTest(value=value):
                steps = "- run: echo safe\n" + textwrap.indent("shell: " + value, "  ")
                self.assert_executable(
                    workflow(steps.replace("EXPR", EXPRESSION)), "jobs.check.steps[0].shell"
                )

    def test_indentationless_steps(self):
        self.assert_executable(
            "on: push\njobs:\n  check:\n    steps:\n    - run: " + EXPRESSION,
            "jobs.check.steps[0].run",
        )

    def test_flow_sequences_and_mappings(self):
        for value in (
            "[{run: 'EXPR'}]",
            "\n      [{run: 'EXPR'}]",
            "\n      [\n        {run: 'EXPR'}\n      ]",
        ):
            with self.subTest(value=value):
                self.assert_executable(
                    "on: push\njobs:\n  check:\n    steps: " + value.replace("EXPR", EXPRESSION),
                    "jobs.check.steps[0].run",
                )
        self.assert_executable(
            "{on: push, jobs: {check: {steps: [{run: '" + EXPRESSION + "'}]}}}",
            "jobs.check.steps[0].run",
        )

    def test_shell_defaults_at_both_scopes(self):
        source = workflow("- run: echo safe")
        source = "defaults: {run: {shell: '" + EXPRESSION + " {0}'}}\n" + source
        source = source.replace(
            "    steps:",
            '    defaults:\n      run:\n        shell: "bash -c\n          '
            + EXPRESSION + ' -- {0}"\n    steps:',
        )
        self.assert_executable(
            source, "workflow.defaults.run.shell", "jobs.check.defaults.run.shell"
        )

    def test_alias_from_data_to_executable_values(self):
        for name in ("script", "1"):
            with self.subTest(name=name):
                source = "env:\n  SCRIPT: &" + name + " " + EXPRESSION + "\n"
                source += workflow("- run: *" + name + "\n  shell: *" + name)
                self.assert_executable(source, "jobs.check.steps[0].run", "jobs.check.steps[0].shell")

    def test_aliases_of_steps_sequences_and_jobs(self):
        source = (
            "on: push\njobs:\n  first: &job\n    steps: &steps\n"
            "      - &step {run: '" + EXPRESSION + "'}\n      - *step\n"
            "  second: *job\n  third:\n    steps: *steps\n"
        )
        self.assert_executable(source, *(
            f"jobs.{job}.steps[{index}].run"
            for job in ("first", "second", "third") for index in range(2)
        ))

    def test_parallel_group(self):
        self.assert_executable(
            workflow("- parallel:\n    - run: " + EXPRESSION),
            "jobs.check.steps[0].parallel[0].run",
        )

    def test_data_and_yaml_comments_remain_data(self):
        source = "# YAML comment " + EXPRESSION + "\n"
        source += "env: &environment\n  run: " + EXPRESSION + "\n  shell: " + EXPRESSION + "\n"
        source += workflow(
            "- name: " + EXPRESSION + "\n  run: | # " + EXPRESSION
            + '\n    echo "$run"\n  shell: bash\n  env: *environment\n'
            "- uses: owner/action@v1\n  with: *environment"
        )
        source = source.replace("    steps:", "    outputs: *environment\n    steps:")
        self.assertEqual([], check_workflow(source))

    def test_reusable_workflow_and_action_only_job(self):
        source = (
            "on: push\njobs:\n  call:\n    uses: owner/repo/.github/workflows/test.yml@main\n"
            "    with:\n      run: " + EXPRESSION + "\n  action:\n"
            "    steps: [{uses: 'owner/action@v1'}]\n"
        )
        self.assertEqual([], check_workflow(source))

    def test_invalid_and_ambiguous_yaml_fails(self):
        cases = {
            "empty document": "",
            "missing jobs": "on: push",
            "empty jobs": "jobs: {}",
            "scalar jobs": "jobs: nope",
            "scalar job": "jobs: {check: nope}",
            "missing steps": "jobs: {check: {runs-on: ubuntu-latest}}",
            "mapping steps": "jobs: {check: {steps: {run: echo safe}}}",
            "empty steps": workflow("[]"),
            "scalar step": workflow("- nope"),
            "invalid run": workflow("- run: [echo, safe]"),
            "invalid shell": workflow("- run: echo safe\n  shell: {bash: true}"),
            "invalid defaults": "defaults: nope\n" + workflow("- run: echo safe"),
            "duplicate sink": workflow("- run: '" + EXPRESSION + "'\n  run: echo safe"),
            "escaped duplicate": workflow('- run: echo safe\n  "r\\u0075n": echo safe'),
            "duplicate parent": workflow("- run: echo safe") + "jobs: {}\n",
            "multiple documents": workflow("- run: echo safe") + "---\n" + workflow("- run: echo safe"),
            "complex key": "? [jobs]\n: {}",
            "recursive alias": "env: &loop {value: *loop}\n" + workflow("- run: echo safe"),
            "unknown alias": workflow("- run: *missing"),
            "merge key": workflow("- <<: {run: echo safe}"),
            "custom tag": workflow("- run: !custom echo safe"),
            "python tag": workflow("- run: !!python/object/apply:os.system ['echo unsafe']"),
            "broken YAML": workflow('- run: "unclosed'),
            # The old fixture called this a valid plain continuation. YAML
            # actually forbids ': ' here; a real parser must reject the fixture.
            "invalid plain fold": workflow("- run: echo start\n    name: " + EXPRESSION),
        }
        for label, source in cases.items():
            with self.subTest(label=label):
                findings = check_workflow(source)
                self.assertTrue(findings)
                self.assertIn("cannot check workflow", findings[-1])

    def test_cli_scans_both_extensions_and_propagates_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def run():
                return subprocess.run(
                    [sys.executable, "-B", str(CHECKER), str(root)],
                    text=True, capture_output=True, check=False,
                )

            result = run()
            self.assertNotEqual(0, result.returncode)
            self.assertIn("no .yml or .yaml workflows", result.stderr)
            (root / "safe.yml").write_text(workflow("- run: echo safe"), encoding="utf-8")
            (root / "safe.yaml").write_text(workflow("- run: echo safe"), encoding="utf-8")
            result = run()
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("2 workflow(s)", result.stdout)
            for extension in ("yml", "yaml"):
                with self.subTest(extension=extension):
                    path = root / ("unsafe." + extension)
                    path.write_text(workflow("- run: " + EXPRESSION), encoding="utf-8")
                    result = run()
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(path.name, result.stderr)
                    self.assertIn("jobs.check.steps[0].run", result.stderr)
                    path.unlink()
            (root / "broken.yml").write_text("jobs: [", encoding="utf-8")
            self.assertNotEqual(0, run().returncode)

    def test_cli_missing_directory_or_parser_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, "-B", str(CHECKER), str(Path(directory) / "missing")],
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("cannot list workflows", result.stderr)
            # -S omits site-packages, reproducing an interpreter without PyYAML.
            result = subprocess.run(
                [sys.executable, "-B", "-S", str(CHECKER), directory],
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("No module named 'yaml'", result.stderr)


if __name__ == "__main__":
    unittest.main()
