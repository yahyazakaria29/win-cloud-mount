@{
    # PSScriptAnalyzer configuration for WinCloudMount CI and local linting.
    # Severity is evaluated at Warning and Error level in CI.
    # Rules excluded below are intentional design choices for this CLI orchestration project:
    ExcludeRules = @(
        # CLI scripts print interactive colored status directly to the user host terminal
        'PSAvoidUsingWriteHost',

        # Domain functions use purposeful operational verbs (e.g. Assert-*, Load-*, Ensure-*)
        'PSUseApprovedVerbs',

        # Domain terms use standard pluralized nouns (e.g. Prerequisites, Errors)
        'PSUseSingularNouns',

        # CLI command routing uses explicit -Action switches rather than PowerShell ShouldProcess cmdlets
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
