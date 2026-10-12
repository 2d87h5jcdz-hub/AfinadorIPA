# Pestana Estúdio 🎸

App gratuito para iPhone, **sem anúncios**, para quem toca: afinador, acordes, metrônomo, um **estúdio de gravação em camadas** e um **modo treino** com separação de instrumentos por IA, que roda no próprio celular.

<p align="center"><img src="docs/prints/00-capa.jpg" width="820"></p>

## 💛 Apoie o projeto

**O Pestana Estúdio é e sempre será gratuito.**

Se o app te ajudou e você tiver condições, pode apoiar com uma doação de qualquer valor via Pix:

**Chave Pix (aleatória):** `63053aa4-cbad-4c78-b92c-8ba3082d83ca`

<img src="docs/pix-qrcode.png" alt="QR Code do Pix" width="220">

<details>
<summary>Pix copia e cola</summary>

```
00020126580014br.gov.bcb.pix013663053aa4-cbad-4c78-b92c-8ba3082d83ca5204000053039865802BR5915PESTANA ESTUDIO6014RIO DE JANEIRO62070503***63044F71
```

</details>

A doação é voluntária e não dá direito a recursos extras nem a suporte. É só um incentivo para eu continuar desenvolvendo o app e novos projetos. Mesmo com ajuda de IA, existem custos, como as assinaturas das ferramentas. Obrigado!

---

## Sumário

