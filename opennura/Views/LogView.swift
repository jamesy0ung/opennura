import SwiftUI

struct LogView: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Spacer()
                Button("Copy All") { copyAll() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logs.indices, id: \.self) { i in
                            Text(logs[i])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 180, maxHeight: 320)
                .onChange(of: logs.count) { _ in
                    if let last = logs.indices.last {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func copyAll() {
        let text = logs.joined(separator: "\n")
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }
}
