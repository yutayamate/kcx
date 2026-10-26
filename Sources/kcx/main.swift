import Darwin
import Foundation
import Security

struct EnvironmentMapping {
    let name: String
    let service: String
}

struct HeaderMapping {
    let name: String
    let service: String
    let bearer: Bool
}

func fail(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("kcx: \(message)\n".utf8))
    exit(status)
}

func usageError(_ message: String) -> Never {
    fail("\(message)\nRun 'kcx --help' for usage.")
}

func showHelp() -> Never {
    let help = """
    Usage:
      kcx run --env NAME=SERVICE [--env NAME=SERVICE ...] -- COMMAND [ARGS...]
      kcx generate [--format FORMAT] (--header NAME=SERVICE | --bearer SERVICE) ...
      kcx completion zsh|bash
      kcx --help

    Read generic passwords from the macOS Keychain. Run injects values as
    environment variables; generate prints HTTP headers as JSON.

    Commands:
      run       Inject Keychain values into a command's environment.
      generate  Generate output from Keychain values in a selected format.
      completion SHELL   Print shell completion code for zsh or Bash.

    Run options:
      --env NAME=SERVICE  Set NAME to the Keychain generic password for SERVICE.
                          Repeat to provide multiple variables.
      --                 Start the command and its arguments.

    Generate options (only valid after 'generate'):
      --format FORMAT     Output format (json; default: json).
      --header NAME=SERVICE
                          Add a header with the Keychain value unchanged.
      --bearer SERVICE    Add Authorization: Bearer <Keychain value>.

    General options:
      -h, --help          Show this help.

    Examples:
      kcx run --env API_KEY=my-api-key -- my-tool --option value
      kcx generate --format json --header X-API-Key=my-api-key --bearer access-token

    Store a secret without putting its value in shell history:
      security add-generic-password -a "$USER" -s my-api-key -w

    A command starts only after every requested Keychain item has been read.
    """
    FileHandle.standardOutput.write(Data((help + "\n").utf8))
    exit(0)
}

