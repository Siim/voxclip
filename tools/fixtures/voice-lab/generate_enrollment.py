#!/usr/bin/env python3
"""C7 enrollment oracle: synthetic inputs only; no provider calls or model downloads."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def main():
    flows = []
    for name, events, outcome in [
        ("success", ["plan", "verify", "create"], "created"),
        ("verify-fail", ["plan", "verify"], "statementMismatch"),
        ("create-fail", ["plan", "verify", "create"], "creationPending"),
        ("speaker-mismatch", [], "speakerMismatch"),
        ("declined", [], "consentRequired"),
        ("disabled", [], "consentRequired"),
        ("plan-denied", ["plan"], "planUnavailable"),
        ("no-slots", ["plan"], "noVoiceSlots"),
    ]:
        flows.append(dict(id=name, events=events, outcome=outcome))
    recoveries = []
    for name, seconds, same, action, events in [
        ("fresh", 299, True, "create", ["plan", "create"]),
        ("expired", 300, False, "create", ["plan", "create"]),
        ("unsent-intent", 0, True, "create", ["plan", "create"]),
        ("declined-recovery", 0, True, "decline", []),
        ("changed-statement", 0, True, "reject", []),
        ("different-creator", 0, True, "reject", []),
        ("dispatched", 0, True, "reject", []),
        ("cancelled", 0, True, "reject", []),
    ]:
        recoveries.append(dict(id=name, elapsedSeconds=seconds, sameQuote=same, action=action, events=events))
    result = dict(schema="voxclip-enrollment-cases/1", flows=flows,
                  mutations=["same", "statementBytes", "statementText", "nonce", "files", "fileBytes", "order", "roles", "name", "language", "createdAt", "noiseRemoval", "recordID"],
                  attempts=dict(limit=3, blockedAtSeconds=599, allowedAtSeconds=600), recoveries=recoveries)
    target = ROOT / "shared/fixtures/voice-lab/enrollment-cases.json"
    target.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
