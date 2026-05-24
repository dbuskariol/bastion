import Testing
import Foundation
@testable import BastionCore

@Suite("SSHCertExpiry parser")
struct SSHCertExpiryParserTests {

    @Test func parsesValidUntilDate() {
        let output = """
        prod_ed25519-cert.pub:
                Type: ssh-ed25519-cert-v01@openssh.com user certificate
                Valid: from 2025-01-01T00:00:00 to 2026-01-01T00:00:00
                Principals: dan
        """
        let date = SSHCertExpiry.parseValidUntil(output)
        #expect(date != nil)
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(components.year == 2026)
        #expect(components.month == 1)
        #expect(components.day == 1)
    }

    @Test func returnsNilForForeverCert() {
        let output = """
                Valid: forever
        """
        #expect(SSHCertExpiry.parseValidUntil(output) == nil)
    }

    @Test func returnsNilWhenNoValidLine() {
        #expect(SSHCertExpiry.parseValidUntil("just some text") == nil)
    }

    @Test func severityCriticalWhenLessThan48Hours() {
        let now = Date()
        let in24h = now.addingTimeInterval(24 * 3600)
        #expect(SSHCertExpiry.severity(validUntil: in24h, now: now) == .critical)
    }

    @Test func severityWarningSoonWhenLessThan7Days() {
        let now = Date()
        let in3d = now.addingTimeInterval(3 * 86_400)
        #expect(SSHCertExpiry.severity(validUntil: in3d, now: now) == .warningSoon)
    }

    @Test func severityOKWhenFarOff() {
        let now = Date()
        let in30d = now.addingTimeInterval(30 * 86_400)
        #expect(SSHCertExpiry.severity(validUntil: in30d, now: now) == .ok)
    }

    @Test func severityExpiredInPast() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(SSHCertExpiry.severity(validUntil: yesterday, now: now) == .expired)
    }

    @Test func severityOKWhenNoCert() {
        #expect(SSHCertExpiry.severity(validUntil: nil) == .ok)
    }
}

@Suite("NotificationCategory")
struct NotificationCategoryTests {
    @Test func allCategoriesHaveDistinctRawValues() {
        let raw = NotificationCategory.allCases.map { $0.rawValue }
        #expect(raw.count == Set(raw).count)
    }
    @Test func displayTitlesNonEmpty() {
        for c in NotificationCategory.allCases {
            #expect(!c.displayTitle.isEmpty)
        }
    }
}