func showCompletions(for shell: String) -> Never {
    let script: String
    switch shell {
    case "zsh":
        script = #"""
        _kcx() {
          if (( ${words[(I)--]} )); then
            _normal
            return
          fi

          case $words[2] in
            run)
              _arguments -s \
                '(-h --help)'{-h,--help}'[Show help]' \
                '--env[Set an environment variable from a Keychain service]:NAME=SERVICE:' \
                '--[Start the command and its arguments]'
              ;;
            generate)
              _arguments -s \
                '(-h --help)'{-h,--help}'[Show help]' \
                '--format[Select generate output format]:FORMAT:(json)' \
                '--header[Add an HTTP header from a Keychain service]:NAME=SERVICE:' \
                '--bearer[Add an Authorization bearer token from a Keychain service]:SERVICE:'
              ;;
            completion)
              _arguments '2:shell:(zsh bash)'
              ;;
            *)
              _arguments -s \
                '1:command:(run generate completion)' \
                '(-h --help)'{-h,--help}'[Show help]'
              ;;
          esac
        }

        compdef _kcx kcx
        """#
    case "bash":
        script = #"""
        _kcx_complete() {
          local cur prev i separator_index=-1 subcommand=""
          cur=${COMP_WORDS[COMP_CWORD]}
          prev=${COMP_WORDS[COMP_CWORD-1]}

          for ((i = 1; i < COMP_CWORD; i++)); do
            case ${COMP_WORDS[i]} in
              run|generate|completion)
                subcommand=${COMP_WORDS[i]}
                break
                ;;
            esac
          done

          for ((i = 1; i < COMP_CWORD; i++)); do
            if [[ ${COMP_WORDS[i]} == -- ]]; then
              separator_index=$i
              break
            fi
          done

          if (( separator_index >= 0 )); then
            if (( COMP_CWORD == separator_index + 1 )); then
              COMPREPLY=( $(compgen -c -- "$cur") )
            fi
            return 0
          fi

          if [[ $prev == --env || $prev == --header || $prev == --bearer ]]; then
            compopt +o bashdefault +o default
            return 0
          fi
          if [[ $prev == --format ]]; then
            COMPREPLY=( $(compgen -W "json" -- "$cur") )
            return 0
          fi

          case $subcommand in
            run) COMPREPLY=( $(compgen -W "--env --help -h --" -- "$cur") ) ;;
            generate) COMPREPLY=( $(compgen -W "--format --header --bearer --help -h" -- "$cur") ) ;;
            completion) COMPREPLY=( $(compgen -W "zsh bash" -- "$cur") ) ;;
            *) COMPREPLY=( $(compgen -W "run generate completion --help -h" -- "$cur") ) ;;
          esac
        }

        complete -o bashdefault -o default -F _kcx_complete kcx
        """#
    default:
        usageError("unsupported completion shell '\(shell)'; choose 'zsh' or 'bash'")
    }
    FileHandle.standardOutput.write(Data(script.utf8))
    exit(0)
}

func keychainHint(for status: OSStatus) -> String {
    switch status {
    case errSecInteractionNotAllowed:
        return "The Keychain may be locked or macOS may need permission to let kcx read this item. Unlock the Keychain in Keychain Access and approve access if prompted."
    case errSecAuthFailed:
        return "Keychain access was denied. Check the item's access controls in Keychain Access and allow kcx to read it."
    case errSecUserCanceled:
        return "Keychain access was cancelled. Retry and approve the access request if prompted."
    case errSecNoSuchKeychain:
        return "The item may be in a Keychain that is not in the user's Keychain search list. Check its location in Keychain Access."
    case errSecNotAvailable:
        return "Keychain services are unavailable. Confirm this is a macOS session with Keychain access."
    default:
        return "Check that the Keychain is available and that kcx is allowed to read the item."
    }
}

func readSecret(service: String) -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: service,
        kSecReturnData as String: true
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
        if status == errSecItemNotFound {
            fail("no generic password found for Keychain service '\(service)'. Add the item in Keychain Access or with 'security add-generic-password'.")
        }
        let systemMessage = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        fail("could not read Keychain service '\(service)': \(systemMessage). \(keychainHint(for: status))")
    }

    guard let data = result as? Data else {
        fail("Keychain returned no password data for service '\(service)'. Check that it is a generic password item.")
    }
    guard let secret = String(data: data, encoding: .utf8) else {
        fail("Keychain value for service '\(service)' is not valid UTF-8. Store the secret as UTF-8 text.")
    }
    return secret
}

func parsePair(_ value: String, option: String) -> (String, String) {
    guard let separator = value.firstIndex(of: "=") else {
        usageError("invalid value for \(option) '\(value)'; expected NAME=SERVICE")
    }
    let name = String(value[..<separator])
    let service = String(value[value.index(after: separator)...])
    guard !name.isEmpty else { usageError("HTTP header name must not be empty") }
    guard !service.isEmpty else { usageError("Keychain service name must not be empty") }
    return (name, service)
}

func generateHeaders(_ arguments: [String]) -> Never {
    var mappings: [HeaderMapping] = []
    var headerNames = Set<String>()
    var outputFormat = "json"
    var formatWasSpecified = false
    var index = 0

    while index < arguments.count {
        let option = arguments[index]
        if option == "--help" || option == "-h" {
            showHelp()
        }
        if option == "--format" {
            guard !formatWasSpecified else { usageError("--format may only be specified once") }
            index += 1
            guard index < arguments.count else { usageError("--format requires a value (currently only 'json' is supported)") }
            outputFormat = arguments[index]
            guard outputFormat == "json" else {
                usageError("unsupported output format '\(outputFormat)'; currently only 'json' is supported")
            }
            formatWasSpecified = true
            index += 1
            continue
        }
        guard option == "--header" || option == "--bearer" else {
            usageError("unexpected option or argument '\(option)'; use --format json, --header NAME=SERVICE, and/or --bearer SERVICE")
        }
        index += 1
        guard index < arguments.count else { usageError("\(option) requires a value") }

        let name: String
        let service: String
        let bearer = option == "--bearer"
        if bearer {
            name = "Authorization"
            service = arguments[index]
            guard !service.isEmpty else { usageError("Keychain service name must not be empty") }
        } else {
            (name, service) = parsePair(arguments[index], option: option)
            guard name.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil else {
                usageError("invalid HTTP header name '\(name)'")
            }
        }

        guard headerNames.insert(name.lowercased()).inserted else {
            usageError("HTTP header '\(name)' was specified more than once")
        }
        mappings.append(HeaderMapping(name: name, service: service, bearer: bearer))
        index += 1
    }

    guard !mappings.isEmpty else {
        usageError("at least one --header NAME=SERVICE or --bearer SERVICE is required")
    }

    var headers: [String: String] = [:]
    for mapping in mappings {
        let secret = readSecret(service: mapping.service)
        guard !secret.isEmpty else { fail("Keychain value for service '\(mapping.service)' is empty") }
        guard !secret.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            fail("Keychain value for service '\(mapping.service)' contains control characters and cannot be used as an HTTP header")
        }
        headers[mapping.name] = mapping.bearer ? "Bearer \(secret)" : secret
    }

    switch outputFormat {
    case "json":
        do {
            var data = try JSONSerialization.data(withJSONObject: headers, options: [.sortedKeys])
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            fail("could not encode HTTP headers as JSON")
        }
    default:
        fail("unsupported output format '\(outputFormat)'")
    }
    exit(0)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "generate" {
    arguments.removeFirst()
    generateHeaders(arguments)
}
if arguments.first == "run" {
    arguments.removeFirst()
}
if arguments.first == "completion" {
    guard arguments.count == 2 else {
        usageError("'completion' requires one shell name: zsh or bash")
    }
    showCompletions(for: arguments[1])
}

var mappings: [EnvironmentMapping] = []
var environmentNames = Set<String>()
var index = 0

while index < arguments.count {
    let argument = arguments[index]
    if argument == "--" {
        index += 1
        break
    }
    if argument == "--help" || argument == "-h" {
        showHelp()
    }
    guard argument == "--env" else {
        usageError("unexpected option or argument '\(argument)'")
    }
    index += 1
    guard index < arguments.count, arguments[index] != "--" else {
        usageError("--env requires a NAME=SERVICE mapping")
    }
    let pair = arguments[index]
    guard let separator = pair.firstIndex(of: "=") else {
        usageError("invalid mapping '\(pair)'; expected NAME=SERVICE")
    }
    let name = String(pair[..<separator])
    let service = String(pair[pair.index(after: separator)...])
    guard !name.isEmpty, name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
        usageError("invalid environment-variable name '\(name)'")
    }
    guard !service.isEmpty else {
        usageError("Keychain service name for '\(name)' must not be empty")
    }
    guard environmentNames.insert(name).inserted else {
        usageError("environment variable '\(name)' was specified more than once")
    }
    mappings.append(EnvironmentMapping(name: name, service: service))
    index += 1
}

guard index < arguments.count else {
    usageError("no command provided after '--'")
}
guard !mappings.isEmpty else {
    usageError("at least one --env NAME=SERVICE mapping is required")
}

// Resolve every item before changing the environment or starting the child.
let resolved = mappings.map { ($0.name, readSecret(service: $0.service)) }
for (name, value) in resolved {
    guard setenv(name, value, 1) == 0 else {
        let reason = String(cString: strerror(errno))
        fail("could not set environment variable '\(name)': \(reason) (errno \(errno))")
    }
}

let commandAndArguments = Array(arguments[index...])
let executable = commandAndArguments[0]
var argv = commandAndArguments.map { strdup($0) }
argv.append(nil)
defer { for pointer in argv where pointer != nil { free(pointer) } }

_ = executable.withCString { path in
    argv.withUnsafeMutableBufferPointer { buffer in
        execvp(path, buffer.baseAddress!)
    }
}

let executionError = errno
let reason = String(cString: strerror(executionError))
if executionError == ENOENT {
    fail("command '\(executable)' was not found. Check its path or make sure it is available in PATH.", status: 127)
}
if executionError == EACCES {
    fail("permission denied when starting '\(executable)'. Check the path and executable permissions.", status: 126)
}
fail("could not start '\(executable)': \(reason) (errno \(executionError))", status: 126)
