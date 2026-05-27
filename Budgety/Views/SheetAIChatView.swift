//
//  SheetAIChatView.swift
//  Expenso
//
//  シート単位の AI チャット UI。iMessage 風の bubble + 日付セパレータ + 送信
//  ステータスを表示する。
//

import SwiftUI

struct SheetAIChatView: View {
    @ObservedObject var record: ExpenseSheet
    @StateObject private var chat: SheetAIChat
    @FocusState private var inputFocused: Bool

    init(record: ExpenseSheet) {
        self.record = record
        self._chat = StateObject(wrappedValue: SheetAIChat(sheet: record))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
        }
        .safeAreaInset(edge: .bottom) {
            inputBar
        }
        .background(Color.platformSystemBackground.ignoresSafeArea())
        .navigationTitle("AI チャット")
        .navigationBarTitleDisplayMode(.inline)
        // 画面表示のたびに、削除/編集でデータが変わっていれば AI の参照データを更新。
        .onAppear { chat.refreshContext() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    chat.resetConversation()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(chat.messages.isEmpty || !SheetAIChat.isAvailable)
            }
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { idx, msg in
                        if shouldShowDateSeparator(at: idx) {
                            dateSeparator(for: msg.createdAt)
                                .padding(.top, idx == 0 ? 4 : 14)
                                .padding(.bottom, 6)
                        }
                        bubble(for: msg)
                            .id(msg.id)
                            .padding(.bottom, isLastInGroup(at: idx) ? 6 : 1)
                    }
                    if shouldShowDeliveredStatus {
                        deliveredStatus
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: chat.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onAppear { scrollToBottom(proxy: proxy) }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastID = chat.messages.last?.id {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    /// 連続メッセージ間で 5 分以上の間隔があれば、日時セパレータを挟む。
    /// (iMessage 風: メッセージ間の長い空白に「火曜日 午後 8:09」が出るあれ)
    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard index < chat.messages.count else { return false }
        if index == 0 { return true }
        let cur = chat.messages[index].createdAt
        let prev = chat.messages[index - 1].createdAt
        return cur.timeIntervalSince(prev) > 5 * 60
    }

    /// グループ最後のメッセージか (= 次のメッセージが別 role / 末尾)。
    /// グループ末尾だけ下に隙間を空けて、同 role 連続は密にする。
    private func isLastInGroup(at index: Int) -> Bool {
        guard index < chat.messages.count else { return false }
        if index == chat.messages.count - 1 { return true }
        return chat.messages[index].role != chat.messages[index + 1].role
    }

    /// 直近のメッセージが user で、AI がもう応答済み (= 次に assistant がある or
    /// thinking 中でない) なら配信済みステータスを出す。
    private var shouldShowDeliveredStatus: Bool {
        guard let last = chat.messages.last else { return false }
        return last.role == .user && !chat.isThinking
    }

    private func dateSeparator(for date: Date) -> some View {
        Text(date.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private var deliveredStatus: some View {
        HStack {
            Spacer()
            Text("送信済み")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 4)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func bubble(for msg: SheetAIChat.Message) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(msg.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        case .assistant:
            HStack {
                Group {
                    if msg.text.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("考え中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(msg.text.asAttributedMarkdown)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(.tertiarySystemFill))
                .foregroundStyle(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer(minLength: 60)
            }
        case .error:
            HStack {
                Label(msg.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer()
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField(
                    SheetAIChat.isAvailable ? "" : "利用できません",
                    text: $chat.inputText,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send() }
                .disabled(!SheetAIChat.isAvailable)

                VStack {
                    Spacer()
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : Color.gray.opacity(0.5))
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.clear), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        SheetAIChat.isAvailable
            && !chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chat.isThinking
    }

    private func send() {
        chat.send()
        inputFocused = false
    }
}
