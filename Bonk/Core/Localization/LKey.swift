import Foundation

// MARK: - Type-safe localization keys

enum LKey: String, CaseIterable {
    /// Tabs
    case settings, general, appearance, terminal = "editor", keyboard
    case ai

    // General
    case language, launchBehavior = "launch_behavior"
    case checkUpdates = "check_updates"

    // Appearance
    case theme, light, dark, auto
    case terminalTheme = "terminal_theme"
    case opacity, moreThemes = "more_themes"
    case font, fontFamily = "font_family", fontSize = "font_size", lineHeight = "line_height"

    // Editor
    case display
    case cursorStyle = "cursor_style", cursorBlink = "cursor_blink"
    case behavior, copyOnSelect = "copy_on_select", scrollbackLines = "scrollback_lines"
    case scrolling, scrollSensitivity = "scroll_sensitivity", scrollMaxLines = "scroll_max_lines"
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

    // AI — Provider Detail
    case apiKey = "api_key", apiKeySet = "api_key_set"
    case testConnection = "test_connection", connectionSuccessful = "connection_successful"
    case authentication, connection, endpoint, model, name
    case save, cancel, add
    case removeProvider = "remove_provider", removeProviderQ = "remove_provider_q"
    case apiKeyDeleted = "api_key_deleted", providerDeletedHint = "provider_deleted_hint"
    case local

    // AI — Inline Suggestions
    case inlineSuggestions = "inline_suggestions"
    case enableInlineSuggestions = "enable_inline_suggestions"
    case configureProviderHint = "configure_provider_hint"
    case aiCandidatePopup = "ai_candidate_popup"
    case aiCandidatePopupDesc = "ai_candidate_popup_desc"
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
    case notDetected = "not_detected"
    case installed

    case status, inactive, plan, free
    case icloudSync = "icloud_sync"
    case syncPrefs = "sync_prefs"

    // AI
    case aiAssistant = "ai_assistant"
    case terminalAssistant = "terminal_assistant"
    case aiThinking = "ai_thinking"
    case aiPaste = "ai_paste"
    case aiRun = "ai_run"
    case aiCopy = "ai_copy"
    case aiAnalyzing = "ai_analyzing"
    case aiNoHistory = "ai_no_history"
    case aiDeleteConversation = "ai_delete_conversation"
    case aiApply = "ai_apply"
    case aiDismissWithEsc = "ai_dismiss_with_esc"
    case hostAutoFillClear = "host_auto_fill_clear"
    case aiDirectSubmit = "ai_direct_submit"
    case rightClickPaste = "right_click_paste"
    case rightClickPasteMenuModifier = "right_click_paste_menu_modifier"
    case rightClickPasteDesc = "right_click_paste_desc"
    case aiStopped = "ai_stopped"

    // AI — Sidebar
    case aiNotEnabled = "ai_not_enabled"
    case aiAllowDirectConnect = "ai_allow_direct_connect"
    case aiDirectConnectDesc = "ai_direct_connect_desc"
    case aiCurrentSession = "ai_current_session"
    case aiConfirmConnect = "ai_confirm_connect"
    case aiDirectConnectDisabled = "ai_direct_connect_disabled"
    case aiInlineModel = "ai_inline_model"
    case aiFollowMainProvider = "ai_follow_main_provider"
    case aiInlineModelDesc = "ai_inline_model_desc"
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
    case fetchingModels = "fetching_models", reload
    case connectionTestFailed = "connection_test_failed"
    case capabilityOverrides = "capability_overrides"
    case capabilityAuto = "capability_auto"
    case capabilityYes = "capability_yes"
    case capabilityNo = "capability_no"
    case supportsChatCompletions = "supports_chat_completions"
    case supportsResponses = "supports_responses"
    case supportsToolCalls = "supports_tool_calls"
    case reasoningSupport = "reasoning_support"
    case reasoningDisableStrategy = "reasoning_disable_strategy"
    case reasoningUnsupported = "reasoning_unsupported"
    case reasoningOptional = "reasoning_optional"
    case reasoningRequired = "reasoning_required"
    case reasoningNone = "reasoning_none"
    case reasoningDeepSeek = "reasoning_deepseek"
    case reasoningEnableThinkingFalse = "reasoning_enable_thinking_false"
    case clearCapabilityOverrides = "clear_capability_overrides"
    case apiProtocol = "api_protocol"
    case apiProtocolHint = "api_protocol_hint"
    case chatCompletions = "chat_completions"
    case responsesAPI = "responses_api"
    case extraHeaders = "extra_headers"
    case headerName = "header_name"
    case headerValue = "header_value"
    case addHeader = "add_header"

    /// General extras
    case custom, notConfigured = "not_configured"

