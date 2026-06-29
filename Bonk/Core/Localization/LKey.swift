import Foundation

// MARK: - Type-safe localization keys

enum LKey: String, CaseIterable {
    /// Tabs
    case settings, general, appearance, terminal = "editor", keyboard
    case ai
    case integrations, account

    // General
    case language, launchBehavior = "launch_behavior"
    case whenLaunch = "when_launch"
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
    case aiChatSidebar = "ai_chat_sidebar"
    case terminalAssistant = "terminal_assistant"
    case aiThinking = "ai_thinking"
    case aiPaste = "ai_paste"
    case aiCopy = "ai_copy"
    case aiDismiss = "ai_dismiss"
    case aiDiagnosis = "ai_diagnosis"
    case aiAnalyzing = "ai_analyzing"
    case aiHistory = "ai_history"
    case aiNoHistory = "ai_no_history"
    case aiDeleteConversation = "ai_delete_conversation"
    case aiFetchingModels = "ai_fetching_models"
    case aiFetchModels = "ai_fetch_models"
    case aiNoModel = "ai_no_model"
    case aiApply = "ai_apply"
    case aiDismissWithEsc = "ai_dismiss_with_esc"
    case hostAutoFillClear = "host_auto_fill_clear"
    case aiDirectSubmit = "ai_direct_submit"
    case aiStopped = "ai_stopped"

    // AI — Sidebar
    case aiNotEnabled = "ai_not_enabled"
    case goToSettings = "go_to_settings"
    case enableAIHint = "enable_ai_hint"
    case describeTask = "describe_task"
    case confirmCommand = "confirm_command"
    case execute, stop
    case agentMode = "agent_mode"
    case agentModeDesc = "agent_mode_desc"
    case noSSHConnectionAgent = "no_ssh_connection_agent"
    case aiModeAsk = "ai_mode_ask"
    case aiModeEdit = "ai_mode_edit"
    case aiModeAgent = "ai_mode_agent"
    case aiModeAskDesc = "ai_mode_ask_desc"
    case aiModeEditDesc = "ai_mode_edit_desc"
    case aiModeAgentDesc = "ai_mode_agent_desc"

    // AI — Detail Sheet
    case addType = "add_type", other
    case modelId = "model_id", maxOutputTokens = "max_output_tokens"
    case modelRequired = "model_required"
    case modelRequiredHint = "model_required_hint"
    case advanced, apiKeyRequired = "api_key_required"
    case authenticationRequired = "authentication_required"
    case signInGithub = "sign_in_github", signedIn = "signed_in", signOut = "sign_out"
    case serviceStopped = "service_stopped", sendTelemetry = "send_telemetry"
    case fetchingModels = "fetching_models", reload
    case connectionTestFailed = "connection_test_failed"
    case enterCodeGithub = "enter_code_github", codeCopied = "code_copied"
    case codeExpires = "code_expires", completeSignIn = "complete_sign_in"
    case signedInAs = "signed_in_as", startingService = "starting_service"

    /// General extras
    case custom, notConfigured = "not_configured"

    // ContentView
    case about
    case ok
    case serverInfo = "server_info", sftpBrowser = "sftp_browser"
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

    /// ServerInfoPanel
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
    case os
    case kernel, arch, hostname, shell, uptime, cpu
    case resources, memory, disk, loadAvg = "load_avg"
    case serverIP = "server_ip", fetching

    /// File operations
    case open, download, delete

    // Groups
    case groups, addGroup = "add_group", editGroup = "edit_group"
    case groupName = "group_name", groupColor = "group_color", groupIcon = "group_icon"
    case noGroups = "no_groups", noGroupsHint = "no_groups_hint"
    case noIcon = "no_icon", customColor = "custom_color"
    case deleteGroupConfirm = "delete_group_confirm"

    /// Search
    case search, system

    // Keychain
    case keychain
    case addCredential = "add_credential"
    case editCredential = "edit_credential"
    case noCredentials = "no_credentials"
    case noCredentialsHint = "no_credentials_hint"
    case credential
    case notes
    case manageCredentials = "manage_credentials"
    case deleteConfirm = "delete_confirm"
    case noOutput = "no_output"
    case unGrouped = "ungrouped"
    case noModelContext = "no_model_context"
    case credentialsNotSet = "credentials_not_set"
    case sftpConnectFailed = "sftp_connect_failed"
    case noSSHConnection = "no_ssh_connection"
    case recent
    case favorites
    case allHosts = "all_hosts"
    case quickConnect = "quick_connect"
    case searchHosts = "search_hosts"
    case searchResults = "search_results"
    case connectTo = "connect_to"
    case newConnection = "new_connection"
    case enterHost = "enter_host"
    case enterUsername = "enter_username"
    case enterPassword = "enter_password"
    case upload
    case uploadingTo = "uploading_to"
    case uploadSuccess = "upload_success"
    case uploadFailed = "upload_failed"
    case showInFinder = "show_in_finder"

