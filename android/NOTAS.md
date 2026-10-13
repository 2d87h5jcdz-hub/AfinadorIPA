# Android — estado e pendências

Última sessão: out/2026. Ramo de trabalho: `android` (CI: `.github/workflows/android.yml`,
gera o APK e roda o teste no emulador; prints no ramo `android-capturas`).

## Pronto
- Afinador, Acordes, Metrônomo, Treino (tom/velocidade/A-B, separação HTDemucs em ONNX num
  processo próprio `:ia`, modelo `HTDemucs-v2.onnx` da release `demucs-model`, pico ~1 GB).

## Em desenvolvimento: Estúdio
- Telas, linha do tempo, efeitos, amp NAM, afinação automática e exportação funcionam.
- **Problema aberto:** a gravação pelo microfone (celular ou fone) chega estourada/distorcida
  num aparelho real (voz ~15–20 dB alta demais, ~30% das amostras no limite), mesmo sem efeito
  e com ganho 0 dB. No iPhone a mesma gravação fica perfeita.
- Já tentado (sem resolver no aparelho do usuário): fila na entrada do Oboe, preset Camcorder
  (antes Unprocessed) para microfones internos, limitador suave, compressor mais leve,
  aviso de estouro e botão "Ajustar nível".
- Próximas hipóteses: gravar com `AudioRecord` (fonte MIC/CAMCORDER) em vez do Oboe para
  comparar; testar `InputPreset::VoicePerformance`/`Generic`; registrar o pico bruto da
  entrada antes do ganho; conferir conversão de formato (I16→float) e `setDeviceId` no aparelho.
