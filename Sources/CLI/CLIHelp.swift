import Foundation

/// The text of `swamp help [command]`. Localised; the command names and options stay in English.
enum CLIHelp {
    static func text(topic: CLICommand?) -> String {
        guard let topic else { return overview }
        switch topic {
        case .convert:
            return L("""
            swamp convert <files...> --op <id> [--preset <name>] [--set key=value ...] [--out <folder>] [--json]

            Converts or processes files with the same engine the wheel uses.
              --op <id>        the operation (list them: swamp list-ops). A target id such as image.convert, or a target format such as jpg, also works.
              --preset <name>  a built-in or saved preset (id or name); it supplies the options and the operation.
              --set k=v        one option, repeatable (discover the keys: swamp options <op>). Values are typed from the option: true/false, numbers, 1:30 for times, choices.
              --out <folder>   where the results go (default: the folder settings, usually next to the original).
            Without --set and --preset the result is exactly what the wheel makes. Folders and names with spaces or a leading dash work (put -- before such names).
            stdout: the paths of the results (or JSON Lines with --json). stderr: progress.
            """, """
            swamp convert <файлы...> --op <id> [--preset <имя>] [--set ключ=значение ...] [--out <папка>] [--json]

            Конвертирует или обрабатывает файлы тем же движком, что и колесо.
              --op <id>        операция (список: swamp list-ops). Подойдёт и id цели, например image.convert, и формат, например jpg.
              --preset <имя>   встроенный или сохранённый шаблон (id или имя); он задаёт параметры и операцию.
              --set к=з        один параметр, можно повторять (ключи: swamp options <op>). Значения приводятся к типу параметра: true/false, числа, 1:30 для времени, варианты выбора.
              --out <папка>    куда класть результат (по умолчанию как в настройках, обычно рядом с исходным файлом).
            Без --set и --preset результат тот же, что у колеса. Папки и имена с пробелами или дефисом в начале работают (перед такими именами поставьте --).
            stdout: пути результатов (или JSON Lines с --json). stderr: ход работы.
            """)
        case .download:
            return L("""
            swamp download <url> [--mode best|max|universal|audio-m4a|audio-mp3] [--out <folder>] [--set key=value ...] [--consent] [--json]

            Downloads a link with yt-dlp and, by default, converts it with "Best for Apple".
              --mode      the link wheel's sector (default: the mode in Settings > Downloader).
              --out       the folder for the files.
              --set k=v   any option of the download target (swamp options link.best).
              --consent   agree to the network use for this one run (otherwise agree once in the app).
            Exit 3 when yt-dlp is missing or consent is missing; the message says how to fix it. This is the only command that uses the network.
            Use it only for content you have the right to download; the terms of a site may restrict downloading.
            """, """
            swamp download <url> [--mode best|max|universal|audio-m4a|audio-mp3] [--out <папка>] [--set ключ=значение ...] [--consent] [--json]

            Скачивает ссылку через yt-dlp и по умолчанию конвертирует режимом «Лучшее для Apple».
              --mode      сектор колеса ссылок (по умолчанию режим из Настройки > Загрузка).
              --out       папка для файлов.
              --set к=з   любой параметр цели загрузки (swamp options link.best).
              --consent   согласиться на использование сети для этого запуска (иначе согласитесь один раз в приложении).
            Код 3, если нет yt-dlp или согласия; сообщение подскажет, что делать. Только эта команда использует сеть.
            Скачивайте только то, что вы вправе скачивать; условия сайта могут ограничивать загрузку.
            """)
        case .probe:
            return L("""
            swamp probe <file> [--json] [--plan]

            Shows what the app knows about a file: kind, facts (video.height, audio.0.codec ...), streams, warnings.
              --plan   for a video: the smart-transcode plan for Best for Apple, Maximum quality and Universal (lossless remux or re-encode, codecs, container).
            """, """
            swamp probe <файл> [--json] [--plan]

            Показывает, что приложение знает о файле: вид, факты (video.height, audio.0.codec ...), дорожки, замечания.
              --plan   для видео: план умной перекодировки для режимов «Лучшее для Apple», «Максимальное качество» и «Универсальный» (ремукс без потерь или перекодирование, кодеки, контейнер).
            """)
        case .listOps:
            return L("""
            swamp list-ops [--kind image|audio|video|pdf|document|slides|spreadsheet|subtitle|archive|ocr|download|app|convert|tools|actions|link] [--available] [--json]

            Lists every operation: id, wheel, label, whether it is available here (and why not), the target (schema) id, accepted inputs, usesNetwork.
            """, """
            swamp list-ops [--kind image|audio|video|pdf|document|slides|spreadsheet|subtitle|archive|ocr|download|app|convert|tools|actions|link] [--available] [--json]

            Список всех операций: id, колесо, название, доступна ли здесь (и почему нет), id цели (схемы), допустимые входные данные, usesNetwork.
            """)
        case .presets:
            return L("""
            swamp presets list [--target <schema id>] [--json]
            swamp presets show <id|name> [--json]
            swamp presets export <id|name> <file> [--force]
            swamp presets import <file>

            Presets are named sets of options for one target. Use one with: swamp convert <files> --preset <id|name>.
            """, """
            swamp presets list [--target <id схемы>] [--json]
            swamp presets show <id|имя> [--json]
            swamp presets export <id|имя> <файл> [--force]
            swamp presets import <файл>

            Шаблон — именованный набор параметров для одной цели. Применение: swamp convert <файлы> --preset <id|имя>.
            """)
        case .options:
            return L("""
            swamp options <operation> [--json]

            Prints every option of an operation: key, type, default, the value the wheel uses (quick), range or choices, the label. These keys go to --set.
            """, """
            swamp options <операция> [--json]

            Печатает все параметры операции: ключ, тип, значение по умолчанию, значение колеса (quick), диапазон или варианты, название. Эти ключи подходят для --set.
            """)
        case .version:
            return L("swamp version [--json]\n\nPrints the version (with --json: the tools found on this Mac).", "swamp version [--json]\n\nПечатает версию (с --json: найденные на этом Mac программы).")
        case .help:
            return overview
        }
    }

