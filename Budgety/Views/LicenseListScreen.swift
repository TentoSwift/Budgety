//
//  LicenseListScreen.swift
//  Budgety
//
//  OSS ライセンス一覧画面。cybozu/LicenseList (SPM パッケージ + ビルドプラグイン) を
//  使い、依存パッケージの LICENSE を自動集約して表示する。
//
//  パッケージ追加前でもビルドが通るよう `#if canImport(LicenseList)` でガードしている。
//  Xcode で LicenseList パッケージ + LicenseListPlugin を iOS ターゲットに追加すると
//  自動的に実体の一覧が表示される。
//

import SwiftUI
#if canImport(LicenseList)
import LicenseList
#endif

struct LicenseListScreen: View {
    var body: some View {
        Group {
            #if canImport(LicenseList)
            LicenseListView()
            #else
            ContentUnavailableView {
                Label("ライセンス情報は準備中です", systemImage: "doc.text")
            } description: {
                Text("LicenseList パッケージを追加すると、依存パッケージのライセンス一覧が表示されます。")
            }
            #endif
        }
        .navigationTitle("ライセンス")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
