# DMS für macOS

Ein lokales Datenmanagement-System für den Mac, das über den Finder hinausgeht. Die App legt einen Index über deine Ordner auf dem Mac, auf dem Synology-NAS (CAWServer) und im Google-Drive-Ordner. Die Dateien bleiben dabei, wo sie sind. Alles läuft lokal, kein Inhalt verlässt den Mac.

Konzept: siehe das Konzeptdokument im Projekt.

## Stand: Schritt 2 (Grundgerüst)

- Quellen einbinden: Ordner auf dem Mac, NAS-Freigaben (werden beim Start bei Bedarf neu verbunden) und den Google-Drive-Ordner. Die Art wird automatisch erkannt.
- Scan und Index in einer lokalen SQLite-Datenbank (`~/Library/Application Support/DMS/dms.sqlite`).
- Änderungen auf dem Mac und in Google Drive werden sofort erkannt, das NAS wird stündlich abgeglichen.
- Volltextsuche über Dateinamen, Inhalt und Tags, mit Textausschnitt im Treffer.
- Text aus PDF, Word (.docx, .doc), Excel (.xlsx), PowerPoint (.pptx), RTF, Text und Code.
- OCR (Deutsch und Englisch) für Bilder und gescannte PDFs.
- Google Drive im Modus „Streamen“: Dateien, die nur online liegen, werden nur mit Namen erfasst und nicht heruntergeladen.
- Vorschau mit QuickLook, Öffnen, Im Finder zeigen.
- Tags für eine oder mehrere Dateien. Tags werden als Finder-Tags gespiegelt, vorhandene Finder-Tags werden übernommen.
- Dashboard: belegter und freier Speicher je Quelle, Dateitypen nach Größe.
- Standard-Apps pro Dateityp ändern.

Noch nicht enthalten (Schritte 3 und 4): Dubletten, Ablagevorschläge, Regeln, Versionen, lokale KI.

## Starten

Voraussetzung: macOS 15 oder neuer, Xcode.

1. Repository klonen oder herunterladen.
2. In Xcode: *File > Open …* und den Ordner `dms-mac` wählen (Xcode erkennt `Package.swift`).
3. Oben als Ziel „DMS“ und „My Mac“ wählen, dann *Product > Run* (⌘R).

Alternativ im Terminal: `swift run DMS`. Tests: `swift test`.

Beim ersten Zugriff auf Ordner wie Dokumente oder Schreibtisch fragt macOS um Erlaubnis. Für NAS-Freigaben werden die Zugangsdaten aus dem Schlüsselbund verwendet.
