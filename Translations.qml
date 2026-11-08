import QtQuick
import Quickshell
import Quickshell.Io
import "Locale.js" as Locale

// Use one language source for text, digits and layout on every shell version.
// A native loader may choose English when our locale fallback chose another
// language, so do not layer its English catalog over the resolved local one.
QtObject {
  id: root
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config"
  readonly property var registry: Locale.parse(registryFile.text())
  readonly property string language: Locale.normalize(Quickshell.env("OMARCHY_YUBIKEY_LANGUAGE") || languageFile.text() ||
    Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANGUAGE") || Quickshell.env("LANG"), registry)
  readonly property string baseLanguage: language.split("-")[0]
  readonly property bool rightToLeft: (registry[language] || {}).direction === "rtl"
  readonly property var english: Locale.parse(englishFile.text())
  readonly property var baseStrings: Locale.parse(baseFile.text())
  readonly property var translated: Locale.parse(translatedFile.text())
  readonly property var fallbackPrompts: {
    try { return JSON.parse(fallbackFile.text() || "[]") } catch (error) { return [] }
  }

  function t(source, values) {
    var template = translated[source] || baseStrings[source] || english[source] || source
    return Locale.render(template, values)
  }

  function number(value) {
    var zero = (registry[language] || {}).zeroDigit || "0"
    return String(value).replace(/[0-9]/g, function(digit) { return String.fromCharCode(zero.charCodeAt(0) + Number(digit)) })
  }

  property FileView languageFile: FileView {
    path: Quickshell.env("OMARCHY_LANGUAGE_FILE") || root.configHome + "/omarchy/language"
    watchChanges: true; blockLoading: true; printErrors: false
    onFileChanged: reload()
  }
  property FileView registryFile: FileView {
    path: Qt.resolvedUrl("i18n/locales.json"); blockLoading: true; printErrors: false
  }
  property FileView englishFile: FileView {
    path: Qt.resolvedUrl("i18n/en.json"); blockLoading: true; printErrors: false
  }
  property FileView baseFile: FileView {
    path: root.baseLanguage !== root.language ? Qt.resolvedUrl("i18n/" + root.baseLanguage + ".json") : ""
    blockLoading: true; printErrors: false
  }
  property FileView translatedFile: FileView {
    path: root.language !== "en" ? Qt.resolvedUrl("i18n/" + root.language + ".json") : ""
    blockLoading: true; printErrors: false
  }
  property FileView fallbackFile: FileView {
    path: Qt.resolvedUrl("i18n/fallback-prompts.json"); blockLoading: true; printErrors: false
  }
}
