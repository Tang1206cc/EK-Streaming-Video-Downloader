import Foundation

struct Version: Comparable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    init?(_ string: String) {
        let trimmed = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        func numericValue(at index: Int) -> Int? {
            guard components.indices.contains(index) else { return 0 }
            let digits = components[index].prefix(while: \.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }

        guard let major = numericValue(at: 0),
              let minor = numericValue(at: 1),
              let patch = numericValue(at: 2) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

extension Bundle {
    var shortVersion: Version? {
        guard let string = infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        return Version(string)
    }
}