    // ContentView
    case about
    case ok
    case serverInfo = "server_info", sftpBrowser = "sftp_browser"
    case serverResourceDetail = "server_resource_detail"
    case refreshNow = "refresh_now"
    case connectionError = "connection_error", unknownError = "unknown_error"

    // AddHostSheet
    case hostInformation = "host_information", pastePemKey = "paste_pem_key"
    case addHost = "add_host", editHost = "edit_host"
    case displayName = "display_name", hostnameOrIp = "hostname_or_ip"
    case username, groupOptional = "group_optional"
    case method, password, privateKey = "private_key"

    // Authentication failure dialog
    case authFailedTitle = "auth_failed_title"
    case authFailedMessage = "auth_failed_message"

    // SFTPBrowserView
    case retry, sftpNotConnected = "sftp_not_connected"
    case connect, create, sftp, uploadFile = "upload_file"
    case newFolder = "new_folder", refresh
    case transfers, done

    // TerminalView
    case connectingTo = "connecting_to"
    case disconnected, reconnecting
    case reconnectingPlain = "reconnecting_plain"

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
    case disconnect, connected
    case host, auth
    case privateKeyAuth = "private_key_auth"
    case error
    // Server system info
    case systemInfo = "system_info"
    case os
    case kernel, arch, hostname, shell, uptime, cpu
    case resources, memory, disk, swap, network, loadAvg = "load_avg"
    case diskIO = "disk_io", cpuTemp = "cpu_temp"
    case topProcesses = "top_processes", listenPorts = "listen_ports"
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
    case unGrouped = "ungrouped"
    case noModelContext = "no_model_context"
    case credentialsNotSet = "credentials_not_set"
    case invalidPort = "invalid_port"
    case sftpConnectFailed = "sftp_connect_failed"
    case noSSHConnection = "no_ssh_connection"
    case recent
    case allHosts = "all_hosts"
    case searchHosts = "search_hosts"
    case connectTo = "connect_to"
    case upload
    case uploadSuccess = "upload_success"
    case uploadFailed = "upload_failed"
    case showInFinder = "show_in_finder"

    // Command Palette
    case snippets, addSnippet = "add_snippet", editSnippet = "edit_snippet"
    case noSnippets = "no_snippets", insertSnippet = "insert_snippet"
    case snippetCategory = "snippet_category"

    // Command
    case command

    // Sessions
    case noSessions = "no_sessions"

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
    case sftpOverwriteAlways = "sftp_overwrite_always"
    case sftpDefaultLocalPath = "sftp_default_local_path"
    case browse

    // Serial Port
    case serialPort = "serial_port"
    case scanPorts = "scan_ports"
    case selectPort = "select_port"
    case saveSerialPort = "save_serial_port"
    case editSerialPort = "edit_serial_port"
    case portPath = "port_path"
    case moveToGroup = "move_to_group"
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

    // Broadcast
    case disableBroadcast = "disable_broadcast"
    case enableBroadcast = "enable_broadcast"
    case toggleSidebar = "toggle_sidebar"

    /// Inspector
    case snippetsHistory = "snippets_history"

    /// Common
    case type, remote

    /// Terminal context menu / UI
    case paste, linked = "linked", unsplit = "unsplit"
    case color, enter, folder
    case cancelled, run
    case sendFile = "send_file"
    case receiveFile = "receive_file"
    case fileTransfer = "file_transfer"
    case dropToSplit = "drop_to_split"
    case exampleKeyTag = "example_key_tag"
    case securityFeatures = "security_features"
    case ecdsaP256 = "ecdsa_p256"
    case hardwareNonExportable = "hardware_non_exportable"

    /// Keyboard shortcut action names
    case actionNewTerminal = "action_new_terminal"
    case actionCloseTab = "action_close_tab"
    case actionClosePane = "action_close_pane"
    case actionNextTab = "action_next_tab"
    case actionPreviousTab = "action_previous_tab"
    case actionFind = "action_find"
    case actionSettings = "action_settings"
    case actionReconnect = "action_reconnect"
    case actionClearTerminal = "action_clear_terminal"
    case actionSplitHorizontal = "action_split_horizontal"
    case actionSplitVertical = "action_split_vertical"
    case actionSftpBrowser = "action_sftp_browser"
    case actionAiAssistant = "action_ai_assistant"

    // Command History
    case commandHistory = "command_history"
    case noCommands = "no_commands"
    case rerunCommand = "rerun_command"
    case clearHistory = "clear_history"
    case clearHistoryConfirm = "clear_history_confirm"
    case saveToSnippets = "save_to_snippets"
    case copy

    // Broadcast
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

    /// Broadcast
    case broadcastPanes = "broadcast_panes"

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

    // Key recorder shortcuts

    // AI errors
    case noActiveProvider = "no_active_provider"
    case apiKeyNotSet = "api_key_not_set"
    case aiNoResponse = "ai_no_response"

