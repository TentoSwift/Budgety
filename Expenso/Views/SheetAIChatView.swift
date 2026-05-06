//
//  SheetAIChatView.swift
//  Expenso
//
//  シート単位の AI チャット UI。`SheetAIChat` のメッセージを bubble 表示し、
//  下部の入力欄から質問する。
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
            Divider()
            inputBar
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("AI チャット")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                LazyVStack(spacing: 10) {
                    ForEach(chat.messages) { msg in
                        bubble(for: msg).id(msg.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 16)
            }
            // ストリーミング中はテキストが伸びるたびに最下部へ
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

    @ViewBuilder
    private func bubble(for msg: SheetAIChat.Message) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(msg.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.15), in: Circle())
                Group {
                    if msg.text.isEmpty {
                        // ストリーミング開始前 = まだトークンが届いていない
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("考え中…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(.init(msg.text))
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 40)
            }
        case .error:
            HStack {
                Label(msg.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer()
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(
                SheetAIChat.isAvailable ? "質問を入力..." : "AI が利用できません",
                text: $chat.inputText,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit { send() }
            .disabled(!SheetAIChat.isAvailable)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canSend ? Color.accentColor : Color.gray.opacity(0.5))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
