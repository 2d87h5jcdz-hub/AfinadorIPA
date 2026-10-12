#!/usr/bin/env bash
# Teste de fumaça no emulador (roda no GitHub Actions): instala o APK, abre cada aba,
# tira prints (retrato e paisagem) e falha se o app fechar sozinho.
set -u
APK="$1"
OUT="$2"
PKG=com.pestana.estudio
mkdir -p "$OUT"
FAIL=0

shot() { sleep "${2:-2}"; adb exec-out screencap -p > "$OUT/$1.png"; echo "print: $1"; }

alive() {
  if [ -z "$(adb shell pidof $PKG | tr -d '\r')" ]; then
    echo "::error title=App fechou::O app não está rodando depois de: $1"
    FAIL=1
  fi
}

# Espera até $2 segundos pelo texto $1 na tela.
wait_text() {
  local t=0
  while [ $t -lt "$2" ]; do
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1
    if grep -q "text=\"$1\"" /tmp/ui.xml; then return 0; fi
    sleep 5; t=$((t + 5))
  done
  return 1
}

scroll_down() { adb shell input swipe 540 1700 540 500 400; sleep 1; }

# Toca no elemento cujo texto é exatamente $1 (o de baixo, se houver vários: barra de abas).
tap_text() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1
  local xy
  xy=$(python3 - "$1" <<'PY'
import re, sys
t = sys.argv[1]
xml = open('/tmp/ui.xml', encoding='utf-8').read()
best = None
for m in re.finditer(r'<node [^>]*>', xml):
    n = m.group(0)
    tm = re.search(r' text="([^"]*)"', n)
    dm = re.search(r' content-desc="([^"]*)"', n)
    if (tm and tm.group(1) == t) or (dm and dm.group(1) == t):
        b = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        x1, y1, x2, y2 = map(int, b.groups())
        c = ((x1 + x2) // 2, (y1 + y2) // 2)
        if best is None or c[1] > best[1]:
            best = c
print(f"{best[0]} {best[1]}" if best else "")
PY
)
  if [ -z "$xy" ]; then
    echo "::warning title=Elemento não achado::Texto '$1' não apareceu na tela"
    return 1
  fi
  if [ "${2:-}" = long ]; then
    adb shell input swipe $xy $xy 900
  else
    adb shell input tap $xy
  fi
}

adb install -r "$APK" || { echo "::error title=Instalação::adb install falhou"; exit 1; }
adb logcat -G 32M; adb logcat -c
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 0

adb shell am start -W -n $PKG/.MainActivity
shot 01-afinador-permissao 4
alive "abrir o app"

# Concede o microfone (como se o usuário tivesse tocado em Permitir) e volta ao app.
adb shell pm grant $PKG android.permission.RECORD_AUDIO
adb shell input keyevent KEYCODE_HOME
sleep 1
adb shell am start -W -n $PKG/.MainActivity
shot 02-afinador 3
alive "ligar o microfone"

tap_text "A" long; sleep 1            # segurar a corda = nota de referência
alive "tocar nota de referência"
tap_text "Padrão (E A D G B E)" && shot 02b-afinador-afinacoes 1
tap_text "Drop D (D A D G B E)"; sleep 1
tap_text "Por corda" && shot 02c-afinador-por-corda 1
tap_text "Acordes" && shot 03-acordes
tap_text "F" && shot 04-acordes-pestana
tap_text "Tocar acorde"; sleep 2
alive "tocar acorde"

tap_text "Metrônomo" && sleep 1
tap_text "Iniciar"; shot 05-metronomo-tocando 2
alive "metrônomo"
tap_text "Parar"

tap_text "Estúdio" && shot 06-estudio
tap_text "Treino" && shot 07-treino

