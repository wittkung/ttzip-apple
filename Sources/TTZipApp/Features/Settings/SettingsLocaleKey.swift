// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

#if canImport(TTI18nCore)
import TTI18nCore
#endif

/// Strongly-typed localization keys covering redesigned Settings panes across all 7 app languages.
public enum SettingsLocaleKey: String, TTZipCore.LocaleKeyProtocol, CaseIterable, Sendable {
    case generalSubtitle = "settings.redesign.general.subtitle"
    case localizationSubtitle = "settings.redesign.localization.subtitle"
    case presetsSubtitle = "settings.redesign.presets.subtitle"
    case vaultSubtitle = "settings.redesign.vault.subtitle"
    case licenseSubtitle = "settings.redesign.license.subtitle"

    case accentThemeTitle = "settings.redesign.accent.title"
    case accentThemeDesc = "settings.redesign.accent.desc"
    case accentBamboo = "settings.redesign.accent.bamboo"
    case accentGold = "settings.redesign.accent.gold"
    case accentAmber = "settings.redesign.accent.amber"
    case accentCinnabar = "settings.redesign.accent.cinnabar"
    case accentPurple = "settings.redesign.accent.purple"

    case fileAndPreviewHeader = "settings.redesign.file_preview.header"
    case softWrapTitle = "settings.redesign.soft_wrap.title"
    case softWrapDesc = "settings.redesign.soft_wrap.desc"

    case byteUnitsDesc = "settings.redesign.byte_units.desc"
    case byteUnitsPreviewLabel = "settings.redesign.byte_units.preview_label"

    case defaultFormatDesc = "settings.redesign.presets.default_format_desc"
    case defaultLevelTitle = "settings.redesign.presets.default_level_title"
    case defaultLevelDesc = "settings.redesign.presets.default_level_desc"
    case skipMacJunkDesc = "settings.redesign.presets.skip_mac_junk_desc"
    case openFinderDesc = "settings.redesign.presets.open_finder_desc"
    case savedPresetsHeader = "settings.redesign.presets.saved_header"
    case savedPresetsSummaryFormat = "settings.redesign.presets.saved_summary_format"
    case openPresetStudioAction = "settings.redesign.presets.open_studio"

    case vaultStatusHeader = "settings.redesign.vault.status_header"
    case vaultStateUnlocked = "settings.redesign.vault.state_unlocked"
    case vaultStateLocked = "settings.redesign.vault.state_locked"
    case vaultStateUninitialized = "settings.redesign.vault.state_uninitialized"
    case autoUnlockTitle = "settings.redesign.vault.auto_unlock_title"
    case autoUnlockDesc = "settings.redesign.vault.auto_unlock_desc"
    case savedCredentialsCountFormat = "settings.redesign.vault.credentials_count_format"
    case openVaultWorkspaceAction = "settings.redesign.vault.open_workspace"

    case localModelEnableToggleTitle = "settings.redesign.local_model.enable_title"
    case localModelEnableToggleDesc = "settings.redesign.local_model.enable_desc"

    case systemDiagnosticsHeader = "settings.redesign.system.diagnostics_header"
    case diagnosticsDesc = "settings.redesign.system.diagnostics_desc"
    case checkForUpdatesDesc = "settings.redesign.system.updates_desc"

    case masLicenseSubtitle = "settings.redesign.license.mas_subtitle"
    case steamEditionTitle = "settings.redesign.license.steam_title"
    case steamEditionSubtitle = "settings.redesign.license.steam_subtitle"
    case directProRegisteredFormat = "settings.redesign.license.direct_pro_format"
    case licenseDeactivatedNotice = "settings.redesign.license.deactivated_notice"
    case communityEditionTitle = "settings.redesign.license.community_title"
    case communityEditionSubtitle = "settings.redesign.license.community_subtitle"
    case communityEditionBadge = "settings.redesign.license.community_badge"
    case licenseKeyPrompt = "settings.redesign.license.key_prompt"

    public var rawKey: String { rawValue }

    public func translation(for language: TTZipCore.AppLanguage) -> String {
        guard let entry = SettingsLocaleCatalog.entries[self] else {
            return rawValue
        }
        return entry.value(for: language)
    }
}

