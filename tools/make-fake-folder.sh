#!/bin/sh
# Build a fake firmware folder for testing fix-wifi.sh and fix-audio.sh.
# Usage: make-fake-folder.sh FOLDER BDENCODER
set -eu
R=$1; BDE=$2
mkdir -p "$R/fw/ath11k/WCN6855/hw2.1" "$R/build" "$R/fw/qcom/x1e80100" \
         "$R/ucm/conf.d/x1e80100" "$R/ucm/Qualcomm/x1e80100"
cd "$R/build"
head -c 1000 /dev/urandom > generic.bin
head -c 900 /dev/urandom > other.bin
cat > board-2.json <<'J'
[{"board":[
 {"names":["bus=pci,vendor=17cb,device=1103,subsystem-vendor=105b,subsystem-device=e105,qmi-chip-id=18,qmi-board-id=255"],"data":"generic.bin"},
 {"names":["bus=pci,vendor=17cb,device=1103,subsystem-vendor=17aa,subsystem-device=9309,qmi-chip-id=18,qmi-board-id=255"],"data":"other.bin"}]}]
J
python3 "$BDE" -c board-2.json -o "$R/fw/ath11k/WCN6855/hw2.1/board-2.bin" >/dev/null
echo tplgdata > "$R/fw/qcom/x1e80100/X1E80100-Romulus-tplg.bin"
echo profile > "$R/ucm/Qualcomm/x1e80100/LENOVO-T14s.conf"
echo "fake folder ready at $R"
