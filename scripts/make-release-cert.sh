#!/bin/zsh
# 배포판 전용 자체 서명 코드 서명 인증서(이름: MacPyeon Release)를 만든다. 한 번만.
#
# 배포판을 매번 같은 인증서로 서명해야 macOS가 업데이트 전후를 같은 앱으로 보고
# 손쉬운 사용 권한을 유지한다. 이 인증서(열쇠)를 잃으면 다음 업데이트에서
# 모든 사용자가 권한을 한 번 다시 허용해야 하므로 반드시 백업해 둔다.
#
# 만드는 것:
#   - 로그인 키체인의 인증서와 열쇠 (codesign만 쓰도록 허용)
#   - 백업: ~/Documents/MacPyeon-Release-signing.p12 (암호 걸림)
#   - 백업 암호: 키체인 '암호' 항목 "MacPyeon Release signing backup"
#       꺼내 보기: security find-generic-password -s "MacPyeon Release signing backup" -w
#
# 개인 정보는 들어가지 않는다(이름만 MacPyeon Release).
set -euo pipefail

NAME="MacPyeon Release"
BACKUP="$HOME/Documents/MacPyeon-Release-signing.p12"
SERVICE="MacPyeon Release signing backup"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✓ 인증서가 이미 있어요: $NAME (새로 만들지 않습니다)"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
umask 077

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

# 20년. (만료돼도 이미 서명한 앱의 권한 유지에는 영향이 없지만 넉넉히)
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS=$(openssl rand -base64 24)
openssl pkcs12 -export -legacy -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -passout "pass:$PASS"

security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
security add-generic-password -U -s "$SERVICE" -a macpyeon -w "$PASS" >/dev/null

if [[ -e "$BACKUP" ]]; then
  BACKUP="${BACKUP%.p12}-$(date +%Y%m%d%H%M%S).p12"
fi
cp "$TMP/id.p12" "$BACKUP"
chmod 600 "$BACKUP"

echo "✓ 인증서를 만들었어요: $NAME"
echo "✓ 백업: $BACKUP"
echo "  백업 암호는 키체인 암호 항목 \"$SERVICE\"에 있어요."
echo "  이 파일과 암호를 Mac 밖(비밀번호 관리자 등)에도 보관해 주세요."
