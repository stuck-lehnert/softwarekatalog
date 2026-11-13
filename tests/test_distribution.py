"""Portable build and ADMX/ADML integrity checks; no external packages."""
import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class DistributionTests(unittest.TestCase):
    def test_bootstrap_is_ascii_and_preserves_exact_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "setup.ps1"
            env = dict(os.environ, SOFTKAT_BUILD_COMMIT="ci-build-marker")
            subprocess.run(["bash", "scripts/build-dist.sh", "setup.ps1", str(output)],
                           cwd=ROOT, env=env, check=True)
            wrapper = output.read_bytes()
            self.assertTrue(wrapper.isascii())
            match = re.search(rb"\$Payload = @'\r?\n([^\r\n]+)\r?\n'@", wrapper)
            self.assertIsNotNone(match)
            payload = base64.b64decode(match[1], validate=True)
            self.assertEqual(payload, b"# Softwarekatalog build commit: ci-build-marker\n" +
                             (ROOT / "setup.ps1").read_bytes())
            for parameter in ("Mode", "RequestAction", "AppAlias", "RequestedBy", "RequestedBySid"):
                self.assertIn(("-" + parameter + " $" + parameter).encode(), wrapper)
            self.assertIn(b"finally", wrapper)
            self.assertIn(b"Remove-Item -LiteralPath $TempScript", wrapper)
            self.assertIn(b"$OutputBytes[0] = 0xEF", wrapper)

    def test_policy_resource_references_exist_in_both_languages(self):
        admx = ET.parse(ROOT / "PolicyDefinitions/Softwarekatalog.admx").getroot()
        raw = ET.tostring(admx, encoding="unicode")
        string_refs = set(re.findall(r"\$\(string\.([^)]+)\)", raw))
        presentation_refs = set(re.findall(r"\$\(presentation\.([^)]+)\)", raw))
        self.assertTrue(string_refs)
        ids_by_language = []
        for locale in ("de-DE", "en-US"):
            adml = ET.parse(ROOT / f"PolicyDefinitions/{locale}/Softwarekatalog.adml").getroot()
            strings = [n.attrib["id"] for n in adml.findall(".//{*}string")]
            presentations = [n.attrib["id"] for n in adml.findall(".//{*}presentation")]
            self.assertEqual(len(strings), len(set(strings)), f"duplicate string IDs in {locale}")
            self.assertEqual(len(presentations), len(set(presentations)))
            self.assertLessEqual(string_refs, set(strings), locale)
            self.assertLessEqual(presentation_refs, set(presentations), locale)
            ids_by_language.append((set(strings), set(presentations)))
        self.assertEqual(*ids_by_language)
        policies = admx.findall(".//{*}policy")
        self.assertTrue(policies)
        self.assertTrue(all(p.attrib.get("class") == "Machine" for p in policies))

    def test_repository_does_not_track_generated_payload(self):
        tracked = subprocess.check_output(["git", "ls-files", "dist"], cwd=ROOT, text=True)
        self.assertEqual(tracked.strip(), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