    // Log colorization
    case logColorization = "log_colorization"
    case logColorizationDesc = "log_colorization_desc"

    // SSH Config Import
    case importSSHConfig = "import_ssh_config"
    case importTabby = "import_tabby"
    case importSessions = "import_sessions"
    case importSSHConfigDescription = "import_ssh_config_description"
    case hostsFound = "hosts_found"
    case noSSHConfigEntries = "no_ssh_config_entries"
    case noSSHConfigEntriesDescription = "no_ssh_config_entries_description"
    case importResult = "import_result"
    case importSuccessMessage = "import_success_message"

    // Auto-reconnect
    case autoReconnect = "auto_reconnect"
    case maxReconnectAttempts = "max_reconnect_attempts"
    case reconnectBaseDelay = "reconnect_base_delay"

    // SSH Certificate
    case certificate = "certificate"
    case pasteCertificate = "paste_certificate"
    case selectFile = "select_file"
    case pasteManually = "paste_manually"
    case selectPrivateKeyFile = "select_private_key_file"
    case selectCertificateFile = "select_certificate_file"

    // SSH Key Generator
    case generateSSHKey = "generate_ssh_key"
    case generateSSHKeyDescription = "generate_ssh_key_description"
    case keyType = "key_type"
    case passphraseOptional = "passphrase_optional"
    case passphraseHint = "passphrase_hint"
    case fingerprint = "fingerprint"
    case publicKey = "public_key"
    case privateKeyWarning = "private_key_warning"
    case privateKeyOverwriteWarning = "private_key_overwrite_warning"
    case copyPublicKey = "copy_public_key"
    case copyPrivateKey = "copy_private_key"
    case saveToFile = "save_to_file"
    case generate = "generate"
    case generateNew = "generate_new"
    case copied = "copied"
    case sshKeys = "ssh_keys"
    case detectedKeyType = "detected_key_type"

    // Secure Enclave
    case secureEnclave = "secure_enclave"
    case generateSecureEnclaveKey = "generate_secure_enclave_key"
    case generateSecureEnclaveKeyDescription = "generate_secure_enclave_key_description"
    case keyIdentifier = "key_identifier"
    case keyIdentifierHint = "key_identifier_hint"
    case hardwareProtection = "hardware_protection"
    case hardwareProtectionDesc = "hardware_protection_desc"
    case biometricAuth = "biometric_auth"
    case biometricAuthDesc = "biometric_auth_desc"
    case verifyKey = "verify_key"
    case keyVerified = "key_verified"
    case enterKeyIdentifier = "enter_key_identifier"
    case keyNotFound = "key_not_found"
    case secureEnclaveKeyGenerated = "secure_enclave_key_generated"
    case addPublicKeyToServer = "add_public_key_to_server"
    case change = "change"

    // SSH Connection Errors
    case sshErrorForwardingDisabled = "ssh_error_forwarding_disabled"
    case sshErrorJumpForwardingDisabled = "ssh_error_jump_forwarding_disabled"
    case sshErrorNetworkUnreachable = "ssh_error_network_unreachable"
    case sshErrorAuthentication = "ssh_error_authentication"
    case sshErrorHostKey = "ssh_error_host_key"
    case sshErrorTimeout = "ssh_error_timeout"

    // VNext — Host Inspector (§6.4)
    case sshEngineDiagnosis = "ssh_engine_diagnosis"
    case sshBackend = "ssh_backend"
    case sshBackendNative = "ssh_backend_native"
    case sshBackendCompatibility = "ssh_backend_compatibility"
    case sshBackendReason = "ssh_backend_reason"
    case sshLastDetected = "ssh_last_detected"
    case sshExpiresAt = "ssh_expires_at"
    case sshNoProfile = "ssh_no_profile"
    case sshRedetect = "ssh_redetect"
    case sshAlwaysCompatibility = "ssh_always_compatibility"
    case sshAlwaysCompatibilityDesc = "ssh_always_compatibility_desc"
    case sshFingerprint = "ssh_fingerprint"
    case sshAlgorithms = "ssh_algorithms"
    case sshProfileValid = "ssh_profile_valid"
    case sshProfileExpired = "ssh_profile_expired"
    case sshPolicyNoExpiry = "ssh_policy_no_expiry"

    // Workspaces
    case workspaces = "workspaces"
    case saveWorkspace = "save_workspace"
    case loadWorkspace = "load_workspace"
    case deleteWorkspace = "delete_workspace"
    case renameWorkspace = "rename_workspace"
    case workspaceName = "workspace_name"
    case noWorkspaces = "no_workspaces"
    case noWorkspacesHint = "no_workspaces_hint"
    case tabsCount = "tabs_count"
    case saveCurrentAsWorkspace = "save_current_as_workspace"
    case deleteWorkspaceConfirm = "delete_workspace_confirm"
    case workspaceCount = "workspace_count"
    case ago = "ago"
    case template = "template"
    case templates = "templates"
    case all = "all"
    case saveAsTemplate = "save_as_template"
    case templateDescription = "template_description"

