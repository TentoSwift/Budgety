//
//  CSVImportView.swift
//  Budgety
//
//  CSV ファイルをシートに取り込む UI。
//  ファイル選択 → プレビュー → 取り込み確定 の 3 ステップ。
//

import SwiftUI
import UniformTypeIdentifiers

struct CSVImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let sheet: ExpenseSheet

    @State private var showFilePicker: Bool = false
    @State private var preview: CSVImporter.PreviewResult?
    @State private var sourceFileName: String?
    @State private var errorMessage: String?
    @State private var isImporting: Bool = false
    @State private var importedCount: Int?

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                if let preview {
                    summarySection(preview: preview)
                    previewSection(preview: preview)
                    if !preview.skipped.isEmpty {
                        skippedSection(preview: preview)
                    }
                } else {
                    selectFileSection
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if let importedCount {
                    Section {
                        Label("\(importedCount) 件を取り込みました", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("CSV 取り込み")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let preview, !preview.rows.isEmpty, importedCount == nil {
                        Button {
                            performImport(preview: preview)
                        } label: {
                            if isImporting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("取り込む")
                            }
                        }
                        .disabled(isImporting)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText, .plainText, UTType(filenameExtension: "csv") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
        }
    }

    // MARK: - Sections

    private var targetSection: some View {
        Section("取り込み先") {
            HStack(spacing: 12) {
                SheetIconView.baseIcon(
                    symbol: sheet.symbol ?? "person.2.fill",
                    tint: sheet.tint,
                    size: 28
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(sheet.displayName).foregroundStyle(.primary)
                    Text("既定通貨: \(sheet.resolvedDefaultCurrencyCode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectFileSection: some View {
        Section {
            Button {
                showFilePicker = true
            } label: {
                Label("CSV ファイルを選択", systemImage: "doc.text.fill")
            }
        } footer: {
            Text("UTF-8 / Shift_JIS の CSV に対応。ヘッダ行は date, title, amount, kind, currency, category, payer, note を認識します (日本語ヘッダもOK)。amount 列は必須、それ以外は省略可。")
                .font(.caption2)
        }
    }

    private func summarySection(preview: CSVImporter.PreviewResult) -> some View {
        Section("サマリ") {
            HStack {
                Text("ファイル")
                Spacer()
                Text(sourceFileName ?? "—").foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Text("ヘッダ")
                Spacer()
                Text(preview.header.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("解析できた行")
                Spacer()
                Text("\(preview.rows.count) 件")
                    .foregroundStyle(.green)
                    .fontWeight(.semibold)
            }
            if !preview.skipped.isEmpty {
                HStack {
                    Text("スキップ")
                    Spacer()
                    Text("\(preview.skipped.count) 件").foregroundStyle(.orange)
                }
            }
        }
    }

    private func previewSection(preview: CSVImporter.PreviewResult) -> some View {
        Section("プレビュー (最大 8 件)") {
            ForEach(Array(preview.rows.prefix(8).enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(formatDate(r.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(r.kind == .income ? "+" : "-")\(formatAmount(r.amount, code: r.currencyCode ?? sheet.resolvedDefaultCurrencyCode))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(r.kind == .income ? .green : .primary)
                    }
                    Text(r.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let cat = r.categoryName, !cat.isEmpty {
                            Text(cat).font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let payer = r.payerName, !payer.isEmpty {
                            Text("• \(payer)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func skippedSection(preview: CSVImporter.PreviewResult) -> some View {
        Section("スキップした行") {
            ForEach(Array(preview.skipped.enumerated()), id: \.offset) { _, s in
                HStack {
                    Text("行 \(s.line)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(s.reason).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
        }
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        errorMessage = nil
        importedCount = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            sourceFileName = url.lastPathComponent
            // セキュアスコープアクセスを取得 (ファイル選択ピッカー経由のため)
            let needsAccess = url.startAccessingSecurityScopedResource()
            defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                if let parsed = CSVImporter.parse(
                    data: data,
                    defaultCurrency: sheet.resolvedDefaultCurrencyCode
                ) {
                    preview = parsed
                } else {
                    errorMessage = String(localized: "ファイルを解析できませんでした (エンコーディング不明)")
                }
            } catch {
                errorMessage = String(localized: "読み込みエラー: \(error.localizedDescription)")
            }
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }

    private func performImport(preview: CSVImporter.PreviewResult) {
        isImporting = true
        Task { @MainActor in
            let count = CSVImporter.importRows(preview.rows, into: sheet, ctx: viewContext)
            importedCount = count
            isImporting = false
            Haptics.success()
        }
    }

    // MARK: - Helpers

    private func formatDate(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy/MM/dd"
        return df.string(from: d)
    }

    private func formatAmount(_ d: Decimal, code: String) -> String {
        CurrencyCatalog.format(d, code: code)
    }
}
