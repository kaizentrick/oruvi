// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import SwiftUI

struct TypographySettings: View {
    @Bindable var model: StandbyModel
    @State private var target: Target = .lyrics

    private enum Target: String, CaseIterable {
        case lyrics = "Letras"
        case clock = "Reloj"
        case content = "Texto general"
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.height >= 465 {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    ScrollView { fontCards }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        controls
                        fontCards
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder private var controls: some View {
        Picker("Texto que quieres personalizar", selection: $target) {
            ForEach(Target.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("typography.target")

        preview
        options
        Text("Fuentes")
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private var fontCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 134), spacing: 8)], spacing: 8) {
            ForEach(AmbientTypeface.allCases.filter(\.installed)) { typeface in
                typefaceCard(typeface)
            }
        }
        .padding(2)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vista previa").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(currentTypeface.name).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("typography.preview.family")
            }
            Group {
                switch target {
                case .lyrics:
                    VStack(alignment: .leading, spacing: 5) {
                        Text("La noche baja despacio")
                            .font(lyricFont(19)).foregroundStyle(.secondary)
                        Text("Y el ritmo me acompaña")
                            .font(lyricFont(36, emphasized: true))
                            .accessibilityIdentifier("typography.preview.lyric")
                        Text("Hasta que vuelva el sol")
                            .font(lyricFont(21)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).minimumScaleFactor(0.55)
                case .clock:
                    EditorialTime(text: model.twentyFourHour ? "13:36" : "1:36", maximumSize: 78,
                                  centered: true, typeface: model.clockTypeface, weight: model.clockWeight)
                case .content:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Música para la noche").font(model.contentTypeface.font(size: 28, emphasized: true))
                        Text("Oruvi").font(model.contentTypeface.font(size: 15)).foregroundStyle(.secondary)
                        Text("También hay calma en el silencio.")
                            .font(model.contentTypeface.font(size: 16)).italic().foregroundStyle(.secondary)
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 155, alignment: .center)
        }
        .padding(16)
        .background(LinearGradient(colors: [.accentColor.opacity(0.11), .primary.opacity(0.035)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.10))
        }
    }

    @ViewBuilder private var options: some View {
        switch target {
        case .lyrics:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Tamaño").font(.subheadline.weight(.medium))
                    Image(systemName: "textformat.size.smaller").accessibilityHidden(true)
                    Slider(value: $model.lyricSizePercent, in: LyricTypography.sizeRange, step: 5) {
                        Text("Tamaño de la letra")
                    }
                    .labelsHidden()
                    .accessibilityValue("\(Int(model.lyricSizePercent)) %")
                    .accessibilityIdentifier("typography.lyric.size")
                    Image(systemName: "textformat.size.larger").accessibilityHidden(true)
                    Text("\(Int(model.lyricSizePercent)) %")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                        .accessibilityHidden(true)
                }
                HStack {
                    if model.lyricTypefaceOverride == nil {
                        Text("Usa la fuente del texto general").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Usar fuente del texto general") { model.lyricTypefaceOverride = nil }
                            .controlSize(.small)
                            .accessibilityIdentifier("typography.lyric.inherit")
                    }
                    Spacer()
                    Button("Restablecer tamaño") { model.lyricSizePercent = LyricTypography.defaultSize }
                        .controlSize(.small)
                        .disabled(model.lyricSizePercent == LyricTypography.defaultSize)
                        .accessibilityIdentifier("typography.lyric.reset")
                }
            }
        case .clock:
            Picker("Grosor del reloj", selection: $model.clockWeight) {
                ForEach(ClockWeight.allCases) { Text($0.name).tag($0) }
            }
        case .content:
            Text("La fuente se aplica a títulos, artistas y frases. Las letras pueden usar su propia fuente.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var currentTypeface: AmbientTypeface {
        switch target {
        case .lyrics: return model.lyricTypeface
        case .clock: return model.clockTypeface
        case .content: return model.contentTypeface
        }
    }

    private func lyricFont(_ size: CGFloat, emphasized: Bool = false) -> Font {
        LyricTypography.font(model.lyricTypeface, baseSize: size, sizePercent: model.lyricSizePercent, emphasized: emphasized)
    }

    private func typefaceCard(_ typeface: AmbientTypeface) -> some View {
        let selected = typeface == currentTypeface
        let sample = switch target {
        case .lyrics: "Y el ritmo"
        case .clock: model.twentyFourHour ? "13:36" : "1:36"
        case .content: "Música y calma"
        }
        let font = switch target {
        case .lyrics: typeface.font(size: 22, emphasized: true)
        case .clock: Font(typeface.native(size: 26, weight: model.clockWeight.native))
        case .content: typeface.font(size: 20, emphasized: true)
        }
        return Button {
            switch target {
            case .lyrics: model.lyricTypefaceOverride = typeface
            case .clock: model.clockTypeface = typeface
            case .content: model.contentTypeface = typeface
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(sample).font(font).lineLimit(1).minimumScaleFactor(0.68)
                Text(typeface.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : .primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.11), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(typeface.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("typography.font." + typeface.rawValue)
    }
}