    // Quake Terminal
    case quakeEnabled = "quake_enabled"
    case accessibilityPermission = "accessibility_permission"
    case granted = "granted"
    case grantPermission = "grant_permission"
    case toggleHotkey = "toggle_hotkey"
    case windowSettings = "window_settings"
    case height = "height"
    case width = "width"
    case autoHideOnFocusLoss = "auto_hide_on_focus_loss"
    case escKeyBehavior = "esc_key_behavior"
    case quakeTerminal = "quake_terminal"
    case connectFromMainWindow = "connect_from_main_window"

    // Recording (asciicast v2)
    case recording = "recording"
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case showRecordings = "show_recordings"
    case recordings = "recordings"
    case noRecordings = "no_recordings"
    case noRecordingsHint = "no_recordings_hint"
    case play = "play"
    case replay = "replay"
    case pause = "pause"
    case share = "share"
    case deleteRecording = "delete_recording"
    case showLess = "show_less"
    case showAll = "show_all"
    case rec = "rec"

    case zmodem = "zmodem"
    case zmodemDesc = "zmodem_desc"

    // General — Recording / SSH Config (GeneralSettingsView)
    case autoRecordSessions = "auto_record_sessions"
    case autoRecordDesc = "auto_record_desc"
    case sshConfig = "ssh_config"
    case autoSyncSSHConfig = "auto_sync_ssh_config"
    case autoSyncSSHConfigDesc = "auto_sync_ssh_config_desc"

    // Triggers
    case triggers
    case triggersDescription = "triggers_description"
    case noTriggers = "no_triggers"
    case noTriggersDescription = "no_triggers_description"
    case addTrigger = "add_trigger"
    case editTrigger = "edit_trigger"
    case triggerName = "trigger_name"
    case triggerPattern = "trigger_pattern"
    case triggerRegex = "trigger_regex"
    case triggerCaseSensitive = "trigger_case_sensitive"
    case triggerAction = "trigger_action"
    case triggerHighlight = "trigger_highlight"
    case triggerNotify = "trigger_notify"
    case triggerSendText = "trigger_send_text"
    case triggerHighlightDesc = "trigger_highlight_desc"
    case triggerEnabled = "trigger_enabled"
    case importUnifiedDescription = "import_unified_description"
    case importTabbyPasswordWarning = "import_tabby_password_warning"
    case escAlways = "esc_always"
    case escNever = "esc_never"
    case escOnlyNoAlt = "esc_only_no_alt"
    case chooseFile = "choose_file"

    // Team
    case team
    case hostSession = "host_session"
    case joinSession = "join_session"
    case startHosting = "start_hosting"
    case stopHosting = "stop_hosting"
    case noGuests = "no_guests"
    case grantControl = "grant_control"
    case revokeControl = "revoke_control"
    case discovered = "discovered"
    case noHostsFound = "no_hosts_found"
    case manualIP = "manual_ip"
    case liveTerminal = "live_terminal"
    case waitingForOutput = "waiting_for_output"
    case requestControl = "request_control"
    case typeCommand = "type_command"
    case send = "send"
    case connectedPeers = "connected_peers"
    case hostControls = "host_controls"
    case driver
    case teamHostHint = "team_host_hint"
    case controlRequestTitle = "control_request_title"
    case controlRequestMessage = "control_request_message"
    case allow = "allow"
    case deny = "deny"
    case teamVisitorMode = "team_visitor_mode"
    case shareHostsToGuest = "share_hosts_to_guest"
    case teamMaxGuests = "team_max_guests"
    case teamMaxGuestsDesc = "team_max_guests_desc"
    case exportHosts = "export_hosts"

    // Command Blocks (Warp-style)
    case blocks
    case noResults = "no_results"
    case searchCommandOrOutput = "search_command_or_output"
    case copySnippet = "copy_snippet"
    case shellIntegrationHint = "shell_integration_hint"
    case copyCommand = "copy_command"
    case copyOutput = "copy_output"
    case copyBoth = "copy_both"
    case searchInTerminal = "search_in_terminal"
    case guestOperating = "guest_operating"
    case showDetails = "show_details"
    case hideDetails = "hide_details"

    // Sidebar badges
    case sidebar = "sidebar"
    case showEngineBadge = "show_engine_badge"
    case showCustomTag = "show_custom_tag"
    case customTag = "custom_tag"
    case customTagPlaceholder = "custom_tag_placeholder"
    case customTagHint = "custom_tag_hint"
}
