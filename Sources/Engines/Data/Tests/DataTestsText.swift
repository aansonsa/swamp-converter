import Foundation

// Self-tests of the text encoding detector shared by CSV, subtitles and zip names.

enum DataTestsText {
    static let samples: [(label: String, text: String, encodings: [DataEncoding])] = [
        ("Russian", "Съешь же ещё этих мягких французских булок, да выпей чаю. Привет, мир! Это тестовая строка с кириллицей.", [.windows1251, .koi8r, .cp866]),
        ("Russian caps", "ДОГОВОР ПОСТАВКИ № 15 от 12 марта: Поставщик обязуется передать, а Покупатель принять и оплатить товар.", [.windows1251, .koi8r, .cp866]),
        ("Ukrainian", "Широкий вибір різноманітних товарів: їжа, одяг та ґрунт для саду. Це українська мова, ґанок і єнот.", [.windows1251]),
        ("Latvian", "Rīgas Latvijas galvaspilsēta ir Baltijas ūdeņu pērle; ķirši, ģimene, šņukst, ļoti žēl. Čau, Šodien ir jauka diena.", [.windows1257]),
        ("Lithuanian", "Lietuvos sostinė Vilnius yra gražus miestas, šiandien ūkininkas ėjo per žemę ir įsižiūrėjo į pasaulį.", [.windows1257]),
        ("Czech", "Příliš žluťoučký kůň úpěl ďábelské ódy. Žluťák se řítí lesem, kde šeptá větrný stín nad řekou.", [.windows1250, .iso88592]),
        ("Polish", "Zażółć gęślą jaźń, a potem pójdź w łan. Śnieg pada, ćma lata nad łąką i źródłem.", [.windows1250, .iso88592]),
        ("French", "Voilà un déjà-vu à Zürich: Grüße, Straße, café, naïve garçon dans la forêt près d'Orléans, où l'été est beau.", [.windows1252])
    ]

    static func register() {
        let t = SelfTestRegistry.shared

        t.register("data.encoding", "every sample text in every plausible code page is detected correctly (Russian, Ukrainian, Latvian, Lithuanian, Czech, Polish, French)") {
            var wrong: [String] = []
            for s in samples {
                for e in s.encodings {
                    let bytes = TextEncodingKit.encode(s.text, as: e)
                    guard bytes.replaced == 0 else { continue }
                    let d = TextEncodingKit.decode(bytes.data)
                    if d.text != s.text { wrong.append("\(s.label) as \(e.displayName) -> \(d.encoding.displayName)") }
                }
            }
            try expect(wrong.isEmpty, "mis-detected: \(wrong.joined(separator: "; "))")
        }

        t.register("data.encoding", "short Cyrillic names (zip entries, titles) are still recognised") {
            for (text, e) in [("Привет мир.txt", DataEncoding.cp866), ("Договор.pdf", .windows1251), ("Отчёт за 2024 год.xlsx", .cp866), ("Фото отпуск.jpg", .windows1251)] {
                let b = TextEncodingKit.encode(text, as: e).data
                try expectEqual(TextEncodingKit.decode(b).text, text, "\(text) as \(e.displayName)")
            }
        }

        t.register("data.encoding", "BOMs, UTF-16 without BOM, strict UTF-8 and explicit overrides") {
            let text = "Žluťák — Привет, мир! 日本語"
            let u8 = TextEncodingKit.encode(text, as: .utf8, bom: true)
            let d8 = TextEncodingKit.decode(u8.data)
            try expectEqual(d8.text, text); try expect(d8.hadBOM && d8.encoding == .utf8)
            try expectEqual(TextEncodingKit.decode(TextEncodingKit.encode(text, as: .utf16).data).text, text)
            try expectEqual(TextEncodingKit.decode(TextEncodingKit.encode(text, as: .utf16be, bom: true).data).text, text)
            let noBOM = TextEncodingKit.encode("Name;Count\r\nHello;3\r\n", as: .utf16le).data
            try expectEqual(TextEncodingKit.decode(noBOM).encoding, .utf16le, "UTF-16 LE without BOM is recognised by its NUL bytes")
            try expectEqual(TextEncodingKit.decode(TextEncodingKit.encode(text, as: .utf8).data).encoding, .utf8)
            let forced = TextEncodingKit.decode(TextEncodingKit.encode("Привет", as: .windows1251).data, override: .koi8r)
            try expect(forced.text != "Привет" && forced.encoding == .koi8r, "an explicit override is honoured even when wrong")
            try expectEqual(TextEncodingKit.decode(Data("plain ascii".utf8)).encoding, .utf8)
        }

        t.register("data.encoding", "encoding to a code page reports characters it cannot represent") {
            let r = TextEncodingKit.encode("Привет Žluťák", as: .windows1251)
            try expectEqual(r.replaced, 3, "Ž, ť, á are not Cyrillic (the base letter is kept) and the count is reported")
            try expectEqual(TextEncodingKit.decodeSingleByte(r.data, .windows1251), "Привет Zlutak")
            try expectEqual(TextEncodingKit.encode("Rīga", as: .windows1257).replaced, 0)
        }

        t.register("data.encoding", "streaming decoder equals whole-file decode across arbitrary chunk boundaries") {
            let text = "Привет, мир! Žluťák 😀 Rīga\n" + String(repeating: "дальше ", count: 40)
            for e in [DataEncoding.utf8, .utf16le, .utf16be, .windows1251] {
                guard let data = Optional(TextEncodingKit.encode(text, as: e, bom: e.isUnicode)), data.replaced == 0 else { continue }
                for chunk in [1, 2, 3, 5, 7] {
                    let dec = TextStreamDecoder(encoding: e)
                    var out: [UInt8] = []
                    var i = 0
                    while i < data.data.count { out += dec.decode(data.data.subdata(in: i..<min(i + chunk, data.data.count))); i += chunk }
                    out += dec.finish()
                    try expectEqual(String(decoding: out, as: UTF8.self), text, "\(e.displayName), chunk \(chunk)")
                }
            }
        }
    }
}
