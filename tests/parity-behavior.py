#!/usr/bin/env python3
"""
BEHAVIORAL parity between the two deployment engines.

While `parity-json.ps1` verifies serialization parity, this suite tests behavioral
parity: runs both engines against synthetic target manifests in temporary directories
and confirms that files produced on disk match byte-for-byte.

Verifies conditional strategies such as `superseded_by` (deciding whether to write,
remove, or skip content) and `remove`.

Usage:  python tests/parity-behavior.py [--quiet]
Output: stable final status line, exit 0/1.
"""
import argparse
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MARCADOR = "<!-- parity-behavior-block -->"
TMPDIR = os.environ.get("AGENTSHIELD_TEST_TMPDIR")
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")
DEV_BEFORE = "# Dev notes\n\nI use pnpm, not npm.\n"
DEV_AFTER = "## After the block\n\nText that the dev wrote below.\n"

_ok = 0
_fail = 0


def chk(passou, rotulo, detalhe=""):
    global _ok, _fail
    if passou:
        _ok += 1
        tag = "OK  "
    else:
        _fail += 1
        tag = "FAIL"
    if not passou or not ARGS.quiet:
        linha = "  [%s] %s" % (tag, rotulo)
        if detalhe:
            linha += "  --  %s" % detalhe
        print(linha)
    return passou


def monta_raiz(tmp, com_superseded):
    """Minimal target root: one manifest and compose payload."""
    os.makedirs(os.path.join(tmp, "targets"))
    os.makedirs(os.path.join(tmp, "policy"))
    io.open(os.path.join(tmp, "policy", "rules.md"), "w",
            encoding="utf-8", newline="\n").write("RULE ONE\n")

    spec = {
        "dest": {
            "windows": "${HOME}/target.md",
            "linux": "${HOME}/target.md",
            "darwin": "${HOME}/target.md",
        },
        "format": "markdown",
        "strategy": "md-block",
        "marker": MARCADOR,
        "compose": ["policy/rules.md"],
    }
    if com_superseded:
        spec["superseded_by"] = {
            "windows": "${HOME}/policy.md",
            "linux": "${HOME}/policy.md",
            "darwin": "${HOME}/policy.md",
        }

    target = {
        "id": "teste",
        "label": "Synthetic parity target",
        "tool": "claude",
        "scope": "user",
        "requires_admin": False,
        "selectors": ["parity"],
        "enforcement": {"windows": "advisory", "linux": "advisory",
                        "darwin": "advisory"},
        "files": [spec],
    }
    io.open(os.path.join(tmp, "targets", "teste.json"), "w",
            encoding="utf-8", newline="\n").write(
                json.dumps(target, indent=2, ensure_ascii=False) + "\n")


def roda(motor, raiz, home):
    if motor == "py":
        cmd = [sys.executable, os.path.join(ROOT, "lib", "apply_targets.py"),
               "--root", raiz, "--scope", "user", "--only", "teste",
               "--home", home]
    else:
        cmd = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", os.path.join(ROOT, "lib", "ApplyTargets.ps1"),
               "-Root", raiz, "-Scope", "user", "-Only", "teste",
               "-TargetHome", home]
    r = subprocess.run(cmd, capture_output=True, text=True)
    caminho = os.path.join(home, "target.md")
    conteudo = None
    if os.path.isfile(caminho):
        conteudo = io.open(caminho, encoding="utf-8", newline="").read()
    return conteudo, r.returncode, r.stdout


