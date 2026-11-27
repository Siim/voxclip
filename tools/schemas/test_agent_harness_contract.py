import json
import unittest

import test_harness_contract as contract


class AgentHarnessContract(unittest.TestCase):
    def setUp(self):
        self.saved = contract.HarnessContract()
        self.addCleanup(self.saved.doCleanups)
        self.saved.setUp()

    def test_saved_hosts_refuse_revisions_without_staging(self):
        arguments = {"timelines": [self.saved.timeline], "revises": "t1"}
        (reply,) = self.saved.replay(self.saved.call("propose_timeline", **arguments))
        refusal = "Revising is only for the in-app chat."
        self.assertTrue(reply["isError"])
        self.assertEqual(reply["content"][0]["text"], refusal)
        cli = self.saved.run_cli("propose-timeline", json.dumps(arguments))
        self.assertNotEqual(cli.returncode, 0)
        self.assertIn(refusal, cli.stderr)
        self.assertFalse(self.saved.pending.exists())


if __name__ == "__main__":
    unittest.main()
