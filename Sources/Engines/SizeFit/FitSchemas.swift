import Foundation

enum FitSchemas {
    static let defaultTarget = "discord10"

    /// One schema per kind ("fit.video", "fit.audio", "fit.image", "fit.pdf"): page Target (preset picker with the sizes shown, custom MB;
    /// the live estimate chip sits next to it in the Studio summary bar, fed by `SizeEstimator`), page Method (downscale allowed, two-pass,
    /// audio budget, minimum quality, format, privacy), `.oracle(...)` on every field.
    static func schema(id: String) -> OptionSchema {
        guard let kind = FitKind(schemaID: id) else {
            return OptionSchema(id: id, title: L10n("Fit to size", "До размера"), symbol: "scalemass", pages: [])
        }
        return OptionSchema(id: id, title: L10n("Fit to size", "До размера"), symbol: "scalemass", pages: [targetPage(kind), methodPage(kind)])
    }

    // MARK: Target

    private static func targetPage(_ kind: FitKind) -> OptionPage {
        let options = SizeTargetCatalog.presets(for: kind.fileKind).map { FieldOption($0.id, $0.label, symbol: $0.symbol, hint: $0.note) }
        let target = OptionField.picker(FitKeys.target, L10n("Size limit", "Лимит размера"), options, def: defaultTarget)
            .basic()
            .help(L10n("The result will be no larger than this and as close to it as the content allows.",
                       "Результат не превысит этот размер и будет как можно ближе к нему, насколько позволяет содержимое."))
            .oracle("fit.out.size")
            .aliases(["whatsapp", "telegram", "discord", "mail", "почта", "мессенджер", "лимит", "МБ", "MB"])
        let custom = OptionField.number(FitKeys.customMB, L10n("Size in megabytes (MB)", "Размер в мегабайтах (МБ)"), min: 0.05, max: 100_000, step: 0.5, def: 10, decimals: 2)
            .basic()
            .visible(.eq(FitKeys.target, .string(SizeTarget.customID)))
            .help(L10n("1 MB is 1,000,000 bytes, the way Finder shows sizes.", "1 МБ - это 1 000 000 байт, как показывает Finder."))
            .oracle("fit.out.size.custom")
        return .make("target", symbol: "scalemass", L10n("Target", "Цель"), [.make("limit", L10n("Size", "Размер"), [target, custom])])
    }

    // MARK: Method

