/// What kind of prompt an overlay entry belongs to.
public enum RequestSource: String {
    case onePassword
    case oidcLogin

    /// Line written to the trigger's TTY by the overlay's "Send Message" button.
    var ttyMessage: String {
        switch self {
        case .onePassword: return "\n[op-who] 1Password approval requested from this session\n"
        case .oidcLogin: return "\n[op-who] OIDC login requested from this session\n"
        }
    }
}
