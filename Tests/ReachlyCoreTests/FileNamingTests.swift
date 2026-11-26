import Foundation
import Testing
@testable import ReachlyCore

@Suite struct FileNamingTests {
    // MARK: validationError

    @Test func ordinaryNamesAreValid() {
        for name in ["report.txt", ".env", "a", "My Folder", "archive.tar.gz", " leading space", "naïve résumé.md", "...dots"] {
            #expect(FileNaming.validationError(for: name) == nil, "\(name)")
        }
    }

    @Test func emptyAndBlankNamesAreRejected() {
        #expect(FileNaming.validationError(for: "") == "Enter a name.")
        #expect(FileNaming.validationError(for: "   ") == "Enter a name.")
        #expect(FileNaming.validationError(for: "\t\n") == "Enter a name.")
    }

    @Test func dotAndDotDotAreRejected() {
        #expect(FileNaming.validationError(for: ".") != nil)
        #expect(FileNaming.validationError(for: "..") != nil)
        #expect(FileNaming.validationError(for: "...") == nil)
    }

    @Test func slashesAreRejected() {
        #expect(FileNaming.validationError(for: "a/b") == "Names can't contain a slash.")
        #expect(FileNaming.validationError(for: "/") == "Names can't contain a slash.")
        #expect(FileNaming.validationError(for: "trailing/") == "Names can't contain a slash.")
    }

    @Test func nulIsRejected() {
        #expect(FileNaming.validationError(for: "a\u{0}b") == "Names can't contain a null character.")
    }

    @Test func namesOver255BytesAreRejected() {
        #expect(FileNaming.validationError(for: String(repeating: "a", count: 255)) == nil)
        #expect(FileNaming.validationError(for: String(repeating: "a", count: 256)) == "That name is too long.")
        // Bytes, not characters: 128 two-byte letters are 256 bytes.
        #expect(FileNaming.validationError(for: String(repeating: "é", count: 127)) == nil)
        #expect(FileNaming.validationError(for: String(repeating: "é", count: 128)) == "That name is too long.")
    }

    @Test func messagesAreShortSentences() {
        for name in ["", ".", "a/b", "a\u{0}", String(repeating: "x", count: 300)] {
            let message = FileNaming.validationError(for: name) ?? ""
            #expect(message.hasSuffix("."), "\(name)")
            #expect(message.count < 60, "\(name)")
        }
    }

    // MARK: pathComponentError

    @Test func namesThatCantStandForOneItemAreRefused() {
        #expect(FileNaming.pathComponentError(for: "") == "The name is empty.")
        #expect(FileNaming.pathComponentError(for: "..") != nil)
        #expect(FileNaming.pathComponentError(for: "../x") == "Names can't contain a slash.")
        #expect(FileNaming.pathComponentError(for: "a\u{0}") == "Names can't contain a null character.")
        #expect(FileNaming.pathComponentError(for: String(repeating: "a", count: 256)) == "That name is too long.")
    }

    @Test func blankNamesStandForOneItem() {
        // Unusual, but each names exactly one file in its folder.
        #expect(FileNaming.pathComponentError(for: " ") == nil)
        #expect(FileNaming.pathComponentError(for: "\t") == nil)
        #expect(FileNaming.pathComponentError(for: "report.txt") == nil)
    }

    @Test func displayedNamesHideControlCharactersAndStayShort() {
        #expect(FileNaming.displayed("a\u{0}b\nc") == "a\u{FFFD}b\u{FFFD}c")
        #expect(FileNaming.displayed("../x") == "../x")
        let long = FileNaming.displayed(String(repeating: "x", count: 300))
        #expect(long.count == 61 && long.hasSuffix("…"))
    }