# --- Treino: importa um áudio pelo "Abrir com" (intent VIEW), toca, muda tom/velocidade e separa com IA
python3 android/ci/make_wav.py /tmp/teste.wav 13
adb push /tmp/teste.wav /sdcard/Music/teste.wav
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Music/teste.wav >/dev/null
sleep 3
ID=""
for i in 1 2 3 4 5 6; do
  ID=$(adb shell content query --uri content://media/external/audio/media --projection _id:_display_name | grep "teste.wav" | sed -e 's/.*_id=\([0-9]*\).*/\1/' | head -1 | tr -d '\r')
  [ -n "$ID" ] && break
  adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1
  sleep 3
done
echo "MediaStore id: $ID"
if [ -n "$ID" ]; then
  adb shell am start -a android.intent.action.VIEW -d "content://media/external/audio/media/$ID" -t audio/wav \
    --grant-read-uri-permission -n $PKG/.MainActivity
fi
if ! wait_text "MÚSICA ORIGINAL" 30; then
  # Plano B: o seletor de arquivos do Android, como o usuário faria.
  tap_text "OK"
  tap_text "Importar música (MP3, M4A, WAV)"; sleep 3
  shot 10b-seletor 1
  tap_text "teste.wav" || { adb shell input keyevent KEYCODE_BACK; }
fi
if wait_text "MÚSICA ORIGINAL" 60; then
  shot 11-treino-player 2
  tap_text "Tocar"; sleep 3
  tap_text "75%"; tap_text "Meio tom acima"; sleep 2
  shot 12-treino-tocando 1
  alive "tocar no Treino"
  tap_text "Pausar"
  scroll_down; scroll_down
  if tap_text "Separar instrumentos (IA)"; then
    sleep 2; tap_text "Baixar e separar"
    sleep 20; shot 13-treino-separando 1
    if wait_text "Usar instrumentos separados" 900; then
      sleep 3; scroll_down; scroll_down
      tap_text "Karaokê"; sleep 1
      shot 14-treino-instrumentos 1
      scroll_down
      shot 15-treino-instrumentos-2 1
      echo "::notice title=Separação::Concluída no emulador"
      # --- Estúdio: usa os stems como base, grava 4 s por cima, toca e exporta
      tap_text "Tudo"; sleep 1
      scroll_down; scroll_down
      if tap_text "Usar como base no Estúdio" && wait_text "Faixas" 120; then
        sleep 3; shot 17-estudio-base 1
        # Afinação automática na faixa de voz
        if tap_text "Voz ›"; then
          sleep 2; scroll_down
          tap_text "Afinação automática"
          if wait_text "✓ Pronto: a reprodução e a exportação já usam a voz afinada." 180; then
            shot 17b-estudio-afinacao 1
            echo "::notice title=Afinação::Voz afinada no emulador"
          else
            shot 17b-estudio-afinacao-falhou 1
            echo "::error title=Afinação::Não terminou no emulador"
            FAIL=1
          fi
          adb shell input keyevent KEYCODE_BACK; sleep 2
        fi
        tap_text "Gravar"; sleep 8
        shot 18-estudio-gravando 0
        tap_text "Parar gravação"; sleep 3
        shot 19-estudio-gravado 1
        alive "gravar no Estúdio"
        tap_text "Tocar"; sleep 3; shot 20-estudio-tocando 0
        tap_text "Parar"; sleep 1
        tap_text "Exportar"; sleep 1; tap_text "M4A"; sleep 15
        shot 21-estudio-exportar 1
        alive "exportar"
        adb shell input keyevent KEYCODE_BACK; sleep 2
        adb shell input keyevent KEYCODE_BACK; sleep 2
        shot 22-estudio-lista 1
        tap_text "Treino"; sleep 2
      else
        echo "::error title=Estúdio::Não abriu o projeto a partir do Treino"
        FAIL=1
      fi
    else
      shot 13b-treino-separacao-falhou 1
      echo "::error title=Separação::Não terminou (ou falhou) no emulador"
      FAIL=1
    fi
  fi
  alive "separar com IA"
  adb shell input keyevent KEYCODE_BACK; sleep 1
  shot 16-treino-biblioteca 1
else
  shot 11-treino-import-falhou 1
  echo "::error title=Treino::A música não abriu (intent VIEW e seletor)"
  tap_text "OK"
  FAIL=1
fi

# Paisagem
adb shell settings put system accelerometer_rotation 0
adb shell wm user-rotation lock 1 || adb shell settings put system user_rotation 1
sleep 4
adb shell dumpsys window | grep -m1 -i "mCurrentRotation\|mRotation" || true
tap_text "Afinador" && shot 08-afinador-paisagem 3
tap_text "Acordes" && shot 09-acordes-paisagem
tap_text "Metrônomo" && shot 10-metronomo-paisagem
tap_text "Estúdio" && shot 10b-estudio-paisagem
alive "girar a tela"
adb shell wm user-rotation lock 0 || adb shell settings put system user_rotation 0

adb logcat -d > "$OUT/logcat.txt"
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then
  trace=$(grep -A25 "FATAL EXCEPTION" "$OUT/logcat.txt" | head -30 | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
  echo "::error title=Crash::$trace"
  FAIL=1
fi
# Tempo por segmento da IA (emulador x86_64)
grep "Demucs: segmento" "$OUT/logcat.txt" | head -3 | while read -r l; do echo "::notice title=IA::${l##*: }"; done
grep -E "AndroidRuntime|Pestana" "$OUT/logcat.txt" | grep -E " [EF] " | head -5 | while read -r l; do echo "::warning title=Log::$l"; done
# Erros do áudio do app (para depurar sem aparelho)
grep -E "AudioTrack|AudioRecord" "$OUT/logcat.txt" | grep -E " E " | head -5 | while read -r l; do echo "::warning title=Áudio::$l"; done

exit $FAIL
