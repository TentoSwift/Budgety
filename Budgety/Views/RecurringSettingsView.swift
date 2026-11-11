//
//  RecurringSettingsView.swift
//  Expenso
//
//  AddExpenseView から navigate して開く繰り返し設定の専用画面。
//  親の @State に Bind して値を直接編集する。
//

import SwiftUI

struct RecurringSettingsView: View {
    @Binding var isRecurring: Bool
    @Binding var frequency: RecurrenceFrequency
    @Binding var interval: Int
    @Binding var hasEndDate: Bool
    @Binding var endDate: Date
    let startDate: Date
    var isLocked: Bool = false

    var body: some View {
        List {
            Section {
                Picker("繰り返し", selection: $isRecurring) {
                    Text("しない").tag(false)
                    Text("する").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(isLocked)
            } footer: {
                if isRecurring {
                    Text("この日付を開始日として、未生成分を自動的にシートに追加します。")
                        .font(.caption2)
                }
            }

            if isRecurring {
                Section {
                    Picker("頻度", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    Stepper(value: $interval, in: 1...60) {
                        HStack {
                            Text("間隔")
                            Spacer()
                            Text(frequency.summary(interval: interval))
                                .font(.sheetNumber(.body))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Toggle("終了日を設定", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("終了日",
                                   selection: $endDate,
                                   in: startDate...,
                                   displayedComponents: [.date])
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("繰り返し")
        .navigationBarTitleDisplayMode(.inline)
    }
}
