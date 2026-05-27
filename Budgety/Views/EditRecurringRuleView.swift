//
//  EditRecurringRuleView.swift
//  Expenso
//

import SwiftUI
import CoreData
import CloudKit

struct EditRecurringRuleView: View {
    enum Mode {
        case create(record: ExpenseSheet)
        case edit(rule: RecurringRule)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var profile = UserProfileStore.shared

    let mode: Mode

    @State private var title: String = ""
    @State private var amountText: String = ""
    @State private var kind: TransactionKind = .expense
    @State private var currencyCode: String = CurrencyCatalog.defaultCode
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var interval: Int = 1
    @State private var startDate: Date = .now
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = .now
    @State private var selectedCategory: ExpenseCategory?
    @State private var selectedPayer: Member?
    @State private var note: String = ""
    @State private var didLoad: Bool = false

    private var contextSheet: ExpenseSheet? {
        switch mode {
        case .create(let r): return r
        case .edit(let rule): return rule.sheet
        }
    }

    /// Member に対応する per-sheet ParticipantProfile を引く。
    private func currentParticipantProfile(for member: Member) -> ParticipantProfile? {
        guard let rn = member.recordName, !rn.isEmpty,
              rn != "_defaultOwner_", rn != "__defaultOwner__",
              let sheet = contextSheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == rn })
    }

    /// 自分の per-sheet ParticipantProfile (= 未選択時のデフォルト候補表示用)。
    private var selfParticipantProfileInSheet: ParticipantProfile? {
        guard let rn = profile.userRecordName, !rn.isEmpty,
              let sheet = contextSheet,
              let profiles = sheet.participantProfiles as? Set<ParticipantProfile> else { return nil }
        return profiles.first(where: { $0.recordName == rn })
    }

    private var amountDecimal: Decimal? {
        guard !amountText.isEmpty else { return nil }
        return Decimal(string: amountText)
    }

    private var canSave: Bool {
        amountDecimal != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var navTitle: String {
        switch mode {
        case .create: "定期項目を追加"
        case .edit:   "定期項目を編集"
        }
    }

    private var decimalKeypadNeeded: Bool {
        !["JPY", "KRW", "VND", "IDR"].contains(currencyCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("種別", selection: $kind) {
                        ForEach(TransactionKind.allCases) { k in
                            Label(k.label, systemImage: k.symbol).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("内容") {
                    TextField(kind == .expense ? "タイトル (例: Netflix, 家賃)" : "タイトル (例: 給料)", text: $title)
                    HStack(spacing: 6) {
                        Text(CurrencyCatalog.option(for: currencyCode).symbol)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .leading)
                        TextField("0", text: $amountText)
                            .keyboardType(decimalKeypadNeeded ? .decimalPad : .numberPad)
                            .font(.title3.monospacedDigit())
                            .onChange(of: amountText) { _, new in
                                let allowed = decimalKeypadNeeded
                                    ? new.filter { $0.isNumber || $0 == "." }
                                    : new.filter { $0.isNumber }
                                if allowed != new { amountText = allowed }
                            }
                    }
                    Picker("通貨", selection: $currencyCode) {
                        ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                            Text("\(opt.symbol)  \(opt.code) — \(opt.displayName)").tag(opt.code)
                        }
                    }
                    #if os(macOS)
                    .pickerStyle(.menu)
                    #else
                    .pickerStyle(.navigationLink)
                    #endif
                }

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
                                .foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("開始日", selection: $startDate, displayedComponents: [.date])
                    Toggle("終了日を設定", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("終了日", selection: $endDate, in: startDate..., displayedComponents: [.date])
                    }
                } header: {
                    Text("繰り返し")
                } footer: {
                    Text("開始日から指定の頻度で、過去〜今日までの未生成分を自動でシートに追加します。")
                }

                Section("カテゴリ") {
                    if let sheet = contextSheet {
                        NavigationLink {
                            CategoryPickerView(selected: $selectedCategory, record: sheet, kind: kind)
                        } label: {
                            HStack {
                                Text("カテゴリ")
                                Spacer()
                                if let cat = selectedCategory {
                                    CategoryIconView(category: cat, size: 24)
                                    Text(cat.displayName)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("未選択")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(kind.partyLabel) {
                    NavigationLink {
                        MemberPickerView(selected: $selectedPayer, record: contextSheet, kind: kind)
                    } label: {
                        HStack {
                            Text(kind.partyLabel)
                            Spacer()
                            if let m = selectedPayer {
                                if let pp = currentParticipantProfile(for: m) {
                                    ObservedParticipantProfileAvatar(profile: pp, size: 24)
                                    Text(pp.displayName?.isEmpty == false ? pp.displayName! : m.displayName)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ObservedMemberAvatar(member: m, size: 24)
                                    Text(m.displayName)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let pp = selfParticipantProfileInSheet {
                                ObservedParticipantProfileAvatar(profile: pp, size: 24)
                                Text(pp.displayName?.isEmpty == false ? pp.displayName! : profile.resolvedDisplayName)
                                    .foregroundStyle(.secondary)
                            } else {
                                AvatarView(
                                    photoData: profile.photoData,
                                    displayName: profile.resolvedDisplayName,
                                    colorHex: profile.avatarBgColorHex ?? "#5B8DEF",
                                    size: 24
                                )
                                Text(profile.resolvedDisplayName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("メモ (任意)") {
                    TextField("詳細", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if case .edit(let rule) = mode {
                    Section {
                        Button(role: .destructive) {
                            viewContext.delete(rule)
                            PersistenceController.shared.save()
                            Haptics.warning()
                            dismiss()
                        } label: {
                            Label("削除", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("削除しても、過去に自動生成された支出/収入は残ります。")
                    }
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    #if os(macOS)
                    Button("完了") { save() }
                        .disabled(!canSave)
                    #else
                    Button("保存", systemImage: "checkmark") { save() }
                        .disabled(!canSave)
                    #endif
                }
            }
            .onAppear { loadIfNeeded() }
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        profile.ensureSelfMemberExists(in: viewContext)

        switch mode {
        case .create(let record):
            currencyCode = record.resolvedDefaultCurrencyCode
            if selectedCategory == nil {
                let cats = (record.categories as? Set<ExpenseCategory>) ?? []
                let sorted = cats.sorted { $0.sortOrder < $1.sortOrder }
                selectedCategory = sorted.first(where: { $0.name == "食費" }) ?? sorted.first
            }
            if selectedPayer == nil, let id = profile.selfMemberID {
                let req = NSFetchRequest<Member>(entityName: "Member")
                req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                req.fetchLimit = 1
                selectedPayer = (try? viewContext.fetch(req))?.first
            }
        case .edit(let rule):
            title = rule.displayTitle
            amountText = NSDecimalNumber(decimal: rule.amountDecimal).stringValue
            kind = rule.kind
            currencyCode = rule.resolvedCurrencyCode
            frequency = rule.resolvedFrequency
            interval = rule.resolvedInterval
            startDate = rule.startDate ?? .now
            if let end = rule.endDate {
                hasEndDate = true
                endDate = end
            }
            note = rule.note ?? ""
            if let sheet = rule.sheet,
               let raw = rule.categoryRaw,
               let cats = sheet.categories as? Set<ExpenseCategory> {
                selectedCategory = cats.first(where: { $0.name == raw })
            }
            if let pid = rule.payerProfileID,
               let uuid = UUID(uuidString: pid) {
                let req = NSFetchRequest<Member>(entityName: "Member")
                req.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                req.fetchLimit = 1
                selectedPayer = (try? viewContext.fetch(req))?.first
            }
        }
    }

    private func save() {
        guard let amountDecimal else { return }
        let pc = PersistenceController.shared

        switch mode {
        case .create(let record):
            let rule = RecurringRule(context: viewContext)
            // 親シートと同じストアに割り当て
            if let store = record.objectID.persistentStore {
                viewContext.assign(rule, to: store)
            }
            rule.id = UUID()
            rule.createdAt = .now
            rule.sheet = record
            apply(to: rule, amount: amountDecimal)
        case .edit(let rule):
            apply(to: rule, amount: amountDecimal)
        }
        pc.save()
        // 保存直後にも一回 generate を回して、startDate が今日以前ならすぐに反映
        RecurringExpenseGenerator.generateAll(in: viewContext)
        Haptics.success()
        dismiss()
    }

    private func apply(to rule: RecurringRule, amount: Decimal) {
        rule.title = title.trimmingCharacters(in: .whitespaces)
        rule.amount = NSDecimalNumber(decimal: amount)
        rule.kindRaw = kind.rawValue
        rule.currencyCode = currencyCode
        rule.categoryRaw = selectedCategory?.name
        let share = rule.sheet.flatMap { ShareCoordinator.shared.existingShare(for: $0) }
        rule.paidBy = nil
        rule.payerProfileID = selectedPayer?.resolvedProfileID(forShare: share)
        rule.note = note
        rule.frequency = frequency.rawValue
        rule.interval = Int32(interval)
        rule.startDate = Calendar.current.startOfDay(for: startDate)
        rule.endDate = hasEndDate ? Calendar.current.startOfDay(for: endDate) : nil
    }
}
