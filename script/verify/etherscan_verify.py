#!/usr/bin/env python3
"""Submit to Etherscan V2 by raw HTTP, because forge 1.7.1 cannot.

forge's built-in chain list predates Robinhood Chain (4663), so `--verifier etherscan` fails before
it ever builds a request: without --verifier-url it says "No known Etherscan API URL for chain 4663",
and with one it says "ETHERSCAN_API_KEY must be set" even when the key is exported AND passed as a
flag. Both are the same failure to construct a verifier for an unknown chain; the key message is a
red herring.

chainid goes in the QUERY STRING, not just the body — in the body alone it silently defaults to
chainid=1 (skill gotcha 10).
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

CHAIN = "4663"
API = f"https://api.etherscan.io/v2/api?chainid={CHAIN}"
COMPILER = "v0.8.34+commit.80d5c536"  # v-prefixed here, unlike Sourcify

LIB_LINK = {
    "src/libraries/UniswapV3VaultMath.sol": {
        "UniswapV3VaultMath": "0xcabe2683c45855ca7dba5cc2e30186ac7cdb523a"
    }
}


def key():
    for line in open("/home/sgzerbo/github-projects/"
                    "onchain-investment-vehicles-feat-uniswap-v3-position-vault/.env"):
        if line.startswith("ETHERSCAN_API_KEY="):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    sys.exit("no ETHERSCAN_API_KEY in .env")


KEY = key()


def post(fields):
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(API, data=data, method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())


def get(params):
    with urllib.request.urlopen(f"{API}&{urllib.parse.urlencode(params)}", timeout=60) as r:
        return json.loads(r.read())


def read_status(addr):
    res = get({"module": "contract", "action": "getsourcecode", "address": addr, "apikey": KEY})
    result = res.get("result")
    if isinstance(result, list) and result:
        return "VERIFIED" if result[0].get("SourceCode") else "not-verified"
    return f"read-error: {json.dumps(res)[:120]}"


def submit(label, std_path, ident, addr, link_library=False, ctor=""):
    print(f"=== {label} {addr}")
    before = read_status(addr)
    print(f"  before: {before}")
    if before == "VERIFIED":
        return

    std = json.load(open(std_path))
    if link_library:
        std["settings"]["libraries"] = LIB_LINK

    fields = {
        "module": "contract", "action": "verifysourcecode", "apikey": KEY,
        "chainid": CHAIN,
        "codeformat": "solidity-standard-json-input",
        "sourceCode": json.dumps(std),
        "contractaddress": addr,
        "contractname": ident,
        "compilerversion": COMPILER,
    }
    if ctor:
        fields["constructorArguements"] = ctor  # Etherscan's own misspelling

    res = post(fields)
    print(f"  submit: {json.dumps(res)[:200]}")
    guid = res.get("result") if res.get("status") == "1" else None
    if not guid:
        return

    for _ in range(30):
        time.sleep(8)
        st = get({"module": "contract", "action": "checkverifystatus",
                  "guid": guid, "apikey": KEY})
        msg = str(st.get("result"))
        if "Pending" in msg:
            continue
        print(f"  status: {msg[:160]}")
        break
    else:
        print("  status: still pending after 4 minutes")
    print(f"  after:  {read_status(addr)}")


if __name__ == "__main__":
    submit("UniswapV3VaultMath", "/tmp/verif/lib.json",
           "src/libraries/UniswapV3VaultMath.sol:UniswapV3VaultMath",
           "0xcabe2683c45855ca7dba5cc2e30186ac7cdb523a")
    submit("UniswapV3PositionVault", "/tmp/verif/impl.json",
           "src/UniswapV3PositionVault.sol:UniswapV3PositionVault",
           "0xed93fc3b31206f3778163a5ad29b50bf7eeb8948", link_library=True)
    print("MARKER_DONE")
