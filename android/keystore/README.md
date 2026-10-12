# Chave de assinatura do APK

`pestana-release.jks` assina o APK gerado pelo GitHub Actions. Como o app é gratuito e de
código aberto, a chave fica no próprio repositório: assim todo APK novo instala **por cima**
do anterior (mesma assinatura) sem perder dados.

- Arquivo: `pestana-release.jks` (PKCS12)
- Alias: `pestana`
- Senha do arquivo e da chave: `pestana123`

Se um dia o app for para a Play Store, gere uma chave nova e guarde-a fora do repositório
(nos *Secrets* do GitHub). As variáveis `PESTANA_KEYSTORE`, `PESTANA_KEYSTORE_PASSWORD`,
`PESTANA_KEY_ALIAS` e `PESTANA_KEY_PASSWORD` substituem os valores acima sem mexer no código.
