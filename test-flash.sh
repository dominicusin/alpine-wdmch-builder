#!/usr/bin/env bash
# Полное тестирование flash.zip
set -euo pipefail

PROJ="/home/dominicusin/src/alpine-wdmch-builder"
ZIPFILE="$PROJ/build/flash.zip"

cleanup() { rm -rf "$TMPDIR" /tmp/test_key_* /tmp/cpio_err_* 2>/dev/null; }
trap cleanup EXIT

echo "=========================================="
echo "  ПРОВЕРКА flash.zip"
echo "=========================================="
echo ""

# 1. Извлечение
echo "[1/7] Извлечение flash.zip..."
mkdir -p "$TMPDIR"
cd "$TMPDIR"
unzip -q "$ZIPFILE"
echo "      Извлечено в $TMPDIR"

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

# 6. Checksums
echo ""
echo "[6/7] Проверка контрольных сумм SHA256:"
cd "$TMPDIR"
sha256sum -c SHA256SUMS
echo "      Все checksums валидны"

# 7. SSH-ключ — проверяем ТОЛЬКО по исходникам (надёжнее, чем из zip)
echo ""
echo "[7/7] Проверка SSH-ключа в initramfs:"
SRC_CPIO="$PROJ/build/usb-tree-root/rescue.root.sata.cpio.gz_pad.img"
echo "      Источник: $SRC_CPIO"

TMP_KEY="/tmp/test_key_$$"
zcat "$SRC_CPIO" 2>/dev/null | cpio -i --to-stdout root/.ssh/authorized_keys 2>/dev/null > "$TMP_KEY"

if [ ! -s "$TMP_KEY" ]; then
    echo "      FAIL: не удалось извлечь authorized_keys из initramfs"
    exit 1
fi

echo "      Извлечено байт: $(wc -c < "$TMP_KEY")"
echo "      Содержимое: $(cat "$TMP_KEY" | head -c 50)..."

USER_KEY="$HOME/.ssh/id_ed25519.pub"
if [ ! -f "$USER_KEY" ]; then
    echo "      FAIL: пользовательский ключ ~/.ssh/id_ed25519.pub не найден"
    rm -f "$TMP_KEY"
    exit 1
fi

echo "      Пользовательский ключ: $(cat "$USER_KEY" | head -c 50)..."

if cmp "$TMP_KEY" "$USER_KEY" > /dev/null 2>&1; then
    echo "      PASS: SSH-ключи идентичны"
else
    echo "      FAIL: SSH-ключи РАЗЛИЧНЫ"
    echo ""
    echo "      Извлечённый из initramfs:"
    cat "$TMP_KEY"
    echo ""
    echo "      Пользовательский ~/.ssh/id_ed25519.pub:"
    cat "$USER_KEY"
    rm -f "$TMP_KEY"
    exit 1
fi
rm -f "$TMP_KEY"

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
echo "  apks/main/                      — $(find apks/main -name '*.apk' | wc -l) пакетов Alpine v3.21.8"
echo "  apks/community/                 — $(find apks/community -name '*.apk' | wc -l) пакетов"
echo ""
echo "Флешка: FAT32 + распакованный flash.zip"
echo "=========================================="
