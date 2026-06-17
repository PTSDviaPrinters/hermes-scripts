<#PSScriptInfo
.VERSION 1.0.0
.GUID 12345678-1234-1234-1234-123456789012
.AUTHOR Toby
.COMPANYNAME Lee County
.COPYRIGHT 2026
.TAGS vcenter uptime windows powercli
.LICENSEURI 
.PROJECTURI 
.ICONURI 
.TOOLSETS 
.RELEASENOTES
>
#Requires -Modules VMware.VimAutomation.Core, VMware.VimAutomation.Common
#Requires -Modules VMware.Sdk.vSphere

<#
.SYNOPSIS
    Connects to vCenter, enumerates Windows VMs in a cluster, and reports uptime via WinRM.
.DESCRIPTION
    This script connects to a vCenter server, lists available clusters, allows the user
    to select one, then enumerates all Windows VMs in that cluster. It checks the uptime
    of each VM via WinRM (Kerberos) and exports the results to a CSV file.
.PARAMETER vCenter
    The vCenter server hostname (default: lc1pvm-vcenter.lee-county-fl.gov)
.EXAMPLE
    .\vcenter-uptime-report.ps1
.EXAMPLE
    .\vcenter-uptime-report.ps1 -vCenter "my-vcenter.local"
#>

param(
    [string]$vCenter = "lc1pvm-vcenter.lee-county-fl.gov"
)

# ============================================================
# Configuration
# ============================================================
$vCenterURL = "https://$vCenter"
$winrmPort = 5985
$winrmAuth = "Kerberos"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "uptime-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

# ============================================================
# Functions
# ============================================================

function Connect-vCenter {
    <#
    .SYNOPSIS
        Connect to vCenter server using PowerCLI.
    .DESCRIPTION
        Prompts for credentials and establishes a connection to the vCenter server.
    #>
    param(
        [string]$Server = $vCenterURL
    )
    
    Write-Host "Connecting to vCenter: $Server" -ForegroundColor Cyan
    Write-Host "Enter vCenter credentials:" -ForegroundColor Yellow
    
    try {
        $creds = Get-Credential -Message "vCenter Authentication"
        Connect-VIServer -Server $Server -Credential $creds -ErrorAction Stop | Out-Null
        Write-Host "Connected to vCenter successfully." -ForegroundColor Green
    } catch {
        Write-Host "Failed to connect to vCenter: $_" -ForegroundColor Red
        exit 1
    }
}

function Get-ClusterList {
    <#
    .SYNOPSIS
        Retrieve and display all clusters in the vCenter.
    .DESCRIPTION
        Queries the vCenter for all available clusters and displays them as a numbered list.
    #>
    Write-Host "`nRetrieving cluster list..." -ForegroundColor Cyan
    
    try {
        $clusters = Get-Cluster | Sort-Object Name
        if ($clusters.Count -eq 0) {
            Write-Host "No clusters found in vCenter." -ForegroundColor Red
            exit 1
        }
        
        Write-Host "`nAvailable Clusters:" -ForegroundColor White
        for ($i = 0; $i -lt $clusters.Count; $i++) {
            Write-Host "  [$($i + 1)] $($clusters[$i].Name)" -ForegroundColor White
        }
        
        return $clusters
    } catch {
        Write-Host "Failed to retrieve cluster list: $_" -ForegroundColor Red
        exit 1
    }
}

function Select-Cluster {
    <#
    .SYNOPSIS
        Prompt the user to select a cluster from the list.
    .DESCRIPTION
        Displays a numbered list of clusters and prompts the user to select one by number.
    #>
    param(
        [array]$Clusters
    )
    
    $maxIndex = $Clusters.Count
    $userInput = Read-Host "`nSelect a cluster (1-$maxIndex)"
    
    if ([int]::TryParse($userInput, [ref]$null) -and $userInput -ge 1 -and $userInput -le $maxIndex) {
        $selectedIndex = [int]$userInput - 1
        Write-Host "Selected cluster: $($Clusters[$selectedIndex].Name)" -ForegroundColor Green
        return $Clusters[$selectedIndex]
    } else {
        Write-Host "Invalid selection. Please enter a number between 1 and $maxIndex." -ForegroundColor Red
        return Select-Cluster -Clusters $Clusters
    }
}

function Get-WindowsVMs {
    <#
    .SYNOPSIS
        Enumerate Windows VMs in the selected cluster.
    .DESCRIPTION
        Retrieves all virtual machines in the specified cluster that are running Windows.
        Extracts the FQDN for each VM.
    #>
    param(
        [object]$Cluster
    )
    
    Write-Host "`nEnumerating Windows VMs in cluster: $($Cluster.Name)" -ForegroundColor Cyan
    
    try {
        $vms = Get-VM -Location $Cluster | Where-Object {
            $_.Guest.OSFullName -match "Windows"
        }
        
        if ($vms.Count -eq 0) {
            Write-Host "No Windows VMs found in cluster: $($Cluster.Name)" -ForegroundColor Yellow
            return @()
        }
        
        Write-Host "Found $($vms.Count) Windows VMs." -ForegroundColor Green
        
        # Extract FQDN from VM guest network interfaces
        $vmList = @()
        foreach ($vm in $vms) {
            $fqdn = $null
            if ($vm.Guest.IPAddress.Count -gt 0) {
                # Use the first IP address as FQDN if available
                $fqdn = $vm.Guest.IPAddress[0]
            }
            
            $vmList += [PSCustomObject]@{
                Name = $vm.Name
                FQDN = $fqdn
                PowerState = $vm.PowerState
            }
        }
        
        return $vmList
    } catch {
        Write-Host "Failed to enumerate VMs: $_" -ForegroundColor Red
        return @()
    }
}

