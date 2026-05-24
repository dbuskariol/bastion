import Foundation

/// Canonical list of OpenSSH options Bastion surfaces in its UI. Lower-case
/// `rawValue` matches `ssh -G`'s emission. Source: `ssh_config(5)` plus
/// the dual-model-consensus design's Basic/Advanced/Raw triage.
public enum SSHOption: String, Codable, Sendable, Hashable, CaseIterable {
    // Identity & auth
    case identityFile = "identityfile"
    case identitiesOnly = "identitiesonly"
    case addKeysToAgent = "addkeystoagent"
    case useKeychain = "usekeychain"
    case preferredAuthentications = "preferredauthentications"
    case identityAgent = "identityagent"
    case certificateFile = "certificatefile"
    case pkcs11Provider = "pkcs11provider"
    case securityKeyProvider = "securitykeyprovider"

    // Connection
    case addressFamily = "addressfamily"
    case connectTimeout = "connecttimeout"
    case connectionAttempts = "connectionattempts"
    case bindAddress = "bindaddress"
    case bindInterface = "bindinterface"
    case canonicalizeHostname = "canonicalizehostname"
    case canonicalDomains = "canonicaldomains"

    // Keepalive & multiplexing
    case serverAliveInterval = "serveraliveinterval"
    case serverAliveCountMax = "serveralivecountmax"
    case tcpKeepAlive = "tcpkeepalive"
    case controlMaster = "controlmaster"
    case controlPath = "controlpath"
    case controlPersist = "controlpersist"

    // Forwarding
    case localForward = "localforward"
    case remoteForward = "remoteforward"
    case dynamicForward = "dynamicforward"
    case gatewayPorts = "gatewayports"
    case exitOnForwardFailure = "exitonforwardfailure"

    // Jump / proxy
    case proxyJump = "proxyjump"
    case proxyCommand = "proxycommand"

    // Host verification
    case strictHostKeyChecking = "stricthostkeychecking"
    case userKnownHostsFile = "userknownhostsfile"
    case checkHostIP = "checkhostip"
    case hashKnownHosts = "hashknownhosts"
    case verifyHostKeyDNS = "verifyhostkeydns"
    case updateHostKeys = "updatehostkeys"
    case visualHostKey = "visualhostkey"

    // Crypto
    case hostKeyAlgorithms = "hostkeyalgorithms"
    case kexAlgorithms = "kexalgorithms"
    case ciphers = "ciphers"
    case macs = "macs"
    case pubkeyAcceptedAlgorithms = "pubkeyacceptedalgorithms"

    // Session
    case requestTTY = "requesttty"
    case remoteCommand = "remotecommand"
    case sendEnv = "sendenv"
    case setEnv = "setenv"
    case logLevel = "loglevel"
    case compression = "compression"
    case sessionType = "sessiontype"
    case ipQoS = "ipqos"

    // Agent / forwarding
    case forwardAgent = "forwardagent"

    // Auth modes
    case kbdInteractiveAuthentication = "kbdinteractiveauthentication"
    case kbdInteractiveDevices = "kbdinteractivedevices"
    case passwordAuthentication = "passwordauthentication"

    // Tags
    case tag = "tag"

    /// Canonical CamelCase for writing into `bastion.conf`.
    public var configKey: String {
        switch self {
        case .identityFile:                  return "IdentityFile"
        case .identitiesOnly:                return "IdentitiesOnly"
        case .addKeysToAgent:                return "AddKeysToAgent"
        case .useKeychain:                   return "UseKeychain"
        case .preferredAuthentications:      return "PreferredAuthentications"
        case .identityAgent:                 return "IdentityAgent"
        case .certificateFile:               return "CertificateFile"
        case .pkcs11Provider:                return "PKCS11Provider"
        case .securityKeyProvider:           return "SecurityKeyProvider"
        case .addressFamily:                 return "AddressFamily"
        case .connectTimeout:                return "ConnectTimeout"
        case .connectionAttempts:            return "ConnectionAttempts"
        case .bindAddress:                   return "BindAddress"
        case .bindInterface:                 return "BindInterface"
        case .canonicalizeHostname:          return "CanonicalizeHostname"
        case .canonicalDomains:              return "CanonicalDomains"
        case .serverAliveInterval:           return "ServerAliveInterval"
        case .serverAliveCountMax:           return "ServerAliveCountMax"
        case .tcpKeepAlive:                  return "TCPKeepAlive"
        case .controlMaster:                 return "ControlMaster"
        case .controlPath:                   return "ControlPath"
        case .controlPersist:                return "ControlPersist"
        case .localForward:                  return "LocalForward"
        case .remoteForward:                 return "RemoteForward"
        case .dynamicForward:                return "DynamicForward"
        case .gatewayPorts:                  return "GatewayPorts"
        case .exitOnForwardFailure:          return "ExitOnForwardFailure"
        case .proxyJump:                     return "ProxyJump"
        case .proxyCommand:                  return "ProxyCommand"
        case .strictHostKeyChecking:         return "StrictHostKeyChecking"
        case .userKnownHostsFile:            return "UserKnownHostsFile"
        case .checkHostIP:                   return "CheckHostIP"
        case .hashKnownHosts:                return "HashKnownHosts"
        case .verifyHostKeyDNS:              return "VerifyHostKeyDNS"
        case .updateHostKeys:                return "UpdateHostKeys"
        case .visualHostKey:                 return "VisualHostKey"
        case .hostKeyAlgorithms:             return "HostKeyAlgorithms"
        case .kexAlgorithms:                 return "KexAlgorithms"
        case .ciphers:                       return "Ciphers"
        case .macs:                          return "MACs"
        case .pubkeyAcceptedAlgorithms:      return "PubkeyAcceptedAlgorithms"
        case .requestTTY:                    return "RequestTTY"
        case .remoteCommand:                 return "RemoteCommand"
        case .sendEnv:                       return "SendEnv"
        case .setEnv:                        return "SetEnv"
        case .logLevel:                      return "LogLevel"
        case .compression:                   return "Compression"
        case .sessionType:                   return "SessionType"
        case .ipQoS:                         return "IPQoS"
        case .forwardAgent:                  return "ForwardAgent"
        case .kbdInteractiveAuthentication:  return "KbdInteractiveAuthentication"
        case .kbdInteractiveDevices:         return "KbdInteractiveDevices"
        case .passwordAuthentication:        return "PasswordAuthentication"
        case .tag:                           return "Tag"
        }
    }

    /// Options that may legitimately appear multiple times in a Host stanza
    /// (and that `ssh -G` repeats on separate lines).
    public var isMultiValued: Bool {
        switch self {
        case .identityFile, .certificateFile,
             .localForward, .remoteForward, .dynamicForward,
             .sendEnv, .setEnv:
            return true
        default:
            return false
        }
    }
}
