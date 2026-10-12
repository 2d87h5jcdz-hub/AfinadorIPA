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
adb logcat -c
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

# Paisagem
adb shell settings put system accelerometer_rotation 0
adb shell wm user-rotation lock 1 || adb shell settings put system user_rotation 1
sleep 4
adb shell dumpsys window | grep -m1 -i "mCurrentRotation\|mRotation" || true
tap_text "Afinador" && shot 08-afinador-paisagem 3
tap_text "Acordes" && shot 09-acordes-paisagem
tap_text "Metrônomo" && shot 10-metronomo-paisagem
alive "girar a tela"
adb shell wm user-rotation lock 0 || adb shell settings put system user_rotation 0

adb logcat -d > "$OUT/logcat.txt"
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then
  trace=$(grep -A25 "FATAL EXCEPTION" "$OUT/logcat.txt" | head -30 | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
  echo "::error title=Crash::$trace"
  FAIL=1
fi
# Erros do áudio do app (para depurar sem aparelho)
grep -E "AudioTrack|AudioRecord" "$OUT/logcat.txt" | grep -E " E " | head -5 | while read -r l; do echo "::warning title=Áudio::$l"; done

exit $FAIL
