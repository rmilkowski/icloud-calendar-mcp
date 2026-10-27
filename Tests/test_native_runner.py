# SPDX-FileCopyrightText: 2026 Robert Milkowski
# SPDX-License-Identifier: AGPL-3.0-only
import contextlib
import io
import json
import subprocess
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


RUNNER = Path(__file__).resolve().parent.parent / "scripts/test-native"
loader = importlib.machinery.SourceFileLoader("calendar_native_test_runner", str(RUNNER))
spec = importlib.util.spec_from_loader(loader.name, loader)
runner = importlib.util.module_from_spec(spec)
loader.exec_module(runner)


class NativeRunnerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="calendar-runner-evidence-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def report(self, cases):
        path = self.root / "results.xml"
        path.write_text("<testsuites><testsuite>" + cases + "</testsuite></testsuites>")
        return path

    def testCompleteInventoryAcceptsModuleQualificationAndMethodParentheses(self):
        path = self.report('<testcase classname="CalendarHelperTests.Example" name="testOne()"/>')
        result = runner.report_results(path, ["Example/testOne"])
        self.assertEqual(result["inventory_errors"], [])
        self.assertEqual((result["tests"], result["skipped"], result["failures"]), (1, 0, 0))

    def testPartialSuccessfulReportCannotMasqueradeAsFullSuite(self):
        path = self.report('<testcase classname="Example" name="testOne"/>')
        result = runner.report_results(path, ["Example/testOne", "Example/testTwo"])
        self.assertEqual(result["inventory_errors"], [{"missing": ["Example/testTwo"]}])

    def testDuplicatesAndUnexpectedTestsAreRejected(self):
        path = self.report('<testcase classname="Example" name="testOne"/>' * 2)
        result = runner.report_results(path, ["Example/testTwo"])
        self.assertIn({"duplicated": ["Example/testOne"]}, result["inventory_errors"])
        self.assertIn({"unexpected": ["Example/testOne"]}, result["inventory_errors"])

    def testMissingOrMalformedXMLIsFailedEvidence(self):
        path = self.root / "absent.xml"
        self.assertTrue(runner.report_results(path, ["Example/testOne"])["inventory_errors"])
        path.write_text("<broken")
        self.assertTrue(runner.report_results(path, ["Example/testOne"])["inventory_errors"])

    def testSkippedAndFailedCasesRemainVisible(self):
        path = self.report('<testcase classname="Example" name="testOne"><skipped/></testcase>'
                           '<testcase classname="Example" name="testTwo"><failure/></testcase>')
        result = runner.report_results(path, ["Example/testOne", "Example/testTwo"])
        self.assertEqual((result["skipped"], result["failures"]), (1, 1))

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("synthetic executable fixture")
        path.chmod(0o700)
        return path

    def testBundleDiscoveryUsesActualToolchainNameAndRejectsAmbiguity(self):
        binary = self.executable(self.root / "debug/CalendarHelperTests.xctest/Contents/MacOS/CalendarHelperTests")
        self.assertEqual(runner.test_binary(self.root), binary.resolve())
        self.executable(self.root / "debug/OtherTests.xctest/Contents/MacOS/OtherTests")
        with self.assertRaises(ValueError):
            runner.test_binary(self.root)

    def testSkipBuildRejectsStaleSourceOrBinaryBeforeLaunchingSwift(self):
        repo, scratch = self.root / "repo", self.root / "build"
        tests = repo / "Tests/CalendarHelperTests"
        tests.mkdir(parents=True)
        (repo / "Sources").mkdir()
        (repo / "Package.swift").write_text("// synthetic package")
        source = tests / "Example.swift"
        source.write_text("final class Example: XCTestCase {\n    func testOne() {}\n}\n")
        binary = self.executable(scratch / "debug/ActualTests.xctest/Contents/MacOS/ActualTests")
        helper = self.executable(scratch / "debug/CalendarHelper")
        manifest = runner.build_binding(runner.source_identity(repo), binary, helper)
        (scratch / "test-native-build.json").write_text(json.dumps(manifest))
        for changed in (source, binary):
            original = changed.read_text()
            changed.write_text(original + "\n// changed")
            argv = ["test-native", "--skip-build", "--scratch-path", str(scratch),
                    "--output-dir", str(self.root / (changed.name + "-report"))]
            with patch.object(runner, "REPO", repo), patch("sys.argv", argv), patch.dict("os.environ", {}, clear=True), \
                    patch.object(runner.subprocess, "run") as launch, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    runner.main()
                self.assertEqual(error.exception.code, 2)
                launch.assert_not_called()
            changed.write_text(original)

    def testMissingReportStillPersistsSuccessfulSubprocessEvidenceAsFailedRun(self):
        repo, scratch = self.root / "repo", self.root / "build"
        tests = repo / "Tests/CalendarHelperTests"
        tests.mkdir(parents=True)
        (repo / "Sources").mkdir()
        (repo / "Package.swift").write_text("// synthetic package")
        (tests / "Example.swift").write_text("final class Example: XCTestCase {\n    func testOne() {}\n}\n")
        binary = self.executable(scratch / "debug/ActualTests.xctest/Contents/MacOS/ActualTests")
        helper = self.executable(scratch / "debug/CalendarHelper")
        binding = runner.build_binding(runner.source_identity(repo), binary.resolve(), helper.resolve())
        (scratch / "test-native-build.json").write_text(json.dumps(binding))
        output = self.root / "report"
        argv = ["test-native", "--skip-build", "--scratch-path", str(scratch), "--output-dir", str(output)]
        with patch.object(runner, "REPO", repo), patch("sys.argv", argv), patch.dict("os.environ", {}, clear=True), \
                patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main(), 1)
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["exit_code"], 0)
        self.assertTrue(summary["inventory_errors"])
        self.assertEqual(summary["expected_inventory"], ["Example/testOne"])
        self.assertGreaterEqual(summary["execution_seconds"], 0)

    def serial_log(self, status="passed"):
        skipped, failures = int(status == "skipped"), int(status == "failed")
        aggregate = f"    Executed 1 test, with {str(skipped) + ' test skipped and ' if skipped else ''}{failures} failures (0 unexpected) in 0.125 (0.130) seconds"
        return ("Test Suite 'All tests' started at synthetic-time.\n"
                "Test Case '-[CalendarHelperTests.Example testOne]' started.\n"
                f"Test Case '-[CalendarHelperTests.Example testOne]' {status} (0.125 seconds).\n"
                f"Test Suite 'All tests' {'failed' if failures else 'passed'} at synthetic-time.\n"
                + aggregate + "\n")

    def serial_result(self, text):
        path = self.root / "serial.log"
        path.write_text(text)
        return runner.serial_results(path, ["Example/testOne"])

    def testSerialCompleteStartCompletionAndFinalAggregateAreRequired(self):
        result = self.serial_result(self.serial_log())
        self.assertEqual(result["inventory_errors"], [])
        self.assertEqual(result["report_format"], "serial_log")
        self.assertEqual(result["tests"], 1)
        self.assertEqual(result["test_seconds"], 0.125)

    def testSerialTruncatedFinalSummaryFails(self):
        for text in (self.serial_log().rsplit("\n", 2)[0] + "\n", self.serial_log().split("Test Suite 'All tests' passed")[0]):
            with self.subTest(text=text):
                self.assertTrue(self.serial_result(text)["inventory_errors"])

    def testSerialEarlierClassAggregateCannotSubstituteForFinalAllTestsAggregate(self):
        text = self.serial_log()
        aggregate = text.splitlines()[-1]
        text = text.replace("Test Suite 'All tests' passed at", "Test Suite 'Example' passed at")
        self.assertIn(aggregate, text)
        self.assertTrue(self.serial_result(text)["inventory_errors"])

    def testSerialDuplicatesUnknownCasesAndMissingStartFail(self):
        text = self.serial_log()
        case_lines = "\n".join(text.splitlines()[1:3]) + "\n"
        variants = [text.replace(case_lines, case_lines * 2), text.replace("testOne", "testOther"),
                    text.replace(text.splitlines()[1] + "\n", ""), text.replace(text.splitlines()[2] + "\n", "")]
        for variant in variants:
            with self.subTest(variant=variant):
                self.assertTrue(self.serial_result(variant)["inventory_errors"])

    def testSerialMalformedOrWrongModuleCaseSyntaxFails(self):
        for text in (self.serial_log().replace("CalendarHelperTests.Example", "OtherModule.Example"),
                     self.serial_log().replace("passed (0.125 seconds).", "finished.")):
            with self.subTest(text=text):
                self.assertTrue(self.serial_result(text)["inventory_errors"])

    def testSerialFinalAggregateCountsAndUnexpectedFailuresMustAgree(self):
        for text in (self.serial_log().replace("Executed 1 test", "Executed 2 tests"),
                     self.serial_log().replace("0 failures", "1 failure"),
                     self.serial_log().replace("0 unexpected", "1 unexpected")):
            with self.subTest(text=text):
                self.assertTrue(self.serial_result(text)["inventory_errors"])

    def testSerialSkippedAndFailedCasesRemainVisible(self):
        skipped = self.serial_result(self.serial_log("skipped"))
        self.assertEqual((skipped["skipped"], skipped["failures"]), (1, 0))
        self.assertEqual(skipped["inventory_errors"], [])
        failed = self.serial_result(self.serial_log("failed"))
        self.assertEqual(failed["failures"], 1)
        self.assertTrue(failed["inventory_errors"])

    def testSerialDuplicateSuiteAndCaseAfterSuiteEndFail(self):
        text = self.serial_log()
        for variant in (text + text, text + text.splitlines()[1] + "\n"):
            with self.subTest(variant=variant):
                self.assertTrue(self.serial_result(variant)["inventory_errors"])

    def testNonzeroSerialProcessCannotPassDespiteACompleteSuccessfulLog(self):
        repo, scratch = self.root / "repo", self.root / "build"
        tests = repo / "Tests/CalendarHelperTests"
        tests.mkdir(parents=True)
        (repo / "Sources").mkdir()
        (repo / "Package.swift").write_text("// synthetic package")
        (tests / "Example.swift").write_text("final class Example: XCTestCase {\n    func testOne() {}\n}\n")
        binary = self.executable(scratch / "debug/ActualTests.xctest/Contents/MacOS/ActualTests")
        helper = self.executable(scratch / "debug/CalendarHelper")
        binding = runner.build_binding(runner.source_identity(repo), binary.resolve(), helper.resolve())
        (scratch / "test-native-build.json").write_text(json.dumps(binding))
        output = self.root / "serial-report"
        def launch(command, **kwargs):
            kwargs["stdout"].write(self.serial_log().encode())
            return subprocess.CompletedProcess(command, 3)
        argv = ["test-native", "--workers", "1", "--skip-build", "--scratch-path", str(scratch), "--output-dir", str(output)]
        with patch.object(runner, "REPO", repo), patch("sys.argv", argv), patch.dict("os.environ", {}, clear=True), \
                patch.object(runner.subprocess, "run", side_effect=launch), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main(), 3)
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["report_format"], "serial_log")
        self.assertEqual(summary["tests"], 1)
        self.assertEqual(summary["exit_code"], 3)

    def testSourceInventoryRejectsDuplicatesRatherThanHidingThem(self):
        path = self.root / "Example.swift"
        path.write_text("final class Example: XCTestCase {\n    func testOne() {}\n    func testOne() {}\n}\n")
        with self.assertRaises(ValueError):
            runner.source_inventory(self.root)


if __name__ == "__main__":
    unittest.main()
