#!/bin/sh
#
#  ci_post_clone.sh
#  Budgety — Xcode Cloud post-clone script
#
#  リポジトリ clone 直後 (依存解決・ビルドの前) に Xcode Cloud が実行する。
#  1) SPM ビルドプラグイン (LicenseList の PrepareLicenseList) と Swift マクロを
#     CI 環境で承認する。UI の "Trust & Enable" 相当で、これが無いと
#     「Plugin "PrepareLicenseList" ... must be enabled」でビルドが失敗する。
#  2) ビルド番号を UTC 日付ベース (YYYYMMDDHH) で全ターゲットに自動採番する。
#     手動の CURRENT_PROJECT_VERSION 上げが不要になる (commit 値は上書きされる)。
#

set -e

# --- 1) パッケージプラグイン / マクロの fingerprint 検証をスキップ (CI 承認) ---
# 注: "Validatation" は Apple 側のキー名の綴り (typo) でこれが正しい。
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

# --- 2) ビルド番号の自動採番 (UTC, YYYYMMDDHH。例: 2026061214) ---
# 単調増加し uint32 (<= 4294967295) に収まり、既存 TestFlight ビルドより大きい。
BUILD=$(date -u +%Y%m%d%H)
PBXPROJ="${CI_PRIMARY_REPOSITORY_PATH}/Budgety.xcodeproj/project.pbxproj"

if [ -f "${PBXPROJ}" ]; then
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "${PBXPROJ}"
    echo "ci_post_clone: set CURRENT_PROJECT_VERSION = ${BUILD}"
else
    echo "ci_post_clone: ERROR project.pbxproj not found at ${PBXPROJ}" >&2
    exit 1
fi
