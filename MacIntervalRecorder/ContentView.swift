import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: RecorderController

    var body: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                CameraPreview(session: recorder.session)
                    .frame(minHeight: 390)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.separator, lineWidth: 1)
                    }

                if recorder.isRecordingClip {
                    Label("正在录制", systemImage: "record.circle.fill")
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(.red.opacity(0.9), in: Capsule())
                        .padding(12)
                }
            }

            HStack(spacing: 18) {
                Picker("摄像头", selection: $recorder.selectedCameraID) {
                    ForEach(recorder.cameras, id: \.uniqueID) { camera in
                        Text(camera.localizedName).tag(camera.uniqueID)
                    }
                }
                .frame(maxWidth: 300)
                .disabled(recorder.isRunning)

                Stepper(value: $recorder.intervalMinutes, in: 1...120) {
                    Text("间隔：\(recorder.intervalMinutes) 分钟")
                }
                .disabled(recorder.isRunning)

                Stepper(value: $recorder.clipSeconds, in: 1...60) {
                    Text("片段：\(recorder.clipSeconds) 秒")
                }
                .disabled(recorder.isRunning)

                Toggle("录制声音", isOn: $recorder.includeAudio)
                    .disabled(recorder.isRunning)
            }

            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(recorder.statusText)
                        .font(.headline)
                    Text("已捕捉 \(recorder.clipCount) 个片段")
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if recorder.isExporting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("清除片段", role: .destructive) {
                    recorder.clearClips()
                }
                .disabled(recorder.isRunning || recorder.clipCount == 0 || recorder.isExporting)

                Button("开始") {
                    Task { await recorder.startSchedule() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recorder.isRunning || recorder.isExporting)

                Button("结束并导出") {
                    Task { await recorder.stopAndExport() }
                }
                .disabled(!recorder.isRunning || recorder.isExporting)
            }

            if let message = recorder.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .task { await recorder.prepare() }
        .onDisappear { recorder.shutdown() }
    }
}