def cenario(nome, com_superseded, politica_existe, conteudo_inicial, espera):
    """Executes the same scenario across both engines and compares output."""
    saidas = {}
    for motor in ("py", "ps"):
        tmp = tempfile.mkdtemp(dir=TMPDIR)
        raiz = os.path.join(tmp, "raiz")
        home = os.path.join(tmp, "home")
        os.makedirs(raiz)
        os.makedirs(home)
        monta_raiz(raiz, com_superseded)

        if conteudo_inicial is not None:
            io.open(os.path.join(home, "target.md"), "w",
                    encoding="utf-8", newline="\n").write(conteudo_inicial)
        if politica_existe:
            io.open(os.path.join(home, "policy.md"), "w",
                    encoding="utf-8", newline="\n").write("POLICY\n")

        saidas[motor], rc, _ = roda(motor, raiz, home)
        chk(rc == 0, "%s [%s]: engine exits 0" % (nome, motor), "rc=%d" % rc)
        shutil.rmtree(tmp, ignore_errors=True)

    chk(saidas["py"] == saidas["ps"], "%s: both engines produce the SAME file" % nome,
        "" if saidas["py"] == saidas["ps"]
        else "py=%r ps=%r" % (saidas["py"], saidas["ps"]))

    obtido = saidas["py"]
    tem_bloco = obtido is not None and MARCADOR in obtido
    chk(tem_bloco == espera["bloco"],
        "%s: block %s" % (nome, "present" if espera["bloco"] else "absent"),
        "obtained=%s" % tem_bloco)
    if espera.get("preserva"):
        for trecho in espera["preserva"]:
            chk(obtido is not None and trecho in obtido,
                "%s: preserves dev %r" % (nome, trecho[:20]))


def cenario_remove(nome, arquivo_existe):
    """'remove' strategy in both engines: deletes existing, tolerates absent."""
    estados = {}
    for motor in ("py", "ps"):
        tmp = tempfile.mkdtemp(dir=TMPDIR)
        raiz = os.path.join(tmp, "raiz")
        home = os.path.join(tmp, "home")
        os.makedirs(raiz)
        os.makedirs(home)
        monta_raiz(raiz, False)

        alvo_json = os.path.join(raiz, "targets", "teste.json")
        d = json.loads(io.open(alvo_json, encoding="utf-8").read())
        d["files"] = [{
            "dest": {k: "${HOME}/descartado.json" for k in
                     ("windows", "linux", "darwin")},
            "strategy": "remove",
            "$comment": "parity scenario",
        }]
        io.open(alvo_json, "w", encoding="utf-8", newline="\n").write(
            json.dumps(d, indent=2, ensure_ascii=False) + "\n")

        caminho = os.path.join(home, "descartado.json")
        if arquivo_existe:
            io.open(caminho, "w", encoding="utf-8", newline="\n").write("{}\n")

        _, rc, _ = roda(motor, raiz, home)
        chk(rc == 0, "%s [%s]: engine exits 0" % (nome, motor), "rc=%d" % rc)
        estados[motor] = os.path.isfile(caminho)
        shutil.rmtree(tmp, ignore_errors=True)

    chk(estados["py"] == estados["ps"],
        "%s: both engines reach the SAME state" % nome,
        "py_exists=%s ps_exists=%s" % (estados["py"], estados["ps"]))
    chk(estados["py"] is False, "%s: file absent at end" % nome,
        "" if estados["py"] is False
        else "still present -- exclusive MCP control would continue applying")


ARGS = None


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    ARGS = ap.parse_args()

    if not POWERSHELL:
        print("PARITY-BEHAVIOR: SKIP powershell-not-found")
        return 0

    print("=" * 78)
    print("Behavioral parity: superseded_by")
    print("=" * 78)

    cenario("without superseded_by", False, False, None, {"bloco": True})
    cenario("supersede declared, file absent", True, False, None,
            {"bloco": True})
    cenario("supersede active: block removed", True, True,
            DEV_BEFORE + "\n" + MARCADOR + "\nOLD\n" + MARCADOR + "\n\n" + DEV_AFTER,
            {"bloco": False, "preserva": ["I use pnpm", "Text that the dev wrote"]})
    cenario("supersede active, target without block", True, True, DEV_BEFORE,
            {"bloco": False, "preserva": ["I use pnpm"]})

    print("")
    print("=" * 78)
    print("Behavioral parity: remove")
    print("=" * 78)

    cenario_remove("remove with file present", True)
    cenario_remove("remove with file already absent", False)

    print("")
    print("RESULT: %d OK, %d FAIL" % (_ok, _fail))
    print("PARITY-BEHAVIOR: DONE ok=%d fail=%d" % (_ok, _fail))
    return 1 if _fail else 0


if __name__ == "__main__":
    sys.exit(main())