function Test-WinRMConnectivity {
    <#
    .SYNOPSIS
        Test WinRM connectivity to a remote server.
    .DESCRIPTION
        Attempts to establish a WinRM session to the specified server to verify connectivity.
    #>
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credentials
    )
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -Credential $Credentials -Authentication Kerberos -ErrorAction Stop
        Remove-PSSession $session
        return $true
    } catch {
        Write-Host "  WinRM connection failed for $ComputerName: $_" -ForegroundColor Red
        return $false
    }
}

function Get-ServerUptime {
    <#
    .SYNOPSIS
        Retrieve uptime information from a Windows server via WinRM.
    .DESCRIPTION
        Connects to a Windows server via WinRM and retrieves the last boot time.
        Calculates the uptime duration from the last boot time to the current time.
    #>
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credentials
    )
    
    try {
        $session = New-PSSession -ComputerName $ComputerName -Credential $Credentials -Authentication Kerberos -ErrorAction Stop
        
        $bootTime = Invoke-Command -Session $session -ScriptBlock {
            (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        }
        
        Remove-PSSession $session
        
        if ($bootTime) {
            $uptime = (Get-Date) - $bootTime
            $uptimeString = "{0} days, {1} hours, {2} minutes, {3} seconds" -f $uptime.Days, $uptime.Hours, $uptime.Minutes, $uptime.Seconds
            
            return @{
                BootTime = $bootTime
                Uptime = $uptimeString
                Status = "Success"
            }
        } else {
            return @{
                BootTime = $null
                Uptime = $null
                Status = "No boot time data"
            }
        }
    } catch {
        return @{
            BootTime = $null
            Uptime = $null
            Status = "Failed: $_"
        }
    }
}

function Export-Results {
    <#
    .SYNOPSIS
        Export uptime results to a CSV file.
    .DESCRIPTION
        Takes an array of result objects and exports them to a CSV file with the specified filename.
    #>
    param(
        [array]$Results,
        [string]$OutputPath
    )
    
    try {
        $Results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "`nReport exported to: $OutputPath" -ForegroundColor Green
        Write-Host "Total VMs processed: $($Results.Count)" -ForegroundColor Green
        Write-Host "Successful: $($Results | Where-Object { $_.Status -eq 'Success' }).Count" -ForegroundColor Green
        Write-Host "Failed: $($Results | Where-Object { $_.Status -ne 'Success' }).Count" -ForegroundColor Red
    } catch {
        Write-Host "Failed to export results: $_" -ForegroundColor Red
    }
}

# ============================================================
# Main Execution
# ============================================================

function Main {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  vCenter Uptime Report Generator" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Step 1: Connect to vCenter
    Connect-vCenter
    
    # Step 2: Get cluster list
    $clusters = Get-ClusterList
    
    # Step 3: Select cluster
    $selectedCluster = Select-Cluster -Clusters $clusters
    
    # Step 4: Get Windows VMs
    $vms = Get-WindowsVMs -Cluster $selectedCluster
    
    if ($vms.Count -eq 0) {
        Write-Host "No VMs to process. Exiting." -ForegroundColor Yellow
        exit 0
    }
    
    # Step 5: Get credentials for WinRM
    Write-Host "`nEntering WinRM credentials (same as vCenter):" -ForegroundColor Yellow
    $winrmCreds = Get-Credential -Message "WinRM Authentication"
    
    # Step 6: Process each VM
    Write-Host "`nProcessing $($vms.Count) VMs..." -ForegroundColor Cyan
    $results = @()
    $progress = 0
    
    foreach ($vm in $vms) {
        $progress++
        Write-Host "`n[$progress/$($vms.Count)] Processing: $($vm.Name)" -ForegroundColor White
        
        if (-not $vm.FQDN) {
            Write-Host "  No FQDN found for $($vm.Name). Skipping." -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                VMName = $vm.Name
                FQDN = "N/A"
                LastBootTime = "N/A"
                Uptime = "N/A"
                Status = "No FQDN"
            }
            continue
        }
        
        Write-Host "  FQDN: $($vm.FQDN)" -ForegroundColor Gray
        Write-Host "  Checking uptime..." -ForegroundColor Gray
        
        $uptime = Get-ServerUptime -ComputerName $vm.FQDN -Credentials $winrmCreds
        
        $results += [PSCustomObject]@{
            VMName = $vm.Name
            FQDN = $vm.FQDN
            LastBootTime = if ($uptime.BootTime) { $uptime.BootTime.ToString() } else { "N/A" }
            Uptime = $uptime.Uptime
            Status = $uptime.Status
        }
    }
    
    # Step 7: Export results
    Export-Results -Results $results -OutputPath $outputFile
    
    # Disconnect from vCenter
    Write-Host "`nDisconnecting from vCenter..." -ForegroundColor Cyan
    Disconnect-VIServer -Server $vCenter -Confirm:$false | Out-Null
    Write-Host "Done." -ForegroundColor Green
}

# Run the main function
Main