    static var overview: String {
        L("""
        swamp: the command line of Swamp Converter. The same engine as the wheel, headless.

          swamp convert <files...> --op <id> [--preset <name>] [--set key=value ...] [--out <folder>]
          swamp download <url> [--mode best|max|universal|audio-m4a|audio-mp3] [--out <folder>] [--consent]
          swamp probe <file> [--plan]
          swamp list-ops [--kind <kind>] [--available]
          swamp options <operation>
          swamp presets list|show|export|import
          swamp version | help [command]

        Everywhere: --json (JSON Lines on stdout), --pretty (indent JSON documents), --quiet, --verbose, --lang en|ru|system.
        Exit codes: 0 ok, 1 failed, 2 usage error, 3 unavailable (tool missing, consent needed, unsupported input), 4 partial (some files failed), 130 cancelled.
        stdout carries only the result; progress and messages go to stderr. Ctrl-C cancels and leaves no partial files.
        """, """
        swamp: командная строка Swamp Converter. Тот же движок, что у колеса, без окна.

          swamp convert <файлы...> --op <id> [--preset <имя>] [--set ключ=значение ...] [--out <папка>]
          swamp download <url> [--mode best|max|universal|audio-m4a|audio-mp3] [--out <папка>] [--consent]
          swamp probe <файл> [--plan]
          swamp list-ops [--kind <вид>] [--available]
          swamp options <операция>
          swamp presets list|show|export|import
          swamp version | help [команда]

        Везде: --json (JSON Lines в stdout), --pretty (отступы в JSON-документах), --quiet, --verbose, --lang en|ru|system.
        Коды выхода: 0 готово, 1 ошибка, 2 неверный вызов, 3 недоступно (нет программы, нужно согласие, файл не подходит), 4 частично (часть файлов не удалась), 130 отменено.
        В stdout только результат; ход работы и сообщения идут в stderr. Ctrl-C отменяет работу и не оставляет частичных файлов.
        """)
    }
}
