//
//  CurrencyPickerView.swift
//  Expenso
//
//  通貨を選ぶ push 画面。行タップで選択して自動で戻る。
//  SwiftUI 標準の `Picker(.navigationLink)` だと push 先が
//  独自の view にならず、AddExpenseView の「変更を破棄しますか?」
//  確認ダイアログのアンカー (DiscardGuardedBack) を差し込めない。
//  そこで CategoryPickerView / MemberPickerView と同じ自作リストにして、
//  push 先でも確認ダイアログを一貫して出せるようにする。
//

import SwiftUI

struct CurrencyPickerView: View {
    @Binding var selectedCode: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                Button {
                    selectedCode = opt.code
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(opt.symbol)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 32, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.displayName)
                                .foregroundStyle(.primary)
                            Text(opt.code)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selectedCode == opt.code {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("通貨を選択")
        .navigationBarTitleDisplayMode(.inline)
    }
}
