#!/bin/zsh
# 이 Mac에서만 쓰는 자체 서명 코드 서명 인증서를 만든다. (선택 사항, 직접 빌드하는 사람용)
# 개인 정보는 들어가지 않고(이름: MacPyeon Local Signing) 이 Mac 키체인에만 저장된다.
# 배포판(scripts/release.sh)은 이 인증서를 쓰지 않고 항상 임시 서명한다.
# 임시 서명(ad-hoc)은 빌드할 때마다 서명이 바뀌어 손쉬운 사용 권한이 풀리지만,
# 이 인증서로 서명하면 서명이 계속 같아서 권한을 한 번만 허용하면 된다.
set -euo pipefail

NAME="MacPyeon Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✓ 인증서가 이미 있어요: $NAME"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "✓ 인증서를 만들었어요: $NAME"
