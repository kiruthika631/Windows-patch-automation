#requires -Version 7.2
<#
.SYNOPSIS
Orchestrates convergent Windows patching through VMware Guest Operations.

.NOTES
All guest interaction is performed by PowerCLI Guest Operations cmdlets:
Invoke-VMScript and Copy-VMGuestFile. No network connection from the runner to
Windows management ports is required or used.
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $PSScriptRoot '../config/settings.json'),
    [string]$InventoryPath = (Join-Path $PSScriptRoot '../config/vms.csv'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../output'),
    [switch]$FailOnNonCompliance
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$commonModule = Join-Path $PSScriptRoot 'Modules/Framework.Common.psm1'
$guestOpsModule = Join-Path $PSScriptRoot 'Modules/VCenter.GuestOps.psm1'
$guestPatchScript = Join-Path $PSScriptRoot 'Guest/Invoke-WindowsUpdate.ps1'
$guestRepairScript = Join-Path $PSScriptRoot 'Guest/Repair-WindowsUpdateAgent.ps1'
$guestOfflineScript = Join-Path $PSScriptRoot 'Guest/Install-OfflineCumulativeUpdate.ps1'
Import-Module $commonModule -Force
Import-Module $guestOpsModule -Force

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw 'VMware.PowerCLI is required. Install the version pinned by the GitHub Actions workflow.'
}
if (-not (Test-Path -LiteralPath $guestPatchScript -PathType Leaf)) {
    throw "Guest patch script not found: $guestPatchScript"
}
if (-not (Test-Path -LiteralPath $guestRepairScript -PathType Leaf)) {
    throw "Guest repair script not found: $guestRepairScript"
}
if (-not (Test-Path -LiteralPath $guestOfflineScript -PathType Leaf)) {
    throw "Guest offline install script not found: $guestOfflineScript"
}

$configuration = Import-FrameworkConfiguration -SettingsPath $SettingsPath -InventoryPath $InventoryPath
$settings = $configuration.Settings
$inventory = @($configuration.Inventory)
Assert-FrameworkSettings -Settings $settings

$vCenterUser = Get-RequiredEnvironmentVariable -Name 'VCENTER_USERNAME'
$vCenterPassword = Get-RequiredEnvironmentVariable -Name 'VCENTER_PASSWORD'
$guestUser = Get-RequiredEnvironmentVariable -Name 'WINDOWS_GUEST_USERNAME'
$guestPassword = Get-RequiredEnvironmentVariable -Name 'WINDOWS_GUEST_PASSWORD'
$vCenterCredential = [pscredential]::new($vCenterUser, (ConvertTo-SecureString $vCenterPassword -AsPlainText -Force))
$guestCredential = [pscredential]::new($guestUser, (ConvertTo-SecureString $guestPassword -AsPlainText -Force))

# Avoid retaining plaintext secret strings beyond credential construction.
$vCenterPassword = $null
$guestPassword = $null
[GC]::Collect()

$runId = if ($env:GITHUB_RUN_ID) { "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)" } else { [guid]::NewGuid().ToString('N') }
$runDirectory = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) $runId
$vmLogsDirectory = Join-Path $runDirectory 'vm-logs'
New-Item -ItemType Directory -Path $vmLogsDirectory -Force | Out-Null
$masterLog = Join-Path $runDirectory 'master.jsonl'
Write-StructuredLog -Path $masterLog -Level Information -Stage Run -Message 'Patch run started.' -Data @{
    runId = $runId
    vmCount = $inventory.Count
    throttleLimit = [int]$settings.throttleLimit
    maxPatchCycles = [int]$settings.maxPatchCycles
}

try {
    & (Join-Path $PSScriptRoot 'Update-DocsSite.ps1') | Out-Null
}
catch {
    Write-StructuredLog -Path $masterLog -Level Warning -Stage Run -Message 'Failed to refresh docs site at patch start.' -Data @{
        error = $_.Exception.Message
    }
}

# Pre-connect all vCenters in the parent runspace so parallel workers inherit live sessions.
$inventoryVCenters = @($inventory | ForEach-Object {
    if ($_.PSObject.Properties.Name -contains 'VCenterServer' -and -not [string]::IsNullOrWhiteSpace($_.VCenterServer)) {
        $_.VCenterServer.Trim()
    }
    else {
        [string]$settings.vCenterServer
    }
} | Sort-Object -Unique)
foreach ($preConnectServer in $inventoryVCenters) {
    Connect-PatchVCenter -Server $preConnectServer -Credential $vCenterCredential `
        -IgnoreInvalidCertificate ([bool]$settings.ignoreInvalidCertificate) `
        -WebOperationTimeoutSeconds ([int]$settings.timeouts.webOperationSeconds) | Out-Null
    Write-StructuredLog -Path $masterLog -Level Information -Stage Run -Message 'Pre-connected vCenter for patch workers.' -Data @{
        vCenter = $preConnectServer
    }
}

