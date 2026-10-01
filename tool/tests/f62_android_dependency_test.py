from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FreeRdpAndroidDependencyTest(unittest.TestCase):
    def test_packaged_debug_runtime_aligns_the_stable_instrumentation_runner(self):
        build = (ROOT / "android/app/build.gradle.kts").read_text()
        constraint = 'debugRuntimeOnly("androidx.test:runner:1.7.0")'
        instrumentation = 'androidTestImplementation("androidx.test:runner:1.7.0")'

        self.assertEqual(build.count(constraint), 1)
        self.assertEqual(build.count(instrumentation), 1)
        self.assertIn("constraints {\n        if (hasFreeRdp || hasMoonlight) {", build)
        self.assertLess(build.index(constraint), build.index(instrumentation))
        self.assertNotIn("resolutionStrategy.force", build)
        self.assertNotIn('implementation("androidx.test:runner:', build)


if __name__ == "__main__":
    unittest.main()
