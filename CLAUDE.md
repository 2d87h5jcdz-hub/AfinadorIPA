# Pestana Estúdio — contexto para o Claude

Leia antes de qualquer tarefa neste repositório. Resume as decisões e o histórico das conversas anteriores.

## Usuário e jeito de trabalhar
- Desenvolvedor .NET brasileiro, Rio de Janeiro. Usa **Windows, sem Mac**. **Responda sempre em português do Brasil.**
- Testa no iPhone instalando o `.ipa` gerado pelo CI (LiveContainer/Sideloadly). Manda prints e descreve o que sentiu ao usar.
- Gosta de respostas diretas e de saber o que testar. Quando ele diz "não gera build ainda", junte os pedidos e só compile no fim.
- Prefere economia de tokens: não reler arquivos grandes à toa, não narrar passo a passo.
- App **gratuito, sem anúncios**, para a comunidade; doação opcional via Pix (chave aleatória `63053aa4-cbad-4c78-b92c-8ba3082d83ca`, QR em `docs/pix-qrcode.png`).

## Repositório e ramos
- GitHub `2d87h5jcdz-hub/PestanaEstudio` (antigo `AfinadorIPA`; o remoto local pode ter o nome antigo, o GitHub redireciona).
- `estudio`: ramo de trabalho do **iOS**. `main`: só recebe versões lançadas (fast-forward a partir do `estudio`).
- `android`: app Android (pasta `android/`, Kotlin + Compose + Oboe/C++). Já foi juntado ao `main`/`estudio`; tem `android/NOTAS.md` com as pendências. `android-capturas`: prints do emulador.
- Commits: identidade `Claude <noreply@anthropic.com>`, mensagem em PT-BR terminando com
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (e a linha `Claude-Session` quando houver).
- `[skip ci]` na mensagem evita build (útil só para docs).

## iOS — arquitetura (SwiftUI, iOS 16, Swift 5)
- Projeto gerado por **XcodeGen** (`project.yml`): target `Afinador`, nome exibido "Pestana", bundle `com.afinador.app`. Bridging header `Afinador/Afinador-Bridging-Header.h`. C++20, `-O3`, `NAM_SAMPLE_FLOAT`.
- Abas (`Afinador/RootView.swift`): Afinador (`ContentView.swift` + `TunerEngine.swift`, YIN, ponteiro com mola), Acordes, Metrônomo, Estúdio, Treino. `AboutView.swift`: aviso de boas-vindas (gratuito/doação), abre na 1ª vez e pelo ⓘ do Afinador. `statusBarCover()` em todas as abas.
- **Estúdio** (`Afinador/Studio/`):
  - `StudioModels.swift`: contrato (`StudioProject/Track/Clip`, `EffectSettings` com decodificação tolerante, presets, `DriveStyle`, `ModulationType`; `StudioTrack.pitch` e `effectsOn` = botão FX).
  - `StudioEngine.swift` (@MainActor): AVAudioEngine, gravação com punch-in, faixa armada, entrada/ganho, jobs de afinação automática (`pitchProgress`).
  - `StudioAudioNodes.swift`: cadeia gate → EQ → compressor → drive → **guitarra (AU próprio)** → delay → reverb; pistas de clips.
  - `StudioAudioOffline.swift`: exportação (manual rendering). `StudioEngineSupport.swift`: storage, waveforms (`.peaks`).
  - Linha do tempo: `StudioTimelineView/Lane/Ruler/TrackSheet.swift`. A régua usa o espaço de coordenadas da rolagem; a rolagem automática na borda mexe direto na `UIScrollView` (achada por `StudioScrollViewFinder`) com `CADisplayLink` em `.common`. Isso foi o que funcionou; `scrollTo` + `Timer` padrão não funcionam com o dedo na tela.
  - `StudioPitchCorrection.swift` + `StudioPitchPanel.swift`: afinação automática **offline** (YIN → nota por segmento → TD-PSOLA), gera `<arquivo>.tune-<assinatura>.caf`; o original nunca muda.
  - `StudioAmps.swift`: modelos `.nam` importados em Documentos/Amps.
