//
//  LogSettlementView.swift
//  Expenso
//
//  「送金済みにする」ダイアログ。送金プランから開く場合は from / to / amount / currency が
//  プリフィルされる。手動で開く場合は全フィールドを編集できる。
//

import SwiftUI
import CoreData
import CloudKit

struct LogSettlementView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var sheet: ExpenseSheet
    /// 編集対象。nil なら新規作成。
    let record: SettlementRecord?
    /// プリフィル用 (新規作成時のみ参照)
    let prefillFrom: String?
    let prefillTo: String?
    let prefillAmount: Decimal?
    let prefillCurrencyCode: String?

    @State private var fromProfileID: String = ""
    @State private var toProfileID: String = ""
    @State private var amountText: String = ""
    @State private var currencyCode: String = ""
    @State private var date: Date = .now
    @State private var note: String = ""
    @State private var didLoad: Bool = false
    @State private var share: CKShare?

    init(
        sheet: ExpenseSheet,
        record: SettlementRecord? = nil,
        prefillFrom: String? = nil,
        prefillTo: String? = nil,
        prefillAmount: Decimal? = nil,
        prefillCurrencyCode: String? = nil
    ) {
        self.sheet = sheet
        self.record = record
        self.prefillFrom = prefillFrom
        self.prefillTo = prefillTo
        self.prefillAmount = prefillAmount
        self.prefillCurrencyCode = prefillCurrencyCode
    }

    private var canSave: Bool {
        !fromProfileID.isEmpty
        && !toProfileID.isEmpty
        && fromProfileID != toProfileID
        && Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) != nil
        && (Decimal(string: amountText.replacingOccurrences(of: ",", with: "")) ?? 0) > 0
    }

    // MARK: - Members

    private var selfIDSet: Set<String> {
        UserProfileStore.shared.canonicalSelfIDs(forShare: share)
    }
    private var selfProfileID: String {
        UserProfileStore.shared.canonicalSelfID(forShare: share)
            ?? UserProfileStore.shared.userRecordName ?? ""
    }

    private var allMemberIDs: [String] {
        var ids: [String] = []
        var seen = Set<String>()
        if !selfProfileID.isEmpty {
            ids.append(selfProfileID)
            seen.insert(selfProfileID)
        }
        for id in selfIDSet { seen.insert(id) }
        if let share {
            // CKShare ロード済 → participants だけ使う (解除済み・未参加の人は出さない)
            for p in share.participants {
                guard p.acceptanceStatus == .accepted else { continue }
                let rn = p.userIdentity.userRecordID?.recordName ?? ""
                guard !rn.isEmpty,
                      !UserProfileStore.isSelfPlaceholderRecordName(rn),
                      seen.insert(rn).inserted else { continue }
                ids.append(rn)
            }
            // バーチャルメンバーは CKShare に出ないので PP から追加する。
            // (SettlementCalculator の memberOrder 構築と挙動を揃える)
            let virtualPPs = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
            for pp in virtualPPs.sorted(by: {
                ($0.displayName ?? "", $0.recordName ?? "") < ($1.displayName ?? "", $1.recordName ?? "")
            }) {
                guard let rn = pp.recordName,
                      UserProfileStore.isVirtualRecordName(rn),
                      seen.insert(rn).inserted else { continue }
                ids.append(rn)
            }
        } else {
            // CKShare 未ロード時はバーチャルメンバーのみ PP から追加する。
            // 非バーチャルの PP は「共有していたが抜けた参加者」の残骸であることが
            // あるため含めない (SettlementCalculator と挙動を揃える)。
            let pps = (sheet.participantProfiles as? Set<ParticipantProfile>) ?? []
            for pp in pps.sorted(by: {
                ($0.displayName ?? "", $0.recordName ?? "") < ($1.displayName ?? "", $1.recordName ?? "")
            }) {
                guard let rn = pp.recordName,
                      UserProfileStore.isVirtualRecordName(rn),
                      seen.insert(rn).inserted else { continue }
                ids.append(rn)
            }
        }
        return ids
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("送金者 (From)") {
                    memberPicker(selection: $fromProfileID, excludeID: toProfileID)
                }
                Section("受取者 (To)") {
                    memberPicker(selection: $toProfileID, excludeID: fromProfileID)
                }
                Section("金額") {
                    HStack {
                        TextField("0", text: $amountText)
                        #if os(iOS)
                            .keyboardType(.decimalPad)
                        #endif
                            .onChange(of: amountText) { _, new in
                                let normalized = new
                                    .applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? new
                                let allowed = normalized
                                    .filter { $0.isASCII && ($0.isNumber || $0 == ".") }
                                if allowed != new { amountText = allowed }
                            }
                        Spacer()
                        Picker("通貨", selection: $currencyCode) {
                            ForEach(CurrencyCatalog.allOrderedByLocale) { opt in
                                Text("\(opt.symbol) \(opt.code)").tag(opt.code)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
                Section("日付") {
                    DatePicker("送金日", selection: $date, displayedComponents: .date)
                }
                Section("メモ") {
                    TextField("", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
            .frame(width: 460, height: 560)
            #endif
            .navigationTitle(record == nil ? "送金を記録" : "送金を編集")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(record == nil ? "保存" : "更新", systemImage: "checkmark") { save() }
                        .disabled(!canSave)
                }
            }
            .task { await loadDefaults() }
        }
    }

    @ViewBuilder
    private func memberPicker(selection: Binding<String>, excludeID: String) -> some View {
        ForEach(allMemberIDs.filter { $0 != excludeID }, id: \.self) { id in
            let info = sheet.memberDisplayInfo(for: id)
            let isMe = selfIDSet.contains(id)
            let isOn = (selection.wrappedValue == id)
            Button {
                selection.wrappedValue = id
            } label: {
                HStack(spacing: 12) {
                    AvatarView(
                        photoData: info.photoData,
                        displayName: info.name,
                        colorHex: info.colorHex,
                        size: 28
                    )
                    Text(isMe ? "\(info.name) (自分)" : info.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @MainActor
    private func loadDefaults() async {
        share = ShareCoordinator.shared.existingShare(for: sheet)
        await UserProfileStore.shared.ensureUserRecordNameLoaded()
        guard !didLoad else { return }
        didLoad = true
        if let r = record {
            fromProfileID = r.fromProfileID ?? ""
            toProfileID = r.toProfileID ?? ""
            amountText = NSDecimalNumber(decimal: r.amountDecimal).stringValue
            currencyCode = r.resolvedCurrencyCode
            date = r.date ?? .now
            note = r.note ?? ""
        } else {
            fromProfileID = prefillFrom ?? selfProfileID
            toProfileID = prefillTo ?? ""
            if let a = prefillAmount {
                amountText = NSDecimalNumber(decimal: a).stringValue
            }
            currencyCode = prefillCurrencyCode ?? sheet.resolvedDefaultCurrencyCode
        }
    }

    private func save() {
        guard let amount = Decimal(string: amountText.replacingOccurrences(of: ",", with: "")),
              amount > 0 else { return }

        let target: SettlementRecord
        if let existing = record {
            target = existing
        } else {
            target = SettlementRecord(context: viewContext)
            if let store = sheet.objectID.persistentStore {
                viewContext.assign(target, to: store)
            }
            target.id = UUID()
            target.sheet = sheet
            target.createdAt = .now
            target.createdByProfileID = UserProfileStore.shared.canonicalSelfID(forShare: share)
                ?? UserProfileStore.shared.userRecordName
        }
        target.fromProfileID = fromProfileID
        target.toProfileID = toProfileID
        target.amount = NSDecimalNumber(decimal: amount)
        target.currencyCode = currencyCode.isEmpty
            ? sheet.resolvedDefaultCurrencyCode
            : currencyCode
        target.date = date
        target.note = note

        PersistenceController.shared.save()
        dismiss()
    }
}
