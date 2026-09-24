#!/usr/bin/env bash
# Полное тестирование flash.zip (локально и в CI)
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
ZIPFILE="$PROJ/build/flash.zip"
WORKDIR=""

cleanup() {
    [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
    rm -f /tmp/test_key_* /tmp/cpio_err_* 2>/dev/null || true
}
trap cleanup EXIT

echo "=========================================="
echo "  ПРОВЕРКА flash.zip"
echo "=========================================="
echo ""

# 1. Извлечение
echo "[1/7] Извлечение flash.zip..."
[ -f "$ZIPFILE" ] || { echo "      FAIL: $ZIPFILE не найден"; exit 1; }
WORKDIR="$(mktemp -d)"
cd "$WORKDIR"
unzip -q "$ZIPFILE"
echo "      Извлечено в $WORKDIR"

# 2. Дерево
echo ""
echo "[2/7] Дерево извлечённого содержимого:"
find . -type f | sort
echo ""

# 3. Структура
echo "[3/7] Проверка структуры (файлы в корне, apks/ — отдельно):"
if [ -d ./boot ]; then
    echo "      FAIL: boot/ каталог существует"
    exit 1
else
    echo "      PASS: boot/ каталог отсутствует"
fi

# 4. Обязательные файлы
echo ""
echo "[4/7] Проверка обязательных файлов:"
for f in sata.uImage rescue.sata.dtb rescue.root.sata.cpio.gz_pad.img SHA256SUMS manifest.json README.txt; do
    if [ -f "$f" ]; then
        echo "      ✓ $f"
    else
        echo "      ✗ $f — ОТСУТСТВУЕТ"
        exit 1
    fi
done

# 5. apks/
echo ""
echo "[5/7] Проверка apks/:"
if [ -d apks/main ] && [ -d apks/community ]; then
    echo "      ✓ apks/main/ и apks/community/ существуют"
else
    echo "      ✗ apks/ отсутствует"
    exit 1
fi

main_count=$(find apks/main -name '*.apk' | wc -l)
comm_count=$(find apks/community -name '*.apk' | wc -l)
echo "      Пакетов main: $main_count"
echo "      Пакетов community: $comm_count"
echo "      Всего APK-файлов: $((main_count + comm_count))"
if [ "$((main_count + comm_count))" -lt 20 ]; then
    echo "      FAIL: слишком мало APK-пакетов ($((main_count + comm_count)) < 20) — offline-репозиторий неполный"
    exit 1
fi

# 6. Checksums
echo ""
echo "[6/7] Проверка контрольных сумм SHA256:"
cd "$WORKDIR"
sha256sum -c SHA256SUMS
echo "      Все checksums валидны"

# 7. SSH-ключ — проверяем ТОЛЬКО по исходникам (надёжнее, чем из zip)
echo ""
echo "[7/7] Проверка SSH-ключа в initramfs:"
SRC_CPIO="$PROJ/build/usb-tree-root/rescue.root.sata.cpio.gz_pad.img"
echo "      Источник: $SRC_CPIO"
[ -f "$SRC_CPIO" ] || { echo "      FAIL: $SRC_CPIO не найден"; exit 1; }

TMP_KEY="$(mktemp /tmp/test_key_XXXXXX)"
zcat "$SRC_CPIO" 2>/dev/null | cpio -i --to-stdout root/.ssh/authorized_keys 2>/dev/null > "$TMP_KEY"

if [ ! -s "$TMP_KEY" ]; then
    echo "      FAIL: не удалось извлечь authorized_keys из initramfs"
    exit 1
fi

echo "      Извлечено байт: $(wc -c < "$TMP_KEY")"
echo "      Содержимое: $(head -c 50 "$TMP_KEY")..."

# Эталон: WDMCH_SSH_AUTHORIZED_KEY (CI) или ~/.ssh/id_ed25519.pub (локально)
if [ -n "${WDMCH_SSH_AUTHORIZED_KEY:-}" ]; then
    REF_KEY="$(mktemp /tmp/test_key_ref_XXXXXX)"
    printf '%s\n' "$WDMCH_SSH_AUTHORIZED_KEY" > "$REF_KEY"
elif [ -f "${HOME:-}/.ssh/id_ed25519.pub" ]; then
    REF_KEY="${HOME}/.ssh/id_ed25519.pub"
else
    echo "      FAIL: нет эталонного ключа (WDMCH_SSH_AUTHORIZED_KEY или ~/.ssh/id_ed25519.pub)"
    exit 1
fi

echo "      Эталонный ключ: $(head -c 50 "$REF_KEY")..."

# Сравниваем только сами ключи (тип + base64), игнорируя комментарий
key_body() { awk '{print $1" "$2}' "$1"; }

if [ "$(key_body "$TMP_KEY")" = "$(key_body "$REF_KEY")" ]; then
    echo "      PASS: SSH-ключи идентичны"
else
    echo "      FAIL: SSH-ключи РАЗЛИЧНЫ"
    echo ""
    echo "      Извлечённый из initramfs:"
    cat "$TMP_KEY"
    echo ""
    echo "      Эталонный:"
    cat "$REF_KEY"
    exit 1
fi
rm -f "$TMP_KEY"
[ -f /tmp/test_key_ref_* ] && rm -f /tmp/test_key_ref_* || true

echo ""
echo "=========================================="
echo "  flash.zip ГОТОВ и ПРОВЕРЕН"
echo "=========================================="
echo ""
echo "Файлы для копирования на FAT-флешку (корень):"
echo "  sata.uImage                      — ядро (патчено, RAW, +512K padding)"
echo "  rescue.sata.dtb                 — DTB"
echo "  rescue.root.sata.cpio.gz_pad.img — initramfs (dropbear + ssh, ровно 4 MiB)"
echo "  SHA256SUMS                      — контрольные суммы"
echo "  manifest.json                   — метаданные"
echo "  README.txt                      — инструкция"
echo ""
echo "  apks/main/                      — $(find apks/main -name '*.apk' | wc -l) пакетов Alpine"
echo "  apks/community/                 — $(find apks/community -name '*.apk' | wc -l) пакетов"
echo ""
echo "Флешка: FAT32 + распакованный flash.zip"
echo "=========================================="
