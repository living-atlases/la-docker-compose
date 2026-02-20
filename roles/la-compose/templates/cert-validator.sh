#!/bin/sh
set -u

SSL_CERT_DIR="${SSL_CERT_DIR}"
SSL_CERT_FILE="${SSL_CERT_FILE}"
SSL_KEY_FILE="${SSL_KEY_FILE}"

CERT_PATH="$SSL_CERT_DIR/$SSL_CERT_FILE"
KEY_PATH="$SSL_CERT_DIR/$SSL_KEY_FILE"

echo "[*] Using SSL configuration:"
echo "    SSL_CERT_DIR:  $SSL_CERT_DIR"
echo "    SSL_CERT_FILE: $SSL_CERT_FILE"
echo "    SSL_KEY_FILE:  $SSL_KEY_FILE"
echo ""
echo "[*] Full paths:"
echo "    CERT_PATH: $CERT_PATH"
echo "    KEY_PATH:  $KEY_PATH"
echo ""
echo "[*] Listing directory contents:"
ls -lah "$SSL_CERT_DIR" 2>/dev/null || echo "    (Directory not found or not readable)"
echo ""

ERRORS=0
WARNINGS=0
CERT_VALID=0
KEY_VALID=0

if ! command -v openssl >/dev/null 2>&1; then
  echo "[ERROR] openssl not found in this container"
  ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -eq 0 ]; then
  if [ ! -f "$CERT_PATH" ]; then
    echo "[ERROR] Certificate not found at $CERT_PATH"
    ERRORS=$((ERRORS + 1))
  else
    echo "[OK] Certificate found: $CERT_PATH"

    # Check if file is empty
    if [ ! -s "$CERT_PATH" ]; then
      echo "[ERROR] Certificate file is EMPTY (0 bytes)"
      ERRORS=$((ERRORS + 1))
    else
      FILE_SIZE=$(wc -c < "$CERT_PATH" 2>/dev/null || echo "0")
      echo "[OK] Certificate file size: $FILE_SIZE bytes"
    fi

    if ! openssl x509 -in "$CERT_PATH" -noout >/dev/null 2>&1; then
      echo "[ERROR] Certificate is not valid PEM/X509"
      ERRORS=$((ERRORS + 1))
    else
      CERT_VALID=1
      echo "[OK] Certificate PEM/X509 format valid"

      if ! openssl x509 -in "$CERT_PATH" -noout -checkend 0 >/dev/null 2>&1; then
        echo "[ERROR] Certificate is expired"
        ERRORS=$((ERRORS + 1))
      else
        EXPIRATION="$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)"
        echo "[OK] Certificate not expired (notAfter: $EXPIRATION)"

        if ! openssl x509 -in "$CERT_PATH" -noout -checkend 2592000 >/dev/null 2>&1; then
          echo "[WARN] Certificate expires within 30 days (notAfter: $EXPIRATION)"
          WARNINGS=$((WARNINGS + 1))
        fi
      fi
    fi
  fi

  if [ ! -f "$KEY_PATH" ]; then
    echo "[ERROR] Private key not found at $KEY_PATH"
    ERRORS=$((ERRORS + 1))
  else
    echo "[OK] Private key found: $KEY_PATH"

    # Check if file is empty
    if [ ! -s "$KEY_PATH" ]; then
      echo "[ERROR] Private key file is EMPTY (0 bytes)"
      ERRORS=$((ERRORS + 1))
    else
      FILE_SIZE=$(wc -c < "$KEY_PATH" 2>/dev/null || echo "0")
      echo "[OK] Private key file size: $FILE_SIZE bytes"
    fi

    if [ ! -r "$KEY_PATH" ]; then
      echo "[ERROR] Private key is not readable - check permissions"
      ERRORS=$((ERRORS + 1))
    else
      echo "[OK] Private key is readable"
    fi

    if ! openssl pkey -in "$KEY_PATH" -noout >/dev/null 2>&1; then
      echo "[ERROR] Private key is not a valid PEM private key"
      if [ $CERT_VALID -eq 1 ]; then
        echo "       Possible: cert/key variables swapped, or key is encrypted/invalid"
      fi
      ERRORS=$((ERRORS + 1))
    else
      KEY_VALID=1
      echo "[OK] Private key PEM format valid"
    fi
  fi

  if [ $CERT_VALID -eq 1 ] && [ $KEY_VALID -eq 1 ]; then
    CERT_PUB_FP="$(openssl x509 -in "$CERT_PATH" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')"
    KEY_PUB_FP="$(openssl pkey -in "$KEY_PATH" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $2}')"

    if [ -z "${CERT_PUB_FP:-}" ] || [ -z "${KEY_PUB_FP:-}" ]; then
      echo "[ERROR] Could not compute public key fingerprints to compare cert and key"
      ERRORS=$((ERRORS + 1))
    elif [ "$CERT_PUB_FP" != "$KEY_PUB_FP" ]; then
      echo "[ERROR] Certificate and private key do not match"
      ERRORS=$((ERRORS + 1))
    else
      echo "[OK] Certificate and private key match"
    fi
  fi
fi

echo ""
echo "================================"
if [ $ERRORS -eq 0 ]; then
  if [ $WARNINGS -gt 0 ]; then
    echo "[OK] Checks passed with $WARNINGS warning(s)"
  else
    echo "[OK] All checks passed"
  fi
  exit 0
else
  if [ $WARNINGS -gt 0 ]; then
    echo "[ERROR] Checks failed with $ERRORS error(s) and $WARNINGS warning(s)"
  else
    echo "[ERROR] Checks failed with $ERRORS error(s)"
  fi
  echo ""
  echo "SOLUTIONS:"
  echo "1. Ensure cert/key files exist at the mounted path"
  echo "2. Check SSL_CERT_FILE and SSL_KEY_FILE point to correct files"
  echo "3. Verify private key is a valid PEM and not corrupted"
  exit 1
fi