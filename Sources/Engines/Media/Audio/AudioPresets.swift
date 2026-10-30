import Foundation

// Built-in presets of the audio target (spec/handbrake.md 4.3). Values are sparse over the schema defaults.

enum AudioPresets {
    private static func p(_ id: String, _ en: String, _ ru: String, note: L10n? = nil, symbol: String = "waveform", group: PresetGroup,
                          _ values: OptionValues) -> Preset {
        .builtin(id, target: AudioSchemas.convertID, L10n(en, ru), notes: note, symbol: symbol, group: group, values)
    }

    static let builtins: [Preset] = [
        p("aud.mp3.v0", "MP3, best (V0)", "MP3, максимум (V0)", symbol: "music.note", group: .web,
          [AudioKeys.target: "mp3", AudioKeys.rateControl: "quality", AudioKeys.quality: 100]),
        p("aud.mp3.v2", "MP3, standard (V2, about 190 kbit/s)", "MP3, стандарт (V2, около 190 кбит/с)", symbol: "music.note", group: .web,
          [AudioKeys.target: "mp3", AudioKeys.rateControl: "quality", AudioKeys.quality: 78]),
        p("aud.mp3.320", "MP3 320 kbit/s", "MP3 320 кбит/с", symbol: "music.note", group: .web,
          [AudioKeys.target: "mp3", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 320]),
        p("aud.mp3.128", "MP3, small (128 kbit/s)", "MP3, компактно (128 кбит/с)", symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize,
          [AudioKeys.target: "mp3", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 128, AudioKeys.channels: "stereo"]),
        p("aud.aac.256", "AAC 256 kbit/s", "AAC 256 кбит/с", symbol: "applelogo", group: .devices,
          [AudioKeys.target: "aac", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 256]),
        p("aud.aac.128", "AAC, small (128 kbit/s)", "AAC, компактно (128 кбит/с)", symbol: "arrow.down.right.and.arrow.up.left", group: .smallSize,
          [AudioKeys.target: "aac", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 128]),
        p("aud.flac", "FLAC, lossless", "FLAC без потерь", symbol: "checkmark.seal", group: .lossless,
          [AudioKeys.target: "flac", AudioKeys.flacLevel: 8]),
        p("aud.alac", "Apple Lossless (ALAC)", "Apple Lossless (ALAC)", symbol: "checkmark.seal", group: .lossless,
          [AudioKeys.target: "alac"]),
        p("aud.wav.cd", "WAV 16-bit 44.1 kHz (CD)", "WAV 16 бит 44,1 кГц (CD)", symbol: "opticaldisc", group: .lossless,
          [AudioKeys.target: "wav", AudioKeys.sampleRate: "44100", AudioKeys.bitDepth: "16", AudioKeys.channels: "stereo"]),
        p("aud.wav.pro", "WAV 24-bit 48 kHz (video, studio)", "WAV 24 бита 48 кГц (видео, студия)", symbol: "slider.horizontal.3", group: .lossless,
          [AudioKeys.target: "wav", AudioKeys.sampleRate: "48000", AudioKeys.bitDepth: "24"]),
        p("aud.opus.music", "Opus 128 kbit/s (music)", "Opus 128 кбит/с (музыка)", symbol: "music.note", group: .web,
          [AudioKeys.target: "opus", AudioKeys.bitrate: 128, AudioKeys.opusApp: "audio", AudioKeys.opusVBR: "on", AudioKeys.sampleRate: "48000"]),
        p("aud.opus.voice", "Opus 32 kbit/s (voice)", "Opus 32 кбит/с (голос)", symbol: "mic", group: .smallSize,
          [AudioKeys.target: "opus", AudioKeys.bitrate: 32, AudioKeys.opusApp: "voip", AudioKeys.channels: "mono", AudioKeys.sampleRate: "48000", AudioKeys.highpass: 80]),
        p("aud.podcast", "Podcast, speech (mono AAC)", "Подкаст, речь (AAC моно)", symbol: "mic",
          group: .web, [AudioKeys.target: "aac", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 64, AudioKeys.channels: "mono", AudioKeys.sampleRate: "44100",
                        AudioKeys.normalize: "custom", AudioKeys.normLUFS: -19, AudioKeys.normTP: -1.5, AudioKeys.highpass: 80]),
        p("aud.podcast.stereo", "Podcast, stereo AAC", "Подкаст, стерео AAC", symbol: "mic",
          group: .web, [AudioKeys.target: "aac", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 96, AudioKeys.channels: "stereo", AudioKeys.sampleRate: "44100",
                        AudioKeys.normalize: "podcast", AudioKeys.highpass: 80]),
        p("aud.audiobook", "Audiobook (M4B)", "Аудиокнига (M4B)", symbol: "book", group: .devices,
          [AudioKeys.target: "m4b", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 64, AudioKeys.channels: "mono", AudioKeys.sampleRate: "44100"]),
        p("aud.voicemsg", "Voice message (Telegram, WhatsApp)", "Голосовое сообщение (Telegram, WhatsApp)", symbol: "message", group: .social,
          [AudioKeys.target: "opus", AudioKeys.bitrate: 32, AudioKeys.opusApp: "voip", AudioKeys.channels: "mono", AudioKeys.sampleRate: "48000"]),
        p("aud.ringtone", "iPhone ringtone (M4R, up to 40 s)", "Рингтон iPhone (M4R, до 40 с)", symbol: "bell", group: .devices,
          [AudioKeys.target: "m4r", AudioKeys.rateControl: "bitrate", AudioKeys.bitrate: 256, AudioKeys.trimEnd: 40, AudioKeys.fadeOut: 1]),
        p("aud.norm.16", "Normalise to -16 LUFS (podcasts, music)", "Нормализовать до -16 LUFS (подкасты, музыка)", symbol: "slider.vertical.3", group: .web,
          [AudioKeys.target: "same", AudioKeys.normalize: "podcast"]),
        p("aud.norm.stream", "Normalise to -14 LUFS (streaming)", "Нормализовать до -14 LUFS (стриминг)", symbol: "slider.vertical.3", group: .web,
          [AudioKeys.target: "same", AudioKeys.normalize: "streaming", AudioKeys.limiter: true]),
        p("aud.norm.ebu", "Normalise to -23 LUFS (EBU R128, broadcast)", "Нормализовать до -23 LUFS (EBU R128, вещание)", symbol: "slider.vertical.3", group: .archive,
          [AudioKeys.target: "same", AudioKeys.normalize: "ebu", AudioKeys.limiter: true]),
        p("aud.fit.16", "Under 16 MB (WhatsApp)", "До 16 МБ (WhatsApp)", note: L10n("The bit rate is chosen so that the file stays just under the limit.", "Битрейт подбирается так, чтобы файл оказался чуть меньше лимита."),
          symbol: "paperplane", group: .social, [AudioKeys.target: "aac", AudioKeys.fitMB: 16, AudioKeys.channels: "stereo"]),
        p("aud.fit.25", "Under 25 MB (e-mail, Discord)", "До 25 МБ (почта, Discord)", note: L10n("The bit rate is chosen so that the file stays just under the limit.", "Битрейт подбирается так, чтобы файл оказался чуть меньше лимита."),
          symbol: "envelope", group: .social, [AudioKeys.target: "aac", AudioKeys.fitMB: 25, AudioKeys.channels: "stereo"])
    ]
}
