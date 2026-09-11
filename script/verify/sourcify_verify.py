#!/usr/bin/env python3
"""Verify deployed contracts on Sourcify v2.

Sourcify is keyless, exact-matches against chain state (so no constructor args), and is the only
backend that covers some newer chains at all — on Robinhood Chain (4663) it is the ONLY one:
Etherscan V2 and Routescan answer "chain not supported", OKLink has no chainShortName for it, and the
Blockscout instance serves its whole API behind a Cloudflare JS challenge that curl cannot answer.

    python3 script/verify/sourcify_verify.py --chain 4663 --targets robinhood-vaults

Generating the standard-JSON inputs first (two traps, both silent):

  # a dummy ETHERSCAN_API_KEY is REQUIRED or forge writes an EMPTY file and exits 0
  ETHERSCAN_API_KEY=dummy forge verify-contract 0x0 <path>:<Name> \
      --compilation-profile <profile> --show-standard-json-input > std.json

  # --compilation-profile is REQUIRED for any contract the repo builds under more than one profile
  # (UniswapV3VaultMath is built at runs=2000 by default and runs=60 under vault-size); without it
  # forge refuses with "Ambiguous compilation profiles found in cache".

For a contract that links a library, settings.libraries must carry the DEPLOYED library address or
the recompiled code keeps a __$…$__ placeholder and matches nothing. Pinning it in foundry.toml would
break the fork tests, which deploy their own library, so inject it into the std-JSON instead — see
LIBRARY_LINKS below. That injection changes the metadata hash, which is why such a contract comes
back `match` rather than `exact_match`: the code is verified, the metadata is not byte-identical.
"""
import argparse
import json
import time
import urllib.error
import urllib.request

SERVER = "https://sourcify.dev/server"
COMPILER = "0.8.34+commit.80d5c536"  # BARE — Sourcify takes no "v" prefix, unlike every other backend

# Injected into a std-JSON before submission; keyed by the std-JSON path.
LIBRARY_LINKS = {
    "/tmp/verif/impl.json": {
        "src/libraries/UniswapV3VaultMath.sol": {
            "UniswapV3VaultMath": "0xcabe2683c45855ca7dba5cc2e30186ac7cdb523a"
        }
    },
}

PROXY_IDENT = ("lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/"
               "ERC1967/ERC1967Proxy.sol:ERC1967Proxy")

TARGET_SETS = {
    # Robinhood Chain WETH/USDG vaults, deployed 2026-09-11.
    "robinhood-vaults": [
        ("UniswapV3VaultMath", "/tmp/verif/lib.json",
         "src/libraries/UniswapV3VaultMath.sol:UniswapV3VaultMath",
         "0xcabe2683c45855ca7dba5cc2e30186ac7cdb523a"),
        ("UniswapV3PositionVault", "/tmp/verif/impl.json",
         "src/UniswapV3PositionVault.sol:UniswapV3PositionVault",
         "0xed93fc3b31206f3778163a5ad29b50bf7eeb8948"),
        ("vault fee 100", "/tmp/verif/proxy.json", PROXY_IDENT,
         "0x769b7288280a846c3ce0a19c6187c8111f3e6884"),
        ("vault fee 500", "/tmp/verif/proxy.json", PROXY_IDENT,
         "0x096F31D7616b7dc4a1097805c7fc0e59899036a1"),
        ("vault fee 3000", "/tmp/verif/proxy.json", PROXY_IDENT,
         "0x483D16CC55998a0b1572C0961E40d87F7AE914B1"),
        ("vault fee 10000", "/tmp/verif/proxy.json", PROXY_IDENT,
         "0xbC05cFfE0aF35fa9132aC42fC6cbc09c0328B802"),
    ],
}


def call(url, payload=None, timeout=120):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if payload is not None else {}
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if payload is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        try:
            return exc.code, json.loads(body)
        except ValueError:
            return exc.code, {"raw": body[:300]}
    except Exception as exc:  # noqa: BLE001 - a transport failure is a result, not a crash
        return 0, {"error": str(exc)}


def load_std(path):
    std = json.load(open(path))
    links = LIBRARY_LINKS.get(path)
    if links:
        std["settings"]["libraries"] = links
    return std


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chain", required=True)
    ap.add_argument("--targets", required=True, choices=sorted(TARGET_SETS))
    ap.add_argument("--read-only", action="store_true",
                    help="Only read current status; submit nothing.")
    args = ap.parse_args()

    targets = TARGET_SETS[args.targets]
    jobs = []

    for label, path, ident, addr in targets:
        # Read first: an already-verified contract needs no submission, and the read is free.
        _, current = call(f"{SERVER}/v2/contract/{args.chain}/{addr}")
        if current.get("match"):
            print(f"{label:24} {addr}  already {current['match']}")
            continue
        if args.read_only:
            print(f"{label:24} {addr}  NOT VERIFIED")
            continue

        status, res = call(f"{SERVER}/v2/verify/{args.chain}/{addr}", {
            "stdJsonInput": load_std(path),
            "compilerVersion": COMPILER,
            "contractIdentifier": ident,
        })
        vid = res.get("verificationId")
        print(f"{label:24} {addr}  submit HTTP {status}  {json.dumps(res)[:120]}")
        if vid:
            jobs.append((label, addr, vid))

    for label, addr, vid in jobs:
        for _ in range(40):
            time.sleep(6)
            _, job = call(f"{SERVER}/v2/verify/{vid}")
            if not job.get("isJobCompleted"):
                continue
            contract = job.get("contract", {})
            line = f"{label:24} {addr}  match={contract.get('match')}"
            if job.get("error"):
                line += f"  error={json.dumps(job['error'])[:200]}"
            ext = job.get("externalVerifications")
            if ext:
                line += f"  propagated={json.dumps(ext)[:160]}"
            print(line)
            break
        else:
            print(f"{label:24} {addr}  still running after 4 minutes")

    # Confirm by read, never by submit result — the skill's rule, and it has caught wrong answers.
    print("\n--- confirmation reads ---")
    for label, _, _, addr in targets:
        _, final = call(f"{SERVER}/v2/contract/{args.chain}/{addr}")
        print(f"{label:24} {addr}  {final.get('match')}")


if __name__ == "__main__":
    main()
