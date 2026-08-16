#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Construye wheels para Termux/Android (bionic aarch64) de:
#   tree-sitter core + grammars + rapidfuzz  (ver grammar_manifest.txt)
#
# Corre DENTRO del contenedor termux/termux-docker:latest (uid 1000), con el
# checkout montado en /workspace. NO corre en el dispositivo.
#
# Salida:
#   /workspace/wheels/  -> wheels que pasaron el test de runtime
#   /workspace/failed/  -> wheels que fallaron (build o ABI), con reporte
# =============================================================================
set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
SCRIPTS="$WORKSPACE/scripts"
WHEELS="$WORKSPACE/wheels"
FAILED="$WORKSPACE/failed"
MANIFEST="$SCRIPTS/grammar_manifest.txt"
mkdir -p "$WHEELS" "$FAILED"

echo "== [1/5] pkg update + upgrade (python debe coincidir con el dispositivo) =="
for i in 1 2 3; do
  pkg update -y && break || { echo "retry pkg update ($i)"; sleep 5; }
done
# upgrade con tolerancia: si un paquete pin falla, seguimos (los .deb viejos
# del bootstrap pueden dar conflictos transitorios; lo que importa es python)
pkg upgrade -y || echo "WARN: pkg upgrade fallo parcialmente, continuando"

echo "== [2/5] toolchain + python extras =="
pkg install -y clang make cmake ninja python-numpy

echo "== [3/5] pip base =="
python -m pip install --upgrade pip setuptools wheel

echo "== [4/5] compilar wheels (uno por uno, tolerante a fallos) =="
# NOTA: el contenedor termux-docker no tiene directorio temporal global
# escribible — usar $HOME (el home del uid 1000) para logs y venv de test.
LOG="$HOME/build.log"
while IFS= read -r spec; do
  # saltar lineas vacias y comentarios
  if [ -z "$spec" ] || [ "${spec#\#}" != "$spec" ]; then
    continue
  fi
  name="${spec%%==*}"
  echo "--- build: $spec ---"
  if python -m pip wheel --no-deps --no-binary :all: "$spec" -w "$WHEELS" --progress-bar off >"$LOG" 2>&1; then
    echo "OK  build: $spec"
  else
    echo "FAIL build: $spec"
    echo "=== $spec ===" >> "$FAILED/build-failed.txt"
    tail -25 "$LOG" >> "$FAILED/build-failed.txt"
  fi
done < "$MANIFEST"

echo "== [5/5] test de runtime (import + Language + parse) =="
# solo si hay al menos un wheel del core
if ls "$WHEELS"/tree_sitter-*.whl >/dev/null 2>&1; then
  python -m venv "$HOME/testvenv" --system-site-packages
  # instalar TODOS los wheels generados (sin deps: ya estan todos aqui)
  "$HOME/testvenv/bin/pip" install --no-index --no-deps --find-links "$WHEELS" \
    "$WHEELS"/*.whl >"$HOME/pip-test-install.log" 2>&1 \
    || { echo "FALLO instalando wheels en venv de test"; tail -20 "$HOME/pip-test-install.log"; exit 1; }
  # test_grammars.py mueve los wheels que fallan a FAILED/
  "$HOME/testvenv/bin/python" "$SCRIPTS/test_grammars.py" "$WHEELS" "$FAILED" \
    || echo "WARN: test_grammars.py termino con codigo != 0 (ver failed/)"
else
  echo "ERROR: no se construyo el wheel del core tree-sitter"
  exit 1
fi

echo
echo "== RESUMEN =="
echo "Wheels OK:   $(ls "$WHEELS"/*.whl 2>/dev/null | wc -l)"
echo "Wheels FAIL: $(ls "$FAILED"/*.whl 2>/dev/null | wc -l)"
ls "$WHEELS" 2>/dev/null