$workerResults = @($inventory | ForEach-Object -ThrottleLimit ([int]$settings.throttleLimit) -Parallel {
    $row = $_
    Import-Module $using:commonModule -Force
    Import-Module $using:guestOpsModule -Force

    $runDirectory = $using:runDirectory
    $workerSettings = $using:settings
    $workerVCenterCredential = $using:vCenterCredential
    $workerGuestCredential = $using:guestCredential
    $guestRepairScript = $using:guestRepairScript
    $guestOfflineScript = $using:guestOfflineScript
    $offlineFallbackConfig = $using:settings.offlineCumulativeFallback
    $vmName = $row.VMName.Trim()
    $inventoryIp = if ($row.PSObject.Properties.Name -contains 'IPAddress') { [string]$row.IPAddress.Trim() } else { '' }
    $safeVMName = $vmName -replace '[^\w.-]', '_'
    $localVMDirectory = Join-Path $using:vmLogsDirectory $safeVMName
    New-Item -ItemType Directory -Path $localVMDirectory -Force | Out-Null
    $vmLog = Join-Path $localVMDirectory 'orchestrator.jsonl'
    $started = [DateTime]::UtcNow
    $stage = 'Initialize'
    $connected = $false
    $viServer = $null
    $completedConvergence = $false
    $totalFound = 0
    $totalInstalled = 0
    $reboots = 0
    $cycles = 0
    $allUpdates = [Collections.Generic.List[object]]::new()
    $status = 'Failed'
    $errorMessage = $null
    $errorType = $null

    $logRetry = {
        param($attempt, $retryError)
        Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
            -Message 'Retrying failed operation.' -Data @{
                attempt = $attempt
                error = $retryError.Exception.Message
            }
    }

    try {
        Write-StructuredLog -Path $vmLog -Level Information -Stage Initialize -VMName $vmName -Message 'VM worker started.'
        $stage = 'ConnectVCenter'
        $hasServerOverride = $row.PSObject.Properties.Name -contains 'VCenterServer'
        $server = if ($hasServerOverride -and -not [string]::IsNullOrWhiteSpace($row.VCenterServer)) {
            $row.VCenterServer
        }
        else {
            $workerSettings.vCenterServer
        }
        $viServer = Invoke-WithRetry -Operation {
            Connect-PatchVCenter -Server $server -Credential $workerVCenterCredential `
                -IgnoreInvalidCertificate ([bool]$workerSettings.ignoreInvalidCertificate) `
                -WebOperationTimeoutSeconds ([int]$workerSettings.timeouts.webOperationSeconds)
        } -OperationName "Connect to vCenter '$server'" -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        $connected = $true

        $stage = 'ValidateVM'
        $vm = Invoke-WithRetry -Operation { Get-UniquePatchVM -VMName $vmName -Server $viServer -IPAddress $inventoryIp } -OperationName "Find VM '$vmName'" `
            -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        if ($vm.PowerState -ne 'PoweredOn') {
            throw "VM '$vmName' is '$($vm.PowerState)'; PoweredOn is required."
        }

        $stage = 'WaitForTools'
        Wait-VMToolsReady -VM $vm -Server $viServer -TimeoutSeconds ([int]$workerSettings.timeouts.toolsReadySeconds) `
            -PollSeconds ([int]$workerSettings.pollIntervalSeconds)
        Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
            -Message 'VM exists and VMware Tools is ready.'

        $stage = 'StageGuestScript'
        $guestDirectory = $workerSettings.guestWorkingDirectory
        $guestScriptPath = "$($guestDirectory.TrimEnd('\', '/'))\Invoke-WindowsUpdate.ps1"
        $guestRepairScriptPath = "$($guestDirectory.TrimEnd('\', '/'))\Repair-WindowsUpdateAgent.ps1"
        Invoke-WithRetry -Operation {
            Initialize-GuestPatchWorkspace -VM $vm -GuestCredential $workerGuestCredential -GuestWorkingDirectory $guestDirectory
            Copy-PatchScriptToGuest -VM $vm -GuestCredential $workerGuestCredential `
                -Source $using:guestPatchScript -Destination $guestScriptPath
            Copy-PatchScriptToGuest -VM $vm -GuestCredential $workerGuestCredential `
                -Source $using:guestRepairScript -Destination $guestRepairScriptPath
        } -OperationName 'Stage guest patch scripts' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry

        Invoke-WithRetry -Operation {
            Reset-GuestPatchWorkspace -VM $vm -GuestCredential $workerGuestCredential -GuestWorkingDirectory $guestDirectory
        } -OperationName 'Reset guest patch workspace' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry

        $stage = 'PrepareGuestAutomation'
        $tokenPolicy = Invoke-WithRetry -Operation {
            Enable-GuestLocalAdminTokenPolicy -VM $vm -GuestCredential $workerGuestCredential
        } -OperationName 'Enable guest local admin token policy' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
            -Message 'Guest automation token policy verified.' -Data @{
                changed = [bool]$tokenPolicy.Changed
                previousValue = [int]$tokenPolicy.PreviousValue
                currentValue = [int]$tokenPolicy.CurrentValue
            }
        if ([bool]$tokenPolicy.Changed) {
            if (-not [bool]$workerSettings.autoRebootWhenRequired) {
                throw "Guest token policy changed but autoRebootWhenRequired is disabled for '$vmName'."
            }
            $stage = 'Reboot'
            $reboots++
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message 'Restarting guest after enabling LocalAccountTokenFilterPolicy.'
            Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                -PollSeconds ([int]$workerSettings.pollIntervalSeconds) `
                -PostRebootWarmUpSeconds ([int]$workerSettings.postRebootWarmUpSeconds)
        }

        $stage = 'RepairWindowsUpdate'
        $deepRepairAttempted = $false
        Invoke-WithRetry -Operation {
            Reset-GuestWindowsUpdateConnectivity -VM $vm -GuestCredential $workerGuestCredential -ExpectedIPv4 $inventoryIp
        } -OperationName 'Reset guest Windows Update connectivity' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        $comAvailableBeforeRepair = Invoke-WithRetry -Operation {
            Test-GuestWindowsUpdateComAvailable -VM $vm -GuestCredential $workerGuestCredential `
                -SearchCriteria $workerSettings.windowsUpdateSearchCriteria
        } -OperationName 'Test Windows Update COM availability' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        $prePatchConvergence = Invoke-WithRetry -Operation {
            Test-GuestPatchConvergence -VM $vm -GuestCredential $workerGuestCredential `
                -SearchCriteria $workerSettings.windowsUpdateSearchCriteria
        } -OperationName 'Test pre-patch convergence' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
        if (-not [string]::IsNullOrWhiteSpace($prePatchConvergence.SearchError)) {
            Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
                -Message 'Windows Update search reported an error during pre-check.' -Data @{
                    searchError = $prePatchConvergence.SearchError
                    comAvailable = [bool]$comAvailableBeforeRepair
                }
            if (-not $comAvailableBeforeRepair) {
                Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
                    -Message 'Windows Update COM unavailable; agent repair required before patching.'
            }
        }

        $skipOnlinePatchCycles = $false
        $osBuild = Get-GuestOsBuildNumbers -VM $vm -GuestCredential $workerGuestCredential
        $offlineFamily = [string]$osBuild.Build
        $offlineMinUbr = 5074
        $wuUnreachable = -not [string]::IsNullOrWhiteSpace($prePatchConvergence.SearchError)
        if ($null -ne $offlineFallbackConfig -and $offlineFallbackConfig.PSObject.Properties.Name -contains $offlineFamily) {
            $offlineMinUbr = [int]$offlineFallbackConfig.$offlineFamily.minimumUbr
        }
        if ($offlineFamily -eq '20348' -and [int]$osBuild.Ubr -ge $offlineMinUbr) {
            $status = 'Compliant'
            $completedConvergence = $true
            $skipOnlinePatchCycles = $true
            Write-StructuredLog -Path $vmLog -Level Information -Stage Convergence -VMName $vmName `
                -Message 'Guest OS build already meets minimum; skipping online Windows Update cycles.' -Data @{
                    build = $osBuild.Full
                    minimumUbr = $offlineMinUbr
                }
        }
        elseif ($offlineFamily -eq '20348' -and [int]$osBuild.Ubr -lt $offlineMinUbr -and $wuUnreachable -and $null -ne $offlineFallbackConfig) {
            $stage = 'OfflineCumulativeUpdate'
            Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
                -Message 'Windows Update unreachable; installing cached cumulative MSU via Guest Operations.' -Data @{
                    buildBefore = $osBuild.Full
                    minimumUbr = $offlineMinUbr
                }
            $cacheDir = Join-Path $runDirectory 'offline-msu-cache'
            $localMsu = Get-OfflineCumulativeMsuPath -BuildFamily $offlineFamily -FallbackConfig $offlineFallbackConfig `
                -CacheDirectory $cacheDir
            $offlineResult = Invoke-GuestOfflineCumulativeUpdate -VM $vm -GuestCredential $workerGuestCredential `
                -GuestWorkingDirectory $guestDirectory -LocalMsuPath $localMsu `
                -GuestInstallScriptPath $guestOfflineScript -LocalDirectory $localVMDirectory `
                -MinimumUbr $offlineMinUbr
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message 'Offline cumulative MSU finished.' -Data @{
                    status = [string]$offlineResult.status
                    wusaExitCode = $offlineResult.wusaExitCode
                    buildAfter = [string]$offlineResult.buildAfter
                }
            if ([string]$offlineResult.status -eq 'Failed') {
                throw "Offline cumulative update failed: $($offlineResult.error.message)"
            }
            if ([bool]$offlineResult.rebootRequired -or [string]$offlineResult.status -eq 'RebootRequired') {
                if (-not [bool]$workerSettings.autoRebootWhenRequired) {
                    throw "Offline cumulative update requires reboot but autoRebootWhenRequired is disabled for '$vmName'."
                }
                $stage = 'Reboot'
                $reboots++
                Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                    -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                    -PollSeconds ([int]$workerSettings.pollIntervalSeconds) `
                    -PostRebootWarmUpSeconds ([Math]::Max([int]$workerSettings.postRebootWarmUpSeconds, 240))
            }
            $osBuild = Get-GuestOsBuildNumbers -VM $vm -GuestCredential $workerGuestCredential
            if ([int]$osBuild.Ubr -ge $offlineMinUbr) {
                $status = 'Compliant'
                $completedConvergence = $true
                $skipOnlinePatchCycles = $true
            }
        }

        if ($skipOnlinePatchCycles) {
            Write-StructuredLog -Path $vmLog -Level Information -Stage Convergence -VMName $vmName `
                -Message 'Build meets minimum after offline cumulative update; skipping online patch cycles.' -Data @{
                    build = $osBuild.Full
                    minimumUbr = $offlineMinUbr
                }
        }
        if (-not $skipOnlinePatchCycles) {
        if ($comAvailableBeforeRepair -and [int]$prePatchConvergence.PendingUpdates -eq 0 -and `
            [string]::IsNullOrWhiteSpace($prePatchConvergence.SearchError)) {
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message 'Windows Update COM is available; skipping pre-patch repair.'
            $repairResult = [pscustomobject]@{
                status = 'Ready'
                comAvailable = $true
                deepRepairApplied = $false
                rebootRequired = $false
            }
        }
        elseif ($comAvailableBeforeRepair -and ([int]$prePatchConvergence.PendingUpdates -gt 0 -or `
            -not [string]::IsNullOrWhiteSpace($prePatchConvergence.SearchError))) {
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message 'Healthy Windows Update COM; skipping agent repair and proceeding to patch cycles.' -Data @{
                    pendingUpdates = [int]$prePatchConvergence.PendingUpdates
                    searchError = [string]$prePatchConvergence.SearchError
                }
            $repairResult = [pscustomobject]@{
                status = 'Ready'
                comAvailable = $true
                deepRepairApplied = $false
                rebootRequired = $false
            }
        }
        else {
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message 'Running Windows Update Agent repair before patching.'
            $repairResult = Invoke-WithRetry -Operation {
                Invoke-GuestWindowsUpdateRepair -VM $vm -GuestCredential $workerGuestCredential `
                    -GuestScriptPath $guestRepairScriptPath -GuestWorkingDirectory $guestDirectory `
                    -LocalDirectory $localVMDirectory -Server $server -VCenterCredential $workerVCenterCredential `
                    -IgnoreInvalidCertificate ([bool]$workerSettings.ignoreInvalidCertificate) `
                    -WebOperationTimeoutSeconds ([int]$workerSettings.timeouts.webOperationSeconds) `
                    -TimeoutSeconds ([int]$workerSettings.timeouts.repairCycleSeconds) `
                    -PollSeconds ([int]$workerSettings.pollIntervalSeconds)
            } -OperationName 'Repair Windows Update Agent' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
                -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
            if (-not [bool]$repairResult.comAvailable -and [string]$repairResult.status -ne 'Ready') {
                Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
                    -Message 'Basic repair did not restore Windows Update COM; running DISM/SFC deep repair.'
                $repairResult = Invoke-WithRetry -Operation {
                    Invoke-GuestWindowsUpdateRepair -VM $vm -GuestCredential $workerGuestCredential `
                        -GuestScriptPath $guestRepairScriptPath -GuestWorkingDirectory $guestDirectory `
                        -LocalDirectory $localVMDirectory -Server $server -VCenterCredential $workerVCenterCredential `
                        -IgnoreInvalidCertificate ([bool]$workerSettings.ignoreInvalidCertificate) `
                        -WebOperationTimeoutSeconds ([int]$workerSettings.timeouts.webOperationSeconds) `
                        -TimeoutSeconds ([int]$workerSettings.timeouts.repairCycleSeconds) `
                        -PollSeconds ([int]$workerSettings.pollIntervalSeconds) -DeepRepair
                } -OperationName 'Deep repair Windows Update Agent' -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
                    -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
            }
        }
        Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
            -Message 'Windows Update repair completed.' -Data @{
                status = [string]$repairResult.status
                comAvailable = [bool]$repairResult.comAvailable
                deepRepairApplied = [bool]$repairResult.deepRepairApplied
                rebootRequired = [bool]$repairResult.rebootRequired
            }
        if ([string]$repairResult.status -eq 'Failed') {
            $repairError = if ($repairResult.error) { $repairResult.error.message } else { 'Unknown repair error.' }
            throw "Windows Update repair failed: $repairError"
        }
        if ([string]$repairResult.status -eq 'RebootRequired' -or [bool]$repairResult.rebootRequired) {
            if (-not [bool]$workerSettings.autoRebootWhenRequired) {
                throw "Windows Update repair requires a reboot but autoRebootWhenRequired is disabled for '$vmName'."
            }
            $stage = 'Reboot'
            $reboots++
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message 'Restarting guest after Windows Update repair.'
            Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                -PollSeconds ([int]$workerSettings.pollIntervalSeconds) `
                -PostRebootWarmUpSeconds ([int]$workerSettings.postRebootWarmUpSeconds)
        }
        }

        $postRebootWarmUpSeconds = [int]$workerSettings.postRebootWarmUpSeconds
        $maxRebootOnlyCycles = [int]$workerSettings.maxRebootOnlyCycles
        $consecutiveRebootOnlyCycles = 0

        $testConvergence = {
            param($Reason)
            $convergence = Test-GuestPatchConvergence -VM $vm -GuestCredential $workerGuestCredential `
                -SearchCriteria $workerSettings.windowsUpdateSearchCriteria
            Write-StructuredLog -Path $vmLog -Level Information -Stage Convergence -VMName $vmName `
                -Message $Reason -Data @{
                    pendingUpdates = $convergence.PendingUpdates
                    rebootRequired = $convergence.RebootRequired
                    registryRebootPending = $convergence.RegistryRebootPending
                    isCompliant = $convergence.IsCompliant
                }
            return $convergence
        }

        $wuNetworkRepairAttempted = $false
        if (-not $skipOnlinePatchCycles) {
        for ($cycle = 1; $cycle -le [int]$workerSettings.maxPatchCycles; $cycle++) {
            $cycles = $cycle
            $stage = 'PatchCycle'
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message "Starting patch cycle $cycle."

            $cycleHandle = Invoke-WithRetry -Operation {
                Invoke-GuestPatchCycleSync -VM $vm -GuestCredential $workerGuestCredential `
                    -GuestScriptPath $guestScriptPath -GuestWorkingDirectory $guestDirectory `
                    -SearchCriteria $workerSettings.windowsUpdateSearchCriteria -Cycle $cycle
            } -OperationName "Start patch cycle $cycle" -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
                -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry

            $cycleResult = Invoke-WithRetry -Operation {
                Copy-GuestPatchArtifacts -VM $vm -GuestCredential $workerGuestCredential -CycleHandle $cycleHandle `
                    -LocalDirectory $localVMDirectory -Cycle $cycle
            } -OperationName "Collect patch cycle $cycle artifacts" -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
                -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry

            $totalFound += [int]$cycleResult.applicableCount
            $totalInstalled += [int]$cycleResult.installedCount
            foreach ($update in @($cycleResult.updates)) { $allUpdates.Add($update) }
            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                -Message "Patch cycle $cycle completed." -Data @{
                    status = $cycleResult.status
                    applicable = [int]$cycleResult.applicableCount
                    installed = [int]$cycleResult.installedCount
                    rebootRequired = [bool]$cycleResult.rebootRequired
                }

            if ($cycleResult.status -eq 'Failed') {
                $guestError = if ($cycleResult.error) { $cycleResult.error.message } else { 'Unknown guest patch error.' }
                $guestErrorId = if ($cycleResult.error) { [string]$cycleResult.error.fullyQualifiedErrorId } else { '' }
                $isComFailure = ($guestError + ' ' + $guestErrorId) -match '(?i)800703fa|8007041d|80040154|Microsoft\.Update\.(Session|SystemInfo)|COM class factory|marked for deletion|NoCOMClassIdentified|CimException|GetCimInstanceCommand'
                if ($isComFailure) {
                    if ($reboots -ge 2) {
                        throw "Windows Update COM failure persisted after $($reboots) remediation reboot(s) for '$vmName'."
                    }
                    if (-not [bool]$workerSettings.autoRebootWhenRequired) {
                        throw "Windows Update COM failure requires remediation reboot but autoRebootWhenRequired is disabled for '$vmName'."
                    }
                    $stage = 'Remediation'
                    Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
                        -Message 'Windows Update COM failure detected; rebooting guest to complete agent remediation.'
                    Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                        -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                        -PollSeconds ([int]$workerSettings.pollIntervalSeconds) `
                        -PostRebootWarmUpSeconds ([int]$workerSettings.postRebootWarmUpSeconds)
                    $reboots++
                    continue
                }
                $isWuSyncFailure = ($guestError + ' ' + $guestErrorId) -match '(?i)8024402C|WU_E_PT_NO_SYNC'
                if ($isWuSyncFailure -and -not $wuNetworkRepairAttempted) {
                    $wuNetworkRepairAttempted = $true
                    Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
                        -Message 'Windows Update sync failed; repairing guest IPv4 routing/DNS and retrying patch cycle.' -Data @{
                            error = $guestError
                        }
                    Repair-GuestIPv4Networking -VM $vm -GuestCredential $workerGuestCredential -ExpectedIPv4 $inventoryIp | Out-Null
                    Reset-GuestWindowsUpdateConnectivity -VM $vm -GuestCredential $workerGuestCredential -ExpectedIPv4 $inventoryIp | Out-Null
                    $cycle--
                    continue
                }
                throw "Guest patch cycle failed: $guestError"
            }
            if ($cycleResult.status -eq 'NoUpdates') {
                $status = 'Compliant'
                $completedConvergence = $true
                break
            }

            $needsReboot = ($cycleResult.status -eq 'RebootRequired' -or [bool]$cycleResult.rebootRequired)
            $isRebootOnlyCycle = ($needsReboot -and [int]$cycleResult.applicableCount -eq 0 -and [int]$cycleResult.installedCount -eq 0)
            if ($isRebootOnlyCycle) {
                $consecutiveRebootOnlyCycles++
            }
            else {
                $consecutiveRebootOnlyCycles = 0
            }

            if ($isRebootOnlyCycle -and $consecutiveRebootOnlyCycles -ge $maxRebootOnlyCycles) {
                $convergence = & $testConvergence 'Reboot-only cycles reached safety cap; verifying patch convergence.'
                if ($convergence.IsCompliant) {
                    $status = 'Compliant'
                    $completedConvergence = $true
                    break
                }
                if ($convergence.PendingUpdates -gt 0) {
                    Write-StructuredLog -Path $vmLog -Level Warning -Stage Convergence -VMName $vmName `
                        -Message 'Pending updates remain after reboot-only cycles; extending guest warm-up before retrying.'
                    $consecutiveRebootOnlyCycles = 0
                    Invoke-GuestPostRebootWarmUp -VM $vm -GuestCredential $workerGuestCredential `
                        -WarmUpSeconds ([Math]::Max($postRebootWarmUpSeconds, 120))
                    continue
                }
            }

            if ($needsReboot) {
                if ($isRebootOnlyCycle -and [bool]$cycleResult.remediationApplied -and -not $deepRepairAttempted) {
                    $convergence = & $testConvergence 'COM remediation loop detected; evaluating forced deep repair.'
                    if ([int]$convergence.PendingUpdates -gt 0) {
                        $stage = 'RepairWindowsUpdate'
                        Write-StructuredLog -Path $vmLog -Level Warning -Stage $stage -VMName $vmName `
                            -Message 'COM remediation did not restore update installation; running forced DISM/SFC deep repair.' -Data @{
                                pendingUpdates = [int]$convergence.PendingUpdates
                            }
                        $repairResult = Invoke-WithRetry -Operation {
                            Invoke-GuestWindowsUpdateRepair -VM $vm -GuestCredential $workerGuestCredential `
                                -GuestScriptPath $guestRepairScriptPath -GuestWorkingDirectory $guestDirectory `
                                -LocalDirectory $localVMDirectory -Server $server -VCenterCredential $workerVCenterCredential `
                                -IgnoreInvalidCertificate ([bool]$workerSettings.ignoreInvalidCertificate) `
                                -WebOperationTimeoutSeconds ([int]$workerSettings.timeouts.webOperationSeconds) `
                                -TimeoutSeconds ([int]$workerSettings.timeouts.repairCycleSeconds) `
                                -PollSeconds ([int]$workerSettings.pollIntervalSeconds) -DeepRepair:$true -ForceDeepRepair:$true
                        } -OperationName 'Forced deep repair after COM remediation loop' `
                            -MaxAttempts ([int]$workerSettings.retry.maxAttempts) `
                            -InitialDelaySeconds ([int]$workerSettings.retry.initialDelaySeconds) -OnRetry $logRetry
                        if ($null -ne $repairResult.dismExitCode) {
                            $deepRepairAttempted = $true
                        }
                        Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                            -Message 'Forced deep repair completed.' -Data @{
                                status = [string]$repairResult.status
                                comAvailable = [bool]$repairResult.comAvailable
                                deepRepairApplied = [bool]$repairResult.deepRepairApplied
                                rebootRequired = [bool]$repairResult.rebootRequired
                            }
                        if ([string]$repairResult.status -eq 'Failed') {
                            $repairError = if ($repairResult.error) { $repairResult.error.message } else { 'Unknown repair error.' }
                            throw "Forced deep repair failed: $repairError"
                        }
                        if ([string]$repairResult.status -eq 'RebootRequired' -or [bool]$repairResult.rebootRequired) {
                            if (-not [bool]$workerSettings.autoRebootWhenRequired) {
                                throw "Forced deep repair requires a reboot but autoRebootWhenRequired is disabled for '$vmName'."
                            }
                            $stage = 'Reboot'
                            $reboots++
                            Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                                -Message 'Restarting guest after forced deep repair.'
                            Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                                -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                                -PollSeconds ([int]$workerSettings.pollIntervalSeconds) `
                                -PostRebootWarmUpSeconds ([Math]::Max($postRebootWarmUpSeconds, 180))
                        }
                        $consecutiveRebootOnlyCycles = 0
                        continue
                    }
                }
                if ($isRebootOnlyCycle) {
                    $convergence = & $testConvergence 'Reboot requested with zero installs; checking guest state before reboot.'
                    if ($convergence.IsCompliant) {
                        $status = 'Compliant'
                        $completedConvergence = $true
                        break
                    }
                    if ($convergence.PendingUpdates -gt 0) {
                        Write-StructuredLog -Path $vmLog -Level Information -Stage Convergence -VMName $vmName `
                            -Message 'Rebooting despite pending updates to recover Windows Update COM or complete staged installs.'
                    }
                }
                if (-not [bool]$workerSettings.autoRebootWhenRequired) {
                    throw "Updates require a reboot but autoRebootWhenRequired is disabled for '$vmName'."
                }
                $stage = 'Reboot'
                $reboots++
                $rebootReason = if ($isRebootOnlyCycle) { 'Windows Update agent recovery or pending reboot flag.' } else { 'update installation.' }
                Write-StructuredLog -Path $vmLog -Level Information -Stage $stage -VMName $vmName `
                    -Message "Restarting guest after $rebootReason"
                Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                    -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                    -PollSeconds ([int]$workerSettings.pollIntervalSeconds) `
                    -PostRebootWarmUpSeconds $postRebootWarmUpSeconds

                $convergence = & $testConvergence 'Verifying patch convergence after reboot.'
                if ($convergence.IsCompliant) {
                    $status = 'Compliant'
                    $completedConvergence = $true
                    break
                }
            }
        }
        }

        if (-not $completedConvergence -and -not $skipOnlinePatchCycles) {
            $convergence = & $testConvergence 'Final convergence verification after patch cycles.'
            if ($convergence.IsCompliant) {
                $status = 'Compliant'
                $completedConvergence = $true
            }
            elseif ($convergence.PendingUpdates -gt 0 -and [bool]$workerSettings.autoRebootWhenRequired) {
                Write-StructuredLog -Path $vmLog -Level Warning -Stage Convergence -VMName $vmName `
                    -Message 'Final recovery reboot before marking non-compliant.'
                $stage = 'Reboot'
                $reboots++
                Restart-PatchVMGuest -VM $vm -Server $viServer -GuestCredential $workerGuestCredential `
                    -TimeoutSeconds ([int]$workerSettings.timeouts.rebootSeconds) `
                    -PollSeconds ([int]$workerSettings.pollIntervalSeconds) `
                    -PostRebootWarmUpSeconds ([Math]::Max($postRebootWarmUpSeconds, 120))
                $convergence = & $testConvergence 'Final recovery reboot convergence verification.'
                if ($convergence.IsCompliant) {
                    $status = 'Compliant'
                    $completedConvergence = $true
                }
            }
        }

        if (-not $completedConvergence) {
            $stage = 'Convergence'
            $status = 'MaxCyclesExceeded'
            throw "Applicable updates remain after the safety cap of $($workerSettings.maxPatchCycles) cycles."
        }
    }
    catch {
        if ($status -ne 'MaxCyclesExceeded') { $status = 'Failed' }
        $errorMessage = $_.Exception.Message
        $errorType = $_.Exception.GetType().FullName
        Write-StructuredLog -Path $vmLog -Level Error -Stage $stage -VMName $vmName -Message $errorMessage `
            -Data @{ type = $errorType; fullyQualifiedErrorId = $_.FullyQualifiedErrorId }
    }
    finally {
        # Do not Disconnect-VIServer here: parallel workers share one PowerCLI process and
        # disconnecting one vCenter session breaks other in-flight workers on the same host.
    }

    $ended = [DateTime]::UtcNow
    [pscustomobject]@{
        VMName = $vmName
        Status = $status
        Cycles = $cycles
        UpdatesFound = $totalFound
        UpdatesInstalled = $totalInstalled
        Reboots = $reboots
        StartUtc = $started.ToString('o')
        EndUtc = $ended.ToString('o')
        DurationSeconds = [Math]::Round(($ended - $started).TotalSeconds, 2)
        ErrorStage = if ($errorMessage) { $stage } else { $null }
        ErrorType = $errorType
        ErrorMessage = $errorMessage
        Updates = @($allUpdates)
        LogDirectory = $localVMDirectory
    }
})

$reports = Export-ComplianceReports -Results $workerResults -OutputDirectory $runDirectory

try {
    & (Join-Path $PSScriptRoot 'Update-DocsSite.ps1') | Out-Null
    Write-StructuredLog -Path $masterLog -Level Information -Stage Run -Message 'Internal docs site fleet status refreshed.' -Data @{
        fleetStatusJson = (Join-Path $PSScriptRoot '../docs/fleet-status.json')
    }
}
catch {
    Write-StructuredLog -Path $masterLog -Level Warning -Stage Run -Message 'Failed to refresh internal docs site fleet status.' -Data @{
        error = $_.Exception.Message
    }
}

# Build a deterministic master JSONL log from the run envelope and isolated VM logs.
$vmLogFiles = @(Get-ChildItem -LiteralPath $vmLogsDirectory -Filter '*.jsonl' -File -Recurse | Sort-Object FullName)
foreach ($vmLogFile in $vmLogFiles) {
    Get-Content -LiteralPath $vmLogFile.FullName | Add-Content -LiteralPath $masterLog -Encoding utf8
}
$compliantCount = @($workerResults | Where-Object Status -eq 'Compliant').Count
$failedCount = $workerResults.Count - $compliantCount
Write-StructuredLog -Path $masterLog -Level Information -Stage Run -Message 'Patch run completed.' -Data @{
    total = $workerResults.Count
    compliant = $compliantCount
    nonCompliant = $failedCount
    reportDirectory = $runDirectory
}

$summary = @"
## Windows Patch Automation

| Result | Count |
|---|---:|
| Total VMs | $($workerResults.Count) |
| Compliant | $compliantCount |
| Failed / non-compliant | $failedCount |

Run ID: ``$runId``  
Reports: ``$runDirectory``

### VM results

| VM | Status | Cycles | Installed | Reboots | Error stage |
|---|---|---:|---:|---:|---|
$($workerResults | Sort-Object VMName | ForEach-Object {
    "| $($_.VMName.Replace('|','\|')) | $($_.Status) | $($_.Cycles) | $($_.UpdatesInstalled) | $($_.Reboots) | $($_.ErrorStage) |"
} | Out-String)
"@

if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
else {
    $summary | Set-Content -LiteralPath (Join-Path $runDirectory 'github-summary.md') -Encoding utf8
}

Write-Output "Reports generated: $($reports.Json), $($reports.Csv), $($reports.Html)"
if ($FailOnNonCompliance -and $failedCount -gt 0) {
    throw "$failedCount VM(s) failed or did not converge. Reports were generated in '$runDirectory'."
}
