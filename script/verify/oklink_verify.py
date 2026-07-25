#!/usr/bin/env python3
"""Verify the salt-v3 canonical contracts on OKLink, and report what is already verified.

Usage (from the repo root, with foundry on PATH):

    python3 script/verify/oklink_verify.py --prepare   # regenerate the standard-JSON inputs
    python3 script/verify/oklink_verify.py             # sweep all 30 targets

Safe and idempotent: a target that is already verified is reported as such and left
alone, and anything genuinely unverified is submitted and polled to a final result.


Reading OKLink's responses
--------------------------
OKLink's two verify routes are KEYLESS. An OKX *trading* API key does not work here --
it returns `Invalid OK-ACCESS-KEY`, because that credential belongs to a different
product. What the routes do need is a browser `User-Agent`: OKLink's WAF answers 403 to
urllib and other default agents, so every request below goes out through `curl`.

`verify-source-code` (submit) returns:

    {"code": "0", ...,  "data": ["<guid>"]}   accepted; poll the guid
    {"code": "50026", "msg": "System error, please try again later."}

**50026 does not mean a system error, and it does not mean rate-limiting.** It means
*this (chain, address) already has a successful verification*. That was established by
controlled experiment on 2026-07-25:

  * it tracks the (chain, address) pair, not the payload -- a 200-byte throwaway
    payload at one of our addresses returns 50026, while that same payload at an
    unrelated address is accepted, as is our full 244 KB payload at an unrelated
    address (so it is not size, not the source, and not our IP);
  * gnosis returned `code 0` before it was verified, and 50026 minutes later once its
    three contracts had come back `Success` -- same chain, same address, same payload;
  * an address carrying only *failed* verification jobs keeps accepting resubmits.

The earlier reading of 50026 as IP throttling ("retry from a cooled-down IP") was wrong
and cost a session; it is recorded here so it is not rediscovered a third time.

`check-verify-result` (poll by guid) is keyless, never throttled, and returns the result
as a **bare list of strings**, not a list of objects:

    {"code": "0", "data": ["Success"]}        # NOT [{"verifyResult": "Success"}]

A guid is only ever minted by a submit, so an already-verified target cannot be re-read
directly -- 50026 is the only signal available for it.
"""

import argparse
import json
import os
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STD_DIR = os.path.join(REPO, "script", "verify", "std-json")

BASE = "https://www.oklink.com/api/v5/explorer/contract"
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

COMPILER = "v0.8.34+commit.80d5c536"
OPTIMIZER_RUNS = "2000"

# Constructor args are the DEPLOY-TIME values (owner is the deployer EOA, not the Safe
# it was later handed to; the factory's 8th arg is the address(0) placeholder wired up
# afterwards by setKpkSharesDeployer). Read back off the verified mainnet entries.
CONTRACTS = {
    "kpkOivFactory": {
        "address": "0xbafbca1804B6e46D4c54Cac0A0273F5B2A8F677F",
        "identifier": "src/KpkOivFactory.sol:KpkOivFactory",
        "ctor": (
            "000000000000000000000000aa5a7c7ea51f276301f881f9ccb501a1dfef4f72"
            "000000000000000000000000a6b71e26c5e0845f74c812102ca7114b6a896ab2"
            "00000000000000000000000041675c099f32341bf84bfc5382af534df5c7461a"
            "0000000000000000000000002dd68b007b46fbe91b9a7c3eda5a7a1063cb5b47"
            "000000000000000000000000fd0732dc9e303f09fcef3a7388ad10a83459ec99"
            "000000000000000000000000000000000000addb49795b0f9ba5bc298cdda236"
            "000000000000000000000000f2964ce6161ce0e75964fe7927ce114cb0b283d5"
            "0000000000000000000000000000000000000000000000000000000000000000"
        ),
    },
    "kpkSharesDeployer": {
        "address": "0xea084E763F8535CBe28759b990F963BeDf60be9a",
        "identifier": "src/KpkSharesDeployer.sol:KpkSharesDeployer",
        "ctor": "000000000000000000000000bafbca1804b6e46d4c54cac0a0273f5b2a8f677f",
    },
    "ccipOivDeployer": {
        "address": "0x6F2A3D35Ff275d6B76dB47eFB0Da1b2358daf11b",
        "identifier": "src/CcipOivDeployer.sol:CcipOivDeployer",
        "ctor": (
            "000000000000000000000000aa5a7c7ea51f276301f881f9ccb501a1dfef4f72"
            "000000000000000000000000bafbca1804b6e46d4c54cac0a0273f5b2a8f677f"
        ),
    },
}

