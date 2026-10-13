# MacStroke 本地签名证书

`build_app.sh` 使用登录钥匙串里的自签名身份 **"MacStroke Self Signed"** 签名。
好处：designated requirement 是 `identifier "net.mtjo.MacStroke" and certificate root = H(33BFE…)`，
认的是这把证书而不是 cdhash —— 所以重新编译（cdhash 必然变）之后重装或自动更新，
辅助功能（TCC）授权仍然有效。回退成 ad-hoc 签名就会丢掉这条 DR，用户要重勾一次。

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

## 发版流水线里的用法

`.github/workflows/release.yml` 在 GitHub 的 macos-14 runner 上重建同一个身份，材料就是上面
那份备份：`macstroke-signing-cert.pem` 进 secret `CODESIGN_CERT_PEM`，私钥转成
traditional DER 再 base64 成一行进 `CODESIGN_KEY_DER_B64`（`openssl rsa -outform der -traditional`，
`security import` 只认这种编码）。导进临时钥匙串后，只有 `find-identity -v` 认不出这个身份时，
流水线才用 `sudo -n security add-trusted-cert -d …` 补写系统信任域 —— 不带 sudo 的那条命令走
GUI 授权，无界面环境会永久挂起（dry-run 实测踩过）。
