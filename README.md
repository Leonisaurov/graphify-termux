# Graphify para Termux (port aarch64)

Port de [Graphify](https://github.com/Graphify-Labs/graphify) (`graphifyy` en
PyPI) para Termux/Android aarch64. Convierte una codebase en un grafo de
conocimiento consultable (compresión de contexto para asistentes de IA) usando
tree-sitter AST local, sin LLM para la parte de código.

## El problema

- `graphifyy` depende del binding `tree-sitter` + **26 grammars PyPI**.
- pip en Termux **solo acepta wheels con tag de plataforma `android_*`**
  (nunca manylinux) y no hay wheels android en PyPI → todo se compila desde
  sdist.
- Los sdists de las grammars son C puro (parser.c ya generado) → compilan con
  clang, pero compilar 27 paquetes en el dispositivo es lento y arriesgado
  (throttling térmico, ABI mismatches).

## La solución: wheels android vía GitHub Actions

El workflow `.github/workflows/build-wheels.yml` compila todo **dentro de un
contenedor Termux real** (`termux/termux-docker`) en un runner arm64 nativo:

1. `pkg update` + `pkg upgrade` (el python del contenedor debe coincidir con el
   del dispositivo para que los tags de los wheels coincidan: cp314 android).
2. `tree-sitter` core (**0.26.0**, ABI 15 — fuera del rango `<0.26` de
   graphify a propósito: acepta las grammars modernas que emiten
   `TSFieldMapSlice`) y `rapidfuzz`: `pip wheel --no-binary :all:` normal.
3. **Grammars**: los bindings abi3 de PyPI son frágiles en Android (sus sdists
   no traen `tree_sitter/parser.h` → falla el build desde source; y los que
   compilan con scanner externo no exportan el símbolo con
   `-fvisibility=hidden` → `dlopen failed` en runtime). Por eso cada grammar se
   compila como **`.so` puro** con clang (`parser.c` + `scanner.c`, headers de
   master del repo tree-sitter) y se empaqueta en un **wheel shim**
   `tree_sitter_<lang>/` que expone `language()` + `language_<símbolo>()` (la
   API exacta que graphify espera, incl. `language_typescript()`/`language_tsx()`)
   cargando el `.so` con ctypes. El sdist de `tree-sitter-typescript` está
   incompleto (sin `common/scanner.h`): se compila desde el tarball del repo
   de GitHub.
4. Test de runtime de cada grammar (`scripts/test_grammars.py`): import →
   `Language()` (detecta ABI mismatch core/grammar) → parse de un snippet.
   Los wheels que fallan se mueven a `failed/` y no entran al release.
5. Sube los wheels como artefacto; con tag `v*` (o manual + create_release)
   publica un GitHub Release con los `.whl`.

Las versiones del manifest se resuelven contra los rangos de `graphifyy`
(`scripts/resolve_versions.py`), eligiendo la última versión en rango que
tenga sdist (php baja a 0.23.11: 0.24.1 no publica sdist).

**Versiones clave:** tree-sitter core 0.26.0 (ABI 15, acepta grammars ABI
14 y 15; graphify se instala con `--no-deps`), grammars de sus rangos,
rapidfuzz 3.14.5.

## Instalación en el dispositivo (sin compilar nada)

```bash
# requisitos previos (ya presentes normalmente):
#   pkg install python python-numpy gh
bash scripts/install_device.sh          # usa el ultimo release de GitHub
# o para probar wheels locales:
bash scripts/install_device.sh --local /ruta/a/wheels
```

El script:
1. Descarga los `.whl` del release (`gh release download` o API+curl).
2. Crea `~/graphify-venv` con `--system-site-packages` (numpy 2.4 y networkx
   vienen del paquete nativo `python-numpy` — nunca wheels manylinux).
3. Instala los wheels `--no-deps` + `graphifyy` desde PyPI (sus deps ya están
   satisfechas: numpy/networkx del sistema, el resto de los wheels).
4. Smoke test: `graphify --version` + lista de grammars importables.

## Uso

```bash
~/graphify-venv/bin/graphify build ./mi-repo     # build inicial (lento, una vez)
~/graphify-venv/bin/graphify query "como funciona X"
~/graphify-venv/bin/graphify path "A" "B"
~/graphify-venv/bin/graphify explain "Simbolo"
~/graphify-venv/bin/graphify install             # registra el skill en Hermes
```

Env `GRAPHIFY_MAX_WORKERS=1-2` en Termux para no saturar la CPU en el build
inicial.

## Limitaciones

- **Grammars que fallen el test ABI** (si alguna) se excluyen del release;
  graphify captura `ImportError` por extractor y simplemente omite ese
  lenguaje (sin romper el CLI).
- Sin API key de LLM, la extracción semántica de docs/PDFs queda deshabilitada;
  el grafo de código es 100% estructural (AST), local y determinista.
- El build inicial de un repo grande tarda varios minutos en el dispositivo;
  los queries posteriores son baratos (el valor del port).
- Extras opcionales de graphify (mcp, neo4j, video, office...) no se instalan
  por defecto.

## Archivos

| Archivo | Rol |
|---|---|
| `.github/workflows/build-wheels.yml` | CI: compila y publica wheels android |
| `scripts/build_wheels.sh` | Corre dentro del contenedor Termux (CI) |
| `scripts/test_grammars.py` | Test ABI/runtime de cada grammar |
| `scripts/grammar_manifest.txt` | paquete==version a compilar |
| `scripts/resolve_versions.py` | Resuelve versiones contra los rangos de graphifyy |
| `scripts/install_device.sh` | Instalador en el dispositivo (sin compilar) |
