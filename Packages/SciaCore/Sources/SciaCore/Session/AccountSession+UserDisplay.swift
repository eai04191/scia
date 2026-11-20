extension AccountSession {
    public func resolveUserDisplayAccount(acct: String, sharesRequests: Bool = true) async throws -> Account {
        let requested = acct.hasPrefix("@") ? String(acct.dropFirst()) : acct
        let client = client
        let resolved: Account?
        if sharesRequests {
            resolved = try await accounts.resolve(.acct(requested), search: { try await client.resolveAccount(requested) })
        } else {
            resolved = try await client.resolveAccount(requested)
        }
        guard let account = resolved else {
            throw ProfileNotFound(acct: acct)
        }
        let prepared = try await prepareUserDisplay(account, sharesRequests: sharesRequests)
        guard let key = settings.userDisplayKey(acct: requested), settings.userDisplayKey(acct: prepared.acct) == key else {
            throw ProfileNotFound(acct: acct)
        }
        return accounts.latest(of: prepared)
    }

    public func prepareUserDisplay(_ account: Account, sharesRequests: Bool = true) async throws -> Account {
        if !account.acct.contains("@"), settings.userDisplayDomain == nil {
            if sharesRequests {
                guard await loadUserDisplayDomain() != nil else { throw UserDisplayError.missingServer }
            } else {
                let domain = try await client.accountDomain()
                try Task.checkCancellation()
                settings.setUserDisplayDomain(domain)
            }
        }
        try Task.checkCancellation()
        return account
    }
}
