#!/usr/bin/env python3
"""G1 fixture checker (stdlib only): structural validation of schema-v1 fixtures.

Usage: python3 tests/check_fixtures.py
Exit 0 iff all fixtures parse and satisfy the envelope/node contracts.
Full JSON-Schema validation lands with validator deps at G5; this checker
pins the structural invariants G2/G3 code against.
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "tests" / "fixtures"

CUDA_APIS = {"cudaMalloc", "cudaMemcpy", "cudaMemset", "cudaFree",
             "cudaStreamCreate", "cudaStreamSynchronize", "cudaStreamDestroy",
             "cudaEventCreate", "cudaEventRecord", "cudaEventSynchronize",
             "cudaEventDestroy", "cudaEventElapsedTime", "cudaGetLastError",
             "cudaGetErrorString", "cudaSetDevice", "cudaDeviceSynchronize"}
HIP_APIS = {"hip" + a[4:] for a in CUDA_APIS}
BUILTINS = {f"{b}.{a}" for b in ("threadIdx", "blockIdx", "blockDim", "gridDim")
            for a in ("x", "y", "z")}
BINOPS = {"+", "-", "*", "/", "%", "<", "<=", ">", ">=", "==", "!=", "&&", "||"}
ERRORS = []


def err(msg):
    ERRORS.append(msg)


def check_expr(e, ctx, hip):
    if not isinstance(e, dict) or "kind" not in e:
        return err(f"{ctx}: expr not an object with kind: {e!r:.80}")
    k = e["kind"]
    if k == "var":
        if not isinstance(e.get("name"), str):
            err(f"{ctx}: var without name")
    elif k in ("int", "float"):
        if not isinstance(e.get("value"), (int, float)):
            err(f"{ctx}: {k} without numeric value")
    elif k == "binop":
        if e.get("op") not in BINOPS:
            err(f"{ctx}: bad binop {e.get('op')}")
        check_expr(e.get("left"), ctx, hip)
        check_expr(e.get("right"), ctx, hip)
    elif k == "unop":
        if e.get("op") not in ("!", "-"):
            err(f"{ctx}: bad unop {e.get('op')}")
        check_expr(e.get("expr"), ctx, hip)
    elif k == "subscript":
        check_expr(e.get("base"), ctx, hip)
        check_expr(e.get("index"), ctx, hip)
    elif k == "builtin":
        if e.get("name") not in BUILTINS:
            err(f"{ctx}: bad builtin {e.get('name')}")
    elif k == "addrof":
        if not isinstance(e.get("name"), str):
            err(f"{ctx}: addrof without name")
    elif k == "call":
        for a in e.get("args", []):
            check_expr(a, ctx, hip)
    else:
        err(f"{ctx}: unknown expr kind {k!r}")


def check_stmt(s, ctx, hip):
    if not isinstance(s, dict) or "kind" not in s:
        err(f"{ctx}: statement must be an object with kind: {s!r:.80}")
        return
    k = s.get("kind")
    if k == "let":
        check_expr(s["value"], ctx, hip)
    elif k == "store":
        check_expr(s["target"], ctx, hip)
        check_expr(s["value"], ctx, hip)
    elif k == "if":
        check_expr(s["cond"], ctx, hip)
        if not isinstance(s.get("then"), list) or not isinstance(s.get("else"), list):
            err(f"{ctx}: if branches must be lists")
            return
        for t in s.get("then", []):
            check_stmt(t, ctx, hip)
        for t in s.get("else", []):
            check_stmt(t, ctx, hip)
    elif k in ("syncthreads",):
        pass
    elif k == "expr_stmt":
        check_expr(s["expr"], ctx, hip)
    else:
        err(f"{ctx}: unknown stmt kind {k!r}")


def check_envelope(path, tag, header, apis):
    try:
        doc = json.loads(path.read_text())
    except Exception as exc:
        return err(f"{path.name}: invalid JSON: {exc}")
    if doc.get("schema") != tag:
        err(f"{path.name}: schema tag {doc.get('schema')!r} != {tag!r}")
    if not isinstance(doc.get("source"), str):
        err(f"{path.name}: missing source")
    prog, diags = doc.get("program"), doc.get("diagnostics")
    if not isinstance(diags, list):
        err(f"{path.name}: diagnostics not a list")
    for d in diags:
        if not all(k in d for k in ("code", "feature", "loc", "hint")):
            err(f"{path.name}: malformed diagnostic {d!r:.80}")
    if prog is None:
        if not diags:
            err(f"{path.name}: null program requires a blocking diagnostic")
        return
    if prog.get("header") != header:
        err(f"{path.name}: header {prog.get('header')!r} != {header!r}")
    for kn in prog.get("kernels", []):
        for p in kn.get("params", []):
            if p.get("type") not in ("int", "float", "double"):
                err(f"{path.name}: bad param type {p!r:.60}")
        if not isinstance(kn.get("body"), list):
            err(f"{path.name}: kernel body must be a list")
            continue
        for s in kn.get("body", []):
            check_stmt(s, path.name, tag.startswith("minihip"))
    for h in prog.get("host", []):
        hk = h.get("kind")
        if hk == "api":
            if h["name"] not in apis:
                err(f"{path.name}: api {h['name']!r} not in {'hip' if 'hip' in tag else 'cuda'} set")
            if h["name"].endswith("Memcpy") and "copyKind" not in h:
                err(f"{path.name}: memcpy without copyKind")
            if not isinstance(h.get("args"), list):
                err(f"{path.name}: api args must be a list")
                continue
            for a in h.get("args", []):
                check_expr(a, path.name, False)
        elif hk == "launch":
            check_expr(h["grid"], path.name, False)
            check_expr(h["block"], path.name, False)
            if not isinstance(h.get("args"), list):
                err(f"{path.name}: launch args must be a list")
                continue
        elif hk == "host_code":
            if "cuda" in h.get("text", ""):
                err(f"{path.name}: host_code passthrough contains cuda* identifier")
        else:
            err(f"{path.name}: unknown host node {hk!r}")


def main():
    plans = [
        ("vectorAdd.minicuda.json", "minicuda/v1", "cuda_runtime.h", CUDA_APIS),
        ("saxpy.minicuda.json", "minicuda/v1", "cuda_runtime.h", CUDA_APIS),
        ("reject-asm.minicuda.json", "minicuda/v1", "cuda_runtime.h", CUDA_APIS),
        ("vectorAdd.minihip.json", "minihip/v1", "hip/hip_runtime.h", HIP_APIS),
    ]
    for name, tag, header, apis in plans:
        p = FIX / name
        if not p.exists():
            err(f"missing fixture {name}")
        else:
            check_envelope(p, tag, header, apis)
    # cross-fixture: minihip api set must be the exact cuda->hip rename
    if HIP_APIS != {"hip" + a[4:] for a in CUDA_APIS}:
        err("hip api set drifted from cuda set rename rule")
    if ERRORS:
        print(f"{len(ERRORS)} fixture error(s):")
        for m in ERRORS:
            print(f"  - {m}")
        return 1
    print(f"OK: {len(plans)} fixtures valid (schema v1 structural contract holds)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
