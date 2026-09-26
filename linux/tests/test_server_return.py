"""ssh-server-return.v1: la política de Linux decide lo mismo que la del Mac, caso a caso."""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from contracts_dir import contract  # noqa: E402
from uniconnect.server_return import (CHECK_INTERVAL_SECONDS, PROBE_TIMEOUT_SECONDS,  # noqa: E402
                                      ServerReturnPolicy)


class ServerReturnContractTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(contract("ssh-server-return-v1", "casos.json").read_text(encoding="utf-8"))

    def test_every_case_decides_the_same(self):
        self.assertEqual(self.data["contrato"], "ssh-server-return.v1")
        self.assertTrue(self.data["casos"])
        for case in self.data["casos"]:
            with self.subTest(case=case["nombre"]):
                policy = ServerReturnPolicy()
                decided = [policy.observe(answer) for answer in case["observaciones"]]
                self.assertEqual(decided, case["decisiones"])

    def test_cadence_matches_the_contract(self):
        self.assertEqual(CHECK_INTERVAL_SECONDS, self.data["intervalo_segundos"])
        self.assertEqual(PROBE_TIMEOUT_SECONDS, self.data["timeout_sonda_segundos"])


if __name__ == "__main__":
    unittest.main()
