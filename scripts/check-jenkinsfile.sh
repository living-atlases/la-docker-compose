#!/usr/bin/env bash
#
# check-jenkinsfile.sh — parse the Jenkinsfile as Groovy.
#
# The Jenkinsfile is ~80 KB of declarative pipeline with deeply nested triple-quoted shell
# blocks. A stray brace or quote in ONE stage does not break that stage, it breaks the whole
# pipeline before any of it runs, and the only feedback is a failed build. This catches that
# locally in a second.
#
# Parse only: it stops at the CONVERSION phase, so it validates SYNTAX and nothing else. It
# cannot see whether a step exists, whether a variable is defined, or whether the declarative
# structure is legal -- for that you need Jenkins' own `declarative-linter`. It still catches
# the class of mistake that is easy to make and expensive to discover.
#
# Needs a Groovy jar and a JDK it supports (groovy 3.x does not run on Java 21+; the JDK
# picked below is whatever `java` resolves to unless JAVA_CMD says otherwise). Skips with a
# warning rather than failing when neither is available, so it never blocks anyone.
set -euo pipefail

TARGET="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Jenkinsfile}"
[[ -f "$TARGET" ]] || { echo "no such file: $TARGET" >&2; exit 1; }

find_groovy_jar() {
  local j
  for j in "${GROOVY_JAR:-}" \
           "$HOME/.m2/repository/org/codehaus/groovy/groovy/3.0.3/groovy-3.0.3.jar" \
           "$HOME/.sdkman/candidates/groovy/current/lib/groovy-"*.jar; do
    [[ -n "$j" && -f "$j" ]] && { printf '%s\n' "$j"; return 0; }
  done
  # last resort: anything that looks like one
  find "$HOME/.m2" "$HOME/.sdkman" -name 'groovy-[0-9]*.jar' 2>/dev/null | head -1
}

JAR="$(find_groovy_jar)"
if [[ -z "$JAR" ]]; then
  echo "WARNING: no groovy jar found; skipping the Jenkinsfile parse check." >&2
  echo "         Install one with 'sdk install groovy', or set GROOVY_JAR." >&2
  exit 0
fi

# Groovy 3 cannot read class files from Java 21+ (major version 65). Prefer an older JDK
# when one is around rather than reporting a toolchain problem as a parse failure.
JAVA_CMD="${JAVA_CMD:-}"
if [[ -z "$JAVA_CMD" ]]; then
  for c in "$HOME/.sdkman/candidates/java/11"*/bin/java "$HOME/.sdkman/candidates/java/17"*/bin/java java; do
    [[ -x "$c" || "$c" == java ]] && { JAVA_CMD="$c"; break; }
  done
fi
command -v "$JAVA_CMD" >/dev/null 2>&1 || [[ -x "$JAVA_CMD" ]] || {
  echo "WARNING: no java found; skipping the Jenkinsfile parse check." >&2; exit 0; }

SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
cat > "$SRC/ParseCheck.groovy" <<'GROOVY'
import org.codehaus.groovy.control.CompilationUnit
import org.codehaus.groovy.control.Phases
def f = new File(args[0])
def cu = new CompilationUnit()
cu.addSource(f)
cu.compile(Phases.CONVERSION)
println "PARSE OK: ${f}"
GROOVY

if out=$("$JAVA_CMD" -cp "$JAR" groovy.ui.GroovyMain "$SRC/ParseCheck.groovy" "$TARGET" 2>&1); then
  printf '%s\n' "$out"
else
  echo "PARSE FAILED: $TARGET" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