- [Instalação](#instalação)
- [Afinador](#afinador)
- [Acordes](#acordes)
- [Metrônomo](#metrônomo)
- [Estúdio](#estúdio)
- [Treino](#treino)
- [Usando na horizontal](#usando-na-horizontal)
- [Perguntas frequentes](#perguntas-frequentes)

---

## Instalação

O app não está na App Store. Ele é distribuído como arquivo **.ipa**, que você instala assinando com o seu próprio Apple ID.

1. Baixe o **PestanaEstudio.ipa** mais recente em [**Releases**](../../releases).
2. Instale com uma destas ferramentas:
   - **[Sideloadly](https://sideloadly.io/)** (Windows ou Mac): conecte o iPhone no cabo, arraste o .ipa, informe seu Apple ID e clique em *Start*.
   - **LiveContainer** ou **AltStore**: abra o .ipa por eles.
3. Na primeira vez, se o iPhone pedir, vá em **Ajustes › Geral › VPN e Gerenciamento de Dispositivos** e confie no seu Apple ID.
4. Com Apple ID gratuito, a assinatura vale **7 dias**. Depois disso é só reinstalar por cima: **suas músicas e gravações não se perdem**.

> Se o app pedir acesso ao microfone, permita. Ele é usado para afinar e gravar. Nada sai do seu iPhone sem você compartilhar.

---

## Afinador

<img src="docs/prints/01-afinador.jpg" width="260">

- Toque uma corda: o ponteiro mostra se está **baixa** (esquerda) ou **alta** (direita). No centro, fica verde: **afinada ✓**.
- **Automático** detecta sozinho qual corda você está tocando. **Por corda** deixa você escolher a corda tocando nela.
- **Segure uma corda** para ouvir a nota de referência.
- Embaixo você escolhe a **afinação** (padrão, drop D, meio tom abaixo…) e o **Lá central** (A4 = 440 Hz por padrão).

---

## Acordes

<img src="docs/prints/02-acordes.jpg" width="260">

- Escolha a **nota** (Dó, Ré, Mi…) e o **tipo** (maior, menor, com sétima…). O desenho mostra onde colocar os dedos.
- Deslize o desenho para o lado para ver outras posições do mesmo acorde.
- Toque em **Tocar acorde** para ouvir como ele deve soar.

---

## Metrônomo

<img src="docs/prints/03-metronomo.jpg" width="260">

- Ajuste o **BPM** pelos botões ou pela barra, ou toque em **Tap** no ritmo da música para ele descobrir o andamento.
- Escolha o **compasso** (2/4, 3/4, 4/4, 6/8…). O primeiro tempo é acentuado.
- Toque em **Iniciar** para começar.

---

## Estúdio

O Estúdio grava **em camadas**: você grava o violão, depois grava a voz por cima ouvindo o violão, depois um solo, e assim por diante. No fim, exporta tudo misturado.

### 1. Criar uma música

<img src="docs/prints/04-estudio-lista.jpg" width="260">

Toque em **Nova música** e dê um nome. Cada música é um projeto com as suas faixas. Para renomear ou apagar, use o menu **⋯** da música.

### 2. Ajustes da música e entrada

<img src="docs/prints/05-estudio-projeto.jpg" width="260">

- **BPM, compasso, clique e contagem**: toque na barra para abrir. Com o clique ligado, você ouve o metrônomo enquanto grava, mas ele **não entra na gravação**. A contagem dá 1 ou 2 compassos antes de começar a gravar.
- **Entrada**: escolha de onde vem o som (**Microfone do iPhone**, microfone do fone ou interface USB) e ajuste o **Ganho** se a captação estiver baixa. A barra verde mostra o nível. Toque alto, mas sem encostar no fim.
- **Ouvir a entrada**: escute o que está sendo captado, com efeito ao vivo (violão aço, nylon, voz, guitarra…). **Use fone de ouvido**, senão vira microfonia.

### 3. Faixas e linha do tempo

<img src="docs/prints/06-estudio-timeline.jpg" width="260">

- Cada linha é uma **faixa**, e os blocos dourados são os trechos gravados, com a forma de onda.
- **Nova faixa** cria uma faixa vazia, que já fica **armada** (bolinha vermelha cheia). A próxima gravação entra nela.
- Toque na **bolinha vermelha** de uma faixa para armar ou desarmar. Sem nenhuma armada, cada gravação cria uma faixa nova.
- **M** deixa a faixa muda e **S** faz solo (só ela toca). Toque no **nome** da faixa para volume, pan, efeitos, renomear e apagar.
- **Importar áudio** traz uma base, uma guia ou um playback do app Arquivos como faixa.

### 4. Posicionar a cabeça de reprodução

<!-- PRINT: docs/prints/07-estudio-zoom.png -->

- **Deslize o dedo na régua** (a faixa de cima, com os números dos compassos) para levar a cabeça até o ponto desejado.
- **Arraste nas ondas** para andar pela música sem mexer na cabeça. **Um toque** nas ondas leva a cabeça até ali.
- **Pinça** (dois dedos) ou as **lupas** dão zoom. De longe você vê a música inteira; de perto, a régua mostra décimos e **milissegundos**.
- O canto esquerdo da régua mostra a posição exata, por exemplo `0:12.345`.
- O botão **⇥** leva a cabeça até o fim da faixa armada, para **continuar de onde parou**.

### 5. Gravar

- Toque no **botão vermelho**. Se a contagem estiver ligada, ela toca antes, e então a gravação começa na posição da cabeça.
- Gravar no meio de uma faixa que já tem áudio **substitui só aquele trecho** (*punch-in*). O resto da faixa fica intacto.
- **Tocar** reproduz tudo. **⏮** volta ao começo.

### 6. Editar trechos

<!-- PRINT: docs/prints/08-estudio-trecho.png -->

Toque num trecho para selecioná-lo. Aparecem as opções:

- **Segure e arraste** o trecho para movê-lo. Ele gruda na batida.
- **Mover p/ cursor** leva o trecho para onde está a cabeça.
- **Fim da faixa** e **Apagar trecho**.

### 7. Efeitos

<!-- PRINT: docs/prints/09-estudio-efeitos.png -->

Cada faixa tem seus efeitos: presets prontos (**Violão aço, Violão nylon, Voz, Guitarra limpa, Guitarra drive**) ou ajuste manual de **noise gate, equalizador, compressor, drive, delay e reverb**.

### 8. Exportar

<!-- PRINT: docs/prints/10-estudio-exportar.png -->

Toque em **Exportar**, escolha **M4A** (menor, bom para WhatsApp) ou **WAV** (qualidade máxima) e compartilhe ou salve no Arquivos.

---

## Treino

O modo Treino é para **estudar músicas**: mudar o tom, desacelerar, repetir um trecho e até tirar o violão da música para você tocar no lugar.

### 1. Importar uma música

<!-- PRINT: docs/prints/11-treino-lista.png -->

Toque em **Importar música (MP3, M4A, WAV)** e escolha o arquivo no app Arquivos.

### 2. Tom, velocidade e repetição

<img src="docs/prints/12-treino-player.jpg" width="260">

- **Tom**: suba ou desça em semitons. O app mostra como os acordes mudam, por exemplo "um acorde de C vira D".
- **Velocidade**: desacelere sem mudar o tom, ótimo para pegar solos.
- **Repetir trecho (A-B)**: marque o ponto **A**, depois o **B**, e o trecho fica em loop.

### 3. Separar instrumentos (IA)

<img src="docs/prints/13-treino-separando.jpg" width="260"> <img src="docs/prints/13-treino-separacao.jpg" width="260">

- Toque em **Separar instrumentos (IA)**. Leva alguns minutos, porque a IA roda **no próprio iPhone**, sem internet. Deixe o app aberto.
- Depois, use os atalhos **Karaokê** (sem voz), **Sem violão**, **Tudo**, ou ajuste cada instrumento (voz, bateria, baixo, guitarra, piano, outros).
- **Usar como base no Estúdio** cria um projeto no Estúdio com a música (ou os instrumentos separados) para você gravar por cima.

---

## Usando na horizontal

<img src="docs/prints/14-horizontal.jpg" width="640">

Todas as telas funcionam com o iPhone deitado. No Estúdio, a linha do tempo ganha a tela toda à direita, e os controles de gravação ficam à esquerda.

---

## Perguntas frequentes

**O app parou de abrir.**
Passaram os 7 dias da assinatura gratuita. Reinstale o .ipa por cima com o Sideloadly; seus projetos continuam lá.

**A gravação ficou baixa com fone.**
Com fone conectado, o iPhone troca para o microfone do fone. Em **Entrada**, escolha **Microfone do iPhone** ou aumente o **Ganho**.

**Ouço um atraso quando escuto a entrada.**
Fones Bluetooth têm atraso. Para gravar ouvindo a entrada, prefira fone com fio.

**Onde ficam meus arquivos?**
No app **Arquivos › No meu iPhone › Pestana**. Dá para copiar e fazer backup por lá.

---

## Para desenvolvedores

O .ipa é gerado pelo GitHub Actions (workflow **Gerar IPA**, em macOS) a partir do `project.yml` (XcodeGen). O .ipa sai sem assinatura, e a ferramenta de instalação faz a assinatura. O modelo de separação (Demucs) é convertido para Core ML pelo workflow `demucs-model.yml`.