#if canImport(TTI18nCore)
extension SettingsLocaleKey: FallbackLocaleKeyProtocol {
    public func fallbackTranslation(for language: TTI18nCore.AppLanguage) -> String {
        let mapped = TTZipCore.AppLanguage.from(identifier: language.bcp47) ?? .en
        return translation(for: mapped)
    }
}
#endif

private struct SettingsLocaleEntry: Sendable {
    let en: String
    let zhHans: String
    let zhHant: String
    let ja: String
    let de: String
    let fr: String
    let es: String

    func value(for language: TTZipCore.AppLanguage) -> String {
        switch language {
        case .en: return en
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        case .ja: return ja
        case .de: return de
        case .fr: return fr
        case .es: return es
        }
    }
}

private enum SettingsLocaleCatalog {
    static let entries: [SettingsLocaleKey: SettingsLocaleEntry] = [
        .generalSubtitle: .init(
            en: "Window appearance, mineral ambient tint, extraction conflicts, and text preview behavior.",
            zhHans: "窗口外观、流体矿物色相、解压冲突处理与文本预览习惯。",
            zhHant: "視窗外觀、流體礦物色相、解壓衝突處理與文本預覽習慣。",
            ja: "ウィンドウ外観、背景の鉱物カラー、展開時の競合処理、テキスト表示設定。",
            de: "Erscheinungsbild, Mineralfarben, Konfliktlösung beim Entpacken und Textumbruch.",
            fr: "Apparence des fenêtres, teinte minérale, conflits d’extraction et aperçu texte.",
            es: "Apariencia, tinte mineral del lienzo, conflictos al extraer y vista previa de texto."
        ),
        .localizationSubtitle: .init(
            en: "Instant interface language switching and byte size formatting standards.",
            zhHans: "实时切换应用界面语言，并配置容量字节的换算与显示标准。",
            zhHant: "即時切換應用介面語言，並配置容量位元組的換算與顯示標準。",
            ja: "表示言語の即時切り替えとデータ容量単位の表記基準を設定します。",
            de: "Sofortige Sprachumschaltung der Oberfläche und Byte-Einheitenstandard.",
            fr: "Changement instantané de langue et norme d’affichage des tailles en octets.",
            es: "Cambio instantáneo de idioma y estándar de formato para tamaños en bytes."
        ),
        .presetsSubtitle: .init(
            en: "Initial format, compression tier, cleanup flags for new archives, and custom presets.",
            zhHans: "配置新建压缩任务的默认格式、压缩强度、文件过滤与完成后动作。",
            zhHant: "配置建立壓縮任務的預設格式、壓縮強度、檔案過濾與完成後動作。",
            ja: "新規アーカイブ作成時の標準形式、圧縮レベル、除外設定およびプリセット。",
            de: "Standardformat, Kompressionsstufe, macOS-Filter und gespeicherte Voreinstellungen.",
            fr: "Format initial, niveau de compression, filtres macOS et préréglages enregistrés.",
            es: "Formato inicial, nivel de compresión, filtros de macOS y preajustes guardados."
        ),
        .vaultSubtitle: .init(
            en: "Automatic archive decryption preferences, live lock status, and vault encryption specs.",
            zhHans: "管理压缩包自动解锁偏好、当前钥匙串锁定状态与本地加密规格。",
            zhHant: "管理壓縮檔自動解鎖偏好、目前鑰匙圈鎖定狀態與本地加密規格。",
            ja: "暗号化アーカイブの自動解除設定、現在のロック状態、暗号化仕様。",
            de: "Automatisches Entsperren von Archiven, aktueller Tresorstatus und Verschlüsselung.",
            fr: "Déverrouillage automatique des archives, état actuel du coffre et chiffrement.",
            es: "Desbloqueo automático de archivos, estado actual del almacén y cifrado."
        ),
        .licenseSubtitle: .init(
            en: "Edition license status, Apple Silicon topology, software updates, and log diagnostics.",
            zhHans: "查看当前发行版授权状态、Apple Silicon 硬件拓扑与系统诊断日志。",
            zhHant: "檢視目前發行版授權狀態、Apple Silicon 硬體拓樸與系統診斷日誌。",
            ja: "ライセンス状態、Apple Silicon 構成、アップデート確認と診断ログ。",
            de: "Lizenzstatus, Apple-Silicon-Topologie, Updates und Diagnoseprotokolle.",
            fr: "Statut de licence, topologie Apple Silicon, mises à jour et journaux système.",
            es: "Estado de licencia, topología de Apple Silicon, actualizaciones y diagnóstico."
        ),
        .accentThemeTitle: .init(
            en: "Mineral Canvas Accent",
            zhHans: "流体矿物色相",
            zhHant: "流體礦物色相",
            ja: "背景の鉱物カラー",
            de: "Mineralfarbe des Hintergrunds",
            fr: "Teinte minérale du fond",
            es: "Tinte mineral del fondo"
        ),
        .accentThemeDesc: .init(
            en: "Sets the ambient fluid pigment applied across browser and preview windows.",
            zhHans: "控制主窗口与浏览画布的背景矿物色彩风格。",
            zhHant: "控制主視窗與瀏覽畫布的背景礦物色彩風格。",
            ja: "ファイルブラウザーやウィンドウ全体の流体背景カラーを切り替えます。",
            de: "Legt den umgebenden Mineralfarbton für alle Hauptfenster fest.",
            fr: "Définit la teinte minérale ambiante appliquée aux fenêtres.",
            es: "Define el pigmento ambiental aplicado en todas las ventanas."
        ),
        .accentBamboo: .init(
            en: "Bamboo", zhHans: "翠竹", zhHant: "翠竹",
            ja: "竹緑", de: "Bambus", fr: "Bambou", es: "Bambú"
        ),
        .accentGold: .init(
            en: "Kintsugi Gold", zhHans: "金缮", zhHant: "金繕",
            ja: "金継ぎ", de: "Kintsugi-Gold", fr: "Or Kintsugi", es: "Oro Kintsugi"
        ),
        .accentAmber: .init(
            en: "Amber", zhHans: "琥珀", zhHant: "琥珀",
            ja: "琥珀", de: "Bernstein", fr: "Ambre", es: "Ámbar"
        ),
        .accentCinnabar: .init(
            en: "Cinnabar", zhHans: "朱砂", zhHant: "朱砂",
            ja: "朱色", de: "Zinnober", fr: "Cinabre", es: "Cinabrio"
        ),
        .accentPurple: .init(
            en: "Amethyst", zhHans: "紫晶", zhHant: "紫晶",
            ja: "紫水晶", de: "Amethyst", fr: "Améthyste", es: "Amatista"
        ),
        .fileAndPreviewHeader: .init(
            en: "File Handling & Preview",
            zhHans: "文件操作与预览",
            zhHant: "檔案操作與預覽",
            ja: "ファイル処理とプレビュー",
            de: "Dateiverarbeitung & Vorschau",
            fr: "Gestion de fichiers et aperçu",
            es: "Manejo de archivos y vista previa"
        ),
        .softWrapTitle: .init(
            en: "Soft Wrap in Text & Code Previews",
            zhHans: "文本与代码预览自动换行",
            zhHant: "文本與程式碼預覽自動換行",
            ja: "テキストとコードプレビューの自動折り返し",
            de: "Zeilenumbruch in Text- und Codevorschau",
            fr: "Retour à la ligne dans l’aperçu texte et code",
            es: "Ajuste de línea en texto y código"
        ),
        .softWrapDesc: .init(
            en: "Wraps long lines inside plain text, source code, and raw Markdown viewers.",
            zhHans: "开启后，超长文本或代码行将按窗口宽度折行显示，无需横向滚动。",
            zhHant: "開啟後，過長文本或程式碼行將依視窗寬度折行顯示，無需橫向捲動。",
            ja: "長い行をウィンドウ幅に合わせて折り返して表示します。",
            de: "Bricht lange Zeilen in Text-, Quellcode- und rohen Markdown-Ansichten um.",
            fr: "Adapte les lignes longues à la largeur de la fenêtre dans les aperçus.",
            es: "Ajusta las líneas largas al ancho de la ventana sin desplazamiento horizontal."
        ),
        .byteUnitsDesc: .init(
            en: "Controls whether archive and file sizes use decimal SI (1000) or binary IEC (1024) units.",
            zhHans: "决定归档体积与文件列表采用十进制（1000）还是二进制（1024）换算。",
            zhHant: "決定歸檔體積與檔案列表採用十進位（1000）還是二進位（1024）換算。",
            ja: "ファイル容量を10進数 SI (1000) または 2進数 IEC (1024) のどちらで表記するか選択します。",
            de: "Bestimmt, ob Größen im Dezimalsystem (SI, 1000) oder Binärsystem (IEC, 1024) angezeigt werden.",
            fr: "Définit l’affichage des tailles en base décimale SI (1000) ou binaire IEC (1024).",
            es: "Define si los tamaños usan base decimal SI (1000) o binaria IEC (1024)."
        ),
        .byteUnitsPreviewLabel: .init(
            en: "Live Formatting Example",
            zhHans: "实时格式预览",
            zhHant: "即時格式預覽",
            ja: "表示プレビュー",
            de: "Live-Formatvorschau",
            fr: "Aperçu en direct",
            es: "Vista previa en tiempo real"
        ),
        .defaultFormatDesc: .init(
            en: "Pre-selected format when starting a new compression workspace session.",
            zhHans: "每次新建压缩任务工作区时自动选中的初始归档容器格式。",
            zhHant: "每次建立壓縮任務工作區時自動選取的初始歸檔容器格式。",
            ja: "新規圧縮セッション開始時に既定で選択されるアーカイブ形式です。",
            de: "Vorausgewähltes Format beim Start einer neuen Komprimierungssitzung.",
            fr: "Format présélectionné à l’ouverture d’une nouvelle session de compression.",
            es: "Formato preseleccionado al iniciar una nueva sesión de compresión."
        ),
        .defaultLevelTitle: .init(
            en: "Default Compression Level",
            zhHans: "默认压缩级别",
            zhHant: "預設壓縮層級",
            ja: "標準圧縮レベル",
            de: "Standard-Kompressionsstufe",
            fr: "Niveau de compression par défaut",
            es: "Nivel de compresión predeterminado"
        ),
        .defaultLevelDesc: .init(
            en: "Initial speed-vs-ratio tier applied to new tasks and clamped to format limits.",
            zhHans: "决定新建压缩任务时的默认速度与压缩率档位，并自动适配所选格式范围。",
            zhHant: "決定建立壓縮任務時的預設速度與壓縮率檔位，並自動適配所選格式範圍。",
            ja: "新規タスクの初期速度・圧縮率プリセットです（形式ごとの上限に自動調整）。",
            de: "Anfangsstufe für das Verhältnis aus Geschwindigkeit und Größe neuer Archive.",
            fr: "Palier initial entre vitesse et taux de compression pour les nouvelles tâches.",
            es: "Equilibrio inicial entre velocidad y compresión adaptado a cada formato."
        ),
        .skipMacJunkDesc: .init(
            en: "Excludes .DS_Store and AppleDouble (._*) metadata files when packing folders.",
            zhHans: "打包目录时自动过滤 .DS_Store 与 AppleDouble (._*) 系统元数据文件。",
            zhHant: "打包目錄時自動過濾 .DS_Store 與 AppleDouble (._*) 系統中繼資料檔案。",
            ja: "圧縮時に .DS_Store や AppleDouble (._*) メタデータを自動的に除外します。",
            de: "Schließt .DS_Store- und AppleDouble-(._*)-Metadatendateien beim Packen aus.",
            fr: "Exclut les fichiers .DS_Store et AppleDouble (._*) lors de la création d’archives.",
            es: "Excluye archivos .DS_Store y metadatos AppleDouble (._*) al empaquetar."
        ),
        .openFinderDesc: .init(
            en: "Reveals the newly created archive in Finder when compression completes.",
            zhHans: "压缩完成后自动在访达中定位并高亮显示生成的归档文件。",
            zhHant: "壓縮完成後自動在 Finder 中定位並顯示產生的歸檔檔案。",
            ja: "圧縮完了後に Finder で生成されたアーカイブを選択表示します。",
            de: "Zeigt das neu erstellte Archiv nach Abschluss direkt im Finder an.",
            fr: "Affiche l’archive créée dans le Finder une fois la compression terminée.",
            es: "Muestra el archivo resultante en el Finder al completar la compresión."
        ),
        .savedPresetsHeader: .init(
            en: "Custom Preset Profiles",
            zhHans: "自定义配置方案",
            zhHant: "自訂配置方案",
            ja: "カスタムプリセット",
            de: "Benutzerdefinierte Profile",
            fr: "Profils de préréglages",
            es: "Perfiles de preajuste"
        ),
        .savedPresetsSummaryFormat: .init(
            en: "%d saved preset profile(s) available across the compression workspace",
            zhHans: "当前共有 %d 个已保存配置，可在压缩工作区与管理面板中一键复用",
            zhHant: "目前共有 %d 個已儲存配置，可在壓縮工作區與管理面板中一鍵複用",
            ja: "%d 件の保存済みプリセットを圧縮ワークスペースで利用できます",
            de: "%d gespeicherte Voreinstellung(en) im Komprimierungsbereich verfügbar",
            fr: "%d profil(s) enregistré(s) disponible(s) dans l’espace de compression",
            es: "%d perfil(es) guardado(s) disponible(s) en el área de compresión"
        ),
        .openPresetStudioAction: .init(
            en: "Manage Presets…",
            zhHans: "管理预设…",
            zhHant: "管理預設…",
            ja: "プリセットを管理…",
            de: "Voreinstellungen…",
            fr: "Gérer les préréglages…",
            es: "Gestionar preajustes…"
        ),
        .vaultStatusHeader: .init(
            en: "Vault Status & Auto-Unlock",
            zhHans: "保险库状态与自动解锁",
            zhHant: "保險庫狀態與自動解鎖",
            ja: "キーチェーン状態と自動解除",
            de: "Tresorstatus & Auto-Entsperrung",
            fr: "État du coffre et déverrouillage",
            es: "Estado del almacén y desbloqueo"
        ),
        .vaultStateUnlocked: .init(
            en: "Unlocked", zhHans: "已解锁", zhHant: "已解鎖",
            ja: "ロック解除済み", de: "Entsperrt", fr: "Déverrouillé", es: "Desbloqueado"
        ),
        .vaultStateLocked: .init(
            en: "Locked", zhHans: "已锁定", zhHant: "已鎖定",
            ja: "ロック中", de: "Gesperrt", fr: "Verrouillé", es: "Bloqueado"
        ),
        .vaultStateUninitialized: .init(
            en: "Not Set Up", zhHans: "未设置主密码", zhHant: "未設定主密碼",
            ja: "未設定", de: "Nicht eingerichtet", fr: "Non configuré", es: "Sin configurar"
        ),
        .autoUnlockTitle: .init(
            en: "Auto-Unlock Encrypted Archives",
            zhHans: "自动解锁加密归档",
            zhHant: "自動解鎖加密歸檔",
            ja: "暗号化アーカイブを自動解除",
            de: "Verschlüsselte Archive automatisch entsperren",
            fr: "Déverrouiller automatiquement les archives chiffrées",
            es: "Desbloquear archivos cifrados automáticamente"
        ),
        .autoUnlockDesc: .init(
            en: "Automatically tests saved Vault passwords before prompting when opening encrypted files.",
            zhHans: "开启加密归档时，优先尝试密码保险库中已解锁的常用凭证，失败后再提示输入。",
            zhHant: "開啟加密歸檔時，優先嘗試密碼保險庫中已解鎖的常用憑證，失敗後再提示輸入。",
            ja: "暗号化ファイルを開く際、パスワード入力を求める前に保存済み候補を自動で試します。",
            de: "Probiert beim Öffnen verschlüsselter Dateien zuerst gespeicherte Passwörter aus.",
            fr: "Teste automatiquement les mots de passe enregistrés avant de demander la saisie.",
            es: "Prueba automáticamente las contraseñas guardadas antes de mostrar el aviso."
        ),
        .savedCredentialsCountFormat: .init(
            en: "%d credential(s) loaded in volatile memory",
            zhHans: "当前内存中已载入 %d 条保险库密码记录",
            zhHant: "目前記憶體中已載入 %d 筆保險庫密碼記錄",
            ja: "揮発性メモリに %d 件の認証情報が読み込まれています",
            de: "%d Zugangsdaten im flüchtigen Speicher geladen",
            fr: "%d identifiant(s) chargé(s) en mémoire volatile",
            es: "%d credencial(es) cargada(s) en memoria volátil"
        ),
        .openVaultWorkspaceAction: .init(
            en: "Open Vault…",
            zhHans: "打开保险库…",
            zhHant: "開啟保險庫…",
            ja: "金庫を開く…",
            de: "Tresor öffnen…",
            fr: "Ouvrir le coffre…",
            es: "Abrir almacén…"
        ),
        .localModelEnableToggleTitle: .init(
            en: "Enable Optional Gemma Component",
            zhHans: "启用 Gemma 可选组件",
            zhHant: "啟用 Gemma 可選元件",
            ja: "オプションの Gemma コンポーネントを有効化",
            de: "Optionale Gemma-Komponente aktivieren",
            fr: "Activer le composant optionnel Gemma",
            es: "Activar componente opcional Gemma"
        ),
        .localModelEnableToggleDesc: .init(
            en: "Off by default. Downloading only installs model files; enabling loads them for semantic indexing.",
            zhHans: "默认关闭。下载只将模型存入磁盘；开启开关后才会载入运行时并执行语义索引。",
            zhHant: "預設關閉。下載只將模型存入磁碟；開啟開關後才會載入執行階段並執行語義索引。",
            ja: "既定ではオフです。ダウンロード後は有効にした場合のみモデルを読み込みます。",
            de: "Standardmäßig deaktiviert. Erst das Aktivieren lädt das Modell für semantische Suche.",
            fr: "Désactivé par défaut. Le téléchargement installe les fichiers sans les charger.",
            es: "Desactivado por defecto. Solo se carga al activar el interruptor."
        ),
        .systemDiagnosticsHeader: .init(
            en: "Diagnostics & Updates",
            zhHans: "诊断报告与版本更新",
            zhHant: "診斷報告與版本更新",
            ja: "診断レポートとアップデート",
            de: "Diagnose & Updates",
            fr: "Diagnostics et mises à jour",
            es: "Diagnóstico y actualizaciones"
        ),
        .diagnosticsDesc: .init(
            en: "Inspect runtime logs or package an anonymized diagnostic archive on your Desktop.",
            zhHans: "在访达中查看运行日志目录，或于桌面打包系统诊断压缩包。",
            zhHant: "在 Finder 中檢視執行日誌目錄，或於桌面打包系統診斷壓縮檔。",
            ja: "動作ログを Finder で開くか、デスクトップへ診断アーカイブを書き出します。",
            de: "Protokolle im Finder öffnen oder ein Diagnosearchiv auf dem Schreibtisch sichern.",
            fr: "Afficher les journaux dans le Finder ou exporter une archive de diagnostic.",
            es: "Muestra los registros en Finder o exporta un paquete de diagnóstico al Escritorio."
        ),
        .checkForUpdatesDesc: .init(
            en: "Check for new direct-distribution releases.",
            zhHans: "检查独立分发版是否有新版本可用。",
            zhHant: "檢查獨立發佈版是否有新版本可用。",
            ja: "直接配布版の最新アップデートを確認します。",
            de: "Auf neue Updates der Direktversion prüfen.",
            fr: "Vérifier la disponibilité de mises à jour pour la version directe.",
            es: "Buscar nuevas versiones disponibles para descarga directa."
        ),
        .masLicenseSubtitle: .init(
            en: "Pro Lifetime License · Apple Sandbox Protection Active",
            zhHans: "Pro 终身许可证 · Apple 沙盒防护已启用",
            zhHant: "Pro 終身許可證 · Apple 沙盒防護已啟用",
            ja: "Pro 永続ライセンス · Apple サンドボックス保護有効",
            de: "Pro-Lebenszeitlizenz · Apple-Sandbox-Schutz aktiv",
            fr: "Licence Pro à vie · Protection bac à sable Apple active",
            es: "Licencia Pro vitalicia · Protección de entorno aislado de Apple activa"
        ),
        .steamEditionTitle: .init(
            en: "Steam Store Edition",
            zhHans: "Steam 商店版",
            zhHant: "Steam 商店版",
            ja: "Steam ストア版",
            de: "Steam-Store-Edition",
            fr: "Édition Steam Store",
            es: "Edición de Steam Store"
        ),
        .steamEditionSubtitle: .init(
            en: "Pro Lifetime License · Steam Verified & DRM-Free",
            zhHans: "Pro 终身许可证 · Steam 正版验证",
            zhHant: "Pro 終身許可證 · Steam 正版驗證",
            ja: "Pro 永続ライセンス · Steam 認証済み (DRM フリー)",
            de: "Pro-Lebenszeitlizenz · Steam-verifiziert & DRM-frei",
            fr: "Licence Pro à vie · Vérifiée par Steam et sans DRM",
            es: "Licencia Pro vitalicia · Verificada por Steam y sin DRM"
        ),
        .directProRegisteredFormat: .init(
            en: "Registered to %@ · Order %@",
            zhHans: "注册邮箱 %@ · 订单号 %@",
            zhHant: "註冊郵箱 %@ · 訂單號 %@",
            ja: "登録先 %@ · 注文番号 %@",
            de: "Registriert für %@ · Bestellung %@",
            fr: "Enregistré pour %@ · Commande %@",
            es: "Registrado a %@ · Pedido %@"
        ),
        .licenseDeactivatedNotice: .init(
            en: "Deactivated. Reverted to Community Edition.",
            zhHans: "已取消激活，已恢复至社区版。",
            zhHant: "已取消啟用，已恢復至社群版。",
            ja: "ライセンスを解除し、コミュニティ版に戻りました。",
            de: "Deaktiviert. Auf die Community-Edition zurückgesetzt.",
            fr: "Désactivée. Retour à l’édition communautaire.",
            es: "Desactivada. Se ha restablecido la edición comunitaria."
        ),
        .communityEditionTitle: .init(
            en: "Community Edition",
            zhHans: "社区版",
            zhHant: "社群版",
            ja: "コミュニティ版",
            de: "Community-Edition",
            fr: "Édition communautaire",
            es: "Edición comunitaria"
        ),
        .communityEditionSubtitle: .init(
            en: "All core archiving and compression capabilities are 100% unrestricted.",
            zhHans: "全部核心归档与压缩解压功能均完整开放、无限制使用。",
            zhHant: "全部核心歸檔與壓縮解壓功能均完整開放、無限制使用。",
            ja: "すべての基本圧縮・展開機能は制限なく完全にご利用いただけます。",
            de: "Alle Kernfunktionen zum Archivieren und Entpacken sind uneingeschränkt nutzbar.",
            fr: "Toutes les fonctions principales de compression et d’extraction sont sans restriction.",
            es: "Todas las funciones principales de compresión y extracción están sin restricciones."
        ),
        .communityEditionBadge: .init(
            en: "Free & Open Source",
            zhHans: "免费版",
            zhHant: "免費版",
            ja: "無料・オープンソース",
            de: "Kostenlos & Open Source",
            fr: "Gratuit et open source",
            es: "Gratuita y de código abierto"
        ),
        .licenseKeyPrompt: .init(
            en: "Enter Ed25519 License Key (TTZIP1-...) to unlock Pro badge & priority support:",
            zhHans: "输入 Ed25519 许可证密钥 (TTZIP1-...) 解锁 Pro 徽章与优先支持：",
            zhHant: "輸入 Ed25519 許可證金鑰 (TTZIP1-...) 解鎖 Pro 徽章與優先支援：",
            ja: "Ed25519 ライセンスキー (TTZIP1-...) を入力して Pro バッジを有効化：",
            de: "Ed25519-Lizenzschlüssel (TTZIP1-...) eingeben, um das Pro-Abzeichen zu aktivieren:",
            fr: "Saisissez une clé Ed25519 (TTZIP1-...) pour débloquer le badge Pro :",
            es: "Introduce la clave de licencia Ed25519 (TTZIP1-...) para activar la insignia Pro:"
        ),
    ]
}
