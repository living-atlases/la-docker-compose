#!/usr/bin/env bash
# Run on a deployed host by the Jenkins `CA distrust check` stage:
#   ssh <host> bash -s < scripts/ca-distrust-ci-collect.sh
#
# Checks that no running container still trusts a CA root distrusted after a
# compromise. First case: eMudhra (2026-10-17), whose intermediates' private keys
# can be derived from their public certificates; the distro fix removes
# "emSign ECC Root CA - G3" and "AAA Certificate Services". Roots are matched by
# SHA-256, never by name: emSign C1/C3/G1 stay in the fixed packages.
#
# Per container and trust store, one tab-separated line on stdout:
#   <container> <image> <store> <OK|TRUSTS|ERR> <detail>
# Stores: the system bundle (read with `cat`, or with `docker cp` when the image has
# no shell), the JVM cacerts (keytool inside the container), Node's built-in roots and
# certifi's bundle. A store an image does not have prints nothing. Nothing else on stdout; always exits 0, the verdict is
# the summary's job.
#
# DOCKER overrides the docker command (tests only).
set -u

BAD="86A1ECBA089C4A8D3BBE2734C612BA341D813E043CF9E8A862CD5C57A36BBE6B D7A7A0FB5D7E2731D771E9484EBCDEF71D5F0C3E0A2948782BC83EE0EA699EF4"
if [ -n "${DOCKER:-}" ]; then
  read -r -a docker <<<"$DOCKER"
elif [ "$(id -u)" = 0 ]; then
  docker=(docker)
else
  docker=(sudo docker)
fi
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT

# Short fingerprints of the distrusted roots found in the fingerprint list on stdin.
bad_of() {
  tr -d ':\r' | while read -r fp; do
    case " $BAD " in *" $fp "*) printf '%s ' "${fp:0:8}" ;; esac
  done
}
pem_fps() { # PEM bundle -> one SHA-256 per certificate
  rm -f "$w"/c*.pem
  awk -v d="$w" '/BEGIN CERT/{n++} n{print > (d "/c" n ".pem")}' "$1"
  for f in "$w"/c*.pem; do
    [ -f "$f" ] && openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//'
  done
}
line() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }
grab() { # container path -> the bundle in $w/bundle, 0 when it got one
  # `exec cat` first, it is cheapest. Then `docker cp`, which runs nothing inside the
  # container: a distroless image ships the bundle but has no shell, so `cat` fails on
  # an image whose trust store is perfectly readable from outside. That read as
  # "unreadable" for la_gatus_service, the one container whose whole job is outbound
  # HTTPS -- the check was blind exactly where a bad root would be used. -L: on alpine
  # /etc/ssl/cert.pem is a symlink, and cp without it copies the link, not the bundle.
  rm -f "$w/b1"
  if "${docker[@]}" exec "$1" cat "$2" >"$w/b1" 2>/dev/null </dev/null && [ -s "$w/b1" ]; then
    mv "$w/b1" "$w/bundle"; return 0
  fi
  "${docker[@]}" cp -L "$1:$2" - 2>/dev/null | tar -xOf - >"$w/b1" 2>/dev/null
  [ -s "$w/b1" ] || return 1
  mv "$w/b1" "$w/bundle"
}
verdict() { # container image store bad-list
  if [ -n "$4" ]; then line "$1" "$2" "$3" TRUSTS "roots: $4"; else line "$1" "$2" "$3" OK "-"; fi
}

"${docker[@]}" ps --format '{{.Names}}\t{{.Image}}' >"$w/ctrs" 2>/dev/null || exit 0
while IFS=$'\t' read -r name image; do
  got=""
  for b in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    if grab "$name" "$b"; then
      verdict "$name" "$image" "$b" "$(pem_fps "$w/bundle" | bad_of)"
      got=1
      break
    fi
  done
  [ -n "$got" ] || line "$name" "$image" system ERR "no CA bundle at any known path"

  # Java: keytool inside the container, from the JVM that would run.
  if "${docker[@]}" exec "$name" sh -c '
      j=$(command -v java 2>/dev/null) || exit 3
      j=$(readlink -f "$j"); h=$(dirname "$(dirname "$j")")
      for c in "$h/lib/security/cacerts" "$h/jre/lib/security/cacerts"; do
        [ -e "$c" ] || continue
        k="$(dirname "$j")/keytool"; [ -x "$k" ] || k=keytool
        LC_ALL=C "$k" -list -v -keystore "$c" -storepass changeit 2>/dev/null
        exit 0
      done
      exit 4' >"$w/kt" 2>/dev/null </dev/null; then
    if grep -q 'SHA256:' "$w/kt"; then
      verdict "$name" "$image" jvm "$(sed -n 's/.*SHA256: *//p' "$w/kt" | bad_of)"
    else
      line "$name" "$image" jvm ERR "keytool printed no certificates"
    fi
  fi

  if "${docker[@]}" exec "$name" sh -c 'command -v node' >/dev/null 2>&1 </dev/null; then
    "${docker[@]}" exec "$name" node -e 'console.log(require("tls").rootCertificates.join("\n"))' \
      >"$w/node.pem" 2>/dev/null </dev/null
    if [ -s "$w/node.pem" ]; then
      verdict "$name" "$image" node "$(pem_fps "$w/node.pem" | bad_of)"
    else
      line "$name" "$image" node ERR "tls.rootCertificates empty"
    fi
  fi

  # Python: certifi ships its OWN bundle and requests/boto3 verify against that, not
  # against /etc/ssl/certs, so an image can have a clean system bundle and a stale
  # certifi. The airflow base had exactly that: ca-certificates upgraded to a fixed
  # version, certifi 2024.08.30 still carrying both eMudhra roots. No certifi installed
  # prints nothing, as an absent JVM or Node does.
  for py in python python3; do
    "${docker[@]}" exec "$name" sh -c "command -v $py" >/dev/null 2>&1 </dev/null || continue
    "${docker[@]}" exec "$name" "$py" -c \
      'import certifi,sys; sys.stdout.write(open(certifi.where()).read())' \
      >"$w/py.pem" 2>/dev/null </dev/null
    [ -s "$w/py.pem" ] || break
    verdict "$name" "$image" certifi "$(pem_fps "$w/py.pem" | bad_of)"
    break
  done
done <"$w/ctrs"
exit 0
