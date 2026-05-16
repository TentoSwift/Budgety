//
//  BudgetyVisionContentView.swift
//  Budgety For visionOS
//
//  メインウィンドウ。左に NavigationSplit でシート一覧、右に詳細。
//

import SwiftUI
import CoreData

struct BudgetyVisionContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Binding var immersiveSheetID: NSManagedObjectID?

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \ExpenseSheet.createdAt, ascending: true)
        ],
        animation: .default
    ) private var sheets: FetchedResults<ExpenseSheet>

    @State private var selectedSheet: ExpenseSheet?

    var body: some View {
        NavigationSplitView {
            sheetList
                .navigationTitle("Budgety")
        } detail: {
            if let sheet = selectedSheet {
                BudgetyVisionSheetView(
                    sheet: sheet,
                    immersiveSheetID: $immersiveSheetID
                )
            } else {
                ContentUnavailableView(
                    "シートを選択",
                    systemImage: "rectangle.stack",
                    description: Text("左のリストからシートを選んでください。")
                )
            }
        }
        .onAppear { selectedSheet = sheets.first }
    }

    private var sheetList: some View {
        List(selection: $selectedSheet) {
            ForEach(sheets) { sheet in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sheet.displayName)
                            .font(.headline)
                        if let cur = sheet.defaultCurrencyCode {
                            Text(cur)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: sheet.symbol ?? "person.2.fill")
                        .foregroundStyle(sheet.tint)
                }
                .tag(sheet)
            }
        }
        .listStyle(.sidebar)
    }
}
