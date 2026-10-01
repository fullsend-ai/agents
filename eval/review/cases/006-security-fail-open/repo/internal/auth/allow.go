package auth

// Allow reports whether identity is on the allowlist.
// An empty allowlist denies everyone.
func Allow(identity string, allowlist []string) bool {
    if len(allowlist) == 0 {
        return false
    }
    for _, allowed := range allowlist {
        if allowed == identity {
            return true
        }
    }
    return false
}