    @Test func displayedNamesCantReorderOrBreakTheTextAroundThem() {
        // "invoice\u{202E}fdp.exe" would read as "invoiceexe.pdf".
        #expect(FileNaming.displayed("invoice\u{202E}fdp.exe") == "invoice\u{FFFD}fdp.exe")
        let disguising: [Unicode.Scalar] = [
            "\u{061C}", "\u{200E}", "\u{200F}", "\u{2028}", "\u{2029}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        ]
        for scalar in disguising {
            #expect(FileNaming.displayed("a\(scalar)b") == "a\u{FFFD}b", "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
        // Right-to-left letters, accents and emoji built with joiners are names like any other.
        for name in ["שלום.txt", "ملف.txt", "e\u{301}te\u{301}.txt", "👨‍👩‍👧 photos", "日本語"] {
            #expect(FileNaming.displayed(name) == name)
        }
    }

    // MARK: copyName

    @Test func fileCopiesKeepTheExtension() {
        #expect(FileNaming.copyName(for: "report.txt", isDirectory: false, existing: ["report.txt"]) == "report copy.txt")
        #expect(FileNaming.copyName(for: "report.txt", isDirectory: false, existing: ["report.txt", "report copy.txt"]) == "report copy 2.txt")
        #expect(FileNaming.copyName(for: "report.txt", isDirectory: false, existing: ["report.txt", "report copy.txt", "report copy 2.txt"]) == "report copy 3.txt")
    }

    @Test func manyClashesCountUp() {
        var existing: Set<String> = ["report.txt", "report copy.txt"]
        for number in 2...40 { existing.insert("report copy \(number).txt") }
        #expect(FileNaming.copyName(for: "report.txt", isDirectory: false, existing: existing) == "report copy 41.txt")
        // A gap is filled first.
        existing.remove("report copy 7.txt")
        #expect(FileNaming.copyName(for: "report.txt", isDirectory: false, existing: existing) == "report copy 7.txt")
    }

    @Test func foldersAndNamesWithoutAnExtension() {
        #expect(FileNaming.copyName(for: "src", isDirectory: true, existing: ["src"]) == "src copy")
        #expect(FileNaming.copyName(for: "src", isDirectory: true, existing: ["src", "src copy"]) == "src copy 2")
        #expect(FileNaming.copyName(for: "Makefile", isDirectory: false, existing: ["Makefile"]) == "Makefile copy")
        #expect(FileNaming.copyName(for: "Makefile", isDirectory: false, existing: ["Makefile", "Makefile copy"]) == "Makefile copy 2")
    }

    @Test func foldersAreNeverSplitAtADot() {
        #expect(FileNaming.copyName(for: "photos.2024", isDirectory: true, existing: []) == "photos.2024 copy")
        #expect(FileNaming.copyName(for: "photos.2024", isDirectory: false, existing: []) == "photos copy.2024")
    }

    @Test func dotfilesKeepTheirDot() {
        #expect(FileNaming.copyName(for: ".env", isDirectory: false, existing: [".env"]) == ".env copy")
        #expect(FileNaming.copyName(for: ".env", isDirectory: false, existing: [".env", ".env copy"]) == ".env copy 2")
        #expect(FileNaming.copyName(for: ".config", isDirectory: true, existing: [".config"]) == ".config copy")
        #expect(FileNaming.copyName(for: ".env.local", isDirectory: false, existing: []) == ".env copy.local")
        #expect(FileNaming.copyName(for: "..hidden", isDirectory: false, existing: []) == "..hidden copy")
    }

    @Test func compoundTarExtensionsStayTogether() {
        #expect(FileNaming.copyName(for: "archive.tar.gz", isDirectory: false, existing: ["archive.tar.gz"]) == "archive copy.tar.gz")
        #expect(FileNaming.copyName(for: "archive.tar.gz", isDirectory: false, existing: ["archive copy.tar.gz"]) == "archive copy 2.tar.gz")
        #expect(FileNaming.copyName(for: "backup.TAR.xz", isDirectory: false, existing: []) == "backup copy.TAR.xz")
        #expect(FileNaming.copyName(for: "site.tar", isDirectory: false, existing: []) == "site copy.tar")
    }

    @Test func severalDotsUseTheLastOne() {
        #expect(FileNaming.copyName(for: "my.report.txt", isDirectory: false, existing: []) == "my.report copy.txt")
        #expect(FileNaming.copyName(for: "jquery.min.js", isDirectory: false, existing: []) == "jquery.min copy.js")
        #expect(FileNaming.copyName(for: "v1.2.3", isDirectory: false, existing: []) == "v1.2 copy.3")
    }

    @Test func oddDotsAreNotExtensions() {
        #expect(FileNaming.copyName(for: "file.", isDirectory: false, existing: []) == "file. copy")
        #expect(FileNaming.copyName(for: "notes.final draft", isDirectory: false, existing: []) == "notes.final draft copy")
    }

    @Test func copyingACopyDoesNotStackCopy() {
        #expect(FileNaming.copyName(for: "report copy.txt", isDirectory: false, existing: ["report.txt", "report copy.txt"]) == "report copy 2.txt")
        #expect(FileNaming.copyName(for: "report copy 2.txt", isDirectory: false, existing: ["report.txt", "report copy.txt", "report copy 2.txt"]) == "report copy 3.txt")
        #expect(FileNaming.copyName(for: "src copy", isDirectory: true, existing: ["src", "src copy"]) == "src copy 2")
        #expect(FileNaming.copyName(for: "archive copy.tar.gz", isDirectory: false, existing: ["archive copy.tar.gz"]) == "archive copy 2.tar.gz")
        #expect(FileNaming.copyName(for: ".env copy", isDirectory: false, existing: [".env copy"]) == ".env copy 2")
    }

    @Test func copyLikeWordsThatAreNotACopySuffixStay() {
        // "copy" alone, "copy 1", "copy 02" and "copy x" are part of the name, not a suffix Reachly added.
        #expect(FileNaming.copyName(for: "copy.txt", isDirectory: false, existing: ["copy.txt"]) == "copy copy.txt")
        #expect(FileNaming.copyName(for: "photocopy.txt", isDirectory: false, existing: []) == "photocopy copy.txt")
        #expect(FileNaming.copyName(for: "report copy 1.txt", isDirectory: false, existing: []) == "report copy 1 copy.txt")
        #expect(FileNaming.copyName(for: "report copy 02.txt", isDirectory: false, existing: []) == "report copy 02 copy.txt")
        #expect(FileNaming.copyName(for: "report copy x.txt", isDirectory: false, existing: []) == "report copy x copy.txt")
        #expect(FileNaming.copyName(for: " copy", isDirectory: true, existing: []) == " copy copy")
    }

    @Test func copyNamesIgnoreLetterCaseWhenLookingForAFreeName() {
        #expect(FileNaming.copyName(for: "Report.txt", isDirectory: false, existing: ["REPORT COPY.TXT"]) == "Report copy 2.txt")
    }

    @Test func copyNamesStayWithinTheLengthLimit() {
        let long = String(repeating: "a", count: 251) + ".txt"
        let copy = FileNaming.copyName(for: long, isDirectory: false, existing: [long])
        #expect(copy.utf8.count == 255)
        #expect(copy.hasSuffix(" copy.txt"))
        #expect(FileNaming.validationError(for: copy) == nil)

        let second = FileNaming.copyName(for: long, isDirectory: false, existing: [long, copy])
        #expect(second.hasSuffix(" copy 2.txt"))
        #expect(second.utf8.count <= 255)

        // Multi-byte letters are cut whole, never into invalid UTF-8.
        let accents = String(repeating: "é", count: 127)
        let accentCopy = FileNaming.copyName(for: accents, isDirectory: true, existing: [])
        #expect(accentCopy.utf8.count <= 255)
        #expect(accentCopy.hasSuffix(" copy"))
        #expect(accentCopy.dropLast(5).allSatisfy { $0 == "é" })
    }

    @Test func copyNameIsNeverInExisting() {
        let names = ["report.txt", "src", ".env", "archive.tar.gz", "a copy", "x copy 9.md"]
        for name in names {
            var existing: Set<String> = [name]
            for _ in 0..<5 {
                let copy = FileNaming.copyName(for: name, isDirectory: !name.contains("."), existing: existing)
                #expect(!existing.contains(copy), "\(name) → \(copy)")
                existing.insert(copy)
            }
        }
    }

    // MARK: uniqueName

    @Test func uniqueNameIsTheBaseWhenFree() {
        #expect(FileNaming.uniqueName("untitled.txt", existing: []) == "untitled.txt")
        #expect(FileNaming.uniqueName("untitled.txt", existing: ["other.txt"]) == "untitled.txt")
    }

    @Test func uniqueNameCountsFromTwo() {
        #expect(FileNaming.uniqueName("untitled.txt", existing: ["untitled.txt"]) == "untitled 2.txt")
        #expect(FileNaming.uniqueName("untitled.txt", existing: ["untitled.txt", "untitled 2.txt"]) == "untitled 3.txt")
        #expect(FileNaming.uniqueName("untitled folder", existing: ["untitled folder"]) == "untitled folder 2")
        #expect(FileNaming.uniqueName(".env", existing: [".env"]) == ".env 2")
        #expect(FileNaming.uniqueName("archive.tar.gz", existing: ["archive.tar.gz"]) == "archive 2.tar.gz")
    }

    @Test func uniqueNameWithManyClashes() {
        var existing: Set<String> = ["untitled.txt"]
        for number in 2...25 { existing.insert("untitled \(number).txt") }
        #expect(FileNaming.uniqueName("untitled.txt", existing: existing) == "untitled 26.txt")
    }

    @Test func uniqueNameDoesNotRenumberANumberedName() {
        // "Chapter 2.txt" taken does not turn into "Chapter 3.txt", which would read as a different chapter.
        #expect(FileNaming.uniqueName("Chapter 2.txt", existing: ["Chapter 2.txt"]) == "Chapter 2 2.txt")
    }

    @Test func uniqueNameIgnoresLetterCase() {
        #expect(FileNaming.uniqueName("untitled.txt", existing: ["Untitled.TXT"]) == "untitled 2.txt")
    }

    @Test func uniqueFolderNamesAreNotSplitAtADot() {
        #expect(FileNaming.uniqueName("photos.2024", isDirectory: true, existing: ["photos.2024"]) == "photos.2024 2")
        #expect(FileNaming.uniqueName("photos.2024", existing: ["photos.2024"]) == "photos 2.2024")
    }
}