- **Bloco Guitarra** (`Afinador/GuitarFX/`): `GuitarFXCore.cpp/.h` (C++ puro: NAM + chorus/flanger/phaser/tremolo) e `PestanaGuitarAU.mm` (AUAudioUnit v3 registrado no app). Código de terceiros em `Vendor/` (NeuralAmpModelerCore MIT, Eigen 3.4 MPL2, nlohmann/json).
- **Treino** (`Afinador/Practice/`): player com tom/velocidade/A-B e separação Demucs (htdemucs_6s) via Core ML (`DemucsSeparator.swift`, STFT no app). Modelo baixado no CI da Release `demucs-model`.

## Build, CI e lançamento
- `.github/workflows/build.yml` ("Gerar IPA", macOS): roda em push no `main`/`estudio`; artifact `PestanaEstudio-ipa`. Erros e avisos viram anotações: leia com
  `gh api repos/2d87h5jcdz-hub/PestanaEstudio/check-runs/<job_id>/annotations` (job id via `gh run view <run> --json jobs`). Logs completos e artifacts **não** baixam pelo proxy.
- **Release iOS automática:** quando o `main` recebe um `MARKETING_VERSION` novo em `project.yml`, o build cria a Release `v<versão>` com o `.ipa`, usando `docs/release-notes/v<versão>.md`. Para lançar: subir `MARKETING_VERSION` **e** `CURRENT_PROJECT_VERSION`, escrever as notas, fast-forward do `estudio` no `main`.
- `altstore-source.yml`: depois de cada build do `main`, gera `altstore/source.json` a partir das Releases (`altstore/build_source.py` + `altstore/app.json`) e anexa na Release mais recente. URL da fonte (AltStore/SideStore): `https://github.com/2d87h5jcdz-hub/PestanaEstudio/releases/latest/download/source.json`.
- Outros: `android.yml` (APK `PestanaEstudio-apk` + teste no emulador), `demucs-model.yml` / `demucs-onnx.yml` (conversão do modelo), `pix-qrcode.yml`.
- Versões lançadas: 1.0.0, 1.1.0 (afinação automática, NAM, efeitos, FX), 1.1.1 (aviso de boas-vindas + licença nova), **1.2.0** (afinador com modo Livre cromático).

## Limitações do ambiente (não perca tempo)
- Pelo proxy, **não dá para criar tags, refs nem Releases** pela API nem por `git push` de tag. Por isso a Release é publicada pelo próprio workflow.
- GraphQL bloqueado: use `gh api repos/...` (REST). Se o repo não estiver acessível, use `add_repo` (owner `2d87h5jcdz-hub`, repo `PestanaEstudio`, access push).
- `git clone` do GitHub funciona; GitLab, pip e npm não (sem rede). Há `clang++`, `cmake`, `python3` com numpy/scipy. **Não há Swift/Xcode**: valide o Swift pelo CI. Teste DSP em Python/C++ localmente antes.
- Swift: só APIs do iOS 16; quebre views grandes em propriedades (evita "unable to type-check"); prefira tipos explícitos.

## Licença e distribuição
- Código sob **PolyForm Noncommercial 1.0.0** (`LICENSE`, com "Required Notice"); `Vendor/` mantém as licenças originais (`THIRD-PARTY-NOTICES.md`). Nome e logo fora da licença. Sugestão pendente: registrar a marca no INPI se o app crescer.
- README tem tutorial com prints (`docs/prints/`), instalação (Sideloadly, SideStore/AltStore com a fonte), seção Apoie com Pix/QR.

## Ideias e pendências conhecidas
- Página de download (GitHub Pages) com botões iPhone/Android: combinada para depois que o Android estabilizar.
- NAM: simulação de caixa (IR) para capturas "amp only"; avaliar desempenho ao vivo no iPhone.
- App Store: exigiria conta de desenvolvedor (US$ 99/ano) e tirar Pix de dentro do app.
- Android: ver `android/NOTAS.md`.