    // Command Palette
    case searchCommands = "search_commands"
    case commandPalette = "command_palette"

    // Snippets
    case snippets, addSnippet = "add_snippet", editSnippet = "edit_snippet"
    case noSnippets = "no_snippets", insertSnippet = "insert_snippet"
    case snippetCategory = "snippet_category"

    // Command categories
    case categoryConnection = "cat_connection"
    case categoryTabs = "cat_tabs"
    case categoryTerminal = "cat_terminal"
    case clearTerminalCmd = "clear_terminal"
    case command

    // Sessions
    case sessions, noSessions = "no_sessions"
    case noSessionsHint = "no_sessions_hint"

    // Port Forwarding
    case portForwarding = "port_forwarding"
    case addPortForward = "add_port_forward"
    case editPortForward = "edit_port_forward"
    case noPortForwards = "no_port_forwards"

    // Menu
    case menuView = "menu_view"
    case menuConnection = "menu_connection"
    case splitHorizontal = "split_horizontal"
    case splitVertical = "split_vertical"
    case closePane = "close_pane"
    case splitRight = "split_right"
    case splitDown = "split_down"
    case dropToSplit = "drop_to_split"
    case sftpOverwriteAlways = "sftp_overwrite_always"
    case overwritingTo = "overwriting_to"

    // Serial Port
    case serialPort = "serial_port"
    case scanPorts = "scan_ports"
    case selectPort = "select_port"
    case scanning
    case baudRate = "baud_rate"
    case dataBits = "data_bits"
    case stopBits = "stop_bits"
    case parity
    case flowControl = "flow_control"

    // SFTP Window
    case noActiveSession = "no_active_session"
    case connectToHostFirst = "connect_to_host_first"
    case localFiles = "local_files"

    // Jump Host
    case jumpHosts = "jump_hosts"
    case addJumpHost = "add_jump_host"
    case editJumpHost = "edit_jump_host"
    case noJumpHosts = "no_jump_hosts"
    case jumpHostHint = "jump_host_hint"
    case jumpHostAdvanced = "jump_host_advanced"
    case jumpHostHostname = "jump_host_hostname"

    // Broadcast
    case broadcastMode = "broadcast_mode"
    case disableBroadcast = "disable_broadcast"
    case enableBroadcast = "enable_broadcast"

    /// Inspector
    case snippetsHistory = "snippets_history"

    /// Toolbar
    case sftpBrowserToolbar = "sftp_browser_toolbar"

    /// Common
    case type, remote

    // Command History
    case commandHistory = "command_history"
    case noCommands = "no_commands"
    case rerunCommand = "rerun_command"
    case clearHistory = "clear_history"
    case saveToSnippets = "save_to_snippets"
    case copy

    // Broadcast
    case broadcastInput = "broadcast_input"
    case selectPanes = "select_panes"
    case selectAll = "select_all"
    case deselectAll = "deselect_all"
    case pane

    // AI
    case output
    case dangerousCommand = "dangerous_command"
    case couldNotDiagnose = "could_not_diagnose"
    case failed

    // Terminal
    case pressShortcut = "press_shortcut"
    case notSet = "not_set"

    /// Sessions
    case unfavorite, favorite

    // MARK: - New keys for hardcoded string fixes

    /// BonkApp menu
    case menuAI = "menu_ai"

    // Restart alert (I18n)
    case restartRequired = "restart_required"
    case restartMessage = "restart_message"
    case restartNow = "restart_now"
    case restartLater = "restart_later"

    // AI Chat / Agent
    case thinking
    case executionPlan = "execution_plan"
    case stepsCount = "steps_count"
    case executePlan = "execute_plan"
    case exitCode = "exit_code"
    case waitingForOutput = "waiting_for_output"

    /// Broadcast
    case broadcastPanes = "broadcast_panes"

    // Copilot errors
    case signInExpired = "sign_in_expired"
    case accessDenied = "access_denied"
    case signInTimedOut = "sign_in_timed_out"

    // Command safety levels
    case safe
    case moderate
    case dangerous
    case blocked

    // Agent plan executor
    case planRejected = "plan_rejected"
    case noProvider
    case cancelledAtStep = "cancelled_at_step"
    case blockedStep = "blocked_step"
    case skippedStep = "skipped_step"
    case executionReport = "execution_report"

    // Key recorder shortcuts
    case shortcutNewTerminal = "shortcut_new_terminal"
    case shortcutCloseTab = "shortcut_close_tab"
    case shortcutNextTab = "shortcut_next_tab"
    case shortcutPrevTab = "shortcut_prev_tab"
    case shortcutFind = "shortcut_find"
    case shortcutSettings = "shortcut_settings"
    case shortcutReconnect = "shortcut_reconnect"
    case shortcutClearTerminal = "shortcut_clear_terminal"

    // AI errors
    case noActiveProvider = "no_active_provider"
    case apiKeyNotSet = "api_key_not_set"
    case aiNoResponse = "ai_no_response"

    /// I18n restart
    case needsRestart = "needs_restart"
}
