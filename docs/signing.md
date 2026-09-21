# MacStroke 本地签名证书

`build_app.sh` 使用登录钥匙串里的自签名身份 **"MacStroke Self Signed"** 签名。
好处：cdhash 每次构建保持一致 → 重装后辅助功能（TCC）授权不会被重置。

- 证书/私钥备份：`~/Library/Application Support/MacStrokeDev/`
  （`macstroke-signing-cert.pem`、`form_rsa.der`、`macstroke-signing.p12`），有效期 10 年（至 2036-09）。
- 身份指纹：`33BFE3CCB6027293E257EA62F131BE834147719E`

## 新机器 / 钥匙串丢失后重建

注意：macOS 的 `security import` 只认 **DER 编码的 RSA (SEC1) 私钥**，
OpenSSL 3 的 PEM 与 pkcs12 导出都可能报 `Unknown format` / `MAC verification failed`，
按下面步骤走即可：

```bash
DIR="$HOME/Library/Application Support/MacStrokeDev"
openssl req -x509 -newkey rsa:2048 -keyout $DIR/key.pem -out $DIR/cert.pem \
  -days 3650 -nodes -subj "/CN=MacStroke Self Signed/O=net.mtjo" -extensions v3_ext \
  -config <(printf '[req]\ndistinguished_name=dn\nx509_extensions=v3_ext\nprompt=no\n[dn]\nCN=MacStroke Self Signed\n[v3_ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
openssl rsa -in $DIR/key.pem -out $DIR/key.der -outform der -traditional
security import $DIR/cert.pem -k ~/Library/Keychains/login.keychain-db -f openssl -A
security import $DIR/key.der  -k ~/Library/Keychains/login.keychain-db -f openssl -A
security add-trusted-cert -d -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db $DIR/cert.pem
security find-identity -v -p codesigning   # 应看到 "MacStroke Self Signed"
```

若身份缺失，`build_app.sh` 会打印警告并回退为 ad-hoc 签名（不影响构建，但 TCC 会重置）。