    private static func methodPage(_ kind: FitKind) -> OptionPage {
        var groups: [OptionGroup] = []
        switch kind {
        case .video:
            groups.append(.make("picture", L10n("Picture", "Картинка"), [
                .toggle(FitKeys.allowDownscale, L10n("Allow lower resolution", "Разрешить меньшее разрешение"), def: true).basic()
                    .help(L10n("When the limit is tight for this clip, the picture is reduced in steps (1080p, 720p, 540p …) so it stays clean instead of turning into blocks.",
                               "Если лимит тесен для этого ролика, картинка уменьшается ступенями (1080p, 720p, 540p ...), чтобы оставаться чистой, а не рассыпаться на квадраты."))
                    .oracle("fit.out.height")
            ]))
            groups.append(.make("encoding", L10n("Encoding", "Кодирование"), [
                .toggle(FitKeys.twoPass, L10n("Two passes", "Два прохода"), def: true)
                    .needs(["ff.enc.libx264"], reason: L10n("Needs ffmpeg with libx264. Open Settings > Tools.", "Нужен ffmpeg с libx264. Откройте Настройки > Инструменты."))
                    .help(L10n("Slower, but the size lands closer to the limit and the bits are spread more evenly. Hardware encoders always use one pass.",
                               "Медленнее, но размер ближе к лимиту, а биты распределяются равномернее. Аппаратные кодировщики всегда работают в один проход."))
                    .oracle("fit.argv.pass")
            ]))
            let rates = [32, 48, 64, 96, 128, 160, 192].map { FieldOption(String($0), L10n("\($0) kbit/s", "\($0) кбит/с")) }
            groups.append(.make("sound", L10n("Sound", "Звук"), [
                .picker(FitKeys.audioKbps, L10n("Sound quality", "Качество звука"), rates, def: "96")
                    .help(L10n("Bitrate of the AAC soundtrack. The rest of the limit goes to the picture. Very small limits lower it automatically.",
                               "Битрейт звука AAC. Остальной лимит отдаётся картинке. При очень малом лимите он снижается автоматически."))
                    .oracle("fit.out.audio.bitrate")
            ]))
        case .audio:
            groups.append(.make("format", L10n("Format", "Формат"), [
                .picker(FitKeys.audioCodec, L10n("Audio format", "Формат звука"), [
                    FieldOption("auto", L10n("AAC (M4A), recommended", "AAC (M4A), рекомендуется"), hint: L10n("The most exact size; plays everywhere.", "Самый точный размер; играет везде.")),
                    FieldOption("mp3", L10n("MP3", "MP3"), requires: ["ff.enc.libmp3lame"], hint: L10n("Sizes come in coarse steps.", "Размеры меняются крупными ступенями.")),
                    FieldOption("opus", L10n("Opus", "Opus"), requires: ["ff.enc.libopus"], hint: L10n("Best for voice at very small sizes.", "Лучше всего для голоса при очень малом размере."))
                ], def: "auto").basic().oracle("fit.out.audio.codec")
            ]))
        case .image:
            groups.append(.make("size", L10n("Size and quality", "Размер и качество"), [
                .toggle(FitKeys.allowDownscale, L10n("Allow a smaller picture", "Разрешить уменьшить картинку"), def: true).basic()
                    .help(L10n("If lowering the quality is not enough, the picture is made smaller in small steps and the quality is raised again.",
                               "Если одного снижения качества мало, картинка уменьшается небольшими шагами, а качество снова повышается."))
                    .oracle("fit.out.dimensions"),
                .slider(FitKeys.minQuality, L10n("Lowest quality", "Минимальное качество"), min: 20, max: 95, step: 5, def: 60,
                        minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better quality", "Лучше качество"))
                    .help(L10n("The quality never goes below this at full size; below it the picture is reduced instead.",
                               "В полном размере качество не опустится ниже этого значения; дальше уменьшается сама картинка."))
                    .oracle("fit.out.quality.floor")
            ]))
            groups.append(.make("format", L10n("Format", "Формат"), [
                .toggle(FitKeys.keepFormat, L10n("Keep the original format", "Сохранить исходный формат"), def: false)
                    .help(L10n("Off: JPEG, which opens everywhere (PNG when the picture has transparency).", "Выкл.: JPEG, он открывается везде (PNG, если у картинки есть прозрачность)."))
                    .oracle("fit.out.format"),
                .picker(FitKeys.imageFormat, L10n("Format", "Формат"), [
                    FieldOption("auto", L10n("Automatic (JPEG)", "Автоматически (JPEG)")),
                    FieldOption("jpg", L10n("JPEG", "JPEG")),
                    FieldOption("heic", L10n("HEIC (smaller)", "HEIC (меньше)"), hint: L10n("Not every app can open HEIC.", "Не все приложения открывают HEIC.")),
                    FieldOption("webp", L10n("WebP (smaller)", "WebP (меньше)"), requires: ["tool.cwebp"])
                ], def: "auto").visible(.not(.isSet(FitKeys.keepFormat))).oracle("fit.out.format")
            ]))
        case .pdf:
            groups.append(.make("method", L10n("Method", "Способ"), [
                .toggle(FitKeys.allowDownscale, L10n("Allow turning pages into pictures", "Разрешить превращать страницы в картинки"), def: true).basic()
                    .help(L10n("Used only when pictures alone cannot reach the limit. The text stays selectable, but fonts and drawings become part of the picture.",
                               "Используется, только если одними картинками лимит не достичь. Текст остаётся выделяемым, но шрифты и рисунки становятся частью картинки."))
                    .oracle("fit.out.pages.raster"),
                .slider(FitKeys.minQuality, L10n("Lowest picture quality", "Минимальное качество картинок"), min: 30, max: 90, step: 5, def: 50,
                        minLabel: L10n("Smaller file", "Меньше файл"), maxLabel: L10n("Better quality", "Лучше качество"))
                    .oracle("fit.out.quality.floor")
            ]))
        }
        let stripLabel: L10n = kind == .pdf ? L10n("Remove document info", "Удалить сведения о документе") : L10n("Remove location and camera info", "Удалить геолокацию и сведения о камере")
        groups.append(.make("privacy", L10n("Privacy", "Конфиденциальность"), [
            .toggle(FitKeys.stripMetadata, stripLabel, def: false)
                .help(L10n("Good for sharing: GPS position, device and dates stay out of the result.", "Удобно для публикации: координаты, устройство и даты не попадут в результат."))
                .oracle("fit.out.metadata")
        ]))
        return .make("method", symbol: "slider.horizontal.3", L10n("Method", "Способ"), groups)
    }
}
