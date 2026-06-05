import Foundation

// MARK: - Type-safe localization keys

enum LKey: String, CaseIterable {
    // Tabs
    case settings, general, appearance, terminal = "editor", keyboard, ai, integrations, account

    // General
    case language, launchBehavior = "launch_behavior"
    case whenLaunch = "when_launch"
    case restoreSessions = "restore_sessions"
    case checkUpdates = "check_updates"

    // Appearance
    case theme, light, dark, auto
    case builtInThemes = "built_in_themes"
    case terminalTheme = "terminal_theme"
    case opacity, moreThemes = "more_themes"
    case font, fontFamily = "font_family", fontSize = "font_size", lineHeight = "line_height"

    // Editor
    case display
    case cursorStyle = "cursor_style", cursorBlink = "cursor_blink"
    case behavior, copyOnSelect = "copy_on_select", scrollbackLines = "scrollback_lines"
    case cursorBlock = "cursor_block", cursorUnderline = "cursor_underline", cursorBar = "cursor_bar"

    // Keyboard
    case shortcuts, newTerminal = "new_terminal"
    case closeTab = "close_tab", nextTab = "next_tab", prevTab = "prev_tab"
    case find
    case input, optionMeta = "option_meta", mouseReporting = "mouse_reporting"

    // AI
    case enableAIFeatures = "enable_ai_features"
    case activeProvider = "active_provider", none
    case providers, noProvidersConfigured = "no_providers_configured"
    case edit, setAsActive = "set_as_active", remove
    case addProvider = "add_provider", addCustomProvider = "add_custom_provider"
    case addProviderType = "add_provider_type"

    // AI — Provider Detail
    case apiKey = "api_key", apiKeySet = "api_key_set"
    case testConnection = "test_connection", connectionSuccessful = "connection_successful"
    case authentication, connection, endpoint, model, name
    case save, cancel
    case removeProvider = "remove_provider", removeProviderQ = "remove_provider_q"
    case apiKeyDeleted = "api_key_deleted", providerDeletedHint = "provider_deleted_hint"
    case local

    // AI — Inline Suggestions
    case inlineSuggestions = "inline_suggestions"
    case enableInlineSuggestions = "enable_inline_suggestions"
    case configureProviderHint = "configure_provider_hint"
    case debounce
    case inlineSuggestionsFooter = "inline_suggestions_footer"

    // AI — Context
    case context
    case includeTerminalOutput = "include_terminal_output"
    case includeCommandHistory = "include_command_history"
    case includeEnvInfo = "include_env_info"

    // AI — Privacy
    case privacy, connectionPolicy = "connection_policy"
    case alwaysAllow = "always_allow", askEachTime = "ask_each_time", never

    // Integrations
    case services, docker, notDetected = "not_detected"
    case kubernetes, plugins, installed

    // Account
    case license, licenseKey = "license_key"
    case notActivated = "not_activated", activate
    case status, inactive, plan, free
    case sync, icloudSync = "icloud_sync"
    case syncHosts = "sync_hosts", syncPrefs = "sync_prefs"
    case lastSynced = "last_synced"
    case syncNow = "sync_now"

    // AI
    case aiAssistant = "ai_assistant"
    case terminalAssistant = "terminal_assistant"
    case aiThinking = "ai_thinking"
    case aiPaste = "ai_paste"
    case aiCopy = "ai_copy"
    case aiDismiss = "ai_dismiss"
    case aiDiagnosis = "ai_diagnosis"
    case aiAnalyzing = "ai_analyzing"
    case aiApply = "ai_apply"
    case aiDismissWithEsc = "ai_dismiss_with_esc"
    case hostAutoFillClear = "host_auto_fill_clear"
    case aiDirectSubmit = "ai_direct_submit"

    // AI — Detail Sheet
    case addType = "add_type", other
    case modelId = "model_id", maxOutputTokens = "max_output_tokens"
    case advanced, apiKeyRequired = "api_key_required"
    case authenticationRequired = "authentication_required"
    case signInGithub = "sign_in_github", signedIn = "signed_in", signOut = "sign_out"
    case serviceStopped = "service_stopped", sendTelemetry = "send_telemetry"
    case fetchingModels = "fetching_models", reload
    case connectionTestFailed = "connection_test_failed"
    case enterCodeGithub = "enter_code_github", codeCopied = "code_copied"
    case codeExpires = "code_expires", completeSignIn = "complete_sign_in"
    case signedInAs = "signed_in_as", startingService = "starting_service"

    // General extras
    case custom, notConfigured = "not_configured"

    // ContentView
    case about, ok, serverInfo = "server_info", sftpBrowser = "sftp_browser"
    case connectionError = "connection_error", unknownError = "unknown_error"

    // AddHostSheet
    case hostInformation = "host_information", pastePemKey = "paste_pem_key"
    case addHost = "add_host", editHost = "edit_host"
    case displayName = "display_name", hostnameOrIp = "hostname_or_ip"
    case username, groupOptional = "group_optional"
    case method, password, privateKey = "private_key"

    // SFTPBrowserView
    case retry, sftpNotConnected = "sftp_not_connected"
    case connect, create, sftp, uploadFile = "upload_file"
    case newFolder = "new_folder", refresh
    case transfers, done

    // TerminalView
    case connectingTo = "connecting_to"
    case disconnected, reconnecting

    // TerminalTabView
    case rename, enterNewName = "enter_new_name"
    case overwrite, alwaysOverwrite = "always_overwrite"
    case fileExists = "file_exists"
    case noTerminal = "no_terminal", selectHost = "select_host"

    // ServerInfoPanel
    case selectHostInfo = "select_host_info", port

    // Context menu
    case duplicate
    case close, reconnect

    // ServerInfoPanel extra
    case hostDetails = "host_details", actions, disconnect, connected
    case host, auth
    case passwordAuth = "password_auth", privateKeyAuth = "private_key_auth"
    case error
    // Server system info
    case systemInfo = "system_info"
    case os, kernel, arch, hostname, shell, uptime, cpu
    case resources, memory, disk, loadAvg = "load_avg"
    case serverIP = "server_ip", fetching

    // File operations
    case open, download, delete

    // Groups
    case groups, addGroup = "add_group", editGroup = "edit_group"
    case groupName = "group_name", groupColor = "group_color", groupIcon = "group_icon"
    case noGroups = "no_groups", noGroupsHint = "no_groups_hint"
    case noIcon = "no_icon", customColor = "custom_color"
    case deleteGroupConfirm = "delete_group_confirm"

    // Search
    case search, system

    // Keychain
    case keychain
    case addCredential = "add_credential"
    case editCredential = "edit_credential"
    case noCredentials = "no_credentials"
    case noCredentialsHint = "no_credentials_hint"
    case credential = "credential"
    case notes
    case manageCredentials = "manage_credentials"
    case deleteConfirm = "delete_confirm"
    case noOutput = "no_output"
    case unGrouped = "ungrouped"
    case noModelContext = "no_model_context"
    case credentialsNotSet = "credentials_not_set"
    case sftpConnectFailed = "sftp_connect_failed"
    case noSSHConnection = "no_ssh_connection"
    case uploadingTo = "uploading_to"
    case uploadSuccess = "upload_success"
    case uploadFailed = "upload_failed"
}