# The 10 of our 19 deployed chains that OKLink serves, in `chainShortName` form.
# `Empty` is deliberately absent from CONTRACTS: it is a no-logic contract and fails
# every exact-bytecode-match backend (OKLink, Sourcify, Tenderly). That is structural,
# not a gap -- it is covered on Etherscan V2 + Blockscout instead.
CHAINS = {
    "ethereum": "ETH",
    "optimism": "OP",
    "gnosis": "GNOSIS",
    "base": "BASE",
    "arbitrum": "ARBITRUM",
    "bnb": "BSC",
    "polygon": "POLYGON",
    "avalanche": "AVAXC",
    "linea": "LINEA",
    "scroll": "SCROLL",
}

ALREADY_VERIFIED = "50026"


def std_path(name):
    return os.path.join(STD_DIR, "%s.json" % name)


def prepare():
    """Regenerate the standard-JSON inputs with forge (optimizer/viaIR live inside)."""
    os.makedirs(STD_DIR, exist_ok=True)
    for name, meta in CONTRACTS.items():
        with open(std_path(name), "w") as fh:
            subprocess.run(
                ["forge", "verify-contract",
                 "0x0000000000000000000000000000000000000000",
                 meta["identifier"], "--show-standard-json-input"],
                cwd=REPO, stdout=fh, check=True,
            )
        print("wrote %s (%d bytes)" % (std_path(name), os.path.getsize(std_path(name))))


def post(route, body, timeout=90):
    tmp = os.path.join(STD_DIR, ".request.json")
    with open(tmp, "w") as fh:
        json.dump(body, fh)
    try:
        proc = subprocess.run(
            ["curl", "-s", "-m", str(timeout), "-X", "POST", "%s/%s" % (BASE, route),
             "-H", "Content-Type: application/json", "-H", "User-Agent: " + UA,
             "--data-binary", "@" + tmp],
            capture_output=True, text=True,
        )
    finally:
        os.path.exists(tmp) and os.remove(tmp)
    try:
        return json.loads(proc.stdout.strip())
    except ValueError:
        return {"code": "PARSE_ERROR", "msg": proc.stdout.strip()[:300]}


def submit(chain, name):
    meta = CONTRACTS[name]
    with open(std_path(name)) as fh:
        source = fh.read()
    r = post("verify-source-code", {
        "chainShortName": CHAINS[chain],
        "contractAddress": meta["address"],
        "contractName": meta["identifier"],
        "sourceCode": source,
        "codeFormat": "solidity-standard-json-input",
        "compilerVersion": COMPILER,
        "optimization": "1",
        "optimizationRuns": OPTIMIZER_RUNS,
        "constructorArguments": meta["ctor"],
    })
    data = r.get("data") or []
    return r.get("code"), (data[0] if data else None)


def check(chain, guid):
    r = post("check-verify-result",
             {"chainShortName": CHAINS[chain], "guid": guid})
    data = r.get("data") or []
    if not data:
        return None
    return data[0].get("verifyResult") if isinstance(data[0], dict) else data[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prepare", action="store_true",
                    help="regenerate the standard-JSON inputs and exit")
    ap.add_argument("--spacing", type=float, default=4.0,
                    help="seconds between submits (default 4)")
    args = ap.parse_args()

    if args.prepare:
        prepare()
        return 0

    for name in CONTRACTS:
        if not os.path.exists(std_path(name)):
            print("missing %s -- run with --prepare first" % std_path(name))
            return 1

    verified, pending, problems = [], [], []
    for chain in CHAINS:
        for name in CONTRACTS:
            code, guid = submit(chain, name)
            target = "%s/%s" % (chain, name)
            if code == ALREADY_VERIFIED:
                verified.append(target)
                print("%-34s already verified" % target)
            elif code == "0" and guid:
                pending.append((chain, name, guid))
                print("%-34s submitted (%s)" % (target, guid))
            else:
                problems.append((target, code))
                print("%-34s UNEXPECTED code=%s" % (target, code))
            time.sleep(args.spacing)

    # Anything actually submitted was NOT verified before; poll it to a final answer.
    for chain, name, guid in pending:
        target = "%s/%s" % (chain, name)
        for _ in range(12):
            time.sleep(10)
            result = check(chain, guid)
            if result and result != "Pending":
                print("%-34s %s" % (target, result))
                if result != "Success":
                    problems.append((target, result))
                break
        else:
            print("%-34s still pending after 120s" % target)
            problems.append((target, "timeout"))

    total = len(CHAINS) * len(CONTRACTS)
    print("\n%d/%d verified (%d already, %d newly submitted), %d problem(s)"
          % (total - len(problems), total, len(verified), len(pending), len(problems)))
    for target, why in problems:
        print("  ! %s: %s" % (target, why))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
